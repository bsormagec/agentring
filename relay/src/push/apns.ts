import { createPrivateKey, type KeyObject } from "node:crypto";
import http2 from "node:http2";
import { SignJWT } from "jose";
import {
  APNS_MAX_BYTES,
  apnsBody,
  apnsExpiration,
  apnsPushType,
  type PushOptions,
  type PushPayload,
  type PushProvider,
  type PushResult,
  type PushTarget,
} from "./push-provider.js";

export const APNS_HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
} as const;

/** Apple wants the provider token refreshed every 20–60 minutes, and no more often than every 20. */
const TOKEN_TTL_MS = 50 * 60_000;
const REQUEST_TIMEOUT_MS = 15_000;
/** APNs reasons (with status 400) that mean the token will never work again for this topic. */
const DEAD_TOKEN_REASONS = new Set(["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"]);

export interface ApnsOptions {
  /** The `.p8` key (PKCS#8 PEM) or an already-parsed key. */
  key: string | KeyObject;
  keyId: string;
  teamId: string;
  /** Default topic (bundle id) when the target has none. */
  topic: string;
  /**
   * Test only: one origin for both environments instead of Apple's hosts.
   * `http://` uses HTTP/2 without TLS (h2c), for a plain `http2.createServer` fake.
   */
  host?: string;
  tokenTtlMs?: number;
  requestTimeoutMs?: number;
}

interface ApnsResponse {
  status: number;
  body: string;
  apnsId?: string;
}

/**
 * APNs provider over HTTP/2 with token (`.p8`) authentication. No dependency besides
 * `jose` for the ES256 provider token. One long-lived HTTP/2 session per host,
 * reopened when it closes (Apple drops idle connections and sends GOAWAY).
 */
export class ApnsProvider implements PushProvider {
  readonly name = "apns";
  private readonly key: KeyObject;
  private jwt?: { value: string; createdAt: number };
  private readonly sessions = new Map<string, http2.ClientHttp2Session>();

  constructor(private readonly opts: ApnsOptions) {
    this.key = typeof opts.key === "string" ? createPrivateKey(opts.key) : opts.key;
    if (this.key.asymmetricKeyType !== "ec") throw new Error("The APNs key must be an EC (P-256) .p8 key");
  }

  get topic(): string {
    return this.opts.topic;
  }

  async prepare(): Promise<void> {
    await this.providerToken();
  }

  async close(): Promise<void> {
    for (const s of this.sessions.values()) s.close();
    this.sessions.clear();
  }

  /** The cached provider token, re-signed every ~50 minutes. */
  private async providerToken(): Promise<string> {
    const ttl = this.opts.tokenTtlMs ?? TOKEN_TTL_MS;
    if (this.jwt && Date.now() - this.jwt.createdAt < ttl) return this.jwt.value;
    const now = Date.now();
    const value = await new SignJWT({})
      .setProtectedHeader({ alg: "ES256", kid: this.opts.keyId })
      .setIssuer(this.opts.teamId)
      .setIssuedAt(Math.floor(now / 1000))
      .sign(this.key);
    this.jwt = { value, createdAt: now };
    return value;
  }

  private origin(environment: PushTarget["environment"]): string {
    return this.opts.host ?? APNS_HOSTS[environment ?? "production"];
  }

  private session(origin: string): http2.ClientHttp2Session {
    const existing = this.sessions.get(origin);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const s = http2.connect(origin);
    // Errors surface on the requests; a dead session is dropped and reopened on next use.
    s.on("error", () => this.drop(origin, s));
    s.on("close", () => this.drop(origin, s));
    // GOAWAY: new pushes go to a new connection; the ones in flight may still finish.
    s.on("goaway", () => this.drop(origin, s, true));
    // Don't keep the process alive just for an idle push connection.
    s.unref();
    this.sessions.set(origin, s);
    return s;
  }

  private drop(origin: string, s: http2.ClientHttp2Session, graceful = false): void {
    if (this.sessions.get(origin) === s) this.sessions.delete(origin);
    if (graceful) {
      if (!s.closed) s.close();
    } else if (!s.destroyed) {
      s.destroy();
    }
  }

