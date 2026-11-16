# agentring for iPhone

Native Swift + SwiftUI app (iOS 17+). Your agent messages you and **calls you like a
real phone call**, locked screen included (PushKit + CallKit), and you can call it
back. Same relay, same protocol and same daemon as the Android app. The design is in
[docs/ios.md](../docs/ios.md).

```
app-ios/
  project.yml                    XcodeGen spec (the .xcodeproj is generated, not committed)
  Config/                        Base/Debug/Release.xcconfig, Local.xcconfig.example
  AgentringCore/                 SwiftPM package: protocol models, PushVerifier, RelayApi, RelaySocket
  Agentring/                     the app: SwiftUI, CallKit, PushKit, LiveKit
  AgentringNotificationService/  verifies alert pushes and fills in the message text
  Shared/                        code compiled into both targets (Keychain pairing, message store)
```

Dependencies: only the LiveKit Swift SDK, pinned to an exact version in `project.yml`
(`client-sdk-swift` 2.19.0). Everything else comes from the system.

## Build

You need a Mac with Xcode 16.3 or later (LiveKit's package needs Swift 6.1 tools; the
app itself is compiled in Swift 5 mode).

```bash
brew install xcodegen
cd app-ios
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set DEVELOPMENT_TEAM (and your bundle id)
xcodegen generate
open Agentring.xcodeproj
```

Run `xcodegen generate` again after pulling changes that touch `project.yml` or add files.

### Bundle id and signing

`Config/Base.xcconfig` sets `AGENTRING_BUNDLE_ID = dev.agentring.app`. Building it
yourself, you need an id your team owns: set `AGENTRING_BUNDLE_ID` and
`DEVELOPMENT_TEAM` in `Config/Local.xcconfig` (git-ignored). Everything else follows
from the bundle id:

| What | Value |
|---|---|
| App | `$(AGENTRING_BUNDLE_ID)` |
| Notification Service Extension | `$(AGENTRING_BUNDLE_ID).NotificationService` |
| App Group (message store shared with the extension) | `group.$(AGENTRING_BUNDLE_ID)` |
| Keychain sharing group (pairing shared with the extension) | `$(AppIdentifierPrefix)$(AGENTRING_BUNDLE_ID).shared` |
| APNs topics the relay pushes to | `$(AGENTRING_BUNDLE_ID)` (alerts), `$(AGENTRING_BUNDLE_ID).voip` (calls) |

With automatic signing, Xcode registers the App IDs, the App Group and these
capabilities for you: **Push Notifications**, **Background Modes** (Voice over IP,
Audio, Remote notifications), **App Groups**, **Keychain Sharing** and **Time
Sensitive Notifications** (entitlements in `Agentring/Agentring.entitlements` and
`AgentringNotificationService/AgentringNotificationService.entitlements`). If you sign
manually, enable them on both App IDs in the Apple Developer portal first.

Debug builds get APNs **sandbox** tokens (`aps-environment = development`) and tell the
relay `environment: sandbox`; Release builds (TestFlight / App Store) use
`production`. The relay picks the APNs host per token, so one relay serves both.

### Run on a device

The simulator can show the UI, pair and exchange messages over the WebSocket, but it
gets no VoIP pushes and has no CallKit ringing on a locked screen. Calls need a real
iPhone: pick it as the run destination and press Run. The first launch asks for
notifications and the microphone; the camera is asked when you scan the pairing QR.

## Point it at a relay that can wake it

A relay can only push to an app signed by the team that owns its APNs key. Three cases:

1. **agentring cloud** (`https://agentring.io`): the App Store build works as is.
2. **Your own relay, your own build.** Create an APNs key (Apple Developer → Keys → New
   key → Apple Push Notifications service), download the `.p8`, and give the relay:

   ```bash
   AGENTRING_APNS_KEY_FILE=/run/secrets/AuthKey_ABC123.p8
   AGENTRING_APNS_KEY_ID=ABC123            # the key's id
   AGENTRING_APNS_TEAM_ID=ABCDE12345       # your team id
   AGENTRING_APNS_TOPIC=dev.agentring.app  # your AGENTRING_BUNDLE_ID
   ```

   Details in [docs/apns.md](../docs/apns.md). Then `agentring pair` and scan the QR. The
   pair response carries `push_config = {provider: apns, apns: {topic, via_gateway: false}}`;
   the app compares `topic` with its own bundle id and sends its VoIP and alert tokens to
   the relay.
