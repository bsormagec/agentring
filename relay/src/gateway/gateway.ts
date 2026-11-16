/**
 * Push gateway mode (`AGENTRING_PUSH_GATEWAY=1`, protocol/push-gateway.openapi.yaml):
 * lets self-hosted relays push to the App Store build of the iOS app, whose APNs key
 * only its publisher holds. The publisher runs this; it serves only `/v1/register`,
 * `/v1/send` and `/healthz`, and stores nothing per device (handles are the APNs
 * tokens encrypted with the gateway's key).
 */
import { randomBytes } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import Fastify, { type FastifyInstance, type FastifyServerOptions } from "fastify";
import { type Config, trustedHops } from "../config.js";
import { ApnsProvider } from "../push/apns.js";
import { APNS_MAX_BYTES, type ApnsPushType, type PushKind, type PushProvider } from "../push/push-provider.js";
import { HandleCodec } from "./handles.js";
import { RateLimiter } from "./rate-limit.js";

export interface GatewayLimits {
  /** Pushes per device token per hour, by push type. VoIP pushes are the scarce ones. */
  voipPerHour: number;
  alertPerHour: number;
  backgroundPerHour: number;
  /** `/v1/send` calls per source IP per hour (one self-hosted relay = one IP, a few phones). */
  sendPerIpPerHour: number;
  /** `/v1/register` calls per source IP per hour. */
  registerPerIpPerHour: number;
}

export const DEFAULT_GATEWAY_LIMITS: GatewayLimits = {
  voipPerHour: 30,
  alertPerHour: 300,
  backgroundPerHour: 120,
  sendPerIpPerHour: 2000,
  registerPerIpPerHour: 60,
};

export interface GatewayOptions {
  logger?: FastifyServerOptions["logger"];
  /** Inject the APNs provider (tests). Defaults to `ApnsProvider` with the configured key. */
  provider?: PushProvider;
  limits?: Partial<GatewayLimits>;
}

const HEX_TOKEN = { type: "string", pattern: "^[0-9a-fA-F]{16,200}$" } as const;
const KIND: Record<ApnsPushType, PushKind> = { voip: "call", alert: "message", background: "update" };
const HOUR_MS = 3600_000;

class GatewayError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

/**
 * The gateway's AES-256 key: AGENTRING_GATEWAY_KEY (32 bytes, base64/base64url or hex),
 * or generated on first start into DATA_DIR/gateway_key (mode 0600), like the relay's
 * API key. Changing it invalidates every handle (apps re-register on their next start).
 */
export function resolveGatewayKey(cfg: Config): Buffer {
  const fromEnv = cfg.pushGateway?.key;
  const parse = (s: string): Buffer => {
    const t = s.trim();
    const b = /^[0-9a-fA-F]{64}$/.test(t) ? Buffer.from(t, "hex") : Buffer.from(t, "base64url");
    if (b.length !== 32) throw new Error("AGENTRING_GATEWAY_KEY must be 32 bytes (openssl rand -base64 32)");
    return b;
  };
  if (fromEnv) return parse(fromEnv);
  if (cfg.dataDir === ":memory:") return randomBytes(32);
  const file = join(cfg.dataDir, "gateway_key");
  if (existsSync(file)) return parse(readFileSync(file, "utf8"));
  const key = randomBytes(32);
  mkdirSync(cfg.dataDir, { recursive: true });
  writeFileSync(file, key.toString("base64url") + "\n", { mode: 0o600 });
  chmodSync(file, 0o600);
  return key;
}

interface SendBody {
  handle: string;
  push_type: ApnsPushType;
  payload: { aps: Record<string, unknown>; agentring: Record<string, string> };
  expiration: number;
  collapse_id?: string;
}

interface RegisterBody {
  voip_token?: string;
  alert_token?: string;
  environment: "sandbox" | "production";
  topic: string;
}

