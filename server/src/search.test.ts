import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  baseFold,
  classify,
  cyrillicCandidate,
  exact,
  folded,
  foldedForm,
  forEachToken,
  LATIN_DIGRAPHS,
  LATIN_LETTERS,
  NORMALIZER_VERSION,
  TAJIK_FOLDS,
  tajikFold,
  tokens,
  type ScalarClass,
} from "./search";
import tables from "./search-unicode-tables.json";
import {
  headline,
  loadBlocks,
  parseOracle,
  percent,
  SCALAR_COUNT,
  scalarReport,
  scoreScalars,
  scoreVectors,
  vectorReport,
  type Oracle,
  type ScalarImplementation,
  type Vector,
  type VectorImplementation,
} from "./search-parity";

// The contract this file enforces was written before it existed:
// scripts/generate-search-normalizer-vectors.py says "`server/src/search.test.ts` will assert the
// same of Bun". Swift reads the same vectors and the same manifest in SearchTextNormalizerTests.

const ROOT = join(import.meta.dir, "..", "..");
const manifest = JSON.parse(
  readFileSync(join(ROOT, "Toj/Core/Search/search-tokenizer-manifest.json"), "utf8"),
) as { tokenizer: string; normalizerVersion: number; digests: { tables: string; maps: string; behavior: string } };
const handVectors = (
  JSON.parse(readFileSync(join(import.meta.dir, "search-normalizer-vectors.json"), "utf8")) as { vectors: Vector[] }
).vectors;
const generatedFile = JSON.parse(readFileSync(join(import.meta.dir, "search-parity-vectors.json"), "utf8")) as {
  normalizerVersion: number;
  counts: Record<string, number>;
  vectors: Vector[];
};

const bun: VectorImplementation = { exact, folded, tokens: (text) => tokens(foldedForm(text)) };
const scalarsOf = (text: string) => Array.from(text, (char) => char.codePointAt(0)!);

// Serialization matches scripts/generate-search-manifest.py byte for byte.
const RECORD = Buffer.from([0x1d]);
const FIELD = Buffer.from([0x1e]);
const ITEM = Buffer.from([0x1f]);
const u32 = (value: number) => {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32LE(value);
  return buffer;
};
const byUtf8 = (a: string, b: string) => Buffer.compare(Buffer.from(a), Buffer.from(b));

describe("search normalizer: Bun against the pinned manifest", () => {
  test("configuration and version agree with the manifest Swift also reads", () => {
    expect(tables.tokenize).toBe(manifest.tokenizer);
    expect(NORMALIZER_VERSION).toBe(manifest.normalizerVersion);
    expect(generatedFile.normalizerVersion).toBe(manifest.normalizerVersion);
  });

  test("tables digest: the Bun copy of the probe is the Swift copy", () => {
    const hash = createHash("sha256");
    for (const name of ["separatorRanges", "ignoredScalars", "foldPairs"] as const) {
      const values = tables[name];
      hash.update(`${name}:${values.length}`);
      for (const value of values) hash.update(u32(value));
    }
    expect(hash.digest("hex")).toBe(manifest.digests.tables);
  });

  test("maps digest: Tajik folds and transliteration tables match Swift's literals", () => {
    const hash = createHash("sha256");
    const feed = (name: string, pairs: [string, number][]) => {
      pairs.sort((a, b) => byUtf8(a[0], b[0]));
      hash.update(`${name}:${pairs.length}`);
      for (const [key, value] of pairs) hash.update(Buffer.concat([Buffer.from(key), ITEM, u32(value), FIELD]));
    };
    feed("tajikFolds", [...TAJIK_FOLDS].map(([k, v]) => [String.fromCodePoint(k), v]));
    feed("latinDigraphs", [...LATIN_DIGRAPHS]);
    feed("latinLetters", [...LATIN_LETTERS].map(([k, v]) => [String.fromCodePoint(k), v]));
    expect(hash.digest("hex")).toBe(manifest.digests.maps);
  });

  test("behavior digest: computed from Bun's own output, not read back from the fixture", () => {
    const hash = createHash("sha256");
    for (const vector of [...handVectors].sort((a, b) => byUtf8(a.input, b.input))) {
      hash.update(Buffer.concat([Buffer.from(vector.input), ITEM]));
      hash.update(Buffer.concat([Buffer.from(exact(vector.input)), ITEM]));
      hash.update(Buffer.concat([Buffer.from(folded(vector.input) ?? ""), ITEM]));
      hash.update(Buffer.from(tokens(foldedForm(vector.input)).join("\u001e")));
      hash.update(RECORD);
    }
    expect(hash.digest("hex")).toBe(manifest.digests.behavior);
  });

  test("every hand-listed vector, field by field", () => {
    expect(handVectors).toHaveLength(32);
    for (const vector of handVectors) {
      expect({ input: vector.input, exact: exact(vector.input) }).toEqual({ input: vector.input, exact: vector.exact });
      expect(folded(vector.input)).toBe(vector.folded);
      expect(tokens(foldedForm(vector.input))).toEqual(vector.tokens);
    }
  });

  test("generated vectors: every shape passes, and the report says so per shape", () => {
    const score = scoreVectors(generatedFile.vectors, bun);
    console.log(vectorReport("generated vectors", score));
    expect(score.total).toBeGreaterThanOrEqual(3000);
    expect(Object.fromEntries(score.byShape)).toEqual(
      Object.fromEntries(Object.entries(generatedFile.counts).map(([shape, n]) => [shape, { total: n, agreed: n }])),
    );
    expect(score.failures).toEqual([]);
  });
});

