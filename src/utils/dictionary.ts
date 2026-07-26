import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

/**
 * Shared custom-vocabulary store, persisted at `~/.nota/dictionary.json`
 * (schema v1). The macOS app reads and writes the same file via
 * `macos/Nota/Dictation/DictionaryStore.swift`, so the field names, the
 * `version` value, and the case-insensitive uniqueness rule below must stay
 * in lockstep with that file.
 *
 *   { "version": 1,
 *     "terms": [ { "term": "genc2rust", "spokenForms": ["gency to rust"],
 *                  "source": "manual", "starred": false, "addedAt": "<ISO>" } ] }
 */
export interface DictionaryTerm {
  term: string;
  spokenForms: string[];
  /** Where the term came from. `starred` (not source) wins the L1 100-cap cut. */
  source: DictionaryTermSource;
  starred: boolean;
  addedAt: string;
}

export type DictionaryTermSource = "manual" | "learned" | "harvested";

export const DICTIONARY_SOURCES: DictionaryTermSource[] = [
  "manual",
  "learned",
  "harvested",
];

export const DICTIONARY_VERSION = 1;

/**
 * Resolve the dictionary file path. NOTA_DICTIONARY_FILE overrides the default
 * of ~/.nota/dictionary.json (used to keep tests hermetic).
 */
export function defaultDictionaryPath(): string {
  return (
    process.env.NOTA_DICTIONARY_FILE ??
    path.join(homedir(), ".nota", "dictionary.json")
  );
}

/** Case-insensitive identity key. Matches `DictionaryTerm.key` in Swift. */
export function key(term: string): string {
  return term.trim().toLowerCase();
}

type ParseOutcome =
  | { ok: true; terms: DictionaryTerm[] }
  | { ok: false; reason: string };

/** Read and shape-check the file. Shared by the two loaders below. */
function parseDictionary(filePath: string): ParseOutcome {
  let raw: string;
  try {
    raw = readFileSync(filePath, "utf-8");
  } catch (error) {
    return { ok: false, reason: `${filePath} could not be read (${error})` };
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { ok: false, reason: `${filePath} is not valid JSON` };
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { ok: false, reason: `${filePath} is not a JSON object` };
  }
  const rawTerms = (parsed as Record<string, unknown>).terms;
  // No `terms` key at all is an empty dictionary, not damage: there is nothing
  // to lose by writing over it.
  if (rawTerms === undefined) return { ok: true, terms: [] };
  if (!Array.isArray(rawTerms)) {
    return { ok: false, reason: `${filePath} has no valid "terms" array` };
  }
  return {
    ok: true,
    terms: normalizeTerms(rawTerms.map(coerceTerm).filter(isTerm)),
  };
}

/**
 * Load the dictionary terms. A missing file is an empty dictionary; an
 * unparseable or wrongly-shaped file warns on stderr and reads as empty so
 * dictation is never blocked by a bad dictionary.
 */
export function loadDictionary(
  filePath = defaultDictionaryPath(),
): DictionaryTerm[] {
  if (!existsSync(filePath)) return [];
  const outcome = parseDictionary(filePath);
  if (!outcome.ok) {
    process.stderr.write(`warning: ${outcome.reason}; ignoring it.\n`);
    return [];
  }
  return outcome.terms;
}

/**
 * The read half of a mutation. Unlike `loadDictionary`, a file that cannot be
 * parsed at all is copied aside to `<name>.corrupt-<epoch>` first: the
 * `writeDictionary` that follows replaces every term the parser could not read
 * with whatever is being added, so the bytes have to survive somewhere.
 * Mirrors `DictionaryStore.loadForMutation` in Swift.
 *
 * Per-entry damage never reaches here — `parseDictionary` drops the bad entry
 * and keeps the rest, exactly like the Swift decoder.
 */
export function loadDictionaryForMutation(
  filePath = defaultDictionaryPath(),
): DictionaryTerm[] {
  if (!existsSync(filePath)) return [];
  const outcome = parseDictionary(filePath);
  if (!outcome.ok) {
    quarantineDictionary(filePath, outcome.reason);
    return [];
  }
  return outcome.terms;
}

/**
 * Copy an unparseable dictionary to `<name>.corrupt-<epoch>` and warn.
 *
 * Copy, not rename: if the write that follows fails, the original is still
 * where it was. An existing backup from the same second is left alone rather
 * than overwritten with a second rescue attempt.
 */
