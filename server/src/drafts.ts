import type { SQL } from "bun";
import { timingSafeEqual } from "node:crypto";
import { requireActiveDevice } from "./auth";
import { draftBodyAAD, draftResponseAAD, requestFingerprintIndex } from "./crypto";
import {
  DialogAccessError,
  lockDialogForMutation,
  requireDialogReadAccess,
} from "./dialog-access";
import { fanoutDialogEvent, type FanoutPush } from "./fanout";
import {
  draftMutationReceiptKey,
  lockAccountMutations,
  lockMutationKeys,
} from "./locks";
import { mediaDTOFromRow, type MediaDTO } from "./media";
import { notifySyncWakeups } from "./sync-wakeup";
import { openForScope, preloadEnvelopeKeys, sealForScope } from "./envelope-crypto";
import { EXPIRED_BLIND_INDEX_KEY_ID } from "./blind-index";

export class DraftError extends Error {
  constructor(
    message: string,
    readonly status = 400,
    readonly code = "invalid_draft_request",
    readonly retryAfter?: number,
  ) {
    super(message);
    this.name = "DraftError";
  }
}

export type DraftMentionDTO = {
  account_id: string;
  offset: number;
  length: number;
};

export type DraftAttachmentDTO = {
  attachment_id: string;
  media_id: string;
  position: number;
  media: MediaDTO;
};

export type DraftReplyPreviewDTO = {
  msg_id: number;
  sender_account_id: string;
  text: string;
  unavailable: boolean;
};

export type DraftDTO = {
  dialog_id: string;
  revision: number;
  state: "active" | "cleared";
  text: string;
  reply_to_msg_id: number | null;
  reply_preview: DraftReplyPreviewDTO | null;
  mentions: DraftMentionDTO[];
  attachments: DraftAttachmentDTO[];
  operation_id: string;
  updated_at: string;
};

export type DraftMutationResult = {
  draft: DraftDTO;
  duplicate: boolean;
  pushes: FanoutPush[];
};

export type DraftConsumeResult = {
  revision: number;
  pushes: FanoutPush[];
} | null;

type NormalizedAttachment = {
  attachmentId: string;
  mediaId: string;
  position: number;
};

type NormalizedDraft = {
  state: "active" | "cleared";
  text: string;
  replyToMsgId: number | null;
  mentions: DraftMentionDTO[];
  attachments: NormalizedAttachment[];
};

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_TEXT_BYTES = 16 * 1024;
const MAX_ATTACHMENTS = 10;
const MAX_MUTATIONS_PER_MINUTE = 120;

const n = (value: unknown) => Number(value as any);
const buf = (value: unknown) => Buffer.from(value as Uint8Array);
const iso = (value: unknown) => value instanceof Date ? value.toISOString() : String(value);

function jsonValue<T>(value: unknown, fallback: T): T {
  if (value == null) return fallback;
  if (typeof value === "string") return JSON.parse(value) as T;
  return value as T;
}

function requireUUID(value: unknown, name: string): string {
  const normalized = String(value ?? "").toLowerCase();
  if (!UUID_PATTERN.test(normalized)) throw new DraftError(`invalid ${name}`);
  return normalized;
}

function optionalMessageId(value: unknown): number | null {
  if (value == null) return null;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new DraftError("invalid reply target", 400, "invalid_reply_target");
  }
  return parsed;
}

function normalizeMentions(value: unknown, text: string): DraftMentionDTO[] {
  if (value == null) return [];
  if (!Array.isArray(value)) throw new DraftError("mentions must be an array");
  if (value.length > 100) throw new DraftError("too many mentions");
  const seen = new Set<string>();
  return value.map((raw: any) => {
    const accountId = requireUUID(raw?.account_id ?? raw?.accountId, "mention account");
    const offset = Number(raw?.offset);
    const length = Number(raw?.length);
    // JavaScript String.length is UTF-16 code units, matching NSRange on iOS.
    if (!Number.isSafeInteger(offset) || offset < 0
      || !Number.isSafeInteger(length) || length <= 0
      || offset + length > text.length) {
      throw new DraftError("invalid mention range");
    }
    if (seen.has(accountId)) throw new DraftError("duplicate mention target");
    seen.add(accountId);
    return { account_id: accountId, offset, length };
  }).sort((left, right) =>
    left.offset - right.offset || left.account_id.localeCompare(right.account_id)
  );
}

