import { createHash, randomUUID } from "node:crypto";
import { Client } from "pg";
import type { SQL } from "bun";
import { requireActiveDevice } from "./auth";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const PRESENCE_NOTIFY_CHANNEL = "toj_presence_events";
const PRESENCE_LEASE_SECONDS = 60;
const TYPING_EXPIRES_MS = 7_000;
const RECIPIENT_CHUNK_SIZE = 100;

const runtimeMetrics = {
  transitions: 0,
  typingPublications: 0,
  notificationFailures: 0,
  rejectedFrames: new Map<string, number>(),
};
const renderedMetricsCache = new WeakMap<object, { expiresAt: number; value: string }>();

export function recordPresenceRejectedFrame(
  reason: "malformed" | "oversized" | "unsupported" | "unauthorized" | "rate_limited",
): void {
  runtimeMetrics.rejectedFrames.set(reason, (runtimeMetrics.rejectedFrames.get(reason) ?? 0) + 1);
}

export function validPresenceDialogId(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

export class PresenceError extends Error {
  constructor(
    message: string,
    readonly code = "invalid_request",
    readonly status = 400,
  ) {
    super(message);
    this.name = "PresenceError";
  }
}

export type PresenceSnapshot = {
  accountId: string;
  online: boolean;
  lastSeenAt: string | null;
  revision: number;
};

export type PresenceSocketEvent =
  | ({ type: "presence_update" } & PresenceSnapshot)
  | { type: "presence_visibility"; accountId: string; visible: boolean }
  | { type: "session_revoked"; deviceId: string | null; reason: string }
  | {
      type: "typing_update";
      dialogId: string;
      actorAccountId: string;
      typingSessionId: string;
      active: boolean;
      expiresInMs: number;
    };

export type PresenceBroadcast = {
  /** Identifies one publication so an origin node can suppress only its PostgreSQL echo. */
  deliveryId?: string;
  recipientAccountIds: string[];
  event: PresenceSocketEvent;
};

type PresenceInput = {
  accountId: string;
  deviceId: string;
  connectionId: string;
  connectionEpoch?: string;
  active: boolean;
  allowRevokedCleanup?: boolean;
};

type TypingInput = {
  accountId: string;
  deviceId: string;
  dialogId: string;
  typingSessionId: string;
  active: boolean;
  allowRevokedCleanup?: boolean;
};

const iso = (value: unknown): string | null => {
  if (value == null) return null;
  return value instanceof Date ? value.toISOString() : new Date(String(value)).toISOString();
};

export function presenceConfigured(): boolean {
  return process.env.TOJ_PRESENCE_V1_ENABLED === "1";
}

/** Stable per-account rollout. The global switch is always the outer kill switch. */
export function presenceEnabledForAccount(accountId: string): boolean {
  if (!presenceConfigured()) return false;
  const normalized = accountId.trim().toLowerCase();
  const allowlist = new Set((process.env.TOJ_PRESENCE_ALLOWLIST ?? "")
    .split(",").map((value) => value.trim().toLowerCase()).filter(Boolean));
  if (allowlist.has(normalized)) return true;
  const percent = Number(process.env.TOJ_PRESENCE_ROLLOUT_PERCENT ?? "0");
  if (!Number.isFinite(percent) || percent <= 0) return false;
  if (percent >= 100) return true;
  const digest = createHash("sha256")
    .update(`toj-presence-rollout-v1|${normalized}`)
    .digest();
  return digest.readUInt32BE(0) / 0x1_0000_0000 * 100 < percent;
}

export async function presenceSchemaReadiness(
  sql: SQL,
): Promise<{ ready: boolean; missing: string[] }> {
  const row = (await sql`
    SELECT
      to_regclass('public.account_presence') IS NOT NULL AS account_presence,
      to_regclass('public.device_presence_leases') IS NOT NULL AS device_presence_leases,
      (SELECT count(*) = 4
       FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'account_presence'
         AND ((column_name = 'account_id' AND data_type = 'uuid' AND is_nullable = 'NO')
           OR (column_name = 'last_seen_at' AND data_type = 'timestamp with time zone'
               AND is_nullable = 'YES')
           OR (column_name = 'revision' AND data_type = 'bigint' AND is_nullable = 'NO')
           OR (column_name = 'updated_at' AND data_type = 'timestamp with time zone'
               AND is_nullable = 'NO'))) AS account_columns,
      (SELECT count(*) = 6
       FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'device_presence_leases'
         AND ((column_name = 'device_id' AND data_type = 'uuid' AND is_nullable = 'NO')
           OR (column_name = 'account_id' AND data_type = 'uuid' AND is_nullable = 'NO')
           OR (column_name = 'connection_id' AND data_type = 'uuid' AND is_nullable = 'NO')
           OR (column_name = 'connection_epoch' AND data_type = 'bigint' AND is_nullable = 'NO')
           OR (column_name = 'last_heartbeat_at' AND data_type = 'timestamp with time zone'
               AND is_nullable = 'NO')
           OR (column_name = 'expires_at' AND data_type = 'timestamp with time zone'
               AND is_nullable = 'NO'))) AS lease_columns,
      EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = to_regclass('public.account_presence') AND contype = 'p'
      ) AS account_primary_key,
      EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = to_regclass('public.device_presence_leases') AND contype = 'p'
      ) AS lease_primary_key,
      to_regclass('public.device_presence_leases_account_expiry_idx') IS NOT NULL AS account_index,
      to_regclass('public.device_presence_leases_expiry_idx') IS NOT NULL AS expiry_index,
      to_regclass('public.presence_connection_epoch_seq') IS NOT NULL AS connection_epoch_sequence,
      EXISTS (SELECT 1 FROM schema_migrations WHERE name = 'presence-v1-expand') AS marker`)[0] ?? {};
  const checks: [string, boolean][] = [
    ["account_presence", Boolean(row.account_presence)],
    ["device_presence_leases", Boolean(row.device_presence_leases)],
    ["account_presence_columns", Boolean(row.account_columns)],
    ["device_presence_leases_columns", Boolean(row.lease_columns)],
    ["account_presence_primary_key", Boolean(row.account_primary_key)],
    ["device_presence_leases_primary_key", Boolean(row.lease_primary_key)],
    ["device_presence_leases_account_expiry_idx", Boolean(row.account_index)],
    ["device_presence_leases_expiry_idx", Boolean(row.expiry_index)],
    ["presence_connection_epoch_seq", Boolean(row.connection_epoch_sequence)],
    ["presence-v1-expand", Boolean(row.marker)],
  ];
  const missing = checks.filter(([, ready]) => !ready).map(([name]) => name);
  return { ready: missing.length === 0, missing };
}

export async function nextPresenceConnectionEpoch(sql: SQL): Promise<string> {
  return String((await sql`
    SELECT nextval('presence_connection_epoch_seq')::text AS epoch`)[0].epoch);
}

async function authorizedPresenceRecipients(sql: SQL, subjectAccountId: string): Promise<string[]> {
  const rows = await sql`
    SELECT DISTINCT peer.account_id
    FROM dialogs dialog
    JOIN dialog_members subject
      ON subject.dialog_id = dialog.id
     AND subject.account_id = ${subjectAccountId}
     AND subject.left_at IS NULL
    JOIN dialog_members peer
      ON peer.dialog_id = dialog.id
     AND peer.account_id <> ${subjectAccountId}
     AND peer.left_at IS NULL
    WHERE dialog.type = 'direct' AND dialog.closed_at IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM account_blocks block
        WHERE (block.blocker_account_id = ${subjectAccountId}
               AND block.blocked_account_id = peer.account_id)
           OR (block.blocker_account_id = peer.account_id
               AND block.blocked_account_id = ${subjectAccountId})
      )
    ORDER BY peer.account_id`;
  return rows.map((row: any) => String(row.account_id));
}

async function notifyBroadcasts(sql: SQL, broadcasts: PresenceBroadcast[]): Promise<void> {
  const payloads: string[] = [];
  for (const broadcast of broadcasts) {
    for (let index = 0; index < broadcast.recipientAccountIds.length; index += RECIPIENT_CHUNK_SIZE) {
      payloads.push(JSON.stringify({
        deliveryId: broadcast.deliveryId,
        recipientAccountIds: broadcast.recipientAccountIds.slice(index, index + RECIPIENT_CHUNK_SIZE),
        event: broadcast.event,
      }));
    }
  }
  if (payloads.length === 0) return;
  try {
    await sql`
      SELECT pg_notify(${PRESENCE_NOTIFY_CHANNEL}, payload)
      FROM unnest(${sql.array(payloads, "text")}::text[]) AS payload`;
  } catch (error) {
    runtimeMetrics.notificationFailures += 1;
    throw error;
  }
}

/** Best-effort cross-node control plane for credentials invalidated after WebSocket upgrade. */
export async function publishPresenceSessionRevocation(
  sql: SQL,
  accountId: string,
  deviceId: string | null,
  reason: "device_revoked" | "account_deleted",
): Promise<void> {
  await notifyBroadcasts(sql, [{
    deliveryId: randomUUID(),
    recipientAccountIds: [accountId],
    event: { type: "session_revoked", deviceId, reason },
  }]);
}

async function transitionBroadcast(
  sql: SQL,
  subjectAccountId: string,
  online: boolean,
  lastSeenAt: string | null,
  revision: number,
): Promise<PresenceBroadcast[]> {
  const recipients = (await authorizedPresenceRecipients(sql, subjectAccountId))
    .filter(presenceEnabledForAccount);
  if (recipients.length === 0) return [];
  return [{
    deliveryId: randomUUID(),
    recipientAccountIds: recipients,
    event: { type: "presence_update", accountId: subjectAccountId, online, lastSeenAt, revision },
  }];
}

async function setPresenceActivityTx(
  tx: SQL,
  input: PresenceInput,
  alreadyAuthorized = false,
): Promise<PresenceBroadcast[]> {
  if (input.active) {
    if (!presenceEnabledForAccount(input.accountId)) return [];
    if (!alreadyAuthorized) {
      await requireActiveDevice(tx, input.accountId, input.deviceId);
    }
    await tx`
      INSERT INTO account_presence(account_id)
      VALUES (${input.accountId})
      ON CONFLICT (account_id) DO NOTHING`;
    await tx`
      SELECT last_seen_at, revision
      FROM account_presence
      WHERE account_id = ${input.accountId}
      FOR UPDATE`;
    const wasOnline = (await tx`
      SELECT EXISTS(
        SELECT 1 FROM device_presence_leases
        WHERE account_id = ${input.accountId} AND expires_at > now()
      ) AS online`)[0]?.online === true;

    const connectionEpoch = input.connectionEpoch ?? await nextPresenceConnectionEpoch(tx);
    const acquired = await tx`
      INSERT INTO device_presence_leases(
        device_id, account_id, connection_id, connection_epoch, last_heartbeat_at, expires_at
      ) VALUES (
        ${input.deviceId}, ${input.accountId}, ${input.connectionId}, ${connectionEpoch}::bigint, now(),
        now() + ${PRESENCE_LEASE_SECONDS} * interval '1 second'
      )
      ON CONFLICT (device_id) DO UPDATE SET
        account_id = excluded.account_id,
        connection_id = excluded.connection_id,
        connection_epoch = excluded.connection_epoch,
        last_heartbeat_at = excluded.last_heartbeat_at,
        expires_at = excluded.expires_at
      WHERE device_presence_leases.connection_id = excluded.connection_id
         OR device_presence_leases.connection_epoch < excluded.connection_epoch
      RETURNING connection_id`;
    if (acquired.length === 0) {
      throw new PresenceError(
        "presence connection was superseded", "stale_presence_connection", 409,
      );
    }
    if (wasOnline) return [];
    const updated = (await tx`
      UPDATE account_presence
      SET revision = revision + 1, updated_at = now()
      WHERE account_id = ${input.accountId}
      RETURNING last_seen_at, revision`)[0];
    runtimeMetrics.transitions += 1;
    const broadcasts = await transitionBroadcast(
      tx, input.accountId, true, iso(updated.last_seen_at), Number(updated.revision),
    );
    await notifyBroadcasts(tx, broadcasts);
    return broadcasts;
  }

    if (!input.allowRevokedCleanup && !alreadyAuthorized) {
      await requireActiveDevice(tx, input.accountId, input.deviceId);
    }

    // Deactivation is cleanup, so it must continue to work after rollout is disabled or the
    // credential has already been revoked. Lock the per-account state before deleting a lease so
    // concurrent device disconnects cannot both miss the final offline transition.
    const state = (await tx`
      SELECT last_seen_at, revision
      FROM account_presence
      WHERE account_id = ${input.accountId}
      FOR UPDATE`)[0];
    const removed = await tx`
      DELETE FROM device_presence_leases
      WHERE device_id = ${input.deviceId}
        AND account_id = ${input.accountId}
        AND connection_id = ${input.connectionId}
      RETURNING device_id`;
    if (removed.length === 0) return [];
    if (!state) return [];
    const remainsOnline = (await tx`
      SELECT EXISTS(
        SELECT 1 FROM device_presence_leases
        WHERE account_id = ${input.accountId} AND expires_at > now()
      ) AS online`)[0]?.online === true;
    if (remainsOnline) return [];
    const updated = (await tx`
      UPDATE account_presence
      SET last_seen_at = now(), revision = revision + 1, updated_at = now()
      WHERE account_id = ${input.accountId}
        AND EXISTS (
          SELECT 1 FROM accounts
          WHERE id = ${input.accountId} AND status IN ('active','limited')
        )
      RETURNING last_seen_at, revision`)[0];
    if (!updated) return [];
    runtimeMetrics.transitions += 1;
    const broadcasts = await transitionBroadcast(
      tx, input.accountId, false, iso(updated.last_seen_at), Number(updated.revision),
    );
    await notifyBroadcasts(tx, broadcasts);
    return broadcasts;
}

export async function setPresenceActivity(sql: SQL, input: PresenceInput): Promise<PresenceBroadcast[]> {
  if (input.active && !presenceEnabledForAccount(input.accountId)) return [];
  return await sql.begin(async (tx) => {
    return await setPresenceActivityTx(tx, input);
  });
}

/** Removes every lease owned by a revoked device in the caller's revocation transaction. */
export async function revokeDevicePresence(
  tx: SQL,
  accountId: string,
  deviceId: string,
): Promise<PresenceBroadcast[]> {
  const schema = (await tx`
    SELECT to_regclass('public.account_presence') IS NOT NULL AS account_presence,
           to_regclass('public.device_presence_leases') IS NOT NULL AS leases`)[0];
  if (schema?.account_presence !== true || schema?.leases !== true) return [];
  const state = (await tx`
    SELECT revision FROM account_presence
    WHERE account_id = ${accountId}
    FOR UPDATE`)[0];
  const removed = await tx`
    DELETE FROM device_presence_leases
    WHERE account_id = ${accountId} AND device_id = ${deviceId}
    RETURNING device_id`;
  if (removed.length === 0 || !state) return [];
  const remainsOnline = (await tx`
    SELECT EXISTS(
      SELECT 1 FROM device_presence_leases
      WHERE account_id = ${accountId} AND expires_at > now()
    ) AS online`)[0]?.online === true;
  if (remainsOnline) return [];
  const updated = (await tx`
    UPDATE account_presence
    SET last_seen_at = now(), revision = revision + 1, updated_at = now()
    WHERE account_id = ${accountId}
    RETURNING last_seen_at, revision`)[0];
  if (!updated) return [];
  runtimeMetrics.transitions += 1;
  const broadcasts = await transitionBroadcast(
    tx, accountId, false, iso(updated.last_seen_at), Number(updated.revision),
  );
  await notifyBroadcasts(tx, broadcasts);
  return broadcasts;
}

/** Publishes the terminal account state before privacy cleanup erases its exact-presence rows. */
export async function revokeAccountPresence(
  tx: SQL,
  accountId: string,
): Promise<PresenceBroadcast[]> {
  const schema = (await tx`
    SELECT to_regclass('public.account_presence') IS NOT NULL AS account_presence,
           to_regclass('public.device_presence_leases') IS NOT NULL AS leases`)[0];
  if (schema?.account_presence !== true || schema?.leases !== true) return [];
  const recipients = (await authorizedPresenceRecipients(tx, accountId))
    .filter(presenceEnabledForAccount);
  const state = (await tx`
    SELECT revision FROM account_presence
    WHERE account_id = ${accountId}
    FOR UPDATE`)[0];
  const wasOnline = (await tx`
    SELECT EXISTS(
      SELECT 1 FROM device_presence_leases
      WHERE account_id = ${accountId} AND expires_at > now()
    ) AS online`)[0]?.online === true;
  await tx`DELETE FROM device_presence_leases WHERE account_id = ${accountId}`;

  const broadcasts: PresenceBroadcast[] = [];
  if (state && wasOnline) {
    const updated = (await tx`
      UPDATE account_presence
      SET last_seen_at = now(), revision = revision + 1, updated_at = now()
      WHERE account_id = ${accountId}
      RETURNING last_seen_at, revision`)[0];
    if (updated && recipients.length > 0) {
      runtimeMetrics.transitions += 1;
      broadcasts.push({
        deliveryId: randomUUID(),
        recipientAccountIds: recipients,
        event: {
          type: "presence_update",
          accountId,
          online: false,
          lastSeenAt: iso(updated.last_seen_at),
          revision: Number(updated.revision),
        },
      });
    }
  }
  if (recipients.length > 0) {
    broadcasts.push({
      deliveryId: randomUUID(),
      recipientAccountIds: recipients,
      event: { type: "presence_visibility", accountId, visible: false },
    });
  }
  await notifyBroadcasts(tx, broadcasts);
  return broadcasts;
}

export async function heartbeatPresence(
  sql: SQL,
  input: Omit<PresenceInput, "active">,
): Promise<PresenceBroadcast[]> {
  if (!presenceEnabledForAccount(input.accountId)) return [];
  return await sql.begin(async (tx) => {
    await requireActiveDevice(tx, input.accountId, input.deviceId);
    const updated = await tx`
      UPDATE device_presence_leases
      SET last_heartbeat_at = now(),
          expires_at = now() + ${PRESENCE_LEASE_SECONDS} * interval '1 second'
      WHERE device_id = ${input.deviceId}
        AND account_id = ${input.accountId}
        AND connection_id = ${input.connectionId}
        AND expires_at > now()
      RETURNING device_id`;
    if (updated.length > 0) return [];
    // A delayed heartbeat may race lease expiry, but it must never steal a newer connection's
    // lease for the same device.
    const replacement = await tx`
      SELECT connection_id, expires_at <= now() AS expired
      FROM device_presence_leases
      WHERE device_id = ${input.deviceId} AND account_id = ${input.accountId}
      FOR UPDATE`;
    if (replacement.length > 0
      && String(replacement[0].connection_id) !== input.connectionId) return [];
    return await setPresenceActivityTx(tx, { ...input, active: true }, true);
  });
}

export async function expirePresenceLeases(
  sql: SQL,
  limit = 500,
): Promise<PresenceBroadcast[]> {
  const boundedLimit = Math.max(1, Math.min(5_000, limit));
  return await sql.begin(async (tx) => {
    // Every application node may run the timer, but only one claims an expiry batch. The lock is
    // transaction-scoped and therefore releases on success, error, or process loss.
    const claimed = (await tx`
      SELECT pg_try_advisory_xact_lock(
        hashtextextended('toj-presence-expiry-v1', 0)
      ) AS claimed`)[0]?.claimed === true;
    if (!claimed) return [];

    const candidates = await tx`
      SELECT account_id
      FROM device_presence_leases
      WHERE expires_at <= now()
      GROUP BY account_id
      ORDER BY min(expires_at), account_id
      LIMIT ${boundedLimit}`;
    if (candidates.length === 0) return [];
    const candidateIds = candidates.map((row) => String(row.account_id));
    const accountRows = await tx`
      SELECT id, status FROM accounts
      WHERE id = ANY(${tx.array(candidateIds, "uuid")}::uuid[])
      ORDER BY id FOR SHARE`;
    const activeIds = accountRows
      .filter((row) => row.status === "active" || row.status === "limited")
      .map((row) => String(row.id));
    const activeIdSet = new Set(activeIds);
    const deletedIds = candidateIds.filter((id) => !activeIdSet.has(id));
    if (deletedIds.length > 0) {
      await tx`
        DELETE FROM device_presence_leases
        WHERE account_id = ANY(${tx.array(deletedIds, "uuid")}::uuid[])`;
      await tx`
        DELETE FROM account_presence
        WHERE account_id = ANY(${tx.array(deletedIds, "uuid")}::uuid[])`;
    }
    if (activeIds.length === 0) return [];

    await tx`
      INSERT INTO account_presence(account_id)
      SELECT expanded.account_id
      FROM unnest(${tx.array(activeIds, "uuid")}::uuid[]) AS expanded(account_id)
      ON CONFLICT (account_id) DO NOTHING`;
    await tx`
      SELECT account_id FROM account_presence
      WHERE account_id = ANY(${tx.array(activeIds, "uuid")}::uuid[])
      ORDER BY account_id FOR UPDATE`;
    const updatedRows = await tx`
      WITH expired AS (
        DELETE FROM device_presence_leases
        WHERE account_id = ANY(${tx.array(activeIds, "uuid")}::uuid[])
          AND expires_at <= now()
        RETURNING account_id, last_heartbeat_at
      ), offline AS (
        SELECT expired.account_id, max(expired.last_heartbeat_at) AS last_heartbeat_at
        FROM expired
        WHERE NOT EXISTS (
          SELECT 1 FROM device_presence_leases remaining
          WHERE remaining.account_id = expired.account_id
            AND remaining.expires_at > now()
        )
        GROUP BY expired.account_id
      )
      UPDATE account_presence presence
      SET last_seen_at = offline.last_heartbeat_at,
          revision = presence.revision + 1,
          updated_at = now()
      FROM offline
      WHERE presence.account_id = offline.account_id
      RETURNING presence.account_id, presence.last_seen_at, presence.revision`;
    if (updatedRows.length === 0) return [];

    const offlineIds = updatedRows.map((row) => String(row.account_id));
    const recipientRows = await tx`
      SELECT DISTINCT subject.account_id AS subject_account_id, peer.account_id
      FROM unnest(${tx.array(offlineIds, "uuid")}::uuid[]) AS subject(account_id)
      JOIN dialog_members mine
        ON mine.account_id = subject.account_id AND mine.left_at IS NULL
      JOIN dialogs dialog
        ON dialog.id = mine.dialog_id AND dialog.type = 'direct' AND dialog.closed_at IS NULL
      JOIN dialog_members peer
        ON peer.dialog_id = dialog.id
       AND peer.account_id <> subject.account_id
       AND peer.left_at IS NULL
      WHERE NOT EXISTS (
        SELECT 1 FROM account_blocks block
        WHERE (block.blocker_account_id = subject.account_id
               AND block.blocked_account_id = peer.account_id)
           OR (block.blocker_account_id = peer.account_id
               AND block.blocked_account_id = subject.account_id)
      )
      ORDER BY subject.account_id, peer.account_id`;
    const recipientsBySubject = new Map<string, string[]>();
    for (const row of recipientRows) {
      const subjectId = String(row.subject_account_id);
      const recipientId = String(row.account_id);
      if (!presenceEnabledForAccount(recipientId)) continue;
      const recipients = recipientsBySubject.get(subjectId) ?? [];
      recipients.push(recipientId);
      recipientsBySubject.set(subjectId, recipients);
    }
    runtimeMetrics.transitions += updatedRows.length;
    const broadcasts: PresenceBroadcast[] = updatedRows.flatMap((row) => {
      const accountId = String(row.account_id);
      const recipients = recipientsBySubject.get(accountId) ?? [];
      if (recipients.length === 0) return [];
      return [{
        deliveryId: randomUUID(),
        recipientAccountIds: recipients,
        event: {
          type: "presence_update" as const,
          accountId,
          online: false,
          lastSeenAt: iso(row.last_seen_at),
          revision: Number(row.revision),
        },
      }];
    });
    await notifyBroadcasts(tx, broadcasts);
    return broadcasts;
  });
}

export async function queryPresence(
  sql: SQL,
  observerAccountId: string,
  rawAccountIds: unknown,
): Promise<{ presences: PresenceSnapshot[] }> {
  if (!presenceEnabledForAccount(observerAccountId)
    || !(await presenceSchemaReadiness(sql)).ready) {
    throw new PresenceError("presence capability unavailable", "capability_unavailable", 404);
  }
  if (!Array.isArray(rawAccountIds)) throw new PresenceError("accountIds must be an array");
  const accountIds = [...new Set(rawAccountIds.map(String))];
  if (accountIds.length > 200) throw new PresenceError("too many accountIds", "too_many_accounts", 413);
  if (accountIds.some((id) => !UUID_PATTERN.test(id))) throw new PresenceError("invalid accountId");
  if (accountIds.length === 0) return { presences: [] };
  const rows = await sql`
    SELECT subject.id,
           EXISTS(
             SELECT 1 FROM device_presence_leases lease
             WHERE lease.account_id = subject.id AND lease.expires_at > now()
           ) AS online,
           presence.last_seen_at,
           COALESCE(presence.revision, 0) AS revision
    FROM accounts subject
    LEFT JOIN account_presence presence ON presence.account_id = subject.id
    WHERE subject.id = ANY(${sql.array(accountIds, "uuid")}::uuid[])
      AND subject.status IN ('active','limited')
      AND EXISTS (
        SELECT 1
        FROM dialogs dialog
        JOIN dialog_members observer
          ON observer.dialog_id = dialog.id
         AND observer.account_id = ${observerAccountId}
         AND observer.left_at IS NULL
        JOIN dialog_members peer
          ON peer.dialog_id = dialog.id
         AND peer.account_id = subject.id
         AND peer.left_at IS NULL
        WHERE dialog.type = 'direct' AND dialog.closed_at IS NULL
      )
      AND NOT EXISTS (
        SELECT 1 FROM account_blocks block
        WHERE (block.blocker_account_id = ${observerAccountId}
               AND block.blocked_account_id = subject.id)
           OR (block.blocker_account_id = subject.id
               AND block.blocked_account_id = ${observerAccountId})
      )
    ORDER BY subject.id`;
  return {
    presences: rows.map((row: any) => ({
      accountId: String(row.id),
      online: Boolean(row.online),
      lastSeenAt: iso(row.last_seen_at),
      revision: Number(row.revision),
    })),
  };
}

export async function publishTyping(
  sql: SQL,
  input: TypingInput,
): Promise<PresenceBroadcast[]> {
  if (!presenceEnabledForAccount(input.accountId)) return [];
  if (!UUID_PATTERN.test(input.dialogId)) return [];
  return await sql.begin(async (tx) => {
    if (!input.allowRevokedCleanup) {
      await requireActiveDevice(tx, input.accountId, input.deviceId);
    }
    if (input.active && !input.allowRevokedCleanup) {
      const ownsForegroundLease = (await tx`
        SELECT EXISTS (
          SELECT 1 FROM device_presence_leases
          WHERE account_id = ${input.accountId}
            AND device_id = ${input.deviceId}
            AND connection_id = ${input.typingSessionId}
            AND expires_at > now()
        ) AS owns`)[0]?.owns === true;
      if (!ownsForegroundLease) return [];
    }
    const dialog = (await tx`
      SELECT dialog.type
      FROM dialogs dialog
      JOIN dialog_members actor
        ON actor.dialog_id = dialog.id
       AND actor.account_id = ${input.accountId}
       AND actor.left_at IS NULL
      WHERE dialog.id = ${input.dialogId} AND dialog.closed_at IS NULL`)[0];
    if (!dialog || dialog.type === "saved") return [];
    const recipientRows = dialog.type === "direct"
      ? await tx`
          SELECT peer.account_id
          FROM dialog_members peer
          WHERE peer.dialog_id = ${input.dialogId}
            AND peer.account_id <> ${input.accountId}
            AND peer.left_at IS NULL
            AND NOT EXISTS (
              SELECT 1 FROM account_blocks block
              WHERE (block.blocker_account_id = ${input.accountId}
                     AND block.blocked_account_id = peer.account_id)
                 OR (block.blocker_account_id = peer.account_id
                     AND block.blocked_account_id = ${input.accountId})
            )`
      : await tx`
          SELECT peer.account_id
          FROM dialog_members peer
          WHERE peer.dialog_id = ${input.dialogId}
            AND peer.account_id <> ${input.accountId}
            AND peer.left_at IS NULL
          ORDER BY peer.account_id`;
    const recipients = recipientRows.map((row: any) => String(row.account_id))
      .filter(presenceEnabledForAccount);
    if (recipients.length === 0) return [];
    const broadcasts: PresenceBroadcast[] = [{
      deliveryId: randomUUID(),
      recipientAccountIds: recipients,
      event: {
        type: "typing_update",
        dialogId: input.dialogId,
        actorAccountId: input.accountId,
        typingSessionId: input.typingSessionId,
        active: input.active,
        expiresInMs: TYPING_EXPIRES_MS,
      },
    }];
    runtimeMetrics.typingPublications += 1;
    await notifyBroadcasts(tx, broadcasts);
    return broadcasts;
  });
}

export async function publishPresenceVisibility(
  sql: SQL,
  leftAccountId: string,
  rightAccountId: string,
  visible: boolean,
): Promise<PresenceBroadcast[]> {
  if (visible) {
    const authorized = await sql`
      SELECT EXISTS (
        SELECT 1
        FROM dialogs dialog
        JOIN dialog_members left_member
          ON left_member.dialog_id = dialog.id
         AND left_member.account_id = ${leftAccountId}
         AND left_member.left_at IS NULL
        JOIN dialog_members right_member
          ON right_member.dialog_id = dialog.id
         AND right_member.account_id = ${rightAccountId}
         AND right_member.left_at IS NULL
        WHERE dialog.type = 'direct' AND dialog.closed_at IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM account_blocks block
            WHERE (block.blocker_account_id = ${leftAccountId}
                   AND block.blocked_account_id = ${rightAccountId})
               OR (block.blocker_account_id = ${rightAccountId}
                   AND block.blocked_account_id = ${leftAccountId})
          )
      ) AS visible`;
    if (authorized[0]?.visible !== true) return [];
  }
  const broadcasts: PresenceBroadcast[] = [
    {
      deliveryId: randomUUID(),
      recipientAccountIds: [leftAccountId],
      event: { type: "presence_visibility", accountId: rightAccountId, visible },
    },
    {
      deliveryId: randomUUID(),
      recipientAccountIds: [rightAccountId],
      event: { type: "presence_visibility", accountId: leftAccountId, visible },
    },
  ];
  await notifyBroadcasts(sql, broadcasts);
  return broadcasts;
}

export function startPresenceNotificationListener(
  databaseUrl: string | null,
  onBroadcast: (broadcast: PresenceBroadcast) => void | Promise<void>,
): () => void {
  if (!databaseUrl) return () => {};
  let stopped = false;
  let client: Client | null = null;
  let retry: ReturnType<typeof setTimeout> | null = null;
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
      application_name: "toj-presence-notify",
    });
    client = next;
    next.on("notification", (notification) => {
      if (notification.channel !== PRESENCE_NOTIFY_CHANNEL || !notification.payload) return;
      try {
        const broadcast = JSON.parse(notification.payload) as PresenceBroadcast;
        if (!Array.isArray(broadcast.recipientAccountIds)
          || broadcast.recipientAccountIds.length > RECIPIENT_CHUNK_SIZE
          || broadcast.recipientAccountIds.some((id) => !UUID_PATTERN.test(id))
          || !broadcast.event || typeof broadcast.event.type !== "string") return;
        void onBroadcast(broadcast);
      } catch { /* Ephemeral notifications are never authoritative. */ }
    });
    let handled = false;
    const disconnected = () => {
      if (handled) return;
      handled = true;
      if (client !== next) return;
      client = null;
      if (!stopped) runtimeMetrics.notificationFailures += 1;
      schedule();
    };
    next.once("error", disconnected);
    next.once("end", disconnected);
    try {
      await next.connect();
      await next.query(`LISTEN ${PRESENCE_NOTIFY_CHANNEL}`);
      attempts = 0;
    } catch {
      try { await next.end(); } catch {}
      disconnected();
    }
  };
  void connect();
  return () => {
    stopped = true;
    if (retry) clearTimeout(retry);
    retry = null;
    const current = client;
    client = null;
    if (current) void current.end().catch(() => {});
  };
}

