import type { SQL } from "bun";
import { createHash, timingSafeEqual } from "node:crypto";
import { requireActiveDevice } from "./auth";
import { bodyAAD, requestFingerprintIndex } from "./crypto";
import { sealForScope } from "./envelope-crypto";
import {
  DialogAccessError,
  lockDialogForMutation,
  requireDialogReadAccess,
  type DialogAccess,
} from "./dialog-access";
import { fanoutDialogEvent, type FanoutPush } from "./fanout";
import { lockAccountMutations, lockMutationKeys } from "./locks";
import { loadPollDTO, type PollDTO } from "./messaging-content";
import { notifySyncWakeups } from "./sync-wakeup";

export class MessagingFeatureError extends Error {
  constructor(
    message: string,
    readonly status = 400,
    readonly code = "invalid_messaging_feature_request",
  ) {
    super(message);
    this.name = "MessagingFeatureError";
  }
}

export type MessagingFeatureFlags = {
  pinnedMessages: boolean;
  autoDeleteCreation: boolean;
  polls: boolean;
  stickerPacks: boolean;
  giphy: boolean;
  multiAccountPush: boolean;
  support: boolean;
};

type FeatureOperation =
  | "pin"
  | "unpin"
  | "set_auto_delete"
  | "poll_vote"
  | "poll_close"
  | "sticker_install"
  | "sticker_remove"
  | "sticker_favorite"
  | "sticker_unfavorite";

type MutationIdentity = {
  actorAccountId: string;
  actorDeviceId: string;
  operationId: string;
};

type ClaimedMutation = { duplicate: false } | { duplicate: true; response: any };

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SUPPORT_EMAIL_PATTERN = /^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)+$/i;

const enabled = (name: string) => process.env[name] === "1";
const iso = (value: unknown) => value instanceof Date ? value.toISOString() : String(value);

export function messagingFeatureFlagsFromEnvironment(): MessagingFeatureFlags {
  const giphyApproved = enabled("TOJ_GIPHY_AGREEMENT_APPROVED");
  return {
    pinnedMessages: enabled("TOJ_PINNED_MESSAGES_ENABLED"),
    autoDeleteCreation: enabled("TOJ_AUTO_DELETE_ENABLED"),
    polls: enabled("TOJ_POLLS_ENABLED"),
    stickerPacks: enabled("TOJ_STICKER_PACKS_ENABLED"),
    giphy: enabled("TOJ_GIPHY_ENABLED") && giphyApproved && validGiphyClientKey() != null,
    multiAccountPush: enabled("TOJ_MULTI_ACCOUNT_PUSH_ENABLED"),
    support: enabled("TOJ_SUPPORT_ENABLED"),
  };
}

function accountInFeatureRollout(prefix: string, accountId: string): boolean {
  const allowlist = new Set(
    String(process.env[`${prefix}_ALLOWLIST`] ?? "")
      .split(",")
      .map((item) => item.trim().toLowerCase())
      .filter(Boolean),
  );
  if (allowlist.has(accountId.toLowerCase())) return true;
  const rawPercent = Number(process.env[`${prefix}_ROLLOUT_PERCENT`] ?? 0);
  const percent = Number.isFinite(rawPercent) ? Math.max(0, Math.min(100, rawPercent)) : 0;
  if (percent <= 0) return false;
  if (percent >= 100) return true;
  const digest = createHash("sha256").update(`${prefix}|${accountId}`).digest();
  return digest.readUInt32BE(0) % 10_000 < Math.floor(percent * 100);
}

/** Creation and mutation admission is dark unless both the switch and account rollout gate pass. */
export function messagingFeatureFlagsForAccount(accountId: string): MessagingFeatureFlags {
  const configured = messagingFeatureFlagsFromEnvironment();
  return {
    pinnedMessages: configured.pinnedMessages
      && accountInFeatureRollout("TOJ_PINNED_MESSAGES", accountId),
    autoDeleteCreation: configured.autoDeleteCreation
      && accountInFeatureRollout("TOJ_AUTO_DELETE", accountId),
    polls: configured.polls && accountInFeatureRollout("TOJ_POLLS", accountId),
    stickerPacks: configured.stickerPacks
      && accountInFeatureRollout("TOJ_STICKER_PACKS", accountId),
    giphy: configured.giphy && accountInFeatureRollout("TOJ_GIPHY", accountId),
    multiAccountPush: configured.multiAccountPush
      && accountInFeatureRollout("TOJ_MULTI_ACCOUNT_PUSH", accountId),
    // FAQ and the validated support address are useful before authentication and contain no
    // account data, so support remains a global switch rather than a per-account bucket.
    support: configured.support,
  };
}

export function validSupportEmail(): string | null {
  const value = process.env.TOJ_SUPPORT_EMAIL?.trim() ?? "";
  return value.length <= 254 && SUPPORT_EMAIL_PATTERN.test(value) ? value : null;
}

export function validGiphyClientKey(): string | null {
  const value = process.env.TOJ_GIPHY_API_KEY?.trim() ?? "";
  return /^[A-Za-z0-9_-]{8,128}$/.test(value) ? value : null;
}

