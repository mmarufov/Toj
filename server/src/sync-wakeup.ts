import type { SQL } from "bun";

export type SyncPush = {
  accountId: string;
  pts: number;
  ptsCount: number;
};

export const SYNC_NOTIFY_CHANNEL = "toj_sync_events";

/**
 * PostgreSQL delivers notifications only when the surrounding transaction commits. Keeping this
 * beside the account-event write prevents a successful mutation from returning before its
 * cross-process wake-up is durable.
 */
export async function notifySyncWakeups(sql: SQL, pushes: SyncPush[]): Promise<void> {
  const coalesced = new Map<string, SyncPush>();
  for (const push of pushes) {
    const current = coalesced.get(push.accountId);
    if (!current || push.pts > current.pts) coalesced.set(push.accountId, push);
  }
  const payloads = [...coalesced.values()]
    .sort((a, b) => a.accountId.localeCompare(b.accountId))
    .map((push) => JSON.stringify(push));
  if (payloads.length === 0) return;
  // One statement for every recipient, so a group send costs the same round trips at any size.
  await sql`
    SELECT pg_notify(${SYNC_NOTIFY_CHANNEL}, wakeup.payload)
    FROM unnest(${sql.array(payloads, "text")}::text[]) WITH ORDINALITY AS wakeup(payload, position)
    ORDER BY wakeup.position`;
}

export function isSyncWakeupChannel(channel: string): boolean {
  return channel === SYNC_NOTIFY_CHANNEL;
}