describe("search normalizer: exhaustive properties over all 1,112,064 scalars", () => {
  test("class counts expand to exactly what the probe reported", () => {
    const counts: Record<ScalarClass, number> = { token: 0, separator: 0, ignored: 0 };
    for (let scalar = 0; scalar < 0x110000; scalar += 1) {
      if (scalar >= 0xd800 && scalar <= 0xdfff) continue;
      counts[classify(scalar)] += 1;
    }
    expect(counts).toEqual({ token: 1_104_042, separator: 7_997, ignored: 25 });
    expect(tables.counts).toEqual({
      scalars: 1_112_064,
      token: 1_104_042,
      separator: 7_997,
      ignored: 25,
      separatorRanges: 410,
      folds: 1_274,
    });
  });

  test("folding is scalar-preserving, idempotent, and never moves a token boundary", () => {
    let folds = 0;
    for (let scalar = 0; scalar < 0x110000; scalar += 1) {
      if (scalar >= 0xd800 && scalar <= 0xdfff) continue;
      const once = tajikFold(baseFold(scalar));
      if (once !== scalar) folds += 1;
      if (once > 0x10ffff || (once >= 0xd800 && once <= 0xdfff)) throw new Error(`U+${scalar.toString(16)} folds to a non-scalar`);
      if (tajikFold(baseFold(once)) !== once) throw new Error(`fold of U+${scalar.toString(16)} is not idempotent`);
      if (once !== scalar && (classify(scalar) !== "token" || classify(once) !== "token")) {
        throw new Error(`U+${scalar.toString(16)} folds across a class boundary`);
      }
    }
    // 1,274 probed folds plus the six Tajik letters. Their capitals are already in the probed set.
    expect(folds).toBe(1_274 + 6);
  });
});

describe("search normalizer: behaviour a UTF-16 runtime gets wrong by default", () => {
  test("an astral token scalar is one scalar of one token, not two surrogates", () => {
    const text = "a\u{1D400}b \u{20000}";
    const spans: [string, number, number][] = [];
    forEachToken(foldedForm(text), (token, start, end) => spans.push([token, start, end]));
    expect(spans).toEqual([
      ["a\u{1D400}b", 0, 3],
      ["\u{20000}", 4, 5],
    ]);
    expect(scalarsOf(exact(text))).toHaveLength(scalarsOf(text).length);
  });

  test("offsets count scalars and skip ignored diacritics without ending the token", () => {
    const spans: [string, number, number][] = [];
    forEachToken("égalité x", (token, start, end) => spans.push([token, start, end]));
    expect(spans).toEqual([
      ["egalite", 0, 8],
      ["x", 10, 11],
    ]);
  });

  test("transliteration matches the Swift rules", () => {
    expect(cyrillicCandidate("salom")).toBe("салом");
    expect(cyrillicCandidate("chon")).toBe("чон");
    expect(cyrillicCandidate("shchi")).toBe("щи");
    expect(cyrillicCandidate("Ghafurov")).toBe("гафуров");
    expect(cyrillicCandidate("салом")).toBeNull();
    expect(cyrillicCandidate("2024")).toBeNull();
  });
});

