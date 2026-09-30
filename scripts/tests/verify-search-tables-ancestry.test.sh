#!/usr/bin/env bash
# Regression: verify-search-tables.sh must fail closed when it cannot see real ancestry.
#
# The first version of that script skipped its version-bump check whenever the base ref was
# unresolvable, and CI checked out at depth 1 — so the check never ran, and its silence was
# indistinguishable from a pass. These cases reproduce the shapes that produced that silence and
# assert a non-zero exit for each.
#
# Runs against a scratch repository rather than this one, so it exercises the ancestry logic without
# needing the pod or a Unicode probe. The regeneration half of the script is covered by CI running
# it for real.

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/scripts/verify-search-tables.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0

expect_failure() {
  local name="$1"; shift
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    echo "FAIL: $name exited 0; it must fail closed" >&2
    echo "$output" | sed 's/^/      /' >&2
    failures=$((failures + 1))
  else
    echo "  ok  $name fails closed (exit $status)"
  fi
}

# A scratch repo standing in for the real one. The script exits at the pod check before touching
# git, so these cases assert the *entry* conditions; the ancestry cases below get a fake pod so
# execution reaches the git logic.
setup_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name Test
  mkdir -p "$dir/Pods/SQLCipher" "$dir/scripts" "$dir/Toj/Core/Search" "$dir/server/src"
  printf '#define SQLITE_VERSION "3.50.4"\n' > "$dir/Pods/SQLCipher/sqlite3.h"
  touch "$dir/Pods/SQLCipher/sqlite3.c"
  # Generators that echo the committed file, so the regeneration diff always passes and the test
  # isolates the ancestry behaviour.
  for pair in "generate-search-unicode-tables.py:Toj/Core/Search/SearchUnicodeTables.swift" \
              "generate-search-normalizer-vectors.py:server/src/search-normalizer-vectors.json" \
              "generate-search-unicode-tables-json.py:server/src/search-unicode-tables.json" \
              "generate-search-parity-vectors.py:server/src/search-parity-vectors.json" \
              "generate-search-manifest.py:Toj/Core/Search/search-tokenizer-manifest.json"; do
    printf '#!/usr/bin/env python3\nimport sys\nsys.stdout.write(open("%s").read())\n' \
      "${pair##*:}" > "$dir/scripts/${pair%%:*}"
  done
  cp "$SCRIPT" "$dir/scripts/verify-search-tables.sh"
  chmod +x "$dir/scripts/"*
  echo "// tables" > "$dir/Toj/Core/Search/SearchUnicodeTables.swift"
  echo '{"vectors":[]}' > "$dir/server/src/search-normalizer-vectors.json"
  echo '{"separatorRanges":[]}' > "$dir/server/src/search-unicode-tables.json"
  echo '{"vectors":[]}' > "$dir/server/src/search-parity-vectors.json"
  cat > "$dir/Toj/Core/Search/search-tokenizer-manifest.json" <<'JSON'
{
  "tokenizer": "unicode61 remove_diacritics 2",
  "normalizerVersion": 3,
  "digests": { "tables": "aaa", "maps": "bbb", "behavior": "ccc" }
}
JSON
  git -C "$dir" add -A
  git -C "$dir" commit -qm "base"
}

echo "==> verify-search-tables.sh ancestry regressions"

# 1. No base ref at all.
setup_repo "$WORK/norepo"
expect_failure "missing base argument" \
  bash -c "cd '$WORK/norepo' && ./scripts/verify-search-tables.sh"

# 2. Base ref that does not resolve — a ref CI expected but never fetched.
expect_failure "unresolvable base ref" \
  bash -c "cd '$WORK/norepo' && ./scripts/verify-search-tables.sh origin/main"