export function publicSupportConfiguration(flags = messagingFeatureFlagsFromEnvironment()): {
  support_email?: string;
} {
  const supportEmail = flags.support ? validSupportEmail() : null;
  return supportEmail ? { support_email: supportEmail } : {};
}

/** Authenticated bootstrap data for direct client-side GIPHY requests. */
export function giphyClientConfiguration(flags = messagingFeatureFlagsFromEnvironment()): {
  enabled: boolean;
  api_key?: string;
  rating: "pg";
  attribution_required: true;
  proxying_permitted: false;
  persistence: "provider_id_only";
} {
  const apiKey = flags.giphy ? validGiphyClientKey() : null;
  return {
    enabled: Boolean(apiKey),
    ...(apiKey ? { api_key: apiKey } : {}),
    rating: "pg",
    attribution_required: true,
    proxying_permitted: false,
    persistence: "provider_id_only",
  };
}

function validateMutationIdentity(identity: MutationIdentity): void {
  if (!UUID_PATTERN.test(identity.operationId)) {
    throw new MessagingFeatureError("invalid operation id");
  }
}

function fingerprint(operation: FeatureOperation, payload: unknown, keyId?: string) {
  return requestFingerprintIndex(
    "messaging-feature",
    JSON.stringify({ operation, payload }),
    keyId,
  );
}

async function claimMutation(
  sql: SQL,
  identity: MutationIdentity,
  operation: FeatureOperation,
  dialogId: string | null,
  msgId: number | null,
  payload: unknown,
): Promise<ClaimedMutation> {
  validateMutationIdentity(identity);
  await lockMutationKeys(sql, [
    `messaging-feature-receipt:${identity.actorAccountId}:${identity.operationId}`,
  ]);
  const payloadFingerprint = fingerprint(operation, payload);
  const existing = (await sql`
    SELECT operation, dialog_id, msg_id, payload_fingerprint, fingerprint_key_id,
           response, completed_at
    FROM messaging_feature_mutations
    WHERE actor_account_id = ${identity.actorAccountId}
      AND operation_id = ${identity.operationId}
    FOR UPDATE`)[0];
  if (existing) {
    const expected = fingerprint(
      operation,
      payload,
      String(existing.fingerprint_key_id ?? "legacy-v1"),
    );
    const existingFingerprint = Buffer.from(existing.payload_fingerprint);
    const sameFingerprint = existingFingerprint.length === expected.digest.length
      && timingSafeEqual(existingFingerprint, expected.digest);
    if (
      existing.operation !== operation
      || String(existing.dialog_id ?? "") !== String(dialogId ?? "")
      || Number(existing.msg_id ?? 0) !== Number(msgId ?? 0)
      || !sameFingerprint
    ) {
      throw new MessagingFeatureError(
        "operation id already used for different content",
        409,
        "idempotency_conflict",
      );
    }
    if (existing.completed_at == null) {
      throw new MessagingFeatureError("operation is already in progress", 409, "operation_in_progress");
    }
    if (String(existing.fingerprint_key_id) !== payloadFingerprint.keyId) {
      await sql`UPDATE messaging_feature_mutations
        SET payload_fingerprint = ${payloadFingerprint.digest},
            fingerprint_key_id = ${payloadFingerprint.keyId}
        WHERE actor_account_id = ${identity.actorAccountId}
          AND operation_id = ${identity.operationId}`;
    }
    return {
      duplicate: true,
      response: typeof existing.response === "string"
        ? JSON.parse(existing.response)
        : existing.response,
    };
  }
  await sql`
    INSERT INTO messaging_feature_mutations (
      actor_account_id, operation_id, operation, dialog_id, msg_id,
      payload_fingerprint, fingerprint_key_id
    ) VALUES (
      ${identity.actorAccountId}, ${identity.operationId}, ${operation},
      ${dialogId}, ${msgId}, ${payloadFingerprint.digest}, ${payloadFingerprint.keyId}
    )`;
  return { duplicate: false };
}

async function completeMutation(
  sql: SQL,
  identity: MutationIdentity,
  response: unknown,
): Promise<void> {
  await sql`
    UPDATE messaging_feature_mutations
    SET response = ${JSON.stringify(response)}::jsonb, completed_at = now()
    WHERE actor_account_id = ${identity.actorAccountId}
      AND operation_id = ${identity.operationId}`;
}

function requireSharedMutationPermission(access: DialogAccess): void {
  if (access.type === "group" && access.role === "member") {
    throw new DialogAccessError("owner or admin role required", "insufficient_group_role", 403);
  }
  if (access.type === "saved" && access.role !== "owner") {
    throw new DialogAccessError("Saved Messages is owner-only", "saved_dialog_forbidden", 403);
  }
}