// A synthetic oracle built from the committed tables, so the scorer can be tested on Linux CI
// without the pod. The real oracle is the probe; scripts/score-search-parity.sh scores against it.
function syntheticOracle(): Oracle {
  const classes = new Uint8Array(0x110000).fill(255);
  const folds = new Uint32Array(0x110000);
  const code = { separator: 0, token: 1, ignored: 2 } as const;
  for (let scalar = 0; scalar < 0x110000; scalar += 1) {
    if (scalar >= 0xd800 && scalar <= 0xdfff) continue;
    classes[scalar] = code[classify(scalar)];
    folds[scalar] = baseFold(scalar);
  }
  return { classes, folds };
}

describe("parity scorer: a regression reads as a score with a location", () => {
  const oracle = syntheticOracle();
  const blocks = loadBlocks();
  const bunScalars: ScalarImplementation = { classify, baseFold };

  test("the unmodified implementation scores 100% over every scalar", () => {
    const score = scoreScalars(oracle, bunScalars, blocks);
    expect(score.total).toBe(SCALAR_COUNT);
    expect(headline(score)).toBe("100.0000% (1,112,064/1,112,064), every scalar agrees");
    expect(score.byClass).toEqual({
      token: { total: 1_104_042, agreed: 1_104_042 },
      separator: { total: 7_997, agreed: 7_997 },
      ignored: { total: 25, agreed: 25 },
    });
    // 343 non-surrogate blocks from Blocks.txt 17.0.0, plus code points in no block.
    expect(score.byBlock.size).toBe(344);
  });

  test("eight misclassified letters in one block", () => {
    const broken = new Set([0xa640, 0xa641, 0xa642, 0xa643, 0xa650, 0xa651, 0xa660, 0xa661]);
    const score = scoreScalars(oracle, {
      classify: (s) => (broken.has(s) ? "separator" : classify(s)),
      baseFold,
    }, blocks);
    expect(headline(score)).toBe("99.9993% (1,112,056/1,112,064), 8 scalars in Cyrillic Extended-B");
    expect(score.byClass.token).toEqual({ total: 1_104_042, agreed: 1_104_034 });
    expect(score.byClass.separator.agreed).toBe(7_997);
    expect(scalarReport(score)).toContain("U+A640 Cyrillic Extended-B: expected token -> U+A641, got separator");
  });

  test("a wrong fold on a correctly classified scalar is still a disagreement", () => {
    const score = scoreScalars(oracle, {
      classify,
      baseFold: (s) => (s === 0x00c9 ? 0x00e9 : baseFold(s)), // É -> é, keeping the accent
    }, blocks);
    expect(headline(score)).toBe("99.9999% (1,112,063/1,112,064), 1 scalar in Latin-1 Supplement");
  });

  test("the v2 bug, ignored diacritics treated as separators, is one class in one block", () => {
    const score = scoreScalars(oracle, {
      classify: (s) => (classify(s) === "ignored" ? "separator" : classify(s)),
      baseFold,
    }, blocks);
    expect(score.byClass.ignored).toEqual({ total: 25, agreed: 0 });
    expect(score.total - score.agreed).toBe(25);
    expect(headline(score)).toBe("99.9978% (1,112,039/1,112,064), 25 scalars in Combining Diacritical Marks");
  });

  test("a truncated oracle is refused rather than scored over fewer scalars", () => {
    expect(() => parseOracle("65\t1\t97\n")).toThrow("oracle covers 1 scalars, expected 1112064");
    expect(percent({ agreed: 1_112_063, total: 1_112_064 })).toBe("99.9999%");
  });
});