# 3. A depth-1 checkout: base and head both exist but share no ancestry, so `git merge-base`
#    has no answer and any diff against the base is meaningless.
setup_repo "$WORK/shallow"
(
  cd "$WORK/shallow"
  git checkout -q --orphan detached
  git commit -qm "unrelated head" --allow-empty
)
orphan_base="$(git -C "$WORK/shallow" rev-parse main 2>/dev/null || git -C "$WORK/shallow" rev-parse master)"
expect_failure "no merge base (depth-1 shape)" \
  bash -c "cd '$WORK/shallow' && ./scripts/verify-search-tables.sh '$orphan_base'"

# 4. Token-affecting change without a version bump must fail even with good ancestry.
setup_repo "$WORK/nobump"
(
  cd "$WORK/nobump"
  python3 - <<'PY'
import json
p = "Toj/Core/Search/search-tokenizer-manifest.json"
d = json.load(open(p))
d["digests"]["behavior"] = "changed"      # a token-affecting input moved
json.dump(d, open(p, "w"), indent=2)      # normalizerVersion deliberately left alone
PY
  git commit -qam "change digest without bumping version"
)
expect_failure "digest change without version bump" \
  bash -c "cd '$WORK/nobump' && ./scripts/verify-search-tables.sh HEAD~1"

# 5. A downgrade must fail. Equality was the only rejected case before, so 3 -> 2 sailed through
#    while leaving installs on an index built under rules the code no longer applies.
setup_repo "$WORK/downgrade"
(
  cd "$WORK/downgrade"
  python3 - <<'JSON_EOF'
import json
p = "Toj/Core/Search/search-tokenizer-manifest.json"
d = json.load(open(p))
d["digests"]["behavior"] = "changed"
d["normalizerVersion"] = 2                # base is 3
json.dump(d, open(p, "w"), indent=2)
JSON_EOF
  git commit -qam "downgrade version alongside a token-affecting change"
)
expect_failure "version downgrade 3 -> 2" \
  bash -c "cd '$WORK/downgrade' && ./scripts/verify-search-tables.sh HEAD~1"

# 6. A non-integer version cannot be ordered, so it must be rejected rather than compared as a
#    string — "10" < "9" lexically, and a float or word would silently satisfy any inequality test.
for bad in '"3.1"' '"three"' 'null'; do
  slug="$(printf '%s' "$bad" | tr -cd '[:alnum:]')"
  setup_repo "$WORK/nonnumeric$slug"
  (
    cd "$WORK/nonnumeric$slug"
    python3 - "$bad" <<'JSON_EOF'
import json, sys
p = "Toj/Core/Search/search-tokenizer-manifest.json"
d = json.load(open(p))
d["digests"]["behavior"] = "changed"
d["normalizerVersion"] = json.loads(sys.argv[1])
json.dump(d, open(p, "w"), indent=2)
JSON_EOF
    git commit -qam "non-integer version"
  )
  expect_failure "non-integer version $bad" \
    bash -c "cd '$WORK/nonnumeric$slug' && ./scripts/verify-search-tables.sh HEAD~1"
done

# 7. The same change *with* a forward bump must pass, or the gate is useless noise.
setup_repo "$WORK/bumped"
(
  cd "$WORK/bumped"
  python3 - <<'PY'
import json
p = "Toj/Core/Search/search-tokenizer-manifest.json"
d = json.load(open(p))
d["digests"]["behavior"] = "changed"
d["normalizerVersion"] = 4
json.dump(d, open(p, "w"), indent=2)
PY
  git commit -qam "change digest and bump version"
)
if (cd "$WORK/bumped" && ./scripts/verify-search-tables.sh HEAD~1 > /dev/null 2>&1); then
  echo "  ok  digest change with version bump 3 -> 4 passes"
else
  echo "FAIL: a properly bumped change was rejected" >&2
  (cd "$WORK/bumped" && ./scripts/verify-search-tables.sh HEAD~1 2>&1 | sed 's/^/      /') >&2
  failures=$((failures + 1))
fi

if [[ $failures -ne 0 ]]; then
  echo "==> $failures ancestry regression(s) failed" >&2
  exit 1
fi
echo "==> ancestry regressions passed"