async function insertFeatureServiceMessage(
  sql: SQL,
  actorAccountId: string,
  dialogId: string,
  serviceType: "message.pinned" | "message.unpinned" | "dialog.auto_delete_changed" | "poll.closed",
  serviceData: Record<string, unknown>,
): Promise<number> {
  const dialog = (await sql`
    UPDATE dialogs SET last_msg_id = last_msg_id + 1, updated_at = now()
    WHERE id = ${dialogId} RETURNING last_msg_id`)[0];
  const msgId = Number(dialog.last_msg_id);
  const clientMsgId = crypto.randomUUID();
  const sealed = await sealForScope(
    sql,
    { kind: "account", accountId: actorAccountId },
    "",
    bodyAAD(dialogId, msgId, actorAccountId),
  );
  await sql`
    INSERT INTO messages (
      dialog_id, msg_id, sender_account_id, client_msg_id, kind,
      body_key_id, body_nonce, body_ciphertext, service_type, service_data
    ) VALUES (
      ${dialogId}, ${msgId}, ${actorAccountId}, ${clientMsgId}, 'service',
      ${sealed.keyId}, ${sealed.nonce}, ${sealed.ciphertext}, ${serviceType},
      ${JSON.stringify(serviceData)}::jsonb
    )`;
  return msgId;
}

async function appendFeatureServiceEvent(
  sql: SQL,
  input: {
    actorAccountId: string;
    actorDeviceId: string;
    dialogId: string;
    serviceType: "message.pinned" | "message.unpinned" | "dialog.auto_delete_changed" | "poll.closed";
    serviceData: Record<string, unknown>;
  },
): Promise<FanoutPush[]> {
  const msgId = await insertFeatureServiceMessage(
    sql,
    input.actorAccountId,
    input.dialogId,
    input.serviceType,
    input.serviceData,
  );
  return await fanoutDialogEvent(sql, {
    dialogId: input.dialogId,
    type: "message.new",
    msgId,
    actorAccountId: input.actorAccountId,
    sourceDeviceId: input.actorDeviceId,
    alertRecipients: false,
  });
}

export async function listPinnedMessages(
  sql: SQL,
  accountId: string,
  dialogId: string,
  options: { before?: string; limit?: number } = {},
): Promise<{
  items: Array<{
    msg_id: number;
    pinned_by_account_id: string;
    notify_members: boolean;
    created_at: string;
  }>;
  next_before?: string;
  count: number;
}> {
  await requireDialogReadAccess(sql, accountId, dialogId);
  const limit = Math.max(1, Math.min(100, Number(options.limit ?? 30)));
  const before = options.before ? new Date(options.before) : null;
  if (before && Number.isNaN(before.getTime())) {
    throw new MessagingFeatureError("invalid pin cursor");
  }
  const rows = before
    ? await sql`
        SELECT pin.*
        FROM message_pins pin
        JOIN messages message USING (dialog_id, msg_id)
        WHERE pin.dialog_id = ${dialogId} AND pin.created_at < ${before}
          AND message.state = 'visible'
          AND (message.expires_at IS NULL OR message.expires_at > now())
        ORDER BY pin.created_at DESC, pin.msg_id DESC LIMIT ${limit + 1}`
    : await sql`
        SELECT pin.*
        FROM message_pins pin
        JOIN messages message USING (dialog_id, msg_id)
        WHERE pin.dialog_id = ${dialogId}
          AND message.state = 'visible'
          AND (message.expires_at IS NULL OR message.expires_at > now())
        ORDER BY pin.created_at DESC, pin.msg_id DESC LIMIT ${limit + 1}`;
  const count = Number((await sql`
    SELECT count(*) AS count
    FROM message_pins pin JOIN messages message USING (dialog_id, msg_id)
    WHERE pin.dialog_id = ${dialogId} AND message.state = 'visible'
      AND (message.expires_at IS NULL OR message.expires_at > now())`)[0].count);
  const page = rows.slice(0, limit);
  return {
    items: page.map((row: any) => ({
      msg_id: Number(row.msg_id),
      pinned_by_account_id: String(row.pinned_by_account_id),
      notify_members: Boolean(row.notify_members),
      created_at: iso(row.created_at),
    })),
    ...(rows.length > limit ? { next_before: iso(page[page.length - 1].created_at) } : {}),
    count,
  };
}

