/**
 * Transport-agnostic push interface: FCM for Android, APNs (direct or through a
 * push gateway) for iOS. The dispatcher picks the provider per device.
 */
export interface PushTarget {
  deviceId: string;
  /** FCM registration token, APNs device token (hex) or push-gateway handle. */
  token: string;
  /** APNs only: which host the token belongs to. */
  environment?: "sandbox" | "production";
  /** APNs only: the app's bundle id (the provider's default when absent). */
  topic?: string;
}

/** String map delivered to the app (FCM `data`, APNs `agentring`). See `PushData` in the OpenAPI. */
export type PushPayload = Record<string, string>;

/**
 * What a push is for. FCM ignores it; APNs maps it to its push type:
 * `call` → `voip` (PushKit), `message` → `alert`, `update` → `background`.
 */
export type PushKind = "call" | "message" | "update";

export interface PushOptions {
  ttlSeconds: number;
  highPriority: boolean;
  /** FCM `collapse_key`; APNs `apns-collapse-id`. */
  collapseKey?: string;
  kind?: PushKind;
  /** Absolute expiry (ms since epoch). APNs `apns-expiration`; defaults to now + ttlSeconds. */
  expiresAt?: number;
  /** APNs only: the `aps` dictionary of the payload (alert placeholder, category, ...). */
  aps?: Record<string, unknown>;
}

export type PushResult = { ok: true } | { ok: false; unregistered: boolean; error: string };

export interface PushProvider {
  readonly name: string;
  send(target: PushTarget, payload: PushPayload, opts: PushOptions): Promise<PushResult>;
  /** Optional warm-up (e.g. fetch credentials) so the first real push is fast. */
  prepare?(): Promise<void>;
  /** Optional: release connections (HTTP/2 sessions). */
  close?(): Promise<void>;
}

export type ApnsPushType = "voip" | "alert" | "background";

export function apnsPushType(opts: PushOptions): ApnsPushType {
  switch (opts.kind) {
    case "call":
      return "voip";
    case "update":
      return "background";
    default:
      return "alert";
  }
}

/** APNs `apns-expiration` in UNIX seconds. */
export function apnsExpiration(opts: PushOptions, now = Date.now()): number {
  return Math.ceil((opts.expiresAt ?? now + opts.ttlSeconds * 1000) / 1000);
}

/** The JSON body of an APNs push (`ApnsPayload` in the OpenAPI). */
export function apnsBody(payload: PushPayload, opts: PushOptions): { aps: Record<string, unknown>; agentring: PushPayload } {
  const pushType = apnsPushType(opts);
  const aps = opts.aps ?? (pushType === "background" ? { "content-available": 1 } : {});
  return { aps, agentring: payload };
}

/** APNs payload size limits (bytes). */
export const APNS_MAX_BYTES: Record<ApnsPushType, number> = { voip: 5120, alert: 4096, background: 4096 };
