// Replays seeded SMS-pumping attacks against the real startVerification on local PostgreSQL.
//
//   bun run scripts/otp-fraud-replay.ts run --seeds 0-14 --shapes A,B,C,D --configs today,budget,rules \
//     [--rules <json file>] [--volume 2000] [--telegram 0.5] [--workers 8] --out <results.jsonl>
//   bun run scripts/otp-fraud-replay.ts report --in <results.jsonl> [--seeds 15-19]
//
// The traffic model, attack shapes, thresholds, seeds and metrics are registered in
// docs/results/otp-fraud-preregistration.md; this file implements that document and nothing more.
// Everything it produces is simulated. Each worker creates, migrates and finally drops its own
// database; it never touches an existing one.
import { $, SQL } from "bun";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { AuthError, checkVerification, startVerification, type OTPDelivery } from "../src/auth";
import { setOtpClock } from "../src/otp-clock";
import { EVALUATION_OTP_RISK_RULES, parseOtpRiskRules, type OtpRiskConfig, type OtpRiskRules } from "../src/otp-risk";

// ---------------------------------------------------------------------------------------------
// Registered constants (pre-registration sections 2 to 4)

const SMS_MICROS = 450_500;
const TELEGRAM_MICROS = 10_000;
const HORIZON_DAYS = 4;
/** 00:00 Asia/Dushanbe (UTC+5) on simulated day 1. */
const START = Date.parse("2026-10-04T19:00:00Z");
const HOUR = 3_600_000;
const DIURNAL = [2, 1, 1, 1, 1, 2, 3, 5, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7, 8, 9, 9, 8, 6, 4];
const DIURNAL_SUM = DIURNAL.reduce((a, b) => a + b, 0);
const OPERATORS = [
  { name: "tcell", share: 0.36, ranges: ["+99292", "+99293"] },
  { name: "megafon", share: 0.28, ranges: ["+99290", "+99288"] },
  { name: "zet", share: 0.20, ranges: ["+99291", "+99255"] },
  { name: "babilon", share: 0.15, ranges: ["+99298", "+99250"] },
  { name: "foreign", share: 0.01, ranges: ["+7916", "+7926"] },
] as const;
const TAJIK_RANGES = OPERATORS.slice(0, 4).flatMap((operator) => operator.ranges);
const CGNAT_POOL = 64;
const MOBILE_SHARE = 0.85;
const URBAN_SHARE = 0.6;
const DELIVERY = { smsUrban: 0.97, smsRural: 0.87, telegram: 0.99 };
const ENTER_PROBABILITY = 0.97;
const MAX_REQUESTS = 3;
const TELEGRAM_FIRST = 0.3;
const FOREIGN_LOW_AND_SLOW = [
  "+88213", "+88216", "+88234", "+88239", "+88298", "+88299", "+88310", "+88351", "+87010", "+87015",
];

export type Shape = "A" | "B" | "C" | "D";
export type ConfigName = "today" | "budget" | "rules";

// ---------------------------------------------------------------------------------------------
// Deterministic randomness: one independent stream per (seed, purpose).

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4_294_967_296;
  };
}

function stream(seed: number, label: string): () => number {
  let hash = 2166136261 ^ seed;
  for (const char of label) hash = Math.imul(hash ^ char.charCodeAt(0), 16777619);
  return mulberry32(hash);
}

function poisson(random: () => number, mean: number): number {
  // Knuth for small means, normal approximation above 50 (every mean here is well defined).
  if (mean > 50) {
    const u = Math.max(random(), 1e-12);
    const v = random();
    return Math.max(0, Math.round(mean + Math.sqrt(mean) * Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v)));
  }
  const limit = Math.exp(-mean);
  let k = 0;
  let p = 1;
  do { k += 1; p *= random(); } while (p > limit);
  return k - 1;
}

const between = (random: () => number, low: number, high: number) => low + (high - low) * random();

// ---------------------------------------------------------------------------------------------
// Traffic

