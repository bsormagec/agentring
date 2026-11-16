# iOS push (APNs)

How the relay wakes an iPhone: Apple Push Notification service (APNs). The design and
the reasons behind it are in [ios.md](ios.md); the wire format (which event becomes
which push, payloads, headers) is in [protocol.md](protocol.md#push-apns).

Android needs nothing from this page (it uses FCM, see [firebase.md](firebase.md)).

## Which setup do I need?

APNs only delivers to an app signed by the Apple developer team that owns the key. So
who sends the push depends on which iOS app is on the phone:

| Relay | iOS app | What to configure |
|---|---|---|
| agentring cloud (hub mode) | App Store app | Nothing: the publisher's key is already on the hub. |
| Self-hosted | Your own build (Xcode / TestFlight, your team) | Your own APNs key: [steps 1–3](#1-app-id-with-push-notifications). |
| Self-hosted | App Store app | The publisher's push gateway: [`AGENTRING_APNS_GATEWAY_URL`](#using-a-push-gateway). |

Without any of them the iPhone still pairs and gets messages and calls, but **only
while the app is open**. The pair response says so (`push_config: null`), and the app
tells the user.

## 1. App ID with Push Notifications

You need a paid Apple Developer Program membership.

1. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list)
   → **Identifiers** → **+** → **App IDs** → **App**.
2. Bundle ID (explicit): `dev.agentring.app`, or your own if you build the app under
   another id (then set `AGENTRING_APNS_TOPIC` to it, below).
3. Under **Capabilities**, check **Push Notifications** (and **Time Sensitive
   Notifications**). Save.

VoIP pushes (PushKit) need no separate identifier or certificate with token
authentication: the relay sends them to the topic `<bundle id>.voip` with the same key.

## 2. Create the APNs key (.p8)

1. **Keys** → **+**. Name it (e.g. `agentring relay`) and check **Apple Push
   Notifications service (APNs)**. If the portal asks for an environment, pick
   **Sandbox & Production**; if it asks for a scope, **Team Scoped (All Topics)** or a
   key limited to your bundle id.
2. **Register**, then **Download**. You get `AuthKey_<KEY ID>.p8`. Apple lets you
   download it **once**: keep a copy offline, like a release keystore.
3. Note two 10-character ids:
   - the **Key ID** (in the file name and on the key's page),
   - your **Team ID** (top right of the developer portal, or **Membership details**).

One key works for every app of your team and for both environments, and it doesn't
expire. Revoke it in the portal if it leaks.

## 3. Give the key to the relay

With the docker compose deployment:

```bash
cd deploy
cp ~/Downloads/AuthKey_ABC123DEFG.p8 secrets/
chmod 600 secrets/AuthKey_ABC123DEFG.p8
```

In `deploy/.env`:

```bash
AGENTRING_APNS_KEY_FILE=/secrets/AuthKey_ABC123DEFG.p8
AGENTRING_APNS_KEY_ID=ABC123DEFG
AGENTRING_APNS_TEAM_ID=TEAM123456
#AGENTRING_APNS_TOPIC=dev.agentring.app   # only if your bundle id differs
```

Restart: `docker compose up -d`. The relay log shows `"push_providers":["fcm","apns"]`
(or just `apns`), and `agentring status` shows `Push: fcm, apns`.

| Variable | Meaning |
|---|---|
| `AGENTRING_APNS_KEY_FILE` | Path to the `.p8` file (inside the container). |
| `AGENTRING_APNS_KEY` | The key's PEM text instead of a file (newlines may be written as `\n`). Use one of the two. |
| `AGENTRING_APNS_KEY_ID` | The 10-character Key ID. |
| `AGENTRING_APNS_TEAM_ID` | The 10-character Team ID. |
| `AGENTRING_APNS_TOPIC` | The iOS app's bundle id. Default `dev.agentring.app`. |
| `AGENTRING_APNS_GATEWAY_URL` | Push through a gateway instead (below). |
| `AGENTRING_APNS_HOST` | **Tests only.** One origin for both APNs environments; `http://` (HTTP/2 without TLS) needs `AGENTRING_INSECURE_DEV=1`. |

The relay checks at start that the key is an EC P-256 PKCS#8 key and that both ids
have 10 characters, and refuses to start otherwise.

Running the relay without docker? Set the same variables. Hub mode (agentring cloud)
uses the same variables: one key for every tenant, like the shared FCM project.

### Sandbox vs production

APNs has two hosts, and a device token belongs to one of them:

| Build | Environment | Host |
|---|---|---|
| Debug build run from Xcode | `sandbox` | `api.sandbox.push.apple.com` |
| TestFlight, App Store, Ad Hoc | `production` | `api.push.apple.com` |

The app sends its environment with its tokens (`apns.environment` in `POST /v1/pair`
or `POST /v1/device/push-tokens`), and the relay picks the host **per device**, so one
relay serves a debug iPhone and a TestFlight iPhone at the same time.

### How the relay talks to APNs

- HTTP/2 (`node:http2`), one long-lived connection per host, reopened when Apple
  closes it.
- Token authentication: an ES256 JWT (`kid` = Key ID, `iss` = Team ID, `iat`), signed
  with the `.p8` key and re-signed every 50 minutes (Apple wants 20–60).
- A push that APNs answers with `410`, or `400` `BadDeviceToken` /
  `Unregistered` / `DeviceTokenNotForTopic`, clears that token on the device (like an
  `UNREGISTERED` FCM token). The app sends fresh tokens on its next start.

### Troubleshooting

`agentring devices` shows each phone's platform; `agentring status` shows whether it
has a push token. The relay logs every failed push with APNs' reason:

| Reason | Usually means |
|---|---|
| `InvalidProviderToken` | Wrong Key ID or Team ID, or the key was revoked. |
| `BadDeviceToken` | A sandbox token sent to production or the other way round (the app reported the wrong `environment`). The token is cleared. |
| `DeviceTokenNotForTopic` / `TopicDisallowed` | The app's bundle id is not `AGENTRING_APNS_TOPIC`, or the key belongs to another team. |
| `TooManyProviderTokenUpdates` | Several relays (or restarts in a loop) signing new provider tokens with one key. |
| `ExpiredProviderToken` | The server clock is off; the relay re-signs and retries once. |

## Using a push gateway

The App Store app can only be reached with its publisher's key. A self-hosted relay
reaches it through the publisher's **push gateway**
([protocol/push-gateway.openapi.yaml](../protocol/push-gateway.openapi.yaml)):

1. The app registers its APNs tokens with the gateway and gets an opaque **handle**
   (the tokens encrypted with the gateway's key).
2. It gives the handle to your relay (`apns.gateway_handle`); your relay never sees
   the tokens.
3. Your relay sends each push to the gateway, which sends it to APNs.

On your relay, set only:

```bash
AGENTRING_APNS_GATEWAY_URL=https://push.agentring.io   # the publisher's gateway
```

The pair response then tells the app `{"provider":"apns","apns":{"topic":…,"via_gateway":true,"gateway_url":…}}`.
The payload is the same signed `agentring` object as always: the app verifies `sig`
with the secret only it and your relay know, so the gateway can't forge events. It can
read them, as Apple and Google can (payloads are signed, not encrypted).

### Running a gateway (app publishers)

The gateway is the relay in another mode. It needs the publisher's APNs key and
nothing else (no database, no LiveKit, no Firebase):

```bash
AGENTRING_PUSH_GATEWAY=1
AGENTRING_APNS_KEY_FILE=/secrets/AuthKey_ABC123DEFG.p8
AGENTRING_APNS_KEY_ID=ABC123DEFG
AGENTRING_APNS_TEAM_ID=TEAM123456
AGENTRING_APNS_TOPIC=dev.agentring.app
AGENTRING_DATA_DIR=/data            # where gateway_key is generated on first start
#AGENTRING_GATEWAY_KEY=...          # or give the 32-byte key (openssl rand -base64 32)
AGENTRING_TRUSTED_PROXIES=1         # reverse proxies in front (per-IP limits use the client address)
```

```bash
docker run -d --name agentring-push -p 127.0.0.1:8080:8080 \
  -e AGENTRING_PUSH_GATEWAY=1 -e AGENTRING_APNS_KEY_FILE=/secrets/AuthKey_ABC123DEFG.p8 \
  -e AGENTRING_APNS_KEY_ID=ABC123DEFG -e AGENTRING_APNS_TEAM_ID=TEAM123456 \
  -v "$PWD/secrets:/secrets:ro" -v agentring-push:/data \
  ghcr.io/mutonby/agentring-relay:<version>
```

Put it behind an HTTPS reverse proxy (Caddy, Traefik). It serves only:

| Endpoint | |
|---|---|
| `POST /v1/register` | Called by the app: `{voip_token?, alert_token?, environment, topic}` → `{handle}`. A topic other than `AGENTRING_APNS_TOPIC` is refused. |
| `POST /v1/send` | Called by relays: `{handle, push_type, payload, expiration, collapse_id?}` → `{ok:true}`, `410` when APNs dropped the token (the relay then drops the handle), `429` when rate-limited, `502` on other APNs errors. |
| `GET /healthz` | |

- **Handles** are AES-256-GCM of the tokens, environment and topic. The gateway
  stores nothing per device. Keep `gateway_key` (in the data dir, mode 0600) like any
  secret: losing or changing it invalidates every handle, and the apps register again
  on their next start (a relay treats a handle the gateway can't open as dead).
- **Rate limits** (in memory, per gateway process): per device token 30 VoIP, 300
  alert and 120 background pushes per hour; per source IP 2000 sends and 60
  registrations per hour.
- Only the relay's signed `PushData` passes through: `payload` must be
  `{aps, agentring:{v, relay_id, event, sig}}`, anything else in it is dropped.
