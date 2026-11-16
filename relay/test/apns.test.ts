import { generateKeyPairSync } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { decodeProtectedHeader, jwtVerify } from "jose";
import { afterEach, describe, expect, it, vi } from "vitest";
import { buildApp } from "../src/app.js";
import { buildPayload, iosPushOptions, signEvent } from "../src/push/dispatcher.js";
import { ApnsProvider } from "../src/push/apns.js";
import { apnsBody, apnsExpiration, apnsPushType } from "../src/push/push-provider.js";
import { apnsKey, startFakeApns } from "./apns-helpers.js";
import { AGENT, FakeLiveKit, FakePush, pairDevice, testConfig } from "./helpers.js";

const PROTOCOL = join(import.meta.dirname, "../../protocol");
const VOIP = "a".repeat(64);
const ALERT = "b".repeat(64);

let cleanup: Array<() => Promise<unknown>> = [];
afterEach(async () => {
  vi.useRealTimers();
  for (const c of cleanup.reverse()) await c();
  cleanup = [];
});

const flush = () => new Promise((r) => setImmediate(r));

async function fakeApns(respond?: Parameters<typeof startFakeApns>[0]) {
  const f = await startFakeApns(respond);
  cleanup.push(f.close);
  return f;
}

function provider(url: string, key = apnsKey()) {
  const p = new ApnsProvider({ key: key.pem, keyId: "KEYID12345", teamId: "TEAMID1234", topic: "dev.agentring.app", host: url });
  cleanup.push(() => p.close());
  return p;
}

const PAYLOAD = { v: "1", relay_id: "rly_x", event: "{}", sig: "s" };