export async function mutatePinnedMessage(
  sql: SQL,
  input: MutationIdentity & {
    dialogId: string;
    msgId: number;
    pinned: boolean;
    notifyMembers?: boolean;
  },
): Promise<{ pinned: boolean; pin_count: number; latest_msg_id: number | null; duplicate: boolean; pushes: FanoutPush[] }> {
  const msgId = Number(input.msgId);
  if (!Number.isSafeInteger(msgId) || msgId <= 0) {
    throw new MessagingFeatureError("invalid message id");
  }
  return await sql.begin(async (tx) => {
    const operation = input.pinned ? "pin" : "unpin";
    const claimed = await claimMutation(tx, input, operation, input.dialogId, msgId, {
      pinned: input.pinned,
      notifyMembers: input.notifyMembers === true,
    });
    if (claimed.duplicate) return { ...claimed.response, duplicate: true, pushes: [] };
    await lockAccountMutations(tx, [input.actorAccountId]);
    await requireActiveDevice(tx, input.actorAccountId, input.actorDeviceId);
    const access = await lockDialogForMutation(tx, input.actorAccountId, input.dialogId);
    requireSharedMutationPermission(access);
    const target = (await tx`
      SELECT state, expires_at FROM messages
      WHERE dialog_id = ${input.dialogId} AND msg_id = ${msgId}
      FOR UPDATE`)[0];
    if (!target || target.state !== "visible" || (
      target.expires_at != null && new Date(target.expires_at).getTime() <= Date.now()
    )) {
      throw new MessagingFeatureError("message cannot be pinned", 409, "pin_target_unavailable");
    }
    const existing = (await tx`
      SELECT pinned_by_account_id, notify_members
      FROM message_pins WHERE dialog_id = ${input.dialogId} AND msg_id = ${msgId}
      FOR UPDATE`)[0];
    let changed = false;
    if (input.pinned && !existing) {
      const pinCount = Number((await tx`
        SELECT count(*) AS count FROM message_pins WHERE dialog_id = ${input.dialogId}`)[0].count);
      if (pinCount >= 100) {
        throw new MessagingFeatureError("a dialog may have at most 100 pinned messages", 409, "pin_limit_reached");
      }
      await tx`
        INSERT INTO message_pins (
          dialog_id, msg_id, pinned_by_account_id, notify_members
        ) VALUES (
          ${input.dialogId}, ${msgId}, ${input.actorAccountId}, ${input.notifyMembers === true}
        )`;
      changed = true;
    } else if (!input.pinned && existing) {
      await tx`DELETE FROM message_pins WHERE dialog_id = ${input.dialogId} AND msg_id = ${msgId}`;
      changed = true;
    }
    const summary = (await tx`
      SELECT count(*) AS count,
             (array_agg(msg_id ORDER BY created_at DESC, msg_id DESC))[1] AS latest_msg_id
      FROM message_pins WHERE dialog_id = ${input.dialogId}`)[0];
    const servicePushes = changed && input.notifyMembers === true
      ? await appendFeatureServiceEvent(tx, {
      actorAccountId: input.actorAccountId,
      actorDeviceId: input.actorDeviceId,
      dialogId: input.dialogId,
      serviceType: input.pinned ? "message.pinned" : "message.unpinned",
      serviceData: { target_msg_id: msgId },
    }) : [];
    const pushes = changed ? [...servicePushes, ...await fanoutDialogEvent(tx, {
      dialogId: input.dialogId,
      type: "pin.updated",
      msgId,
      actorAccountId: input.actorAccountId,
      sourceDeviceId: input.actorDeviceId,
      alertRecipients: input.notifyMembers === true,
      data: { pinned: input.pinned, notify_members: input.notifyMembers === true },
    })] : [];
    const response = {
      pinned: input.pinned,
      pin_count: Number(summary.count),
      latest_msg_id: summary.latest_msg_id == null ? null : Number(summary.latest_msg_id),
    };
    await completeMutation(tx, input, response);
    await notifySyncWakeups(tx, pushes);
    return { ...response, duplicate: false, pushes };
  });
}

export async function setDialogAutoDelete(
  sql: SQL,
  input: MutationIdentity & { dialogId: string; seconds: number | null },
): Promise<{ auto_delete_seconds: number | null; revision: number; duplicate: boolean; pushes: FanoutPush[] }> {
  const seconds = input.seconds == null || Number(input.seconds) === 0 ? null : Number(input.seconds);
  if (seconds != null && (!Number.isSafeInteger(seconds) || seconds < 3600 || seconds > 31_536_000)) {
    throw new MessagingFeatureError("auto-delete must be off or between 1 hour and 365 days");
  }
  return await sql.begin(async (tx) => {
    const claimed = await claimMutation(tx, input, "set_auto_delete", input.dialogId, null, { seconds });
    if (claimed.duplicate) return { ...claimed.response, duplicate: true, pushes: [] };
    await lockAccountMutations(tx, [input.actorAccountId]);
    await requireActiveDevice(tx, input.actorAccountId, input.actorDeviceId);
    const access = await lockDialogForMutation(tx, input.actorAccountId, input.dialogId);
    requireSharedMutationPermission(access);
    const row = (await tx`
      UPDATE dialogs
      SET auto_delete_seconds = ${seconds}, revision = revision + 1
      WHERE id = ${input.dialogId} AND auto_delete_seconds IS DISTINCT FROM ${seconds}
      RETURNING revision`)[0];
    const revision = row ? Number(row.revision) : Number((await tx`
      SELECT revision FROM dialogs WHERE id = ${input.dialogId}`)[0].revision);
    const servicePushes = row ? await appendFeatureServiceEvent(tx, {
      actorAccountId: input.actorAccountId,
      actorDeviceId: input.actorDeviceId,
      dialogId: input.dialogId,
      serviceType: "dialog.auto_delete_changed",
      serviceData: { auto_delete_seconds: seconds },
    }) : [];
    const pushes = row ? [...servicePushes, ...await fanoutDialogEvent(tx, {
      dialogId: input.dialogId,
      type: "dialog.auto_delete_updated",
      actorAccountId: input.actorAccountId,
      sourceDeviceId: input.actorDeviceId,
      alertRecipients: false,
      data: { auto_delete_seconds: seconds, revision },
    })] : [];
    const response = { auto_delete_seconds: seconds, revision };
    await completeMutation(tx, input, response);
    await notifySyncWakeups(tx, pushes);
    return { ...response, duplicate: false, pushes };
  });
}