3. **Your own relay, the App Store build.** Your key can't reach an app someone else
   signed, so your relay pushes through the publisher's push gateway
   ([protocol/push-gateway.openapi.yaml](../protocol/push-gateway.openapi.yaml)): set
   `AGENTRING_APNS_GATEWAY_URL` on the relay (see [docs/apns.md](../docs/apns.md)). The relay
   announces `via_gateway: true` and a `gateway_url`; the app registers its tokens with the
   gateway and gives your relay only the opaque handle it gets back.

Without APNs on the relay (`push_config` is `null`), pairing still works, but messages
and calls arrive **only while the app is open**. The app says so after pairing and in
Settings, as it does when the relay's `topic` is not this app's bundle id.

## How it works (short)

- **Incoming call:** VoIP push (`call.invite` only) → reported to CallKit at once with a
  UUID derived from the call id → verified (`PushVerifier`, push secret from the
  Keychain) → `POST /v1/calls/{id}/ringing`. A push that fails verification is ended at
  once. There is no "stop ringing" VoIP push: while it rings the app keeps the WebSocket
  open, polls `GET /v1/calls/{id}` every 2 s and stops at `expires_at`.
- **Answer:** `accept` (or `join` if the ring window just closed) → LiveKit room → the
  CallKit action is fulfilled once connected. CallKit owns the audio session: LiveKit's
  automatic `AVAudioSession` handling is off and its audio engine runs only between
  `provider(_:didActivate:)` and `didDeactivate` (`AudioManager.setEngineAvailability`).
- **Call the agent:** `POST /v1/calls` → `CXStartCallAction` (Recents, CarPlay) → the
  phone joins the room and shows "Calling…" until `call.accept`, the agent in the room or
  the 2 s poll. Offline / busy / declined / no answer show the same texts as Android.
- **Group calls:** another phone's `call.accept` arrives as a background push; the app
  checks the call and posts a "Join" notification. `active_call` in `/v1/status` shows a
  Join banner when the app opens.
- **Messages:** alert pushes with a placeholder; the Notification Service Extension
  verifies them, puts in the agent's name and the text (fetching it when the push was
  truncated), and saves it to the store shared with the app. Inline reply sends
  `POST /v1/messages` from the app, launched in the background.
- **Lock-screen privacy:** CallKit only shows the agent's name; the call reason is in the
  app's call screen.

## Device test checklist

The acceptance test of [docs/ios.md](../docs/ios.md#build-ci-and-release), on a real
iPhone with a relay that has APNs configured for this build:

- [ ] Pair by scanning the QR; Settings shows Push **Registered**, both tokens OK.
- [ ] `agentring msg "hello"` with the phone locked → notification titled with the
      agent's name and the real text; inline **Reply** reaches `agentring replies`.
- [ ] A message longer than the push limit shows its full text (the extension fetches it).
- [ ] Phone locked, screen off for 10 min → `agentring call "test"` rings in **< 5 s**
      with the CallKit UI → answer → two-way audio.
- [ ] Same with the app force-quit (swiped away).
- [ ] Same in a Focus that allows agentring, and with the silent switch on (CallKit
      follows the switch: it vibrates).
- [ ] After a reboot, **before** the first unlock: the call can't be verified and ends at
      once; after unlocking, the relay's "Missed call" alert shows.
- [ ] The agent hangs up while it rings → the ring stops within ~2 s (WebSocket or poll);
      nobody answers → it stops at `expires_at` and a missed-call notification shows once.
- [ ] Mute from the lock screen / AirPods ↔ the in-app mute button stay in sync; speaker
      toggles.
- [ ] **Call agent** from the app: "Calling…" until the agent answers; hang up while it
      rings → `canceled`; with the agent offline / busy the message shows under the button.
- [ ] Group call with an Android phone: both ring; answer on Android → the iPhone shows a
      Join notification (or the Join banner when opened) → Join → all three hear each other.
- [ ] Unpair in Settings; `agentring devices revoke <id>` on a paired phone → the app shows
      "This phone was unpaired".
