import { describe, expect, test } from "bun:test";
import { clientNetworkAddress, startCloudServer } from "./cloud";
import { makeSql } from "./db";

const db = makeSql(process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test");

// Header shapes recorded from a Render web service on 2026-09-30 (docs/results/step1-hardening.md).
// Render's proxy is the socket peer; Cloudflare sits in front of it.
const RENDER_PEER = "10.25.18.179";
const CLIENT = "198.51.100.23";
const CLOUDFLARE_EDGE = "162.159.115.23";

function renderHeaders(clientSupplied: Record<string, string> = {}): Headers {
  const spoofedChain = clientSupplied["x-forwarded-for"];
  return new Headers({
    "cf-connecting-ip": CLIENT,
    "true-client-ip": CLIENT,
    // Cloudflare and Render append; nothing on the path removes what the client sent.
    "x-forwarded-for": [spoofedChain, CLIENT, CLOUDFLARE_EDGE, RENDER_PEER].filter(Boolean).join(", "),
  });
}

describe("client network address", () => {
  test("the edge header distinguishes clients that share one proxy peer", () => {
    const env = { TOJ_CLIENT_IP_HEADER: "cf-connecting-ip" };
    const other = new Headers({ "cf-connecting-ip": "203.0.113.200" });
    expect(clientNetworkAddress(renderHeaders(), RENDER_PEER, env)).toBe(CLIENT);
    expect(clientNetworkAddress(other, RENDER_PEER, env)).toBe("203.0.113.200");
  });

  test("a client-supplied forwarding chain never chooses the key", () => {
    const spoof = renderHeaders({ "x-forwarded-for": "203.0.113.7" });
    expect(clientNetworkAddress(spoof, RENDER_PEER, { TOJ_CLIENT_IP_HEADER: "cf-connecting-ip" })).toBe(CLIENT);
    // One trusted proxy: only its own (rightmost) entry counts, never the leftmost.
    const single = new Headers({ "x-forwarded-for": "203.0.113.7, 198.51.100.40" });
    expect(clientNetworkAddress(single, "10.0.0.2", { TOJ_TRUST_PROXY: "1" })).toBe("198.51.100.40");
  });

  test("a missing or malformed header falls back to the shared peer, never to client input", () => {
    const env = { TOJ_CLIENT_IP_HEADER: "cf-connecting-ip" };
    expect(clientNetworkAddress(new Headers(), RENDER_PEER, env)).toBe(RENDER_PEER);
    for (const value of ["1.2.3", "0x7f.0.0.1", "not-an-ip", "198.51.100.23, 203.0.113.7", ""]) {
      expect(clientNetworkAddress(new Headers({ "cf-connecting-ip": value }), RENDER_PEER, env))
        .toBe(RENDER_PEER);
    }
  });

  test("addresses are canonicalised so one client cannot occupy several keys", () => {
    const env = { TOJ_CLIENT_IP_HEADER: "cf-connecting-ip" };
    expect(clientNetworkAddress(new Headers({ "cf-connecting-ip": "::ffff:198.51.100.23" }), null, env))
      .toBe(CLIENT);
    expect(clientNetworkAddress(new Headers({ "cf-connecting-ip": "2001:DB8:0:0::1" }), null, env))
      .toBe("2001:db8::1");
  });

  test("with nothing configured the socket peer is the key and headers are ignored", () => {
    expect(clientNetworkAddress(renderHeaders(), RENDER_PEER, {})).toBe(RENDER_PEER);
  });
});

describe("per-network OTP window behind a shared proxy", () => {
  test("one client exhausting its window does not block another client on the same proxy", async () => {
    await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
    const original = process.env.TOJ_CLIENT_IP_HEADER;
    process.env.TOJ_CLIENT_IP_HEADER = "cf-connecting-ip";
    // Every request reaches the server from the same socket peer, as it does behind Render.
    const server = startCloudServer(0, db, null, null, { backgroundWorkers: false });
    const start = async (phoneSuffix: number, client: string) =>
      await fetch(`http://127.0.0.1:${server.port}/v1/auth/start`, {
        method: "POST",
        headers: { "content-type": "application/json", "cf-connecting-ip": client },
        body: JSON.stringify({ phone: `+1650555${String(7200 + phoneSuffix).padStart(4, "0")}` }),
      });
    try {
      // 20 requests per 15 minutes per network (auth.ts OTP_NETWORK_WINDOW_LIMIT). One number per
      // request, so neither the per-phone window nor the resend cooldown is what trips.
      for (let i = 0; i < 20; i += 1) {
        expect((await start(i, "198.51.100.23")).status).toBe(200);
      }
      expect((await start(20, "198.51.100.23")).status).toBe(429);
      expect((await start(21, "203.0.113.200")).status).toBe(200);
    } finally {
      await server.stop(true);
      if (original == null) delete process.env.TOJ_CLIENT_IP_HEADER;
      else process.env.TOJ_CLIENT_IP_HEADER = original;
    }
  });
});
