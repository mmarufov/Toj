import type { SQL } from "bun";
import {
  requestFingerprintIndex,
  scheduledItemAAD,
} from "./crypto";
import { openForScope, preloadEnvelopeKeys, sealForScope } from "./envelope-crypto";
import { lockAccountMutations, lockMutationKeys } from "./locks";
import { requireDialogReadAccess } from "./dialog-access";
import { sendMediaGroup, sendMessage, SyncError } from "./sync";
import { notifySyncWakeups } from "./sync-wakeup";
import { touchWorkerHeartbeat } from "./cloud-productivity-readiness";
import { linkPreviewsEnabledForAccount } from "./cloud-productivity-readiness";
import { EXPIRED_BLIND_INDEX_KEY_ID } from "./blind-index";
import {
  adjustProductivityActiveJobs,
  productivityWorkerLeaseSeconds,
  recordProductivityLeaseRenewalFailure,
  scheduledDeliveryWorkerConcurrency,
} from "./productivity-runtime";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_TEXT_BYTES = 16 * 1024;
const MAX_PENDING_ACCOUNT = 100;
const MAX_PENDING_DIALOG = 25;
const MAX_ITEMS = 10;

export class ScheduledDeliveryError extends Error {
  constructor(
    message: string,
    readonly code = "invalid_scheduled_delivery",
    readonly status = 400,
    readonly retryAfter?: number,
    readonly details: Record<string, unknown> = {},
  ) {
    super(message);
    this.name = "ScheduledDeliveryError";
  }
}

export type ScheduledDeliveryItemDTO = {
  clientMsgId: string;
  kind: "text" | "photo" | "video" | "file" | "voice";
  body: string;
  replyToMsgId: number | null;
  mediaId: string | null;
  mentions: Array<{ accountId: string; offset: number; length: number }>;
  linkPreviewCandidate: {
    url: string;
    utf16Offset: number;
    utf16Length: number;
    disabled: boolean;
  } | null;
};

export type ScheduledDeliveryDTO = {
  id: string;
  dialogId: string;
  deliverAt: string;
  state: "scheduled" | "processing" | "delivered" | "failed" | "canceled";
  silent: boolean;
  reminder: boolean;
  revision: number;
  attempts: number;
  lastErrorCode: string | null;
  deliveredFirstMsgId: number | null;
  deliveredLastMsgId: number | null;
  items: ScheduledDeliveryItemDTO[];
  createdAt: string;
  updatedAt: string;
  completedAt: string | null;
};

export type ScheduledDeliveryMutationResult = {
  scheduledDelivery: ScheduledDeliveryDTO;
  collectionRevision: number;
  pts: number;
  clientMutationId: string;
  duplicate: boolean;
  serverNow: string;
};

type StoredItemPayload = Omit<ScheduledDeliveryItemDTO, "clientMsgId" | "kind" | "mediaId">;
type WorkerClaim = { id: string; leaseToken: string };

const n = (value: unknown) => Number(value as any);
const iso = (value: unknown): string => value instanceof Date ? value.toISOString() : String(value);

function requireUUID(value: unknown, field: string): string {
  const normalized = String(value ?? "").toLowerCase();
  if (!UUID_PATTERN.test(normalized)) {
    throw new ScheduledDeliveryError(`${field} is invalid`);
  }
  return normalized;
}

function optionalMessageId(value: unknown): number | null {
  if (value == null) return null;
  const result = Number(value);
  if (!Number.isSafeInteger(result) || result <= 0) {
    throw new ScheduledDeliveryError("reply message id is invalid");
  }
  return result;
}

function normalizeMentions(value: unknown, body: string) {
  if (value == null) return [];
  if (!Array.isArray(value) || value.length > 100) {
    throw new ScheduledDeliveryError("mentions are invalid");
  }
  const seen = new Set<string>();
  return value.map((raw: any) => {
    const accountId = requireUUID(raw?.accountId ?? raw?.account_id, "mention account id");
    const offset = Number(raw?.offset);
    const length = Number(raw?.length);
    if (
      !Number.isSafeInteger(offset) || offset < 0
      || !Number.isSafeInteger(length) || length <= 0
      || offset + length > body.length
      || seen.has(accountId)
    ) {
      throw new ScheduledDeliveryError("mentions are invalid");
    }
    seen.add(accountId);
    return { accountId, offset, length };
  }).sort((left, right) => left.offset - right.offset || left.accountId.localeCompare(right.accountId));
}

function normalizePreview(value: any, body: string): ScheduledDeliveryItemDTO["linkPreviewCandidate"] {
  if (value == null) return null;
  const disabled = Boolean(value.disabled);
  if (disabled) return { url: "", utf16Offset: 0, utf16Length: 0, disabled: true };
  const url = String(value.url ?? "");
  const utf16Offset = Number(value.utf16Offset ?? value.utf16_offset);
  const utf16Length = Number(value.utf16Length ?? value.utf16_length);
  if (
    url.length === 0 || Buffer.byteLength(url, "utf8") > 4_096
    || !Number.isSafeInteger(utf16Offset) || utf16Offset < 0
    || !Number.isSafeInteger(utf16Length) || utf16Length <= 0
    || utf16Offset + utf16Length > body.length
    || body.slice(utf16Offset, utf16Offset + utf16Length) !== url
  ) {
    throw new ScheduledDeliveryError("link preview candidate is invalid");
  }
  return { url, utf16Offset, utf16Length, disabled: false };
}

function normalizeItems(value: unknown): ScheduledDeliveryItemDTO[] {
  if (!Array.isArray(value) || value.length < 1 || value.length > MAX_ITEMS) {
    throw new ScheduledDeliveryError("scheduled delivery requires 1 to 10 items");
  }
  const clientIds = new Set<string>();
  const mediaIds = new Set<string>();
  const items = value.map((raw: any): ScheduledDeliveryItemDTO => {
    const clientMsgId = requireUUID(raw?.clientMsgId ?? raw?.client_msg_id, "client message id");
    if (clientIds.has(clientMsgId)) {
      throw new ScheduledDeliveryError("duplicate scheduled client message id");
    }
    clientIds.add(clientMsgId);
    const kind = String(raw?.kind ?? "text") as ScheduledDeliveryItemDTO["kind"];
    if (!["text", "photo", "video", "file", "voice"].includes(kind)) {
      throw new ScheduledDeliveryError("scheduled item kind is invalid");
    }
    const body = String(raw?.body ?? "");
    if (Buffer.byteLength(body, "utf8") > MAX_TEXT_BYTES) {
      throw new ScheduledDeliveryError("scheduled message body is too large");
    }
    const mediaId = raw?.mediaId == null && raw?.media_id == null
      ? null
      : requireUUID(raw?.mediaId ?? raw?.media_id, "media id");
    if (kind === "text" && (body.trim().length === 0 || mediaId != null)) {
      throw new ScheduledDeliveryError("scheduled text is invalid");
    }
    if (kind !== "text" && mediaId == null) {
      throw new ScheduledDeliveryError("scheduled media is missing");
    }
    if (mediaId && mediaIds.has(mediaId)) {
      throw new ScheduledDeliveryError("duplicate scheduled media id");
    }
    if (mediaId) mediaIds.add(mediaId);
    return {
      clientMsgId,
      kind,
      body,
      replyToMsgId: optionalMessageId(raw?.replyToMsgId ?? raw?.reply_to_msg_id),
      mediaId,
      mentions: normalizeMentions(raw?.mentions, body),
      linkPreviewCandidate: normalizePreview(
        raw?.linkPreviewCandidate ?? raw?.link_preview_candidate,
        body,
      ),
    };
  });
  if (items.length > 1 && items.some((item) => item.kind === "text" || item.kind === "voice")) {
    throw new ScheduledDeliveryError("scheduled albums support photo, video, and file items only");
  }
  return items;
}