describe("ApnsProvider", () => {
  it("sends voip / alert / background pushes with an ES256 provider token and the right headers", async () => {
    const apns = await fakeApns();
    const key = apnsKey();
    const p = provider(apns.url, key);
    const expiresAt = Date.now() + 30_000;

    expect(await p.send({ deviceId: "d", token: VOIP, environment: "sandbox" }, PAYLOAD, { kind: "call", ttlSeconds: 30, highPriority: true, expiresAt, aps: {} })).toEqual({ ok: true });
    expect(
      await p.send({ deviceId: "d", token: ALERT, topic: "com.example.mine" }, PAYLOAD, {
        kind: "message",
        ttlSeconds: 60,
        highPriority: true,
        collapseKey: "call_1",
        aps: { alert: { title: "A", body: "New message" }, "mutable-content": 1 },
      }),
    ).toEqual({ ok: true });
    expect(await p.send({ deviceId: "d", token: ALERT }, PAYLOAD, { kind: "update", ttlSeconds: 3600, highPriority: false })).toEqual({ ok: true });

    const [voip, alert, bg] = apns.received;
    // provider token: ES256, kid = key id, iss = team id, iat
    const jwt = String(voip!.headers.authorization).replace(/^bearer /, "");
    expect(decodeProtectedHeader(jwt)).toEqual({ alg: "ES256", kid: "KEYID12345" });
    const { payload: claims } = await jwtVerify(jwt, key.publicKey, { issuer: "TEAMID1234" });
    expect(claims.iat).toBeGreaterThan(0);
    // one token for all three (cached)
    expect(alert!.headers.authorization).toBe(voip!.headers.authorization);
    expect(bg!.headers.authorization).toBe(voip!.headers.authorization);

    expect(voip!.headers).toMatchObject({
      ":method": "POST",
      ":path": `/3/device/${VOIP}`,
      "apns-push-type": "voip",
      "apns-topic": "dev.agentring.app.voip",
      "apns-priority": "10",
      "apns-expiration": String(Math.ceil(expiresAt / 1000)),
    });
    expect(voip!.headers["apns-collapse-id"]).toBeUndefined();
    expect(JSON.parse(voip!.body)).toEqual({ aps: {}, agentring: PAYLOAD });

    expect(alert!.headers).toMatchObject({
      ":path": `/3/device/${ALERT}`,
      "apns-push-type": "alert",
      "apns-topic": "com.example.mine",
      "apns-priority": "10",
      "apns-collapse-id": "call_1",
    });
    expect(JSON.parse(alert!.body).aps).toEqual({ alert: { title: "A", body: "New message" }, "mutable-content": 1 });

    expect(bg!.headers).toMatchObject({ "apns-push-type": "background", "apns-topic": "dev.agentring.app", "apns-priority": "5" });
    expect(Number(bg!.headers["apns-expiration"])).toBeGreaterThan(Date.now() / 1000 + 3500);
    expect(JSON.parse(bg!.body).aps).toEqual({ "content-available": 1 });
  });

  it("reports dead tokens (410, BadDeviceToken, DeviceTokenNotForTopic) as unregistered, other errors not", async () => {
    const responses = [
      { status: 410, body: { reason: "Unregistered", timestamp: 1 } },
      { status: 400, body: { reason: "BadDeviceToken" } },
      { status: 400, body: { reason: "DeviceTokenNotForTopic" } },
      { status: 400, body: { reason: "PayloadEmpty" } },
      { status: 429, body: { reason: "TooManyRequests" } },
    ];
    const apns = await fakeApns((_r, n) => responses[n - 1]!);
    const p = provider(apns.url);
    const results = [];
    for (let i = 0; i < responses.length; i++) results.push(await p.send({ deviceId: "d", token: ALERT }, PAYLOAD, { kind: "message", ttlSeconds: 1, highPriority: true }));
    expect(results.map((r) => !r.ok && r.unregistered)).toEqual([true, true, true, false, false]);
    expect(results[0]).toMatchObject({ ok: false, error: expect.stringContaining("410 Unregistered") });
  });

  it("re-signs the provider token when APNs says it expired, and reconnects after the server drops the session", async () => {
    const apns = await fakeApns((_r, n) => (n === 1 ? { status: 403, body: { reason: "ExpiredProviderToken" } } : { status: 200 }));
    const p = provider(apns.url);
    vi.useFakeTimers({ toFake: ["Date"] });
    expect(await p.send({ deviceId: "d", token: ALERT }, PAYLOAD, { kind: "message", ttlSeconds: 1, highPriority: true })).toEqual({ ok: true });
    expect(apns.received).toHaveLength(2);
    // a new token (issued a second later, so it differs)
    expect(apns.received[1]!.headers.authorization).not.toBe(apns.received[0]!.headers.authorization);
    vi.useRealTimers();

    // the server closes every connection; the next push opens a new one
    for (const s of apns.sessions) s.destroy();
    await new Promise((r) => setTimeout(r, 20));
    expect(await p.send({ deviceId: "d", token: ALERT }, PAYLOAD, { kind: "message", ttlSeconds: 1, highPriority: true })).toEqual({ ok: true });
    expect(apns.received).toHaveLength(3);
  });

  it("refreshes the provider token after its lifetime", async () => {
    const apns = await fakeApns();
    const key = apnsKey();
    const p = new ApnsProvider({ key: key.privateKey, keyId: "KEYID12345", teamId: "TEAMID1234", topic: "t.app", host: apns.url, tokenTtlMs: 50 * 60_000 });
    cleanup.push(() => p.close());
    vi.useFakeTimers({ toFake: ["Date"] });
    await p.send({ deviceId: "d", token: ALERT }, PAYLOAD, { ttlSeconds: 1, highPriority: true });
    vi.setSystemTime(Date.now() + 49 * 60_000);
    await p.send({ deviceId: "d", token: ALERT }, PAYLOAD, { ttlSeconds: 1, highPriority: true });
    vi.setSystemTime(Date.now() + 2 * 60_000);
    await p.send({ deviceId: "d", token: ALERT }, PAYLOAD, { ttlSeconds: 1, highPriority: true });
    const auths = apns.received.map((r) => r.headers.authorization);
    expect(auths[1]).toBe(auths[0]);
    expect(auths[2]).not.toBe(auths[1]);
  });

  it("rejects oversized payloads without sending and a non-EC key at construction", async () => {
    const apns = await fakeApns();
    const p = provider(apns.url);
    const big = { ...PAYLOAD, event: "x".repeat(4100) };
    const r = await p.send({ deviceId: "d", token: ALERT }, big, { kind: "message", ttlSeconds: 1, highPriority: true });
    expect(r).toMatchObject({ ok: false, unregistered: false });
    // a VoIP push may be bigger (5120)
    expect(await p.send({ deviceId: "d", token: VOIP }, big, { kind: "call", ttlSeconds: 1, highPriority: true })).toEqual({ ok: true });
    expect(apns.received).toHaveLength(1);
    const rsa = generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey;
    expect(() => new ApnsProvider({ key: rsa, keyId: "K", teamId: "T", topic: "t" })).toThrow(/EC/);
  });
});