type Party = {
  id: number;
  kind: "legit" | "attack";
  phone: string;
  network: string;
  urban: boolean;
  hasTelegram: boolean;
  channel: "sms" | "telegram";
  requests: number;
  steered: boolean;
  /** Per-party randomness, so a user's delivery luck is identical under every configuration. */
  random: () => number;
  outcome?: "verified" | "risk_refused" | "existing_refused" | "abandoned" | "other";
};

type Event = { at: number; party: Party; action: "request" | "enter" };

class NumberPool {
  private used = new Set<string>();
  constructor(private readonly random: () => number) {}
  draw(range: string): string {
    // Seven subscriber digits after every range used here gives a valid E.164 length for each.
    const digits = 7;
    for (;;) {
      const number = `${range}${String(Math.floor(this.random() * 10 ** digits)).padStart(digits, "0")}`;
      if (!this.used.has(number)) {
        this.used.add(number);
        return number;
      }
    }
  }
}

function legitimateParties(seed: number, volume: number, telegramShare: number, pool: NumberPool): Event[] {
  const random = stream(seed, "legit");
  const events: Event[] = [];
  let id = 0;
  for (let day = 0; day < HORIZON_DAYS; day += 1) {
    for (let hour = 0; hour < 24; hour += 1) {
      const count = poisson(random, (volume * DIURNAL[hour]) / DIURNAL_SUM);
      for (let i = 0; i < count; i += 1) {
        let pick = random();
        const operator = OPERATORS.find((candidate) => (pick -= candidate.share) < 0) ?? OPERATORS[0];
        const range = operator.ranges[Math.floor(random() * operator.ranges.length)];
        const mobile = random() < MOBILE_SHARE;
        const hasTelegram = random() < telegramShare;
        const party: Party = {
          id: id++,
          kind: "legit",
          phone: pool.draw(range),
          network: mobile ? `${operator.name}-nat-${Math.floor(random() * CGNAT_POOL)}` : `wifi-${seed}-${id}`,
          urban: random() < URBAN_SHARE,
          hasTelegram,
          channel: hasTelegram && random() < TELEGRAM_FIRST ? "telegram" : "sms",
          requests: 0,
          steered: false,
          random: stream(seed * 1_000_003 + id, "behaviour"),
        };
        events.push({ at: START + (day * 24 + hour) * HOUR + random() * HOUR, party, action: "request" });
      }
    }
  }
  return events;
}

export function attackEvents(seed: number, shape: Shape, pool: NumberPool): Event[] {
  const random = stream(seed, `attack-${shape}`);
  const begin = START + 24 * HOUR + random() * 24 * HOUR;
  const end = START + HORIZON_DAYS * 24 * HOUR;
  const events: Event[] = [];
  let id = 1_000_000;
  const add = (at: number, range: string, networks: number, label: string) => {
    if (at >= end) return;
    events.push({
      at,
      action: "request",
      party: {
        id: id++, kind: "attack", phone: pool.draw(range),
        network: `${label}-${Math.floor(random() * networks)}`,
        urban: true, hasTelegram: false, channel: "sms", requests: 0, steered: false,
        random: () => 0,
      },
    });
  };
  if (shape === "A") {
    for (let i = 0; i < 400; i += 1) add(begin + random() * 2 * HOUR, "+88216", 50, "proxy-a");
  } else if (shape === "B") {
    const range = "+99292";
    for (let hour = 0; hour < 48; hour += 1) {
      const at = begin + hour * HOUR;
      const local = new Date(at + 5 * HOUR).getUTCHours();
      const count = poisson(random, (20 * 24 * DIURNAL[local]) / DIURNAL_SUM);
      for (let i = 0; i < count; i += 1) add(at + random() * HOUR, range, 200, "resi-b");
    }
  } else if (shape === "C") {
    for (const range of FOREIGN_LOW_AND_SLOW) {
      for (let hour = 0; hour < 48; hour += 1) {
        const count = poisson(random, 3);
        for (let i = 0; i < count; i += 1) add(begin + (hour + random()) * HOUR, range, 500, "resi-c");
      }
    }
  } else {
    for (let hour = 0; hour < 24; hour += 1) {
      const count = poisson(random, 40);
      for (let i = 0; i < count; i += 1) {
        add(begin + (hour + random()) * HOUR, TAJIK_RANGES[Math.floor(random() * TAJIK_RANGES.length)], 200, "resi-d");
      }
    }
  }
  return events;
}

