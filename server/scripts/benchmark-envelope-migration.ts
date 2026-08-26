import { sql } from "../src/db";
import {
  ENVELOPE_MIGRATION_DOMAINS,
  migrateEnvelopeBatch,
  type EnvelopeMigrationDomain,
} from "../src/envelope-migration";

const args = process.argv.slice(2);
const domain = args[0] as EnvelopeMigrationDomain | undefined;
const option = (name: string, fallback: string): string =>
  args.find((value) => value.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;

async function main(): Promise<void> {
  if (process.env.TOJ_ALLOW_CRYPTO_BENCHMARK !== "1") {
    throw new Error("set TOJ_ALLOW_CRYPTO_BENCHMARK=1 for this mutating re-encryption benchmark");
  }
  if (!domain || !ENVELOPE_MIGRATION_DOMAINS.includes(domain)) {
    throw new Error(`domain must be one of: ${ENVELOPE_MIGRATION_DOMAINS.join(", ")}`);
  }
  const fromKeyId = option("from", "dev-v1");
  const batchSize = Number(option("batch", "100"));
  const maxBatches = Number(option("max-batches", "100"));
  if (!Number.isSafeInteger(batchSize) || batchSize < 1 || batchSize > 1_000) {
    throw new Error("--batch must be between 1 and 1000");
  }
  if (!Number.isSafeInteger(maxBatches) || maxBatches < 1 || maxBatches > 100_000) {
    throw new Error("--max-batches must be between 1 and 100000");
  }

  const startedLSN = String((await sql`SELECT pg_current_wal_lsn() AS lsn`)[0].lsn);
  const started = process.hrtime.bigint();
  let rowsMigrated = 0;
  let batches = 0;
  let remaining = 1;
  while (batches < maxBatches && remaining !== 0) {
    const result = await migrateEnvelopeBatch(sql, domain, { fromKeyId, batchSize });
    rowsMigrated += result.migrated;
    remaining = result.remaining;
    batches += 1;
    if (result.retryable) await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const elapsedSeconds = Number(process.hrtime.bigint() - started) / 1_000_000_000;
  const finished = (await sql`
    SELECT pg_current_wal_lsn() AS lsn,
      pg_wal_lsn_diff(pg_current_wal_lsn(), ${startedLSN}::pg_lsn) AS wal_bytes`)[0];
  console.log(JSON.stringify({
    domain,
    fromKeyId,
    batchSize,
    batches,
    rowsMigrated,
    remaining,
    elapsedSeconds,
    rowsPerSecond: elapsedSeconds > 0 ? rowsMigrated / elapsedSeconds : 0,
    walBytes: Number(finished.wal_bytes),
    startedLSN,
    finishedLSN: String(finished.lsn),
  }, null, 2));
}

try {
  await main();
} catch (error) {
  console.error((error instanceof Error ? error.message : String(error)).replace(/[\r\n]+/g, " "));
  process.exitCode = 1;
} finally {
  await sql.close();
}