export function startPresenceCleanupWorker(
  sql: SQL,
  onBroadcasts: (broadcasts: PresenceBroadcast[]) => void,
  intervalMs = 5_000,
): () => void {
  let running = false;
  let schemaReady = false;
  let nextSchemaProbeAt = 0;
  const tick = async () => {
    if (running) return;
    running = true;
    try {
      // Code can be deployed before its additive migration and before rollout. Keep the worker
      // completely dark in either state instead of logging a failed query every interval.
      if (!presenceConfigured()) return;
      if (!schemaReady) {
        if (Date.now() < nextSchemaProbeAt) return;
        schemaReady = (await presenceSchemaReadiness(sql)).ready;
        if (!schemaReady) {
          nextSchemaProbeAt = Date.now() + 30_000;
          return;
        }
      }
      const broadcasts = await expirePresenceLeases(sql);
      if (broadcasts.length > 0) onBroadcasts(broadcasts);
    } catch (error) {
      console.error(JSON.stringify({
        ts: new Date().toISOString(),
        event: "presence.cleanup_error",
        errorType: error instanceof Error ? error.name : "UnknownError",
      }));
    } finally {
      running = false;
    }
  };
  const timer = setInterval(() => { void tick(); }, intervalMs);
  timer.unref?.();
  return () => clearInterval(timer);
}

