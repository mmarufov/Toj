// Negative controls: prove each test can fail.
//
//   bun run scripts/negative-controls.ts            # every control
//   bun run scripts/negative-controls.ts N3 N7      # selected controls
//
// For each control the script checks out HEAD into a temporary worktree, runs the named tests
// unmodified (they must pass), then applies one mutation that restores an earlier behaviour and
// runs them again (they must fail). A control whose mutated run still passes means the test could
// not have caught the regression it claims to pin, and the script exits non-zero.
//
// Needs a local PostgreSQL that `createdb` can reach. Uses two throwaway databases and drops them.
import { $ } from "bun";
import { mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

type Control = {
  id: string;
  claim: string;
  mutation: string;
  file: string;
  find: string;
  replace: string;
  /** Additional replacements applied together with the first. */
  also?: { file: string; find: string; replace: string }[];
  test: string;
  pattern: string;
  /** Concurrency controls may need several runs to surface; any failing run counts. */
  runs?: number;
};

export const CONTROLS: Control[] = [
  {
    id: "N1",
    claim: "legacy bearer tokens expire at the idle and absolute session bounds",
    mutation: "drop the expiry check from resolveDevice",
    file: "src/auth.ts",
    find: `  if (legacyTokenExpired(rows[0], now)) {
    throw new AuthError("session expired", 401, undefined, "session_expired");
  }
`,
    replace: "",
    test: "src/auth-security.test.ts",
    pattern: "legacy token is honoured inside the idle bound",
  },
  {
    id: "N2",
    claim: "a v2 server refuses to mint legacy credentials",
    mutation: "remove the 426 branch from /v1/auth/check",
    file: "src/cloud.ts",
    find: `          } else if (authSessionsV2Configured()) {`,
    replace: `          } else if (false) {`,
    test: "src/auth-security.test.ts",
    pattern: "v2 server refuses to mint legacy credentials",
  },
  {
    id: "N3",
    claim: "a lost upgrade response is replayed",
    mutation: "answer a retired legacy token with 401",
    file: "src/session-security.ts",
    find: `    if (!device) return await replayLegacyUpgrade(tx, candidates, now);`,
    replace: `    if (!device) return new AuthError("invalid device token", 401, undefined, "device_revoked");`,
    test: "src/auth-security.test.ts",
    pattern: "upgrade whose response was lost is replayed",
  },
  {
    id: "N4",
    claim: "the per-network window keys on the edge-set client address",
    mutation: "key on the leftmost X-Forwarded-For entry, else the peer",
    file: "src/cloud.ts",
    find: `  const header = env.TOJ_CLIENT_IP_HEADER?.trim().toLowerCase();`,
    replace: `  return env.TOJ_TRUST_PROXY === "1"
    ? headers.get("x-forwarded-for")?.split(",")[0]?.trim() || peer
    : peer;
  const header = env.TOJ_CLIENT_IP_HEADER?.trim().toLowerCase();`,
    test: "src/client-address.test.ts",
    pattern: ".",
  },
  {
    id: "N5",
    claim: "a late retry can never re-run a message mutation",
    mutation: "delete message receipts after 24 hours instead of tombstoning them",
    file: "src/ops.ts",
    find: `    UPDATE message_mutation_requests request
    SET result_expired_at = now(), fingerprint = NULL,
      fingerprint_key_id = \${EXPIRED_BLIND_INDEX_KEY_ID}
    FROM doomed
    WHERE request.actor_account_id`,
    replace: `    DELETE FROM message_mutation_requests request
    USING doomed
    WHERE request.actor_account_id`,
    test: "src/m3.test.ts",
    pattern: "late mutation retries",
  },
  {
    id: "N5g",
    claim: "a late retry can never re-run a group mutation",
    mutation: "delete group receipts after 24 hours instead of tombstoning them",
    file: "src/ops.ts",
    find: `    UPDATE group_mutation_requests request SET result_expired_at = now()
    FROM doomed
    WHERE request.actor_account_id`,
    replace: `    DELETE FROM group_mutation_requests request
    USING doomed
    WHERE request.actor_account_id`,
    test: "src/groups.test.ts",
    pattern: "retry inside the window replays",
  },
  {
    id: "N6",
    claim: "a message mutation id reused with different input is a 409 conflict",
    mutation: "stop comparing the stored fingerprint",
    file: "src/sync.ts",
    find: `  if (sameInput && existing.fingerprint != null) {`,
    replace: `  if (false) {`,
    test: "src/m3.test.ts",
    pattern: "mutation id reused with different input",
  },
  {
    id: "N7",
    claim: "64 overlapping group sends on shared members never deadlock",
    mutation: "lock recipient sync states in random order instead of account-UUID order",
    file: "src/fanout.ts",
    find: `      WHERE account_id = ANY(\${sql.array(accountIds, "uuid")}::uuid[])
      ORDER BY account_id
      FOR NO KEY UPDATE`,
    replace: `      WHERE account_id = ANY(\${sql.array(accountIds, "uuid")}::uuid[])
      ORDER BY random()
      FOR NO KEY UPDATE`,
    test: "src/fanout.test.ts",
    pattern: "64 overlapping group sends",
    runs: 3,
  },
  {
    id: "N8",
    claim: "a group send costs the same statements at 2 and 200 members",
    mutation: "send one pg_notify per recipient",
    file: "src/sync-wakeup.ts",
    find: `  await sql\`
    SELECT pg_notify(\${SYNC_NOTIFY_CHANNEL}, wakeup.payload)
    FROM unnest(\${sql.array(payloads, "text")}::text[]) WITH ORDINALITY AS wakeup(payload, position)
    ORDER BY wakeup.position\`;`,
    replace: `  for (const payload of payloads) await sql\`SELECT pg_notify(\${SYNC_NOTIFY_CHANNEL}, \${payload})\`;`,
    test: "src/fanout.test.ts",
    pattern: "same statements at 2 and 200 members",
  },
  {
    id: "N9",
    claim: "the fan-out itself is 4 statements at any group size",
    mutation: "lock each recipient with its own statement",
    file: "src/fanout.ts",
    find: `  const accountIds = selected.map((row: any) => String(row.account_id));
`,
    replace: `  const accountIds = selected.map((row: any) => String(row.account_id));
  for (const id of accountIds) {
    await sql\`SELECT 1 FROM account_sync_states WHERE account_id = \${id} FOR NO KEY UPDATE\`;
  }
`,
    test: "src/fanout.test.ts",
    pattern: "same statements at 2 and 200 members",
  },
  {
    id: "N10",
    claim: "50 concurrent identical sends produce one message and one answer",
    mutation: "disable both idempotency layers (the send_requests claim and recoverCanonical)",
    file: "src/sync.ts",
    find: `      ON CONFLICT (sender_account_id, client_msg_id) DO NOTHING RETURNING status\`;
    if (claim.length === 0) {`,
    replace: `      ON CONFLICT (sender_account_id, client_msg_id) DO NOTHING RETURNING status\`;
    if (false) {`,
    also: [{
      file: "src/sync.ts",
      find: `    // message. Rebuild the receipt before touching counters so a very late retry stays idempotent.
    const recovered = await recoverCanonical();`,
      replace: `    // message. Rebuild the receipt before touching counters so a very late retry stays idempotent.
    const recovered = null as any;`,
    }],
    test: "src/m3.test.ts",
    pattern: "50 concurrent sends with the same client_msg_id",
  },
  {
    id: "N11",
    claim: "/ready fails closed when the receipt columns are missing",
    mutation: "leave the mutation-receipt check out of the overall status",
    file: "src/ops.ts",
    find: `presence.ready && profilePhotos.ready && mutationReceipts.ready`,
    replace: `presence.ready && profilePhotos.ready`,
    test: "src/m3.test.ts",
    pattern: "readiness fails closed on mutation-receipt",
  },
  {
    id: "N12",
    claim: "refresh-rotation receipts replay after any delay (PR #38)",
    mutation: "restore the read predicate PR #38 removed, receipt.expires_at > now",
    file: "src/session-security.ts",
    find: `          AND receipt.request_token_digest_key_id = \${used.token_digest_key_id}\`)[0];`,
    replace: `          AND receipt.request_token_digest_key_id = \${used.token_digest_key_id}
          AND receipt.expires_at > \${now}\`)[0];`,
    test: "src/auth-security.test.ts",
    pattern: "age decides neither replay nor pruning",
  },
];

type RunResult = { pass: number; fail: number; output: string };

async function runTests(serverDir: string, env: Record<string, string>, test: string, pattern: string): Promise<RunResult> {
  const result = await $`bun test --timeout 15000 ${test} -t ${pattern}`
    .cwd(serverDir).env({ ...process.env, ...env }).nothrow().quiet();
  const output = result.stdout.toString() + result.stderr.toString();
  const count = (label: string) => Number(output.match(new RegExp(`^\\s*(\\d+) ${label}`, "m"))?.[1] ?? 0);
  return { pass: count("pass"), fail: count("fail"), output };
}

function mutate(serverDir: string, file: string, find: string, replace: string): () => void {
  const path = join(serverDir, file);
  const original = readFileSync(path, "utf8");
  const occurrences = original.split(find).length - 1;
  if (occurrences !== 1) throw new Error(`${file}: expected the mutation anchor once, found ${occurrences}`);
  writeFileSync(path, original.replace(find, replace));
  return () => writeFileSync(path, original);
}

if (import.meta.main) {
  const selected = process.argv.slice(2);
  const controls = selected.length ? CONTROLS.filter((control) => selected.includes(control.id)) : CONTROLS;
  const root = (await $`git rev-parse --show-toplevel`.text()).trim();
  const sha = (await $`git rev-parse HEAD`.text()).trim();
  const worktree = mkdtempSync(join(tmpdir(), "toj-negative-controls-"));
  const suffix = `${process.pid}`;
  const dev = `toj_negctl_dev_${suffix}`;
  const testDb = `toj_negctl_test_${suffix}`;
  const env = {
    DATABASE_URL: `postgres://localhost:5432/${dev}`,
    TEST_DATABASE_URL: `postgres://localhost:5432/${testDb}`,
  };
  let failed = false;
  try {
    await $`git worktree add --detach ${worktree} ${sha}`.cwd(root).quiet();
    const serverDir = join(worktree, "server");
    symlinkSync(join(root, "server", "node_modules"), join(serverDir, "node_modules"));
    await $`createdb ${dev}`.quiet();
    await $`createdb ${testDb}`.quiet();
    await $`bun run src/migrate.ts`.cwd(serverDir).env({ ...process.env, DATABASE_URL: env.DATABASE_URL }).quiet();
    await $`bun run src/migrate.ts`.cwd(serverDir).env({ ...process.env, DATABASE_URL: env.TEST_DATABASE_URL }).quiet();

    console.log(`negative controls at ${sha}`);
    console.log("| id | claim | unmutated | mutated (failing runs / runs) | verdict |");
    console.log("|---|---|---|---|---|");
    for (const control of controls) {
      const baseline = await runTests(serverDir, env, control.test, control.pattern);
      const restorers = [
        mutate(serverDir, control.file, control.find, control.replace),
        ...(control.also ?? []).map((extra) => mutate(serverDir, extra.file, extra.find, extra.replace)),
      ];
      const runs = control.runs ?? 1;
      let failingRuns = 0;
      let firstFailure = "";
      try {
        for (let run = 0; run < runs; run += 1) {
          const mutated = await runTests(serverDir, env, control.test, control.pattern);
          if (mutated.fail > 0) {
            failingRuns += 1;
            firstFailure ||= mutated.output.split("\n")
              .find((line) => /error:|Expected|Received|\(fail\)/.test(line))?.trim() ?? "";
          }
        }
      } finally {
        for (const restore of restorers.reverse()) restore();
      }
      const ok = baseline.pass > 0 && baseline.fail === 0 && failingRuns > 0;
      failed ||= !ok;
      console.log(`| ${control.id} | ${control.claim} | ${baseline.pass} pass, ${baseline.fail} fail | ${failingRuns}/${runs} | ${ok ? "caught" : "NOT CAUGHT"} |`);
      if (firstFailure) console.log(`|  | mutation: ${control.mutation}; first failure: \`${firstFailure.replaceAll("|", "/").slice(0, 140)}\` | | | |`);
    }
  } finally {
    await $`git worktree remove --force ${worktree}`.cwd(root).nothrow().quiet();
    rmSync(worktree, { recursive: true, force: true });
    await $`dropdb --if-exists ${dev}`.nothrow().quiet();
    await $`dropdb --if-exists ${testDb}`.nothrow().quiet();
  }
  if (failed) process.exit(1);
}