/** A relay with fake FCM + fake APNs (direct) providers, and optionally a fake gateway provider. */
async function relay(over: Parameters<typeof testConfig>[0] = {}, withGateway = false, withApns = true) {
  const fcm = new FakePush();
  const apns = new FakePush();
  const gw = new FakePush();
  const built = await buildApp(testConfig(over), {
    logger: false,
    pushProvider: fcm,
    ...(withApns ? { apnsProvider: apns } : {}),
    ...(withGateway ? { apnsGatewayProvider: gw } : {}),
    livekit: new FakeLiveKit(),
  });
  cleanup.push(() => built.app.close());
  return { ...built, fcm, apns, gw };
}

type Relay = Awaited<ReturnType<typeof relay>>;

async function pairIos(b: Relay, name = "iPhone", apns: object | null = { voip_token: VOIP, alert_token: ALERT, environment: "sandbox" }) {
  const { pairing_token } = (await b.app.inject({ method: "POST", url: "/v1/pairing-tokens", headers: AGENT })).json();
  const r = await b.app.inject({
    method: "POST",
    url: "/v1/pair",
    payload: { pairing_token, device_name: name, platform: "ios", app_version: "1.0", ...(apns ? { apns } : {}) },
  });
  if (r.statusCode !== 201) throw new Error(`pair failed: ${r.body}`);
  const body = r.json();
  return { ...body, headers: { authorization: `Bearer ${body.device_jwt}` } } as {
    device_id: string;
    push_secret: string;
    push_config: unknown;
    headers: { authorization: string };
  };
}

const typeOf = (s: { payload: Record<string, string> }) => JSON.parse(s.payload.event!).type as string;