function normalizeAttachments(value: unknown): NormalizedAttachment[] {
  if (value == null) return [];
  if (!Array.isArray(value)) throw new DraftError("attachments must be an array");
  if (value.length > MAX_ATTACHMENTS) throw new DraftError("too many draft attachments");
  const attachmentIds = new Set<string>();
  const mediaIds = new Set<string>();
  const normalized = value.map((raw: any) => {
    const attachmentId = requireUUID(raw?.attachment_id ?? raw?.attachmentId, "attachment id");
    const mediaId = requireUUID(raw?.media_id ?? raw?.mediaId, "media id");
    const position = Number(raw?.position);
    if (!Number.isSafeInteger(position) || position < 0 || position >= MAX_ATTACHMENTS) {
      throw new DraftError("invalid attachment position");
    }
    if (attachmentIds.has(attachmentId) || mediaIds.has(mediaId)) {
      throw new DraftError("duplicate draft attachment");
    }
    attachmentIds.add(attachmentId);
    mediaIds.add(mediaId);
    return { attachmentId, mediaId, position };
  }).sort((left, right) => left.position - right.position);
  if (normalized.some((attachment, index) => attachment.position !== index)) {
    throw new DraftError("attachment positions must be contiguous");
  }
  return normalized;
}

function normalizeDraft(input: {
  state?: unknown;
  text?: unknown;
  reply_to_msg_id?: unknown;
  replyToMsgId?: unknown;
  mentions?: unknown;
  attachments?: unknown;
}): NormalizedDraft {
  const requestedState = input.state == null ? "active" : String(input.state);
  if (requestedState !== "active" && requestedState !== "cleared") {
    throw new DraftError("invalid draft state");
  }
  if (input.text != null && typeof input.text !== "string") {
    throw new DraftError("draft text must be a string");
  }
  const text = String(input.text ?? "");
  if (Buffer.byteLength(text, "utf8") > MAX_TEXT_BYTES) throw new DraftError("draft text too large");
  const replyToMsgId = optionalMessageId(input.reply_to_msg_id ?? input.replyToMsgId);
  const attachments = normalizeAttachments(input.attachments);
  const mentions = normalizeMentions(input.mentions, text);
  const hasContent = text.trim().length > 0 || replyToMsgId != null || attachments.length > 0;
  const state = requestedState === "cleared" || !hasContent ? "cleared" : "active";
  return state === "cleared"
    ? { state, text: "", replyToMsgId: null, mentions: [], attachments: [] }
    : { state, text, replyToMsgId, mentions, attachments };
}

function draftFingerprint(dialogId: string, draft: NormalizedDraft): {
  canonical: string; digest: Buffer; keyId: string;
} {
  const canonical = JSON.stringify({
    dialog_id: dialogId,
    state: draft.state,
    text: draft.text,
    reply_to_msg_id: draft.replyToMsgId,
    mentions: draft.mentions,
    attachments: draft.attachments.map((attachment) => ({
      attachment_id: attachment.attachmentId,
      media_id: attachment.mediaId,
      position: attachment.position,
    })),
  });
  const index = requestFingerprintIndex("draft-mutation", canonical);
  return { canonical, digest: index.digest, keyId: index.keyId };
}

async function draftFromCachedResponse(
  sql: SQL, row: any, accountId: string, operationId: string,
): Promise<DraftDTO> {
  if (row.status !== "completed" || row.response_key_id == null
    || row.response_nonce == null || row.response_ciphertext == null) {
    throw new DraftError("draft mutation already in progress", 409, "draft_mutation_in_progress");
  }
  return JSON.parse((await openForScope(sql, { kind: "account", accountId }, {
    keyId: row.response_key_id,
    nonce: buf(row.response_nonce),
    ciphertext: buf(row.response_ciphertext),
  }, draftResponseAAD(accountId, operationId))).toString("utf8")) as DraftDTO;
}

