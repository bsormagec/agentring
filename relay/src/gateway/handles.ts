import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

/** What a gateway handle carries: the device's APNs registration. */
export interface HandleData {
  voip_token?: string;
  alert_token?: string;
  environment: "sandbox" | "production";
  topic: string;
}

const VERSION = 1;
const IV_BYTES = 12;
const TAG_BYTES = 16;

/**
 * Opaque push-gateway handles: AES-256-GCM of the APNs registration under the
 * gateway's key. The gateway stores nothing per device; whoever holds a handle can
 * only ask the gateway to push to that device (rate-limited), never read its tokens.
 * Layout (base64url): version byte | 12-byte IV | ciphertext | 16-byte tag; the
 * version byte is authenticated as associated data.
 */
export class HandleCodec {
  private readonly key: Buffer;

  constructor(key: Buffer) {
    if (key.length !== 32) throw new Error("The push gateway key must be 32 bytes");
    this.key = key;
  }

  seal(data: HandleData): string {
    const iv = randomBytes(IV_BYTES);
    const version = Buffer.from([VERSION]);
    const cipher = createCipheriv("aes-256-gcm", this.key, iv);
    cipher.setAAD(version);
    const compact = { v: data.voip_token, a: data.alert_token, e: data.environment === "sandbox" ? "s" : "p", t: data.topic };
    const ct = Buffer.concat([cipher.update(JSON.stringify(compact), "utf8"), cipher.final()]);
    return Buffer.concat([version, iv, ct, cipher.getAuthTag()]).toString("base64url");
  }

  /** The registration in a handle, or undefined if it isn't one of ours (or was tampered with). */
  open(handle: string): HandleData | undefined {
    if (!/^[A-Za-z0-9_-]+$/.test(handle)) return undefined;
    const raw = Buffer.from(handle, "base64url");
    if (raw.length < 1 + IV_BYTES + TAG_BYTES + 2 || raw[0] !== VERSION) return undefined;
    try {
      const decipher = createDecipheriv("aes-256-gcm", this.key, raw.subarray(1, 1 + IV_BYTES));
      decipher.setAAD(raw.subarray(0, 1));
      decipher.setAuthTag(raw.subarray(raw.length - TAG_BYTES));
      const pt = Buffer.concat([decipher.update(raw.subarray(1 + IV_BYTES, raw.length - TAG_BYTES)), decipher.final()]);
      const c = JSON.parse(pt.toString("utf8")) as { v?: string; a?: string; e: string; t: string };
      return {
        ...(c.v ? { voip_token: c.v } : {}),
        ...(c.a ? { alert_token: c.a } : {}),
        environment: c.e === "s" ? "sandbox" : "production",
        topic: c.t,
      };
    } catch {
      return undefined;
    }
  }
}
