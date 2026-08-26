import type { SQL } from "bun";
import { Client } from "pg";

const CHANNEL = "toj_account_security_events";
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type AccountSecurityEvent = {
  accountId: string;
  reason: "banned" | "deleted";
};

/** PostgreSQL publishes this only if the surrounding account mutation commits. */
export async function notifyAccountSecurityEvent(
  sql: SQL,
  event: AccountSecurityEvent,
): Promise<void> {
  await sql`SELECT pg_notify(${CHANNEL}, ${JSON.stringify(event)})`;
}

/** Disconnects sessions on every server process, including bans issued by the operator CLI. */
export function startAccountSecurityEventListener(
  databaseUrl: string | null,
  onEvent: (event: AccountSecurityEvent) => void | Promise<void>,
  lifecycle: {
    onReady?: () => void | Promise<void>;
    onUnavailable?: () => void | Promise<void>;
  } = {},
): () => void {
  if (!databaseUrl) {
    void lifecycle.onUnavailable?.();
    return () => {};
  }
  let stopped = false;
  let client: Client | null = null;
  let retry: ReturnType<typeof setTimeout> | null = null;
  let heartbeat: ReturnType<typeof setInterval> | null = null;
  let attempts = 0;

  const schedule = () => {
    if (stopped || retry) return;
    const delay = Math.min(30_000, 500 * 2 ** Math.min(attempts, 6));
    attempts += 1;
    retry = setTimeout(() => { retry = null; void connect(); }, delay);
    retry.unref?.();
  };
  const connect = async () => {
    if (stopped) return;
    const next = new Client({
      connectionString: databaseUrl,
      application_name: "toj-account-security-notify",
    });
    client = next;
    next.on("notification", (notification) => {
      if (notification.channel !== CHANNEL || !notification.payload) return;
      try {
        const event = JSON.parse(notification.payload) as AccountSecurityEvent;
        if (!UUID_PATTERN.test(event.accountId)
          || (event.reason !== "banned" && event.reason !== "deleted")) return;
        void onEvent(event);
      } catch { /* notifications are hints; database authorization remains authoritative */ }
    });
    let handledDisconnect = false;
    const disconnected = () => {
      if (handledDisconnect) return;
      handledDisconnect = true;
      if (client !== next) return;
      client = null;
      if (heartbeat) clearInterval(heartbeat);
      heartbeat = null;
      void lifecycle.onUnavailable?.();
      schedule();
    };
    next.once("error", disconnected);
    next.once("end", disconnected);
    try {
      await next.connect();
      await next.query(`LISTEN ${CHANNEL}`);
      heartbeat = setInterval(() => {
        next.query("SELECT 1").catch(() => disconnected());
      }, 10_000);
      heartbeat.unref?.();
      await lifecycle.onReady?.();
      attempts = 0;
    } catch {
      try { await next.end(); } catch { /* already closed */ }
      disconnected();
    }
  };
  void connect();
  return () => {
    stopped = true;
    if (retry) clearTimeout(retry);
    retry = null;
    if (heartbeat) clearInterval(heartbeat);
    heartbeat = null;
    if (client) void client.end().catch(() => {});
    client = null;
  };
}
