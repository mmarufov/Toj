import { describe, expect, test } from "bun:test";
import {
  buildCorpus,
  distinctBodyWords,
  engine,
  penalty,
  report,
  runBenchmark,
  SMALL_VOCABULARY,
  termsUnderPrefix,
  type Result,
} from "./search-benchmark";

// The 24-word corpus against the full one, with the harness held fixed. The corpus half always
// runs. The timing half builds four 100,000-message indexes (about 13 s) and runs only with
// TOJ_SEARCH_BENCHMARK=1, the same switch the Swift benchmark uses.

describe("search benchmark corpora", () => {
  const full = buildCorpus("full");
  const small = buildCorpus("small");

  test("the full corpus reproduces the Swift generator's cardinality", () => {
    // 40 stems x 20 suffixes x 20 variants = 16,000 words, of which 15,870 are ever drawn.
    expect(distinctBodyWords(full)).toBe(15_870);
    expect(full.messages).toHaveLength(100_000);
    expect(full.messages.filter((m) => m.fileName).length).toBe(14_286);
    expect(full.messages.filter((m) => m.linkText).length).toBe(10_000);
  });

  test("the small corpus is 24 words and changes nothing else", () => {
    expect(distinctBodyWords(small)).toBe(24);
    expect(Object.values(SMALL_VOCABULARY).flat()).toHaveLength(24);
    // Same generator, same draws: the message count, the dialog of every message and the body
    // length of every message all match the full corpus.
    expect(small.dialogs).toEqual(full.dialogs);
    expect(small.messages.map((m) => m.dialog)).toEqual(full.messages.map((m) => m.dialog));
    expect(small.messages.map((m) => m.body.split(" ").length)).toEqual(
      full.messages.map((m) => m.body.split(" ").length),
    );
  });

  test("what cardinality changes: index terms under each probe prefix", () => {
    // A prefix longer than any prefix index is answered by merging every term under it.
    expect(termsUnderPrefix(small, "при")).toBe(1);
    expect(termsUnderPrefix(full, "при")).toBe(400);
    // In the full corpus the Swift harness's three probe prefixes cover the same 400 terms, so
    // its flat latency across prefix lengths cannot say whether cost follows vocabulary size or
    // the terms under the prefix. A seven-character prefix covering 11 terms can.
    expect(termsUnderPrefix(full, "прив")).toBe(400);
    expect(termsUnderPrefix(full, "привет")).toBe(400);
    expect(termsUnderPrefix(full, "привет1")).toBe(11);
  });
});

describe.skipIf(process.env.TOJ_SEARCH_BENCHMARK !== "1")("search benchmark timing (TOJ_SEARCH_BENCHMARK=1)", () => {
  let results: Record<string, Result> = {};

  test("build and measure both corpora under prefix='2' and prefix='2 3'", () => {
    const corpora = { small: buildCorpus("small"), full: buildCorpus("full") };
    for (const [name, corpus] of Object.entries(corpora)) {
      for (const prefixes of ["2", "2 3"]) results[`${name} ${prefixes}`] = runBenchmark(corpus, prefixes);
    }
    console.log(`${engine()}\n${report(Object.values(results))}`);
  }, 120_000);

  test("the 24-word corpus still tells prefix='2' from prefix='2 3'", () => {
    // The docstring's claim, tested. It does not hold: the gap is about 1 ms, but it is a gap of
    // two orders of magnitude, not noise.
    const small = penalty(results["small 2"], results["small 2 3"], "prefix-3");
    expect(small.ratio).toBeGreaterThan(10);
    expect(small.gapMs).toBeGreaterThan(0.3);
  });

  test("the 24-word corpus understates what prefix='2' costs by several times", () => {
    for (const name of ["prefix-3", "multi-term", "scoped"]) {
      const small = penalty(results["small 2"], results["small 2 3"], name);
      const full = penalty(results["full 2"], results["full 2 3"], name);
      expect(full.gapMs).toBeGreaterThan(4 * small.gapMs);
    }
  });

  test("in the full corpus, cost follows the terms under the prefix, not the vocabulary", () => {
    // Same index, same vocabulary. 11 terms under the prefix against 400.
    const full = results["full 2"].queries;
    const selective = full.find((q) => q.name === "selective-7")!.warmP95Ms;
    const broad = full.find((q) => q.name === "prefix-6+")!.warmP95Ms;
    expect(selective * 5).toBeLessThan(broad);
  });
});
