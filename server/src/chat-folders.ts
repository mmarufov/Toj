import type { SQL } from "bun";
import { chatFolderTitleAAD, requestFingerprintIndex } from "./crypto";
import { openForScope, preloadEnvelopeKeys, sealForScope } from "./envelope-crypto";
import { lockAccountMutations, lockMutationKeys } from "./locks";
import { notifySyncWakeups } from "./sync-wakeup";
import { EXPIRED_BLIND_INDEX_KEY_ID } from "./blind-index";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ICONS = new Set([
  "folder", "unread", "personal", "groups", "muted", "work", "family", "favorite",
]);
const MAX_FOLDERS = 10;
const MAX_RULES_PER_FOLDER = 100;
const MAX_RULES_PER_ACCOUNT = 500;

export class ChatFolderError extends Error {
  constructor(
    message: string,
    readonly code = "invalid_chat_folder",
    readonly status = 400,
    readonly retryAfter?: number,
  ) {
    super(message);
    this.name = "ChatFolderError";
  }
}

export type ChatFolderRuleDTO = { dialogId: string; rule: "include" | "exclude" };
export type ChatFolderDTO = {
  folderId: string;
  title: string;
  icon: string;
  position: number;
  includeDirect: boolean;
  includeGroups: boolean;
  includeSaved: boolean;
  excludeRead: boolean;
  excludeMuted: boolean;
  excludeArchived: boolean;
  revision: number;
  rules: ChatFolderRuleDTO[];
  createdAt: string;
  updatedAt: string;
};

export type ChatFolderSnapshot = {
  collectionRevision: number;
  folders: ChatFolderDTO[];
  clientMutationId?: string;
  pts?: number;
  duplicate?: boolean;
};

type FolderDefinition = {
  title: string;
  icon: string;
  includeDirect: boolean;
  includeGroups: boolean;
  includeSaved: boolean;
  excludeRead: boolean;
  excludeMuted: boolean;
  excludeArchived: boolean;
  rules: ChatFolderRuleDTO[];
};

const n = (value: unknown) => Number(value as any);
const iso = (value: unknown) => value instanceof Date ? value.toISOString() : String(value);

function requireUUID(value: unknown, field: string): string {
  const normalized = String(value ?? "").toLowerCase();
  if (!UUID_PATTERN.test(normalized)) throw new ChatFolderError(`${field} is invalid`);
  return normalized;
}

function bool(value: unknown, fallback: boolean): boolean {
  if (value == null) return fallback;
  if (typeof value !== "boolean") throw new ChatFolderError("folder flags must be booleans");
  return value;
}

function normalizeDefinition(value: any, existing?: ChatFolderDTO): FolderDefinition {
  const title = String(value?.title ?? existing?.title ?? "").trim();
  if (
    title.length === 0
    || [...title].length > 32
    || Buffer.byteLength(title, "utf8") > 64
    || /[\u0000-\u001f\u007f]/u.test(title)
  ) {
    throw new ChatFolderError("folder title must be 1 to 32 characters");
  }
  const icon = String(value?.icon ?? existing?.icon ?? "folder");
  if (!ICONS.has(icon)) throw new ChatFolderError("folder icon is invalid");
  const rawRules = value?.rules ?? existing?.rules ?? [];
  if (!Array.isArray(rawRules) || rawRules.length > MAX_RULES_PER_FOLDER) {
    throw new ChatFolderError("folder has too many explicit chats", "chat_folder_limit");
  }
  const seen = new Set<string>();
  const rules = rawRules.map((raw: any): ChatFolderRuleDTO => {
    const dialogId = requireUUID(raw?.dialogId ?? raw?.dialog_id, "dialogId");
    const rule = String(raw?.rule ?? "");
    if (rule !== "include" && rule !== "exclude") {
      throw new ChatFolderError("folder rule is invalid");
    }
    if (seen.has(dialogId)) throw new ChatFolderError("duplicate folder dialog rule");
    seen.add(dialogId);
    return { dialogId, rule };
  }).sort((left, right) => left.dialogId.localeCompare(right.dialogId));
  return {
    title,
    icon,
    includeDirect: bool(value?.includeDirect ?? value?.include_direct, existing?.includeDirect ?? true),
    includeGroups: bool(value?.includeGroups ?? value?.include_groups, existing?.includeGroups ?? true),
    includeSaved: bool(value?.includeSaved ?? value?.include_saved, existing?.includeSaved ?? true),
    excludeRead: bool(value?.excludeRead ?? value?.exclude_read, existing?.excludeRead ?? false),
    excludeMuted: bool(value?.excludeMuted ?? value?.exclude_muted, existing?.excludeMuted ?? false),
    excludeArchived: bool(value?.excludeArchived ?? value?.exclude_archived, existing?.excludeArchived ?? false),
    rules,
  };
}