function requireMatchingFingerprint(
  row: any,
  dialogId: string,
  fingerprint: { canonical: string; digest: Buffer; keyId: string },
): void {
  const existingFingerprint = buf(row.payload_fingerprint);
  const expected = requestFingerprintIndex(
    "draft-mutation",
    fingerprint.canonical,
    row.fingerprint_key_id ?? "legacy-v1",
  ).digest;
  if (row.dialog_id !== dialogId
    || existingFingerprint.length !== expected.length
    || !timingSafeEqual(existingFingerprint, expected)) {
    throw new DraftError(
      "operation id already used with a different draft",
      409,
      "draft_idempotency_conflict",
    );
  }
}

async function authorizeDuplicate(
  sql: SQL,
  accountId: string,
  deviceId: string,
  dialogId: string,
): Promise<void> {
  await requireActiveDevice(sql, accountId, deviceId);
  try {
    await requireDialogReadAccess(sql, accountId, dialogId);
  } catch (error) {
    if (error instanceof DialogAccessError) {
      throw new DraftError("dialog access denied", 403, "dialog_access_denied");
    }
    throw error;
  }
}

/**
 * Batch-loads account-private drafts and their ready media. Bootstrap/difference callers pass a
 * bounded dialog page, so this remains two queries and never falls into per-dialog media lookups.
 */