describe("iOS pairing and push tokens", () => {
  it("pairs an iOS device, returns the APNs push_config, and reports platform and push tokens", async () => {
    const b = await relay();
    const ios = await pairIos(b);
    expect(ios.push_config).toEqual({ provider: "apns", apns: { topic: "dev.agentring.app", via_gateway: false } });
    const android = await pairDevice(b);
    expect((android as unknown as { push_config: unknown }).push_config).toMatchObject({ provider: "fcm" });

    const devs = (await b.app.inject({ url: "/v1/devices", headers: AGENT })).json().devices;
    expect(devs.map((d: { platform: string; has_push_token: boolean }) => [d.platform, d.has_push_token])).toEqual([
      ["ios", true],
      ["android", true],
    ]);
    const st = (await b.app.inject({ url: "/v1/status", headers: AGENT })).json();
    expect(st.push_providers).toEqual(["fcm", "apns"]);
    expect(st.push_provider).toBe("fake");

    // An iOS device with no tokens yet has no push token
    const bare = await pairIos(b, "iPad", null);
    expect((await b.app.inject({ url: "/v1/devices", headers: AGENT })).json().devices.at(-1)).toMatchObject({ device_id: bare.device_id, has_push_token: false });
  });

  it("push_config: gateway when only a gateway is configured, null without APNs", async () => {
    const gw = await relay({ apnsGateway: { url: "https://push.example", topic: "dev.agentring.app" } }, true, false);
    expect((await pairIos(gw)).push_config).toEqual({
      provider: "apns",
      apns: { topic: "dev.agentring.app", via_gateway: true, gateway_url: "https://push.example" },
    });
    expect((await gw.app.inject({ url: "/v1/status", headers: AGENT })).json().push_providers).toEqual(["fcm", "apns_gateway"]);
    const none = await relay({}, false, false);
    expect((await pairIos(none)).push_config).toBeNull();
    // Android is unaffected
    expect((await pairDevice(none)) as unknown).toMatchObject({ push_config: { provider: "fcm" } });
  });

  it("validates the platform/token combination and the APNs registration", async () => {
    const b = await relay();
    const pair = async (payload: object) => {
      const { pairing_token } = (await b.app.inject({ method: "POST", url: "/v1/pairing-tokens", headers: AGENT })).json();
      return b.app.inject({ method: "POST", url: "/v1/pair", payload: { pairing_token, device_name: "x", ...payload } });
    };
    expect((await pair({ platform: "ios", fcm_token: "f" })).statusCode).toBe(400);
    expect((await pair({ platform: "android", apns: { voip_token: VOIP, environment: "production" } })).statusCode).toBe(400);
    expect((await pair({ platform: "ios", apns: { voip_token: VOIP } })).json().error.message).toMatch(/environment/);
    expect((await pair({ platform: "ios", apns: { voip_token: "xyz", environment: "sandbox" } })).statusCode).toBe(400);
    expect((await pair({ platform: "ios", apns: { voip_token: VOIP, gateway_handle: "h", environment: "sandbox" } })).statusCode).toBe(400);
    expect((await pair({ platform: "ios", apns: { environment: "sandbox" } })).statusCode).toBe(400);
    expect((await pair({ platform: "ios", apns: { voip_token: VOIP, environment: "sandbox", topic: "bad topic\n" } })).statusCode).toBe(400);
    expect((await pair({ platform: "ios", apns: { gateway_handle: "AbC-_1" } })).statusCode).toBe(201);
  });

  it("POST /v1/device/push-tokens replaces the registration; Android may send fcm_token", async () => {
    const b = await relay();
    const ios = await pairIos(b);
    const android = await pairDevice(b);
    const post = (h: Record<string, string>, payload: object) => b.app.inject({ method: "POST", url: "/v1/device/push-tokens", headers: h, payload });
    const row = (id: string) => b.ctx.db.prepare("SELECT * FROM devices WHERE device_id = ?").get(id) as Record<string, unknown>;
    expect(row(ios.device_id)).toMatchObject({ apns_voip_token: VOIP, apns_alert_token: ALERT, apns_env: "sandbox", apns_topic: null, fcm_token: null });

    const voip2 = "C".repeat(64);
    expect((await post(ios.headers, { apns: { voip_token: voip2, environment: "production", topic: "dev.agentring.app" } })).statusCode).toBe(204);
    // tokens are stored lower-case; the alert token wasn't sent, so it's gone
    expect(row(ios.device_id)).toMatchObject({ apns_voip_token: "c".repeat(64), apns_alert_token: null, apns_env: "production", apns_topic: "dev.agentring.app" });
    expect((await post(ios.headers, { apns: { gateway_handle: "handle_1" } })).statusCode).toBe(204);
    expect(row(ios.device_id)).toMatchObject({ apns_voip_token: null, apns_gateway_handle: "handle_1" });

    expect((await post(ios.headers, { fcm_token: "f" })).statusCode).toBe(400);
    expect((await post(ios.headers, {})).statusCode).toBe(400);
    expect((await b.app.inject({ method: "POST", url: "/v1/device/fcm", headers: ios.headers, payload: { fcm_token: "f" } })).statusCode).toBe(400);
    expect((await post(android.headers, { apns: { voip_token: VOIP, environment: "sandbox" } })).statusCode).toBe(400);
    expect((await post(android.headers, { fcm_token: "fcm-2" })).statusCode).toBe(204);
    expect(row(android.device_id).fcm_token).toBe("fcm-2");
    expect((await post(AGENT, { fcm_token: "x" })).statusCode).toBe(403);

    // revoking clears the APNs registration too
    await b.app.inject({ method: "DELETE", url: `/v1/devices/${ios.device_id}`, headers: AGENT });
    expect(row(ios.device_id).apns_gateway_handle).toBeNull();
  });
});

