import { createHmac } from "node:crypto";
import type { FastifyBaseLogger } from "fastify";
import type { Db } from "../db/database.js";
import type { Event } from "../protocol.js";
import type { PushKind, PushOptions, PushPayload, PushProvider, PushTarget } from "./push-provider.js";

/** FCM data payloads are capped at 4096 bytes (APNs alerts too); leave room for the other keys. */
const MAX_EVENT_BYTES = 3000;
const MESSAGE_TTL_S = 28 * 24 * 3600;
/** Call state changes only matter while a phone may still be ringing or on the call. */
const CALL_UPDATE_TTL_S = 30;
/** "Someone is on the call, you can join": long enough for a phone that was offline; the app re-checks the call. */
const CALL_JOINABLE_TTL_S = 3600;
/** iOS missed-call alert: still worth showing when a phone that was off comes back the same day. */
const MISSED_ALERT_TTL_S = 24 * 3600;

/** Looks up a call for push routing. */
export type CallLookup = (callId: string) => CallInfo | undefined;

export function signEvent(pushSecret: string, eventJson: string): string {
  return createHmac("sha256", Buffer.from(pushSecret, "base64url")).update(eventJson, "utf8").digest("base64url");
}

export function buildPayload(relayId: string, pushSecret: string, event: Event): PushPayload {
  let json = JSON.stringify(event);
  if (event.type === "msg.new") {
    let text = event.text;
    while (Buffer.byteLength(json) > MAX_EVENT_BYTES && text.length > 0) {
      const overflow = Buffer.byteLength(json) - MAX_EVENT_BYTES;
      // Cut by code points so we never split a surrogate pair.
      const chars = Array.from(text);
      text = chars.slice(0, Math.max(0, chars.length - Math.max(overflow, 16))).join("");
      json = JSON.stringify({ ...event, text, truncated: true });
    }
  }
  return { v: "1", relay_id: relayId, event: json, sig: signEvent(pushSecret, json) };
}

interface PushRule {
  ttlSeconds: number;
  highPriority: boolean;
}

/** The parts of a call push routing needs; `device_ids` = the phones a targeted call rings. */
export interface CallInfo {
  direction: string;
  device_ids?: string[];
  priority?: "normal" | "urgent";
  agent_name?: string;
}

/** Which events wake an Android phone. Everything else is delivered over the WebSocket only. */
export function androidPushOptions(event: Event, getCall: CallLookup): PushOptions | undefined {
  const rule = ((): PushRule | undefined => {
    switch (event.type) {
      case "msg.new":
        return event.from === "agent" ? { ttlSeconds: MESSAGE_TTL_S, highPriority: true } : undefined;
      case "call.invite":
        // Never deliver an invite after it expired: TTL = time left to ring.
        return event.direction === "agent_to_user"
          ? { ttlSeconds: Math.max(1, Math.ceil((event.expires_at - Date.now()) / 1000)), highPriority: true }
          : undefined;
      case "call.accept":
        // Lets the other phones offer "join the call" (also those whose ring ended or
        // that never got the invite). Normal priority: it doesn't need to wake a phone
        // in Doze, and a high-priority push that shows nothing (the phones still
        // ringing) gets the app's later pushes deprioritized.
        return event.by === "user" && getCall(event.call_id)?.direction === "agent_to_user"
          ? { ttlSeconds: CALL_JOINABLE_TTL_S, highPriority: false }
          : undefined;
      // call.decline is not pushed: in a group call one phone declining doesn't affect the others.
      case "call.end":
      case "call.missed":
        // Stops the ringing on every device (or tears down the call screen).
        return getCall(event.call_id)?.direction === "agent_to_user"
          ? { ttlSeconds: CALL_UPDATE_TTL_S, highPriority: true }
          : undefined;
      default:
        return undefined;
    }
  })();
  if (!rule) return undefined;
  const kind: PushKind = event.type === "msg.new" ? "message" : event.type === "call.invite" ? "call" : "update";
  return { ...rule, kind };
}

/**
 * Which events reach an iPhone, and as which APNs push type (docs/ios.md). A VoIP push
 * must always become a CallKit call, so only `call.invite` is one; `call.end` is not
 * pushed (the app is awake while CallKit rings and follows the WebSocket).
 */
export function iosPushOptions(event: Event, getCall: CallLookup, relayId: string, agentName: string): PushOptions | undefined {
  switch (event.type) {
    case "msg.new":
      if (event.from !== "agent") return undefined;
      return {
        kind: "message",
        ttlSeconds: MESSAGE_TTL_S,
        highPriority: true,
        // Placeholder text: the Notification Service Extension verifies `sig` and puts the message in.
        aps: {
          alert: { title: agentName, body: "New message" },
          "mutable-content": 1,
          sound: "default",
          "thread-id": relayId,
          category: "AGENTRING_MESSAGE",
        },
      };
    case "call.invite":
      return event.direction === "agent_to_user"
        ? {
            kind: "call",
            ttlSeconds: Math.max(1, Math.ceil((event.expires_at - Date.now()) / 1000)),
            highPriority: true,
            expiresAt: event.expires_at,
            aps: {},
          }
        : undefined;
    case "call.accept":
      return event.by === "user" && getCall(event.call_id)?.direction === "agent_to_user"
        ? { kind: "update", ttlSeconds: CALL_JOINABLE_TTL_S, highPriority: false, aps: { "content-available": 1 } }
        : undefined;
    case "call.missed": {
      const call = getCall(event.call_id);
      if (call?.direction !== "agent_to_user") return undefined;
      return {
        kind: "message",
        ttlSeconds: MISSED_ALERT_TTL_S,
        highPriority: true,
        // The app uses call_id for its own missed-call notification too, so they never show twice.
        collapseKey: event.call_id,
        aps: {
          alert: { title: call.agent_name ?? agentName, body: "Missed call" },
          "mutable-content": 1,
          sound: "default",
          "thread-id": relayId,
          category: "AGENTRING_MISSED",
          ...(call.priority === "urgent" ? { "interruption-level": "time-sensitive" } : {}),
        },
      };
    }
    default:
      return undefined;
  }
}

