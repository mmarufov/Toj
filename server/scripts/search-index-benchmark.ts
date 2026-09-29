/**
 * Runs the search index benchmark on the full and 24-word corpora under prefix='2' and '2 3'.
 * See src/search-benchmark.ts for what it reproduces and what it found.
 *
 *   bun run scripts/search-index-benchmark.ts [--runs N]
 *
 * To measure the engine the app ships, build SQLCipher from the pod and key it as the Swift
 * harness does:
 *
 *   cc -O2 -dynamiclib -o /tmp/libsqlcipher.dylib Pods/SQLCipher/sqlite3.c -I Pods/SQLCipher \
 *     -DSQLITE_ENABLE_FTS5 -DSQLITE_HAS_CODEC -DSQLCIPHER_CRYPTO_CC -DSQLITE_THREADSAFE=1 \
 *     -DSQLITE_TEMP_STORE=2 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_EXTRA_INIT=sqlcipher_extra_init \
 *     -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown -framework Security -framework Foundation
 *   TOJ_SQLITE_LIBRARY=/tmp/libsqlcipher.dylib TOJ_SQLCIPHER_PASSPHRASE=$(printf 'Z%.0s' {1..32}) \
 *     bun run scripts/search-index-benchmark.ts
 *
 * Cold numbers under a keyed SQLCipher include key derivation on the fresh connection.
 */
import { buildCorpus, engine, penalty, report, runBenchmark, type Result } from "../src/search-benchmark";

const runsIndex = process.argv.indexOf("--runs");
const runs = runsIndex === -1 ? 1 : Number(process.argv[runsIndex + 1]);

console.log(engine());
const corpora = [buildCorpus("small"), buildCorpus("full")];
for (let run = 1; run <= runs; run += 1) {
  const results: Record<string, Result> = {};
  for (const corpus of corpora) {
    for (const prefixes of ["2", "2 3"]) results[`${corpus.name} ${prefixes}`] = runBenchmark(corpus, prefixes);
  }
  console.log(`\nrun ${run}\n${report(Object.values(results))}`);
  for (const name of ["prefix-3", "multi-term", "scoped"]) {
    const small = penalty(results["small 2"], results["small 2 3"], name);
    const full = penalty(results["full 2"], results["full 2 3"], name);
    console.log(
      `${name.padEnd(11)} cost of '2' over '2 3', warm p95: small ${small.gapMs.toFixed(2)} ms (${small.ratio.toFixed(0)}x),` +
        ` full ${full.gapMs.toFixed(2)} ms (${full.ratio.toFixed(0)}x)`,
    );
  }
}