function normalizeVoteOptions(value: unknown, optionCount: number, multipleChoice: boolean): number[] {
  if (value == null) return [];
  if (!Array.isArray(value)) throw new MessagingFeatureError("poll vote options must be an array");
  const options = value.map(Number).sort((a, b) => a - b);
  if (options.some((option) => !Number.isSafeInteger(option) || option < 0 || option >= optionCount)) {
    throw new MessagingFeatureError("poll vote contains an invalid option");
  }
  if (new Set(options).size !== options.length) {
    throw new MessagingFeatureError("poll vote contains duplicate options");
  }
  if (!multipleChoice && options.length > 1) {
    throw new MessagingFeatureError("poll allows one option only");
  }
  return options;
}

export async function voteInPoll(
  sql: SQL,
  input: MutationIdentity & { dialogId: string; msgId: number; optionIndices: unknown },
): Promise<{ poll: PollDTO; duplicate: boolean; pushes: FanoutPush[] }> {
  const msgId = Number(input.msgId);
  if (!Number.isSafeInteger(msgId) || msgId <= 0) throw new MessagingFeatureError("invalid message id");
  return await sql.begin(async (tx) => {
    const canonicalOptions = Array.isArray(input.optionIndices)
      ? input.optionIndices.map(Number).sort((a, b) => a - b)
      : input.optionIndices;
    const claimed = await claimMutation(tx, input, "poll_vote", input.dialogId, msgId, {
      optionIndices: canonicalOptions,
    });
    if (claimed.duplicate) return { ...claimed.response, duplicate: true, pushes: [] };
    await lockAccountMutations(tx, [input.actorAccountId]);
    await requireActiveDevice(tx, input.actorAccountId, input.actorDeviceId);
    await lockDialogForMutation(tx, input.actorAccountId, input.dialogId);
    const poll = (await tx`
      SELECT poll.option_count, poll.multiple_choice, poll.quiz, poll.closed_at,
             message.state, message.expires_at
      FROM message_polls poll
      JOIN messages message USING (dialog_id, msg_id)
      WHERE poll.dialog_id = ${input.dialogId} AND poll.msg_id = ${msgId}
      FOR UPDATE OF poll, message`)[0];
    if (!poll || poll.state !== "visible" || (
      poll.expires_at != null && new Date(poll.expires_at).getTime() <= Date.now()
    )) {
      throw new MessagingFeatureError("poll is unavailable", 409, "poll_unavailable");
    }
    if (poll.closed_at != null) throw new MessagingFeatureError("poll is closed", 409, "poll_closed");
    const options = normalizeVoteOptions(input.optionIndices, Number(poll.option_count), Boolean(poll.multiple_choice));
    const current = (await tx`
      SELECT option_indices, locked FROM poll_votes
      WHERE dialog_id = ${input.dialogId} AND msg_id = ${msgId}
        AND voter_account_id = ${input.actorAccountId}
      FOR UPDATE`)[0];
    if (poll.quiz && current?.locked) {
      throw new MessagingFeatureError("quiz answer is already locked", 409, "quiz_vote_locked");
    }
    if (poll.quiz && options.length !== 1) {
      throw new MessagingFeatureError("quiz polls require one answer");
    }
    if (options.length === 0) {
      await tx`
        DELETE FROM poll_votes
        WHERE dialog_id = ${input.dialogId} AND msg_id = ${msgId}
          AND voter_account_id = ${input.actorAccountId}`;
    } else {
      await tx`
        INSERT INTO poll_votes (
          dialog_id, msg_id, voter_account_id, option_indices, locked
        ) VALUES (
          ${input.dialogId}, ${msgId}, ${input.actorAccountId},
          ${sql.array(options, "int2")}::smallint[], ${Boolean(poll.quiz)}
        )
        ON CONFLICT (dialog_id, msg_id, voter_account_id) DO UPDATE
        SET option_indices = EXCLUDED.option_indices,
            locked = EXCLUDED.locked,
            updated_at = now()`;
    }
    const pushes = await fanoutDialogEvent(tx, {
      dialogId: input.dialogId,
      type: "poll.updated",
      msgId,
      actorAccountId: input.actorAccountId,
      sourceDeviceId: input.actorDeviceId,
      alertRecipients: false,
    });
    const pollDTO = await loadPollDTO(tx, input.dialogId, msgId, input.actorAccountId);
    if (!pollDTO) throw new MessagingFeatureError("poll is unavailable", 409, "poll_unavailable");
    const response = { poll: pollDTO };
    await completeMutation(tx, input, response);
    await notifySyncWakeups(tx, pushes);
    return { ...response, duplicate: false, pushes };
  });
}

