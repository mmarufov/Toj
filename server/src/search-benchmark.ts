/**
 * Bun port of `TojTests/MessageSearchIndexSizeBenchmark.swift`'s corpus and harness, plus the
 * 24-word corpus its docstring says the first version used.
 *
 * The Swift docstring says the first benchmark "drew from 24 distinct words", and that this is
 * "precisely the regime where `prefix='2'` looks free". Nothing in git shows that earlier run.
 * This module reruns the claim instead: the same harness and schema on both corpora, with only
 * the vocabulary changed. `search-benchmark.test.ts` pins what it shows, which is not quite what
 * the docstring says:
 *
 * - The 24-word corpus does **not** make `'2'` and `'2 3'` indistinguishable. A three-character
 *   prefix still costs about 1 ms warm with `'2'` against 0.01 ms with `'2 3'`.
 * - It does understate the absolute cost about tenfold (roughly 1 ms against 10 ms here), because
 *   `при` covers 1 index term in the small corpus and 400 in the full one.
 * - The cost follows the terms under the prefix, not the vocabulary. At the same 15,870-word
 *   vocabulary, `привет1` (11 terms) is 0.4 ms and `при` (400 terms) is 10 ms. The Swift table's
 *   flat ~24 ms across prefix lengths comes from its three probe prefixes all covering the same
 *   400 terms.
 *
 * Fidelity to the Swift harness: the same LCG and seed, vocabulary, Zipf-ish draw, script mix,
 * attachment and link rates, the same FTS5 declaration and merge settings as
 * `SearchIndexSchema.swift`, and the same `SELECT rowid ... MATCH ? LIMIT 60`. Text is
 * normalized by the Bun port in `search.ts`, which the parity tests hold to the Swift normalizer.
 * The SQLite is whatever `bun:sqlite` loads, unless `TOJ_SQLITE_LIBRARY` names another library,
 * such as one built from `Pods/SQLCipher/sqlite3.c`. The Swift harness ran on SQLCipher with a key.
 *
 *   bun run scripts/search-index-benchmark.ts
 */
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { exact, foldedForm, tokens } from "./search";

const customLibrary = process.env.TOJ_SQLITE_LIBRARY;
if (customLibrary) Database.setCustomSQLite(customLibrary);

/**
 * Set with a SQLCipher library to key every connection, as the Swift harness does. It passes 32
 * bytes of 0x5A to GRDB's `usePassphrase`, which is the passphrase of 32 `Z` characters.
 */
const passphrase = process.env.TOJ_SQLCIPHER_PASSPHRASE;

function open(path: string, readonly = false): Database {
  const db = readonly ? new Database(path, { readonly: true }) : new Database(path, { create: true });
  if (passphrase) db.run(`PRAGMA key = '${passphrase.replaceAll("'", "''")}'`);
  return db;
}

export function engine(): string {
  const db = open(":memory:");
  const version = (db.query("SELECT sqlite_version() AS v").get() as { v: string }).v;
  let cipher = "";
  try {
    cipher = (db.query("PRAGMA cipher_version").get() as { cipher_version?: string } | null)?.cipher_version ?? "";
  } catch {}
  db.close();
  return `SQLite ${version}${cipher ? `, SQLCipher ${cipher}${passphrase ? ", keyed" : ", not keyed"}` : ""}`;
}

export const TOKENIZE = "unicode61 remove_diacritics 2";
export const EXACT_COLUMNS = ["exact", "file_name", "link_text"];

export interface Message {
  dialog: string;
  body: string;
  fileName: string;
  linkText: string;
}

export interface Corpus {
  name: string;
  messages: Message[];
  dialogs: string[];
}

/** The Swift benchmark's generator: `seed = seed * a + c` over UInt64, `(seed >> 33) % bound`. */
function lcg(seed: bigint) {
  const mask = (1n << 64n) - 1n;
  return (bound: number) => {
    seed = (seed * 6_364_136_223_846_793_005n + 1_442_695_040_888_963_407n) & mask;
    return Number((seed >> 33n) % BigInt(bound));
  };
}

const RUSSIAN_STEMS = ["привет", "встреч", "завтра", "спасиб", "хорош", "работ", "город",
  "машин", "деньг", "врем", "друз", "семь", "школ", "книг"];
const TAJIK_STEMS = ["тоҷик", "ҷони", "ғафур", "қишлоқ", "ҳаво", "ӯро", "салом", "рафт",
  "дӯст", "хона", "модар", "падар", "барод", "хоҳар"];
const LATIN_STEMS = ["meeting", "report", "invoice", "project", "message", "picture",
  "holiday", "morning", "evening", "contract", "delivery", "package"];
const SUFFIXES = ["", "а", "ы", "ой", "ам", "ах", "ов", "ing", "ed", "s", "er", "ion",
  "и", "ро", "ат", "он", "ҳо", "ест", "ани", "ик"];

