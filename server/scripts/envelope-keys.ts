import { sql } from "../src/db";
import {
  activateCryptoWriteMode,
  envelopeCrypto,
  envelopeReadiness,
  keyReferenceCount,
  retireDataKey,
  type KeyScope,
} from "../src/envelope-crypto";
import {
  ENVELOPE_MIGRATION_DOMAINS,
  envelopeMigrationStatus,
  migrateEnvelopeBatch,
  type EnvelopeMigrationDomain,
} from "../src/envelope-migration";
import { blindIndexDatabaseReadiness } from "../src/blind-index";
import { migratePhoneBlindIndexBatch } from "../src/blind-index-migration";

const args = process.argv.slice(2);
const command = args[0] ?? "status";

function option(name: string, fallback?: string): string | undefined {
  return args.find((value) => value.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
}

function scopeFromArguments(kind?: string, value?: string): KeyScope {
  if (kind === "account" && value) return { kind, accountId: value };
  if (kind === "service" && value) return { kind, serviceName: value };
  throw new Error("scope must be: account <account-uuid> or service <service-name>");
}

function domainFromArgument(value: string | undefined): EnvelopeMigrationDomain {
  if (!value || !ENVELOPE_MIGRATION_DOMAINS.includes(value as EnvelopeMigrationDomain)) {
    throw new Error(`domain must be one of: ${ENVELOPE_MIGRATION_DOMAINS.join(", ")}`);
  }
  return value as EnvelopeMigrationDomain;
}

async function migrateDomain(domain: EnvelopeMigrationDomain): Promise<void> {
  const fromKeyId = option("from", "dev-v1")!;
  const batchSize = Number(option("batch", "100"));
  const once = args.includes("--once");
  if (!Number.isSafeInteger(batchSize) || batchSize < 1 || batchSize > 1_000) {
    throw new Error("--batch must be between 1 and 1000");
  }
  do {
    const result = await migrateEnvelopeBatch(sql, domain, { fromKeyId, batchSize });
    console.log(JSON.stringify(result));
    if (once || result.remaining === 0) break;
    if (result.retryable) await new Promise((resolve) => setTimeout(resolve, 50));
  } while (true);
}

async function main(): Promise<void> {
  switch (command) {
  case "status":
    console.log(JSON.stringify({
      envelope: await envelopeReadiness(sql),
      blindIndexes: await blindIndexDatabaseReadiness(sql),
      migrations: await envelopeMigrationStatus(sql),
    }, null, 2));
    break;
  case "rotate":
    console.log(JSON.stringify(await envelopeCrypto(sql).rotate(
      scopeFromArguments(args[1], args[2]),
    ), null, 2));
    break;
  case "rewrap": {
    const keyId = args[1];
    if (!keyId) throw new Error("rewrap requires a data-key UUID");
    await envelopeCrypto(sql).rewrap(keyId);
    console.log(JSON.stringify({ keyId, rewrapped: true }));
    break;
  }
  case "activate-mode": {
    const mode = args[1];
    if (mode !== "legacy" && mode !== "envelope-canary" && mode !== "envelope") {
      throw new Error("activate-mode requires legacy, envelope-canary, or envelope");
    }
    if (process.env.TOJ_CONFIRM_CRYPTO_WRITE_MODE !== mode) {
      throw new Error(`set TOJ_CONFIRM_CRYPTO_WRITE_MODE=${mode} to confirm the database writer fence`);
    }
    console.log(JSON.stringify(await activateCryptoWriteMode(sql, mode), null, 2));
    break;
  }
  case "audit": {
    const keyId = args[1];
    if (!keyId) throw new Error("audit requires a data-key UUID");
    console.log(JSON.stringify({ keyId, references: await keyReferenceCount(sql, keyId) }, null, 2));
    break;
  }
  case "retire": {
    const keyId = args[1];
    if (!keyId) throw new Error("retire requires a data-key UUID");
    if (process.env.TOJ_CONFIRM_RETIRE_KEY !== keyId) {
      throw new Error(`set TOJ_CONFIRM_RETIRE_KEY=${keyId} after reference and backup-retention audits`);
    }
    const result = await retireDataKey(sql, keyId);
    console.log(JSON.stringify({
      ...result,
      retired: result.state === "retired",
      nextAction: result.state === "draining"
        ? `rerun retire after ${result.finalizeAfter}; wrapped key material has not been erased`
        : null,
    }));
    break;
  }
  case "migrate": {
    if (args[1] === "all") {
      for (const domain of ENVELOPE_MIGRATION_DOMAINS) await migrateDomain(domain);
    } else {
      await migrateDomain(domainFromArgument(args[1]));
    }
    break;
  }
  case "migrate-blind": {
    if (args[1] !== "phones") throw new Error("migrate-blind currently requires phones");
    const batchSize = Number(option("batch", "100"));
    const once = args.includes("--once");
    const fromKeyId = option("from", "legacy-v1")!;
    if (!Number.isSafeInteger(batchSize) || batchSize < 1 || batchSize > 1_000) {
      throw new Error("--batch must be between 1 and 1000");
    }
    do {
      const result = await migratePhoneBlindIndexBatch(sql, batchSize, fromKeyId);
      console.log(JSON.stringify(result));
      if (once || !result.hasMore) break;
    } while (true);
    break;
  }
  default:
    throw new Error(
      "usage: bun run crypto:keys -- status | rotate account <uuid> | rotate service <name> | "
      + "rewrap <key-uuid> | activate-mode <legacy|envelope-canary|envelope> | "
      + "audit <key-uuid> | retire <key-uuid> | "
      + "migrate <domain|all> [--from=key-id] [--batch=100] [--once] | "
      + "migrate-blind phones [--from=legacy-v1] [--batch=100] [--once]",
    );
  }
}

try {
  await main();
} catch (error) {
  console.error((error instanceof Error ? error.message : String(error)).replace(/[\r\n]+/g, " "));
  process.exitCode = 1;
} finally {
  await sql.close();
}
