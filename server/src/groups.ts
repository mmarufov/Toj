import type { SQL } from "bun";
import { scrubDialogFromChatFoldersInTransaction } from "./chat-folders";
import { createHash } from "node:crypto";
import { bodyAAD } from "./crypto";
import { sealForScope } from "./envelope-crypto";
import {
  DialogAccessError,
  lockDialogForMutation,
  requireDialogReadAccess,
  requireGroupRole,
  type DialogAccess,
} from "./dialog-access";
import { appendAccessRevokedEvent, fanoutDialogEvent, type FanoutPush } from "./fanout";
import { loadMediaDTO, type MediaDTO } from "./media";
import { loadProfiles, type ProfileDTO } from "./sync";
import { failScheduledDeliveriesForRevokedDialogInTransaction } from "./scheduled-deliveries";
import { purgeRevokedDialogDraftState } from "./drafts";
import { updateDialogPreferences } from "./dialog-preferences";
import {
  requireGroupCallSFUBarrierApplied,
  revokeGroupCallAccountInLockedDialog,
  type GroupCallSFUControl,
} from "./group-calls";

const UUID_V4_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_GROUP_MEMBERS = 200;
const CREATE_LIMIT_PER_DAY = 20;
const ADD_LIMIT_PER_HOUR = 100;
const STRANGER_ADD_LIMIT_PER_DAY = 20;

const n = (value: unknown) => Number(value as any);
const iso = (value: unknown) => value instanceof Date ? value.toISOString() : String(value);

export class GroupError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly status = 400,
    readonly details: Record<string, unknown> = {},
    readonly retryAfter?: number,
  ) {
    super(message);
    this.name = "GroupError";
  }
}

export type GroupDTO = {
  id: string;
  title: string;
  photo: MediaDTO | null;
  revision: number;
  memberCount: number;
  selfRole: "owner" | "admin" | "member";
  notificationMode: "all" | "muted";
  createdBy: string;
  createdAt: string;
  closedAt: string | null;
  membersCanSend: boolean;
  membersCanAddMembers: boolean;
  membersCanEditInfo: boolean;
};

export type GroupMemberDTO = {
  accountId: string;
  role: "owner" | "admin" | "member";
  joinedAt: string;
  isActive: boolean;
};

export type GroupEnvelope = {
  group: GroupDTO;
  members?: GroupMemberDTO[];
  profiles: ProfileDTO[];
  duplicate?: boolean;
  pushes?: FanoutPush[];
};

function requireUUID(value: unknown, field: string, v4 = false): string {
  const normalized = String(value ?? "").toLowerCase();
  if (!(v4 ? UUID_V4_PATTERN : UUID_PATTERN).test(normalized)) {
    throw new GroupError(
      `${field} is invalid`,
      field === "groupId" ? "invalid_group_id" : "invalid_request",
    );
  }
  return normalized;
}

function normalizeTitle(value: unknown): string {
  if (typeof value !== "string") throw new GroupError("group title is required", "invalid_group_title");
  const title = value.trim();
  if ([...title].length < 1 || [...title].length > 128 || Buffer.byteLength(title, "utf8") > 256) {
    throw new GroupError("group title must be between 1 and 128 characters", "invalid_group_title");
  }
  return title;
}

function normalizeMemberIds(value: unknown, creatorId: string, requireAtLeastOne = true): string[] {
  if (!Array.isArray(value)) throw new GroupError("memberIds must be an array", "member_unavailable");
  const ids = [...new Set(value.map((item) => requireUUID(item, "memberId")))]
    .filter((id) => id !== creatorId)
    .sort();
  if ((requireAtLeastOne && ids.length === 0) || ids.length + 1 > MAX_GROUP_MEMBERS) {
    throw new GroupError(
      ids.length + 1 > MAX_GROUP_MEMBERS
        ? "group member limit reached"
        : "select at least one registered contact",
      ids.length + 1 > MAX_GROUP_MEMBERS ? "member_limit_reached" : "member_unavailable",
    );
  }
  return ids;
}

function fingerprint(value: unknown): Buffer {
  return createHash("sha256").update(JSON.stringify(value)).digest();
}

function sameBuffer(left: unknown, right: Buffer): boolean {
  return Buffer.from(left as Uint8Array).equals(right);
}

async function lockAccounts(sql: SQL, accountIds: string[]): Promise<void> {
  const ids = [...new Set(accountIds)].sort();
  const rows = await sql`
    SELECT id FROM accounts
    WHERE id = ANY(${sql.array(ids, "uuid")}::uuid[])
      AND status IN ('active','limited')
    ORDER BY id
    FOR SHARE`;
  const found = new Set(rows.map((row: any) => String(row.id)));
  const missing = ids.filter((id) => !found.has(id));
  if (missing.length) {
    throw new GroupError("one or more members are unavailable", "member_unavailable", 400, {
      failingAccountIds: missing,
    });
  }
}

async function groupRow(sql: SQL, accountId: string, dialogId: string): Promise<any> {
  const row = (await sql`
    SELECT d.id, d.type, d.title, d.photo_media_id, d.revision, d.created_by,
           d.members_can_send, d.members_can_add_members, d.members_can_edit_info,
           d.created_at, d.closed_at, dm.role AS self_role, dm.notification_mode,
           dm.left_at,
           (SELECT count(*)::int FROM dialog_members active
            WHERE active.dialog_id = d.id AND active.left_at IS NULL) AS member_count
    FROM dialogs d
    LEFT JOIN dialog_members dm
      ON dm.dialog_id = d.id AND dm.account_id = ${accountId}
    WHERE d.id = ${dialogId}`)[0];
  if (!row || row.type !== "group") {
    throw new GroupError("group not found", "group_not_found", 404);
  }
  if (row.self_role == null) throw new GroupError("not a group member", "not_group_member", 403);
  if (row.left_at != null || row.closed_at != null) {
    throw new GroupError("group access revoked", "group_access_revoked", 410);
  }
  return row;
}