describe("push dispatch per platform", () => {
  const place = (b: Relay, payload: object = { reason: "Deploy ready" }) =>
    b.app.inject({ method: "POST", url: "/v1/calls", headers: AGENT, payload });

  it("msg.new: FCM data to Android, an alert placeholder to iOS", async () => {
    const b = await relay();
    const ios = await pairIos(b);
    await pairDevice(b);
    await b.app.inject({ method: "POST", url: "/v1/messages", headers: AGENT, payload: { text: "secret text" } });
    await flush();
    expect(b.fcm.sent).toHaveLength(1);
    expect(b.apns.sent).toHaveLength(1);
    const s = b.apns.sent[0]!;
    expect(s.target).toEqual({ deviceId: ios.device_id, token: ALERT, environment: "sandbox" });
    expect(s.opts).toMatchObject({ kind: "message", ttlSeconds: 28 * 24 * 3600 });
    expect(s.opts.aps).toEqual({
      alert: { title: "TestAgent", body: "New message" },
      "mutable-content": 1,
      sound: "default",
      "thread-id": b.ctx.relayId,
      category: "AGENTRING_MESSAGE",
    });
    // the visible text never carries the message; the signed event does
    expect(JSON.stringify(s.opts.aps)).not.toContain("secret text");
    expect(s.payload.sig).toBe(signEvent(ios.push_secret, s.payload.event!));
    expect(Object.keys(s.payload).sort()).toEqual(["event", "relay_id", "sig", "v"]);
    // user messages are not pushed
    await b.app.inject({ method: "POST", url: "/v1/messages", headers: ios.headers, payload: { text: "hi" } });
    await flush();
    expect(b.apns.sent).toHaveLength(1);
  });

  it("mixed group call: VoIP invite to iOS, no VoIP push for call.end, missed-call alert (time-sensitive when urgent)", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    const b = await relay({ ringTimeoutS: 30 });
    const ios = await pairIos(b);
    const android = await pairDevice(b);

    // 1) agent hangs up while ringing: Android gets call.end, iOS nothing
    const c1 = (await place(b)).json().call;
    await flush();
    const invite = b.apns.sent.find((s) => typeOf(s) === "call.invite")!;
    expect(invite.target).toMatchObject({ deviceId: ios.device_id, token: VOIP, environment: "sandbox" });
    expect(invite.opts).toMatchObject({ kind: "call", highPriority: true, expiresAt: c1.created_at + 30_000, aps: {} });
    expect(apnsExpiration(invite.opts)).toBe(Math.ceil((c1.created_at + 30_000) / 1000));
    expect(b.fcm.sent.map(typeOf)).toEqual(["call.invite"]);
    await b.app.inject({ method: "POST", url: `/v1/calls/${c1.call_id}/end`, headers: AGENT });
    await flush();
    expect(b.fcm.sent.map(typeOf)).toEqual(["call.invite", "call.end"]);
    expect(b.apns.sent.map(typeOf)).toEqual(["call.invite"]);

    // 2) urgent call rings out: Android gets call.missed (data), iOS a time-sensitive alert
    b.fcm.sent = [];
    b.apns.sent = [];
    const c2 = (await place(b, { reason: "Prod down", priority: "urgent", agent_name: "Ops" })).json().call;
    vi.advanceTimersByTime(31_000);
    await flush();
    expect(b.fcm.sent.map(typeOf)).toEqual(["call.invite", "call.missed"]);
    const missed = b.apns.sent.find((s) => typeOf(s) === "call.missed")!;
    expect(missed.target.token).toBe(ALERT);
    expect(missed.opts).toMatchObject({ kind: "message", collapseKey: c2.call_id });
    expect(missed.opts.aps).toEqual({
      alert: { title: "Ops", body: "Missed call" },
      "mutable-content": 1,
      sound: "default",
      "thread-id": b.ctx.relayId,
      category: "AGENTRING_MISSED",
      "interruption-level": "time-sensitive",
    });

    // 3) normal call answered on Android: iOS gets a background "join" push, the answering phone nothing
    b.fcm.sent = [];
    b.apns.sent = [];
    vi.advanceTimersByTime(1000);
    const c3 = (await place(b)).json().call;
    await b.app.inject({ method: "POST", url: `/v1/calls/${c3.call_id}/accept`, headers: android.headers });
    await flush();
    const accept = b.apns.sent.find((s) => typeOf(s) === "call.accept")!;
    expect(accept.target.token).toBe(ALERT);
    expect(accept.opts).toMatchObject({ kind: "update", highPriority: false, ttlSeconds: 3600, aps: { "content-available": 1 } });
    expect(b.fcm.sent.filter((s) => typeOf(s) === "call.accept")).toHaveLength(0);
    // iOS hangs up last... the call ends; still no call.end push to iOS
    await b.app.inject({ method: "POST", url: `/v1/calls/${c3.call_id}/end`, headers: AGENT });
    vi.advanceTimersByTime(31_000);
    await flush();
    expect(b.apns.sent.map(typeOf)).toEqual(["call.invite", "call.accept"]);

    // 4) a normal missed call has no interruption level
    b.apns.sent = [];
    vi.advanceTimersByTime(1000);
    await place(b);
    vi.advanceTimersByTime(31_000);
    await flush();
    expect(b.apns.sent.find((s) => typeOf(s) === "call.missed")!.opts.aps).not.toHaveProperty("interruption-level");
  });

  it("targeted calls reach only their phones, whatever the platform", async () => {
    const b = await relay();
    const ios = await pairIos(b);
    const ios2 = await pairIos(b, "iPhone 2", { voip_token: "d".repeat(64), environment: "production" });
    await pairDevice(b);
    await place(b, { reason: "x", device_ids: [ios2.device_id] });
    await flush();
    expect(b.fcm.sent).toHaveLength(0);
    expect(b.apns.sent.map((s) => [s.target.deviceId, s.target.token, s.target.environment])).toEqual([[ios2.device_id, "d".repeat(64), "production"]]);
    expect(b.apns.sent.some((s) => s.target.deviceId === ios.device_id)).toBe(false);
  });

  it("skips pushes a device has no token for, and clears only the dead token", async () => {
    const b = await relay();
    const voipOnly = await pairIos(b, "voip only", { voip_token: VOIP, environment: "sandbox" });
    await b.app.inject({ method: "POST", url: "/v1/messages", headers: AGENT, payload: { text: "x" } });
    await flush();
    expect(b.apns.sent).toHaveLength(0);

    const full = await pairIos(b, "full");
    b.apns.next = { ok: false, unregistered: true, error: "410 Unregistered" };
    await b.app.inject({ method: "POST", url: "/v1/messages", headers: AGENT, payload: { text: "y" } });
    await flush();
    await new Promise((r) => setTimeout(r, 10));
    const row = b.ctx.db.prepare("SELECT apns_voip_token, apns_alert_token FROM devices WHERE device_id = ?").get(full.device_id);
    expect(row).toEqual({ apns_voip_token: VOIP, apns_alert_token: null });
    expect((b.ctx.db.prepare("SELECT apns_voip_token FROM devices WHERE device_id = ?").get(voipOnly.device_id) as { apns_voip_token: string }).apns_voip_token).toBe(VOIP);
  });

  it("a device with a gateway handle goes through the gateway provider; 410 drops the handle", async () => {
    const b = await relay({}, true);
    const gwDev = await pairIos(b, "App Store build", { gateway_handle: "opaque-handle" });
    await place(b);
    await flush();
    expect(b.apns.sent).toHaveLength(0);
    expect(b.gw.sent).toHaveLength(1);
    expect(b.gw.sent[0]!.target).toEqual({ deviceId: gwDev.device_id, token: "opaque-handle" });
    expect(b.gw.sent[0]!.opts.kind).toBe("call");
    b.gw.next = { ok: false, unregistered: true, error: "410" };
    await b.app.inject({ method: "POST", url: "/v1/messages", headers: AGENT, payload: { text: "y" } });
    await flush();
    await new Promise((r) => setTimeout(r, 10));
    const row = b.ctx.db.prepare("SELECT apns_gateway_handle FROM devices WHERE device_id = ?").get(gwDev.device_id);
    expect(row).toEqual({ apns_gateway_handle: null });
  });
});

