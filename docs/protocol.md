# Protocol (v1)

> Status: **proposal for M1 review**. The normative definition is
> [`protocol/relay.openapi.yaml`](../protocol/relay.openapi.yaml); this document
> explains the flows.

## Principals and authentication

| Principal | Credential | Header |
|---|---|---|
| **agent** (the daemon) | API key `ak_…` (random 32 bytes, base64url) | `Authorization: Bearer ak_…` |
| **device** (the phone) | `device_jwt` (HS256, `iss`=`relay_id`, `sub`=`device_id`, `aud`=`device`) | `Authorization: Bearer eyJ…` |
| LiveKit server | LiveKit webhook signature | `Authorization: <livekit jwt>` |

In hub mode the agent may also use a short-lived agent token `at_…` issued by the
hub admin API ([cloud.md](cloud.md#admin-api)); it works like the API key until it
expires.

The relay tells credentials apart by prefix (`ak_`, `at_`) vs JWT shape. TLS is
mandatory in production; the relay refuses to start with a non-`https` public
URL unless `AGENTRING_INSECURE_DEV=1`.

Every device request re-checks the device row, so `DELETE /v1/devices/{id}`
revokes immediately (REST returns 401, open WebSockets are closed with code
4401). A phone on the open call also ends that call: its room closes, which is
what takes back a join token LiveKit keeps refreshing.

## Identifiers and time

- IDs are prefixed ULIDs (lexicographically sortable): `dev_…`, `call_…`,
  `msg_…`, `evt_…`. The relay itself has a `relay_id` (`rly_…`) generated on
  first start.
- All timestamps are **integer milliseconds since the Unix epoch (UTC)**.

## Events

Every event is a flat JSON object:

```json
{ "type": "msg.new", "id": "evt_01JB…", "ts": 1761200000000, "seq": 42,
  "msg_id": "msg_01JB…", "from": "agent", "text": "Build finished ✅" }
```

| Field | Meaning |
|---|---|
| `type` | discriminator (below) |
| `id` | unique event id; clients de-duplicate on it (an event can arrive by FCM *and* WS) |
| `ts` | creation time, ms |
| `seq` | position in the relay's event log (monotonic, global, may have gaps per principal). Absent on ephemeral events. |

### Catalogue

| `type` | Payload | Persisted | Emitted when |
|---|---|---|---|
| `call.invite` | `call_id, direction, agent_name, reason, priority, expires_at, device_ids?` | ✓ | a call is created; addressed to the callee side (`device_ids` only on a targeted call) |
| `call.ringing` | `call_id, device_id` | ✓ | a device shows the incoming call UI |
| `call.accept` | `call_id, by, device_id?` | ✓ | a callee answered (in a group call, once per phone that joins, by `accept` or `join`) |
| `call.decline` | `call_id, by, device_id?` | ✓ | a callee declined (in a group call, only that phone) |
| `call.end` | `call_id, by, reason, duration_ms?` | ✓ | either side hung up, caller canceled while ringing, or LiveKit closed the room |
| `call.missed` | `call_id` | ✓ | no answer after `RING_TIMEOUT_S` (default 30) |
| `msg.new` | `msg_id, from, text, reply_to?, truncated?` | ✓ | a message was posted |
| `msg.read` | `msg_id, by` | ✓ | the other side read it |
| `agent.presence` | `online` | ✗ | daemon WS connected / disconnected (devices only) |
| `ws.hello` | `relay_id, last_seq, server_ts` | ✗ | first frame on every WebSocket |

- `direction`: `agent_to_user` (agent calls phone) or `user_to_agent`.
- `priority`: `normal` | `urgent`. Urgent = alarm stream + bypass DnD if the
  user granted policy access.
- `by`: `agent` | `user` | `relay` (relay = timeout / room closed).
- `call.end.reason`: `hangup` | `canceled` | `room_closed` | `error`.
- `expires_at` on `call.invite`: the app must not ring after this time (late
  FCM delivery).
- `msg.new.truncated` is only ever `true` inside a push payload (FCM data is
  capped at 4 KB); the app then fetches `GET /v1/messages/{msg_id}`.

## Transport

### REST (commands)

All mutations are REST calls (see OpenAPI). Errors have the shape
`{"error": {"code": "busy", "message": "…"}}`.

`POST /v1/messages` accepts an optional `client_msg_id`; retries with the same
value return the original message (idempotency for flaky mobile networks).

### WebSocket (event stream)

`GET /v1/ws?after_seq=<n>` with the usual `Authorization` header.

1. Server sends `ws.hello`.
2. Server replays every persisted event visible to the principal with
   `seq > after_seq`, then streams live events.
3. Client → server frames are not used in v1 (keepalive via WS ping/pong every
   20 s; the relay drops sockets silent for 60 s).

`GET /v1/events?after_seq=<n>` returns the same thing as a page, for clients
that only want to catch up (e.g. `agentring replies` when `serve` isn't
running).

Visibility: both principals see all persisted events; each side acts on them
according to `direction`/`from`. Devices additionally get `agent.presence`. The
exception is a targeted call (see *Targeted calls*): its `call.*` events reach
only the agent and the phones it targets, on the WebSocket (live and replay),
over FCM and in `GET /v1/events`. Because of that a page of `GET /v1/events` can
hold fewer events than `limit`; page on its `next_after_seq`.

### Push (FCM)

Sent through the `PushProvider` interface. The dispatcher picks the provider per
device: Android → FCM, iOS → APNs (directly, or through a push gateway when the device
registered a gateway handle). See [Push (APNs)](#push-apns) for iOS.

```ts
interface PushProvider {
  readonly name: string;                       // "fcm" | "apns" | "apns_gateway"
  send(target: PushTarget, payload: PushPayload, opts: PushOptions): Promise<PushResult>;
}
interface PushTarget { deviceId: string; token: string; environment?: "sandbox" | "production"; topic?: string }
interface PushOptions {
  ttlSeconds: number; highPriority: boolean; collapseKey?: string;
  kind?: "call" | "message" | "update";        // FCM ignores it; APNs: voip / alert / background
  expiresAt?: number;                          // APNs apns-expiration (default now + ttl)
  aps?: Record<string, unknown>;               // APNs only
}
type PushResult = { ok: true } | { ok: false; unregistered: boolean; error: string };
```

FCM HTTP v1 message (data-only, never a `notification` block, so the app
always handles it itself):

```json
{
  "message": {
    "token": "<fcm_token>",
    "android": { "priority": "HIGH", "ttl": "30s" },
    "data": {
      "v": "1",
      "relay_id": "rly_01JB…",
      "event": "{\"type\":\"call.invite\",…}",
      "sig": "<base64url HMAC-SHA256(push_secret, event)>"
    }
  }
}
```

Which events are pushed to devices:

| Event | TTL | Why |
|---|---|---|
| `call.invite` (`agent_to_user`) | until `expires_at` (≤ 30 s) | ring |
| `call.end` / `call.missed` of an agent call | 30 s | stop ringing / tear down the call screen on all devices |
| `call.accept` of an agent call (**normal** priority), to every phone except the one that joined | 1 h | offer "join the call" on the phones that are not on it |

A targeted call's pushes go only to the phones it targets.
| `msg.new` (`from: agent`) | 28 days | notification |

`call.accept` goes at normal priority: a phone still ringing has nothing to show
for it, and high-priority pushes that show nothing get an app's later pushes
deprioritized by FCM; a phone in Doze gets it at its next maintenance window or
when the screen turns on, which is soon enough to offer "join". The TTL is long
so a phone that was offline during the ring still learns about the call; the app
checks the call (`GET /v1/calls/{call_id}`) before offering anything.
`call.decline` is not pushed: one phone declining changes nothing for the others.

An `UNREGISTERED` FCM response clears the device's token (the app will
re-send it via `POST /v1/device/fcm` on next start/refresh).

### Push (APNs)

iOS devices (`platform: "ios"`) are pushed over APNs (design: [ios.md](ios.md); setup:
[apns.md](apns.md)). iOS only lets a **VoIP** push (PushKit) ring a locked phone, and
every VoIP push must become a CallKit call, so only `call.invite` is one. Messages and
missed calls are **alert** pushes (the system shows them; the app's Notification
Service Extension rewrites them first), and "someone answered" is a best-effort
**background** push.

| Event | APNs push | `apns-priority` | `apns-expiration` | Other headers / `aps` |
|---|---|---|---|---|
| `call.invite` (`agent_to_user`) | `voip`, topic `<bundle id>.voip` | 10 | `expires_at` | `aps: {}` |
| `call.end` | **none** (the app is awake while CallKit rings: WebSocket, 2 s poll, local timer at `expires_at`) | | | |
| `call.missed` of an agent call | `alert` | 10 | now + 24 h | `apns-collapse-id` = `call_id`; title = the call's `agent_name`, body "Missed call", category `AGENTRING_MISSED`, `interruption-level: time-sensitive` when the call was `urgent` |
| `call.accept` (`by: user`) of an agent call, to every phone except the one that joined | `background` | 5 | now + 1 h | `aps: {"content-available": 1}` |
| `msg.new` (`from: agent`) | `alert` | 10 | now + 28 days | title = agent name, body "New message", category `AGENTRING_MESSAGE` |

Every alert carries `mutable-content: 1`, `sound: "default"` and `thread-id` =
`relay_id`. The visible text is always a placeholder, never the message: the extension
verifies `sig` and only then puts the real text in. `call.decline` is not pushed, and a
targeted call's pushes go only to its phones, as on Android.

Payload (`ApnsPayload`): the signed `agentring` object is exactly the FCM `data` map
(`PushData`), so the same verifier and the push signature vector apply. VoIP pushes
are at most 5120 bytes, the others 4096; the 3000-byte cap on `event` leaves room for
`aps`. Fixtures signed with the vector's `push_secret`:
`protocol/examples/push/apns-voip.json`, `apns-alert.json`, `apns-alert-missed.json`.

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

```json
{
  "aps": {
    "alert": { "title": "Claude", "body": "New message" },
    "mutable-content": 1,
    "sound": "default",
    "thread-id": "rly_01JB…",
    "category": "AGENTRING_MESSAGE"
  },
  "agentring": { "v": "1", "relay_id": "rly_01JB…", "event": "{\"type\":\"msg.new\",…}", "sig": "…" }
}
```

Registration: `POST /v1/pair` with `platform: "ios"` and `apns`, or later
`POST /v1/device/push-tokens`:

```json
{ "apns": { "voip_token": "<hex>", "alert_token": "<hex>", "environment": "sandbox", "topic": "dev.agentring.app" } }
{ "apns": { "gateway_handle": "<from the push gateway's /v1/register>" } }
```

- Each call **replaces** the device's APNs registration: send both tokens every time.
  `environment` is required with tokens (`sandbox` for Xcode debug builds,
  `production` for TestFlight/App Store); `topic` defaults to the relay's
  `AGENTRING_APNS_TOPIC`. Tokens and a handle are mutually exclusive.
- An Android device can't register APNs data and an iOS device can't register an FCM
  token (`400 invalid_request`), so a device has either kind, never both.
- `push_config` in the pair response is chosen by `platform`. For iOS:
  `{"provider":"apns","apns":{"topic":"dev.agentring.app","via_gateway":false}}`, or
  with `via_gateway: true` and `gateway_url` when the relay pushes through a gateway,
  or `null` when it can't push to iOS at all (the app then only gets events while
  open). The app compares `topic` with its own bundle id.
- `GET /v1/status` lists `push_providers` (`fcm`, `apns`, `apns_gateway`);
  `GET /v1/devices` shows each device's `platform`, and `has_push_token` is true when
  it has any token (FCM, either APNs token, or a gateway handle).
- APNs `410`, or `400` `BadDeviceToken` / `Unregistered` / `DeviceTokenNotForTopic`,
  clears that token (only the VoIP or the alert one); a gateway's `410` (or a handle
  it can't open) clears the handle.

## Flows

### Pairing

```
agentring pair
  └─ POST /v1/pairing-tokens  (agent)        → { pairing_token, expires_at, qr_payload }
     prints QR(qr_payload)                      qr_payload = {"v":1,"relay_url":"https://…","pairing_token":"pt_…"}
app scans QR
  └─ POST /v1/pair { pairing_token, fcm_token, device_name, platform, app_version }
       → { device_id, device_jwt, push_secret, relay_id, agent_name, push_config }
     push_config = the user's Firebase client values (or null): the app initialises
     Firebase at runtime, so one prebuilt APK works with anyone's Firebase project
     relay: token single-use (stored hashed), expires after 10 min
app stores device_jwt + push_secret (SecretStore: AES-GCM with an Android Keystore key)
FirebaseMessagingService.onNewToken → POST /v1/device/fcm { fcm_token }
```

An iPhone pairs the same way with `platform: "ios"` and `apns` instead of
`fcm_token`, and refreshes its tokens with `POST /v1/device/push-tokens`
(see [Push (APNs)](#push-apns)).

`agentring pair` polls `GET /v1/devices` (or listens on WS) and prints
"Paired with Pixel 8 ✅".

### Message agent → user (M1)

```
agentring msg "hola" → POST /v1/messages {text}  (agent) → 201 {msg_id}
relay: store, event msg.new(from=agent) → WS (all) + FCM (devices)
app: verify sig → notification (MessagingStyle, inline reply)
```

### Reply user → agent (M1)

```
app (inline reply or thread) → POST /v1/messages {text, client_msg_id, reply_to?}  (device)
relay: event msg.new(from=user) → WS
daemon serve: store locally          agentring replies [--since]
(daemon not running: `agentring replies` falls back to GET /v1/messages?from=user)
```

### Outbound call (agent → user) (M2)

```
daemon: POST /v1/calls {reason, priority}  (agent)
  → 201 { call: {state: ringing,…}, join: {livekit_url, livekit_token, room} }
  daemon worker joins the room immediately
relay: create LiveKit room "call_<id>", event call.invite → WS + FCM, start 30 s timer
app: FCM → verify → ConnectionService.addNewIncomingCall → CallStyle + FSI
     → POST /v1/calls/{id}/ringing
user answers → POST /v1/calls/{id}/accept → 200 { call, join }  → app joins room
relay: state active, event call.accept
hang up (either side) → POST /v1/calls/{id}/end → state ended, event call.end
no answer in 30 s → state missed, event call.missed → daemon sends msg.new(reason) fallback (M4)
```

### Inbound call (user → agent) (M4)

```
app: POST /v1/calls {reason?}  (device)  → 201 { call, join }  → app joins & waits
  (503 agent_offline if no daemon WebSocket is connected)
relay: event call.invite(direction=user_to_agent) → WS
daemon: POST /v1/calls/{id}/accept → join → starts worker
```

App side ("Call agent" button, enabled while the relay WebSocket is connected
and the agent is online):

- The phone joins the LiveKit room right away with the `join` from the 201 and
  shows "Calling <agent>…". It switches to the in-call screen on the first of:
  `call.accept` on the WebSocket, the `agent` participant joining the room, or
  `GET /v1/calls/{id}` returning `active` (polled every 2 s, because events of
  calls to the agent are not pushed by FCM and the socket may be down).
- Hanging up while it rings → `POST /v1/calls/{id}/end` (relay: `canceled`).
- `call.decline` / state `declined` → "The agent declined the call";
  `call.missed` / state `missed` → "The agent didn't answer"; the call screen
  shows the message briefly and closes. As a last resort the app gives up
  after 75 s (ends the call itself).
- `503 agent_offline`, `503 calls_unavailable` and `409 busy` are shown under
  the button; no call screen opens.
- The phone ignores the `call.invite` of its own call (`direction:
  user_to_agent` never rings a phone).

### Call states

```
           accept                 end
ringing ───────────▶ active ───────────▶ ended
   │ decline ─▶ declined
   │ timeout ─▶ missed
   └ caller end ─▶ canceled
```

LiveKit `room_finished` webhook on an `active` call → `ended` with
`by: relay, reason: room_closed` (covers crashes and lost connectivity).

### Group calls (agent → user)

Every paired phone rings. Each may answer while the call rings (until
`expires_at`); they all join the same room and hear the agent and each other.
A phone declining or hanging up only affects itself. The call ends when the
agent hangs up, or when the last phone leaves (once nobody else can still
answer, i.e. after the ring window or when no phone is still ringing). It is
`declined` only if every phone declined, `missed` if nobody answered.

**Join the call.** While the call is `active`, any paired phone that is not on
it (its ring ended, it declined, it hung up, or it never got the invite) may join
at any time with `POST /v1/calls/{call_id}/join` → `{ call, join }` (same
`JoinInfo` as accept). While the call still rings, `join` is the same as
`accept`, so a client can always use it for "join". It emits `call.accept` with
the phone's `device_id`; a phone already on the call just gets a new token.
`409 call_ended` once the call is `ended`/`missed`/`declined`/`canceled`. An
empty call still ends (rule above), so "join" is only offered while someone is
on it.

How a phone learns it can join: the `call.accept` push (or WebSocket event) of
another phone, the response of its own `decline` / `end` (state still `active`),
its own ring timing out locally (it checks `GET /v1/calls/{call_id}`), and
`active_call` in `GET /v1/status` when the app comes to the foreground. It stops
offering it on `call.end` / `call.missed` or a `409 call_ended`.

### Targeted calls (agent → some phones)

The agent may ring only some phones, e.g. calling back just the person who asked
("call me when it's done") instead of waking everyone:

```
POST /v1/calls {"reason": "The report is ready", "device_ids": ["dev_…"]}
```

`device_ids` (agent only) lists paired, non-revoked phones (`GET /v1/devices`);
duplicates are ignored. Unknown or revoked ids, an empty list, or a phone sending
`device_ids` → `400 invalid_request`. Without it, every paired phone rings (group
call, above).

A targeted call is private to its phones. Only they get participant rows, the
`call.invite` (WebSocket and push) and every later event of the call, and only
they can answer, decline or join it; the group-call rules above apply among them.
Every other phone gets no event or push for it, so it never rings or offers
"join", even with an old app: the filtering is done by the relay. For those
phones the call does not exist: `GET /v1/calls/{call_id}` is `404`, it is left
out of `GET /v1/calls` and of `active_call` in `GET /v1/status`, `end` is `404`
too, and `accept` / `decline` / `join` are `403 forbidden` (`ringing` is ignored). It
still blocks new calls while it rings or is active (`409 busy`, one call at a
time). The `Call` object and the `call.invite` event carry `device_ids`.

A LiveKit `participant_left` for a phone's older session (e.g. kicked by its
own rejoin with the same identity) does not take it off the call: the relay
compares the session's join time with the phone's latest join.

### LiveKit

- Room `call_<call_id>`, `emptyTimeout` 30 s, created by the relay.
- Identities: `agent`, `device_<device_id>`.
- Token: one room, `canPublish`, `canSubscribe`, `canPublishData`, TTL 120 s
  (join window only; an established session is not affected).
- Live transcript: not implemented yet. The daemon keeps the transcript of AI calls
  (`agentring call --ai --json`, the MCP `call` tool); the app does not show it.

### Hosted relays (hub mode)

A hosted relay (docs/cloud.md) serves each tenant under a base URL with a path,
`https://host/t/{tenant_id}`; clients append `/v1/...` to it as usual. It may refuse
`POST /v1/pair`, `/v1/calls` and `/v1/messages` with `402 quota_exceeded` when the
plan's limit is reached, end an active call with `end_reason: "quota"` when the call
minutes run out, and answer `403 tenant_disabled` for a disabled account. A
self-hosted relay never does any of this.

## Daemon local HTTP API (M5, sketch)

Bound to `127.0.0.1:7878` by default, `Authorization: Bearer <local key>`.

| Method | Path | Body / query | Response |
|---|---|---|---|
| POST | `/call` | `{reason, priority?, wait?}` | `{call_id, status, summary?}` |
| POST | `/message` | `{text}` | `{msg_id}` |
| GET | `/replies` | `?since=<ms or msg_id>` | `{messages: [...]}` |
| GET | `/calls/{id}` | | `{call_id, status, duration_ms?, summary?, transcript?}` |

The MCP streamable-HTTP transport is mounted on the same server at `/mcp`.
