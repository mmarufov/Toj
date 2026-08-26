import { sql } from "../src/db";
import {
  claimAbuseReport,
  escalateAbuseReport,
  listAbuseReports,
  ReportError,
  resolveAbuseReport,
  viewAbuseReport,
  type ModerationResolution,
} from "../src/reports";

const [command = "list", reportId, ...options] = process.argv.slice(2);
const operatorId = process.env.TOJ_MODERATION_OPERATOR_ID?.trim() ?? "";
const redactedJSON = options.includes("--redacted-json") || process.argv.includes("--redacted-json");

async function stdinNote(): Promise<string | null> {
  if (process.stdin.isTTY) return null;
  let value = "";
  for await (const chunk of process.stdin) value += String(chunk);
  const note = value.trim();
  return note || null;
}

function requireReportId(): string {
  if (!reportId) throw new Error("report id required");
  return reportId;
}

function requireOperator(): string {
  if (!operatorId) throw new Error("TOJ_MODERATION_OPERATOR_ID is required");
  return operatorId;
}

function requireDestructiveConfirmation(id: string): void {
  if (process.env.TOJ_MODERATION_DESTRUCTIVE_CONFIRM !== id) {
    throw new Error(`set TOJ_MODERATION_DESTRUCTIVE_CONFIRM=${id} for this destructive action`);
  }
}

async function main(): Promise<void> {
  switch (command) {
  case "list": {
    const limitArg = process.argv.slice(2).find((value) => /^\d+$/.test(value));
    console.log(JSON.stringify(await listAbuseReports(
      sql, requireOperator(), Number(limitArg ?? 50),
    ), null, 2));
    break;
  }
  case "view": {
    const id = requireReportId();
    if (!process.stdout.isTTY && !redactedJSON) {
      throw new Error("refusing decrypted evidence on non-TTY output; pass --redacted-json for metadata only");
    }
    const report = await viewAbuseReport(sql, id, !redactedJSON, requireOperator());
    console.log(JSON.stringify(report, null, 2));
    break;
  }
  case "claim": {
    console.log(JSON.stringify(await claimAbuseReport(
      sql, requireReportId(), requireOperator(), await stdinNote(),
    ), null, 2));
    break;
  }
  case "resolve":
  case "dismiss":
  case "remove":
  case "ban": {
    const id = requireReportId();
    const resolution: ModerationResolution = command === "dismiss" ? "dismissed"
      : command === "remove" ? "content_removed"
      : command === "ban" ? "account_banned" : "resolved";
    if (resolution === "content_removed" || resolution === "account_banned") {
      requireDestructiveConfirmation(id);
    }
    console.log(JSON.stringify(await resolveAbuseReport(
      sql, id, requireOperator(), resolution, await stdinNote(),
    ), null, 2));
    break;
  }
  case "escalate": {
    console.log(JSON.stringify(await escalateAbuseReport(
      sql, requireReportId(), requireOperator(), await stdinNote(),
    ), null, 2));
    break;
  }
  default:
    throw new Error(
      "usage: bun run moderation:reports -- list [limit] | view <id> [--redacted-json] | "
      + "claim|resolve|dismiss|remove|ban|escalate <id>",
    );
  }
}

try {
  await main();
} catch (error) {
  const message = error instanceof ReportError
    ? `${error.code}: ${error.message}`
    : error instanceof Error ? error.message : String(error);
  console.error(message.replace(/[\r\n]+/g, " "));
  process.exitCode = 1;
} finally {
  await sql.close();
}