function normalizedInstant(value: unknown, now = Date.now(), allowHistorical = false): Date {
  const parsed = new Date(String(value ?? ""));
  if (Number.isNaN(parsed.getTime())) {
    throw new ScheduledDeliveryError("delivery time is invalid");
  }
  if (!allowHistorical && parsed.getTime() < now + 60_000) {
    throw new ScheduledDeliveryError("delivery time must be at least 60 seconds away");
  }
  if (parsed.getTime() > now + 365 * 24 * 60 * 60 * 1_000) {
    throw new ScheduledDeliveryError("delivery time must be within one year");
  }
  return parsed;
}

async function requireActiveDevice(sql: SQL, accountId: string, deviceId: string): Promise<void> {
  const row = (await sql`
    SELECT 1
    FROM accounts account
    JOIN devices device ON device.account_id = account.id
    WHERE account.id = ${accountId}
      AND account.status IN ('active','limited')
      AND device.id = ${deviceId}
      AND device.revoked_at IS NULL
    FOR SHARE OF account, device`)[0];
  if (!row) throw new ScheduledDeliveryError("account unavailable", "authentication_required", 401);
}

async function validateItems(
  sql: SQL,
  accountId: string,
  dialogId: string,
  items: ScheduledDeliveryItemDTO[],
): Promise<void> {
  await requireDialogReadAccess(sql, accountId, dialogId);
  const mediaIds = items.flatMap((item) => item.mediaId ? [item.mediaId] : []);
  if (mediaIds.length) {
    const rows = await sql`
      SELECT id, kind FROM media_objects
      WHERE id = ANY(${sql.array(mediaIds, "uuid")}::uuid[])
        AND owner_account_id = ${accountId}
        AND status = 'ready'
        AND purpose = 'message'
      FOR SHARE`;
    if (rows.length !== mediaIds.length) {
      throw new ScheduledDeliveryError("scheduled media is unavailable", "media_unavailable", 409);
    }
    const kindById = new Map(rows.map((row: any) => [String(row.id), String(row.kind)]));
    if (items.some((item) => item.mediaId && kindById.get(item.mediaId) !== item.kind)) {
      throw new ScheduledDeliveryError("scheduled media kind does not match", "media_unavailable", 409);
    }
  }
}

async function validateReminder(sql: SQL, accountId: string, dialogId: string, reminder: boolean) {
  if (!reminder) return;
  const row = (await sql`
    SELECT dialog.type
    FROM dialogs dialog
    JOIN dialog_members member
      ON member.dialog_id = dialog.id AND member.account_id = ${accountId}
    WHERE dialog.id = ${dialogId}
      AND dialog.type = 'saved'
      AND dialog.created_by = ${accountId}
      AND member.role = 'owner'
      AND member.left_at IS NULL
      AND dialog.closed_at IS NULL
    FOR SHARE OF dialog, member`)[0];
  if (!row) {
    throw new ScheduledDeliveryError(
      "reminders are available only in Saved Messages",
      "reminder_requires_saved_messages",
      400,
    );
  }
}

function itemPayload(item: ScheduledDeliveryItemDTO): StoredItemPayload {
  return {
    body: item.body,
    replyToMsgId: item.replyToMsgId,
    mentions: item.mentions,
    linkPreviewCandidate: item.linkPreviewCandidate,
  };
}

type MutationFingerprint = { canonical: string; digest: Buffer; keyId: string };

function fingerprint(
  operation: string,
  deliveryId: string,
  payload: unknown,
): MutationFingerprint {
  const canonical = JSON.stringify({ operation, deliveryId, payload });
  const index = requestFingerprintIndex(
    "scheduled-delivery-mutation",
    canonical,
  );
  return { canonical, digest: index.digest, keyId: index.keyId };
}

function sameBuffer(left: unknown, right: Buffer): boolean {
  return Buffer.from(left as Uint8Array).equals(right);
}

async function deliveryDTO(
  sql: SQL,
  accountId: string,
  row: any,
  itemRows: any[],
): Promise<ScheduledDeliveryDTO> {
  const deliveryId = String(row.id);
  const items: ScheduledDeliveryItemDTO[] = [];
  for (const item of itemRows) {
    if (!item.payload_key_id || !item.payload_nonce || !item.payload_ciphertext) continue;
    const payload = JSON.parse((await openForScope(
      sql,
      { kind: "account", accountId },
      {
        keyId: String(item.payload_key_id),
        nonce: Buffer.from(item.payload_nonce),
        ciphertext: Buffer.from(item.payload_ciphertext),
      },
      scheduledItemAAD(accountId, deliveryId, n(item.item_index), String(item.client_msg_id)),
    )).toString("utf8")) as StoredItemPayload;
    items.push({
      clientMsgId: String(item.client_msg_id),
      kind: String(item.kind) as ScheduledDeliveryItemDTO["kind"],
      mediaId: item.media_id == null ? null : String(item.media_id),
      body: String(payload.body ?? ""),
      replyToMsgId: payload.replyToMsgId ?? null,
      mentions: payload.mentions ?? [],
      linkPreviewCandidate: payload.linkPreviewCandidate ?? null,
    });
  }
  return {
    id: String(row.id),
    dialogId: String(row.dialog_id),
    deliverAt: iso(row.deliver_at),
    state: String(row.state) as ScheduledDeliveryDTO["state"],
    silent: Boolean(row.silent),
    reminder: Boolean(row.reminder),
    revision: n(row.revision),
    attempts: n(row.attempts),
    lastErrorCode: row.last_error_code == null ? null : String(row.last_error_code),
    deliveredFirstMsgId: row.delivered_first_msg_id == null ? null : n(row.delivered_first_msg_id),
    deliveredLastMsgId: row.delivered_last_msg_id == null ? null : n(row.delivered_last_msg_id),
    items,
    createdAt: iso(row.created_at),
    updatedAt: iso(row.updated_at),
    completedAt: row.completed_at == null ? null : iso(row.completed_at),
  };
}