async function dtoFromRow(row: any): Promise<GroupDTO> {
  return {
    id: row.id,
    title: row.title,
    photo: await loadMediaDTO(row.__sql, row.photo_media_id),
    revision: n(row.revision),
    memberCount: n(row.member_count),
    selfRole: row.self_role,
    notificationMode: row.notification_mode,
    createdBy: row.created_by,
    createdAt: iso(row.created_at),
    closedAt: row.closed_at == null ? null : iso(row.closed_at),
    membersCanSend: row.members_can_send ?? true,
    membersCanAddMembers: row.members_can_add_members ?? false,
    membersCanEditInfo: row.members_can_edit_info ?? false,
  };
}

async function loadGroupDTO(sql: SQL, accountId: string, dialogId: string): Promise<GroupDTO> {
  const row = await groupRow(sql, accountId, dialogId);
  row.__sql = sql;
  return dtoFromRow(row);
}

async function activeMembers(sql: SQL, dialogId: string): Promise<GroupMemberDTO[]> {
  const rows = await sql`
    SELECT account_id, role, joined_at
    FROM dialog_members
    WHERE dialog_id = ${dialogId} AND left_at IS NULL
    ORDER BY joined_at, account_id`;
  return rows.map((row: any) => ({
    accountId: row.account_id,
    role: row.role,
    joinedAt: iso(row.joined_at),
    isActive: true,
  }));
}

async function envelope(
  sql: SQL,
  accountId: string,
  dialogId: string,
  options: { includeMembers?: boolean; duplicate?: boolean; pushes?: FanoutPush[] } = {},
): Promise<GroupEnvelope> {
  const group = await loadGroupDTO(sql, accountId, dialogId);
  const members = options.includeMembers ? await activeMembers(sql, dialogId) : undefined;
  const profileIds = new Set<string>([
    group.createdBy,
    ...(members?.map((member) => member.accountId) ?? []),
  ]);
  return {
    group,
    ...(members ? { members } : {}),
    profiles: await loadProfiles(sql, profileIds),
    ...(options.duplicate !== undefined ? { duplicate: options.duplicate } : {}),
    ...(options.pushes ? { pushes: options.pushes } : {}),
  };
}

