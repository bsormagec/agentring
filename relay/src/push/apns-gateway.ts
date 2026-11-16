import {
  apnsBody,
  apnsExpiration,
  apnsPushType,
  type PushOptions,
  type PushPayload,
  type PushProvider,
  type PushResult,
  type PushTarget,
} from "./push-provider.js";

const REQUEST_TIMEOUT_MS = 15_000;

/**
 * Pushes to iOS devices through a push gateway (protocol/push-gateway.openapi.yaml),
 * for a self-hosted relay and the App Store app, whose APNs key only the publisher
 * holds. `target.token` is the device's opaque gateway handle.
 */
export class ApnsGatewayProvider implements PushProvider {
  readonly name = "apns_gateway";
  private readonly url: string;

  constructor(
    url: string,
    readonly topic: string,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {
    this.url = url.replace(/\/+$/, "");
  }

  get gatewayUrl(): string {
    return this.url;
  }

  async send(target: PushTarget, payload: PushPayload, opts: PushOptions): Promise<PushResult> {
    const body = {
      handle: target.token,
      push_type: apnsPushType(opts),
      payload: apnsBody(payload, opts),
      expiration: apnsExpiration(opts),
      ...(opts.collapseKey ? { collapse_id: opts.collapseKey.slice(0, 64) } : {}),
    };
    let res: Response;
    try {
      res = await this.fetchImpl(`${this.url}/v1/send`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
    } catch (e) {
      return { ok: false, unregistered: false, error: `push gateway: ${String(e)}` };
    }
    if (res.ok) return { ok: true };
    const text = await res.text().catch(() => "");
    // 410: APNs no longer knows the token; a handle the gateway can't decrypt won't work either.
    const unregistered = res.status === 410 || (res.status === 400 && text.includes('"invalid_handle"'));
    return { ok: false, unregistered, error: `${res.status} ${text.slice(0, 300)}` };
  }
}
