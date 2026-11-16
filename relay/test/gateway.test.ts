import { mkdtempSync, readFileSync, statSync } from "node:fs";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { Config } from "../src/config.js";
import { buildGateway, resolveGatewayKey } from "../src/gateway/gateway.js";
import { ApnsGatewayProvider } from "../src/push/apns-gateway.js";
import { ApnsProvider } from "../src/push/apns.js";
import { apnsKey, startFakeApns } from "./apns-helpers.js";
import { FakePush, testConfig } from "./helpers.js";

const VOIP = "a".repeat(64);
const ALERT = "b".repeat(64);
const PAYLOAD = { aps: {}, agentring: { v: "1", relay_id: "rly_x", event: "{}", sig: "s" } };

let cleanup: Array<() => Promise<unknown>> = [];
afterEach(async () => {
  for (const c of cleanup.reverse()) await c();
  cleanup = [];
});

function gwConfig(over: Partial<Config> = {}): Config {
  return testConfig({
    apns: { key: apnsKey().pem, keyId: "KEYID12345", teamId: "TEAMID1234", topic: "dev.agentring.app" },
    pushGateway: {},
    ...over,
  });
}

async function gateway(opts: Parameters<typeof buildGateway>[1] = {}, cfg = gwConfig()) {
  const provider = new FakePush();
  const built = await buildGateway(cfg, { logger: false, provider, ...opts });
  cleanup.push(() => built.app.close());
  return { ...built, provider };
}

async function register(app: Awaited<ReturnType<typeof gateway>>["app"], body: object = {}) {
  return app.inject({
    method: "POST",
    url: "/v1/register",
    payload: { voip_token: VOIP, alert_token: ALERT, environment: "sandbox", topic: "dev.agentring.app", ...body },
  });
}