interface DeviceRow {
  device_id: string;
  platform: string;
  push_secret: string;
  fcm_token: string | null;
  apns_voip_token: string | null;
  apns_alert_token: string | null;
  apns_env: "sandbox" | "production" | null;
  apns_topic: string | null;
  apns_gateway_handle: string | null;
}

export interface PushProviders {
  /** Android devices. */
  fcm?: PushProvider;
  /** iOS devices with APNs tokens (the relay holds the APNs key). */
  apns?: PushProvider;
  /** iOS devices with a push-gateway handle. */
  apnsGateway?: PushProvider;
}

/** A device's push route for one event: provider, target and the column to clear if the token is dead. */
interface Route {
  provider: PushProvider;
  target: PushTarget;
  column: "fcm_token" | "apns_voip_token" | "apns_alert_token" | "apns_gateway_handle";
}

export class PushDispatcher {
  constructor(
    private readonly db: Db,
    private readonly providers: PushProviders,
    private readonly relayId: string,
    private readonly log: FastifyBaseLogger,
    private readonly getCall: CallLookup = () => undefined,
    private readonly agentName = "Agent",
  ) {}

  private route(d: DeviceRow, opts: PushOptions): Route | undefined {
    if (d.platform !== "ios") {
      return this.providers.fcm && d.fcm_token
        ? { provider: this.providers.fcm, target: { deviceId: d.device_id, token: d.fcm_token }, column: "fcm_token" }
        : undefined;
    }
    if (d.apns_gateway_handle) {
      return this.providers.apnsGateway
        ? {
            provider: this.providers.apnsGateway,
            target: { deviceId: d.device_id, token: d.apns_gateway_handle },
            column: "apns_gateway_handle",
          }
        : undefined;
    }
    if (!this.providers.apns) return undefined;
    const column = opts.kind === "call" ? "apns_voip_token" : "apns_alert_token";
    const token = d[column];
    if (!token) return undefined;
    return {
      provider: this.providers.apns,
      target: {
        deviceId: d.device_id,
        token,
        environment: d.apns_env ?? "production",
        ...(d.apns_topic ? { topic: d.apns_topic } : {}),
      },
      column,
    };
  }

  handle(event: Event): void {
    const { fcm, apns, apnsGateway } = this.providers;
    if (!fcm && !apns && !apnsGateway) return;
    const androidOpts = androidPushOptions(event, this.getCall);
    const iosOpts = iosPushOptions(event, this.getCall, this.relayId, this.agentName);
    if (!androidOpts && !iosOpts) return;
    const devices = this.db
      .prepare(
        `SELECT device_id, platform, push_secret, fcm_token, apns_voip_token, apns_alert_token, apns_env, apns_topic,
                apns_gateway_handle
           FROM devices
          WHERE revoked_at IS NULL
            AND (fcm_token IS NOT NULL OR apns_voip_token IS NOT NULL OR apns_alert_token IS NOT NULL
                 OR apns_gateway_handle IS NOT NULL)`,
      )
      .all() as unknown as DeviceRow[];
    // A targeted call's pushes only go to the phones it targets.
    const targets = event.type.startsWith("call.") ? this.getCall((event as { call_id: string }).call_id)?.device_ids : undefined;
    for (const d of devices) {
      if (targets && !targets.includes(d.device_id)) continue;
      // The phone that joined already knows.
      if (event.type === "call.accept" && event.device_id === d.device_id) continue;
      const opts = d.platform === "ios" ? iosOpts : androidOpts;
      if (!opts) continue;
      const route = this.route(d, opts);
      if (!route) continue;
      const payload = buildPayload(this.relayId, d.push_secret, event);
      void route.provider
        .send(route.target, payload, opts)
        .then((res) => {
          if (res.ok) {
            this.log.debug({ device: d.device_id, event: event.type, provider: route.provider.name }, "push sent");
            return;
          }
          this.log.warn({ device: d.device_id, event: event.type, provider: route.provider.name, error: res.error }, "push failed");
          if (res.unregistered) {
            this.db
              .prepare(`UPDATE devices SET ${route.column} = NULL WHERE device_id = ? AND ${route.column} = ?`)
              .run(d.device_id, route.target.token);
          }
        })
        .catch((e: unknown) => this.log.error({ err: e, device: d.device_id }, "push error"));
    }
  }
}