export async function closePoll(
  sql: SQL,
  input: MutationIdentity & { dialogId: string; msgId: number },
): Promise<{ poll: PollDTO; duplicate: boolean; pushes: FanoutPush[] }> {
  const msgId = Number(input.msgId);
  if (!Number.isSafeInteger(msgId) || msgId <= 0) throw new MessagingFeatureError("invalid message id");
  return await sql.begin(async (tx) => {
    const claimed = await claimMutation(tx, input, "poll_close", input.dialogId, msgId, {});
    if (claimed.duplicate) return { ...claimed.response, duplicate: true, pushes: [] };
    await lockAccountMutations(tx, [input.actorAccountId]);
    await requireActiveDevice(tx, input.actorAccountId, input.actorDeviceId);
    const access = await lockDialogForMutation(tx, input.actorAccountId, input.dialogId);
    const poll = (await tx`
      SELECT poll.closed_at, message.sender_account_id, message.state, message.expires_at
      FROM message_polls poll JOIN messages message USING (dialog_id, msg_id)
      WHERE poll.dialog_id = ${input.dialogId} AND poll.msg_id = ${msgId}
      FOR UPDATE OF poll, message`)[0];
    if (!poll || poll.state !== "visible" || (
      poll.expires_at != null && new Date(poll.expires_at).getTime() <= Date.now()
    )) {
      throw new MessagingFeatureError("poll is unavailable", 409, "poll_unavailable");
    }
    const mayClose = poll.sender_account_id === input.actorAccountId
      || (access.type === "group" && (access.role === "owner" || access.role === "admin"))
      || (access.type === "saved" && access.role === "owner");
    if (!mayClose) throw new DialogAccessError("only the poll sender or an admin may close it", "poll_close_forbidden", 403);
    const changed = poll.closed_at == null;
    if (changed) await tx`
      UPDATE message_polls SET closed_at = now(), closed_by_account_id = ${input.actorAccountId}
      WHERE dialog_id = ${input.dialogId} AND msg_id = ${msgId}`;
    const servicePushes = changed ? await appendFeatureServiceEvent(tx, {
      actorAccountId: input.actorAccountId,
      actorDeviceId: input.actorDeviceId,
      dialogId: input.dialogId,
      serviceType: "poll.closed",
      serviceData: { poll_msg_id: msgId },
    }) : [];
    const pushes = changed ? [...servicePushes, ...await fanoutDialogEvent(tx, {
      dialogId: input.dialogId,
      type: "poll.updated",
      msgId,
      actorAccountId: input.actorAccountId,
      sourceDeviceId: input.actorDeviceId,
      alertRecipients: false,
      data: { closed: true },
    })] : [];
    const pollDTO = await loadPollDTO(tx, input.dialogId, msgId, input.actorAccountId);
    if (!pollDTO) throw new MessagingFeatureError("poll is unavailable", 409, "poll_unavailable");
    const response = { poll: pollDTO };
    await completeMutation(tx, input, response);
    await notifySyncWakeups(tx, pushes);
    return { ...response, duplicate: false, pushes };
  });
}

function encodeVoterCursor(updatedAt: unknown, accountId: string): string {
  return Buffer.from(JSON.stringify({ updatedAt: iso(updatedAt), accountId }), "utf8").toString("base64url");
}

function decodeVoterCursor(cursor?: string): { updatedAt: Date; accountId: string } | null {
  if (!cursor) return null;
  try {
    const decoded = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8"));
    const updatedAt = new Date(decoded.updatedAt);
    if (Number.isNaN(updatedAt.getTime()) || !UUID_PATTERN.test(decoded.accountId)) throw new Error();
    return { updatedAt, accountId: decoded.accountId };
  } catch {
    throw new MessagingFeatureError("invalid voter cursor");
  }
}