export async function buildGateway(cfg: Config, opts: GatewayOptions = {}): Promise<{ app: FastifyInstance; codec: HandleCodec }> {
  if (!cfg.apns && !opts.provider) throw new Error("The push gateway needs the APNs key settings");
  const topic = cfg.apns?.topic ?? "dev.agentring.app";
  const limits = { ...DEFAULT_GATEWAY_LIMITS, ...opts.limits };
  const owned = opts.provider ? undefined : new ApnsProvider(cfg.apns!);
  const provider = opts.provider ?? owned!;
  const codec = new HandleCodec(resolveGatewayKey(cfg));
  const perToken = new RateLimiter(HOUR_MS);
  const perIp = new RateLimiter(HOUR_MS);

  const app = Fastify({ logger: opts.logger ?? true, trustProxy: trustedHops(cfg), bodyLimit: 16 * 1024 });
  app.setErrorHandler((err, req, reply) => {
    if (err instanceof GatewayError) return reply.code(err.status).send({ error: { code: err.code, message: err.message } });
    const e = err as { validation?: unknown; statusCode?: number; message: string };
    if (e.validation || (e.statusCode && e.statusCode < 500)) {
      return reply.code(e.statusCode && e.statusCode !== 500 ? e.statusCode : 400).send({ error: { code: "invalid_request", message: e.message } });
    }
    req.log.error({ err }, "unhandled error");
    return reply.code(500).send({ error: { code: "internal", message: "Internal error" } });
  });
  app.setNotFoundHandler((req, reply) =>
    reply.code(404).send({ error: { code: "not_found", message: `${req.method} ${req.url} not found` } }),
  );

  app.get("/healthz", async () => ({ ok: true }));

  app.post<{ Body: RegisterBody }>(
    "/v1/register",
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["environment", "topic"],
          properties: {
            voip_token: HEX_TOKEN,
            alert_token: HEX_TOKEN,
            environment: { type: "string", enum: ["sandbox", "production"] },
            topic: { type: "string", maxLength: 200 },
          },
        },
      },
    },
    async (req) => {
      if (!perIp.take(`register:${req.ip}`, limits.registerPerIpPerHour)) {
        throw new GatewayError(429, "rate_limited", "Too many registrations from this address");
      }
      const b = req.body;
      if (b.topic !== topic) throw new GatewayError(400, "invalid_request", `This gateway only pushes to ${topic}`);
      if (!b.voip_token && !b.alert_token) throw new GatewayError(400, "invalid_request", "voip_token or alert_token is required");
      const handle = codec.seal({
        ...(b.voip_token ? { voip_token: b.voip_token.toLowerCase() } : {}),
        ...(b.alert_token ? { alert_token: b.alert_token.toLowerCase() } : {}),
        environment: b.environment,
        topic: b.topic,
      });
      return { handle };
    },
  );

  app.post<{ Body: SendBody }>(
    "/v1/send",
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["handle", "push_type", "payload", "expiration"],
          properties: {
            handle: { type: "string", minLength: 1, maxLength: 2048 },
            push_type: { type: "string", enum: ["voip", "alert", "background"] },
            payload: {
              type: "object",
              additionalProperties: false,
              required: ["aps", "agentring"],
              properties: {
                aps: { type: "object" },
                // Only the relay's signed PushData: the app verifies `sig` and drops anything else.
                agentring: {
                  type: "object",
                  additionalProperties: false,
                  required: ["v", "relay_id", "event", "sig"],
                  properties: {
                    v: { type: "string" },
                    relay_id: { type: "string", maxLength: 64 },
                    event: { type: "string" },
                    sig: { type: "string", maxLength: 128 },
                  },
                },
              },
            },
            expiration: { type: "integer", minimum: 0 },
            collapse_id: { type: "string", maxLength: 64 },
          },
        },
      },
    },
    async (req, reply) => {
      if (!perIp.take(`send:${req.ip}`, limits.sendPerIpPerHour)) {
        throw new GatewayError(429, "rate_limited", "Too many pushes from this address");
      }
      const b = req.body;
      const data = codec.open(b.handle);
      if (!data) throw new GatewayError(400, "invalid_handle", "Unknown or corrupted handle");
      if (data.topic !== topic) throw new GatewayError(400, "invalid_handle", "The handle is for another app");
      const token = b.push_type === "voip" ? data.voip_token : data.alert_token;
      if (!token) throw new GatewayError(400, "invalid_request", `The handle has no ${b.push_type === "voip" ? "VoIP" : "alert"} token`);
      const size = Buffer.byteLength(JSON.stringify(b.payload));
      if (size > APNS_MAX_BYTES[b.push_type]) throw new GatewayError(400, "invalid_request", `Payload too large (${size} bytes)`);
      const limit =
        b.push_type === "voip" ? limits.voipPerHour : b.push_type === "alert" ? limits.alertPerHour : limits.backgroundPerHour;
      if (!perToken.take(`${b.push_type}:${token}`, limit)) {
        throw new GatewayError(429, "rate_limited", `Too many ${b.push_type} pushes to this device`);
      }
      const res = await provider.send(
        { deviceId: "gateway", token, environment: data.environment, topic: data.topic },
        b.payload.agentring,
        {
          kind: KIND[b.push_type],
          ttlSeconds: 0,
          highPriority: b.push_type !== "background",
          expiresAt: b.expiration * 1000,
          aps: safeAps(b.push_type, b.payload.aps),
          ...(b.collapse_id ? { collapseKey: b.collapse_id } : {}),
        },
      );
      if (res.ok) return { ok: true };
      if (res.unregistered) {
        return reply.code(410).send({ error: { code: "unregistered", message: "APNs no longer accepts this device token" } });
      }
      req.log.warn({ push_type: b.push_type, error: res.error }, "APNs push failed");
      throw new GatewayError(502, "apns_error", res.error);
    },
  );

  app.addHook("onClose", async () => {
    await owned?.close();
  });
  void owned?.prepare().catch((err: unknown) => app.log.warn({ err }, "APNs warm-up failed"));
  return { app, codec };
}

const ALERT_TEXT: Record<string, string> = {
  AGENTRING_MESSAGE: "New message",
  AGENTRING_MISSED: "Missed call",
};

/**
 * The `aps` block the gateway sends, rebuilt from an allowlist. Whoever holds a handle
 * must not choose the text a phone shows: the app's extension only replaces the text
 * after verifying `agentring.sig`, so an unverified push shows these fixed strings and
 * a generic title (the extension puts the agent's name in after verifying).
 */
export function safeAps(pushType: "voip" | "alert" | "background", aps: Record<string, unknown>): Record<string, unknown> {
  if (pushType === "voip") return {};
  if (pushType === "background") return { "content-available": 1 };
  const category = typeof aps.category === "string" && aps.category in ALERT_TEXT ? aps.category : "AGENTRING_MESSAGE";
  const out: Record<string, unknown> = {
    alert: { title: "agentring", body: ALERT_TEXT[category] },
    category,
    "mutable-content": 1,
    sound: "default",
  };
  const thread = aps["thread-id"];
  if (typeof thread === "string" && /^rly_[A-Za-z0-9_-]{1,64}$/.test(thread)) out["thread-id"] = thread;
  if (aps["interruption-level"] === "time-sensitive") out["interruption-level"] = "time-sensitive";
  return out;
}