async function requireActiveDevice(
  sql: SQL,
  accountId: string,
  deviceId: string,
): Promise<void> {
  const row = (await sql`
    SELECT 1
    FROM accounts account
    JOIN devices device ON device.account_id = account.id
    WHERE account.id = ${accountId}
      AND account.status IN ('active','limited')
      AND device.id = ${deviceId}
      AND device.revoked_at IS NULL
    FOR SHARE OF account, device`)[0];
  if (!row) throw new ChatFolderError("account unavailable", "authentication_required", 401);
}

async function validateDialogRules(
  sql: SQL,
  accountId: string,
  rules: ChatFolderRuleDTO[],
): Promise<void> {
  if (rules.length === 0) return;
  const rows = await sql`
    SELECT member.dialog_id
    FROM dialog_members member
    JOIN dialogs dialog ON dialog.id = member.dialog_id
    WHERE member.account_id = ${accountId}
      AND member.left_at IS NULL
      AND dialog.closed_at IS NULL
      AND member.dialog_id = ANY(
        ${sql.array(rules.map((rule) => rule.dialogId), "uuid")}::uuid[]
      )
      AND (
        dialog.type <> 'saved'
        OR (dialog.created_by = ${accountId} AND member.role = 'owner')
      )`;
  if (rows.length !== rules.length) {
    throw new ChatFolderError("one or more folder chats are unavailable", "dialog_access_denied", 403);
  }
}

async function loadSnapshot(sql: SQL, accountId: string): Promise<ChatFolderSnapshot> {
  const state = (await sql`
    SELECT revision FROM account_chat_folder_states WHERE account_id = ${accountId}`)[0];
  const rows = await sql`
    SELECT folder.account_id, folder.folder_id, folder.title_key_id, folder.title_nonce,
           folder.title_ciphertext, folder.icon, folder.position,
           folder.include_direct, folder.include_groups, folder.include_saved,
           folder.exclude_read, folder.exclude_muted, folder.exclude_archived,
           folder.revision, folder.created_at, folder.updated_at,
           COALESCE(jsonb_agg(
             jsonb_build_object('dialogId', rule.dialog_id, 'rule', rule.rule)
             ORDER BY rule.dialog_id
           ) FILTER (WHERE rule.dialog_id IS NOT NULL), '[]'::jsonb) AS rules
    FROM chat_folders folder
    LEFT JOIN chat_folder_dialog_rules rule
      ON rule.account_id = folder.account_id AND rule.folder_id = folder.folder_id
    WHERE folder.account_id = ${accountId}
    GROUP BY folder.account_id, folder.folder_id
    ORDER BY folder.position, folder.folder_id`;
  await preloadEnvelopeKeys(sql, rows.map((row: any) => String(row.title_key_id)));
  const folders: ChatFolderDTO[] = [];
  for (const row of rows) {
    folders.push({
      folderId: String(row.folder_id),
      title: (await openForScope(
        sql,
        { kind: "account", accountId },
        {
          keyId: String(row.title_key_id),
          nonce: Buffer.from(row.title_nonce),
          ciphertext: Buffer.from(row.title_ciphertext),
        },
        chatFolderTitleAAD(accountId, String(row.folder_id)),
      )).toString("utf8"),
      icon: String(row.icon),
      position: n(row.position),
      includeDirect: Boolean(row.include_direct),
      includeGroups: Boolean(row.include_groups),
      includeSaved: Boolean(row.include_saved),
      excludeRead: Boolean(row.exclude_read),
      excludeMuted: Boolean(row.exclude_muted),
      excludeArchived: Boolean(row.exclude_archived),
      revision: n(row.revision),
      rules: (row.rules ?? []).map((rule: any) => ({
        dialogId: String(rule.dialogId),
        rule: String(rule.rule) as "include" | "exclude",
      })),
      createdAt: iso(row.created_at),
      updatedAt: iso(row.updated_at),
    });
  }
  return {
    collectionRevision: n(state?.revision ?? 0),
    folders,
  };
}