async function loadDelivery(
  sql: SQL,
  accountId: string,
  deliveryId: string,
): Promise<ScheduledDeliveryDTO | null> {
  const row = (await sql`
    SELECT id, account_id, dialog_id, deliver_at, state, silent, reminder, revision,
           attempts, last_error_code, delivered_first_msg_id, delivered_last_msg_id,
           created_at, updated_at, completed_at
    FROM scheduled_deliveries
    WHERE id = ${deliveryId} AND account_id = ${accountId}`)[0];
  if (!row) return null;
  const itemRows = await sql`
    SELECT item_index, client_msg_id, kind, payload_key_id, payload_nonce,
           payload_ciphertext, media_id
    FROM scheduled_delivery_items
    WHERE delivery_id = ${deliveryId}
    ORDER BY item_index`;
  await preloadEnvelopeKeys(sql, itemRows.map((item: any) => String(item.payload_key_id ?? "")));
  return await deliveryDTO(sql, accountId, row, itemRows);
}

export async function getScheduledDelivery(
  sql: SQL,
  accountId: string,
  deliveryId: string,
): Promise<ScheduledDeliveryDTO | null> {
  return await loadDelivery(sql, accountId, requireUUID(deliveryId, "schedule id"));
}

export async function listScheduledDeliveries(
  sql: SQL,
  accountId: string,
  options: { dialogId?: string | null; cursor?: string | null; limit?: number } = {},
): Promise<{ collectionRevision: number; deliveries: ScheduledDeliveryDTO[]; nextCursor: string | null }> {
  const dialogId = options.dialogId ? requireUUID(options.dialogId, "dialog id") : null;
  const limit = Math.max(1, Math.min(100, Number(options.limit ?? 50)));
  let cursorDate: Date | null = null;
  let cursorId: string | null = null;
  if (options.cursor) {
    try {
      const decoded = JSON.parse(Buffer.from(options.cursor, "base64url").toString("utf8"));
      cursorDate = new Date(decoded.deliverAt);
      cursorId = requireUUID(decoded.id, "cursor id");
      if (Number.isNaN(cursorDate.getTime())) throw new Error("invalid");
    } catch {
      throw new ScheduledDeliveryError("cursor is invalid");
    }
  }
  return await sql.begin(async (tx) => {
    // Every scheduled mutation and worker state transition takes this account lock. Holding it
    // while assembling one page makes the attached collection revision describe these exact rows,
    // rather than a newer revision sampled after an older row query. Acquire the advisory lock in
    // the revision statement itself so every non-empty page remains exactly three SQL statements.
    const state = (await tx`
      SELECT schedule_state.revision
      FROM (
        SELECT pg_advisory_xact_lock(
          hashtextextended(${`account-mutation:${accountId}`}, 0)
        )
      ) AS held
      LEFT JOIN account_scheduled_delivery_states schedule_state
        ON schedule_state.account_id = ${accountId}`)[0];
    const rows = await tx`
      SELECT id, account_id, dialog_id, deliver_at, state, silent, reminder, revision,
             attempts, last_error_code, delivered_first_msg_id, delivered_last_msg_id,
             created_at, updated_at, completed_at
      FROM scheduled_deliveries
      WHERE account_id = ${accountId}
        AND (${dialogId}::uuid IS NULL OR dialog_id = ${dialogId}::uuid)
        AND (
          state IN ('scheduled','processing')
          OR completed_at >= now() - interval '30 days'
        )
        AND (
          ${cursorDate}::timestamptz IS NULL
          OR (deliver_at, id) > (${cursorDate}::timestamptz, ${cursorId}::uuid)
        )
      ORDER BY deliver_at, id
      LIMIT ${limit + 1}`;
    const selected = rows.slice(0, limit);
    const selectedIds = selected.map((row: any) => String(row.id));
    const itemRows = selectedIds.length === 0 ? [] : await tx`
      SELECT delivery_id, item_index, client_msg_id, kind, payload_key_id, payload_nonce,
             payload_ciphertext, media_id
      FROM scheduled_delivery_items
      WHERE delivery_id = ANY(${tx.array(selectedIds, "uuid")}::uuid[])
      ORDER BY delivery_id, item_index`;
    const itemsByDelivery = new Map<string, any[]>();
    for (const item of itemRows) {
      const deliveryId = String(item.delivery_id);
      const grouped = itemsByDelivery.get(deliveryId) ?? [];
      grouped.push(item);
      itemsByDelivery.set(deliveryId, grouped);
    }
    await preloadEnvelopeKeys(
      tx,
      itemRows.map((item: any) => String(item.payload_key_id ?? "")),
    );
    const deliveries = await Promise.all(selected.map((row: any) =>
      deliveryDTO(tx, accountId, row, itemsByDelivery.get(String(row.id)) ?? [])
    ));
    const last = selected.at(-1);
    return {
      collectionRevision: n(state?.revision ?? 0),
      deliveries,
      nextCursor: rows.length > limit && last
        ? Buffer.from(JSON.stringify({ deliverAt: iso(last.deliver_at), id: last.id })).toString("base64url")
        : null,
    };
  });
}

async function appendScheduleEvent(
  sql: SQL,
  input: {
    accountId: string;
    sourceDeviceId?: string | null;
    type: "scheduled.created" | "scheduled.updated" | "scheduled.canceled" | "scheduled.failed";
    deliveryId: string;
    collectionRevision: number;
    clientMutationId?: string | null;
  },
): Promise<number> {
  const state = (await sql`
    UPDATE account_sync_states SET pts = pts + 1, updated_at = now()
    WHERE account_id = ${input.accountId}
    RETURNING pts`)[0];
  if (!state) throw new ScheduledDeliveryError("account unavailable", "account_unavailable", 404);
  const pts = n(state.pts);
  await sql`
    INSERT INTO account_events(account_id, pts, type, actor_account_id, data)
    VALUES (
      ${input.accountId}, ${pts}, ${input.type}, ${input.accountId},
      ${JSON.stringify({
        scheduled_delivery_id: input.deliveryId,
        collection_revision: input.collectionRevision,
        client_mutation_id: input.clientMutationId ?? undefined,
      })}::text::jsonb
    )`;
  await sql`
    INSERT INTO push_deliveries(account_id, pts, device_id, alert)
    SELECT ${input.accountId}, ${pts}, id, FALSE
    FROM devices
    WHERE account_id = ${input.accountId}
      AND (${input.sourceDeviceId ?? null}::uuid IS NULL OR id <> ${input.sourceDeviceId ?? null}::uuid)
      AND platform = 'ios'
      AND revoked_at IS NULL
      AND (
        (push_token_hash IS NOT NULL AND push_token_ciphertext IS NOT NULL)
        OR EXISTS (
          SELECT 1 FROM push_account_bindings binding
          JOIN push_installations installation USING (installation_id)
          WHERE binding.device_id = devices.id AND binding.account_id = devices.account_id
            AND binding.active AND binding.normal_enabled
            AND installation.normal_token_ciphertext IS NOT NULL
        )
      )
    ON CONFLICT (account_id, pts, device_id) DO NOTHING`;
  await notifySyncWakeups(sql, [{ accountId: input.accountId, pts, ptsCount: 1 }]);
  return pts;
}