export async function loadDrafts(
  sql: SQL,
  accountId: string,
  dialogIds?: string[],
): Promise<Map<string, DraftDTO>> {
  const ids = dialogIds == null ? null : [...new Set(dialogIds)];
  if (ids?.length === 0) return new Map();
  const drafts = ids == null
    ? await sql`
        SELECT draft.*, reply.sender_account_id AS reply_sender_account_id,
               reply.state AS reply_state, reply.body_key_id AS reply_body_key_id,
               reply.body_nonce AS reply_body_nonce, reply.body_ciphertext AS reply_body_ciphertext,
               reply.expires_at AS reply_expires_at
        FROM account_dialog_drafts draft
        LEFT JOIN messages reply
          ON reply.dialog_id = draft.dialog_id AND reply.msg_id = draft.reply_to_msg_id
        WHERE draft.account_id = ${accountId}
        ORDER BY draft.dialog_id`
    : await sql`
        SELECT draft.*, reply.sender_account_id AS reply_sender_account_id,
               reply.state AS reply_state, reply.body_key_id AS reply_body_key_id,
               reply.body_nonce AS reply_body_nonce, reply.body_ciphertext AS reply_body_ciphertext,
               reply.expires_at AS reply_expires_at
        FROM account_dialog_drafts draft
        LEFT JOIN messages reply
          ON reply.dialog_id = draft.dialog_id AND reply.msg_id = draft.reply_to_msg_id
        WHERE draft.account_id = ${accountId}
          AND draft.dialog_id = ANY(${sql.array(ids, "uuid")}::uuid[])
        ORDER BY draft.dialog_id`;
  if (drafts.length === 0) return new Map();

  const draftDialogIds = drafts.map((row: any) => String(row.dialog_id));
  const attachments = await sql`
    SELECT attachment.account_id, attachment.dialog_id, attachment.attachment_id,
           attachment.media_id, attachment.position,
           media.id, media.kind, media.content_type, media.file_name,
           media.file_name_key_id, media.file_name_nonce, media.file_name_ciphertext,
           media.byte_size, media.duration_ms, media.width, media.height,
           media.thumbnail_ciphertext
    FROM draft_attachments attachment
    JOIN media_objects media ON media.id = attachment.media_id AND media.status = 'ready'
    WHERE attachment.account_id = ${accountId}
      AND attachment.dialog_id = ANY(${sql.array(draftDialogIds, "uuid")}::uuid[])
    ORDER BY attachment.dialog_id, attachment.position`;
  const attachmentsByDialog = new Map<string, DraftAttachmentDTO[]>();
  await preloadEnvelopeKeys(sql, [
    ...drafts.flatMap((row: any) => [row.body_key_id, row.reply_body_key_id]),
    ...attachments.map((row: any) => row.file_name_key_id),
  ].filter(Boolean).map(String));
  for (const row of attachments) {
    const dialogId = String(row.dialog_id);
    const current = attachmentsByDialog.get(dialogId) ?? [];
    current.push({
      attachment_id: row.attachment_id,
      media_id: row.media_id,
      position: n(row.position),
      media: await mediaDTOFromRow(sql, row),
    });
    attachmentsByDialog.set(dialogId, current);
  }

  const result = new Map<string, DraftDTO>();
  for (const row of drafts) {
    const dialogId = String(row.dialog_id);
    const revision = n(row.revision);
    const text = (await openForScope(sql, { kind: "account", accountId }, {
      keyId: row.body_key_id,
      nonce: buf(row.body_nonce),
      ciphertext: buf(row.body_ciphertext),
    }, draftBodyAAD(accountId, dialogId, revision))).toString("utf8");
    const replyToMsgId = row.reply_to_msg_id == null ? null : n(row.reply_to_msg_id);
    let replyPreview: DraftReplyPreviewDTO | null = null;
    if (replyToMsgId != null) {
      const unavailable = row.reply_state !== "visible" || (
        row.reply_expires_at != null
        && new Date(row.reply_expires_at).getTime() <= Date.now()
      );
      const replyText = unavailable || row.reply_body_ciphertext == null ? "" : (await openForScope(
        sql,
        { kind: "account", accountId: String(row.reply_sender_account_id) },
        {
          keyId: row.reply_body_key_id,
          nonce: buf(row.reply_body_nonce),
          ciphertext: buf(row.reply_body_ciphertext),
        },
        Buffer.from(
          `toj/msg|${dialogId}|${replyToMsgId}|${row.reply_sender_account_id}`,
          "utf8",
        ),
      )).toString("utf8");
      replyPreview = {
        msg_id: replyToMsgId,
        sender_account_id: row.reply_sender_account_id ?? "",
        text: replyText,
        unavailable,
      };
    }
    result.set(dialogId, {
      dialog_id: dialogId,
      revision,
      state: row.state,
      text: row.state === "cleared" ? "" : text,
      reply_to_msg_id: replyToMsgId,
      reply_preview: replyPreview,
      mentions: row.state === "cleared"
        ? []
        : jsonValue<DraftMentionDTO[]>(row.mentions, []),
      attachments: row.state === "cleared" ? [] : (attachmentsByDialog.get(dialogId) ?? []),
      operation_id: row.operation_id,
      updated_at: iso(row.updated_at),
    });
  }
  return result;
}

async function enforceMutationBudget(
  sql: SQL,
  accountId: string,
  deviceId: string,
  operationId: string,
): Promise<void> {
  const usage = (await sql`
    SELECT count(*)::int AS count
    FROM draft_mutation_budgets
    WHERE device_id = ${deviceId} AND accepted_at > now() - interval '1 minute'`)[0];
  if (n(usage?.count) >= MAX_MUTATIONS_PER_MINUTE) {
    throw new DraftError("draft mutation rate limit exceeded", 429, "draft_rate_limited", 60);
  }
  await sql`
    INSERT INTO draft_mutation_budgets (account_id, device_id, operation_id)
    VALUES (${accountId}, ${deviceId}, ${operationId})`;
}

