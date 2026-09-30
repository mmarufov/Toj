#!/usr/bin/env bash
# Scores the Bun search normalizer against a fresh probe of the locked SQLCipher tokenizer.
#
# verify-search-tables.sh answers "do the committed artifacts still match the pod?" with a diff.
# This answers "how much of the Bun implementation agrees with the engine, and where not?" with
# one verdict per Unicode scalar, reported by class and by block, plus a pass rate per vector
# shape. Exits non-zero unless everything agrees.
#
#     scripts/score-search-parity.sh [output-dir]
#
# Needs `pod install` (for Pods/SQLCipher/sqlite3.c) and bun. Writes oracle.tsv, verdicts.tsv
# (one line per scalar) and parity.json into output-dir, a temp directory by default.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$(mktemp -d)}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"  # absolute, because the scorer runs from server/

if ! command -v bun > /dev/null; then
  echo "FAIL: bun is not on PATH; the implementation being scored is the Bun one." >&2
  exit 2
fi

python3 "$ROOT/scripts/generate-search-unicode-tables.py" --oracle > "$OUT/oracle.tsv"
cd "$ROOT/server"
bun run scripts/score-search-parity.ts \
  --oracle "$OUT/oracle.tsv" --verdicts "$OUT/verdicts.tsv" --json "$OUT/parity.json"
echo "==> verdicts in $OUT"