async function claimMutation(
  sql: SQL,
  input: {
    accountId: string;
    clientMutationId: string;
    deliveryId: string;
    operation: "create" | "update" | "reschedule" | "cancel";
    expectedRevision: number | null;
    fingerprint: MutationFingerprint;
    requestFingerprint: MutationFingerprint;
  },
): Promise<{ duplicate: boolean; receiptRevision: number | null }> {
  const inserted = await sql`
    INSERT INTO scheduled_delivery_mutation_requests (
      account_id, client_mutation_id, delivery_id, operation, expected_revision, fingerprint,
      request_fingerprint, fingerprint_key_id
    ) VALUES (
      ${input.accountId}, ${input.clientMutationId}, ${input.deliveryId}, ${input.operation},
      ${input.expectedRevision}, ${input.fingerprint.digest}, ${input.requestFingerprint.digest},
      ${input.fingerprint.keyId}
    )
    ON CONFLICT (account_id, client_mutation_id) DO NOTHING
    RETURNING status`;
  if (inserted.length) return { duplicate: false, receiptRevision: null };
  const row = (await sql`
    SELECT delivery_id, operation, expected_revision, fingerprint, request_fingerprint,
           fingerprint_key_id, status, result_revision
    FROM scheduled_delivery_mutation_requests
    WHERE account_id = ${input.accountId} AND client_mutation_id = ${input.clientMutationId}
    FOR UPDATE`)[0];
  if (row.fingerprint_key_id === EXPIRED_BLIND_INDEX_KEY_ID) {
    throw new ScheduledDeliveryError(
      "scheduled mutation result has expired", "mutation_result_expired", 409,
    );
  }
  const candidate = row.request_fingerprint == null
    ? input.fingerprint
    : input.requestFingerprint;
  const storedDigest = row.request_fingerprint == null
    ? row.fingerprint
    : row.request_fingerprint;
  const expectedDigest = requestFingerprintIndex(
    "scheduled-delivery-mutation",
    candidate.canonical,
    row.fingerprint_key_id ?? "legacy-v1",
  ).digest;
  if (
    String(row.delivery_id) !== input.deliveryId
    || row.operation !== input.operation
    || (row.expected_revision == null ? null : n(row.expected_revision)) !== input.expectedRevision
    || !sameBuffer(storedDigest, expectedDigest)
  ) {
    throw new ScheduledDeliveryError(
      "mutation id was reused with different input",
      "idempotency_conflict",
      409,
    );
  }
  if (String(row.fingerprint_key_id ?? "legacy-v1") !== input.requestFingerprint.keyId) {
    await sql`UPDATE scheduled_delivery_mutation_requests
      SET request_fingerprint = ${input.requestFingerprint.digest},
          fingerprint_key_id = ${input.requestFingerprint.keyId}
      WHERE account_id = ${input.accountId} AND client_mutation_id = ${input.clientMutationId}`;
  }
  if (row.status !== "completed") {
    throw new ScheduledDeliveryError("schedule mutation is in progress", "mutation_in_progress", 409);
  }
  return { duplicate: true, receiptRevision: n(row.result_revision) };
}

/**
 * Worker-health gating must not strand a mutation whose commit response was lost.
 * This read-only probe allows only an already-completed, same-operation receipt
 * through the unhealthy-worker gate; the normal mutation path still verifies the
 * delivery id, expected revision, and request fingerprint byte-for-byte.
 */
export async function completedScheduledMutationExists(
  sql: SQL,
  accountId: string,
  rawMutationId: unknown,
  operation: "create" | "update" | "reschedule",
): Promise<boolean> {
  const mutationId = requireUUID(rawMutationId, "client mutation id");
  const row = (await sql`
    SELECT 1
    FROM scheduled_delivery_mutation_requests
    WHERE account_id = ${accountId}
      AND client_mutation_id = ${mutationId}
      AND operation = ${operation}
      AND status = 'completed'
    LIMIT 1`)[0];
  return Boolean(row);
}

async function consumeMutationBudget(
  sql: SQL,
  accountId: string,
  action: "write" | "cancel",
): Promise<void> {
  const max = action === "cancel" ? 1_000 : 240;
  const row = await sql`
    INSERT INTO scheduled_delivery_action_budgets(
      account_id, action, bucket_started, mutation_count
    ) VALUES (${accountId}, ${action}, date_trunc('hour', now()), 1)
    ON CONFLICT (account_id, action, bucket_started) DO UPDATE SET
      mutation_count = scheduled_delivery_action_budgets.mutation_count + 1,
      updated_at = now()
    WHERE scheduled_delivery_action_budgets.mutation_count < ${max}
    RETURNING mutation_count`;
  if (!row.length) {
    throw new ScheduledDeliveryError("schedule mutation rate limit reached", "rate_limited", 429, 3600);
  }
}

async function replaceItems(
  sql: SQL,
  accountId: string,
  deliveryId: string,
  items: ScheduledDeliveryItemDTO[],
): Promise<void> {
  await sql`DELETE FROM scheduled_delivery_items WHERE delivery_id = ${deliveryId}`;
  for (const [index, item] of items.entries()) {
    const sealed = await sealForScope(
      sql,
      { kind: "account", accountId },
      JSON.stringify(itemPayload(item)),
      scheduledItemAAD(accountId, deliveryId, index, item.clientMsgId),
    );
    await sql`
      INSERT INTO scheduled_delivery_items(
        delivery_id, item_index, client_msg_id, kind,
        payload_key_id, payload_nonce, payload_ciphertext, media_id
      ) VALUES (
        ${deliveryId}, ${index}, ${item.clientMsgId}, ${item.kind},
        ${sealed.keyId}, ${sealed.nonce}, ${sealed.ciphertext}, ${item.mediaId}
      )`;
  }
}