export async function presenceMetrics(sql: SQL): Promise<string> {
  const cacheKey = sql as unknown as object;
  const cached = renderedMetricsCache.get(cacheKey);
  if (cached && cached.expiresAt > Date.now()) return cached.value;
  const schema = await presenceSchemaReadiness(sql);
  if (!schema.ready) {
    const value = "# HELP toj_presence_schema_available Presence schema contract availability.\n"
      + "# TYPE toj_presence_schema_available gauge\n"
      + "toj_presence_schema_available 0\n";
    renderedMetricsCache.set(cacheKey, { expiresAt: Date.now() + 5_000, value });
    return value;
  }
  const row = (await sql`
    SELECT
      count(*) FILTER (WHERE expires_at > now()) AS active,
      count(*) FILTER (WHERE expires_at <= now()) AS expired,
      COALESCE(extract(epoch FROM now() -
        (min(expires_at) FILTER (WHERE expires_at <= now()))), 0) AS oldest_expired_seconds
    FROM device_presence_leases`)[0];
  const lines = [
    "# HELP toj_presence_schema_available Presence schema contract availability.",
    "# TYPE toj_presence_schema_available gauge",
    "toj_presence_schema_available 1",
    "# HELP toj_presence_active_leases Foreground device presence leases.",
    "# TYPE toj_presence_active_leases gauge",
    `toj_presence_active_leases ${Number(row.active)}`,
    "# HELP toj_presence_expired_leases Expired presence leases awaiting cleanup.",
    "# TYPE toj_presence_expired_leases gauge",
    `toj_presence_expired_leases ${Number(row.expired)}`,
    "# HELP toj_presence_oldest_expired_seconds Age of the oldest expired presence lease.",
    "# TYPE toj_presence_oldest_expired_seconds gauge",
    `toj_presence_oldest_expired_seconds ${Number(row.oldest_expired_seconds)}`,
    "# HELP toj_presence_transitions_total Confirmed online and offline transitions.",
    "# TYPE toj_presence_transitions_total counter",
    `toj_presence_transitions_total ${runtimeMetrics.transitions}`,
    "# HELP toj_presence_typing_publications_total Authorized typing publications.",
    "# TYPE toj_presence_typing_publications_total counter",
    `toj_presence_typing_publications_total ${runtimeMetrics.typingPublications}`,
    "# HELP toj_presence_notification_failures_total PostgreSQL notification failures.",
    "# TYPE toj_presence_notification_failures_total counter",
    `toj_presence_notification_failures_total ${runtimeMetrics.notificationFailures}`,
    "# HELP toj_presence_rejected_frames_total Rejected realtime activity by bounded reason.",
    "# TYPE toj_presence_rejected_frames_total counter",
  ];
  for (const reason of ["malformed", "oversized", "unsupported", "unauthorized", "rate_limited"]) {
    lines.push(`toj_presence_rejected_frames_total{reason="${reason}"} ${runtimeMetrics.rejectedFrames.get(reason) ?? 0}`);
  }
  lines.push("");
  const value = lines.join("\n");
  renderedMetricsCache.set(cacheKey, { expiresAt: Date.now() + 5_000, value });
  return value;
}
