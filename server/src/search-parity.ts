/**
 * Scores a normalizer implementation instead of diffing it.
 *
 * Two legs, both reporting a pass rate with a shape rather than a single pass/fail:
 *
 * - **Exhaustive.** One verdict per Unicode scalar, all 1,112,064 of them, against the raw output
 *   of the FTS5 probe (`generate-search-unicode-tables.py --oracle`). A scalar agrees when its
 *   class matches and, for token scalars, its fold matches too. The probe cannot observe a fold for
 *   a separator or an ignored scalar, since neither produces a token, so only their class is
 *   scored. Coverage is broken out by oracle class and by Unicode block, so a regression reads
 *   "99.9993%, 8 scalars in Cyrillic Extended-B" rather than "diff failed".
 * - **Vectors.** Whole-string cases with exact form, folded form and tokens, scored per shape.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";

export type OracleClass = "separator" | "token" | "ignored";
const CLASS_BY_CODE: OracleClass[] = ["separator", "token", "ignored"];
export const SCALAR_COUNT = 0x110000 - 0x800;

export interface ScalarImplementation {
  classify(scalar: number): OracleClass;
  baseFold(scalar: number): number;
}

/** The probe's view of every scalar. `classes[s]` is 0/1/2 as in the probe, 255 for surrogates. */
export interface Oracle {
  classes: Uint8Array;
  folds: Uint32Array;
}

export function parseOracle(tsv: string): Oracle {
  const classes = new Uint8Array(0x110000).fill(255);
  const folds = new Uint32Array(0x110000);
  let count = 0;
  for (const line of tsv.split("\n")) {
    if (line === "") continue;
    const [scalarText, classText, foldText] = line.split("\t");
    const scalar = Number(scalarText);
    const code = Number(classText);
    if (!(code in CLASS_BY_CODE) || classes[scalar] !== 255) {
      throw new Error(`malformed or repeated oracle line: ${JSON.stringify(line)}`);
    }
    classes[scalar] = code;
    folds[scalar] = foldText === "-" ? scalar : Number(foldText);
    count += 1;
  }
  // A truncated probe must not score as a pass over fewer scalars.
  if (count !== SCALAR_COUNT) throw new Error(`oracle covers ${count} scalars, expected ${SCALAR_COUNT}`);
  return { classes, folds };
}

export interface Block {
  low: number;
  high: number;
  name: string;
}

export const BLOCKS_FILE = join(import.meta.dir, "unicode-blocks-17.0.0.txt");

export function loadBlocks(path = BLOCKS_FILE): Block[] {
  const blocks: Block[] = [];
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const match = /^([0-9A-F]+)\.\.([0-9A-F]+); (.+)$/.exec(line.trim());
    if (match) blocks.push({ low: parseInt(match[1], 16), high: parseInt(match[2], 16), name: match[3] });
  }
  return blocks;
}

export function blockOf(blocks: Block[], scalar: number): string {
  let low = 0;
  let high = blocks.length - 1;
  while (low <= high) {
    const mid = (low + high) >> 1;
    if (scalar < blocks[mid].low) high = mid - 1;
    else if (scalar > blocks[mid].high) low = mid + 1;
    else return blocks[mid].name;
  }
  return "No_Block";
}

export interface Disagreement {
  scalar: number;
  block: string;
  expected: { class: OracleClass; fold: number | null };
  actual: { class: OracleClass; fold: number | null };
}

export interface Tally {
  total: number;
  agreed: number;
}

export interface ScalarScore extends Tally {
  byClass: Record<OracleClass, Tally>;
  byBlock: Map<string, Tally>;
  disagreements: Disagreement[];
}

/**
 * Scores every scalar. `onVerdict`, when given, receives one call per scalar in code point order,
 * which is how the CLI writes the per-scalar verdict file.
 */
export function scoreScalars(
  oracle: Oracle,
  impl: ScalarImplementation,
  blocks: Block[],
  onVerdict?: (scalar: number, agreed: boolean, expected: OracleClass, actual: OracleClass) => void,
): ScalarScore {
  const score: ScalarScore = {
    total: 0,
    agreed: 0,
    byClass: {
      token: { total: 0, agreed: 0 },
      separator: { total: 0, agreed: 0 },
      ignored: { total: 0, agreed: 0 },
    },
    byBlock: new Map(),
    disagreements: [],
  };
  let blockIndex = 0;
  for (let scalar = 0; scalar < 0x110000; scalar += 1) {
    const code = oracle.classes[scalar];
    if (code === 255) continue;
    const expected = CLASS_BY_CODE[code];
    const actual = impl.classify(scalar);
    const expectedFold = expected === "token" ? oracle.folds[scalar] : null;
    const actualFold = expected === "token" ? impl.baseFold(scalar) : null;
    const agreed = actual === expected && actualFold === expectedFold;

    // Blocks are sorted and scalars ascend, so the block cursor only moves forward.
    while (blockIndex < blocks.length && blocks[blockIndex].high < scalar) blockIndex += 1;
    const block =
      blockIndex < blocks.length && blocks[blockIndex].low <= scalar ? blocks[blockIndex].name : "No_Block";

    score.total += 1;
    score.byClass[expected].total += 1;
    const perBlock = score.byBlock.get(block) ?? { total: 0, agreed: 0 };
    perBlock.total += 1;
    if (agreed) {
      score.agreed += 1;
      score.byClass[expected].agreed += 1;
      perBlock.agreed += 1;
    } else {
      score.disagreements.push({
        scalar,
        block,
        expected: { class: expected, fold: expectedFold },
        actual: { class: actual, fold: actualFold },
      });
    }
    score.byBlock.set(block, perBlock);
    onVerdict?.(scalar, agreed, expected, actual);
  }
  return score;
}