export async function createScheduledDelivery(
  sql: SQL,
  input: { accountId: string; deviceId: string; body: any },
): Promise<ScheduledDeliveryMutationResult> {
  const deliveryId = requireUUID(input.body?.scheduleId ?? input.body?.id, "schedule id");
  const mutationId = requireUUID(input.body?.clientMutationId, "client mutation id");
  const completedReplay = await completedScheduledMutationExists(
    sql, input.accountId, mutationId, "create",
  );
  const dialogId = requireUUID(input.body?.dialogId, "dialog id");
  const deliverAt = normalizedInstant(input.body?.deliverAt, Date.now(), completedReplay);
  const items = normalizeItems(input.body?.items);
  const canonical = {
    dialogId,
    deliverAt: deliverAt.toISOString(),
    silent: Boolean(input.body?.silent),
    reminder: Boolean(input.body?.reminder),
    items,
  };
  const digest = fingerprint("create", deliveryId, canonical);
  const requestDigest = fingerprint("create-request", deliveryId, canonical);
  return await sql.begin(async (tx) => {
    await lockMutationKeys(tx, [`scheduled-receipt:${input.accountId}:${mutationId}`]);
    await lockAccountMutations(tx, [input.accountId]);
    await requireActiveDevice(tx, input.accountId, input.deviceId);
    const claim = await claimMutation(tx, {
      accountId: input.accountId,
      clientMutationId: mutationId,
      deliveryId,
      operation: "create",
      expectedRevision: null,
      fingerprint: digest,
      requestFingerprint: requestDigest,
    });
    if (claim.duplicate) {
      const scheduledDelivery = await loadDelivery(tx, input.accountId, deliveryId);
      if (!scheduledDelivery) {
        throw new ScheduledDeliveryError("schedule result expired", "schedule_result_expired", 409);
      }
      const state = (await tx`
        SELECT revision FROM account_scheduled_delivery_states WHERE account_id = ${input.accountId}`)[0];
      return {
        scheduledDelivery,
        collectionRevision: n(state?.revision ?? claim.receiptRevision ?? 0),
        pts: 0,
        clientMutationId: mutationId,
        duplicate: true,
        serverNow: new Date().toISOString(),
      };
    }
    await consumeMutationBudget(tx, input.accountId, "write");
    await validateItems(tx, input.accountId, dialogId, items);
    await validateReminder(tx, input.accountId, dialogId, canonical.reminder);
    const counts = (await tx`
      SELECT count(*) FILTER (WHERE state IN ('scheduled','processing'))::int AS account_count,
             count(*) FILTER (
               WHERE state IN ('scheduled','processing') AND dialog_id = ${dialogId}
             )::int AS dialog_count
      FROM scheduled_deliveries
      WHERE account_id = ${input.accountId}`)[0];
    if (n(counts.account_count) >= MAX_PENDING_ACCOUNT || n(counts.dialog_count) >= MAX_PENDING_DIALOG) {
      throw new ScheduledDeliveryError("scheduled delivery limit reached", "schedule_limit", 409);
    }
    await tx`
      INSERT INTO account_scheduled_delivery_states(account_id, revision)
      VALUES (${input.accountId}, 0)
      ON CONFLICT (account_id) DO NOTHING`;
    const collection = (await tx`
      UPDATE account_scheduled_delivery_states
      SET revision = revision + 1, updated_at = now()
      WHERE account_id = ${input.accountId}
      RETURNING revision`)[0];
    const revision = n(collection.revision);
    await tx`
      INSERT INTO scheduled_deliveries(
        id, account_id, origin_device_id, dialog_id, deliver_at, available_at,
        silent, reminder, revision
      ) VALUES (
        ${deliveryId}, ${input.accountId}, ${input.deviceId}, ${dialogId},
        ${deliverAt}, ${deliverAt}, ${canonical.silent}, ${canonical.reminder}, ${revision}
      )`;
    await replaceItems(tx, input.accountId, deliveryId, items);
    const pts = await appendScheduleEvent(tx, {
      accountId: input.accountId,
      sourceDeviceId: input.deviceId,
      type: "scheduled.created",
      deliveryId,
      collectionRevision: revision,
      clientMutationId: mutationId,
    });
    await tx`
      UPDATE scheduled_delivery_mutation_requests
      SET status = 'completed', result_revision = ${revision}
      WHERE account_id = ${input.accountId} AND client_mutation_id = ${mutationId}`;
    return {
      scheduledDelivery: (await loadDelivery(tx, input.accountId, deliveryId))!,
      collectionRevision: revision,
      pts,
      clientMutationId: mutationId,
      duplicate: false,
      serverNow: new Date().toISOString(),
    };
  });
}

export async function updateScheduledDelivery(
  sql: SQL,
  input: {
    accountId: string;
    deviceId: string;
    deliveryId: string;
    body: any;
    operation?: "update" | "reschedule";
  },
): Promise<ScheduledDeliveryMutationResult> {
  const deliveryId = requireUUID(input.deliveryId, "schedule id");
  const mutationId = requireUUID(input.body?.clientMutationId, "client mutation id");
  const expectedRevision = Number(input.body?.expectedRevision);
  if (!Number.isSafeInteger(expectedRevision) || expectedRevision <= 0) {
    throw new ScheduledDeliveryError("expected revision is invalid");
  }
  const operation = input.operation ?? "update";
  const completedReplay = await completedScheduledMutationExists(
    sql, input.accountId, mutationId, operation,
  );
  return await sql.begin(async (tx) => {
    await lockMutationKeys(tx, [`scheduled-receipt:${input.accountId}:${mutationId}`]);
    await lockAccountMutations(tx, [input.accountId]);
    await requireActiveDevice(tx, input.accountId, input.deviceId);
    const existing = await loadDelivery(tx, input.accountId, deliveryId);
    if (!existing) throw new ScheduledDeliveryError("schedule not found", "schedule_not_found", 404);
    const deliverAt = input.body?.deliverAt == null
      ? new Date(existing.deliverAt)
      : normalizedInstant(input.body.deliverAt, Date.now(), completedReplay);
    const items = input.body?.items == null ? existing.items : normalizeItems(input.body.items);
    const canonical = {
      deliverAt: deliverAt.toISOString(),
      silent: input.body?.silent == null ? existing.silent : Boolean(input.body.silent),
      reminder: input.body?.reminder == null ? existing.reminder : Boolean(input.body.reminder),
      items,
    };
    const digest = fingerprint(operation, deliveryId, canonical);
    const requestDigest = fingerprint(`${operation}-request`, deliveryId, {
      expectedRevision,
      ...(input.body?.deliverAt == null ? {} : { deliverAt: deliverAt.toISOString() }),
      ...(input.body?.silent == null ? {} : { silent: Boolean(input.body.silent) }),
      ...(input.body?.reminder == null ? {} : { reminder: Boolean(input.body.reminder) }),
      ...(input.body?.items == null ? {} : { items }),
    });
    const claim = await claimMutation(tx, {
      accountId: input.accountId,
      clientMutationId: mutationId,
      deliveryId,
      operation,
      expectedRevision,
      fingerprint: digest,
      requestFingerprint: requestDigest,
    });
    if (claim.duplicate) {
      return {
        scheduledDelivery: (await loadDelivery(tx, input.accountId, deliveryId))!,
        collectionRevision: claim.receiptRevision ?? existing.revision,
        pts: 0,
        clientMutationId: mutationId,
        duplicate: true,
        serverNow: new Date().toISOString(),
      };
    }
    await consumeMutationBudget(tx, input.accountId, "write");
    const locked = (await tx`
      SELECT state, revision, dialog_id
      FROM scheduled_deliveries
      WHERE id = ${deliveryId} AND account_id = ${input.accountId}
      FOR UPDATE`)[0];
    if (!locked) throw new ScheduledDeliveryError("schedule not found", "schedule_not_found", 404);
    if (locked.state !== "scheduled") {
      throw new ScheduledDeliveryError("schedule can no longer be edited", "schedule_processing", 409);
    }
    if (n(locked.revision) !== expectedRevision) {
      throw new ScheduledDeliveryError(
        "schedule was changed on another device",
        "schedule_revision_conflict",
        409,
        undefined,
        { scheduledDelivery: existing },
      );
    }
    await validateItems(tx, input.accountId, String(locked.dialog_id), items);
    await validateReminder(tx, input.accountId, String(locked.dialog_id), canonical.reminder);
    const collection = (await tx`
      UPDATE account_scheduled_delivery_states
      SET revision = revision + 1, updated_at = now()
      WHERE account_id = ${input.accountId}
      RETURNING revision`)[0];
    const revision = n(collection.revision);
    await tx`
      UPDATE scheduled_deliveries SET
        deliver_at = ${deliverAt}, available_at = ${deliverAt}, silent = ${canonical.silent},
        reminder = ${canonical.reminder}, revision = ${revision}, updated_at = now(),
        attempts = 0, last_error_code = NULL
      WHERE id = ${deliveryId}`;
    await replaceItems(tx, input.accountId, deliveryId, items);
    const pts = await appendScheduleEvent(tx, {
      accountId: input.accountId,
      sourceDeviceId: input.deviceId,
      type: "scheduled.updated",
      deliveryId,
      collectionRevision: revision,
      clientMutationId: mutationId,
    });
    await tx`
      UPDATE scheduled_delivery_mutation_requests
      SET status = 'completed', result_revision = ${revision}
      WHERE account_id = ${input.accountId} AND client_mutation_id = ${mutationId}`;
    return {
      scheduledDelivery: (await loadDelivery(tx, input.accountId, deliveryId))!,
      collectionRevision: revision,
      pts,
      clientMutationId: mutationId,
      duplicate: false,
      serverNow: new Date().toISOString(),
    };
  });
}

