import {
  defaultDictionaryPath,
  key,
  loadDictionary,
  loadDictionaryForMutation,
  mergeTerm,
  unionForms,
  validateTerm,
  writeDictionary,
  type DictionaryTerm,
} from "../utils/dictionary.js";

export interface DictionaryAddOptions {
  /** Spoken forms for the term; repeatable on the CLI (`--spoken`). */
  spoken?: string[];
  /** Star the term so it survives the downstream context cap. */
  star?: boolean;
}

/** `nota dictionary list` — one tab-separated row per term on stdout. */
export function dictionaryList(filePath = defaultDictionaryPath()): void {
  const terms = loadDictionary(filePath);
  process.stderr.write(`Custom dictionary (file: ${filePath}):\n`);
  process.stderr.write("TERM\tSPOKEN\tSOURCE\tSTARRED\tADDED\n");

  for (const term of terms) {
    const spoken = term.spokenForms.length ? term.spokenForms.join(",") : "-";
    process.stdout.write(
      `${term.term}\t${spoken}\t${term.source}\t${term.starred}\t${term.addedAt}\n`,
    );
  }
}

/** `nota dictionary add <term> [--spoken <form>...] [--star]` — add or merge. */
export function dictionaryAdd(
  rawTerm: string,
  options: DictionaryAddOptions = {},
  filePath = defaultDictionaryPath(),
): DictionaryTerm {
  const term = validateTerm(rawTerm);
  const terms = loadDictionaryForMutation(filePath);
  const existed = terms.some((t) => key(t.term) === key(term));

  const incoming: DictionaryTerm = {
    term,
    spokenForms: unionForms([], options.spoken ?? []),
    source: "manual",
    starred: options.star === true,
    addedAt: new Date().toISOString(),
  };
  const merged = mergeTerm(incoming, terms);
  writeDictionary(merged, filePath);

  const stored = merged.find((t) => key(t.term) === key(term)) ?? incoming;
  const spoken = stored.spokenForms.length
    ? ` (spoken: ${stored.spokenForms.join(", ")})`
    : "";
  const star = stored.starred ? " [starred]" : "";
  process.stderr.write(
    `${existed ? "Updated" : "Added"} "${stored.term}"${spoken}${star}\n`,
  );
  return stored;
}

/** `nota dictionary remove <term>` — case-insensitive; throws when absent. */
export function dictionaryRemove(
  rawTerm: string,
  filePath = defaultDictionaryPath(),
): void {
  const target = key(rawTerm);
  const terms = loadDictionaryForMutation(filePath);
  const remaining = terms.filter((t) => key(t.term) !== target);
  if (remaining.length === terms.length) {
    throw new Error(`Term "${rawTerm.trim()}" is not in the dictionary.`);
  }
  writeDictionary(remaining, filePath);
  process.stderr.write(`Removed "${rawTerm.trim()}"\n`);
}
