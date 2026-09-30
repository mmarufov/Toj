#!/usr/bin/env python3
"""Regenerates server/src/search-parity-vectors.json: a few thousand generated normalizer vectors.

search-normalizer-vectors.json holds 32 hand-listed cases. An implementation can pass 32 cases by
memorising them, or by being right about the handful of scripts someone thought to type, and
`search.test.ts` shows both happening. These vectors are drawn instead, per scalar class and per
Unicode block, and crossed with the token-boundary shapes the hand list only enumerates once each.
Expected outputs come from the same Python reimplementation of the rules
(`generate-search-normalizer-vectors.py`'s `Rules`), never from the Swift or Bun code under test.

Sampling reads only the probe and the committed Blocks.txt, and never `unicodedata`, whose tables
follow the Python version. A different Python on CI must draw the same sample, or the regeneration
diff in verify-search-tables.sh would fail for a reason that has nothing to do with the tokenizer.

This file is deliberately not part of the manifest's `behavior` digest. The digest covers the
hand-listed vectors, which Swift also reads, and moving it would demand a normalizerVersion bump
and a reindex on every install for a change that alters no token.

    python3 scripts/generate-search-parity-vectors.py > server/src/search-parity-vectors.json
"""

import importlib.util
import json
import os
import random
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BLOCKS = os.path.join(ROOT, "server/src/unicode-blocks-17.0.0.txt")
SEED = 0x7015EED

SEPARATOR, TOKEN, IGNORED = 0, 1, 2
TAJIK_LOWER = [0x04B7, 0x0493, 0x04B3, 0x049B, 0x04E3, 0x04EF]
TAJIK_UPPER = [0x04B6, 0x0492, 0x04B2, 0x049A, 0x04E2, 0x04EE]


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, f"{name}.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def blocks():
    spans = []
    for line in open(BLOCKS, encoding="utf-8"):
        match = re.match(r"^([0-9A-F]+)\.\.([0-9A-F]+); (.+)$", line.strip())
        if match:
            spans.append((int(match.group(1), 16), int(match.group(2), 16), match.group(3)))
    return spans