export async function cancelScheduledDelivery(
  sql: SQL,
  input: { accountId: string; deviceId: string; deliveryId: string; body: any },
): Promise<ScheduledDeliveryMutationResult> {
  const deliveryId = requireUUID(input.deliveryId, "schedule id");
  const mutationId = requireUUID(input.body?.clientMutationId, "client mutation id");
  const expectedRevision = Number(input.body?.expectedRevision);
  if (!Number.isSafeInteger(expectedRevision) || expectedRevision <= 0) {
    throw new ScheduledDeliveryError("expected revision is invalid");
  }
  const digest = fingerprint("cancel", deliveryId, { expectedRevision });
  const requestDigest = fingerprint("cancel-request", deliveryId, { expectedRevision });
  return await sql.begin(async (tx) => {
    await lockMutationKeys(tx, [`scheduled-receipt:${input.accountId}:${mutationId}`]);
    await lockAccountMutations(tx, [input.accountId]);
    await requireActiveDevice(tx, input.accountId, input.deviceId);
    const claim = await claimMutation(tx, {
      accountId: input.accountId,
      clientMutationId: mutationId,
      deliveryId,
      operation: "cancel",
      expectedRevision,
      fingerprint: digest,
      requestFingerprint: requestDigest,
    });
    const existing = await loadDelivery(tx, input.accountId, deliveryId);
    if (!existing) throw new ScheduledDeliveryError("schedule not found", "schedule_not_found", 404);
    if (claim.duplicate) {
      return {
        scheduledDelivery: existing,
        collectionRevision: claim.receiptRevision ?? existing.revision,
        pts: 0,
        clientMutationId: mutationId,
        duplicate: true,
        serverNow: new Date().toISOString(),
      };
    }
    await consumeMutationBudget(tx, input.accountId, "cancel");
    const locked = (await tx`
      SELECT state, revision FROM scheduled_deliveries
      WHERE id = ${deliveryId} AND account_id = ${input.accountId}
      FOR UPDATE`)[0];
    if (locked.state === "delivered") {
      throw new ScheduledDeliveryError(
        "schedule already delivered",
        "already_delivered",
        409,
        undefined,
        { firstMsgId: existing.deliveredFirstMsgId, lastMsgId: existing.deliveredLastMsgId },
      );
    }
    if (locked.state === "processing") {
      throw new ScheduledDeliveryError("schedule dispatch already started", "schedule_processing", 409);
    }
    if (n(locked.revision) !== expectedRevision && locked.state === "scheduled") {
      throw new ScheduledDeliveryError(
        "schedule was changed on another device",
        "schedule_revision_conflict",
        409,
        undefined,
        { scheduledDelivery: existing },
      );
    }
    if (locked.state !== "canceled") {
      const collection = (await tx`
        UPDATE account_scheduled_delivery_states
        SET revision = revision + 1, updated_at = now()
        WHERE account_id = ${input.accountId}
        RETURNING revision`)[0];
      const revision = n(collection.revision);
      await tx`
        UPDATE scheduled_deliveries SET
          state = 'canceled', revision = ${revision}, completed_at = now(), updated_at = now(),
          claimed_at = NULL, lease_expires_at = NULL, lease_token = NULL,
          last_error_code = NULL
        WHERE id = ${deliveryId}`;
      await tx`
        UPDATE scheduled_delivery_items SET
          payload_key_id = NULL, payload_nonce = NULL, payload_ciphertext = NULL, media_id = NULL
        WHERE delivery_id = ${deliveryId}`;
      const pts = await appendScheduleEvent(tx, {
        accountId: input.accountId,
        sourceDeviceId: input.deviceId,
        type: "scheduled.canceled",
        deliveryId,
        collectionRevision: revision,
        clientMutationId: mutationId,
      });
      await tx`
        UPDATE scheduled_delivery_mutation_requests
        SET status = 'completed', result_revision = ${revision}
        WHERE account_id = ${input.accountId} AND client_mutation_id = ${mutationId}`;
      return {
        scheduledDelivery: (await loadDelivery(tx, input.accountId, deliveryId))!,
        collectionRevision: revision,
        pts,
        clientMutationId: mutationId,
        duplicate: false,
        serverNow: new Date().toISOString(),
      };
    }
    await tx`
      UPDATE scheduled_delivery_mutation_requests
      SET status = 'completed', result_revision = ${existing.revision}
      WHERE account_id = ${input.accountId} AND client_mutation_id = ${mutationId}`;
    return {
      scheduledDelivery: existing,
      collectionRevision: existing.revision,
      pts: 0,
      clientMutationId: mutationId,
      duplicate: false,
      serverNow: new Date().toISOString(),
    };
  });
}

async function claimDue(sql: SQL, limit: number, leaseSeconds: number): Promise<WorkerClaim[]> {
  return await sql.begin(async (tx) => {
    const rows = await tx`
      WITH candidates AS (
        SELECT id
        FROM scheduled_deliveries
        WHERE (
          state = 'scheduled' AND deliver_at <= now() AND available_at <= now()
        ) OR (
          state = 'processing' AND lease_expires_at <= now()
        )
        ORDER BY deliver_at, id
        LIMIT ${limit}
        FOR UPDATE SKIP LOCKED
      )
      UPDATE scheduled_deliveries delivery SET
        state = 'processing', attempts = delivery.attempts + 1,
        claimed_at = now(),
        lease_expires_at = now() + (${leaseSeconds}::text || ' seconds')::interval,
        lease_token = gen_random_uuid(), updated_at = now()
      FROM candidates
      WHERE delivery.id = candidates.id
      RETURNING delivery.id, delivery.lease_token`;
    return rows.map((row: any) => ({
      id: String(row.id),
      leaseToken: String(row.lease_token),
    }));
  });
}

