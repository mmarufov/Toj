// Counts the SQL statements one message send issues, at 2 and 200 active dialog members.
//
//   DATABASE_URL=postgres://localhost:5432/<empty, migrated db> bun run scripts/measure-fanout-statements.ts
//
// The script deliberately uses only APIs that existed before group chats (0df5aa9, #19), so the
// same file (plus src/statement-count.ts) can be copied into a checkout of 0df5aa9^ to measure the
// per-member loop it replaced.
// Groups did not exist then, so on both trees the extra members are rows inserted straight into
// dialog_members of a direct dialog: identical setup, and each tree fans out to every active member.
// It TRUNCATEs accounts; never point it at a database whose contents matter.
import type { SQL } from "bun";
import { makeSql } from "../src/db";
import { checkVerification, startVerification } from "../src/auth";
import { getOrCreateDirectDialog, sendMessage } from "../src/sync";
import { countStatements } from "../src/statement-count";

function phone(index: number): string {
  return `+1650556${String(index).padStart(4, "0")}`;
}

async function measure(db: SQL, members: number): Promise<number> {
  await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
  const accounts = [];
  for (let i = 0; i < members; i += 1) {
    const { code } = await startVerification(db, phone(i));
    accounts.push(await checkVerification(db, phone(i), code!, "ios", "Bench iPhone", `Member ${i}`));
  }
  const [sender, peer] = accounts;
  const { dialogId } = await getOrCreateDirectDialog(db, sender.accountId, peer.accountId);
  for (const extra of accounts.slice(2)) {
    await db`INSERT INTO dialog_members (dialog_id, account_id) VALUES (${dialogId}, ${extra.accountId})`;
  }
  const active = Number((await db`
    SELECT count(*)::int AS count FROM dialog_members WHERE dialog_id = ${dialogId} AND left_at IS NULL`)[0].count);
  if (active !== members) throw new Error(`expected ${members} active members, found ${active}`);

  // Warm caches (schema-readiness probes, key material) so the measured send is the steady state.
  await sendMessage(db, {
    senderAccountId: sender.accountId, senderDeviceId: sender.deviceId, dialogId,
    clientMsgId: crypto.randomUUID(), body: "warm-up",
  });
  const counted = countStatements(db);
  await sendMessage(counted.sql, {
    senderAccountId: sender.accountId, senderDeviceId: sender.deviceId, dialogId,
    clientMsgId: crypto.randomUUID(), body: "measured",
  });
  const events = Number((await db`
    SELECT count(*)::int AS count FROM account_events WHERE dialog_id = ${dialogId} AND type = 'message.new'`)[0].count);
  if (events !== members * 2) throw new Error(`expected ${members * 2} message.new events, found ${events}`);
  return counted.calls();
}

if (import.meta.main) {
  const db = makeSql();
  try {
    const small = await measure(db, 2);
    const large = await measure(db, 200);
    console.log(JSON.stringify({
      statementsPerSend: { members2: small, members200: large },
      perAdditionalMember: (large - small) / 198,
    }));
  } finally {
    await db.close();
  }
}