def main():
    vectors_module = load("generate-search-normalizer-vectors")
    classes, folds = vectors_module.probe_tables()
    rules = vectors_module.Rules(classes, folds)
    rng = random.Random(SEED)

    def scalars(kind, low=0, high=0x10FFFF):
        return [s for s in range(low, high + 1) if classes.get(s) == kind]

    def pick(pool, count):
        return pool if len(pool) <= count else rng.sample(pool, count)

    token_letters = [ord(c) for c in "abcdefghijklmnopqrstuvwxyz"]
    words = {
        "russian": ["привет", "москва", "ёлка", "йогурт", "съезд", "дела", "Щука", "ЖУРНАЛ"],
        "tajik": ["тоҷикӣ", "ҷони", "Ғафуров", "қишлоқ", "ҳаво", "ӯро", "ДӮСТ", "ХОҲАР"],
        "latin": ["salom", "Café", "naïve", "Straße", "ÉGALITÉ", "Ångström", "chon", "résumé"],
        "digits": ["2024", "½", "²", "٣", "0x1F", "3.14"],
        "symbols": ["🇹🇯", "👋", "—", "«", "»", "@", "#", "…"],
    }
    separators_all = scalars(SEPARATOR)
    ignored_all = scalars(IGNORED)
    fold_sources = sorted(folds)

    cases = []  # (shape, input)

    def add(shape, text):
        cases.append((shape, text))

    # 1-2. Every block: token and separator scalars inside a word. The 32 hand-listed inputs
    #      touch 10 of the 346 blocks in Blocks.txt; this touches all 343 that hold scalars.
    for low, high, name in blocks():
        for s in pick(scalars(TOKEN, low, high), 3):
            add("token-per-block", "a" + chr(s) + "b")
        for s in pick(scalars(SEPARATOR, low, high), 3):
            add("separator-per-block", "a" + chr(s) + "b")
        if "Combining" in name:
            for s in pick(scalars(SEPARATOR, low, high), 6):
                add("unaccepted-combining-mark", rng.choice(["e", "а", "o"]) + chr(s) + "x")

    # 3. The 25 ignored diacritics, each at every position relative to a token.
    for s in ignored_all:
        mark = chr(s)
        other = chr(rng.choice(ignored_all))
        add("ignored-leading", mark + "ab")
        add("ignored-internal", "a" + mark + "b")
        add("ignored-trailing", "ab" + mark)
        add("ignored-run", "a" + mark + other + "b")
        add("ignored-after-separator", "a " + mark + "b")
        add("ignored-alone", mark)
        add("ignored-on-cyrillic", "тоҷ" + mark + "ик")

    # 4. Case and diacritic folds, drawn across the whole fold table rather than Latin-1 only.
    for s in pick(fold_sources, 400):
        prefix = "".join(chr(rng.choice(token_letters)) for _ in range(rng.randint(0, 3)))
        suffix = "".join(chr(rng.choice(token_letters)) for _ in range(rng.randint(0, 3)))
        add("fold", prefix + chr(s) + suffix)

    # 5. Tajik letters, upper and lower, where two folds compose: Ҷ -> ҷ (probed) -> ч (Tajik).
    for _ in range(200):
        letters = [rng.choice(TAJIK_LOWER + TAJIK_UPPER + [0x0430, 0x043E, 0x0418, 0x0425])
                   for _ in range(rng.randint(1, 8))]
        add("tajik", "".join(map(chr, letters)))

    # 6. Private use is a token class: it joins rather than splits.
    for low, high, name in blocks():
        if "Private Use" in name:
            for s in pick(scalars(TOKEN, low, high), 20):
                add("private-use", "abc" + chr(s) + "def")

    # 7. Code points in no block at all. unicode61 treats unassigned scalars as alphanumeric.
    in_block = [(low, high) for low, high, _ in blocks()]
    gaps = []
    cursor = 0
    for low, high in in_block:
        if cursor < low:
            gaps.append((cursor, low - 1))
        cursor = high + 1
    for low, high in gaps:
        for s in pick(scalars(TOKEN, low, min(high, low + 0xFFF)), 4):
            add("no-block", "x" + chr(s) + " " + chr(s))

    # 8. Astral scalars. A JavaScript port that walks UTF-16 code units splits each of these into
    #    two surrogates; this is the shape that catches it.
    astral_tokens = scalars(TOKEN, 0x10000)
    astral_separators = scalars(SEPARATOR, 0x10000)
    for _ in range(150):
        parts = [chr(rng.choice(astral_tokens if rng.random() < 0.6 else astral_separators))
                 for _ in range(rng.randint(1, 4))]
        add("astral", rng.choice(["", "a"]) + "".join(parts) + rng.choice(["", "b", " "]))

    # 9. The edges of the scalar space and of the surrogate hole.
    for s in [0x0000, 0x0009, 0x000A, 0x001F, 0x007F, 0x0085, 0x00A0, 0x00AD, 0x2028, 0x2029,
              0xD7FF, 0xE000, 0xFEFF, 0xFFFD, 0xFFFE, 0xFFFF, 0x10000, 0x1FFFF, 0x10FFFE, 0x10FFFF]:
        add("scalar-edge", "a" + chr(s) + "b")
        add("scalar-edge", chr(s))

    # 10. Real words from the three scripts the app sees, joined by drawn separators.
    for _ in range(400):
        pools = rng.sample(sorted(words), rng.randint(1, 3))
        parts = [rng.choice(words[pool]) for pool in pools for _ in range(rng.randint(1, 2))]
        glue = [chr(rng.choice(separators_all)) if rng.random() < 0.3 else " " for _ in parts]
        add("mixed-script", "".join(p + g for p, g in zip(parts, glue)).rstrip(" "))

    # 11. Unstructured strings from a weighted draw over every class.
    all_tokens = scalars(TOKEN)
    for _ in range(600):
        text = []
        for _ in range(rng.randint(1, 16)):
            roll = rng.random()
            if roll < 0.35:
                text.append(rng.choice(token_letters))
            elif roll < 0.55:
                text.append(rng.choice(all_tokens))
            elif roll < 0.70:
                text.append(rng.choice(separators_all))
            elif roll < 0.80:
                text.append(rng.choice(ignored_all))
            elif roll < 0.92:
                text.append(rng.choice(fold_sources))
            else:
                text.append(rng.choice(TAJIK_LOWER + TAJIK_UPPER))
        add("random-mix", "".join(map(chr, text)))

    seen, vectors = set(), []
    for shape, text in cases:
        if (shape, text) in seen:
            continue
        seen.add((shape, text))
        vectors.append({"shape": shape, **rules.vector(text)})

    counts = {}
    for vector in vectors:
        counts[vector["shape"]] = counts.get(vector["shape"], 0) + 1

    header = {
        "normalizerVersion": vectors_module.NORMALIZER_VERSION,
        "tokenize": vectors_module.TOKENIZE,
        "seed": SEED,
        "blocks": os.path.basename(BLOCKS),
        "note": "Generated by scripts/generate-search-parity-vectors.py. Expected values come "
                "from the Python reimplementation of the rules. 'folded' is null when it equals "
                "'exact'. One vector per line so a regeneration diff names the vectors that moved.",
        "counts": counts,
    }
    lines = [f"  {json.dumps(k)}: {json.dumps(v, ensure_ascii=False)}," for k, v in header.items()]
    body = ",\n".join("    " + json.dumps(v, ensure_ascii=False) for v in vectors)
    print("{\n" + "\n".join(lines) + '\n  "vectors": [\n' + body + "\n  ]\n}")


if __name__ == "__main__":
    main()