async function renewScheduledDeliveryLease(
  sql: SQL,
  claim: WorkerClaim,
  leaseSeconds: number,
): Promise<boolean> {
  try {
    const rows = await sql`
      UPDATE scheduled_deliveries
      SET lease_expires_at = now() + (${leaseSeconds}::text || ' seconds')::interval,
          updated_at = now()
      WHERE id = ${claim.id} AND state = 'processing' AND lease_token = ${claim.leaseToken}
      RETURNING id`;
    return rows.length === 1;
  } catch {
    return false;
  }
}

async function returnForRetry(
  sql: SQL,
  claim: WorkerClaim,
  attempts: number,
  code: string,
): Promise<void> {
  const delaySeconds = Math.min(300, Math.max(1, 2 ** Math.min(8, attempts)));
  await sql`
    UPDATE scheduled_deliveries SET
      state = 'scheduled', available_at = now() + (${delaySeconds}::text || ' seconds')::interval,
      claimed_at = NULL, lease_expires_at = NULL, lease_token = NULL,
      last_error_code = ${code}, updated_at = now()
    WHERE id = ${claim.id} AND state = 'processing' AND lease_token = ${claim.leaseToken}`;
}

async function markPermanentFailure(
  sql: SQL,
  claim: WorkerClaim,
  code: string,
): Promise<void> {
  await sql.begin(async (tx) => {
    const candidate = (await tx`
      SELECT account_id FROM scheduled_deliveries
      WHERE id = ${claim.id} AND state = 'processing' AND lease_token = ${claim.leaseToken}
    `)[0];
    if (!candidate) return;
    const accountId = String(candidate.account_id);
    // Scheduled mutations acquire the account advisory lock before their delivery row. Follow the
    // same order here, then revalidate token ownership under the row lock; reversing those locks can
    // deadlock a cancellation against worker completion.
    await lockAccountMutations(tx, [accountId]);
    const owned = (await tx`
      SELECT 1 FROM scheduled_deliveries
      WHERE id = ${claim.id} AND account_id = ${accountId}
        AND state = 'processing' AND lease_token = ${claim.leaseToken}
      FOR UPDATE`)[0];
    if (!owned) return;
    const collection = (await tx`
      UPDATE account_scheduled_delivery_states
      SET revision = revision + 1, updated_at = now()
      WHERE account_id = ${accountId}
      RETURNING revision`)[0];
    const revision = n(collection.revision);
    await tx`
      UPDATE scheduled_deliveries SET
        state = 'failed', revision = ${revision}, last_error_code = ${code},
        claimed_at = NULL, lease_expires_at = NULL, lease_token = NULL,
        completed_at = now(), updated_at = now()
      WHERE id = ${claim.id}`;
    await tx`
      UPDATE scheduled_delivery_items SET
        payload_key_id = NULL, payload_nonce = NULL, payload_ciphertext = NULL, media_id = NULL
      WHERE delivery_id = ${claim.id}`;
    await appendScheduleEvent(tx, {
      accountId,
      type: "scheduled.failed",
      deliveryId: claim.id,
      collectionRevision: revision,
    });
  });
}

async function dispatchClaim(sql: SQL, claim: WorkerClaim): Promise<void> {
  const header = (await sql`
    SELECT account_id, origin_device_id, dialog_id, silent, reminder, attempts
    FROM scheduled_deliveries
    WHERE id = ${claim.id} AND state = 'processing' AND lease_token = ${claim.leaseToken}`)[0];
  if (!header) return;
  const accountId = String(header.account_id);
  const delivery = await loadDelivery(sql, accountId, claim.id);
  if (!delivery || delivery.items.length === 0) {
    await markPermanentFailure(sql, claim, "payload_unavailable");
    return;
  }
  try {
    let firstMsgId: number;
    let lastMsgId: number;
    if (delivery.items.length === 1) {
      const item = delivery.items[0];
      const send = async (replyToMsgId: number | null, mentions: unknown) => await sendMessage(sql, {
        senderAccountId: accountId,
        senderDeviceId: null,
        dialogId: delivery.dialogId,
        clientMsgId: item.clientMsgId,
        kind: item.kind,
        body: item.body,
        replyToMsgId,
        mediaId: item.mediaId,
        mentions,
        silent: delivery.silent,
        scheduledDeliveryId: delivery.id,
        linkPreviewCandidate: item.linkPreviewCandidate,
        linkPreviewsEnabled: linkPreviewsEnabledForAccount(accountId),
      });
      let result;
      try {
        result = await send(item.replyToMsgId, item.mentions);
      } catch (error) {
        if (error instanceof SyncError && error.code === "invalid_reply_target") {
          result = await send(null, item.mentions);
        } else if (error instanceof SyncError && error.message.includes("mention")) {
          result = await send(item.replyToMsgId, []);
        } else {
          throw error;
        }
      }
      firstMsgId = result.msgId;
      lastMsgId = result.msgId;
    } else {
      const first = delivery.items[0];
      const run = async (replyToMsgId: number | null, mentions: unknown) => await sendMediaGroup(sql, {
        senderAccountId: accountId,
        senderDeviceId: null,
        dialogId: delivery.dialogId,
        clientGroupId: delivery.id,
        items: delivery.items.map((item) => ({
          mediaId: item.mediaId,
          clientMsgId: item.clientMsgId,
        })),
        body: first.body,
        replyToMsgId,
        mentions,
        silent: delivery.silent,
        scheduledDeliveryId: delivery.id,
        internalService: true,
        linkPreviewCandidate: first.linkPreviewCandidate,
        linkPreviewsEnabled: linkPreviewsEnabledForAccount(accountId),
      });
      let result;
      try {
        result = await run(first.replyToMsgId, first.mentions);
      } catch (error) {
        if (error instanceof SyncError && error.code === "invalid_reply_target") {
          result = await run(null, first.mentions);
        } else if (error instanceof SyncError && error.message.includes("mention")) {
          result = await run(first.replyToMsgId, []);
        } else {
          throw error;
        }
      }
      firstMsgId = result.messages[0].msg_id;
      lastMsgId = result.messages.at(-1)!.msg_id;
    }
    await sql.begin(async (tx) => {
      const candidate = (await tx`
        SELECT account_id FROM scheduled_deliveries
        WHERE id = ${claim.id} AND state = 'processing' AND lease_token = ${claim.leaseToken}
      `)[0];
      if (!candidate) return;
      const completedAccountId = String(candidate.account_id);
      await lockAccountMutations(tx, [completedAccountId]);
      const owned = (await tx`
        SELECT 1 FROM scheduled_deliveries
        WHERE id = ${claim.id} AND account_id = ${completedAccountId}
          AND state = 'processing' AND lease_token = ${claim.leaseToken}
        FOR UPDATE`)[0];
      if (!owned) return;
      const collection = (await tx`
        UPDATE account_scheduled_delivery_states
        SET revision = revision + 1, updated_at = now()
        WHERE account_id = ${completedAccountId}
        RETURNING revision`)[0];
      const revision = n(collection.revision);
      await tx`
        UPDATE scheduled_deliveries SET
          state = 'delivered', delivered_first_msg_id = ${firstMsgId},
          delivered_last_msg_id = ${lastMsgId}, last_error_code = NULL,
          revision = ${revision},
          claimed_at = NULL, lease_expires_at = NULL, lease_token = NULL,
          completed_at = now(), updated_at = now()
        WHERE id = ${claim.id}`;
      await tx`
        UPDATE scheduled_delivery_items SET
          payload_key_id = NULL, payload_nonce = NULL, payload_ciphertext = NULL, media_id = NULL
        WHERE delivery_id = ${claim.id}`;
      await appendScheduleEvent(tx, {
        accountId: completedAccountId,
        type: "scheduled.updated",
        deliveryId: claim.id,
        collectionRevision: revision,
      });
    });
  } catch (error) {
    if (error instanceof SyncError && error.status < 500 && error.status !== 429) {
      await markPermanentFailure(sql, claim, error.code);
    } else {
      await returnForRetry(
        sql,
        claim,
        n(header.attempts),
        error instanceof SyncError ? error.code : "infrastructure_unavailable",
      );
    }
  }
}