describe("push gateway", () => {
  it("registers tokens into an opaque handle and sends with it", async () => {
    const g = await gateway();
    expect((await g.app.inject({ url: "/healthz" })).json()).toEqual({ ok: true });
    const r = await register(g.app);
    expect(r.statusCode).toBe(200);
    const { handle } = r.json();
    expect(handle).toMatch(/^[A-Za-z0-9_-]+$/);
    // opaque: the tokens aren't readable in it, and every registration gives a new handle
    expect(Buffer.from(handle, "base64url").toString("latin1")).not.toContain("aaaa");
    expect((await register(g.app)).json().handle).not.toBe(handle);
    expect(g.codec.open(handle)).toEqual({ voip_token: VOIP, alert_token: ALERT, environment: "sandbox", topic: "dev.agentring.app" });

    const send = (push_type: string, extra: object = {}) =>
      g.app.inject({ method: "POST", url: "/v1/send", payload: { handle, push_type, payload: PAYLOAD, expiration: 1761200030, ...extra } });
    expect((await send("voip")).json()).toEqual({ ok: true });
    expect((await send("alert", { collapse_id: "call_1", payload: { ...PAYLOAD, aps: { alert: { title: "A", body: "B" } } } })).statusCode).toBe(200);
    expect((await send("background", { expiration: 0 })).statusCode).toBe(200);

    const [voip, alert, bg] = g.provider.sent;
    expect(voip!.target).toMatchObject({ token: VOIP, environment: "sandbox", topic: "dev.agentring.app" });
    expect(voip!.opts).toMatchObject({ kind: "call", expiresAt: 1761200030_000, aps: {} });
    expect(voip!.payload).toEqual(PAYLOAD.agentring);
    expect(alert!.target.token).toBe(ALERT);
    // The gateway rebuilds `aps`: a handle holder can't choose the text the phone shows.
    expect(alert!.opts).toMatchObject({
      kind: "message",
      collapseKey: "call_1",
      aps: { alert: { title: "agentring", body: "New message" }, category: "AGENTRING_MESSAGE", "mutable-content": 1 },
    });
    expect(bg!.target.token).toBe(ALERT);
    expect(bg!.opts).toMatchObject({ kind: "update", expiresAt: 0, highPriority: false });
  });

  it("rejects another app's topic, missing tokens, bad or tampered handles and arbitrary payloads", async () => {
    const g = await gateway();
    const wrong = await register(g.app, { topic: "com.evil.app" });
    expect(wrong.statusCode).toBe(400);
    expect(wrong.json().error.message).toMatch(/dev\.agentring\.app/);
    expect((await register(g.app, { voip_token: undefined, alert_token: undefined })).statusCode).toBe(400);
    expect((await register(g.app, { voip_token: "nothex" })).statusCode).toBe(400);

    const { handle } = (await register(g.app, { alert_token: undefined })).json();
    const send = (payload: object) => g.app.inject({ method: "POST", url: "/v1/send", payload });
    const ok = { handle, push_type: "voip", payload: PAYLOAD, expiration: 0 };

    const bad = await send({ ...ok, handle: "not-a-handle" });
    expect(bad.statusCode).toBe(400);
    expect(bad.json().error.code).toBe("invalid_handle");
    const raw = Buffer.from(handle, "base64url");
    raw[raw.length - 20]! ^= 1;
    expect((await send({ ...ok, handle: raw.toString("base64url") })).json().error.code).toBe("invalid_handle");
    // a handle from a gateway with another key
    const other = await gateway();
    const foreign = (await register(other.app)).json().handle;
    expect((await send({ ...ok, handle: foreign })).json().error.code).toBe("invalid_handle");

    // no alert token in this handle
    expect((await send({ ...ok, push_type: "alert" })).statusCode).toBe(400);
    expect((await send({ ...ok, payload: { aps: {} } })).statusCode).toBe(400);
    const big = { aps: {}, agentring: { ...PAYLOAD.agentring, event: "x".repeat(5200) } };
    expect((await send({ ...ok, payload: big })).statusCode).toBe(400);
    expect(g.provider.sent).toHaveLength(0);
    // only the relay's signed PushData passes through: anything else is stripped
    const extra = { aps: {}, agentring: { ...PAYLOAD.agentring, extra: "x" }, other: 1 };
    expect((await send({ ...ok, payload: extra })).statusCode).toBe(200);
    expect(g.provider.sent[0]!.payload).toEqual(PAYLOAD.agentring);
  });

  it("rate-limits per device token and push type, and per source IP", async () => {
    const g = await gateway({ limits: { voipPerHour: 2, alertPerHour: 3, sendPerIpPerHour: 8, registerPerIpPerHour: 4 } });
    const { handle } = (await register(g.app)).json();
    const send = (push_type: string, h = handle) =>
      g.app.inject({ method: "POST", url: "/v1/send", payload: { handle: h, push_type, payload: PAYLOAD, expiration: 0 } });
    expect((await send("voip")).statusCode).toBe(200);
    expect((await send("voip")).statusCode).toBe(200);
    const limited = await send("voip");
    expect(limited.statusCode).toBe(429);
    expect(limited.json().error.code).toBe("rate_limited");
    // a fresh handle for the same tokens doesn't reset the limit
    const again = (await register(g.app)).json().handle;
    expect((await send("voip", again)).statusCode).toBe(429);
    // alerts have their own budget
    for (let i = 0; i < 3; i++) expect((await send("alert")).statusCode).toBe(200);
    expect((await send("alert")).statusCode).toBe(429);
    // the IP budget (8 sends) is used up now
    expect((await send("background")).statusCode).toBe(429);
    expect(g.provider.sent).toHaveLength(5);
    // registrations per IP
    await register(g.app);
    await register(g.app);
    expect((await register(g.app)).statusCode).toBe(429);
  });

  it("passes APNs' 410 through and reports other failures as 502", async () => {
    const g = await gateway();
    const { handle } = (await register(g.app)).json();
    const send = () => g.app.inject({ method: "POST", url: "/v1/send", payload: { handle, push_type: "voip", payload: PAYLOAD, expiration: 0 } });
    g.provider.next = { ok: false, unregistered: true, error: "410 Unregistered" };
    const gone = await send();
    expect(gone.statusCode).toBe(410);
    expect(gone.json().error.code).toBe("unregistered");
    g.provider.next = { ok: false, unregistered: false, error: "500 InternalServerError" };
    const fail = await send();
    expect(fail.statusCode).toBe(502);
    expect(fail.json().error.code).toBe("apns_error");
  });

  it("keeps its key in the data dir (0600) or takes it from AGENTRING_GATEWAY_KEY", () => {
    const dir = mkdtempSync(join(tmpdir(), "gw-"));
    const k1 = resolveGatewayKey(gwConfig({ dataDir: dir }));
    expect(k1).toHaveLength(32);
    expect(statSync(join(dir, "gateway_key")).mode & 0o777).toBe(0o600);
    expect(resolveGatewayKey(gwConfig({ dataDir: dir }))).toEqual(k1);
    expect(readFileSync(join(dir, "gateway_key"), "utf8").trim()).toBe(k1.toString("base64url"));
    const fixed = Buffer.alloc(32, 7);
    expect(resolveGatewayKey(gwConfig({ pushGateway: { key: fixed.toString("base64") } }))).toEqual(fixed);
    expect(resolveGatewayKey(gwConfig({ pushGateway: { key: fixed.toString("hex") } }))).toEqual(fixed);
    expect(() => resolveGatewayKey(gwConfig({ pushGateway: { key: "short" } }))).toThrow(/32 bytes/);
  });

  it("end to end: relay-side ApnsGatewayProvider → gateway → (fake) APNs over HTTP/2", async () => {
    const apns = await startFakeApns((r) => (String(r.headers[":path"]).endsWith("dead".repeat(16)) ? { status: 410, body: { reason: "Unregistered" } } : { status: 200 }));
    cleanup.push(apns.close);
    const key = apnsKey();
    const direct = new ApnsProvider({ key: key.pem, keyId: "KEYID12345", teamId: "TEAMID1234", topic: "dev.agentring.app", host: apns.url });
    cleanup.push(() => direct.close());
    const g = await gateway({ provider: direct });
    await g.app.listen({ host: "127.0.0.1", port: 0 });
    const url = `http://127.0.0.1:${(g.app.server.address() as AddressInfo).port}`;
    const { handle } = (await register(g.app, { environment: "production" })).json();
    const relaySide = new ApnsGatewayProvider(url, "dev.agentring.app");
    const expiresAt = Date.now() + 30_000;

    const res = await relaySide.send({ deviceId: "dev_1", token: handle }, PAYLOAD.agentring, {
      kind: "call",
      ttlSeconds: 30,
      highPriority: true,
      expiresAt,
      aps: {},
    });
    expect(res).toEqual({ ok: true });
    expect(apns.received).toHaveLength(1);
    expect(apns.received[0]!.headers).toMatchObject({
      ":path": `/3/device/${VOIP}`,
      "apns-push-type": "voip",
      "apns-topic": "dev.agentring.app.voip",
      "apns-priority": "10",
      "apns-expiration": String(Math.ceil(expiresAt / 1000)),
    });
    expect(JSON.parse(apns.received[0]!.body)).toEqual({ aps: {}, agentring: PAYLOAD.agentring });

    const alert = await relaySide.send({ deviceId: "dev_1", token: handle }, PAYLOAD.agentring, {
      kind: "message",
      ttlSeconds: 60,
      highPriority: true,
      collapseKey: "call_9",
      aps: { alert: { title: "T", body: "Missed call" } },
    });
    expect(alert).toEqual({ ok: true });
    expect(apns.received[1]!.headers).toMatchObject({ "apns-push-type": "alert", "apns-topic": "dev.agentring.app", "apns-collapse-id": "call_9" });

    // APNs 410 → gateway 410 → unregistered on the relay side
    const dead = (await register(g.app, { voip_token: "dead".repeat(16) })).json().handle;
    const gone = await relaySide.send({ deviceId: "dev_1", token: dead }, PAYLOAD.agentring, { kind: "call", ttlSeconds: 30, highPriority: true });
    expect(gone).toMatchObject({ ok: false, unregistered: true });
    // a handle the gateway can't open is dead too
    expect(await relaySide.send({ deviceId: "dev_1", token: "garbage" }, PAYLOAD.agentring, { kind: "call", ttlSeconds: 30, highPriority: true })).toMatchObject({
      ok: false,
      unregistered: true,
    });
    // an unreachable gateway is a plain failure
    const down = new ApnsGatewayProvider("http://127.0.0.1:1", "dev.agentring.app");
    expect(await down.send({ deviceId: "d", token: handle }, PAYLOAD.agentring, { kind: "call", ttlSeconds: 1, highPriority: true })).toMatchObject({
      ok: false,
      unregistered: false,
    });
  });
});

describe("safeAps", () => {
  it("keeps only allowlisted fields and fixed text", async () => {
    const { safeAps } = await import("../src/gateway/gateway.js");
    expect(safeAps("voip", { alert: "x" })).toEqual({});
    expect(safeAps("background", { alert: "x" })).toEqual({ "content-available": 1 });
    expect(
      safeAps("alert", {
        alert: { title: "Your bank", body: "Click here" },
        category: "AGENTRING_MISSED",
        "thread-id": "rly_01JB",
        "interruption-level": "critical",
        sound: "evil.caf",
      }),
    ).toEqual({
      alert: { title: "agentring", body: "Missed call" },
      category: "AGENTRING_MISSED",
      "mutable-content": 1,
      sound: "default",
      "thread-id": "rly_01JB",
    });
    expect(safeAps("alert", { category: "OTHER", "interruption-level": "time-sensitive" })).toMatchObject({
      category: "AGENTRING_MESSAGE",
      "interruption-level": "time-sensitive",
    });
  });
});
