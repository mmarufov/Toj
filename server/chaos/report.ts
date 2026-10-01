// Renders the tables in docs/results/sync-chaos.md from the JSON that chaos/run.ts writes, so no
// number in the results file is copied by hand.
//
//   bun run chaos/report.ts ../docs/results/sync-chaos-after.json [../docs/results/sync-chaos-before.json]

import { readFileSync } from "node:fs";

type Summary = {
  scenario: string; runs: number; messages: number; lost: number; serverDuplicates: number;
  deviceMismatches: number; ptsMismatches: number; conflictingEchoes: number;
  redeliveredUpdates: number; runsWithRedelivery: number; sendAttempts: number;
  sendFailures: number; duplicateAcks: number; lateFailuresAfterEcho: number;
  syncFailures: number; wsConnects: number; fatalErrors: number; unconverged: number;
  convergenceP50Ms: number | null; convergenceP99Ms: number | null;
  convergenceMaxMs: number | null; sendPhaseP50Ms: number | null;
};

type Report = {
  environment: { label: string; date: string; gitSha: string; gitDirty: boolean; machine: string;
    bun: string; postgres: string; toxiproxy: string; command: string };
  summary: Summary[];
};

const load = (path: string): Report => JSON.parse(readFileSync(path, "utf8"));
const seconds = (ms: number | null) => (ms == null ? "n/a" : (ms / 1000).toFixed(2));
const count = (n: number) => n.toLocaleString("en-US");

// Toxiproxy's /version returns JSON on 2.x ({"version": "2.12.0"}) and plain text on older builds.
function toxiproxyVersion(raw: string): string {
  try {
    return String((JSON.parse(raw) as { version?: unknown }).version ?? raw);
  } catch {
    return raw;
  }
}

function environment(report: Report): string {
  const e = report.environment;
  return [
    `- Label: \`${e.label}\``,
    `- Git SHA: \`${e.gitSha}\`${e.gitDirty ? " (working tree differs from this SHA; see notes)" : ""}`,
    `- Date: ${e.date}`,
    `- Machine: ${e.machine}`,
    `- Bun ${e.bun}; ${e.postgres.split(",")[0]}; Toxiproxy ${toxiproxyVersion(e.toxiproxy)}`,
    `- Command (from \`server/\`): \`${e.command}\``,
  ].join("\n");
}

function correctness(report: Report): string {
  const rows = report.summary.map((s) => `| ${s.scenario} | ${s.runs} | ${count(s.messages)} | ${s.lost} | `
    + `${s.serverDuplicates} | ${s.conflictingEchoes} | ${s.deviceMismatches} | ${s.ptsMismatches} | `
    + `${s.unconverged} | ${s.fatalErrors} |`);
  return [
    "| Scenario | Runs | Messages | Lost | Server duplicates | Conflicting echoes | Device mismatches | pts mismatches | Unconverged runs | Fatal errors |",
    "|---|---|---|---|---|---|---|---|---|---|",
    ...rows,
  ].join("\n");
}

function timing(report: Report): string {
  const rows = report.summary.map((s) => `| ${s.scenario} | ${seconds(s.convergenceP50Ms)} | `
    + `${seconds(s.convergenceP99Ms)} | ${seconds(s.sendPhaseP50Ms)} |`);
  return [
    "| Scenario | Convergence p50 (s) | Convergence p99 = max of 20 (s) | Send phase p50 (s) |",
    "|---|---|---|---|",
    ...rows,
  ].join("\n");
}

function faults(report: Report): string {
  const rows = report.summary.map((s) => `| ${s.scenario} | ${count(s.sendAttempts)} | `
    + `${count(s.sendFailures)} | ${count(s.duplicateAcks)} | ${count(s.lateFailuresAfterEcho)} | `
    + `${count(s.syncFailures)} | ${count(s.wsConnects)} |`);
  return [
    "| Scenario | Send attempts | Failed attempts | Replies lost after commit (`duplicate: true`) | Failed after echo | Failed catch-up calls | WebSocket connects |",
    "|---|---|---|---|---|---|---|",
    ...rows,
  ].join("\n");
}

function redelivery(after: Report, before: Report | null): string {
  const byName = new Map(before?.summary.map((s) => [s.scenario, s]) ?? []);
  const rows = after.summary.map((s) => {
    const b = byName.get(s.scenario);
    const beforeCell = b ? `${count(b.redeliveredUpdates)} (${b.runsWithRedelivery} of ${b.runs} runs)` : "n/a";
    return `| ${s.scenario} | ${beforeCell} | ${count(s.redeliveredUpdates)} (${s.runsWithRedelivery} of ${s.runs} runs) |`;
  });
  return [
    "| Scenario | Re-delivered updates before the fix | After the fix |",
    "|---|---|---|",
    ...rows,
  ].join("\n");
}

const [afterPath, beforePath] = process.argv.slice(2);
if (!afterPath) throw new Error("usage: chaos/report.ts after.json [before.json]");
const after = load(afterPath);
const before = beforePath ? load(beforePath) : null;
const sections = [
  "### After the fix: environment", environment(after),
  "### Correctness", correctness(after),
  "### Convergence", timing(after),
  "### Faults the clients hit", faults(after),
  "### Re-delivery before and after the `getDifference` fix", redelivery(after, before),
];
if (before) {
  sections.push("### Before the fix: environment", environment(before),
    "### Before the fix: correctness", correctness(before),
    "### Before the fix: convergence", timing(before));
}
console.log(sections.join("\n\n"));
