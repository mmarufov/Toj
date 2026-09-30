// Toj M1 dev relay — routes opaque E2E ciphertext envelopes between devices.
// Throwaway by design (the real backend is Elixir/Phoenix, milestone 3+).
// It logs METADATA ONLY (users, ids, byte sizes) — never payload contents.

export type Envelope = {
  v: number;
  type: "msg" | "ack";
  id: string;
  from: string;
  to: string;
  payloadType?: number;
  payload?: string; // base64 ciphertext, opaque to the relay
  ts: number;
};

type SocketData = { user: string };

const USER_RE = /^\/v1\/keys\/([A-Za-z0-9_.-]{1,64})$/;

export function startRelay(port: number) {
  const sockets = new Map<string, Bun.ServerWebSocket<SocketData>>();
  const queues = new Map<string, Envelope[]>(); // offline queue per recipient
  const bundles = new Map<string, string>(); // published prekey bundles (opaque JSON)
  const delivered = new Map<string, Set<string>>(); // reconnect-resend dedupe

  const log = (...args: unknown[]) => console.log(new Date().toISOString(), ...args);

  const deliver = (env: Envelope) => {
    const ws = sockets.get(env.to);
    if (ws && ws.readyState === 1) {
      ws.send(JSON.stringify(env));
      log("deliver", `${env.from}->${env.to}`, env.id);
    } else {
      const q = queues.get(env.to) ?? [];
      q.push(env);
      queues.set(env.to, q);
      log("queue", `${env.from}->${env.to}`, env.id, `depth=${q.length}`);
    }
  };

  const server = Bun.serve<SocketData>({
    port,
    fetch(req, server) {
      const url = new URL(req.url);
      if (url.pathname === "/health") return new Response("ok");

      const keys = url.pathname.match(USER_RE);
      if (keys) {
        const user = keys[1];
        if (req.method === "PUT") {
          return req.text().then((body) => {
            bundles.set(user, body);
            log("keys.put", user, `${body.length}b`);
            return new Response("ok");
          });
        }
        if (req.method === "GET") {
          const bundle = bundles.get(user);
          log("keys.get", user, bundle ? "hit" : "miss");
          return bundle
            ? new Response(bundle, { headers: { "content-type": "application/json" } })
            : new Response("not found", { status: 404 });
        }
      }

      if (url.pathname === "/v1/ws") {
        const user = url.searchParams.get("user");
        if (!user || !/^[A-Za-z0-9_.-]{1,64}$/.test(user)) {
          return new Response("valid user required", { status: 400 });
        }
        if (server.upgrade(req, { data: { user } })) return undefined;
        return new Response("upgrade failed", { status: 400 });
      }

      return new Response("not found", { status: 404 });
    },
    websocket: {
      open(ws) {
        sockets.set(ws.data.user, ws);
        log("ws.open", ws.data.user);
        const q = queues.get(ws.data.user) ?? [];
        queues.delete(ws.data.user);
        for (const env of q) deliver(env);
      },
      close(ws) {
        if (sockets.get(ws.data.user) === ws) sockets.delete(ws.data.user);
        log("ws.close", ws.data.user);
      },
      message(ws, raw) {
        let env: Envelope;
        try {
          env = JSON.parse(String(raw));
        } catch {
          return;
        }
        if (env?.type !== "msg" || !env.id || !env.to || env.from !== ws.data.user) return;

        // Ack immediately: the client resends anything unacked after reconnects.
        const ack: Envelope = { v: 1, type: "ack", id: env.id, from: "server", to: env.from, ts: Date.now() };
        ws.send(JSON.stringify(ack));

        const seen = delivered.get(env.to) ?? new Set<string>();
        if (seen.has(env.id)) {
          log("dupe", env.id);
          return;
        }
        seen.add(env.id);
        if (seen.size > 5000) seen.clear();
        delivered.set(env.to, seen);

        log("msg", `${env.from}->${env.to}`, env.id, `${(env.payload ?? "").length}b`);
        deliver(env);
      },
    },
  });

  log(`relay listening on :${server.port}`);
  return server;
}