// ---------------------------------------------------------------------------------------------
// One run

class Ledger implements OTPDelivery {
  codes = new Map<string, string>();
  micros = { legit: 0, attack: 0 };
  sends = { legitSms: 0, legitTelegram: 0, attackSms: 0, attackTelegram: 0 };
  kinds = new Map<string, "legit" | "attack">();
  constructor(readonly channel: "sms" | "telegram", readonly dailyRequestLimit?: number) {}
  async send(phone: string, code: string): Promise<void> {
    this.codes.set(phone, code);
    const kind = this.kinds.get(phone) ?? "legit";
    this.micros[kind] += this.channel === "sms" ? SMS_MICROS : TELEGRAM_MICROS;
    if (this.channel === "sms") this.sends[kind === "legit" ? "legitSms" : "attackSms"] += 1;
    else this.sends[kind === "legit" ? "legitTelegram" : "attackTelegram"] += 1;
  }
}

class Heap {
  private items: Event[] = [];
  push(event: Event) {
    const items = this.items;
    items.push(event);
    let i = items.length - 1;
    while (i > 0) {
      const parent = (i - 1) >> 1;
      if (items[parent].at <= items[i].at) break;
      [items[parent], items[i]] = [items[i], items[parent]];
      i = parent;
    }
  }
  pop(): Event | undefined {
    const items = this.items;
    if (items.length === 0) return undefined;
    const top = items[0];
    const last = items.pop()!;
    if (items.length) {
      items[0] = last;
      let i = 0;
      for (;;) {
        const left = 2 * i + 1;
        const right = left + 1;
        let smallest = i;
        if (left < items.length && items[left].at < items[smallest].at) smallest = left;
        if (right < items.length && items[right].at < items[smallest].at) smallest = right;
        if (smallest === i) break;
        [items[smallest], items[i]] = [items[i], items[smallest]];
        i = smallest;
      }
    }
    return top;
  }
}

export type RunResult = {
  seed: number; shape: Shape; config: ConfigName; volume: number; telegramShare: number;
  rulesDigest: string;
  legit: {
    users: number; verified: number; riskRefused: number; existingRefused: number; abandoned: number;
    steeredVerified: number; smsSends: number; smsSendsVerified: number;
  };
  attack: { requests: number; billedSms: number; refusedByRules: number; refusedByExisting: number };
  micros: { legit: number; attack: number; total: number };
  ruleHits: Record<string, number>;
  elapsedMs: number;
};

function configFor(name: ConfigName, rules: OtpRiskRules): OtpRiskConfig {
  return {
    mode: name === "rules" ? "enforce" : "off",
    rules,
    pricesMicros: { sms: SMS_MICROS, telegram: TELEGRAM_MICROS },
    dailySpendCeilingMicros: null,
  };
}