function vocabulary(stems: string[]): string[] {
  const words: string[] = [];
  for (const stem of stems) {
    for (const suffix of SUFFIXES) {
      for (let index = 0; index < 20; index += 1) words.push(`${stem}${suffix}${index === 0 ? "" : index}`);
    }
  }
  return words;
}

/**
 * 24 words, eight per script. Chosen to keep everything else about the corpus the same: the three
 * scripts in the same proportions, Tajik letters in the Tajik pool so the folded columns still
 * diverge for 20% of rows, and a word under every probe prefix, so `пр`, `при`, `прив` and
 * `привет` all hit real posting lists exactly as they do in the full corpus.
 */
export const SMALL_VOCABULARY = {
  russian: ["привет", "встреча", "завтра", "спасибо", "хорошо", "работа", "город", "машина"],
  tajik: ["тоҷик", "ҷони", "ғафур", "қишлоқ", "ҳаво", "салом", "дӯст", "хона"],
  latin: ["meeting", "report", "invoice", "project", "message", "picture", "holiday", "morning"],
};

export function buildCorpus(
  kind: "full" | "small",
  count = 100_000,
  dialogCount = 40,
): Corpus {
  const next = lcg(0xc0ffeen);
  const russian = kind === "full" ? vocabulary(RUSSIAN_STEMS) : SMALL_VOCABULARY.russian;
  const tajik = kind === "full" ? vocabulary(TAJIK_STEMS) : SMALL_VOCABULARY.tajik;
  const latin = kind === "full" ? vocabulary(LATIN_STEMS) : SMALL_VOCABULARY.latin;

  // Squaring a uniform draw: a mild skew toward early entries, not a real Zipf distribution.
  const zipf = (pool: string[]) => {
    const uniform = next(10_000) / 10_000;
    return pool[Math.min(pool.length - 1, Math.trunc(uniform * uniform * pool.length))];
  };

  const dialogs = Array.from({ length: dialogCount }, (_, index) => {
    const mixed = Number((BigInt(index) * 2_654_435_761n) & 0xffff_ffffn);
    return `${mixed.toString(16).padStart(8, "0")}-0000-4000-8000-${index.toString(16).padStart(12, "0")}`;
  });

  const messages: Message[] = [];
  for (let index = 0; index < count; index += 1) {
    const pool = index % 5 === 0 ? tajik : index % 5 === 1 || index % 5 === 2 ? latin : russian;
    const length = 8 + next(13);
    const body = Array.from({ length }, () => zipf(pool)).join(" ");
    messages.push({
      dialog: dialogs[next(dialogCount)],
      body,
      fileName: index % 7 === 0 ? `${zipf(latin)}_${index}.pdf` : "",
      linkText: index % 10 === 0 ? `${zipf(latin)} example com ${zipf(latin)}` : "",
    });
  }
  return { name: kind, messages, dialogs };
}

/** Distinct body words, counted the way the audit counted them. */
export function distinctBodyWords(corpus: Corpus): number {
  const seen = new Set<string>();
  for (const message of corpus.messages) for (const word of message.body.split(" ")) seen.add(word);
  return seen.size;
}

const quote = (text: string) => `"${text.replaceAll('"', '""')}"`;
const qualify = (expression: string, columns: string[]) => `{${columns.join(" ")}} : (${expression})`;
const dialogToken = (dialogId: string) => exact(dialogId).replaceAll("-", "");

/**
 * `SearchPatternBuilder.prepare(query).exactExpression` for the queries this benchmark runs:
 * at most eight terms, the last one a prefix when it has two or more characters. Swift counts
 * Characters and this counts scalars; the probe terms here are plain letters, where both agree.
 */
export function exactExpression(query: string): string {
  const terms = tokens(exact(query)).slice(0, 8);
  const body = terms
    .map((term, index) => {
      const isPrefix = index === terms.length - 1 && Array.from(term).length >= 2;
      return quote(term) + (isPrefix ? "*" : "");
    })
    .join(" AND ");
  return qualify(body, EXACT_COLUMNS);
}

export interface Measurement {
  name: string;
  coldMs: number;
  warmP50Ms: number;
  warmP95Ms: number;
}

export interface Result {
  corpus: string;
  prefixes: string;
  bytes: number;
  bytesPerMessage: number;
  queries: Measurement[];
}

/** The same query cases, in the same order, as the Swift harness's `measure`. */
function queryCases(dialog: string): [string, string][] {
  const scoped = (expression: string) => `{dialog_token} : ${quote(dialogToken(dialog))} AND (${expression})`;
  return [
    ["prefix-2", exactExpression("пр")],
    ["prefix-3", exactExpression("при")],
    ["prefix-4", exactExpression("прив")],
    ["prefix-6+", exactExpression("привет")],
    ["multi-term", exactExpression("привет при")],
    ["scoped", scoped(exactExpression("при"))],
    // Not in the Swift harness. Same prefix length class as prefix-6+, far fewer terms under it,
    // which separates "cost per vocabulary" from "cost per term under the prefix".
    ["selective-7", exactExpression("привет1")],
  ];
}

