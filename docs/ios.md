# iOS app (design)

> Status: **accepted and being implemented** (2026-11-16). The fork owner asked to
> take every open decision and build it all at once; the decisions are recorded in
> [Decisions](#decisions). The protocol changes are in `protocol/relay.openapi.yaml`
> and `protocol/push-gateway.openapi.yaml`; the app lives in `app-ios/`.

## Goal

An iPhone app with the same promise as the Android one:

- The agent calls the phone over VoIP and **it rings like a real call, locked and
  with the screen off**, using the native call UI (CallKit), in < 5 s.
- The agent sends messages, which show up as notifications you can reply to inline.
- The user calls the agent from the app (M4 flow).
- Same relay, same protocol, same daemon. An agent must not care whether a phone
  runs Android or iOS, and a relay can have both kinds of phones paired at once
  (group calls ring both).

Out of scope for the first version: iPad layout, Apple Watch, macOS, video, Siri
and a CarPlay app of our own (CallKit calls show up in CarPlay anyway, see below).

## What carries over unchanged

The protocol was written for one client, but nothing in it is Android-specific
except push:

| Piece | iOS |
|---|---|
| REST commands (`/v1/pair`, `/v1/messages`, `/v1/calls/...`) | `URLSession`, `Codable` models of `protocol/relay.openapi.yaml` |
| Resumable event stream `GET /v1/ws?after_seq=` | `URLSessionWebSocketTask`, same resume-by-`seq` logic as `RelaySocket.kt` |
| `device_jwt` auth, `4401` on revocation | Same; stored in the Keychain |
| HMAC-signed push payloads (`PushData`) | Same `v`, `relay_id`, `event`, `sig` fields, verified with CryptoKit `HMAC<SHA256>` |
| LiveKit tokens from `accept` / `join` / `POST /v1/calls` | LiveKit Swift SDK (`client-sdk-swift`) |
| Call states, group calls, targeted calls, `call.ringing` ack | Same REST calls, same semantics |
| `RelayUrlPolicy` (http only on private/LAN hosts) | Same rule in Swift; ATS `NSAllowsLocalNetworking` plus the Local Network permission for LAN relays |
| Hub mode (`/t/{tenant_id}`) | Transparent: the QR's `relay_url` already contains the tenant path |

The Android `:core` module (protocol models, `PushVerifier`, `RelayApi`,
`RelaySocket`, `RelayUrlPolicy`) is about 560 lines. Porting it to Swift is
cheaper than setting up Kotlin Multiplatform for it (see
[Language and project layout](#language-and-project-layout)).

## The hard part: push on iOS

Android wakes the app with an FCM high-priority **data** message, and the app
decides what to show. iOS has no equivalent:

1. **Only a PushKit VoIP push can make a locked iPhone ring** with the app in the
   background, suspended or terminated. FCM can't send VoIP pushes, so the relay
   has to talk to **APNs** directly (HTTP/2, token auth with a `.p8` key,
   `apns-push-type: voip`, topic `<bundle id>.voip`).
2. **Every VoIP push must become a CallKit call.** Since iOS 13 the app has to call
   `CXProvider.reportNewIncomingCall` before the PushKit completion handler
   returns. If it doesn't, iOS kills the app, and after a few misses it stops
   delivering VoIP pushes to it. So VoIP pushes may carry **only `call.invite`**,
   never "stop ringing", "someone joined" or a message.
3. **Other pushes are notifications, not code.** A message has to be an `alert`
   push (iOS shows it, and a Notification Service Extension may rewrite it first).
   A `background` push (`content-available: 1`) runs code but is throttled, not
   delivered to an app the user force-quit, and never guaranteed.
4. **APNs credentials can't be supplied at runtime.** On Android the relay hands the
   app the user's own Firebase client config (`push_config`), so one prebuilt APK
   works with anyone's Firebase project (architecture decision 11). APNs only
   delivers to an app signed by the Apple developer team that owns the key. **The
   App Store build can only receive pushes sent with its publisher's APNs key.**
   A self-hosted relay with its own key can only reach a build signed by its owner.

Points 1–3 shape the per-event rules below. Point 4 decides how self-hosted relays
reach the App Store app (see [Push distribution](#push-distribution-needs-ok)).

### Per-event push rules *(needs OK)*

Same events as `docs/protocol.md` → *Push (FCM)*, mapped to APNs push types:

| Event | Android (FCM) | iOS (APNs) | Notes |
|---|---|---|---|
| `call.invite` (`agent_to_user`) | data, high, TTL until `expires_at` | **`voip`**, priority 10, `apns-expiration` = `expires_at` | The app reports the call to CallKit at once, then verifies, then `POST /v1/calls/{id}/ringing`. |
| `call.end` / `call.missed` of an agent call | data, high, 30 s | **no VoIP push.** `call.missed` → `alert` "Missed call from <agent>", `apns-collapse-id` = `call_id` | While CallKit rings, the app is running: it keeps the WebSocket open, polls `GET /v1/calls/{id}` every 2 s as a fallback, and ends the CallKit call itself at `expires_at`. |
| `call.accept` (by a user, agent call) | data, normal, 1 h | `background`, priority 5, `apns-expiration` 1 h | Best effort, as on Android: the app checks the call and posts a local "Join" notification. `active_call` in `GET /v1/status` covers the rest when the app opens. |
| `msg.new` (`from: agent`) | data, high, 28 days | **`alert`**, `mutable-content: 1`, `thread-id` = `relay_id`, `apns-expiration` 28 days | The Notification Service Extension verifies and fills in the text (below). |

`call.decline` is not pushed, same as today. A targeted call's pushes go only to
the phones it targets, same as today.

Why not send `call.end` as a VoIP push? A common workaround is to report a dummy
call and end it immediately, but it can flash the call UI, and Apple's rule makes
every such push a risk. The app is already awake while it rings, so the WebSocket
plus a local timer cover the cancel. *Verify on a device:* the app keeps running
for the whole ring with CallKit's incoming call UI up. If it doesn't, fall back to
the dummy-call workaround for `call.end` only.

`apns-collapse-id` = `call_id` on the missed-call alert, and the app uses
`call_id` as the identifier of its own local missed-call notification, so the two
never show twice.

### APNs payloads

The signed part is byte-for-byte the same as `PushData`, so `PushVerifier` and the
push signature vector in `protocol/examples/push/` apply unchanged.

VoIP (`call.invite`), at most 5120 bytes:

```json
{
  "aps": {},
  "agentring": {
    "v": "1",
    "relay_id": "rly_01JB…",
    "event": "{\"type\":\"call.invite\",…}",
    "sig": "<base64url HMAC-SHA256(push_secret, event)>"
  }
}
```

Alert (`msg.new`, `call.missed`), at most 4096 bytes. The visible text is a
placeholder. Only the extension, after verifying, puts the real message in:

```json
{
  "aps": {
    "alert": { "title": "<agent_name>", "body": "New message" },
    "mutable-content": 1,
    "sound": "default",
    "thread-id": "rly_01JB…"
  },
  "agentring": { "v": "1", "relay_id": "…", "event": "{\"type\":\"msg.new\",…}", "sig": "…" }
}
```

The existing 3000-byte cap on the `event` JSON (`MAX_EVENT_BYTES`, the message text
is truncated with `truncated: true`) leaves enough room for the `aps` block.

### Notification Service Extension

A separate target (`AgentringNotificationService`) that runs for every alert push:

1. Reads `relay_id` + `push_secret` from the Keychain access group it shares with
   the app.
2. Verifies `sig`. If it fails, it leaves the placeholder ("New message") and adds
   nothing. Without Apple's notification filtering entitlement
   (`com.apple.developer.usernotifications.filtering`, granted on request) an
   extension can't hide a notification, so a forged push shows only the
   placeholder, never text an attacker chose.
3. If it verifies: `msg.new` → the message text as the body, the category with an
   inline reply action (`UNTextInputNotificationAction`). If `truncated`, it
   fetches `GET /v1/messages/{msg_id}` (it has about 30 s). It also writes the
   message into the shared store, so the thread is current when the app opens.
4. An urgent `call.missed` (the invite had `priority: urgent`) uses
   `interruption-level: time-sensitive`, so it can break through a Focus the user
   set to allow time-sensitive notifications.

The inline reply runs in the app, launched in the background, which sends
`POST /v1/messages` with `reply_to` and `client_msg_id`, as Android's `ReplyReceiver`
does.

## Push distribution *(needs OK)*

Who sends the APNs push depends on the deployment:

| Deployment | Who holds the APNs key | How the relay pushes |
|---|---|---|
| **agentring cloud** (hub mode) | The App Store app's publisher, who also runs the cloud | Directly: `ApnsProvider` in the relay, like FCM today. |
| **Self-hosted, own build** | The self-hoster (Apple Developer Program, 99 USD/year) | Directly, with their own key, to the app they built and installed (Xcode / TestFlight). |
| **Self-hosted, App Store app** | The publisher | Through a **push gateway** the publisher runs: the relay hands it an opaque, signed payload and the gateway calls APNs. |

Proposed order: ship the first two with the same `ApnsProvider`, then add the
gateway. Without the gateway, a self-hoster who installs the App Store app pairs
fine and gets messages and calls **only while the app is in the foreground**. The
app must say so plainly during pairing, as it does today when `push_config` is
`null`.

### Push gateway (sketch)

A small service (a relay mode, `AGENTRING_PUSH_GATEWAY=1`, Apache-2.0 like the rest)
that the App Store publisher runs, e.g. `https://push.agentring.io`:

```
app ──(1) POST /v1/register {voip_token, alert_token, environment}──▶ gateway
app ◀──────────── { handle }  (APNs tokens encrypted with the gateway's key) ────
app ──(2) POST /v1/pair / push-tokens { apns: { gateway_handle } } ──▶ self-hosted relay
relay ─(3) POST /v1/send { handle, push_type, payload, expiration, collapse_id } ─▶ gateway ─▶ APNs
```

- The self-hosted relay never sees raw APNs tokens, and the gateway stores nothing
  per device: the handle is the encrypted tokens.
- The gateway rate-limits per handle (e.g. VoIP pushes per hour) and per source IP,
  so a leaked handle can't be used to spam a phone. Abuse is bounded anyway: the
  app verifies `sig`, and a VoIP push that fails verification is reported to
  CallKit and ended immediately (`.failed`) without ringing on.
- The gateway rebuilds `aps` from an allowlist: alert pushes always show the title
  "agentring" and a fixed body ("New message" / "Missed call"), so a leaked handle
  can't make a phone show text of the holder's choosing. The extension puts in the
  agent's name and the real text only after verifying `sig`.
- `410 Unregistered` from APNs is passed back as `unregistered: true`, and the relay
  drops the handle like an `UNREGISTERED` FCM token.
- Optional: App Attest on `/v1/register`, so only the genuine app can get handles.
- Privacy: the payload passes through the gateway and Apple, as it passes through
  Google with FCM today. Encrypting `event` with a key derived from `push_secret`
  (HKDF → AES-256-GCM, `v: "2"`) would hide message text from both. It is an
  open decision, and if adopted it should apply to both platforms.

## Protocol changes (draft) *(needs OK)*

Additive only. Existing Android apps and daemons keep working.

1. `platform` (in `PairRequest` and `Device`): `enum: [android, ios]`.
2. `PairRequest` gets an optional `apns` object, the same as the body of the new
   endpoint below.
3. New `POST /v1/device/push-tokens` (device JWT), for token refreshes:
   ```json
   { "apns": { "voip_token": "<hex>", "alert_token": "<hex>", "environment": "sandbox" } }
   ```
   or `{ "apns": { "gateway_handle": "…" } }`. `environment` is `sandbox` (debug
   builds) or `production` (TestFlight/App Store), because APNs uses different hosts
   for them. `/v1/device/fcm` stays as it is for Android.
4. `PushConfig` is chosen by the `platform` in the pair request. For iOS:
   ```json
   { "provider": "apns", "apns": { "topic": "dev.agentring.app", "via_gateway": false } }
   ```
   The app compares `topic` with its own bundle id. If they differ, the relay's
   key can't reach it, and the app shows "this relay can't wake this app" during
   pairing. `null` still means "no push configured".
5. `Status.push_provider` becomes a list in a new field `push_providers:
   ["fcm", "apns"]`. The old field stays for compatibility.
6. `Device.has_push_token` stays (true if any token is set).
7. Fixtures: an iOS pair request/response, an APNs VoIP and alert payload, and an
   encrypted-payload vector if (v2) is adopted.

`docs/protocol.md` gets a *Push (APNs)* section with the table above.

## Relay changes

- `relay/src/push/apns.ts`: an `ApnsProvider` that implements `PushProvider` over
  `node:http2` (no new dependency), with an ES256 provider JWT signed by `jose`
  (already a dependency) and refreshed every 20–60 min as Apple requires. Config:
  `AGENTRING_APNS_KEY_FILE` (`.p8`), `AGENTRING_APNS_KEY_ID`,
  `AGENTRING_APNS_TEAM_ID`, `AGENTRING_APNS_TOPIC` (bundle id). The sandbox or
  production host is picked per token.
- `PushOptions` gains a `kind: "call" | "message" | "update"` hint. FCM ignores it,
  and APNs maps it to `voip` / `alert` / `background`.
- `PushDispatcher` picks the provider per device (`platform` + which tokens are
  set) and applies the iOS rules above (no VoIP push for `call.end`, an alert for
  `call.missed`).
- DB: new nullable columns for the APNs tokens / gateway handle and environment.
  A device can have only one kind of token.
- `ApnsGatewayProvider` (later): the same interface, sends to the gateway.
- Tests: a fake APNs HTTP/2 server (as the FCM tests fake Google), the dispatcher
  rules per platform, and `410` → token cleared.

The daemon needs almost nothing: `agentring devices` shows the platform.

## iOS app

### Capabilities and targets

- App target `dev.agentring.app` (if the publisher keeps the Android id). Background
  modes `voip`, `audio`, `remote-notification`. Push Notifications. Time Sensitive
  Notifications. Keychain sharing / App Group with the extension.
- `AgentringNotificationService` extension (above).
- `Info.plist`: `NSMicrophoneUsageDescription`, `NSCameraUsageDescription` (QR),
  `NSLocalNetworkUsageDescription` (LAN relays), ATS `NSAllowsLocalNetworking`.

### Main pieces (mirrors `app-android`)

| Android | iOS |
|---|---|
| `PairingStore`, `SecretStore` | Keychain items (`device_jwt`, `push_secret`, `relay_id`) in the shared access group, `kSecAttrAccessibleAfterFirstUnlock` |
| `MessageRepository` (Room) | Local store shared with the extension (SQLite in the App Group container; no third-party DB) |
| `ConnectionManager`, `RelaySocket` | `RelayConnection` actor: WebSocket while foreground or on a call, resume by `seq`, `GET /v1/events` paging when woken |
| `AgentringMessagingService`, `PushHandler`, `PushRegistrar` | `PKPushRegistry` delegate (VoIP), `UNUserNotificationCenter` delegate (alerts, actions), token upload to `/v1/device/push-tokens` |
| `CallManager`, `TelecomBridge`, `CallService`, `Ringer` | `CallController` around `CXProvider` + `CXCallController`. CallKit owns the ringtone, the lock-screen UI and the audio session. |
| `VoiceSession` (LiveKit Android) | `VoiceSession` (LiveKit Swift): a new `Room` per call, connect on answer, mic only |
| `CallActivity` | SwiftUI call screen (mute, speaker, hang up) when the app is open. The system call UI otherwise. |
| `MessagesScreen`, `MainScreens`, `OnboardingScreens` | SwiftUI: pairing (QR with VisionKit `DataScannerViewController` or AVFoundation), thread, settings, a short onboarding |
| `:auto` module (Android Auto) | Nothing to build for the basics: CallKit calls show in CarPlay (answer, mute, hang up). Calling the agent from the car (Siri / `INStartCallIntent` from Recents) comes later. |

### Incoming call flow

```
PushKit didReceiveIncomingPush(payload)
  ├─ parse agentring.event (call.invite) → call_id, agent name, priority, expires_at
  ├─ reportNewIncomingCall(uuid = UUID derived from call_id, handle = agent name)   ← must happen first
  ├─ verify sig with push_secret
  │    ├─ bad sig / unknown relay / expired → end the CallKit call at once (.failed / .unanswered)
  │    └─ ok → POST /v1/calls/{id}/ringing, open WebSocket, start expires_at timer + 2 s poll
  ├─ user answers (CXAnswerCallAction) → POST /v1/calls/{id}/accept → { join } → LiveKit connect
  │      → action.fulfill() after the room connects (or fail after ~10 s)
  ├─ user declines (CXEndCallAction while ringing) → POST /v1/calls/{id}/decline
  └─ call.end / call.missed over WS, or timer → reportCall(endedAt:reason:)
```

- **Audio:** CallKit activates the `AVAudioSession`. LiveKit's automatic audio
  session handling is turned off, and the audio engine starts in
  `provider(_:didActivate:)` and stops in `didDeactivate`. The exact API depends on
  the LiveKit Swift SDK version; follow its CallKit example when implementing.
  This is the iOS counterpart of "only one component may control audio routing"
  in `docs/voip-research.md`.
- **Mute** stays in sync both ways: `CXSetMutedCallAction` (lock screen, CarPlay,
  AirPods) ↔ the LiveKit mic.
- **Lock-screen privacy:** CallKit shows only the agent name. The call reason is
  shown in the app, not in the system call UI, the same intent as
  `LockScreenPrivacy.kt`.
- **Before the first unlock after a reboot** the Keychain items can't be read, so
  the app can't verify and ends the call at once. The relay then reports
  `call.missed`, and an alert appears once the phone is unlocked. *Verify on a
  device.*

### Outgoing call to the agent (M4 flow)

"Call agent" → `CXStartCallAction` (the call shows in Recents and in CarPlay) →
`POST /v1/calls` → join the room at once → "Calling…" until `call.accept`, the
agent in the room, or the poll. Cancel while ringing → `POST /v1/calls/{id}/end`.
The agent offline / busy / declined / missed messages are the same as on Android.

### Group calls and "join"

Both platforms ring in the same group call. On iOS the "Join" offer comes from the
best-effort `background` push (local notification with a Join action) or from
`active_call` when the app opens. Join → `POST /v1/calls/{id}/join` →
`CXStartCallAction` for the existing call, so the system knows a call is active.

### Urgent calls

Android plays urgent calls on the alarm stream and can bypass Do Not Disturb. iOS
has no equivalent for VoIP calls: CallKit follows the ring/silent switch and Focus.
Critical Alerts covers notifications only (not CallKit) and needs Apple's approval,
so it is out of scope. What iOS offers: onboarding explains how to allow agentring
in a Focus, and the urgent missed-call alert is time-sensitive.

### Onboarding (much shorter than Android's)

Notifications permission (alerts + time-sensitive), microphone, pairing via QR, then
a test call. No battery, full-screen intent or OEM steps. The app checks that
`push_config.apns.topic` matches and that it got a VoIP token, and says so if not.

## Language and project layout

**Native Swift + SwiftUI**, no cross-platform framework. CallKit, PushKit and audio
session handling are where the work is, and they are best done natively, as the
Android app does with Telecom. Kotlin Multiplatform for `:core` alone is possible,
but it adds a Gradle-built framework to the iOS build for about 560 lines of code.

```
app-ios/
  project.yml                 # XcodeGen spec (text, reviewable); .xcodeproj is generated, not committed
  AgentringCore/              # SwiftPM package: protocol models, PushVerifier, RelayApi, RelaySocket, RelayUrlPolicy
    Tests/                    # round-trips every file in protocol/examples/, push signature vector
  Agentring/                  # app target (SwiftUI, CallKit, PushKit, LiveKit)
  AgentringNotificationService/
  AgentringUITests/           # pairing + messages against a real relay, in the simulator
```

- **Minimum iOS 17**: SwiftUI Observation, VisionKit scanner, and very few devices
  left below it by now.
- **Dependencies:** only the LiveKit Swift SDK (pinned exact version, at least
  ~2 weeks old, per the repo's dependency policy). Networking, JSON, crypto and
  storage come from the system.
- **XcodeGen vs a committed `.xcodeproj`:** XcodeGen keeps the project as reviewable
  text and avoids `project.pbxproj` merge conflicts, at the cost of one pinned build
  tool. *(decision)*

## Build, CI and release

- iOS builds need macOS + Xcode. Cloud sessions (Linux) can edit the code but can't
  build or run it. The user builds locally, or CI does it.
- `.github/workflows/ios.yml` on a `macos` runner (free for a public repo):
  `swift test` for `AgentringCore`, `xcodebuild` for the simulator, and the UI test
  against a relay started in the job (pair → message → reply), mirroring
  `M1EndToEndTest`.
- **What only a real iPhone can test:** PushKit/CallKit ring timing, the locked
  phone, Bluetooth/CarPlay routing, the extension under memory limits. The acceptance
  test mirrors M2's: iPhone locked, screen off for 10 min → `agentring call "test"`
  rings in < 5 s with the CallKit UI → answer → audio works. Repeat with the app
  force-quit, in a Focus, with the silent switch on, and after a reboot before the
  first unlock.
- **Release:** an Apple Developer account (organization), App IDs for the app and
  the extension, an APNs `.p8` key (kept like the Android release key: GitHub
  secrets for CI, offline copy with the maintainer), TestFlight, then App Store.
  App Review notes need a demo relay/account (the cloud is the natural choice).
  CallKit apps are not allowed on the China storefront, so exclude it.

## Phases

| Phase | Scope | Done when |
|---|---|---|
| **I1** | Protocol + relay `ApnsProvider` (direct key). App: pairing, messages, alert pushes via the extension, inline reply. | A message from `agentring msg` shows on a locked iPhone with its text and gets a reply. |
| **I2** | PushKit + CallKit incoming calls, LiveKit audio, ring cancel/missed, group calls with Android phones. | The acceptance test above passes on a real iPhone. |
| **I3** | Call the agent from the app, join, missed/declined fallbacks, onboarding polish. | Same flows as M4 on Android. |
| **I4** | Push gateway for self-hosted relays + App Store app, CI on macOS, TestFlight → App Store, docs (`setup.md`, README). | A self-hosted relay rings the App Store build. |

Each phase ends with a stop, test instructions and the maintainer's OK, as for
M1–M5.

## Decisions

Taken on 2026-11-16 (the sections marked *(needs OK)* above are accepted as written):

1. **Push distribution:** all three paths. The relay pushes directly with an APNs
   key (cloud / hub mode and self-hosters with their own build) or through a push
   gateway (self-hosted relay + App Store app). The gateway is a relay mode
   (`AGENTRING_PUSH_GATEWAY=1`), contract in `protocol/push-gateway.openapi.yaml`.
   Whoever publishes the App Store build runs it.
2. **Bundle id:** a build setting, `AGENTRING_BUNDLE_ID` (default
   `dev.agentring.app`); the relay's `AGENTRING_APNS_TOPIC` must match it, and the
   app warns when `push_config.apns.topic` differs.
3. **Payloads stay v1** (signed, not encrypted), the same as on Android. Encryption
   can come later for both platforms at once.
4. **XcodeGen** (`app-ios/project.yml`); the `.xcodeproj` is generated, not committed.
5. **Minimum iOS 17.**
6. **Ring cancel without a VoIP push** (WebSocket + 2 s poll + local timer). To
   confirm on a device in I2, together with the before-first-unlock case.