  private request(origin: string, headers: http2.OutgoingHttpHeaders, body: string): Promise<ApnsResponse> {
    return new Promise((resolve, reject) => {
      let req: http2.ClientHttp2Stream;
      try {
        req = this.session(origin).request(headers);
      } catch (e) {
        reject(e);
        return;
      }
      let status = 0;
      let apnsId: string | undefined;
      const chunks: Buffer[] = [];
      req.setTimeout(this.opts.requestTimeoutMs ?? REQUEST_TIMEOUT_MS, () => {
        req.close(http2.constants.NGHTTP2_CANCEL);
        reject(new TimeoutError());
      });
      req.on("response", (h) => {
        status = Number(h[":status"]);
        const id = h["apns-id"];
        apnsId = typeof id === "string" ? id : undefined;
      });
      req.on("data", (c: Buffer) => chunks.push(c));
      req.on("end", () => resolve({ status, body: Buffer.concat(chunks).toString("utf8"), apnsId }));
      req.on("error", reject);
      req.end(body);
    });
  }

  async send(target: PushTarget, payload: PushPayload, opts: PushOptions): Promise<PushResult> {
    const pushType = apnsPushType(opts);
    const body = JSON.stringify(apnsBody(payload, opts));
    if (Buffer.byteLength(body) > APNS_MAX_BYTES[pushType]) {
      return { ok: false, unregistered: false, error: `payload too large for ${pushType} (${Buffer.byteLength(body)} bytes)` };
    }
    if (!/^[0-9a-fA-F]{16,200}$/.test(target.token)) {
      return { ok: false, unregistered: true, error: "malformed device token" };
    }
    const topic = target.topic ?? this.opts.topic;
    const origin = this.origin(target.environment);
    const headersFor = (jwt: string): http2.OutgoingHttpHeaders => ({
      ":method": "POST",
      ":path": `/3/device/${target.token}`,
      authorization: `bearer ${jwt}`,
      "apns-push-type": pushType,
      "apns-topic": pushType === "voip" ? `${topic}.voip` : topic,
      // Background pushes must use priority 5; Apple rejects 10 for them.
      "apns-priority": pushType === "background" ? "5" : "10",
      "apns-expiration": String(apnsExpiration(opts)),
      ...(opts.collapseKey ? { "apns-collapse-id": opts.collapseKey.slice(0, 64) } : {}),
      "content-type": "application/json",
    });

    let res: ApnsResponse;
    try {
      res = await this.withRetry(origin, headersFor, body);
    } catch (e) {
      return { ok: false, unregistered: false, error: `APNs: ${String(e)}` };
    }
    if (res.status === 200) return { ok: true };
    const reason = parseReason(res.body);
    const unregistered = res.status === 410 || (res.status === 400 && DEAD_TOKEN_REASONS.has(reason));
    return { ok: false, unregistered, error: `${res.status} ${reason || res.body.slice(0, 200)}` };
  }

  /**
   * One retry on a fresh session when the connection died under the request (a GOAWAY
   * or a reset on an idle connection), and one with a new provider token when APNs
   * says it expired.
   */
  private async withRetry(
    origin: string,
    headersFor: (jwt: string) => http2.OutgoingHttpHeaders,
    body: string,
  ): Promise<ApnsResponse> {
    let res: ApnsResponse;
    try {
      res = await this.request(origin, headersFor(await this.providerToken()), body);
    } catch (e) {
      // A timeout may have reached APNs: don't risk a second ring.
      if (e instanceof TimeoutError) throw e;
      const s = this.sessions.get(origin);
      if (s) this.drop(origin, s);
      res = await this.request(origin, headersFor(await this.providerToken()), body);
    }
    if (res.status === 403 && parseReason(res.body) === "ExpiredProviderToken") {
      this.jwt = undefined;
      res = await this.request(origin, headersFor(await this.providerToken()), body);
    }
    return res;
  }
}

class TimeoutError extends Error {
  constructor() {
    super("APNs request timed out");
  }
}

function parseReason(body: string): string {
  try {
    return String((JSON.parse(body) as { reason?: string }).reason ?? "");
  } catch {
    return "";
  }
}
