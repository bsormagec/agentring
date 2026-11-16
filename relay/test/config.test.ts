import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";

const saved = { ...process.env };
afterEach(() => {
  process.env = { ...saved };
});

function baseEnv() {
  process.env.AGENTRING_PUBLIC_URL = "https://relay.test";
  process.env.AGENTRING_DATA_DIR = ":memory:";
  delete process.env.LIVEKIT_API_KEY;
  delete process.env.LIVEKIT_API_SECRET;
  delete process.env.LIVEKIT_API_SECRET_FILE;
  delete process.env.LIVEKIT_URL;
  delete process.env.LIVEKIT_API_URL;
  for (const k of Object.keys(process.env)) {
    if (k.startsWith("AGENTRING_APNS_") || k === "AGENTRING_PUSH_GATEWAY" || k === "AGENTRING_GATEWAY_KEY" || k === "AGENTRING_INSECURE_DEV") {
      delete process.env[k];
    }
  }
}

describe("LiveKit config", () => {
  it("reads the secret from a file and defaults the URLs to the relay's host", () => {
    baseEnv();
    const dir = mkdtempSync(join(tmpdir(), "agentring-"));
    writeFileSync(join(dir, "secret"), "s".repeat(40) + "\n");
    process.env.LIVEKIT_API_KEY = "lk_test";
    process.env.LIVEKIT_API_SECRET_FILE = join(dir, "secret");
    const lk = loadConfig().livekit!;
    expect(lk.apiSecret).toBe("s".repeat(40));
    expect(lk.publicUrl).toBe("wss://relay.test");
    expect(lk.apiUrl).toBe("https://relay.test");
  });

  it("rejects weak or half-configured secrets and leaves calls off without LiveKit", () => {
    baseEnv();
    expect(loadConfig().livekit).toBeUndefined();
    process.env.LIVEKIT_API_KEY = "lk_test";
    expect(() => loadConfig()).toThrow(/LIVEKIT_API_SECRET/);
    process.env.LIVEKIT_API_SECRET = "short";
    expect(() => loadConfig()).toThrow(/at least 32/);
  });
});

describe("APNs config", () => {
  const pem = () =>
    generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey.export({ type: "pkcs8", format: "pem" }).toString();

  it("reads the .p8 key from a file or inline (escaped newlines), with key id, team id and topic", () => {
    baseEnv();
    expect(loadConfig().apns).toBeUndefined();
    const dir = mkdtempSync(join(tmpdir(), "agentring-"));
    const key = pem();
    writeFileSync(join(dir, "AuthKey.p8"), key);
    process.env.AGENTRING_APNS_KEY_FILE = join(dir, "AuthKey.p8");
    process.env.AGENTRING_APNS_KEY_ID = "ABC123DEFG";
    process.env.AGENTRING_APNS_TEAM_ID = "TEAM123456";
    expect(loadConfig().apns).toEqual({ key, keyId: "ABC123DEFG", teamId: "TEAM123456", topic: "dev.agentring.app" });

    delete process.env.AGENTRING_APNS_KEY_FILE;
    process.env.AGENTRING_APNS_KEY = key.replace(/\n/g, "\\n");
    process.env.AGENTRING_APNS_TOPIC = "com.example.agentring";
    expect(loadConfig().apns).toMatchObject({ key, topic: "com.example.agentring" });
  });

  it("rejects half-configured or invalid APNs settings", () => {
    baseEnv();
    process.env.AGENTRING_APNS_KEY_ID = "ABC123DEFG";
    expect(() => loadConfig()).toThrow(/AGENTRING_APNS_KEY_FILE/);
    process.env.AGENTRING_APNS_TEAM_ID = "TEAM123456";
    process.env.AGENTRING_APNS_KEY = "not a key";
    expect(() => loadConfig()).toThrow(/not a valid .p8/);
    process.env.AGENTRING_APNS_KEY = generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey.export({ type: "pkcs8", format: "pem" }).toString();
    expect(() => loadConfig()).toThrow(/EC P-256/);
    process.env.AGENTRING_APNS_KEY = pem();
    process.env.AGENTRING_APNS_KEY_ID = "short";
    expect(() => loadConfig()).toThrow(/KEY_ID/);
    process.env.AGENTRING_APNS_KEY_ID = "ABC123DEFG";
    process.env.AGENTRING_APNS_HOST = "http://127.0.0.1:9";
    expect(() => loadConfig()).toThrow(/AGENTRING_APNS_HOST/);
    process.env.AGENTRING_INSECURE_DEV = "1";
    expect(loadConfig().apns?.host).toBe("http://127.0.0.1:9");
  });

  it("configures the push gateway client, and gateway mode needs the APNs key", () => {
    baseEnv();
    process.env.AGENTRING_APNS_GATEWAY_URL = "http://push.example";
    expect(() => loadConfig()).toThrow(/https/);
    process.env.AGENTRING_APNS_GATEWAY_URL = "https://push.example/";
    expect(loadConfig().apnsGateway).toEqual({ url: "https://push.example", topic: "dev.agentring.app" });

    baseEnv();
    process.env.AGENTRING_PUSH_GATEWAY = "1";
    process.env.AGENTRING_PUBLIC_URL = "http://localhost:8080";
    expect(() => loadConfig()).toThrow(/needs the APNs key/);
    process.env.AGENTRING_APNS_KEY = pem();
    process.env.AGENTRING_APNS_KEY_ID = "ABC123DEFG";
    process.env.AGENTRING_APNS_TEAM_ID = "TEAM123456";
    process.env.AGENTRING_GATEWAY_KEY = "k";
    expect(loadConfig().pushGateway).toEqual({ key: "k" });
  });
});