export async function putDraft(sql: SQL, input: {
  accountId: string;
  deviceId: string;
  dialogId: string;
  operationId: string;
  state?: unknown;
  text?: unknown;
  replyToMsgId?: unknown;
  mentions?: unknown;
  attachments?: unknown;
}): Promise<DraftMutationResult> {
  const dialogId = requireUUID(input.dialogId, "dialog id");
  const operationId = requireUUID(input.operationId, "operation id");
  const normalized = normalizeDraft({
    state: input.state,
    text: input.text,
    replyToMsgId: input.replyToMsgId,
    mentions: input.mentions,
    attachments: input.attachments,
  });
  const fingerprint = draftFingerprint(dialogId, normalized);

  return await sql.begin(async (tx) => {
    // Cleanup moves completed receipts into compact tombstones under this same lock. Taking it
    // before either table is read makes the receipt+tombstone pair one serialized namespace:
    // cleanup can never delete the live row between this read and the idempotency claim.
    await lockMutationKeys(tx, [
      draftMutationReceiptKey(input.accountId, operationId),
    ]);
    const tombstone = (await tx`
      SELECT dialog_id, payload_fingerprint, fingerprint_key_id, resulting_revision
      FROM draft_mutation_tombstones
      WHERE account_id = ${input.accountId} AND operation_id = ${operationId}
      FOR SHARE`)[0];
    if (tombstone) {
      if (tombstone.fingerprint_key_id === EXPIRED_BLIND_INDEX_KEY_ID) {
        await authorizeDuplicate(tx, input.accountId, input.deviceId, String(tombstone.dialog_id));
        throw new DraftError(
          "draft receipt no longer has a recoverable result", 409, "draft_result_expired",
        );
      }
      requireMatchingFingerprint(tombstone, dialogId, fingerprint);
      if (String(tombstone.fingerprint_key_id ?? "legacy-v1") !== fingerprint.keyId) {
        await tx`UPDATE draft_mutation_tombstones
          SET payload_fingerprint = ${fingerprint.digest}, fingerprint_key_id = ${fingerprint.keyId}
          WHERE account_id = ${input.accountId} AND operation_id = ${operationId}`;
      }
      await authorizeDuplicate(tx, input.accountId, input.deviceId, dialogId);
      const current = (await loadDrafts(tx, input.accountId, [dialogId])).get(dialogId);
      if (!current) {
        throw new DraftError("draft receipt no longer has a recoverable result", 409, "draft_result_expired");
      }
      return { draft: current, duplicate: true, pushes: [] };
    }

    const claim = await tx`
      INSERT INTO draft_mutation_requests (
        account_id, operation_id, dialog_id, payload_fingerprint, fingerprint_key_id, status
      )
      VALUES (${input.accountId}, ${operationId}, ${dialogId},
              ${fingerprint.digest}, ${fingerprint.keyId}, 'pending')
      ON CONFLICT (account_id, operation_id) DO NOTHING
      RETURNING operation_id`;
    if (claim.length === 0) {
      const existing = (await tx`
        SELECT dialog_id, payload_fingerprint, fingerprint_key_id, status, response_key_id,
               response_nonce, response_ciphertext
        FROM draft_mutation_requests
        WHERE account_id = ${input.accountId} AND operation_id = ${operationId}
        FOR UPDATE`)[0];
      requireMatchingFingerprint(existing, dialogId, fingerprint);
      if (String(existing.fingerprint_key_id ?? "legacy-v1") !== fingerprint.keyId) {
        await tx`UPDATE draft_mutation_requests
          SET payload_fingerprint = ${fingerprint.digest}, fingerprint_key_id = ${fingerprint.keyId}
          WHERE account_id = ${input.accountId} AND operation_id = ${operationId}`;
      }
      await authorizeDuplicate(tx, input.accountId, input.deviceId, dialogId);
      return {
        draft: await draftFromCachedResponse(tx, existing, input.accountId, operationId),
        duplicate: true,
        pushes: [],
      };
    }

    await lockAccountMutations(tx, [input.accountId]);
    await requireActiveDevice(tx, input.accountId, input.deviceId);
    await enforceMutationBudget(tx, input.accountId, input.deviceId, operationId);

    const mediaIds = normalized.attachments.map((attachment) => attachment.mediaId).sort();
    if (mediaIds.length) {
      const media = await tx`
        SELECT id, owner_account_id, status, purpose
        FROM media_objects
        WHERE id = ANY(${tx.array(mediaIds, "uuid")}::uuid[])
        ORDER BY id
        FOR UPDATE`;
      if (media.length !== mediaIds.length
        || media.some((row: any) =>
          row.owner_account_id !== input.accountId
          || row.status !== "ready"
          || row.purpose !== "message"
        )) {
        throw new DraftError("draft attachment is unavailable", 409, "draft_attachment_unavailable");
      }
    }

    await lockDialogForMutation(tx, input.accountId, dialogId);
    if (normalized.replyToMsgId != null) {
      const reply = await tx`
        SELECT msg_id FROM messages
        WHERE dialog_id = ${dialogId} AND msg_id = ${normalized.replyToMsgId}
          AND state = 'visible'
          AND (expires_at IS NULL OR expires_at > now())`;
      if (!reply.length) {
        throw new DraftError("reply target not found", 409, "invalid_reply_target");
      }
    }
    if (normalized.mentions.length) {
      const accountIds = normalized.mentions.map((mention) => mention.account_id);
      const available = await tx`
        SELECT account_id
        FROM dialog_members
        WHERE dialog_id = ${dialogId} AND left_at IS NULL
          AND account_id = ANY(${tx.array(accountIds, "uuid")}::uuid[])`;
      if (available.length !== accountIds.length) {
        throw new DraftError("mention target is not an active member", 409, "invalid_mention_target");
      }
    }

    const previousAttachments = await tx`
      SELECT media_id FROM draft_attachments
      WHERE account_id = ${input.accountId} AND dialog_id = ${dialogId}
      ORDER BY media_id
      FOR UPDATE`;
    const pushes = await fanoutDialogEvent(tx, {
      dialogId,
      type: "draft.updated",
      actorAccountId: input.accountId,
      sourceDeviceId: input.deviceId,
      alertRecipients: false,
      recipientAccountIds: [input.accountId],
    });
    const revision = pushes[0]?.pts;
    if (!revision) throw new DraftError("unable to allocate draft revision", 409);
    const sealed = await sealForScope(
      tx,
      { kind: "account", accountId: input.accountId },
      normalized.state === "active" ? normalized.text : "",
      draftBodyAAD(input.accountId, dialogId, revision),
    );
    const stored = (await tx`
      INSERT INTO account_dialog_drafts (
        account_id, dialog_id, state, body_key_id, body_nonce, body_ciphertext,
        reply_to_msg_id, mentions, revision, operation_id, source_device_id
      )
      VALUES (
        ${input.accountId}, ${dialogId}, ${normalized.state}, ${sealed.keyId},
        ${sealed.nonce}, ${sealed.ciphertext}, ${normalized.replyToMsgId},
        ${JSON.stringify(normalized.mentions)}::jsonb, ${revision}, ${operationId}, ${input.deviceId}
      )
      ON CONFLICT (account_id, dialog_id) DO UPDATE SET
        state = excluded.state,
        body_key_id = excluded.body_key_id,
        body_nonce = excluded.body_nonce,
        body_ciphertext = excluded.body_ciphertext,
        reply_to_msg_id = excluded.reply_to_msg_id,
        mentions = excluded.mentions,
        revision = excluded.revision,
        operation_id = excluded.operation_id,
        source_device_id = excluded.source_device_id,
        updated_at = now()
      RETURNING updated_at`)[0];
    await tx`
      DELETE FROM draft_attachments
      WHERE account_id = ${input.accountId} AND dialog_id = ${dialogId}`;
    if (normalized.state === "active" && normalized.attachments.length) {
      await tx`
        INSERT INTO draft_attachments (
          account_id, dialog_id, attachment_id, media_id, position
        )
        SELECT ${input.accountId}, ${dialogId}, attachment_id, media_id, position
        FROM unnest(
          ${tx.array(normalized.attachments.map((item) => item.attachmentId), "uuid")}::uuid[],
          ${tx.array(normalized.attachments.map((item) => item.mediaId), "uuid")}::uuid[],
          ${tx.array(normalized.attachments.map((item) => item.position), "int2")}::smallint[]
        ) AS attachment(attachment_id, media_id, position)`;
    }
    const retained = new Set(normalized.attachments.map((attachment) => attachment.mediaId));
    const removed = previousAttachments
      .map((row: any) => String(row.media_id))
      .filter((mediaId: string) => !retained.has(mediaId));
    if (removed.length) {
      await tx`
        UPDATE media_objects SET last_accessed_at = now()
        WHERE id = ANY(${tx.array(removed, "uuid")}::uuid[])`;
    }

    const loaded = await loadDrafts(tx, input.accountId, [dialogId]);
    const draft = loaded.get(dialogId);
    if (!draft) throw new DraftError("draft persistence failed", 500);
    draft.updated_at = iso(stored.updated_at);
    const cached = await sealForScope(
      tx,
      { kind: "account", accountId: input.accountId },
      JSON.stringify(draft),
      draftResponseAAD(input.accountId, operationId),
    );
    await tx`
      UPDATE draft_mutation_requests SET
        status = 'completed',
        resulting_revision = ${revision},
        response_key_id = ${cached.keyId},
        response_nonce = ${cached.nonce},
        response_ciphertext = ${cached.ciphertext}
      WHERE account_id = ${input.accountId} AND operation_id = ${operationId}`;
    await notifySyncWakeups(tx, pushes);
    return { draft, duplicate: false, pushes };
  });
}