export async function getChatFolders(sql: SQL, accountId: string): Promise<ChatFolderSnapshot> {
  return await loadSnapshot(sql, accountId);
}

function fingerprint(operation: string, folderId: string, payload: unknown): {
  canonical: string; digest: Buffer; keyId: string;
} {
  const canonical = JSON.stringify({ operation, folderId, payload });
  const index = requestFingerprintIndex(
    "chat-folder-mutation",
    canonical,
  );
  return { canonical, digest: index.digest, keyId: index.keyId };
}

function sameBuffer(left: unknown, right: Buffer): boolean {
  return Buffer.from(left as Uint8Array).equals(right);
}

async function appendSnapshotEvent(
  sql: SQL,
  accountId: string,
  deviceId: string,
  mutationId: string,
  snapshot: ChatFolderSnapshot,
): Promise<number> {
  const state = (await sql`
    UPDATE account_sync_states SET pts = pts + 1, updated_at = now()
    WHERE account_id = ${accountId}
    RETURNING pts`)[0];
  if (!state) throw new ChatFolderError("account unavailable", "account_unavailable", 404);
  const pts = n(state.pts);
  await sql`
    INSERT INTO account_events (account_id, pts, type, actor_account_id, data)
    VALUES (
      ${accountId}, ${pts}, 'chat_folders.updated', ${accountId},
      ${JSON.stringify({
        collection_revision: snapshot.collectionRevision,
        client_mutation_id: mutationId,
      })}::text::jsonb
    )`;
  await sql`
    INSERT INTO push_deliveries (account_id, pts, device_id, alert)
    SELECT ${accountId}, ${pts}, id, FALSE
    FROM devices
    WHERE account_id = ${accountId}
      AND id <> ${deviceId}
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
  await notifySyncWakeups(sql, [{ accountId, pts, ptsCount: 1 }]);
  return pts;
}

async function mutate(
  sql: SQL,
  input: {
    accountId: string;
    deviceId: string;
    clientMutationId: unknown;
    folderId: unknown;
    operation: "create" | "update" | "move" | "delete";
    payload?: any;
  },
): Promise<ChatFolderSnapshot> {
  const mutationId = requireUUID(input.clientMutationId, "clientMutationId");
  const folderId = requireUUID(input.folderId, "folderId");
  const canonicalPayload = input.payload ?? {};
  const digest = fingerprint(input.operation, folderId, canonicalPayload);
  return await sql.begin(async (tx) => {
    await lockMutationKeys(tx, [`chat-folder-receipt:${input.accountId}:${mutationId}`]);
    await lockAccountMutations(tx, [input.accountId]);
    await requireActiveDevice(tx, input.accountId, input.deviceId);

    const claim = await tx`
      INSERT INTO chat_folder_mutation_requests (
        account_id, client_mutation_id, folder_id, operation, fingerprint, fingerprint_key_id
      ) VALUES (
        ${input.accountId}, ${mutationId}, ${folderId}, ${input.operation},
        ${digest.digest}, ${digest.keyId}
      )
      ON CONFLICT (account_id, client_mutation_id) DO NOTHING
      RETURNING status`;
    if (claim.length === 0) {
      const receipt = (await tx`
        SELECT folder_id, operation, fingerprint, fingerprint_key_id, status
        FROM chat_folder_mutation_requests
        WHERE account_id = ${input.accountId} AND client_mutation_id = ${mutationId}
        FOR UPDATE`)[0];
      if (receipt.fingerprint_key_id === EXPIRED_BLIND_INDEX_KEY_ID) {
        throw new ChatFolderError(
          "folder mutation result has expired", "mutation_result_expired", 409,
        );
      }
      if (
        String(receipt.folder_id) !== folderId
        || receipt.operation !== input.operation
        || !sameBuffer(receipt.fingerprint, requestFingerprintIndex(
          "chat-folder-mutation",
          digest.canonical,
          receipt.fingerprint_key_id ?? "legacy-v1",
        ).digest)
      ) {
        throw new ChatFolderError(
          "mutation id was reused with different input",
          "idempotency_conflict",
          409,
        );
      }
      if (String(receipt.fingerprint_key_id ?? "legacy-v1") !== digest.keyId) {
        await tx`UPDATE chat_folder_mutation_requests
          SET fingerprint = ${digest.digest}, request_fingerprint = ${digest.digest},
              fingerprint_key_id = ${digest.keyId}
          WHERE account_id = ${input.accountId} AND client_mutation_id = ${mutationId}`;
      }
      if (receipt.status !== "completed") {
        throw new ChatFolderError("folder mutation is already in progress", "mutation_in_progress", 409);
      }
      return { ...(await loadSnapshot(tx, input.accountId)), duplicate: true };
    }

    const budget = await tx`
      INSERT INTO chat_folder_action_budgets (
        account_id, bucket_started, mutation_count
      ) VALUES (${input.accountId}, date_trunc('hour', now()), 1)
      ON CONFLICT (account_id, bucket_started) DO UPDATE SET
        mutation_count = chat_folder_action_budgets.mutation_count + 1,
        updated_at = now()
      WHERE chat_folder_action_budgets.mutation_count < 240
      RETURNING mutation_count`;
    if (budget.length === 0) {
      throw new ChatFolderError("folder mutation rate limit reached", "rate_limited", 429, 3600);
    }

    await tx`
      INSERT INTO account_chat_folder_states(account_id, revision)
      VALUES (${input.accountId}, 0)
      ON CONFLICT (account_id) DO NOTHING`;
    const current = await loadSnapshot(tx, input.accountId);
    const existing = current.folders.find((folder) => folder.folderId === folderId);
    if (input.operation !== "create") {
      const expectedRevision = Number(canonicalPayload.expectedRevision);
      if (!Number.isSafeInteger(expectedRevision) || expectedRevision <= 0) {
        throw new ChatFolderError("expected revision is required", "folder_revision_required", 400);
      }
      if (current.collectionRevision !== expectedRevision) {
        throw new ChatFolderError(
          "folder was changed on another device",
          "folder_revision_conflict",
          409,
        );
      }
    }

    if (input.operation === "create") {
      if (existing) throw new ChatFolderError("folder already exists", "folder_exists", 409);
      if (current.folders.length >= MAX_FOLDERS) {
        throw new ChatFolderError("folder limit reached", "chat_folder_limit", 409);
      }
      const definition = normalizeDefinition(canonicalPayload);
      await validateDialogRules(tx, input.accountId, definition.rules);
      const totalRules = current.folders.reduce((sum, folder) => sum + folder.rules.length, 0)
        + definition.rules.length;
      if (totalRules > MAX_RULES_PER_ACCOUNT) {
        throw new ChatFolderError("account folder rule limit reached", "chat_folder_limit", 409);
      }
      const nextRevision = current.collectionRevision + 1;
      const title = await sealForScope(
        tx,
        { kind: "account", accountId: input.accountId },
        definition.title,
        chatFolderTitleAAD(input.accountId, folderId),
      );
      await tx`
        INSERT INTO chat_folders (
          account_id, folder_id, title_key_id, title_nonce, title_ciphertext, icon, position,
          include_direct, include_groups, include_saved,
          exclude_read, exclude_muted, exclude_archived, revision
        ) VALUES (
          ${input.accountId}, ${folderId}, ${title.keyId}, ${title.nonce}, ${title.ciphertext},
          ${definition.icon}, ${current.folders.length}, ${definition.includeDirect},
          ${definition.includeGroups}, ${definition.includeSaved}, ${definition.excludeRead},
          ${definition.excludeMuted}, ${definition.excludeArchived}, ${nextRevision}
        )`;
      if (definition.rules.length) {
        await tx`
          INSERT INTO chat_folder_dialog_rules(account_id, folder_id, dialog_id, rule)
          SELECT ${input.accountId}, ${folderId}, rule.dialog_id, rule.rule
          FROM unnest(
            ${tx.array(definition.rules.map((rule) => rule.dialogId), "uuid")}::uuid[],
            ${tx.array(definition.rules.map((rule) => rule.rule), "text")}::text[]
          ) AS rule(dialog_id, rule)`;
      }
    } else if (input.operation === "update") {
      if (!existing) throw new ChatFolderError("folder not found", "folder_not_found", 404);
      const definition = normalizeDefinition(canonicalPayload, existing);
      await validateDialogRules(tx, input.accountId, definition.rules);
      const otherRuleCount = current.folders
        .filter((folder) => folder.folderId !== folderId)
        .reduce((sum, folder) => sum + folder.rules.length, 0);
      if (otherRuleCount + definition.rules.length > MAX_RULES_PER_ACCOUNT) {
        throw new ChatFolderError("account folder rule limit reached", "chat_folder_limit", 409);
      }
      const nextRevision = current.collectionRevision + 1;
      const title = await sealForScope(
        tx,
        { kind: "account", accountId: input.accountId },
        definition.title,
        chatFolderTitleAAD(input.accountId, folderId),
      );
      await tx`
        UPDATE chat_folders SET
          title_key_id = ${title.keyId}, title_nonce = ${title.nonce},
          title_ciphertext = ${title.ciphertext}, icon = ${definition.icon},
          include_direct = ${definition.includeDirect}, include_groups = ${definition.includeGroups},
          include_saved = ${definition.includeSaved}, exclude_read = ${definition.excludeRead},
          exclude_muted = ${definition.excludeMuted}, exclude_archived = ${definition.excludeArchived},
          revision = ${nextRevision}, updated_at = now()
        WHERE account_id = ${input.accountId} AND folder_id = ${folderId}`;
      await tx`
        DELETE FROM chat_folder_dialog_rules
        WHERE account_id = ${input.accountId} AND folder_id = ${folderId}`;
      if (definition.rules.length) {
        await tx`
          INSERT INTO chat_folder_dialog_rules(account_id, folder_id, dialog_id, rule)
          SELECT ${input.accountId}, ${folderId}, rule.dialog_id, rule.rule
          FROM unnest(
            ${tx.array(definition.rules.map((rule) => rule.dialogId), "uuid")}::uuid[],
            ${tx.array(definition.rules.map((rule) => rule.rule), "text")}::text[]
          ) AS rule(dialog_id, rule)`;
      }
    } else if (input.operation === "move") {
      if (!existing) throw new ChatFolderError("folder not found", "folder_not_found", 404);
      const beforeId = canonicalPayload.beforeFolderId == null
        ? null : requireUUID(canonicalPayload.beforeFolderId, "beforeFolderId");
      const afterId = canonicalPayload.afterFolderId == null
        ? null : requireUUID(canonicalPayload.afterFolderId, "afterFolderId");
      if ((beforeId == null) === (afterId == null)) {
        throw new ChatFolderError("move requires exactly one relative folder");
      }
      const ordered = current.folders.filter((folder) => folder.folderId !== folderId);
      const anchorId = beforeId ?? afterId!;
      const anchorIndex = ordered.findIndex((folder) => folder.folderId === anchorId);
      if (anchorIndex < 0) throw new ChatFolderError("move anchor not found", "folder_not_found", 404);
      ordered.splice(beforeId ? anchorIndex : anchorIndex + 1, 0, existing);
      const nextRevision = current.collectionRevision + 1;
      for (const [position, folder] of ordered.entries()) {
        await tx`
          UPDATE chat_folders SET position = ${position}, revision = ${nextRevision}, updated_at = now()
          WHERE account_id = ${input.accountId} AND folder_id = ${folder.folderId}`;
      }
    } else {
      if (!existing) throw new ChatFolderError("folder not found", "folder_not_found", 404);
      await tx`
        DELETE FROM chat_folders
        WHERE account_id = ${input.accountId} AND folder_id = ${folderId}`;
      const remaining = current.folders.filter((folder) => folder.folderId !== folderId);
      const nextRevision = current.collectionRevision + 1;
      for (const [position, folder] of remaining.entries()) {
        await tx`
          UPDATE chat_folders SET position = ${position}, revision = ${nextRevision}, updated_at = now()
          WHERE account_id = ${input.accountId} AND folder_id = ${folder.folderId}`;
      }
    }

    const state = (await tx`
      UPDATE account_chat_folder_states
      SET revision = revision + 1, updated_at = now()
      WHERE account_id = ${input.accountId}
      RETURNING revision`)[0];
    const snapshot = await loadSnapshot(tx, input.accountId);
    snapshot.collectionRevision = n(state.revision);
    const pts = await appendSnapshotEvent(
      tx,
      input.accountId,
      input.deviceId,
      mutationId,
      snapshot,
    );
    await tx`
      UPDATE chat_folder_mutation_requests
      SET status = 'completed', result_revision = ${snapshot.collectionRevision}
      WHERE account_id = ${input.accountId} AND client_mutation_id = ${mutationId}`;
    return { ...snapshot, clientMutationId: mutationId, pts, duplicate: false };
  });
}

export async function createChatFolder(
  sql: SQL,
  input: { accountId: string; deviceId: string; body: any },
): Promise<ChatFolderSnapshot> {
  return await mutate(sql, {
    accountId: input.accountId,
    deviceId: input.deviceId,
    clientMutationId: input.body?.clientMutationId,
    folderId: input.body?.folderId,
    operation: "create",
    payload: normalizeDefinition(input.body),
  });
}

export async function updateChatFolder(
  sql: SQL,
  input: { accountId: string; deviceId: string; folderId: string; body: any },
): Promise<ChatFolderSnapshot> {
  return await mutate(sql, {
    accountId: input.accountId,
    deviceId: input.deviceId,
    clientMutationId: input.body?.clientMutationId,
    folderId: input.folderId,
    operation: "update",
    payload: input.body,
  });
}

export async function moveChatFolder(
  sql: SQL,
  input: { accountId: string; deviceId: string; folderId: string; body: any },
): Promise<ChatFolderSnapshot> {
  return await mutate(sql, {
    accountId: input.accountId,
    deviceId: input.deviceId,
    clientMutationId: input.body?.clientMutationId,
    folderId: input.folderId,
    operation: "move",
    payload: {
      beforeFolderId: input.body?.beforeFolderId ?? null,
      afterFolderId: input.body?.afterFolderId ?? null,
      expectedRevision: input.body?.expectedRevision,
    },
  });
}

export async function deleteChatFolder(
  sql: SQL,
  input: { accountId: string; deviceId: string; folderId: string; body: any },
): Promise<ChatFolderSnapshot> {
  return await mutate(sql, {
    accountId: input.accountId,
    deviceId: input.deviceId,
    clientMutationId: input.body?.clientMutationId,
    folderId: input.folderId,
    operation: "delete",
    payload: { expectedRevision: input.body?.expectedRevision },
  });
}

/** Removes stale explicit rules after a dialog access revocation and emits one convergent snapshot. */
export async function scrubDialogFromChatFolders(
  sql: SQL,
  accountId: string,
  dialogId: string,
): Promise<void> {
  await sql.begin(async (tx) => {
    await scrubDialogFromChatFoldersInTransaction(tx, accountId, dialogId);
  });
}

export async function scrubDialogFromChatFoldersInTransaction(
  tx: SQL,
  accountId: string,
  dialogId: string,
): Promise<void> {
    await lockAccountMutations(tx, [accountId]);
    const removed = await tx`
      DELETE FROM chat_folder_dialog_rules
      WHERE account_id = ${accountId} AND dialog_id = ${dialogId}
      RETURNING folder_id`;
    if (!removed.length) return;
    const state = (await tx`
      UPDATE account_chat_folder_states
      SET revision = revision + 1, updated_at = now()
      WHERE account_id = ${accountId}
      RETURNING revision`)[0];
    if (!state) return;
    const syncState = (await tx`
      UPDATE account_sync_states SET pts = pts + 1, updated_at = now()
      WHERE account_id = ${accountId} RETURNING pts`)[0];
    const pts = n(syncState.pts);
    await tx`
      INSERT INTO account_events(account_id, pts, type, actor_account_id, data)
      VALUES (
        ${accountId}, ${pts}, 'chat_folders.updated', ${accountId},
        ${JSON.stringify({ collection_revision: n(state.revision) })}::text::jsonb
      )`;
    await notifySyncWakeups(tx, [{ accountId, pts, ptsCount: 1 }]);
}