async function runOnce(db: SQL, seed: number, shape: Shape, config: ConfigName, rules: OtpRiskRules,
  volume: number, telegramShare: number): Promise<RunResult> {
  const started = performance.now();
  await db`TRUNCATE accounts, otp_challenges, otp_risk_decisions, otp_spend_reservations RESTART IDENTITY CASCADE`;
  const pool = new NumberPool(stream(seed, "numbers"));
  const heap = new Heap();
  const legitEvents = legitimateParties(seed, volume, telegramShare, pool);
  const attack = attackEvents(seed, shape, pool);
  for (const event of [...legitEvents, ...attack]) heap.push(event);

  const limit = config === "budget" ? 10 : undefined;
  const sms = new Ledger("sms", limit);
  const telegram = new Ledger("telegram", limit);
  for (const event of attack) { sms.kinds.set(event.party.phone, "attack"); telegram.kinds.set(event.party.phone, "attack"); }
  const deliveries = new Map([["sms", sms], ["telegram", telegram]] as const);
  const risk = configFor(config, rules);

  const legit = legitEvents.map((event) => event.party);
  const result: RunResult = {
    seed, shape, config, volume, telegramShare, rulesDigest: JSON.stringify(rules),
    legit: { users: legit.length, verified: 0, riskRefused: 0, existingRefused: 0, abandoned: 0,
      steeredVerified: 0, smsSends: 0, smsSendsVerified: 0 },
    attack: { requests: attack.length, billedSms: 0, refusedByRules: 0, refusedByExisting: 0 },
    micros: { legit: 0, attack: 0, total: 0 },
    ruleHits: {},
    elapsedMs: 0,
  };
  let now = START;
  setOtpClock(() => new Date(now));
  try {
    for (let event = heap.pop(); event; event = heap.pop()) {
      now = Math.floor(event.at);
      const party = event.party;
      if (event.action === "enter") {
        const code = (party.channel === "sms" ? sms : telegram).codes.get(party.phone)!;
        try {
          await checkVerification(db, party.phone, code, "ios", "Replay", "Replay");
          party.outcome = "verified";
          if (party.steered) result.legit.steeredVerified += 1;
        } catch {
          party.outcome = "other";
        }
        continue;
      }
      party.requests += 1;
      try {
        await startVerification(db, party.phone, {
          deliveries, deliveryChannel: party.channel, networkKey: party.network, risk,
        });
      } catch (error) {
        const code = error instanceof AuthError ? error.code : undefined;
        const status = error instanceof AuthError ? error.status : 500;
        if (party.kind === "attack") {
          if (code === "sms_unavailable" || code === "verification_unavailable") result.attack.refusedByRules += 1;
          else result.attack.refusedByExisting += 1;
          continue;
        }
        if (code === "sms_unavailable" && party.hasTelegram && !party.steered) {
          party.steered = true;
          party.channel = "telegram";
          party.requests -= 1;
          heap.push({ at: now + 5_000, party, action: "request" });
        } else if (code === "sms_unavailable" || code === "verification_unavailable") {
          party.outcome = "risk_refused";
        } else if (status === 429 && party.requests < MAX_REQUESTS) {
          const retryAfter = error instanceof AuthError && error.retryAfter ? error.retryAfter : 60;
          if (retryAfter > 3_600) party.outcome = "existing_refused";
          else heap.push({ at: now + retryAfter * 1000 + 1000, party, action: "request" });
        } else {
          party.outcome = status === 429 ? "existing_refused" : "other";
        }
        continue;
      }
      if (party.kind === "attack") continue;
      const random = party.random;
      const delivered = random() < (party.channel === "telegram" ? DELIVERY.telegram
        : party.urban ? DELIVERY.smsUrban : DELIVERY.smsRural);
      if (delivered && random() < ENTER_PROBABILITY) {
        heap.push({ at: now + between(random, 30_000, 240_000), party, action: "enter" });
      } else if (!delivered && party.requests < MAX_REQUESTS) {
        heap.push({ at: now + between(random, 60_000, 180_000), party, action: "request" });
      } else {
        party.outcome = "abandoned";
      }
    }
  } finally {
    setOtpClock(null);
  }

  for (const party of legit) {
    if (party.outcome === "verified") result.legit.verified += 1;
    else if (party.outcome === "risk_refused") result.legit.riskRefused += 1;
    else if (party.outcome === "existing_refused") result.legit.existingRefused += 1;
    else result.legit.abandoned += 1;
  }
  const [sends] = await db`
    SELECT count(*) FILTER (WHERE channel = 'sms')::int AS sms,
           count(*) FILTER (WHERE channel = 'sms' AND verified_at IS NOT NULL)::int AS verified
    FROM otp_challenges`;
  result.legit.smsSends = sms.sends.legitSms;
  result.legit.smsSendsVerified = Number(sends.verified);
  result.attack.billedSms = sms.sends.attackSms;
  result.micros = {
    legit: sms.micros.legit + telegram.micros.legit,
    attack: sms.micros.attack + telegram.micros.attack,
    total: sms.micros.legit + telegram.micros.legit + sms.micros.attack + telegram.micros.attack,
  };
  for (const row of await db`
    SELECT rule_id, count(*)::int AS count FROM otp_risk_decisions
    WHERE action <> 'allow' GROUP BY rule_id`) result.ruleHits[String(row.rule_id)] = Number(row.count);
  result.elapsedMs = Math.round(performance.now() - started);
  return result;
}