/**
 * Called only from an already-open message transaction after dialog/media locks are held. The
 * compare on operation_id is the stale-response shield: a newer local generation survives.
 */
export async function consumeDraftInTransaction(
  sql: SQL,
  input: {
    accountId: string;
    deviceId?: string | null;
    dialogId: string;
    operationId?: string | null;
  },
): Promise<DraftConsumeResult> {
  if (!input.operationId) return null;
  const operationId = requireUUID(input.operationId, "draft consume operation id");
  const current = (await sql`
    SELECT operation_id
    FROM account_dialog_drafts
    WHERE account_id = ${input.accountId} AND dialog_id = ${input.dialogId}
    FOR UPDATE`)[0];
  if (!current || current.operation_id !== operationId) return null;
  const attachments = await sql`
    SELECT media_id FROM draft_attachments
    WHERE account_id = ${input.accountId} AND dialog_id = ${input.dialogId}
    ORDER BY media_id
    FOR UPDATE`;
  const pushes = await fanoutDialogEvent(sql, {
    dialogId: input.dialogId,
    type: "draft.updated",
    actorAccountId: input.accountId,
    sourceDeviceId: input.deviceId,
    alertRecipients: false,
    recipientAccountIds: [input.accountId],
  });
  const revision = pushes[0]?.pts;
  if (!revision) throw new DraftError("unable to allocate draft revision", 409);
  const sealed = await sealForScope(
    sql,
    { kind: "account", accountId: input.accountId },
    "",
    draftBodyAAD(input.accountId, input.dialogId, revision),
  );
  await sql`
    UPDATE account_dialog_drafts SET
      state = 'cleared',
      body_key_id = ${sealed.keyId},
      body_nonce = ${sealed.nonce},
      body_ciphertext = ${sealed.ciphertext},
      reply_to_msg_id = NULL,
      mentions = '[]'::jsonb,
      revision = ${revision},
      operation_id = ${operationId},
      source_device_id = ${input.deviceId ?? null},
      updated_at = now()
    WHERE account_id = ${input.accountId} AND dialog_id = ${input.dialogId}`;
  await sql`
    DELETE FROM draft_attachments
    WHERE account_id = ${input.accountId} AND dialog_id = ${input.dialogId}`;
  const mediaIds = attachments.map((row: any) => String(row.media_id));
  if (mediaIds.length) {
    await sql`
      UPDATE media_objects SET last_accessed_at = now()
      WHERE id = ANY(${sql.array(mediaIds, "uuid")}::uuid[])`;
  }
  return { revision, pushes };
}