describe("APNs fixtures", () => {
  const vector = JSON.parse(readFileSync(join(PROTOCOL, "examples/push/signature-vector.json"), "utf8"));
  const files = readdirSync(join(PROTOCOL, "examples/push")).filter((f) => f.startsWith("apns-"));

  it("exist for voip and alert pushes", () => {
    expect(files).toEqual(expect.arrayContaining(["apns-voip.json", "apns-alert.json"]));
  });

  it("are signed with the vector's secret and match what the relay builds", () => {
    const invite = JSON.parse(readFileSync(join(PROTOCOL, "examples/events/call.invite.json"), "utf8"));
    for (const f of files) {
      const fx = JSON.parse(readFileSync(join(PROTOCOL, "examples/push", f), "utf8"));
      expect(fx.push_secret).toBe(vector.push_secret);
      const { agentring } = fx.payload;
      expect(signEvent(fx.push_secret, agentring.event)).toBe(agentring.sig);
      const event = JSON.parse(agentring.event);
      expect(buildPayload(agentring.relay_id, fx.push_secret, event)).toEqual(agentring);
      const opts = iosPushOptions(event, () => ({ direction: "agent_to_user", priority: invite.priority, agent_name: invite.agent_name }), agentring.relay_id, "Claude")!;
      expect(apnsBody(agentring, opts)).toEqual(fx.payload);
      const type = apnsPushType(opts);
      expect(fx.headers["apns-push-type"]).toBe(type);
      expect(fx.headers["apns-topic"]).toBe(type === "voip" ? "dev.agentring.app.voip" : "dev.agentring.app");
      expect(fx.headers["apns-expiration"]).toBe(String(apnsExpiration(opts, event.ts)));
      expect(Buffer.byteLength(JSON.stringify(fx.payload))).toBeLessThanOrEqual(type === "voip" ? 5120 : 4096);
    }
  });
});
