import { beforeEach, describe, expect, test } from "bun:test";
import { checkVerification, startVerification } from "./auth";
import { startCloudServer } from "./cloud";
import { makeSql } from "./db";
import { updateDialogPreferences } from "./dialog-preferences";
import {
  addGroupMembers,
  changeGroupMemberRole,
  createGroup,
  getGroupMembers,
  GroupError,
  leaveGroup,
  removeGroupMember,
  transferGroupOwner,
  updateGroupNotifications,
  updateGroupPermissions,
  updateGroupProfile,
} from "./groups";
import { getDifference, getHistory, sendMessage } from "./sync";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

async function resetDb() {
  await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
}

async function account(phone: string, name: string) {
  const { code } = await startVerification(db, phone);
  return checkVerification(db, phone, code, "ios", `${name} iPhone`, name);
}

async function threeAccounts() {
  const owner = await account("+16505553100", "Owner");
  const alice = await account("+16505553101", "Alice");
  const bob = await account("+16505553102", "Bob");
  return { owner, alice, bob };
}

describe("Groups v1", () => {
  beforeEach(resetDb);

  test("idempotent creation uses the final UUID and produces one owner, active members, and profiles", async () => {
    const { owner, alice, bob } = await threeAccounts();
    const groupId = crypto.randomUUID();
    const first = await createGroup(db, {
      creatorAccountId: owner.accountId,
      creatorDeviceId: owner.deviceId,
      groupId,
      title: "  Weekend plans  ",
      memberIds: [bob.accountId, alice.accountId, bob.accountId],
    });
    const retry = await createGroup(db, {
      creatorAccountId: owner.accountId,
      creatorDeviceId: owner.deviceId,
      groupId,
      title: "Weekend plans",
      memberIds: [alice.accountId, bob.accountId],
    });

    expect(first.group.id).toBe(groupId);
    expect(first.group.revision).toBe(1);
    expect(first.group.memberCount).toBe(3);
    expect(first.members?.find((member) => member.accountId === owner.accountId)?.role).toBe("owner");
    expect(first.profiles.map((profile) => profile.displayName).sort()).toEqual(["Alice", "Bob", "Owner"]);
    expect(retry.duplicate).toBe(true);
    expect(Number((await db`SELECT count(*) AS count FROM dialogs WHERE id = ${groupId}`)[0].count)).toBe(1);
    expect(Number((await db`SELECT count(*) AS count FROM messages WHERE dialog_id = ${groupId}`)[0].count)).toBe(1);
  });

  test("reusing a group id with different normalized input is a non-oracular conflict", async () => {
    const { owner, alice, bob } = await threeAccounts();
    const groupId = crypto.randomUUID();
    await createGroup(db, {
      creatorAccountId: owner.accountId,
      groupId,
      title: "One",
      memberIds: [alice.accountId],
    });
    await expect(createGroup(db, {
      creatorAccountId: owner.accountId,
      groupId,
      title: "Two",
      memberIds: [bob.accountId],
    })).rejects.toMatchObject({ code: "idempotency_conflict", status: 409 });
  });

  test("the existing message engine syncs group text and profile side payloads to every account", async () => {
    const { owner, alice, bob } = await threeAccounts();
    const groupId = crypto.randomUUID();
    await createGroup(db, {
      creatorAccountId: owner.accountId,
      groupId,
      title: "Core team",
      memberIds: [alice.accountId, bob.accountId],
    });
    const before = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${bob.accountId}`)[0].pts);
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId: groupId,
      clientMsgId: crypto.randomUUID(),
      body: "hello group",
    });
    const difference = await getDifference(db, bob.accountId, before);
    if (difference.kind === "difference_too_long") throw new Error("unexpected rebuild");
    expect(difference.updates).toHaveLength(1);
    expect(difference.updates[0].dialog_type).toBe("group");
    expect(difference.updates[0].message.text).toBe("hello group");
    expect(difference.profiles.some((profile) => profile.accountId === alice.accountId)).toBe(true);
  });

  test("structured mentions use UTF-16 ranges and require an active group member", async () => {
    const { owner, alice, bob } = await threeAccounts();
    const outsider = await account("+16505553104", "Outsider");
    const groupId = crypto.randomUUID();
    await createGroup(db, {
      creatorAccountId: owner.accountId,
      groupId,
      title: "Mentions",
      memberIds: [alice.accountId, bob.accountId],
    });
    const before = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${bob.accountId}`)[0].pts);
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId: groupId,
      clientMsgId: crypto.randomUUID(),
      body: "Hi @Bob",
      mentions: [{ accountId: bob.accountId, offset: 3, length: 4 }],
    });
    const difference = await getDifference(db, bob.accountId, before);
    if (difference.kind === "difference_too_long") throw new Error("unexpected rebuild");
    expect(difference.updates[0].message.mentions).toEqual([
      { account_id: bob.accountId, offset: 3, length: 4 },
    ]);
    await expect(sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId: groupId,
      clientMsgId: crypto.randomUUID(),
      body: "Hi @Outsider",
      mentions: [{ accountId: outsider.accountId, offset: 3, length: 9 }],
    })).rejects.toThrow("mention target is not an active member");
  });

  test("jsonb payloads are stored as objects, not double-encoded strings", async () => {
    const { owner, alice, bob } = await threeAccounts();
    const groupId = crypto.randomUUID();
    await createGroup(db, {
      creatorAccountId: owner.accountId,
      groupId,
      title: "Encoding group",
      memberIds: [alice.accountId, bob.accountId],
    });
    await removeGroupMember(db, {
      actorAccountId: owner.accountId,
      actorDeviceId: owner.deviceId,
      dialogId: groupId,
      targetAccountId: bob.accountId,
      clientMutationId: crypto.randomUUID(),
    });

    // Bun binds `${JSON.stringify(x)}::jsonb` as a JSON *string*, so the column ends up holding a
    // scalar and every SQL-side accessor (`->>`, jsonb_to_recordset, expression indexes) silently
    // returns NULL. The read paths parse defensively, so round-trips hide it — only SQL notices.
    // The cast that stores an object is `::text::jsonb`.
    expect(await db`
      SELECT 1 FROM messages
      WHERE service_data IS NOT NULL AND jsonb_typeof(service_data) <> 'object'`).toHaveLength(0);
    expect(await db`
      SELECT 1 FROM account_events WHERE jsonb_typeof(data) <> 'object'`).toHaveLength(0);

    // Both assertions above pass trivially against an empty table, so prove the rows exist and
    // that a key is actually reachable from SQL rather than buried inside a string.
    expect((await db`SELECT 1 FROM messages WHERE service_data IS NOT NULL`).length)
      .toBeGreaterThan(0);
    expect((await db`
      SELECT 1 FROM account_events
      WHERE type = 'dialog.access_revoked' AND data->>'dialog_type' IS NOT NULL`).length)
      .toBeGreaterThan(0);
  });

  test("removed members receive revocation only and lose history access immediately", async () => {
    const { owner, alice, bob } = await threeAccounts();
    const groupId = crypto.randomUUID();
    await createGroup(db, {
      creatorAccountId: owner.accountId,
      groupId,
      title: "Private group",
      memberIds: [alice.accountId, bob.accountId],
    });
    await sendMessage(db, {
      senderAccountId: alice.accountId,
      senderDeviceId: alice.deviceId,
      dialogId: groupId,
      clientMsgId: crypto.randomUUID(),
      body: "secret after removal race",
    });
    const since = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${bob.accountId}`)[0].pts);
    await removeGroupMember(db, {
      actorAccountId: owner.accountId,
      actorDeviceId: owner.deviceId,
      dialogId: groupId,
      targetAccountId: bob.accountId,
      clientMutationId: crypto.randomUUID(),
    });
    await expect(getHistory(db, bob.accountId, groupId)).rejects.toMatchObject({
      code: "group_access_revoked",
      status: 410,
    });
    const difference = await getDifference(db, bob.accountId, since);
    if (difference.kind === "difference_too_long") throw new Error("unexpected rebuild");
    expect(difference.updates).toHaveLength(1);
    expect(difference.updates[0]).toEqual(expect.objectContaining({
      type: "dialog.access_revoked",
      dialog_id: groupId,
    }));
    expect(difference.updates[0].message).toBeUndefined();
  });

  test("difference preserves group remove then re-add across separate and combined pages", async () => {
    const { owner, alice, bob } = await threeAccounts();
    const groupId = crypto.randomUUID();
    await createGroup(db, {
      creatorAccountId: owner.accountId,
      groupId,
      title: "Regrant ordering",
      memberIds: [alice.accountId, bob.accountId],
    });
    const since = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${bob.accountId}`)[0].pts);
    await removeGroupMember(db, {
      actorAccountId: owner.accountId,
      actorDeviceId: owner.deviceId,
      dialogId: groupId,
      targetAccountId: bob.accountId,
      clientMutationId: crypto.randomUUID(),
    });
    await addGroupMembers(db, {
      actorAccountId: owner.accountId,
      actorDeviceId: owner.deviceId,
      dialogId: groupId,
      memberIds: [bob.accountId],
      clientMutationId: crypto.randomUUID(),
    });

    const first = await getDifference(db, bob.accountId, since, { maxEvents: 1 });
    if (first.kind === "difference_too_long") throw new Error("unexpected rebuild");
    expect(first.updates.map((update) => update.type)).toEqual(["dialog.access_revoked"]);
    expect(first.hasMore).toBe(true);
    const second = await getDifference(db, bob.accountId, first.state.pts, { maxEvents: 1 });
    if (second.kind === "difference_too_long") throw new Error("unexpected rebuild");
    expect(second.updates.map((update) => update.type)).toEqual(["dialog.created"]);

    const combined = await getDifference(db, bob.accountId, since);
    if (combined.kind === "difference_too_long") throw new Error("unexpected rebuild");
    expect(combined.updates.map((update) => update.type)).toEqual([
      "dialog.access_revoked",
      "dialog.created",
    ]);
  });

  test("member paging is active-only and keyset based", async () => {
    const { owner, alice, bob } = await threeAccounts();
    const groupId = crypto.randomUUID();
    await createGroup(db, {
      creatorAccountId: owner.accountId,
      groupId,
      title: "Paging",
      memberIds: [alice.accountId, bob.accountId],
    });
    const first = await getGroupMembers(db, owner.accountId, groupId, { limit: 2 });
    expect(first.members).toHaveLength(2);
    expect(first.hasMore).toBe(true);
    const second = await getGroupMembers(db, owner.accountId, groupId, {
      limit: 2,
      cursor: first.nextCursor,
    });
    expect(second.members).toHaveLength(1);
    expect(new Set([...first.members, ...second.members].map((member) => member.accountId)).size).toBe(3);
  });

  test("the owner/admin/member role matrix is enforced and ownership stays unique", async () => {
    const { owner, alice, bob } = await threeAccounts();
    const charlie = await account("+16505553103", "Charlie");
    const groupId = crypto.randomUUID();
    await createGroup(db, {
      creatorAccountId: owner.accountId,
      groupId,
      title: "Roles",
      memberIds: [alice.accountId, bob.accountId],
    });

    await expect(addGroupMembers(db, {
      actorAccountId: bob.accountId,
      dialogId: groupId,
      memberIds: [charlie.accountId],
      clientMutationId: crypto.randomUUID(),
    })).rejects.toMatchObject({ code: "insufficient_group_role", status: 403 });

    await changeGroupMemberRole(db, {
      actorAccountId: owner.accountId,
      dialogId: groupId,
      targetAccountId: alice.accountId,
      role: "admin",
      clientMutationId: crypto.randomUUID(),
    });
    await addGroupMembers(db, {
      actorAccountId: alice.accountId,
      dialogId: groupId,
      memberIds: [charlie.accountId],
      clientMutationId: crypto.randomUUID(),
    });
    await expect(removeGroupMember(db, {
      actorAccountId: alice.accountId,
      dialogId: groupId,
      targetAccountId: owner.accountId,
      clientMutationId: crypto.randomUUID(),
    })).rejects.toMatchObject({ code: "insufficient_group_role", status: 403 });
    await removeGroupMember(db, {
      actorAccountId: alice.accountId,
      dialogId: groupId,
      targetAccountId: bob.accountId,
      clientMutationId: crypto.randomUUID(),
    });

    await transferGroupOwner(db, {
      actorAccountId: owner.accountId,
      dialogId: groupId,
      targetAccountId: alice.accountId,
      clientMutationId: crypto.randomUUID(),
    });
    await leaveGroup(db, {
      actorAccountId: owner.accountId,
      dialogId: groupId,
      clientMutationId: crypto.randomUUID(),
    });
    const roles = await db`
      SELECT account_id, role FROM dialog_members
      WHERE dialog_id = ${groupId} AND left_at IS NULL
      ORDER BY account_id`;
    expect(roles.filter((row: any) => row.role === "owner")).toEqual([
      expect.objectContaining({ account_id: alice.accountId }),
    ]);
    expect(roles.some((row: any) => row.account_id === bob.accountId)).toBe(false);
    expect(roles.some((row: any) => row.account_id === charlie.accountId)).toBe(true);
  });

  test("group mutations are idempotent and reject mutation-id reuse with different input", async () => {
    const { owner, alice } = await threeAccounts();
    const groupId = crypto.randomUUID();
    await createGroup(db, {
      creatorAccountId: owner.accountId,
      groupId,
      title: "Original",
      memberIds: [alice.accountId],
    });
    const mutationId = crypto.randomUUID();
    const first = await updateGroupProfile(db, {
      actorAccountId: owner.accountId,
      dialogId: groupId,
      title: "Updated",
      clientMutationId: mutationId,
    });
    const duplicate = await updateGroupProfile(db, {
      actorAccountId: owner.accountId,
      dialogId: groupId,
      title: "Updated",
      clientMutationId: mutationId,
    });
    expect(first.group.title).toBe("Updated");
    expect(duplicate.duplicate).toBe(true);
    await expect(updateGroupProfile(db, {
      actorAccountId: owner.accountId,
      dialogId: groupId,
      title: "Different",
      clientMutationId: mutationId,
    })).rejects.toMatchObject({ code: "idempotency_conflict", status: 409 });
  });

  test("group creation budget returns a typed 429 with Retry-After metadata", async () => {
    const { owner, alice } = await threeAccounts();
    await db`
      INSERT INTO group_action_budgets (account_id, action)
      SELECT ${owner.accountId}, 'create' FROM generate_series(1, 20)`;
    await expect(createGroup(db, {
      creatorAccountId: owner.accountId,
      groupId: crypto.randomUUID(),
      title: "Rate limited",
      memberIds: [alice.accountId],
    })).rejects.toMatchObject({ code: "rate_limited", status: 429, retryAfter: 3600 });
  });

  test("legacy group notification updates use the canonical preference event and mirror", async () => {
    const { owner, alice } = await threeAccounts();
    const groupId = crypto.randomUUID();
    await createGroup(db, {
      creatorAccountId: owner.accountId,
      creatorDeviceId: owner.deviceId,
      groupId,
      title: "Muted group",
      memberIds: [alice.accountId],
    });
    const ownerBefore = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${owner.accountId}`)[0].pts);
    const aliceBefore = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${alice.accountId}`)[0].pts);
    expect((await db`
      SELECT is_muted
      FROM dialog_preferences
      WHERE dialog_id = ${groupId} AND account_id = ${owner.accountId}`)[0].is_muted)
      .toBe(false);
    const mutationId = crypto.randomUUID();
    const first = await updateGroupNotifications(db, {
      actorAccountId: owner.accountId,
      actorDeviceId: owner.deviceId,
      dialogId: groupId,
      mode: "muted",
      clientMutationId: mutationId,
      usePreferenceService: false,
    });
    const retry = await updateGroupNotifications(db, {
      actorAccountId: owner.accountId,
      actorDeviceId: owner.deviceId,
      dialogId: groupId,
      mode: "muted",
      clientMutationId: mutationId,
      usePreferenceService: false,
    });
    expect(first.envelope.group.notificationMode).toBe("muted");
    expect(retry.envelope.duplicate).toBe(true);
    expect((await db`
      SELECT preference.is_muted, member.notification_mode
      FROM dialog_preferences preference
      JOIN dialog_members member
        ON member.dialog_id = preference.dialog_id
       AND member.account_id = preference.account_id
      WHERE preference.dialog_id = ${groupId}
        AND preference.account_id = ${owner.accountId}`)[0]).toMatchObject({
      is_muted: true,
      notification_mode: "muted",
    });
    const difference = await getDifference(db, owner.accountId, ownerBefore);
    if (difference.kind === "difference_too_long") throw new Error("unexpected rebuild");
    expect(difference.updates).toHaveLength(1);
    expect(difference.updates[0]).toMatchObject({
      type: "dialog.preferences_updated",
      preferences: { dialogId: groupId, muted: true },
    });
    expect(Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${alice.accountId}`)[0].pts))
      .toBe(aliceBefore);

    // A still-running legacy server may write only dialog_members during a rolling deployment.
    // The database mirror keeps the new preference source authoritative in both directions.
    await db`
      UPDATE dialog_members
      SET notification_mode = 'all'
      WHERE dialog_id = ${groupId} AND account_id = ${owner.accountId}`;
    expect((await db`
      SELECT is_muted
      FROM dialog_preferences
      WHERE dialog_id = ${groupId} AND account_id = ${owner.accountId}`)[0].is_muted)
      .toBe(false);
    const reconciled = await getDifference(db, owner.accountId, ownerBefore + 1);
    if (reconciled.kind === "difference_too_long") throw new Error("unexpected rebuild");
    expect(reconciled.updates).toHaveLength(1);
    expect(reconciled.updates[0]).toMatchObject({
      type: "dialog.preferences_updated",
      preferences: { dialogId: groupId, muted: false },
    });
  });

  test("stranger-muted invitations carry recipient preferences in dialog.created", async () => {
    const { owner, alice } = await threeAccounts();
    const groupId = crypto.randomUUID();
    await createGroup(db, {
      creatorAccountId: owner.accountId,
      creatorDeviceId: owner.deviceId,
      groupId,
      title: "Stranger invitation",
      memberIds: [alice.accountId],
    });
    const difference = await getDifference(db, alice.accountId, 0);
    if (difference.kind === "difference_too_long") throw new Error("unexpected rebuild");
    const created = difference.updates.find((update) => update.type === "dialog.created");
    expect(created).toMatchObject({
      dialog_id: groupId,
      preferences: {
        dialogId: groupId,
        muted: true,
        pinned: false,
        archived: false,
      },
    });
    expect((await db`
      SELECT preference.is_muted, member.notification_mode
      FROM dialog_preferences preference
      JOIN dialog_members member
        ON member.dialog_id = preference.dialog_id
       AND member.account_id = preference.account_id
      WHERE preference.dialog_id = ${groupId}
        AND preference.account_id = ${alice.accountId}`)[0]).toMatchObject({
      is_muted: true,
      notification_mode: "muted",
    });
  });

  test("legacy notification toggles share the durable 240-per-hour budget", async () => {
    const { owner, alice } = await threeAccounts();
    const groupId = crypto.randomUUID();
    await createGroup(db, {
      creatorAccountId: owner.accountId,
      creatorDeviceId: owner.deviceId,
      groupId,
      title: "Budgeted notifications",
      memberIds: [alice.accountId],
    });
    for (let index = 0; index < 240; index += 1) {
      await updateGroupNotifications(db, {
        actorAccountId: owner.accountId,
        actorDeviceId: owner.deviceId,
        dialogId: groupId,
        mode: index % 2 === 0 ? "muted" : "all",
        clientMutationId: crypto.randomUUID(),
        usePreferenceService: false,
      });
    }
    await expect(updateGroupNotifications(db, {
      actorAccountId: owner.accountId,
      actorDeviceId: owner.deviceId,
      dialogId: groupId,
      mode: "muted",
      clientMutationId: crypto.randomUUID(),
      usePreferenceService: false,
    })).rejects.toMatchObject({
      code: "rate_limited",
      status: 429,
      retryAfter: 3600,
    });
    expect(Number((await db`
      SELECT mutation_count
      FROM dialog_preference_action_budgets
      WHERE account_id = ${owner.accountId}
        AND bucket_started = date_trunc('hour', now())`)[0].mutation_count)).toBe(240);
  }, 15_000);

  test("an incoming message cannot unarchive a removed member's retained preference", async () => {
    const { owner, alice } = await threeAccounts();
    const groupId = crypto.randomUUID();
    await createGroup(db, {
      creatorAccountId: owner.accountId,
      creatorDeviceId: owner.deviceId,
      groupId,
      title: "Retained archive",
      memberIds: [alice.accountId],
    });
    await updateDialogPreferences(db, {
      accountId: alice.accountId,
      deviceId: alice.deviceId,
      dialogId: groupId,
      clientMutationId: crypto.randomUUID(),
      patch: { archived: true },
    });
    await removeGroupMember(db, {
      actorAccountId: owner.accountId,
      dialogId: groupId,
      targetAccountId: alice.accountId,
      clientMutationId: crypto.randomUUID(),
    });
    await sendMessage(db, {
      senderAccountId: owner.accountId,
      senderDeviceId: owner.deviceId,
      dialogId: groupId,
      clientMsgId: crypto.randomUUID(),
      body: "while removed",
    });
    expect((await db`
      SELECT is_archived
      FROM dialog_preferences
      WHERE dialog_id = ${groupId} AND account_id = ${alice.accountId}`)[0].is_archived)
      .toBe(true);

    await addGroupMembers(db, {
      actorAccountId: owner.accountId,
      dialogId: groupId,
      memberIds: [alice.accountId],
      clientMutationId: crypto.randomUUID(),
    });
    expect((await db`
      SELECT is_archived
      FROM dialog_preferences
      WHERE dialog_id = ${groupId} AND account_id = ${alice.accountId}`)[0].is_archived)
      .toBe(true);
  });

  test("granular member permissions are server-enforced and update atomically", async () => {
    const { owner, alice, bob } = await threeAccounts();
    const groupId = crypto.randomUUID();
    await createGroup(db, {
      creatorAccountId: owner.accountId,
      creatorDeviceId: owner.deviceId,
      groupId,
      title: "Permissions",
      memberIds: [alice.accountId],
    });
    const locked = await updateGroupPermissions(db, {
      actorAccountId: owner.accountId,
      actorDeviceId: owner.deviceId,
      dialogId: groupId,
      membersCanSend: false,
      membersCanAddMembers: false,
      membersCanEditInfo: false,
      clientMutationId: crypto.randomUUID(),
    });
    expect(locked.group).toMatchObject({
      membersCanSend: false, membersCanAddMembers: false, membersCanEditInfo: false,
    });
    await expect(sendMessage(db, {
      senderAccountId: alice.accountId, senderDeviceId: alice.deviceId,
      dialogId: groupId, clientMsgId: crypto.randomUUID(), body: "blocked",
    })).rejects.toMatchObject({ status: 403, code: "group_send_restricted" });
    await expect(addGroupMembers(db, {
      actorAccountId: alice.accountId, dialogId: groupId, memberIds: [bob.accountId],
      clientMutationId: crypto.randomUUID(),
    })).rejects.toMatchObject({ status: 403 });
    await updateGroupPermissions(db, {
      actorAccountId: owner.accountId,
      dialogId: groupId,
      membersCanSend: true,
      membersCanAddMembers: true,
      membersCanEditInfo: true,
      clientMutationId: crypto.randomUUID(),
    });
    await expect(sendMessage(db, {
      senderAccountId: alice.accountId, senderDeviceId: alice.deviceId,
      dialogId: groupId, clientMsgId: crypto.randomUUID(), body: "allowed",
    })).resolves.toMatchObject({ duplicate: false });
    await expect(addGroupMembers(db, {
      actorAccountId: alice.accountId, dialogId: groupId, memberIds: [bob.accountId],
      clientMutationId: crypto.randomUUID(),
    })).resolves.toMatchObject({ group: expect.objectContaining({ memberCount: 3 }) });
  });

  test("the route family hard-404s and stays unadvertised while the flag is off", async () => {
    const previous = process.env.TOJ_GROUPS_V1_ENABLED;
    delete process.env.TOJ_GROUPS_V1_ENABLED;
    const server = startCloudServer(0, db, null);
    try {
      const base = `http://127.0.0.1:${server.port}`;
      const route = await fetch(`${base}/v1/groups`, { method: "POST" });
      expect(route.status).toBe(404);
      const capabilities = await (await fetch(`${base}/v1/capabilities`)).json() as {
        capabilities: string[];
      };
      expect(capabilities.capabilities).not.toContain("groups_v1");
    } finally {
      server.stop(true);
      if (previous === undefined) delete process.env.TOJ_GROUPS_V1_ENABLED;
      else process.env.TOJ_GROUPS_V1_ENABLED = previous;
    }
  });

  test("validation exposes typed group errors", async () => {
    const owner = await account("+16505553120", "Owner");
    await expect(createGroup(db, {
      creatorAccountId: owner.accountId,
      groupId: "not-a-uuid",
      title: "Test",
      memberIds: [],
    })).rejects.toBeInstanceOf(GroupError);
  });
});