export async function getDraft(
  sql: SQL,
  accountId: string,
  dialogId: string,
): Promise<DraftDTO | null> {
  await requireDialogReadAccess(sql, accountId, dialogId);
  return (await loadDrafts(sql, accountId, [dialogId])).get(dialogId) ?? null;
}

/** Removes private draft state when membership is revoked while retaining compact replay shields. */
export async function purgeRevokedDialogDraftState(
  sql: SQL,
  accountId: string,
  dialogId: string,
): Promise<void> {
  const media = await sql`
    SELECT media_id FROM draft_attachments
    WHERE account_id = ${accountId} AND dialog_id = ${dialogId}
    FOR UPDATE`;
  await sql`
    INSERT INTO draft_mutation_tombstones (
      account_id, operation_id, dialog_id, payload_fingerprint, fingerprint_key_id,
      resulting_revision
    )
    SELECT account_id, operation_id, dialog_id, payload_fingerprint, fingerprint_key_id,
           resulting_revision
    FROM draft_mutation_requests
    WHERE account_id = ${accountId} AND dialog_id = ${dialogId} AND status = 'completed'
    ON CONFLICT (account_id, operation_id) DO NOTHING`;
  await sql`
    DELETE FROM draft_mutation_budgets budget
    USING draft_mutation_requests request
    WHERE request.account_id = ${accountId} AND request.dialog_id = ${dialogId}
      AND budget.account_id = request.account_id
      AND budget.operation_id = request.operation_id`;
  await sql`
    DELETE FROM draft_mutation_requests
    WHERE account_id = ${accountId} AND dialog_id = ${dialogId}`;
  await sql`
    DELETE FROM account_dialog_drafts
    WHERE account_id = ${accountId} AND dialog_id = ${dialogId}`;
  if (media.length) {
    const ids = media.map((row: any) => String(row.media_id));
    await sql`
      DELETE FROM media_objects media
      WHERE media.id = ANY(${sql.array(ids, "uuid")}::uuid[])
        AND media.owner_account_id = ${accountId}
        AND NOT EXISTS (SELECT 1 FROM messages WHERE media_id = media.id)
        AND NOT EXISTS (SELECT 1 FROM dialogs WHERE photo_media_id = media.id)
        AND NOT EXISTS (SELECT 1 FROM draft_attachments WHERE media_id = media.id)`;
  }
}

