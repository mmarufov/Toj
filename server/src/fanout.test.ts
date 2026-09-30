import { beforeEach, describe, expect, test } from "bun:test";
import { SQL } from "bun";
import { checkVerification, startVerification } from "./auth";
import { makeSql } from "./db";
import { fanoutDialogEvent } from "./fanout";
import { createGroup } from "./groups";
import { countStatements } from "./statement-count";
import { sendMessage } from "./sync";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

async function resetDb() {
  await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
}

async function accounts(count: number, offset = 0) {
  const created = [];
  for (let i = 0; i < count; i += 1) {
    const phone = `+1650557${String(offset + i).padStart(4, "0")}`;
    const { code } = await startVerification(db, phone);
    created.push(await checkVerification(db, phone, code!, "ios", "Fanout iPhone", `Member ${i}`));
  }
  return created;
}

/** A group of `size` members. Past the first three, members are inserted directly: group-add
 * budgets (100 per hour) exist to stop abuse, not to shape a fan-out measurement. */
async function groupOf(size: number) {
  const members = await accounts(size);
  const [owner, ...rest] = members;
  const groupId = crypto.randomUUID();
  await createGroup(db, {
    creatorAccountId: owner.accountId, creatorDeviceId: owner.deviceId,
    groupId, title: `Group of ${size}`, memberIds: rest.slice(0, 2).map((member) => member.accountId),
  });
  for (const member of rest.slice(2)) {
    await db`
      INSERT INTO dialog_members (dialog_id, account_id, role, invited_by)
      VALUES (${groupId}, ${member.accountId}, 'member', ${owner.accountId})`;
  }
  const active = await db`
    SELECT count(*)::int AS count FROM dialog_members WHERE dialog_id = ${groupId} AND left_at IS NULL`;
  expect(active[0].count).toBe(size);
  return { owner, groupId, members };
}

describe("group fan-out", () => {
  beforeEach(resetDb);

  test("a group event costs the same statements at 2 and 200 members", async () => {
    const measured: Record<number, { fanout: number; send: number }> = {};
    for (const size of [2, 200]) {
      await resetDb();
      const { owner, groupId, members } = await groupOf(size);
      // Warm per-process caches so both sizes measure the steady state.
      await sendMessage(db, {
        senderAccountId: owner.accountId, senderDeviceId: owner.deviceId,
        dialogId: groupId, clientMsgId: crypto.randomUUID(), body: "warm-up",
      });

      await db.begin(async (tx) => {
        const counted = countStatements(tx);
        const pushes = await fanoutDialogEvent(counted.sql, {
          dialogId: groupId, type: "message.new", actorAccountId: owner.accountId,
          unarchiveOnIncomingMessage: true, useDialogPreferences: true,
        });
        expect(pushes).toHaveLength(size);
        measured[size] = { fanout: counted.calls(), send: 0 };
      });

      const send = countStatements(db);
      await sendMessage(send.sql, {
        senderAccountId: owner.accountId, senderDeviceId: owner.deviceId,
        dialogId: groupId, clientMsgId: crypto.randomUUID(), body: "measured",
      });
      measured[size].send = send.calls();

      // Every member got exactly one event per fan-out, at consecutive pts.
      const perMember = await db`
        SELECT account_id, count(*)::int AS events, (max(pts) - min(pts) + 1)::int AS span
        FROM account_events WHERE dialog_id = ${groupId} AND type = 'message.new'
        GROUP BY account_id`;
      expect(perMember).toHaveLength(members.length);
      for (const row of perMember) {
        expect(row.events).toBe(3);
        expect(row.span).toBe(3);
      }
    }
    // Unarchive, recipient select, the lock-bump-insert statement, and push rows.
    expect(measured[2].fanout).toBe(4);
    expect(measured[200].fanout).toBe(4);
    expect(measured[200].send).toBe(measured[2].send);
  }, 60_000);

  test("64 overlapping group sends on shared members never deadlock", async () => {
    // 16 people in 8 groups of 10, each group a different rotation of the same people, so every
    // pair of groups shares members and their fan-outs contend for the same sync-state rows.
    const people = await accounts(16);
    const groups: { groupId: string; memberIndexes: number[] }[] = [];
    for (let g = 0; g < 8; g += 1) {
      const memberIndexes = Array.from({ length: 10 }, (_, i) => (g * 3 + i * 5) % 16)
        .filter((value, index, all) => all.indexOf(value) === index);
      const [ownerIndex, ...rest] = memberIndexes;
      const groupId = crypto.randomUUID();
      await createGroup(db, {
        creatorAccountId: people[ownerIndex].accountId, creatorDeviceId: people[ownerIndex].deviceId,
        groupId, title: `Overlap ${g}`, memberIds: rest.map((index) => people[index].accountId),
      });
      groups.push({ groupId, memberIndexes });
    }

    // A pool as wide as the burst, so all 64 transactions are open at once rather than queued.
    const wide = new SQL(TEST_URL, { max: 64 });
    const deadlocksBefore = Number((await db`
      SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()`)[0].deadlocks);
    const expected = new Map<string, number>();
    try {
      const sends = Array.from({ length: 64 }, (_, i) => {
        const group = groups[i % groups.length];
        const sender = people[group.memberIndexes[(i * 7) % group.memberIndexes.length]];
        for (const index of group.memberIndexes) {
          const id = people[index].accountId;
          expected.set(id, (expected.get(id) ?? 0) + 1);
        }
        return sendMessage(wide, {
          senderAccountId: sender.accountId, senderDeviceId: sender.deviceId,
          dialogId: group.groupId, clientMsgId: crypto.randomUUID(), body: `overlap ${i}`,
        });
      });
      const settled = await Promise.allSettled(sends);
      const failures = settled
        .filter((result): result is PromiseRejectedResult => result.status === "rejected")
        .map((result) => String(result.reason?.errno ?? result.reason?.code ?? result.reason));
      expect(failures).toEqual([]);
    } finally {
      await wide.close();
    }

    // Statistics are flushed when a backend goes idle, at most once a second.
    await Bun.sleep(1_200);
    await db`SELECT pg_stat_clear_snapshot()`;
    const deadlocksAfter = Number((await db`
      SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()`)[0].deadlocks);
    expect(deadlocksAfter - deadlocksBefore).toBe(0);

    // No lost or doubled update: each person's sync log is gapless and has one event per send.
    for (const [accountId, count] of expected) {
      const [row] = await db`
        SELECT count(*) FILTER (WHERE type = 'message.new')::int AS sends,
               count(*)::int AS events, min(pts)::int AS low, max(pts)::int AS high
        FROM account_events WHERE account_id = ${accountId}`;
      expect(row.sends).toBe(count);
      expect(row.high - row.low + 1).toBe(row.events);
      const [state] = await db`SELECT pts::int AS pts FROM account_sync_states WHERE account_id = ${accountId}`;
      expect(state.pts).toBe(row.high);
    }
  }, 60_000);
});