// Implementations that are wrong in ways someone could plausibly ship. Each is scored on the 32
// hand-listed vectors and on the generated set, to show what the generated set is for.
const gamed: Record<string, VectorImplementation> = (() => {
  const memory = new Map(handVectors.map((v) => [v.input, v]));
  const tajik = (text: string) => String.fromCodePoint(...scalarsOf(text).map(tajikFold));
  const foldedOrNull = (exactForm: string) => (tajik(exactForm) === exactForm ? null : tajik(exactForm));

  // Remembers the 32 answers, and falls back to lower-casing ASCII and splitting on spaces.
  const memoriser: VectorImplementation = {
    exact: (t) => memory.get(t)?.exact ?? t.replace(/[A-Z]/g, (c) => c.toLowerCase()),
    folded: (t) => (memory.has(t) ? memory.get(t)!.folded : null),
    tokens: (t) => memory.get(t)?.tokens ?? t.split(" ").filter(Boolean),
  };

  // What the version-2 normalizer did: the 25 ignored diacritics ended the token.
  const v2: VectorImplementation = {
    exact,
    folded,
    tokens: (t) => {
      const out: string[] = [];
      let current = "";
      for (const char of foldedForm(t)) {
        if (classify(char.codePointAt(0)!) === "token") current += char;
        else if (current) (out.push(current), (current = ""));
      }
      if (current) out.push(current);
      return out;
    },
  };

  // The port someone writes without the tables: runtime case mapping, NFD and \p{...} classes.
  const icuExact = (t: string) => t.toLowerCase().normalize("NFD").replace(/\p{Mn}/gu, "").normalize("NFC");
  const icu: VectorImplementation = {
    exact: icuExact,
    folded: (t) => foldedOrNull(icuExact(t)),
    tokens: (t) => tajik(icuExact(t)).split(/[^\p{L}\p{N}]+/u).filter(Boolean),
  };

  // The right tables, walked by UTF-16 code unit instead of by scalar.
  const codeUnits: VectorImplementation = {
    exact,
    folded,
    tokens: (t) => {
      const out: string[] = [];
      let current = "";
      const form = foldedForm(t);
      for (let i = 0; i < form.length; i += 1) {
        const kind = classify(form.charCodeAt(i));
        if (kind === "token") current += form[i];
        else if (kind === "separator" && current) (out.push(current), (current = ""));
      }
      if (current) out.push(current);
      return out;
    },
  };

  return { memoriser, v2, icu, codeUnits };
})();

describe("the generated set cannot be passed by memorising the hand-listed one", () => {
  const scores = Object.fromEntries(
    Object.entries(gamed).map(([name, impl]) => [
      name,
      { hand: scoreVectors(handVectors, impl), generated: scoreVectors(generatedFile.vectors, impl) },
    ]),
  );

  test("report", () => {
    const lines = ["implementation   hand-listed (32)       generated (" + generatedFile.vectors.length + ")"];
    for (const [name, { hand, generated }] of Object.entries(scores)) {
      lines.push(`${name.padEnd(16)} ${percent(hand).padStart(9)} ${String(hand.agreed).padStart(4)}/32   ` +
        `${percent(generated).padStart(9)} ${String(generated.agreed).padStart(5)}/${generated.total}`);
    }
    console.log(lines.join("\n"));
  });

  test("a memoriser is perfect on the 32 and fails most of the generated set", () => {
    expect(scores.memoriser.hand.agreed).toBe(32);
    expect(scores.memoriser.generated.agreed / scores.memoriser.generated.total).toBeLessThan(0.5);
  });

  test("the v2 walker is caught by every ignored-diacritic shape that has a token on both sides", () => {
    const byShape = scores.v2.generated.byShape;
    for (const shape of ["ignored-internal", "ignored-run", "ignored-on-cyrillic"]) {
      expect(byShape.get(shape)).toEqual({ total: 25, agreed: 0 });
    }
  });

  test("a runtime-ICU port fails in blocks the hand list never visits", () => {
    const failingShapes = new Set(scores.icu.generated.failures.map((f) => f.shape));
    expect(scores.icu.generated.agreed).toBeLessThan(scores.icu.generated.total);
    expect(failingShapes.has("token-per-block")).toBe(true);
  });

  test("a code-unit walker is caught by one hand-listed vector and by the astral shape", () => {
    // The flag emoji in "🇹🇯 salom 👋" is the only astral input in the hand list. Delete that one
    // case and the hand list would pass a port that splits every astral scalar in two.
    expect(scores.codeUnits.hand.failures.map((f) => f.input)).toEqual(["🇹🇯 salom 👋"]);
    const astral = scores.codeUnits.generated.byShape.get("astral")!;
    expect(astral.agreed / astral.total).toBeLessThan(0.5);
  });
});