export async function listPollVoters(
  sql: SQL,
  accountId: string,
  dialogId: string,
  msgId: number,
  options: { optionIndex?: number; cursor?: string; limit?: number } = {},
): Promise<{
  items: Array<{ account_id: string; display_name: string; option_indices: number[]; voted_at: string }>;
  next_cursor?: string;
}> {
  await requireDialogReadAccess(sql, accountId, dialogId);
  const poll = (await sql`
    SELECT poll.anonymous, poll.option_count
    FROM message_polls poll JOIN messages message USING (dialog_id, msg_id)
    WHERE poll.dialog_id = ${dialogId} AND poll.msg_id = ${msgId}
      AND message.state = 'visible'
      AND (message.expires_at IS NULL OR message.expires_at > now())`)[0];
  if (!poll) throw new MessagingFeatureError("poll is unavailable", 404, "poll_unavailable");
  if (poll.anonymous) throw new MessagingFeatureError("anonymous polls do not expose voters", 403, "anonymous_poll");
  const optionIndex = options.optionIndex == null ? null : Number(options.optionIndex);
  if (optionIndex != null && (
    !Number.isSafeInteger(optionIndex) || optionIndex < 0 || optionIndex >= Number(poll.option_count)
  )) throw new MessagingFeatureError("invalid poll option");
  const cursor = decodeVoterCursor(options.cursor);
  const limit = Math.max(1, Math.min(100, Number(options.limit ?? 50)));
  const rows = await sql`
    SELECT vote.voter_account_id, vote.option_indices, vote.updated_at, account.display_name
    FROM poll_votes vote JOIN accounts account ON account.id = vote.voter_account_id
    WHERE vote.dialog_id = ${dialogId} AND vote.msg_id = ${msgId}
      AND (${optionIndex}::smallint IS NULL OR vote.option_indices @> ARRAY[${optionIndex}]::smallint[])
      AND (
        ${cursor?.updatedAt ?? null}::timestamptz IS NULL
        OR (vote.updated_at, vote.voter_account_id) < (
          ${cursor?.updatedAt ?? null}::timestamptz,
          ${cursor?.accountId ?? null}::uuid
        )
      )
    ORDER BY vote.updated_at DESC, vote.voter_account_id DESC
    LIMIT ${limit + 1}`;
  const page = rows.slice(0, limit);
  return {
    items: page.map((row: any) => ({
      account_id: String(row.voter_account_id),
      display_name: String(row.display_name),
      option_indices: row.option_indices.map(Number),
      voted_at: iso(row.updated_at),
    })),
    ...(rows.length > limit ? {
      next_cursor: encodeVoterCursor(page[page.length - 1].updated_at, String(page[page.length - 1].voter_account_id)),
    } : {}),
  };
}