export async function drainScheduledDeliveries(
  sql: SQL,
  limit = scheduledDeliveryWorkerConcurrency(),
  options: { concurrency?: number; leaseSeconds?: number; renewEveryMilliseconds?: number } = {},
): Promise<number> {
  const concurrency = Math.max(1, Math.min(32, options.concurrency ?? scheduledDeliveryWorkerConcurrency()));
  const leaseSeconds = Math.max(30, Math.min(600, options.leaseSeconds ?? productivityWorkerLeaseSeconds()));
  const renewEveryMilliseconds = Math.max(1_000, Math.min(
    30_000,
    Math.floor(leaseSeconds * 1_000 / 3),
    options.renewEveryMilliseconds ?? 30_000,
  ));
  const claims = await claimDue(sql, Math.max(1, Math.min(concurrency, limit)), leaseSeconds);
  await Promise.all(claims.map(async (claim) => {
    let finished = false;
    let renewalRunning = false;
    const renew = async () => {
      if (finished || renewalRunning) return;
      renewalRunning = true;
      const owned = await renewScheduledDeliveryLease(sql, claim, leaseSeconds);
      renewalRunning = false;
      if (!owned && !finished) recordProductivityLeaseRenewalFailure("scheduled_delivery");
    };
    const renewalTimer = setInterval(() => void renew(), renewEveryMilliseconds);
    renewalTimer.unref?.();
    adjustProductivityActiveJobs("scheduled_delivery", 1);
    try {
      await dispatchClaim(sql, claim);
    } finally {
      finished = true;
      clearInterval(renewalTimer);
      adjustProductivityActiveJobs("scheduled_delivery", -1);
    }
  }));
  return claims.length;
}

/** Immediately erases undelivered content when an account loses dialog access. */
export async function failScheduledDeliveriesForRevokedDialogInTransaction(
  tx: SQL,
  accountId: string,
  dialogId: string,
): Promise<void> {
  await lockAccountMutations(tx, [accountId]);
  const rows = await tx`
    SELECT id FROM scheduled_deliveries
    WHERE account_id = ${accountId} AND dialog_id = ${dialogId}
      AND state IN ('scheduled','processing')
    ORDER BY id
    FOR UPDATE`;
  for (const row of rows) {
    const deliveryId = String(row.id);
    const collection = (await tx`
      UPDATE account_scheduled_delivery_states
      SET revision = revision + 1, updated_at = now()
      WHERE account_id = ${accountId}
      RETURNING revision`)[0];
    if (!collection) continue;
    const revision = n(collection.revision);
    await tx`
      UPDATE scheduled_deliveries SET
        state = 'failed', revision = ${revision}, last_error_code = 'access_revoked',
        claimed_at = NULL, lease_expires_at = NULL, lease_token = NULL,
        completed_at = now(), updated_at = now()
      WHERE id = ${deliveryId}`;
    await tx`
      UPDATE scheduled_delivery_items SET
        payload_key_id = NULL, payload_nonce = NULL, payload_ciphertext = NULL, media_id = NULL
      WHERE delivery_id = ${deliveryId}`;
    await appendScheduleEvent(tx, {
      accountId,
      type: "scheduled.failed",
      deliveryId,
      collectionRevision: revision,
    });
  }
}

export function startScheduledDeliveryWorker(
  sql: SQL,
  options: {
    pollMilliseconds?: number;
    workerId?: string;
    concurrency?: number;
    leaseSeconds?: number;
    renewEveryMilliseconds?: number;
    heartbeatMilliseconds?: number;
    shutdownDrainMilliseconds?: number;
  } = {},
): () => Promise<void> {
  const workerId = options.workerId ?? crypto.randomUUID();
  const pollMilliseconds = Math.max(250, options.pollMilliseconds ?? 1_000);
  const concurrency = Math.max(1, Math.min(32, options.concurrency ?? scheduledDeliveryWorkerConcurrency()));
  const leaseSeconds = Math.max(30, Math.min(600, options.leaseSeconds ?? productivityWorkerLeaseSeconds()));
  const heartbeatMilliseconds = Math.max(1_000, options.heartbeatMilliseconds ?? 10_000);
  const shutdownDrainMilliseconds = Math.max(1_000, options.shutdownDrainMilliseconds ?? 15_000);
  let stopped = false;
  let running: Promise<void> | null = null;
  let heartbeatRunning = false;
  const tick = async () => {
    if (stopped || running) return;
    const work = (async () => {
      try {
        await drainScheduledDeliveries(sql, concurrency, {
          concurrency,
          leaseSeconds,
          renewEveryMilliseconds: options.renewEveryMilliseconds,
        });
      } catch {
        // No identifiers or schedule content belong in logs. Health is represented by heartbeat age.
      }
    })();
    running = work;
    await work.finally(() => {
      if (running === work) running = null;
    });
  };
  const heartbeat = async () => {
    if (stopped || heartbeatRunning) return;
    heartbeatRunning = true;
    try {
      await touchWorkerHeartbeat(sql, "scheduled_delivery", workerId);
    } catch {
      // The cached heartbeat snapshot fails closed; the worker keeps retrying independently.
    } finally {
      heartbeatRunning = false;
    }
  };
  void heartbeat();
  void tick();
  const timer = setInterval(() => void tick(), pollMilliseconds);
  const heartbeatTimer = setInterval(() => void heartbeat(), heartbeatMilliseconds);
  timer.unref?.();
  heartbeatTimer.unref?.();
  return async () => {
    stopped = true;
    clearInterval(timer);
    clearInterval(heartbeatTimer);
    const active = running;
    if (!active) return;
    await Promise.race([
      active,
      new Promise<void>((resolve) => {
        const drainTimer = setTimeout(resolve, shutdownDrainMilliseconds);
        drainTimer.unref?.();
      }),
    ]);
  };
}
