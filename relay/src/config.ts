import { createPrivateKey } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

export interface FcmClientConfig {
  project_id: string;
  application_id: string;
  api_key: string;
  sender_id: string;
}

export interface Config {
  host: string;
  port: number;
  publicUrl: string;
  dataDir: string;
  agentName: string;
  /** Explicit API key from env; otherwise one is generated and persisted. */
  apiKey?: string;
  ringTimeoutS: number;
  /** Reverse proxies in front of the relay; the client address is read that many hops from the right of X-Forwarded-For. */
  trustedProxies?: number;
  insecureDev: boolean;
  livekit?: LiveKitConfig;
  /** Direct APNs (token auth with a .p8 key): iOS pushes from this relay (or the push gateway). */
  apns?: ApnsConfig;
  /** iOS pushes through a push gateway (self-hosted relay + the App Store app). */
  apnsGateway?: { url: string; topic: string };
  /** AGENTRING_PUSH_GATEWAY=1: serve only the push gateway API (relay/src/gateway). */
  pushGateway?: { key?: string };
  fcm?: {
    serviceAccountFile: string;
    client: FcmClientConfig;
    /** Overridable for tests. */
    apiBase: string;
  };
}

export interface LiveKitConfig {
  /** URL handed to clients (phone and daemon) to join rooms, e.g. wss://relay.example.com. */
  publicUrl: string;
  /** URL the relay uses for LiveKit's server API (room service). */
  apiUrl: string;
  apiKey: string;
  apiSecret: string;
}

export interface ApnsConfig {
  /** PKCS#8 PEM of the .p8 key. */
  key: string;
  keyId: string;
  teamId: string;
  /** Bundle id of the iOS app. */
  topic: string;
  /** Test only: one origin for both APNs environments (`http://` = h2c). */
  host?: string;
}

export const ANDROID_PACKAGE = "dev.agentring.app";
export const IOS_BUNDLE_ID = "dev.agentring.app";

function env(name: string, fallback?: string): string | undefined {
  const v = process.env[name];
  return v === undefined || v === "" ? fallback : v;
}

/**
 * Extracts the public Firebase client values for our Android package from a
 * google-services.json downloaded from the Firebase console.
 */
export function parseGoogleServices(json: unknown, pkg = ANDROID_PACKAGE): FcmClientConfig {
  const j = json as {
    project_info?: { project_id?: string; project_number?: string };
    client?: Array<{
      client_info?: { mobilesdk_app_id?: string; android_client_info?: { package_name?: string } };
      api_key?: Array<{ current_key?: string }>;
    }>;
  };
  const client = j.client?.find((c) => c.client_info?.android_client_info?.package_name === pkg);
  if (!client) {
    throw new Error(`google-services.json has no Android app with package name "${pkg}"`);
  }
  const out = {
    project_id: j.project_info?.project_id ?? "",
    sender_id: j.project_info?.project_number ?? "",
    application_id: client.client_info?.mobilesdk_app_id ?? "",
    api_key: client.api_key?.[0]?.current_key ?? "",
  };
  for (const [k, v] of Object.entries(out)) {
    if (!v) throw new Error(`google-services.json is missing ${k}`);
  }
  return out;
}

/** Fastify's `trustProxy`: trust exactly that many hops, nearest first. */
export function trustedHops(cfg: Pick<Config, "trustedProxies">): (address: string, hop: number) => boolean {
  const hops = cfg.trustedProxies ?? 1;
  return (_address, hop) => hop < hops;
}

function trustedProxies(value: string): number {
  if (!/^\d+$/.test(value)) throw new Error(`AGENTRING_TRUSTED_PROXIES must be a number of proxies (got ${value})`);
  return Number(value);
}

/** Reads and checks the APNs .p8 key settings; undefined when APNs isn't configured. */
function loadApns(insecureDev: boolean): ApnsConfig | undefined {
  const keyFile = env("AGENTRING_APNS_KEY_FILE");
  const keyInline = env("AGENTRING_APNS_KEY");
  const keyId = env("AGENTRING_APNS_KEY_ID");
  const teamId = env("AGENTRING_APNS_TEAM_ID");
  if (!keyFile && !keyInline && !keyId && !teamId) return undefined;
  if (!(keyFile || keyInline) || !keyId || !teamId) {
    throw new Error("Set AGENTRING_APNS_KEY_FILE (or AGENTRING_APNS_KEY), AGENTRING_APNS_KEY_ID and AGENTRING_APNS_TEAM_ID to enable APNs");
  }
  if (keyFile && keyInline) throw new Error("Set only one of AGENTRING_APNS_KEY_FILE and AGENTRING_APNS_KEY");
  // An inline key may come with its newlines escaped (one-line env files).
  const key = keyFile ? readFileSync(keyFile, "utf8") : keyInline!.replace(/\\n/g, "\n");
  let parsed;
  try {
    parsed = createPrivateKey(key);
  } catch (e) {
    throw new Error(`The APNs key is not a valid .p8 (PKCS#8 PEM) key: ${(e as Error).message}`);
  }
  if (parsed.asymmetricKeyType !== "ec" || parsed.asymmetricKeyDetails?.namedCurve !== "prime256v1") {
    throw new Error("The APNs key must be an EC P-256 .p8 key from the Apple developer portal");
  }
  if (!/^[A-Z0-9]{10}$/.test(keyId)) throw new Error(`AGENTRING_APNS_KEY_ID must be the 10-character key id (got ${keyId})`);
  if (!/^[A-Z0-9]{10}$/.test(teamId)) throw new Error(`AGENTRING_APNS_TEAM_ID must be the 10-character team id (got ${teamId})`);
  const host = env("AGENTRING_APNS_HOST")?.replace(/\/+$/, "");
  if (host && !host.startsWith("https://") && !(host.startsWith("http://") && insecureDev)) {
    throw new Error("AGENTRING_APNS_HOST (tests only) must be https://, or http:// with AGENTRING_INSECURE_DEV=1");
  }
  return { key, keyId, teamId, topic: env("AGENTRING_APNS_TOPIC", IOS_BUNDLE_ID)!, ...(host ? { host } : {}) };
}