/** Account deletion is anonymization, not a physical account-row delete, so cascades do not run. */
export async function purgeAccountDraftState(sql: SQL, accountId: string): Promise<void> {
  const mediaRows = await sql`
    SELECT media_id FROM draft_attachments
    WHERE account_id = ${accountId}
    FOR UPDATE`;
  const media = [...new Set(mediaRows.map((row: any) => String(row.media_id)))];
  await sql`DELETE FROM draft_mutation_budgets WHERE account_id = ${accountId}`;
  await sql`DELETE FROM draft_mutation_requests WHERE account_id = ${accountId}`;
  await sql`DELETE FROM draft_mutation_tombstones WHERE account_id = ${accountId}`;
  await sql`DELETE FROM media_group_send_budgets WHERE account_id = ${accountId}`;
  await sql`DELETE FROM media_group_send_requests WHERE sender_account_id = ${accountId}`;
  await sql`DELETE FROM media_group_send_tombstones WHERE sender_account_id = ${accountId}`;
  await sql`DELETE FROM account_dialog_drafts WHERE account_id = ${accountId}`;
  if (media.length) {
    await sql`
      DELETE FROM media_objects media
      WHERE media.id = ANY(${sql.array(media, "uuid")}::uuid[])
        AND media.owner_account_id = ${accountId}
        AND NOT EXISTS (SELECT 1 FROM messages WHERE media_id = media.id)
        AND NOT EXISTS (SELECT 1 FROM dialogs WHERE photo_media_id = media.id)
        AND NOT EXISTS (SELECT 1 FROM draft_attachments WHERE media_id = media.id)`;
  }
}