// ---------------------------------------------------------------------------------------------
// CLI

function parseList(value: string | undefined, fallback: string): string[] {
  return (value ?? fallback).split(",").map((item) => item.trim()).filter(Boolean);
}

function parseSeeds(value: string | undefined): number[] {
  const seeds: number[] = [];
  for (const part of parseList(value, "0-19")) {
    const [low, high] = part.split("-").map(Number);
    for (let seed = low; seed <= (high ?? low); seed += 1) seeds.push(seed);
  }
  return seeds;
}

function argument(args: string[], name: string): string | undefined {
  const index = args.indexOf(`--${name}`);
  return index >= 0 ? args[index + 1] : undefined;
}

async function worker(args: string[]): Promise<void> {
  const database = argument(args, "database")!;
  const jobs = JSON.parse(argument(args, "jobs")!) as [number, Shape, ConfigName][];
  const rules = argument(args, "rules") ? parseOtpRiskRules(readFileSync(argument(args, "rules")!, "utf8"))
    : EVALUATION_OTP_RISK_RULES;
  const volume = Number(argument(args, "volume") ?? 2000);
  const telegramShare = Number(argument(args, "telegram") ?? 0.5);
  const out = argument(args, "out")!;
  process.env.TOJ_RETURN_OTP = "0";
  const db = new SQL(`postgres://localhost:5432/${database}`, { max: 2 });
  try {
    for (const [seed, shape, config] of jobs) {
      const result = await runOnce(db, seed, shape, config, rules, volume, telegramShare);
      appendFileSync(out, `${JSON.stringify(result)}\n`);
      console.log(`seed ${seed} shape ${shape} ${config}: ${result.elapsedMs} ms`);
    }
  } finally {
    await db.close();
  }
}

async function run(args: string[]): Promise<void> {
  const seeds = parseSeeds(argument(args, "seeds"));
  const shapes = parseList(argument(args, "shapes"), "A,B") as Shape[];
  const configs = parseList(argument(args, "configs"), "today,budget,rules") as ConfigName[];
  const workers = Number(argument(args, "workers") ?? 6);
  const out = argument(args, "out");
  if (!out) throw new Error("--out is required");
  const jobs: [number, Shape, ConfigName][] = [];
  for (const seed of seeds) for (const shape of shapes) for (const config of configs) jobs.push([seed, shape, config]);
  const buckets: typeof jobs[] = Array.from({ length: Math.min(workers, jobs.length) }, () => []);
  jobs.forEach((job, index) => buckets[index % buckets.length].push(job));
  const passthrough = ["rules", "volume", "telegram"].flatMap((name) =>
    argument(args, name) != null ? [`--${name}`, argument(args, name)!] : []);
  const databases = buckets.map((_, index) => `toj_otp_replay_${process.pid}_${index}`);
  try {
    for (const database of databases) {
      await $`createdb ${database}`.quiet();
      await $`bun run src/migrate.ts`.cwd(new URL("..", import.meta.url).pathname)
        .env({ ...process.env, DATABASE_URL: `postgres://localhost:5432/${database}` }).quiet();
    }
    const children = buckets.map((bucket, index) => Bun.spawn([
      "bun", "run", import.meta.path, "worker", "--database", databases[index],
      "--jobs", JSON.stringify(bucket), "--out", out, ...passthrough,
    ], { stdout: "inherit", stderr: "inherit", env: { ...process.env, TOJ_RETURN_OTP: "0" } }));
    const codes = await Promise.all(children.map((child) => child.exited));
    if (codes.some((code) => code !== 0)) throw new Error(`worker exit codes ${codes.join(",")}`);
  } finally {
    for (const database of databases) await $`dropdb --if-exists ${database}`.nothrow().quiet();
  }
}