export function loadConfig(): Config {
  const dataDir = env("AGENTRING_DATA_DIR", "./data")!;
  const port = Number(env("PORT", "8080"));
  const publicUrl = env("AGENTRING_PUBLIC_URL", `http://localhost:${port}`)!.replace(/\/+$/, "");
  const insecureDev = env("AGENTRING_INSECURE_DEV") === "1";
  const gatewayMode = env("AGENTRING_PUSH_GATEWAY") === "1";
  // The push gateway has no public URL of its own to hand out.
  if (!gatewayMode && !publicUrl.startsWith("https://") && !insecureDev) {
    throw new Error(
      `AGENTRING_PUBLIC_URL must be https:// (got ${publicUrl}). Set AGENTRING_INSECURE_DEV=1 for local development only.`,
    );
  }

  let fcm: Config["fcm"];
  const saFile = env("FCM_SERVICE_ACCOUNT_FILE");
  const gsFile = env("FCM_GOOGLE_SERVICES_FILE");
  if (saFile || gsFile) {
    if (!saFile || !gsFile) {
      throw new Error("Set both FCM_SERVICE_ACCOUNT_FILE and FCM_GOOGLE_SERVICES_FILE to enable push");
    }
    fcm = {
      serviceAccountFile: saFile,
      client: parseGoogleServices(JSON.parse(readFileSync(gsFile, "utf8"))),
      apiBase: env("FCM_API_BASE", "https://fcm.googleapis.com")!,
    };
  }

  let livekit: LiveKitConfig | undefined;
  const lkKey = env("LIVEKIT_API_KEY");
  // Prefer a file (mounted read-only) so the secret never sits in the environment,
  // where `docker inspect` and deploy tooling would show it.
  const lkSecretFile = env("LIVEKIT_API_SECRET_FILE");
  const lkSecret = lkSecretFile ? readFileSync(lkSecretFile, "utf8").trim() : env("LIVEKIT_API_SECRET");
  if (lkKey || lkSecret) {
    if (!lkKey || !lkSecret) throw new Error("Set LIVEKIT_API_KEY and LIVEKIT_API_SECRET (or LIVEKIT_API_SECRET_FILE) to enable calls");
    // Anyone holding the secret can mint tokens for any call room.
    if (lkSecret.length < 32) throw new Error("LIVEKIT_API_SECRET must be at least 32 characters (generate one with: openssl rand -base64 32)");
    // By default LiveKit is served on the relay's own hostname (Caddy routes /rtc to it).
    const lkPublic = env("LIVEKIT_URL", publicUrl.replace(/^http/, "ws"))!.replace(/\/+$/, "");
    livekit = {
      publicUrl: lkPublic,
      apiUrl: env("LIVEKIT_API_URL", lkPublic.replace(/^ws/, "http"))!.replace(/\/+$/, ""),
      apiKey: lkKey,
      apiSecret: lkSecret,
    };
  }

  const apns = loadApns(insecureDev);
  let apnsGateway: Config["apnsGateway"];
  const gatewayUrl = env("AGENTRING_APNS_GATEWAY_URL")?.replace(/\/+$/, "");
  if (gatewayUrl && !gatewayMode) {
    if (!gatewayUrl.startsWith("https://") && !(gatewayUrl.startsWith("http://") && insecureDev)) {
      throw new Error(`AGENTRING_APNS_GATEWAY_URL must be https:// (got ${gatewayUrl})`);
    }
    apnsGateway = { url: gatewayUrl, topic: env("AGENTRING_APNS_TOPIC", IOS_BUNDLE_ID)! };
  }
  if (gatewayMode && !apns) throw new Error("Push gateway mode (AGENTRING_PUSH_GATEWAY=1) needs the APNs key settings");

  return {
    host: env("HOST", "0.0.0.0")!,
    port,
    publicUrl,
    dataDir,
    agentName: env("AGENTRING_AGENT_NAME", "Agent")!,
    apiKey: env("AGENTRING_API_KEY"),
    ringTimeoutS: Number(env("AGENTRING_RING_TIMEOUT_S", "30")),
    trustedProxies: trustedProxies(env("AGENTRING_TRUSTED_PROXIES", "1")!),
    insecureDev,
    fcm,
    livekit,
    ...(apns ? { apns } : {}),
    ...(apnsGateway ? { apnsGateway } : {}),
    ...(gatewayMode ? { pushGateway: { key: env("AGENTRING_GATEWAY_KEY") } } : {}),
  };
}

export function dbPath(cfg: Config): string {
  return cfg.dataDir === ":memory:" ? ":memory:" : join(cfg.dataDir, "relay.db");
}