async function appendPrivatePreferenceEvent(
  sql: SQL,
  accountId: string,
  actorDeviceId: string,
  data: Record<string, unknown>,
): Promise<FanoutPush[]> {
  const state = (await sql`
    UPDATE account_sync_states SET pts = pts + 1, updated_at = now()
    WHERE account_id = ${accountId} RETURNING pts`)[0];
  const pts = Number(state.pts);
  await sql`
    INSERT INTO account_events (account_id, pts, type, actor_account_id, data)
    VALUES (
      ${accountId}, ${pts}, 'sticker_preferences.updated', ${accountId},
      ${JSON.stringify(data)}::jsonb
    )`;
  await sql`
    INSERT INTO push_deliveries (account_id, pts, device_id, alert)
    SELECT ${accountId}, ${pts}, id, false FROM devices
    WHERE account_id = ${accountId} AND platform = 'ios' AND revoked_at IS NULL
      AND id <> ${actorDeviceId}
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
  return [{ accountId, pts, ptsCount: 1 }];
}

export async function getStickerCatalog(
  sql: SQL,
  accountId: string,
  options: { query?: string; limit?: number } = {},
): Promise<{ packs: any[]; stickers: any[]; favorites: string[]; recents: string[] }> {
  const query = options.query?.trim() ?? "";
  if ([...query].length > 64) throw new MessagingFeatureError("sticker search is too long");
  const limit = Math.max(1, Math.min(200, Number(options.limit ?? 100)));
  const packs = await sql`
    SELECT pack.id, pack.version, pack.title, pack.manifest_sha256, pack.updated_at,
           (installed.pack_id IS NOT NULL) AS installed
    FROM sticker_packs pack
    LEFT JOIN account_sticker_packs installed
      ON installed.pack_id = pack.id AND installed.account_id = ${accountId}
    WHERE pack.status = 'active'
    ORDER BY installed.installed_at DESC NULLS LAST, pack.title, pack.id`;
  const stickers = query
    ? await sql`
        SELECT sticker.* FROM stickers sticker JOIN sticker_packs pack ON pack.id = sticker.pack_id
        WHERE sticker.status = 'active' AND pack.status = 'active'
          AND (
            EXISTS (SELECT 1 FROM unnest(sticker.emoji || sticker.tags) term WHERE term ILIKE ${`%${query}%`})
            OR sticker.id ILIKE ${`%${query}%`}
          )
        ORDER BY sticker.pack_id, sticker.id LIMIT ${limit}`
    : await sql`
        SELECT sticker.* FROM stickers sticker JOIN sticker_packs pack ON pack.id = sticker.pack_id
        LEFT JOIN account_sticker_packs installed
          ON installed.pack_id = sticker.pack_id AND installed.account_id = ${accountId}
        WHERE sticker.status = 'active' AND pack.status = 'active'
        ORDER BY installed.installed_at DESC NULLS LAST, sticker.pack_id, sticker.id LIMIT ${limit}`;
  const favorites = await sql`
    SELECT sticker_id FROM account_sticker_favorites
    WHERE account_id = ${accountId} ORDER BY created_at DESC`;
  const recents = await sql`
    SELECT sticker_id FROM account_sticker_recents
    WHERE account_id = ${accountId} ORDER BY last_used_at DESC LIMIT 50`;
  return {
    packs: packs.map((row: any) => ({
      id: row.id,
      version: Number(row.version),
      title: row.title,
      manifest_sha256: Buffer.from(row.manifest_sha256).toString("hex"),
      installed: Boolean(row.installed),
      updated_at: iso(row.updated_at),
    })),
    stickers: stickers.map((row: any) => ({
      id: row.id,
      pack_id: row.pack_id,
      pack_version: Number(row.pack_version),
      format: row.format,
      mime_type: row.mime_type,
      byte_size: Number(row.byte_size),
      width: Number(row.width),
      height: Number(row.height),
      sha256: Buffer.from(row.sha256).toString("hex"),
      asset_url: row.asset_url,
      emoji: row.emoji,
      tags: row.tags,
    })),
    favorites: favorites.map((row: any) => String(row.sticker_id)),
    recents: recents.map((row: any) => String(row.sticker_id)),
  };
}

export async function mutateStickerPreference(
  sql: SQL,
  input: MutationIdentity & {
    action: "install" | "remove" | "favorite" | "unfavorite";
    itemId: string;
  },
): Promise<{ action: string; item_id: string; duplicate: boolean; pushes: FanoutPush[] }> {
  const operationByAction: Record<typeof input.action, FeatureOperation> = {
    install: "sticker_install",
    remove: "sticker_remove",
    favorite: "sticker_favorite",
    unfavorite: "sticker_unfavorite",
  };
  const operation = operationByAction[input.action];
  return await sql.begin(async (tx) => {
    const claimed = await claimMutation(tx, input, operation, null, null, {
      action: input.action,
      itemId: input.itemId,
    });
    if (claimed.duplicate) return { ...claimed.response, duplicate: true, pushes: [] };
    await lockAccountMutations(tx, [input.actorAccountId]);
    await requireActiveDevice(tx, input.actorAccountId, input.actorDeviceId);
    if (input.action === "install" || input.action === "remove") {
      const pack = (await tx`SELECT status FROM sticker_packs WHERE id = ${input.itemId} FOR SHARE`)[0];
      if (!pack || (input.action === "install" && pack.status !== "active")) {
        throw new MessagingFeatureError("sticker pack is unavailable", 409, "sticker_pack_unavailable");
      }
      if (input.action === "install") await tx`
        INSERT INTO account_sticker_packs (account_id, pack_id)
        VALUES (${input.actorAccountId}, ${input.itemId}) ON CONFLICT DO NOTHING`;
      else await tx`
        DELETE FROM account_sticker_packs
        WHERE account_id = ${input.actorAccountId} AND pack_id = ${input.itemId}`;
    } else {
      const sticker = (await tx`
        SELECT sticker.status, pack.status AS pack_status
        FROM stickers sticker JOIN sticker_packs pack ON pack.id = sticker.pack_id
        WHERE sticker.id = ${input.itemId} FOR SHARE OF sticker, pack`)[0];
      if (!sticker || (input.action === "favorite" && (
        sticker.status !== "active" || sticker.pack_status !== "active"
      ))) throw new MessagingFeatureError("sticker is unavailable", 409, "sticker_unavailable");
      if (input.action === "favorite") await tx`
        INSERT INTO account_sticker_favorites (account_id, sticker_id)
        VALUES (${input.actorAccountId}, ${input.itemId}) ON CONFLICT DO NOTHING`;
      else await tx`
        DELETE FROM account_sticker_favorites
        WHERE account_id = ${input.actorAccountId} AND sticker_id = ${input.itemId}`;
    }
    const pushes = await appendPrivatePreferenceEvent(tx, input.actorAccountId, input.actorDeviceId, {
      action: input.action,
      item_id: input.itemId,
    });
    const response = { action: input.action, item_id: input.itemId };
    await completeMutation(tx, input, response);
    await notifySyncWakeups(tx, pushes);
    return { ...response, duplicate: false, pushes };
  });
}

export async function recordStickerRecent(
  sql: SQL,
  accountId: string,
  stickerId: string,
): Promise<void> {
  await sql`
    INSERT INTO account_sticker_recents (account_id, sticker_id)
    VALUES (${accountId}, ${stickerId})
    ON CONFLICT (account_id, sticker_id) DO UPDATE
    SET use_count = account_sticker_recents.use_count + 1, last_used_at = now()`;
}

export async function cleanupMessagingFeatureReceipts(sql: SQL, batchSize = 1_000): Promise<number> {
  const rows = await sql`
    WITH doomed AS (
      SELECT actor_account_id, operation_id FROM messaging_feature_mutations
      WHERE completed_at IS NULL AND created_at < now() - interval '24 hours'
      ORDER BY created_at LIMIT ${batchSize} FOR UPDATE SKIP LOCKED
    )
    DELETE FROM messaging_feature_mutations mutation USING doomed
    WHERE mutation.actor_account_id = doomed.actor_account_id
      AND mutation.operation_id = doomed.operation_id
    RETURNING mutation.operation_id`;
  return rows.length;
}
