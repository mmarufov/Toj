/**
 * Bun port of `Toj/Core/Search/SearchTextNormalizer.swift`: classify, fold and tokenize.
 *
 * Local search and any future server search must tokenize identically, or the same query returns
 * different rows depending on which side answered it. This file is the second implementation that
 * `server/src/search-normalizer-vectors.json` was written for; `search.test.ts` holds it to those
 * vectors, to the manifest's three digests, and to a few thousand generated vectors.
 *
 * The same rule as the Swift side: nothing here calls `toLowerCase`, `normalize` or a `\p{...}`
 * regex. All three consult whatever ICU this runtime links, so they drift between Bun releases.
 * Classification and folding come only from `search-unicode-tables.json`, which is probed from
 * the SQLCipher FTS5 tokenizer the app ships.
 *
 * JavaScript strings are UTF-16, and the tables are keyed by scalar. Everything below walks
 * code points (`for...of`, `codePointAt`), never code units, or an astral scalar would be split
 * into two surrogates that each classify as a token character.
 */
import tables from "./search-unicode-tables.json";

export const NORMALIZER_VERSION = 3;

export type ScalarClass = "token" | "ignored" | "separator";

/** The six Tajik letters absent from a Russian keyboard, mapped to what users type instead. */
export const TAJIK_FOLDS: ReadonlyMap<number, number> = new Map([
  [0x04b7, 0x0447], // ҷ -> ч
  [0x0493, 0x0433], // ғ -> г
  [0x04b3, 0x0445], // ҳ -> х
  [0x049b, 0x043a], // қ -> к
  [0x04e3, 0x0438], // ӣ -> и
  [0x04ef, 0x0443], // ӯ -> у
]);

export const LATIN_DIGRAPHS: ReadonlyMap<string, number> = new Map([
  ["shch", 0x0449], // щ
  ["sch", 0x0449], // щ
  ["ch", 0x0447], // ч
  ["sh", 0x0448], // ш
  ["kh", 0x0445], // х
  ["zh", 0x0436], // ж
  ["ts", 0x0446], // ц
  ["gh", 0x0433], // ғ folds to г
  ["yu", 0x044e], // ю
  ["ya", 0x044f], // я
]);

export const LATIN_LETTERS: ReadonlyMap<number, number> = new Map(
  (
    [
      ["a", 0x0430], ["b", 0x0431], ["v", 0x0432], ["g", 0x0433], ["d", 0x0434], ["e", 0x0435],
      ["z", 0x0437], ["i", 0x0438], ["y", 0x0438], ["k", 0x043a], ["l", 0x043b], ["m", 0x043c],
      ["n", 0x043d], ["o", 0x043e], ["p", 0x043f], ["r", 0x0440], ["s", 0x0441], ["t", 0x0442],
      ["u", 0x0443], ["f", 0x0444], ["h", 0x0445], ["c", 0x0446], ["j", 0x0447], ["q", 0x043a],
      ["w", 0x0432], ["x", 0x0445],
    ] as const
  ).map(([latin, cyrillic]) => [latin.codePointAt(0)!, cyrillic]),
);

const SEPARATOR_RANGES = Uint32Array.from(tables.separatorRanges);
const IGNORED = new Set<number>(tables.ignoredScalars);
const FOLDS = new Map<number, number>();
for (let index = 0; index < tables.foldPairs.length; index += 2) {
  FOLDS.set(tables.foldPairs[index], tables.foldPairs[index + 1]);
}

function isSeparator(scalar: number): boolean {
  let low = 0;
  let high = SEPARATOR_RANGES.length / 2 - 1;
  while (low <= high) {
    const mid = (low + high) >> 1;
    if (scalar < SEPARATOR_RANGES[mid * 2]) high = mid - 1;
    else if (scalar > SEPARATOR_RANGES[mid * 2 + 1]) low = mid + 1;
    else return true;
  }
  return false;
}

export function classify(scalar: number): ScalarClass {
  if (IGNORED.has(scalar)) return "ignored";
  return isSeparator(scalar) ? "separator" : "token";
}

/** Case fold plus Latin diacritic removal for one scalar, straight from the probed table. */
export function baseFold(scalar: number): number {
  return FOLDS.get(scalar) ?? scalar;
}

export function tajikFold(scalar: number): number {
  return TAJIK_FOLDS.get(scalar) ?? scalar;
}

function mapScalars(text: string, map: (scalar: number) => number): string {
  let out = "";
  for (const char of text) out += String.fromCodePoint(map(char.codePointAt(0)!));
  return out;
}

/** Case folded with Latin diacritics removed, preserving scalar count. */
export function exact(text: string): string {
  return mapScalars(text, baseFold);
}

/** `exact` with the six Tajik letters collapsed onto their Russian lookalikes. */
export function foldedForm(text: string): string {
  return mapScalars(text, (scalar) => tajikFold(baseFold(scalar)));
}

/** The folded form, or `null` when identical to `exact`. */
export function folded(text: string): string | null {
  const exactForm = exact(text);
  const foldedText = mapScalars(exactForm, tajikFold);
  return foldedText === exactForm ? null : foldedText;
}

/**
 * The three-state walker. Calls `body` once per token with its text and the half-open *scalar*
 * offsets it spans. Ignored scalars neither extend nor end a token, and a token only opens on a
 * token scalar, so a leading diacritic cannot start one.
 */
export function forEachToken(
  text: string,
  body: (token: string, start: number, end: number) => void,
): void {
  let current = "";
  let start = 0;
  let end = 0;
  let offset = 0;
  for (const char of text) {
    switch (classify(char.codePointAt(0)!)) {
      case "token":
        if (current === "") start = offset;
        current += char;
        end = offset + 1;
        break;
      case "ignored":
        break;
      case "separator":
        if (current !== "") {
          body(current, start, end);
          current = "";
        }
    }
    offset += 1;
  }
  if (current !== "") body(current, start, end);
}

/** Splits normalized text into the tokens `unicode61` would produce. */
export function tokens(text: string): string[] {
  const out: string[] = [];
  forEachToken(text, (token) => out.push(token));
  return out;
}

const isLatinLetter = (scalar: number) =>
  (scalar >= 0x61 && scalar <= 0x7a) || (scalar >= 0x41 && scalar <= 0x5a);
const isCyrillicLetter = (scalar: number) => scalar >= 0x0400 && scalar <= 0x04ff;

/**
 * A Latin query's likely Cyrillic spelling, or `null` when the input is not plausibly
 * transliteration. Not scalar-preserving: digraphs collapse two scalars into one.
 */
export function cyrillicCandidate(text: string): string | null {
  const lowered = exact(text);
  const scalars = Array.from(lowered, (char) => char.codePointAt(0)!);
  if (!scalars.some(isLatinLetter) || scalars.some(isCyrillicLetter)) return null;

  let result = "";
  let index = 0;
  while (index < scalars.length) {
    let matched = false;
    // Longest digraph first: "shch" before "sh" before "s".
    for (let length = Math.min(4, scalars.length - index); length >= 2; length -= 1) {
      const replacement = LATIN_DIGRAPHS.get(String.fromCodePoint(...scalars.slice(index, index + length)));
      if (replacement !== undefined) {
        result += String.fromCodePoint(replacement);
        index += length;
        matched = true;
        break;
      }
    }
    if (matched) continue;
    result += String.fromCodePoint(LATIN_LETTERS.get(scalars[index]) ?? scalars[index]);
    index += 1;
  }
  return result === lowered ? null : result;
}
