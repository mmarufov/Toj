// Sync chaos harness: 4 headless clients (2 accounts x 2 devices) exchange messages in one direct
// dialog through Toxiproxy while it injects faults, then every device must converge to the
// server's state. Pre-registered design: docs/results/sync-chaos-preregistration.md.
//
//   DATABASE_URL=postgres://localhost:5432/toj_chaos bun run chaos/run.ts --runs 20 --out out.json
//
// It refuses any database that is not on this machine: this harness truncates tables.

import { execSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import os from "node:os";
import { SyncClient, sha256, stateDigest } from "./sync-client";

type Toxic = {
  name: string;
  type: string;
  stream: "upstream" | "downstream";
  toxicity?: number;
  attributes: Record<string, number>;
};

type Scenario = {
  name: string;
  description: string;
  /** Toxics present for the whole send and convergence phase. */
  toxics: Toxic[];
  /**
   * Toxics added for `onMs` out of every `everyMs`, starting immediately. reset_peer only acts on a
   * link that carries data while it is present, so an idle keep-alive link survives a pulse.
   */
  pulse?: { toxics: Toxic[]; everyMs: number; onMs: number };
};

// Full-sweep toxics. `--mild` swaps in the CI smoke values below.
const SCENARIOS: Scenario[] = [
  { name: "clean", description: "no toxics", toxics: [] },
  {
    name: "3g",
    description: "300 ms +/- 200 ms downstream latency, 40 KB/s each way",
    toxics: [
      { name: "latency", type: "latency", stream: "downstream", attributes: { latency: 300, jitter: 200 } },
      { name: "bw_down", type: "bandwidth", stream: "downstream", attributes: { rate: 40 } },
      { name: "bw_up", type: "bandwidth", stream: "upstream", attributes: { rate: 40 } },
    ],
  },
  {
    name: "resets",
    description: "reset_peer both ways for 200 ms out of every 1 s: any link carrying data then is reset",
    toxics: [],
    pulse: {
      everyMs: 1_000,
      onMs: 200,
      toxics: [
        { name: "reset_up", type: "reset_peer", stream: "upstream", attributes: { timeout: 0 } },
        { name: "reset_down", type: "reset_peer", stream: "downstream", attributes: { timeout: 0 } },
      ],
    },
  },
  {
    name: "reply_dropped",
    description: "20% of connections: requests reach the server, replies are dropped, link closed after 1 s",
    toxics: [
      { name: "drop_reply", type: "timeout", stream: "downstream", toxicity: 0.2, attributes: { timeout: 1_000 } },
    ],
  },
  {
    name: "reply_cut",
    description: "20% of connections: closed after 300 downstream bytes, mid-response",
    toxics: [
      { name: "cut_reply", type: "limit_data", stream: "downstream", toxicity: 0.2, attributes: { bytes: 300 } },
    ],
  },
];

const MILD: Record<string, Partial<Scenario>> = {
  "3g": {
    toxics: [
      { name: "latency", type: "latency", stream: "downstream", attributes: { latency: 50, jitter: 25 } },
    ],
  },
  resets: {
    pulse: {
      everyMs: 1_000,
      onMs: 50,
      toxics: [{ name: "reset_up", type: "reset_peer", stream: "upstream", attributes: { timeout: 0 } }],
    },
  },
  reply_dropped: {
    toxics: [
      { name: "drop_reply", type: "timeout", stream: "downstream", toxicity: 0.05, attributes: { timeout: 500 } },
    ],
  },
  reply_cut: {
    toxics: [
      { name: "cut_reply", type: "limit_data", stream: "downstream", toxicity: 0.05, attributes: { bytes: 300 } },
    ],
  },
};

type Options = {
  runs: number;
  messages: number;
  scenarios: string[];
  out: string | null;
  toxiproxy: string;
  upstreamHost: string;
  proxyPort: number;
  convergeTimeoutMs: number;
  mild: boolean;
  label: string;
};

function parseOptions(argv: string[]): Options {
  const value = (flag: string): string | undefined => {
    const index = argv.indexOf(flag);
    return index >= 0 ? argv[index + 1] : undefined;
  };
  return {
    runs: Number(value("--runs") ?? 20),
    messages: Number(value("--messages") ?? 500),
    scenarios: (value("--scenarios") ?? SCENARIOS.map((s) => s.name).join(",")).split(","),
    out: value("--out") ?? null,
    toxiproxy: value("--toxiproxy") ?? process.env.TOXIPROXY_URL ?? "http://127.0.0.1:8474",
    upstreamHost: value("--upstream-host") ?? process.env.TOXIPROXY_UPSTREAM_HOST ?? "127.0.0.1",
    proxyPort: Number(value("--proxy-port") ?? 26_100),
    convergeTimeoutMs: Number(value("--converge-timeout-ms") ?? 180_000),
    mild: argv.includes("--mild"),
    label: value("--label") ?? "",
  };
}

function requireLocalDatabase(): string {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is required and must name a disposable local database");
  const host = new URL(url).hostname;
  if (!["localhost", "127.0.0.1", "::1"].includes(host)) {
    throw new Error(`refusing non-local database host ${host}: this harness truncates tables`);
  }
  if (process.env.NODE_ENV === "production" || process.env.NODE_ENV === "staging") {
    throw new Error("refusing to run with a hosted NODE_ENV");
  }
  return url;
}

class Toxiproxy {
  constructor(private readonly base: string) {}

  private async call(method: string, path: string, body?: unknown): Promise<unknown> {
    const response = await fetch(`${this.base}${path}`, {
      method,
      headers: body ? { "content-type": "application/json" } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    });
    if (!response.ok && !(method === "DELETE" && response.status === 404)) {
      throw new Error(`toxiproxy ${method} ${path}: ${response.status} ${await response.text()}`);
    }
    const text = await response.text();
    return text ? JSON.parse(text) : null;
  }

  async version(): Promise<string> {
    const response = await fetch(`${this.base}/version`);
    return (await response.text()).trim();
  }

  /** Recreating the proxy drops every link, so no connection survives into the next run. */
  async recreate(name: string, listen: string, upstream: string): Promise<void> {
    await this.call("DELETE", `/proxies/${name}`);
    await this.call("POST", "/proxies", { name, listen, upstream, enabled: true });
  }

  async addToxic(proxy: string, toxic: Toxic): Promise<void> {
    await this.call("POST", `/proxies/${proxy}/toxics`, {
      name: toxic.name, type: toxic.type, stream: toxic.stream,
      toxicity: toxic.toxicity ?? 1, attributes: toxic.attributes,
    });
  }

  async removeToxic(proxy: string, name: string): Promise<void> {
    await this.call("DELETE", `/proxies/${proxy}/toxics/${name}`);
  }
}

function percentile(sorted: number[], p: number): number | null {
  if (!sorted.length) return null;
  // Nearest rank: with 20 samples, p99 is the maximum.
  const rank = Math.ceil((p / 100) * sorted.length);
  return sorted[Math.max(0, rank - 1)];
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main(): Promise<void> {
  const options = parseOptions(process.argv.slice(2));
  requireLocalDatabase();
  // Imported after the guard so no module opens a pool against an unchecked URL.
  const { makeSql } = await import("../src/db");
  const { startCloudServer } = await import("../src/cloud");
  const { getDifference } = await import("../src/sync");
  const db = makeSql();
  const toxiproxy = new Toxiproxy(options.toxiproxy);
  const scenarios = options.scenarios.map((name) => {
    const scenario = SCENARIOS.find((s) => s.name === name);
    if (!scenario) throw new Error(`unknown scenario ${name}`);
    return options.mild && MILD[name] ? { ...scenario, ...MILD[name] } : scenario;
  });
  if (options.messages % 4 !== 0) throw new Error("--messages must be a multiple of 4 clients");

  const server = startCloudServer(0, db, null, null, { backgroundWorkers: false });
  const setupBase = `http://127.0.0.1:${server.port}`;
  const apiBase = `http://127.0.0.1:${options.proxyPort}`;
  const environment = {
    label: options.label,
    date: new Date().toISOString(),
    gitSha: execSync("git rev-parse HEAD").toString().trim(),
    gitDirty: execSync("git status --porcelain -- . ../.github").toString().trim().length > 0,
    machine: machineDescription(),
    bun: Bun.version,
    postgres: String((await db`SELECT version() AS v`)[0].v),
    toxiproxy: await toxiproxy.version(),
    command: `bun run chaos/run.ts ${process.argv.slice(2).join(" ")}`,
    options,
  };
  console.log(JSON.stringify({ event: "chaos.start", ...environment }));

  const results: RunResult[] = [];
  try {
    for (const scenario of scenarios) {
      for (let run = 1; run <= options.runs; run += 1) {
        const result = await runOnce(scenario, run);
        results.push(result);
        console.log(JSON.stringify({ event: "chaos.run", ...result }));
      }
    }
  } finally {
    server.stop(true);
  }

  const summary = summarize(results, scenarios);
  const report = { environment, scenarios, summary, runs: results };
  if (options.out) writeFileSync(options.out, JSON.stringify(report, null, 2) + "\n");
  console.log(JSON.stringify({ event: "chaos.summary", summary }));
  await db.close();
  const failed = summary.some((s) => s.lost > 0 || s.serverDuplicates > 0 || s.deviceMismatches > 0
    || s.conflictingEchoes > 0 || s.fatalErrors > 0 || s.unconverged > 0);
  process.exit(failed ? 1 : 0);

  async function resetDatabase(): Promise<void> {
    await db`
      TRUNCATE
        send_requests, push_deliveries, account_events, messages, dialog_members,
        direct_dialog_pairs, dialogs, devices, account_sync_states, accounts, otp_challenges
      RESTART IDENTITY CASCADE`;
  }

  async function runOnce(scenario: Scenario, run: number): Promise<RunResult> {
    await resetDatabase();
    await toxiproxy.recreate("toj", `0.0.0.0:${options.proxyPort}`, `${options.upstreamHost}:${server.port}`);

    const endpoints = { apiBase, setupBase };
    const suffix = String(run).padStart(2, "0") + String(scenarios.indexOf(scenario));
    const phoneA = `+1650555${("1" + suffix).padStart(4, "0").slice(-4)}`;
    const phoneB = `+1650555${("2" + suffix).padStart(4, "0").slice(-4)}`;
    const clients = ["a1", "a2", "b1", "b2"].map((name) => new SyncClient(name, endpoints));
    const [a1, a2, b1, b2] = clients;
    await a1.signIn(phoneA, "Alice");
    await b1.signIn(phoneB, "Bob");
    // A second device on the same phone would hit the 30 s resend cooldown. Backdate the harness's
    // own challenges instead of adding any bypass to production code.
    await db`UPDATE otp_challenges SET created_at = created_at - interval '31 seconds'`;
    await a2.signIn(phoneA, "Alice");
    await b2.signIn(phoneB, "Bob");
    const dialogId = await a1.openDirectDialog(b1.accountId);
    for (const client of clients) client.dialogId = dialogId;

    for (const client of clients) client.start();
    await waitFor(() => clients.every((c) => c.stats.wsConnects > 0 && !c.syncing), 30_000);

    for (const toxic of scenario.toxics) await toxiproxy.addToxic("toj", toxic);
    let pulsing = true;
    const pulse = scenario.pulse;
    const pulser = pulse ? (async () => {
      while (pulsing) {
        for (const toxic of pulse.toxics) await toxiproxy.addToxic("toj", toxic);
        await sleep(pulse.onMs);
        for (const toxic of pulse.toxics) await toxiproxy.removeToxic("toj", toxic.name);
        await sleep(pulse.everyMs - pulse.onMs);
      }
    })() : Promise.resolve();

    const perClient = options.messages / clients.length;
    const generated: string[] = [];
    const sendStarted = performance.now();
    await Promise.all(clients.map(async (client) => {
      for (let i = 0; i < perClient; i += 1) {
        const clientMsgId = crypto.randomUUID();
        generated.push(clientMsgId);
        await client.send(clientMsgId, `chaos ${scenario.name} run ${run} ${client.name} #${i}`);
      }
    }));
    const lastAck = performance.now();

    // Server truth: read in-process, not through the proxy.
    const truth = await serverTruth(getDifference, db, a1.accountId, dialogId);
    const truthB = await serverTruth(getDifference, db, b1.accountId, dialogId);
    const serverPts = new Map((await db`
      SELECT account_id, pts FROM account_sync_states
      WHERE account_id IN (${a1.accountId}, ${b1.accountId})`)
      .map((row: { account_id: string; pts: number }) => [String(row.account_id), Number(row.pts)]));

    const converged = await waitFor(() => clients.every((c) =>
      !c.syncing && c.pts === serverPts.get(c.accountId) && c.digest() === truth.digest
    ), options.convergeTimeoutMs);
    const convergenceMs = converged ? performance.now() - lastAck : null;

    pulsing = false;
    await pulser;
    for (const client of clients) await client.stop();

    const stored = new Set((await db`SELECT client_msg_id FROM messages WHERE dialog_id = ${dialogId}`)
      .map((row: { client_msg_id: string }) => String(row.client_msg_id)));
    const lost = generated.filter((id) => !stored.has(id)).length;
    const serverDuplicates = (await db`
      SELECT client_msg_id FROM messages WHERE dialog_id = ${dialogId}
      GROUP BY client_msg_id HAVING count(*) > 1`).length;
    const sum = (key: keyof SyncClient["stats"]) =>
      clients.reduce((total, c) => total + Number(c.stats[key]), 0);

    return {
      scenario: scenario.name,
      run,
      messages: generated.length,
      serverMessages: stored.size,
      lost,
      serverDuplicates,
      truthAgreesAcrossAccounts: truth.digest === truthB.digest,
      deviceMismatches: clients.filter((c) => c.digest() !== truth.digest).length,
      ptsMismatches: clients.filter((c) => c.pts !== serverPts.get(c.accountId)).length,
      conflictingEchoes: sum("conflictingEchoes"),
      redeliveredUpdates: sum("redeliveredUpdates"),
      sendAttempts: sum("sendAttempts"),
      sendFailures: sum("sendFailures"),
      duplicateAcks: sum("duplicateAcks"),
      lateFailuresAfterEcho: sum("lateFailuresAfterEcho"),
      syncCalls: sum("syncCalls"),
      syncFailures: sum("syncFailures"),
      wsConnects: sum("wsConnects"),
      fatalErrors: clients.flatMap((c) => c.stats.fatalErrors),
      sendPhaseMs: Math.round(lastAck - sendStarted),
      convergenceMs: convergenceMs == null ? null : Math.round(convergenceMs),
    };
  }
}

type RunResult = {
  scenario: string; run: number; messages: number; serverMessages: number; lost: number;
  serverDuplicates: number; truthAgreesAcrossAccounts: boolean; deviceMismatches: number;
  ptsMismatches: number; conflictingEchoes: number; redeliveredUpdates: number;
  sendAttempts: number; sendFailures: number; duplicateAcks: number; lateFailuresAfterEcho: number;
  syncCalls: number; syncFailures: number; wsConnects: number; fatalErrors: string[];
  sendPhaseMs: number; convergenceMs: number | null;
};

async function serverTruth(
  getDifference: typeof import("../src/sync").getDifference,
  db: import("bun").SQL,
  accountId: string,
  dialogId: string,
): Promise<{ digest: string; count: number }> {
  const messages = new Map<string, { msgId: number; senderAccountId: string; textHash: string }>();
  let pts = 0;
  for (;;) {
    const page = await getDifference(db, accountId, pts);
    if (page.kind === "difference_too_long") throw new Error("server truth hit difference_too_long");
    for (const update of page.updates) {
      const message = update.message;
      if (update.type !== "message.new" || !message || message.dialog_id !== dialogId) continue;
      messages.set(String(message.client_msg_id), {
        msgId: Number(message.msg_id),
        senderAccountId: String(message.sender_account_id),
        textHash: sha256(String(message.text ?? "")),
      });
    }
    pts = page.state.pts;
    if (page.kind === "difference") break;
  }
  return { digest: stateDigest(messages), count: messages.size };
}

async function waitFor(condition: () => boolean, timeoutMs: number): Promise<boolean> {
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    if (condition()) return true;
    await sleep(25);
  }
  return condition();
}

function summarize(results: RunResult[], scenarios: Scenario[]) {
  return scenarios.map((scenario) => {
    const runs = results.filter((r) => r.scenario === scenario.name);
    const total = (key: keyof RunResult) => runs.reduce((sum, r) => sum + Number(r[key]), 0);
    const convergence = runs.map((r) => r.convergenceMs).filter((v): v is number => v != null)
      .sort((a, b) => a - b);
    return {
      scenario: scenario.name,
      runs: runs.length,
      messages: total("messages"),
      lost: total("lost"),
      serverDuplicates: total("serverDuplicates"),
      deviceMismatches: total("deviceMismatches"),
      ptsMismatches: total("ptsMismatches"),
      conflictingEchoes: total("conflictingEchoes"),
      redeliveredUpdates: total("redeliveredUpdates"),
      runsWithRedelivery: runs.filter((r) => r.redeliveredUpdates > 0).length,
      sendAttempts: total("sendAttempts"),
      sendFailures: total("sendFailures"),
      duplicateAcks: total("duplicateAcks"),
      lateFailuresAfterEcho: total("lateFailuresAfterEcho"),
      syncFailures: total("syncFailures"),
      wsConnects: total("wsConnects"),
      fatalErrors: runs.reduce((sum, r) => sum + r.fatalErrors.length, 0),
      unconverged: runs.filter((r) => r.convergenceMs == null).length,
      convergenceP50Ms: percentile(convergence, 50),
      convergenceP99Ms: percentile(convergence, 99),
      convergenceMaxMs: convergence.at(-1) ?? null,
      sendPhaseP50Ms: percentile(runs.map((r) => r.sendPhaseMs).sort((a, b) => a - b), 50),
    };
  });
}

function machineDescription(): string {
  const cpu = os.cpus()[0]?.model ?? "unknown cpu";
  let model: string = os.platform();
  try {
    model = os.platform() === "darwin"
      ? execSync("sysctl -n hw.model").toString().trim()
      : execSync("uname -sr").toString().trim();
  } catch {
    // Machine model is descriptive only.
  }
  return `${model}; ${cpu}; ${os.cpus().length} cores; ${Math.round(os.totalmem() / 2 ** 30)} GB`;
}

await main();