/** Four decimals, and never "100.0000%" for anything short of every case. */
export function percent({ agreed, total }: Tally): string {
  if (total === 0) return "n/a";
  const value = (agreed / total) * 100;
  if (agreed < total && value.toFixed(4) === "100.0000") return "99.9999%";
  return `${value.toFixed(4)}%`;
}

const grouped = (value: number) => value.toLocaleString("en-US");
const hex = (scalar: number) => `U+${scalar.toString(16).toUpperCase().padStart(4, "0")}`;

/** The one line a regression prints: the score, and where the disagreements are. */
export function headline(score: ScalarScore): string {
  const head = `${percent(score)} (${grouped(score.agreed)}/${grouped(score.total)})`;
  const missed = score.total - score.agreed;
  if (missed === 0) return `${head}, every scalar agrees`;
  const blocks = [...score.byBlock].filter(([, tally]) => tally.agreed < tally.total);
  blocks.sort((a, b) => b[1].total - b[1].agreed - (a[1].total - a[1].agreed) || a[0].localeCompare(b[0]));
  const where = blocks.map(([name, tally]) => `${grouped(tally.total - tally.agreed)} in ${name}`);
  const noun = missed === 1 ? "scalar" : "scalars";
  if (blocks.length === 1) return `${head}, ${grouped(missed)} ${noun} in ${blocks[0][0]}`;
  return `${head}, ${grouped(missed)} ${noun}: ${where.slice(0, 5).join(", ")}${blocks.length > 5 ? ", ..." : ""}`;
}

export function scalarReport(score: ScalarScore, sample = 10): string {
  const lines = [`exhaustive: ${headline(score)}`, "", "by oracle class"];
  for (const kind of ["token", "separator", "ignored"] as const) {
    const tally = score.byClass[kind];
    lines.push(`  ${kind.padEnd(10)} ${grouped(tally.agreed).padStart(9)}/${grouped(tally.total).padEnd(9)} ${percent(tally)}`);
  }
  const failing = [...score.byBlock].filter(([, tally]) => tally.agreed < tally.total);
  lines.push("", `by Unicode block: ${score.byBlock.size - failing.length} of ${score.byBlock.size} blocks fully agree`);
  for (const [name, tally] of failing) {
    lines.push(`  ${name.padEnd(44)} ${grouped(tally.total - tally.agreed).padStart(7)} disagree of ${grouped(tally.total)}`);
  }
  if (score.disagreements.length > 0) {
    lines.push("", `first ${Math.min(sample, score.disagreements.length)} disagreements`);
    for (const d of score.disagreements.slice(0, sample)) {
      const fold = (value: number | null) => (value === null ? "" : ` -> ${hex(value)}`);
      lines.push(
        `  ${hex(d.scalar)} ${d.block}: expected ${d.expected.class}${fold(d.expected.fold)},` +
          ` got ${d.actual.class}${fold(d.actual.fold)}`,
      );
    }
  }
  return lines.join("\n");
}

// MARK: - Vectors

export interface Vector {
  shape?: string;
  input: string;
  exact: string;
  folded: string | null;
  tokens: string[];
}

export interface VectorImplementation {
  exact(text: string): string;
  folded(text: string): string | null;
  /** Tokens of the folded form, which is what the index stores and what every vector records. */
  tokens(text: string): string[];
}

export interface VectorScore extends Tally {
  byShape: Map<string, Tally>;
  failures: { shape: string; input: string; field: "exact" | "folded" | "tokens" }[];
}

export function scoreVectors(vectors: Vector[], impl: VectorImplementation): VectorScore {
  const score: VectorScore = { total: 0, agreed: 0, byShape: new Map(), failures: [] };
  for (const vector of vectors) {
    const shape = vector.shape ?? "hand-listed";
    let field: "exact" | "folded" | "tokens" | null = null;
    try {
      if (impl.exact(vector.input) !== vector.exact) field = "exact";
      else if (impl.folded(vector.input) !== vector.folded) field = "folded";
      else if (JSON.stringify(impl.tokens(vector.input)) !== JSON.stringify(vector.tokens)) field = "tokens";
    } catch {
      field = "exact";
    }
    const tally = score.byShape.get(shape) ?? { total: 0, agreed: 0 };
    tally.total += 1;
    score.total += 1;
    if (field === null) {
      tally.agreed += 1;
      score.agreed += 1;
    } else {
      score.failures.push({ shape, input: vector.input, field });
    }
    score.byShape.set(shape, tally);
  }
  return score;
}

export function vectorReport(title: string, score: VectorScore): string {
  const lines = [`${title}: ${percent(score)} (${grouped(score.agreed)}/${grouped(score.total)})`];
  for (const [shape, tally] of score.byShape) {
    lines.push(`  ${shape.padEnd(26)} ${String(tally.agreed).padStart(5)}/${String(tally.total).padEnd(5)} ${percent(tally)}`);
  }
  return lines.join("\n");
}
