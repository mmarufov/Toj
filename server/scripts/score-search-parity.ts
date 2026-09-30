/**
 * Scores the Bun normalizer against the FTS5 probe over every Unicode scalar, then against the
 * hand-listed and generated vectors. Exits non-zero unless every scalar and every vector agrees.
 *
 *   bun run scripts/score-search-parity.ts --oracle <probe.tsv> [--verdicts <out.tsv>] [--json <out.json>]
 *
 * `scripts/score-search-parity.sh` at the repository root produces the oracle and runs this.
 * The verdict file holds one line per scalar: codepoint, 1 or 0, expected class, actual class.
 */
import { createWriteStream, readFileSync, writeFileSync } from "node:fs";
import { baseFold, classify, exact, folded, foldedForm, tokens } from "../src/search";
import {
  headline,
  loadBlocks,
  parseOracle,
  scalarReport,
  scoreScalars,
  scoreVectors,
  vectorReport,
  type Vector,
} from "../src/search-parity";

function argument(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

const oraclePath = argument("--oracle");
if (!oraclePath) {
  console.error("usage: score-search-parity.ts --oracle <probe.tsv> [--verdicts <out.tsv>] [--json <out.json>]");
  process.exit(2);
}

const oracle = parseOracle(readFileSync(oraclePath, "utf8"));
const blocks = loadBlocks();

const verdictsPath = argument("--verdicts");
const verdicts = verdictsPath ? createWriteStream(verdictsPath) : null;
const started = performance.now();
const scalars = scoreScalars(oracle, { classify, baseFold }, blocks, verdicts
  ? (scalar, agreed, expected, actual) => verdicts.write(`${scalar}\t${agreed ? 1 : 0}\t${expected}\t${actual}\n`)
  : undefined);
const elapsed = performance.now() - started;
// process.exit below would otherwise drop whatever the stream has not flushed yet.
if (verdicts) await new Promise<void>((resolve) => verdicts.end(resolve));

const impl = { exact, folded, tokens: (text: string) => tokens(foldedForm(text)) };
const load = (file: string) =>
  (JSON.parse(readFileSync(new URL(`../src/${file}`, import.meta.url), "utf8")) as { vectors: Vector[] }).vectors;
const hand = scoreVectors(load("search-normalizer-vectors.json"), impl);
const generated = scoreVectors(load("search-parity-vectors.json"), impl);

console.log(scalarReport(scalars));
console.log(`  (${elapsed.toFixed(0)} ms)`);
console.log("");
console.log(vectorReport("hand-listed vectors", hand));
console.log("");
console.log(vectorReport("generated vectors", generated));

const jsonPath = argument("--json");
if (jsonPath) {
  writeFileSync(jsonPath, JSON.stringify({
    exhaustive: {
      headline: headline(scalars),
      total: scalars.total,
      agreed: scalars.agreed,
      byClass: scalars.byClass,
      blocks: scalars.byBlock.size,
      disagreeingBlocks: Object.fromEntries([...scalars.byBlock].filter(([, t]) => t.agreed < t.total)),
      disagreements: scalars.disagreements.slice(0, 100),
    },
    vectors: {
      handListed: { total: hand.total, agreed: hand.agreed },
      generated: {
        total: generated.total,
        agreed: generated.agreed,
        byShape: Object.fromEntries(generated.byShape),
      },
    },
  }, null, 2));
}

const clean = scalars.agreed === scalars.total && hand.agreed === hand.total && generated.agreed === generated.total;
process.exit(clean ? 0 : 1);