type Row = RunResult;
const pct = (numerator: number, denominator: number) => denominator ? (100 * numerator) / denominator : 0;

export function summarize(rows: Row[]) {
  const key = (row: Row) => `${row.shape}|${row.config}`;
  const groups = new Map<string, Row[]>();
  for (const row of rows) groups.set(key(row), [...(groups.get(key(row)) ?? []), row]);
  const reference = new Map(rows.filter((row) => row.config === "today").map((row) => [`${row.seed}|${row.shape}`, row]));
  const lines: string[] = [];
  for (const [group, members] of [...groups].sort()) {
    const [shape, config] = group.split("|");
    const stat = (value: (row: Row) => number) => {
      const values = members.map(value);
      const mean = values.reduce((a, b) => a + b, 0) / values.length;
      return { mean, min: Math.min(...values), max: Math.max(...values) };
    };
    const blocked = stat((row) => pct(row.attack.requests - row.attack.billedSms, row.attack.requests));
    const byRules = stat((row) => pct(row.attack.refusedByRules, row.attack.requests));
    const legitRisk = stat((row) => pct(row.legit.riskRefused, row.legit.users));
    const existing = stat((row) => pct(row.legit.existingRefused, row.legit.users));
    const steered = stat((row) => pct(row.legit.steeredVerified, row.legit.users));
    const verified = stat((row) => pct(row.legit.verified, row.legit.users));
    const verifyRate = stat((row) => pct(row.legit.smsSendsVerified, row.legit.smsSends));
    const saved = stat((row) => {
      const base = reference.get(`${row.seed}|${row.shape}`);
      return base ? (base.micros.total - row.micros.total) / 1e6 : NaN;
    });
    const fmt = (s: { mean: number; min: number; max: number }, digits = 1) =>
      `${s.mean.toFixed(digits)} (${s.min.toFixed(digits)}-${s.max.toFixed(digits)})`;
    lines.push(`| ${shape} | ${config} | ${members.length} | ${fmt(blocked)} | ${fmt(byRules)} | ${fmt(legitRisk, 2)} | ${fmt(existing, 2)} | ${fmt(steered, 2)} | ${fmt(verified)} | ${fmt(verifyRate)} | ${fmt(saved, 0)} |`);
  }
  return [
    "| Shape | Config | Seeds | Attack sends blocked % | of which by new rules % | Real sign-ups refused by rules % | Refused by existing controls % | Steered to Telegram and verified % | Real users verified % | Legit SMS verify rate % | Dollars saved vs today |",
    "|---|---|---|---|---|---|---|---|---|---|---|",
    ...lines,
  ].join("\n");
}

if (import.meta.main) {
  const [command, ...args] = process.argv.slice(2);
  if (command === "worker") await worker(args);
  else if (command === "run") await run(args);
  else if (command === "report") {
    const seeds = argument(args, "seeds") ? new Set(parseSeeds(argument(args, "seeds"))) : null;
    const rows = readFileSync(argument(args, "in")!, "utf8").trim().split("\n").map((line) => JSON.parse(line) as Row)
      .filter((row) => !seeds || seeds.has(row.seed));
    const output = summarize(rows);
    console.log(output);
    if (argument(args, "write")) writeFileSync(argument(args, "write")!, `${output}\n`);
  } else {
    console.error("usage: otp-fraud-replay.ts run|report ...");
    process.exit(2);
  }
}