async function insertServiceMessage(
  sql: SQL,
  actorAccountId: string,
  dialogId: string,
  serviceType: string,
  serviceData: Record<string, unknown>,
): Promise<number> {
  const dialog = (await sql`
    UPDATE dialogs
    SET last_msg_id = last_msg_id + 1, updated_at = now()
    WHERE id = ${dialogId}
    RETURNING last_msg_id`)[0];
  const msgId = n(dialog.last_msg_id);
  const clientHash = createHash("sha256")
    .update(`${dialogId}|${msgId}|${serviceType}`)
    .digest("hex");
  const clientMsgId = [
    clientHash.slice(0, 8),
    clientHash.slice(8, 12),
    `4${clientHash.slice(13, 16)}`,
    `a${clientHash.slice(17, 20)}`,
    clientHash.slice(20, 32),
  ].join("-");
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
      ${sealed.keyId}, ${sealed.nonce}, ${sealed.ciphertext},
      ${serviceType}, ${JSON.stringify(serviceData)}::jsonb
    )`;
  return msgId;
}

async function emitLifecycle(
  sql: SQL,
  actorAccountId: string,
  dialogId: string,
  eventType: string,
  serviceType: string,
  serviceData: Record<string, unknown>,
  sourceDeviceId?: string | null,
  recipientAccountIds?: string[],
): Promise<FanoutPush[]> {
  const msgId = await insertServiceMessage(sql, actorAccountId, dialogId, serviceType, serviceData);
  const state = (await sql`
    SELECT id, title, revision,
           (SELECT count(*)::int FROM dialog_members
            WHERE dialog_id = ${dialogId} AND left_at IS NULL) AS member_count
    FROM dialogs WHERE id = ${dialogId}`)[0];
  return fanoutDialogEvent(sql, {
    dialogId,
    type: eventType,
    msgId,
    actorAccountId,
    sourceDeviceId,
    recipientAccountIds,
    data: {
      dialog_type: "group",
      group_revision: n(state.revision),
      member_count: n(state.member_count),
      group: {
        id: state.id,
        title: state.title,
        revision: n(state.revision),
        memberCount: n(state.member_count),
      },
      service_type: serviceType,
      service_data: serviceData,
    },
  });
}

async function enforceCreateBudget(sql: SQL, creatorId: string): Promise<void> {
  const count = n((await sql`
    SELECT count(*)::int AS count FROM group_action_budgets
    WHERE account_id = ${creatorId} AND action = 'create'
      AND created_at > now() - interval '24 hours'`)[0].count);
  if (count >= CREATE_LIMIT_PER_DAY) {
    throw new GroupError("group creation rate limit reached", "rate_limited", 429, {}, 3600);
  }
}

async function enforceAddBudgets(
  sql: SQL,
  actorId: string,
  targetIds: string[],
): Promise<Map<string, "all" | "muted">> {
  const addCount = n((await sql`
    SELECT count(*)::int AS count FROM group_action_budgets
    WHERE account_id = ${actorId} AND action = 'add'
      AND created_at > now() - interval '1 hour'`)[0].count);
  if (addCount + targetIds.length > ADD_LIMIT_PER_HOUR) {
    throw new GroupError("member add rate limit reached", "rate_limited", 429, {}, 3600);
  }
  const relationships = await sql`
    SELECT target.id,
           EXISTS (
             SELECT 1
             FROM dialog_members actor_member
             JOIN dialog_members target_member
               ON target_member.dialog_id = actor_member.dialog_id
             WHERE actor_member.account_id = ${actorId}
               AND target_member.account_id = target.id
               AND actor_member.left_at IS NULL
               AND target_member.left_at IS NULL
           ) AS known
    FROM unnest(${sql.array(targetIds, "uuid")}::uuid[]) AS target(id)
    ORDER BY target.id`;
  const modes = new Map<string, "all" | "muted">();
  for (const target of relationships) {
    if (!target.known) {
      const targetCount = n((await sql`
        SELECT count(*)::int AS count FROM group_action_budgets
        WHERE target_account_id = ${target.id} AND action = 'stranger_add'
          AND created_at > now() - interval '24 hours'`)[0].count);
      if (targetCount >= STRANGER_ADD_LIMIT_PER_DAY) {
        throw new GroupError("member cannot be added right now", "rate_limited", 429, {
          failingAccountIds: [target.id],
        }, 3600);
      }
      modes.set(target.id, "muted");
    } else {
      modes.set(target.id, "all");
    }
  }
  return modes;
}

async function recordBudgets(
  sql: SQL,
  actorId: string,
  targetModes: Map<string, "all" | "muted">,
  create = false,
): Promise<void> {
  if (create) {
    await sql`INSERT INTO group_action_budgets (account_id, action) VALUES (${actorId}, 'create')`;
  }
  const targets = [...targetModes.keys()];
  if (targets.length) {
    await sql`
      INSERT INTO group_action_budgets (account_id, target_account_id, action)
      SELECT ${actorId}, target, 'add'
      FROM unnest(${sql.array(targets, "uuid")}::uuid[]) AS target`;
    const strangers = targets.filter((id) => targetModes.get(id) === "muted");
    if (strangers.length) {
      await sql`
        INSERT INTO group_action_budgets (account_id, target_account_id, action)
        SELECT ${actorId}, target, 'stranger_add'
        FROM unnest(${sql.array(strangers, "uuid")}::uuid[]) AS target`;
    }
  }
}

export async function createGroup(sql: SQL, input: {
  creatorAccountId: string;
  creatorDeviceId?: string | null;
  groupId: unknown;
  title: unknown;
  memberIds: unknown;
}): Promise<GroupEnvelope> {
  const groupId = requireUUID(input.groupId, "groupId", true);
  const title = normalizeTitle(input.title);
  const memberIds = normalizeMemberIds(input.memberIds, input.creatorAccountId);
  const requestFingerprint = fingerprint([title, memberIds]);
  return sql.begin(async (tx) => {
    const claim = await tx`
      INSERT INTO group_create_requests (
        creator_account_id, client_group_id, fingerprint, status
      ) VALUES (
        ${input.creatorAccountId}, ${groupId}, ${requestFingerprint}, 'pending'
      )
      ON CONFLICT (creator_account_id, client_group_id) DO NOTHING
      RETURNING status`;
    if (claim.length === 0) {
      const existing = (await tx`
        SELECT fingerprint, status FROM group_create_requests
        WHERE creator_account_id = ${input.creatorAccountId}
          AND client_group_id = ${groupId}
        FOR UPDATE`)[0];
      if (!sameBuffer(existing.fingerprint, requestFingerprint)) {
        throw new GroupError("group request was reused with different details", "idempotency_conflict", 409);
      }
      if (existing.status !== "completed") {
        throw new GroupError("group creation is already in progress", "create_in_progress", 409);
      }
      return envelope(tx, input.creatorAccountId, groupId, {
        includeMembers: true,
        duplicate: true,
      });
    }

    await lockAccounts(tx, [input.creatorAccountId, ...memberIds]);
    await enforceCreateBudget(tx, input.creatorAccountId);
    const modes = await enforceAddBudgets(tx, input.creatorAccountId, memberIds);
    const inserted = await tx`
      INSERT INTO dialogs (id, type, title, created_by, revision)
      VALUES (${groupId}, 'group', ${title}, ${input.creatorAccountId}, 1)
      ON CONFLICT (id) DO NOTHING
      RETURNING id`;
    if (inserted.length === 0) {
      throw new GroupError("group request conflicts with an existing request", "idempotency_conflict", 409);
    }
    await tx`
      INSERT INTO dialog_members (
        dialog_id, account_id, role, invited_by, notification_mode
      ) VALUES (
        ${groupId}, ${input.creatorAccountId}, 'owner', ${input.creatorAccountId}, 'all'
      )`;
    await tx`
      INSERT INTO dialog_members (
        dialog_id, account_id, role, invited_by, notification_mode
      )
      SELECT ${groupId}, member_id, 'member', ${input.creatorAccountId}, mode
      FROM unnest(
        ${tx.array(memberIds, "uuid")}::uuid[],
        ${tx.array(memberIds.map((id) => modes.get(id) ?? "all"), "text")}::text[]
      ) AS member(member_id, mode)`;
    await recordBudgets(tx, input.creatorAccountId, modes, true);
    const pushes = await emitLifecycle(
      tx,
      input.creatorAccountId,
      groupId,
      "dialog.created",
      "group.created",
      { actor_account_id: input.creatorAccountId, member_account_ids: memberIds, title },
      input.creatorDeviceId,
    );
    await tx`
      UPDATE group_create_requests
      SET status = 'completed', result_revision = 1
      WHERE creator_account_id = ${input.creatorAccountId}
        AND client_group_id = ${groupId}`;
    return envelope(tx, input.creatorAccountId, groupId, {
      includeMembers: true,
      duplicate: false,
      pushes,
    });
  });
}

export async function getGroup(
  sql: SQL,
  accountId: string,
  dialogId: string,
): Promise<GroupEnvelope> {
  await requireDialogReadAccess(sql, accountId, dialogId).catch(mapAccessError);
  return envelope(sql, accountId, dialogId);
}

export async function getGroupMembers(
  sql: SQL,
  accountId: string,
  dialogId: string,
  options: { cursor?: string | null; limit?: unknown } = {},
): Promise<{
  group: GroupDTO;
  members: GroupMemberDTO[];
  profiles: ProfileDTO[];
  nextCursor?: string;
  hasMore: boolean;
}> {
  await requireDialogReadAccess(sql, accountId, dialogId).catch(mapAccessError);
  const limit = Math.max(1, Math.min(100, Number(options.limit ?? 50) || 50));
  let joinedAt: string | null = null;
  let cursorAccountId: string | null = null;
  if (options.cursor) {
    try {
      const decoded = JSON.parse(Buffer.from(options.cursor, "base64url").toString("utf8"));
      joinedAt = String(decoded.joinedAt);
      cursorAccountId = requireUUID(decoded.accountId, "cursor account id");
    } catch {
      throw new GroupError("invalid member cursor", "invalid_request");
    }
  }
  const rows = joinedAt && cursorAccountId
    ? await sql`
        SELECT account_id, role, joined_at, joined_at::text AS joined_cursor
        FROM dialog_members
        WHERE dialog_id = ${dialogId} AND left_at IS NULL
          AND (joined_at, account_id) > (${joinedAt}::timestamptz, ${cursorAccountId}::uuid)
        ORDER BY joined_at, account_id
        LIMIT ${limit + 1}`
    : await sql`
        SELECT account_id, role, joined_at, joined_at::text AS joined_cursor
        FROM dialog_members
        WHERE dialog_id = ${dialogId} AND left_at IS NULL
        ORDER BY joined_at, account_id
        LIMIT ${limit + 1}`;
  const pageRows = rows.slice(0, limit);
  const members = pageRows.map((row: any) => ({
    accountId: row.account_id,
    role: row.role,
    joinedAt: iso(row.joined_at),
    isActive: true,
  })) as GroupMemberDTO[];
  const last = rows.length > limit ? pageRows[pageRows.length - 1] : null;
  return {
    group: await loadGroupDTO(sql, accountId, dialogId),
    members,
    profiles: await loadProfiles(sql, members.map((member) => member.accountId)),
    nextCursor: last ? Buffer.from(JSON.stringify({
      joinedAt: last.joined_cursor,
      accountId: last.account_id,
    })).toString("base64url") : undefined,
    hasMore: rows.length > limit,
  };
}

type MutationOperation =
  | "add_members" | "remove_member" | "change_role" | "update_profile"
  | "transfer_owner" | "leave" | "notifications";

async function claimMutation(
  sql: SQL,
  actorId: string,
  mutationIdValue: unknown,
  dialogId: string,
  operation: MutationOperation,
  normalizedInput: unknown,
): Promise<{ duplicate: boolean; mutationId: string }> {
  const mutationId = requireUUID(mutationIdValue, "clientMutationId");
  const inputFingerprint = fingerprint(normalizedInput);
  const inserted = await sql`
    INSERT INTO group_mutation_requests (
      actor_account_id, client_mutation_id, dialog_id, operation, fingerprint, status
    ) VALUES (
      ${actorId}, ${mutationId}, ${dialogId}, ${operation}, ${inputFingerprint}, 'pending'
    )
    ON CONFLICT (actor_account_id, client_mutation_id) DO NOTHING
    RETURNING status`;
  if (inserted.length) return { duplicate: false, mutationId };
  const existing = (await sql`
    SELECT dialog_id, operation, fingerprint, status
    FROM group_mutation_requests
    WHERE actor_account_id = ${actorId} AND client_mutation_id = ${mutationId}
    FOR UPDATE`)[0];
  if (
    existing.dialog_id !== dialogId
    || existing.operation !== operation
    || !sameBuffer(existing.fingerprint, inputFingerprint)
  ) {
    throw new GroupError("mutation id was reused with different details", "idempotency_conflict", 409);
  }
  if (existing.status !== "completed") {
    throw new GroupError("group mutation is already in progress", "create_in_progress", 409);
  }
  return { duplicate: true, mutationId };
}

async function completeMutation(
  sql: SQL,
  actorId: string,
  mutationId: string,
  revision: number,
): Promise<void> {
  await sql`
    UPDATE group_mutation_requests
    SET status = 'completed', result_revision = ${revision}
    WHERE actor_account_id = ${actorId} AND client_mutation_id = ${mutationId}`;
}

async function bumpRevision(sql: SQL, dialogId: string): Promise<number> {
  const row = (await sql`
    UPDATE dialogs SET revision = revision + 1, updated_at = now()
    WHERE id = ${dialogId}
    RETURNING revision`)[0];
  return n(row.revision);
}

function mapAccessError(error: unknown): never {
  if (error instanceof DialogAccessError) {
    throw new GroupError(error.message, error.code, error.status);
  }
  throw error;
}

async function mutationAccess(
  sql: SQL,
  actorId: string,
  dialogId: string,
  roles: Array<DialogAccess["role"]>,
): Promise<DialogAccess> {
  try {
    const access = await lockDialogForMutation(sql, actorId, dialogId);
    requireGroupRole(access, roles);
    return access;
  } catch (error) {
    return mapAccessError(error);
  }
}

async function permissionAccess(
  sql: SQL,
  actorId: string,
  dialogId: string,
  memberPermission: "membersCanAddMembers" | "membersCanEditInfo",
): Promise<DialogAccess> {
  try {
    const access = await lockDialogForMutation(sql, actorId, dialogId);
    requireGroupRole(access, ["owner", "admin", "member"]);
    if (access.role === "member" && !access[memberPermission]) {
      throw new GroupError("this action is restricted to administrators", "insufficient_group_role", 403);
    }
    return access;
  } catch (error) {
    return mapAccessError(error);
  }
}

export async function addGroupMembers(sql: SQL, input: {
  actorAccountId: string;
  actorDeviceId?: string | null;
  dialogId: string;
  memberIds: unknown;
  clientMutationId: unknown;
}): Promise<GroupEnvelope> {
  const ids = normalizeMemberIds(input.memberIds, input.actorAccountId);
  return sql.begin(async (tx) => {
    const claim = await claimMutation(
      tx, input.actorAccountId, input.clientMutationId, input.dialogId, "add_members", ids,
    );
    if (claim.duplicate) return envelope(tx, input.actorAccountId, input.dialogId, { duplicate: true });
    await lockAccounts(tx, [input.actorAccountId, ...ids]);
    const modes = await enforceAddBudgets(tx, input.actorAccountId, ids);
    await permissionAccess(tx, input.actorAccountId, input.dialogId, "membersCanAddMembers");
    const activeCount = n((await tx`
      SELECT count(*)::int AS count FROM dialog_members
      WHERE dialog_id = ${input.dialogId} AND left_at IS NULL`)[0].count);
    const alreadyActive = await tx`
      SELECT account_id FROM dialog_members
      WHERE dialog_id = ${input.dialogId} AND left_at IS NULL
        AND account_id = ANY(${tx.array(ids, "uuid")}::uuid[])`;
    if (alreadyActive.length) {
      throw new GroupError("one or more accounts are already members", "member_unavailable", 400, {
        failingAccountIds: alreadyActive.map((row: any) => row.account_id),
      });
    }
    if (activeCount + ids.length > MAX_GROUP_MEMBERS) {
      throw new GroupError("group member limit reached", "member_limit_reached", 409);
    }
    const lastMsgId = n((await tx`
      SELECT last_msg_id FROM dialogs WHERE id = ${input.dialogId}`)[0].last_msg_id);
    for (const id of ids) {
      await tx`
        INSERT INTO dialog_members (
          dialog_id, account_id, role, last_read_msg_id, invited_by,
          notification_mode, joined_at, left_at
        ) VALUES (
          ${input.dialogId}, ${id}, 'member', ${lastMsgId}, ${input.actorAccountId},
          ${modes.get(id) ?? "all"}, now(), NULL
        )
        ON CONFLICT (dialog_id, account_id) DO UPDATE SET
          role = 'member',
          last_read_msg_id = ${lastMsgId},
          invited_by = ${input.actorAccountId},
          notification_mode = ${modes.get(id) ?? "all"},
          joined_at = now(),
          left_at = NULL`;
    }
    await recordBudgets(tx, input.actorAccountId, modes);
    const revision = await bumpRevision(tx, input.dialogId);
    const existingIds = (await tx`
      SELECT account_id FROM dialog_members
      WHERE dialog_id = ${input.dialogId} AND left_at IS NULL
        AND NOT (account_id = ANY(${tx.array(ids, "uuid")}::uuid[]))
      ORDER BY account_id`).map((row: any) => row.account_id);
    const pushes = [
      ...await emitLifecycle(
        tx, input.actorAccountId, input.dialogId, "member.added", "member.added",
        { actor_account_id: input.actorAccountId, member_account_ids: ids },
        input.actorDeviceId, existingIds,
      ),
      ...await fanoutDialogEvent(tx, {
        dialogId: input.dialogId,
        type: "dialog.created",
        actorAccountId: input.actorAccountId,
        sourceDeviceId: input.actorDeviceId,
        recipientAccountIds: ids,
        data: {
          dialog_type: "group",
          group_revision: revision,
          member_count: activeCount + ids.length,
        },
      }),
    ];
    await completeMutation(tx, input.actorAccountId, claim.mutationId, revision);
    return envelope(tx, input.actorAccountId, input.dialogId, { pushes });
  });
}

export async function removeGroupMember(sql: SQL, input: {
  actorAccountId: string;
  actorDeviceId?: string | null;
  dialogId: string;
  targetAccountId: unknown;
  clientMutationId: unknown;
}, groupCallSFUControl?: GroupCallSFUControl): Promise<GroupEnvelope> {
  const targetId = requireUUID(input.targetAccountId, "accountId");
  let affectedGroupCallIds: string[] = [];
  const result = await sql.begin(async (tx) => {
    const claim = await claimMutation(
      tx, input.actorAccountId, input.clientMutationId, input.dialogId, "remove_member", targetId,
    );
    if (claim.duplicate) return envelope(tx, input.actorAccountId, input.dialogId, { duplicate: true });
    const access = await mutationAccess(tx, input.actorAccountId, input.dialogId, ["owner", "admin"]);
    const target = (await tx`
      SELECT role FROM dialog_members
      WHERE dialog_id = ${input.dialogId} AND account_id = ${targetId} AND left_at IS NULL
      FOR UPDATE`)[0];
    if (!target) throw new GroupError("member is unavailable", "member_unavailable", 404);
    if (target.role === "owner" || (target.role === "admin" && access.role !== "owner")) {
      throw new GroupError("insufficient group role", "insufficient_group_role", 403);
    }
    await tx`
      UPDATE dialog_members SET left_at = now()
      WHERE dialog_id = ${input.dialogId} AND account_id = ${targetId}`;
    // Membership and media authorization share the locked dialog as their linearization point.
    // The removed account loses its group-call participant and forces a fresh epoch in this same
    // commit, so it can never remain an SFU-authorized member after group access is revoked.
    affectedGroupCallIds = await revokeGroupCallAccountInLockedDialog(tx, input.dialogId, targetId);
    await purgeRevokedDialogDraftState(tx, targetId, input.dialogId);
    await scrubDialogFromChatFoldersInTransaction(tx, targetId, input.dialogId);
    await failScheduledDeliveriesForRevokedDialogInTransaction(tx, targetId, input.dialogId);
    const revision = await bumpRevision(tx, input.dialogId);
    const pushes = await emitLifecycle(
      tx, input.actorAccountId, input.dialogId, "member.removed", "member.removed",
      { actor_account_id: input.actorAccountId, subject_account_id: targetId },
      input.actorDeviceId,
    );
    pushes.push(await appendAccessRevokedEvent(
      tx, targetId, input.dialogId, input.actorAccountId, "group",
    ));
    await completeMutation(tx, input.actorAccountId, claim.mutationId, revision);
    return envelope(tx, input.actorAccountId, input.dialogId, { pushes });
  });
  if (affectedGroupCallIds.length) {
    await requireGroupCallSFUBarrierApplied(sql, affectedGroupCallIds, groupCallSFUControl);
  }
  return result;
}

export async function changeGroupMemberRole(sql: SQL, input: {
  actorAccountId: string;
  actorDeviceId?: string | null;
  dialogId: string;
  targetAccountId: unknown;
  role: unknown;
  clientMutationId: unknown;
}): Promise<GroupEnvelope> {
  const targetId = requireUUID(input.targetAccountId, "accountId");
  const role = String(input.role ?? "");
  if (role !== "admin" && role !== "member") {
    throw new GroupError("role must be admin or member", "invalid_request");
  }
  return sql.begin(async (tx) => {
    const claim = await claimMutation(
      tx, input.actorAccountId, input.clientMutationId, input.dialogId, "change_role", [targetId, role],
    );
    if (claim.duplicate) return envelope(tx, input.actorAccountId, input.dialogId, { duplicate: true });
    await mutationAccess(tx, input.actorAccountId, input.dialogId, ["owner"]);
    const changed = await tx`
      UPDATE dialog_members SET role = ${role}
      WHERE dialog_id = ${input.dialogId} AND account_id = ${targetId}
        AND left_at IS NULL AND role <> 'owner'
      RETURNING account_id`;
    if (!changed.length) throw new GroupError("member is unavailable", "member_unavailable", 404);
    const revision = await bumpRevision(tx, input.dialogId);
    const pushes = await emitLifecycle(
      tx, input.actorAccountId, input.dialogId, "member.role_changed", "member.role_changed",
      { actor_account_id: input.actorAccountId, subject_account_id: targetId, role },
      input.actorDeviceId,
    );
    await completeMutation(tx, input.actorAccountId, claim.mutationId, revision);
    return envelope(tx, input.actorAccountId, input.dialogId, { pushes });
  });
}

export async function updateGroupProfile(sql: SQL, input: {
  actorAccountId: string;
  actorDeviceId?: string | null;
  dialogId: string;
  title?: unknown;
  photoMediaId?: unknown;
  clearPhoto?: boolean;
  clientMutationId: unknown;
}): Promise<GroupEnvelope> {
  const title = input.title === undefined ? undefined : normalizeTitle(input.title);
  const photoMediaId = input.photoMediaId == null
    ? null
    : requireUUID(input.photoMediaId, "photoMediaId");
  if (title === undefined && photoMediaId === null && !input.clearPhoto) {
    throw new GroupError("title or photo change required", "invalid_request");
  }
  return sql.begin(async (tx) => {
    const claim = await claimMutation(
      tx, input.actorAccountId, input.clientMutationId, input.dialogId, "update_profile",
      [title ?? null, photoMediaId, Boolean(input.clearPhoto)],
    );
    if (claim.duplicate) return envelope(tx, input.actorAccountId, input.dialogId, { duplicate: true });
    if (photoMediaId) {
      const media = (await tx`
        SELECT owner_account_id, kind, purpose, status
        FROM media_objects WHERE id = ${photoMediaId}
        FOR UPDATE`)[0];
      if (
        !media || media.owner_account_id !== input.actorAccountId || media.kind !== "photo"
        || media.purpose !== "group_photo" || media.status !== "ready"
      ) {
        throw new GroupError("group photo upload is unavailable", "member_unavailable", 404);
      }
    }
    await permissionAccess(tx, input.actorAccountId, input.dialogId, "membersCanEditInfo");
    await tx`
      UPDATE dialogs SET
        title = COALESCE(${title ?? null}, title),
        photo_media_id = CASE
          WHEN ${Boolean(input.clearPhoto)} THEN NULL
          WHEN ${photoMediaId}::uuid IS NOT NULL THEN ${photoMediaId}::uuid
          ELSE photo_media_id
        END
      WHERE id = ${input.dialogId}`;
    const revision = await bumpRevision(tx, input.dialogId);
    const serviceType = title !== undefined ? "dialog.title_changed" : "dialog.photo_changed";
    const pushes = await emitLifecycle(
      tx, input.actorAccountId, input.dialogId, "dialog.profile_updated", serviceType,
      { actor_account_id: input.actorAccountId, ...(title !== undefined ? { title } : {}) },
      input.actorDeviceId,
    );
    await completeMutation(tx, input.actorAccountId, claim.mutationId, revision);
    return envelope(tx, input.actorAccountId, input.dialogId, { pushes });
  });
}

export async function updateGroupPermissions(sql: SQL, input: {
  actorAccountId: string;
  actorDeviceId?: string | null;
  dialogId: string;
  membersCanSend: unknown;
  membersCanAddMembers: unknown;
  membersCanEditInfo: unknown;
  clientMutationId: unknown;
}): Promise<GroupEnvelope> {
  const values = [input.membersCanSend, input.membersCanAddMembers, input.membersCanEditInfo];
  if (values.some((value) => typeof value !== "boolean")) {
    throw new GroupError("all permission values are required", "invalid_request");
  }
  const permissions = {
    membersCanSend: input.membersCanSend as boolean,
    membersCanAddMembers: input.membersCanAddMembers as boolean,
    membersCanEditInfo: input.membersCanEditInfo as boolean,
  };
  return sql.begin(async (tx) => {
    const claim = await claimMutation(
      tx, input.actorAccountId, input.clientMutationId, input.dialogId,
      "update_permissions", permissions,
    );
    if (claim.duplicate) return envelope(tx, input.actorAccountId, input.dialogId, { duplicate: true });
    await mutationAccess(tx, input.actorAccountId, input.dialogId, ["owner", "admin"]);
    await tx`
      UPDATE dialogs SET members_can_send = ${permissions.membersCanSend},
        members_can_add_members = ${permissions.membersCanAddMembers},
        members_can_edit_info = ${permissions.membersCanEditInfo}
      WHERE id = ${input.dialogId}`;
    const revision = await bumpRevision(tx, input.dialogId);
    const pushes = await fanoutDialogEvent(tx, {
      dialogId: input.dialogId,
      type: "dialog.profile_updated",
      actorAccountId: input.actorAccountId,
      sourceDeviceId: input.actorDeviceId,
      data: {
        group_revision: revision,
        members_can_send: permissions.membersCanSend,
        members_can_add_members: permissions.membersCanAddMembers,
        members_can_edit_info: permissions.membersCanEditInfo,
      },
    });
    await completeMutation(tx, input.actorAccountId, claim.mutationId, revision);
    return envelope(tx, input.actorAccountId, input.dialogId, { pushes });
  });
}

export async function transferGroupOwner(sql: SQL, input: {
  actorAccountId: string;
  actorDeviceId?: string | null;
  dialogId: string;
  targetAccountId: unknown;
  clientMutationId: unknown;
}): Promise<GroupEnvelope> {
  const targetId = requireUUID(input.targetAccountId, "accountId");
  if (targetId === input.actorAccountId) {
    throw new GroupError("select another member", "member_unavailable");
  }
  return sql.begin(async (tx) => {
    const claim = await claimMutation(
      tx, input.actorAccountId, input.clientMutationId, input.dialogId, "transfer_owner", targetId,
    );
    if (claim.duplicate) return envelope(tx, input.actorAccountId, input.dialogId, { duplicate: true });
    await mutationAccess(tx, input.actorAccountId, input.dialogId, ["owner"]);
    const target = await tx`
      SELECT account_id FROM dialog_members
      WHERE dialog_id = ${input.dialogId} AND account_id = ${targetId} AND left_at IS NULL
      FOR UPDATE`;
    if (!target.length) throw new GroupError("member is unavailable", "member_unavailable", 404);
    // The partial unique owner index means the old owner must move first inside the locked dialog.
    await tx`
      UPDATE dialog_members SET role = 'admin'
      WHERE dialog_id = ${input.dialogId} AND account_id = ${input.actorAccountId}`;
    await tx`
      UPDATE dialog_members SET role = 'owner'
      WHERE dialog_id = ${input.dialogId} AND account_id = ${targetId}`;
    const revision = await bumpRevision(tx, input.dialogId);
    const pushes = await emitLifecycle(
      tx, input.actorAccountId, input.dialogId, "member.role_changed", "dialog.owner_transferred",
      { actor_account_id: input.actorAccountId, subject_account_id: targetId },
      input.actorDeviceId,
    );
    await completeMutation(tx, input.actorAccountId, claim.mutationId, revision);
    return envelope(tx, input.actorAccountId, input.dialogId, { pushes });
  });
}

export async function leaveGroup(sql: SQL, input: {
  actorAccountId: string;
  actorDeviceId?: string | null;
  dialogId: string;
  successorAccountId?: unknown;
  clientMutationId: unknown;
}, groupCallSFUControl?: GroupCallSFUControl): Promise<{
  left: true; closed: boolean; pushes: FanoutPush[];
}> {
  const successorId = input.successorAccountId == null
    ? null
    : requireUUID(input.successorAccountId, "successorAccountId");
  let affectedGroupCallIds: string[] = [];
  const result = await sql.begin(async (tx) => {
    const claim = await claimMutation(
      tx, input.actorAccountId, input.clientMutationId, input.dialogId, "leave", successorId,
    );
    if (claim.duplicate) return { left: true, closed: false, pushes: [] };
    const access = await mutationAccess(
      tx, input.actorAccountId, input.dialogId, ["owner", "admin", "member"],
    );
    const count = n((await tx`
      SELECT count(*)::int AS count FROM dialog_members
      WHERE dialog_id = ${input.dialogId} AND left_at IS NULL`)[0].count);
    let closed = false;
    if (access.role === "owner" && count > 1) {
      if (!successorId) {
        throw new GroupError("transfer ownership before leaving", "owner_transfer_required", 409);
      }
      const successor = await tx`
        SELECT account_id FROM dialog_members
        WHERE dialog_id = ${input.dialogId} AND account_id = ${successorId}
          AND left_at IS NULL AND account_id <> ${input.actorAccountId}
        FOR UPDATE`;
      if (!successor.length) throw new GroupError("successor is unavailable", "member_unavailable", 404);
      await tx`
        UPDATE dialog_members SET role = 'admin'
        WHERE dialog_id = ${input.dialogId} AND account_id = ${input.actorAccountId}`;
      await tx`
        UPDATE dialog_members SET role = 'owner'
        WHERE dialog_id = ${input.dialogId} AND account_id = ${successorId}`;
    } else if (access.role === "owner") {
      closed = true;
      await tx`UPDATE dialogs SET closed_at = now() WHERE id = ${input.dialogId}`;
    }
    await tx`
      UPDATE dialog_members SET left_at = now()
      WHERE dialog_id = ${input.dialogId} AND account_id = ${input.actorAccountId}`;
    affectedGroupCallIds = await revokeGroupCallAccountInLockedDialog(
      tx,
      input.dialogId,
      input.actorAccountId,
    );
    await purgeRevokedDialogDraftState(tx, input.actorAccountId, input.dialogId);
    await scrubDialogFromChatFoldersInTransaction(tx, input.actorAccountId, input.dialogId);
    await failScheduledDeliveriesForRevokedDialogInTransaction(
      tx, input.actorAccountId, input.dialogId,
    );
    const revision = await bumpRevision(tx, input.dialogId);
    const pushes = closed
      ? []
      : await emitLifecycle(
          tx, input.actorAccountId, input.dialogId, "member.left", "member.left",
          {
            actor_account_id: input.actorAccountId,
            ...(successorId ? { successor_account_id: successorId } : {}),
          },
          input.actorDeviceId,
        );
    pushes.push(await appendAccessRevokedEvent(
      tx, input.actorAccountId, input.dialogId, input.actorAccountId, "group",
    ));
    await completeMutation(tx, input.actorAccountId, claim.mutationId, revision);
    return { left: true, closed, pushes };
  });
  if (affectedGroupCallIds.length) {
    await requireGroupCallSFUBarrierApplied(sql, affectedGroupCallIds, groupCallSFUControl);
  }
  return result;
}

export async function updateGroupNotifications(sql: SQL, input: {
  actorAccountId: string;
  actorDeviceId: string;
  dialogId: string;
  mode: unknown;
  clientMutationId: unknown;
  usePreferenceService?: boolean;
}): Promise<{ envelope: GroupEnvelope; pushes: FanoutPush[] }> {
  const mode = String(input.mode ?? "");
  if (mode !== "all" && mode !== "muted") {
    throw new GroupError("notification mode must be all or muted", "invalid_request");
  }
  if (input.usePreferenceService === false) {
    return sql.begin(async (tx) => {
      const claim = await claimMutation(
        tx,
        input.actorAccountId,
        input.clientMutationId,
        input.dialogId,
        "notifications",
        mode,
      );
      if (claim.duplicate) {
        return {
          envelope: await envelope(tx, input.actorAccountId, input.dialogId, {
            duplicate: true,
          }),
          pushes: [],
        };
      }
      const access = await mutationAccess(
        tx,
        input.actorAccountId,
        input.dialogId,
        ["owner", "admin", "member"],
      );
      await tx`
        UPDATE dialog_members
        SET notification_mode = ${mode}
        WHERE dialog_id = ${input.dialogId}
          AND account_id = ${input.actorAccountId}`;
      await completeMutation(tx, input.actorAccountId, claim.mutationId, access.revision);
      return {
        envelope: await envelope(tx, input.actorAccountId, input.dialogId),
        pushes: [],
      };
    }).catch((error: any) => {
      if (error?.message?.includes("dialog_preference_rate_limited")) {
        throw new GroupError(
          "dialog preference rate limit reached",
          "rate_limited",
          429,
          {},
          3600,
        );
      }
      if (error?.message?.includes("dialog_preference_account_unavailable")) {
        throw new GroupError("account unavailable", "account_unavailable", 403);
      }
      throw error;
    });
  }
  const result = await updateDialogPreferences(sql, {
    accountId: input.actorAccountId,
    deviceId: input.actorDeviceId,
    dialogId: input.dialogId,
    clientMutationId: input.clientMutationId,
    patch: { muted: mode === "muted" },
  });
  return {
    envelope: await envelope(sql, input.actorAccountId, input.dialogId, {
      duplicate: result.duplicate,
    }),
    pushes: result.pushes,
  };
}

/** Called inside account deletion after devices are revoked and before commit. */
export async function handoffOwnedGroupsForDeletedAccount(
  sql: SQL,
  accountId: string,
): Promise<void> {
  const owned = await sql`
    SELECT d.id
    FROM dialogs d
    JOIN dialog_members owner
      ON owner.dialog_id = d.id AND owner.account_id = ${accountId}
    WHERE d.type = 'group' AND d.closed_at IS NULL
      AND owner.role = 'owner' AND owner.left_at IS NULL
    ORDER BY d.id
    FOR UPDATE OF d`;
  for (const group of owned) {
    const successor = (await sql`
      SELECT account_id
      FROM dialog_members
      WHERE dialog_id = ${group.id} AND account_id <> ${accountId} AND left_at IS NULL
      ORDER BY CASE role WHEN 'admin' THEN 0 ELSE 1 END, joined_at, account_id
      LIMIT 1
      FOR UPDATE`)[0];
    await sql`
      UPDATE dialog_members SET left_at = now(), role = 'member'
      WHERE dialog_id = ${group.id} AND account_id = ${accountId}`;
    if (successor) {
      await sql`
        UPDATE dialog_members SET role = 'owner'
        WHERE dialog_id = ${group.id} AND account_id = ${successor.account_id}`;
    } else {
      await sql`UPDATE dialogs SET closed_at = now() WHERE id = ${group.id}`;
    }
    await bumpRevision(sql, group.id);
  }
}
