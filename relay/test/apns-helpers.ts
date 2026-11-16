import { generateKeyPairSync, type KeyObject } from "node:crypto";
import http2 from "node:http2";
import type { AddressInfo } from "node:net";

export function apnsKey(): { privateKey: KeyObject; publicKey: KeyObject; pem: string } {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  return { privateKey, publicKey, pem: privateKey.export({ type: "pkcs8", format: "pem" }).toString() };
}

interface Received {
  headers: http2.IncomingHttpHeaders;
  body: string;
}

/** A plain HTTP/2 (h2c) server standing in for APNs. */
export async function startFakeApns(respond: (r: Received, n: number) => { status: number; body?: object } = () => ({ status: 200 })) {
  const received: Received[] = [];
  const sessions = new Set<http2.ServerHttp2Session>();
  const server = http2.createServer();
  server.on("session", (s) => {
    sessions.add(s);
    s.on("close", () => sessions.delete(s));
  });
  server.on("stream", (stream, headers) => {
    const chunks: Buffer[] = [];
    stream.on("data", (c: Buffer) => chunks.push(c));
    stream.on("end", () => {
      const r = { headers, body: Buffer.concat(chunks).toString("utf8") };
      received.push(r);
      const out = respond(r, received.length);
      stream.respond({ ":status": out.status, "apns-id": "11111111-2222-3333-4444-555555555555" });
      stream.end(out.body ? JSON.stringify(out.body) : undefined);
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const close = async () => {
    for (const s of sessions) s.destroy();
    await new Promise((r) => server.close(r));
  };
  return { url, received, sessions, close };
}