export function runBenchmark(corpus: Corpus, prefixes: string, options = { warmup: 5, samples: 40 }): Result {
  const directory = mkdtempSync(join(tmpdir(), "toj-search-bench-"));
  const path = join(directory, "bench.sqlite");
  try {
    const db = open(path);
    db.run(`
      CREATE VIRTUAL TABLE message_search USING fts5(
        exact, file_name, link_text,
        folded, file_name_folded, link_text_folded,
        dialog_token,
        tokenize = '${TOKENIZE}',
        ${prefixes ? `prefix = '${prefixes}',` : ""}
        content = '', contentless_delete = 1
      )`);
    db.run("INSERT INTO message_search(message_search, rank) VALUES('automerge', 8)");
    db.run("INSERT INTO message_search(message_search, rank) VALUES('deletemerge', 10)");

    const insert = db.prepare(`INSERT INTO message_search(
        rowid, exact, file_name, link_text, folded, file_name_folded, link_text_folded, dialog_token
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`);
    for (let chunk = 0; chunk < corpus.messages.length; chunk += 5_000) {
      db.transaction(() => {
        const upper = Math.min(chunk + 5_000, corpus.messages.length);
        for (let index = chunk; index < upper; index += 1) {
          const m = corpus.messages[index];
          insert.run(index + 1, exact(m.body), exact(m.fileName), exact(m.linkText),
            foldedForm(m.body), foldedForm(m.fileName), foldedForm(m.linkText), dialogToken(m.dialog));
        }
      })();
    }
    db.run("INSERT INTO message_search(message_search) VALUES('optimize')");

    // Read by position: reading these by column name gave NaN sizes under the keyed SQLCipher build.
    const pragma = (name: string) => Number(db.query(`PRAGMA ${name}`).values()[0][0]);
    const bytes = pragma("page_count") * pragma("page_size");

    const sql = "SELECT rowid FROM message_search WHERE message_search MATCH ? LIMIT 60";
    const queries: Measurement[] = [];
    for (const [name, expression] of queryCases(corpus.dialogs[0])) {
      // Cold: a fresh connection, so the page cache does not carry over.
      const cold = open(path, true);
      let started = performance.now();
      cold.query(sql).all(expression);
      const coldMs = performance.now() - started;
      cold.close();

      const statement = db.query(sql);
      for (let i = 0; i < options.warmup; i += 1) statement.all(expression);
      const samples: number[] = [];
      for (let i = 0; i < options.samples; i += 1) {
        started = performance.now();
        statement.all(expression);
        samples.push(performance.now() - started);
      }
      samples.sort((a, b) => a - b);
      queries.push({
        name,
        coldMs,
        warmP50Ms: samples[Math.floor(samples.length / 2)],
        warmP95Ms: samples[Math.floor(samples.length * 0.95)],
      });
    }
    db.close();
    return { corpus: corpus.name, prefixes, bytes, bytesPerMessage: Math.floor(bytes / corpus.messages.length), queries };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

/** Index terms a prefix query must visit when no prefix index of its length exists. */
export function termsUnderPrefix(corpus: Corpus, prefix: string): number {
  const seen = new Set<string>();
  for (const m of corpus.messages) {
    for (const text of [m.body, m.fileName, m.linkText]) {
      for (const token of tokens(exact(text))) if (token.startsWith(prefix)) seen.add(token);
    }
  }
  return seen.size;
}

/**
 * What `prefix='2'` costs over `prefix='2 3'` on one query case: the warm p95 gap in milliseconds
 * and the ratio between them. Only prefix-3, multi-term and scoped can differ, since `'2'` already
 * serves two-character prefixes and neither setting serves four or more.
 */
export function penalty(two: Result, twoThree: Result, name: string): { gapMs: number; ratio: number } {
  const a = two.queries.find((q) => q.name === name)!.warmP95Ms;
  const b = twoThree.queries.find((q) => q.name === name)!.warmP95Ms;
  return { gapMs: a - b, ratio: a / b };
}

export function report(results: Result[]): string {
  const lines: string[] = [];
  const names = results[0]?.queries.map((q) => q.name) ?? [];
  lines.push(`${"corpus/prefix".padEnd(22)}${"size".padStart(10)}${"B/msg".padStart(7)}` +
    names.map((n) => n.padStart(20)).join(""));
  for (const r of results) {
    lines.push(`${`${r.corpus} '${r.prefixes}'`.padEnd(22)}${`${(r.bytes / 1_048_576).toFixed(1)} MB`.padStart(10)}` +
      `${String(r.bytesPerMessage).padStart(7)}` +
      r.queries.map((q) => `${q.coldMs.toFixed(1)}/${q.warmP50Ms.toFixed(2)}/${q.warmP95Ms.toFixed(2)}`.padStart(20)).join(""));
  }
  lines.push("latency cells: cold / warm p50 / warm p95, ms");
  return lines.join("\n");
}