function quarantineDictionary(filePath: string, reason: string): void {
  const backup = `${filePath}.corrupt-${Math.floor(Date.now() / 1000)}`;
  try {
    if (!existsSync(backup)) copyFileSync(filePath, backup);
  } catch (error) {
    throw new Error(
      `Refusing to overwrite the dictionary: ${reason}, and it could not be backed up (${error}). Fix or remove that file, then try again.`,
    );
  }
  process.stderr.write(
    `warning: ${reason}; backed it up to ${backup} and started a new one.\n`,
  );
}

/**
 * Atomically write the dictionary (temp file + rename), normalizing terms so a
 * duplicate or blank entry can never reach disk.
 */
export function writeDictionary(
  terms: DictionaryTerm[],
  filePath = defaultDictionaryPath(),
): void {
  const file = { version: DICTIONARY_VERSION, terms: normalizeTerms(terms) };
  mkdirSync(path.dirname(filePath), { recursive: true });
  const tmp = `${filePath}.tmp-${process.pid}-${Date.now()}`;
  writeFileSync(tmp, `${JSON.stringify(file, null, 2)}\n`, "utf-8");
  renameSync(tmp, filePath);
}

/**
 * Merge one term into a list under case-insensitive uniqueness: spoken forms
 * are unioned, `starred` is sticky once set, and the original `addedAt` is
 * kept. Pure — mirrors `DictionaryStore.merging` in Swift.
 */
export function mergeTerm(
  incoming: DictionaryTerm,
  terms: DictionaryTerm[],
): DictionaryTerm[] {
  const result = [...terms];
  const index = result.findIndex((t) => key(t.term) === key(incoming.term));
  if (index < 0) {
    result.push(incoming);
    return result;
  }
  const existing = result[index];
  result[index] = {
    ...existing,
    // Last spelling wins so `add "Nota"` can fix the casing of "nota".
    term: incoming.term,
    spokenForms: unionForms(existing.spokenForms, incoming.spokenForms),
    starred: existing.starred || incoming.starred,
    source: incoming.source === "manual" ? existing.source : incoming.source,
  };
  return result;
}

/** Drop blank terms and collapse case-insensitive duplicates (first wins). */
export function normalizeTerms(terms: DictionaryTerm[]): DictionaryTerm[] {
  const seen = new Set<string>();
  const result: DictionaryTerm[] = [];
  for (const term of terms) {
    const trimmed = term.term.trim();
    if (!trimmed || seen.has(key(trimmed))) continue;
    seen.add(key(trimmed));
    result.push({
      ...term,
      term: trimmed,
      spokenForms: unionForms([], term.spokenForms),
    });
  }
  return result;
}

/**
 * Validate a term for storage. Tabs and newlines are rejected because they
 * would corrupt the tab-separated `nota dictionary list` rows.
 */
export function validateTerm(term: string): string {
  const trimmed = term.trim();
  if (!trimmed || trimmed.includes("\t") || trimmed.includes("\n")) {
    throw new Error(
      `Invalid dictionary term "${term}": must be non-empty and free of tabs and newlines.`,
    );
  }
  return trimmed;
}

/** Union spoken forms case-insensitively, preserving first-seen order. */
export function unionForms(base: string[], extra: string[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const raw of [...base, ...extra]) {
    const form = raw.trim();
    if (!form || form.includes("\t") || form.includes("\n")) continue;
    if (seen.has(form.toLowerCase())) continue;
    seen.add(form.toLowerCase());
    result.push(form);
  }
  return result;
}

/**
 * Coerce one on-disk entry into a term. Tolerant like the Swift decoder: only
 * `term` is required, an unknown `source` degrades to "manual".
 */
function coerceTerm(raw: unknown): DictionaryTerm | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const entry = raw as Record<string, unknown>;
  if (typeof entry.term !== "string") return null;
  const spokenForms = Array.isArray(entry.spokenForms)
    ? entry.spokenForms.filter((f): f is string => typeof f === "string")
    : [];
  const source =
    typeof entry.source === "string" &&
    (DICTIONARY_SOURCES as string[]).includes(entry.source)
      ? (entry.source as DictionaryTermSource)
      : "manual";
  return {
    term: entry.term,
    spokenForms,
    source,
    starred: entry.starred === true,
    addedAt:
      typeof entry.addedAt === "string"
        ? entry.addedAt
        : new Date().toISOString(),
  };
}

function isTerm(term: DictionaryTerm | null): term is DictionaryTerm {
  return term !== null;
}
