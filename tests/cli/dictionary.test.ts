import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  dictionaryAdd,
  dictionaryList,
  dictionaryRemove,
} from "../../src/cli/dictionary.js";
import {
  DICTIONARY_VERSION,
  loadDictionary,
  mergeTerm,
  normalizeTerms,
  type DictionaryTerm,
} from "../../src/utils/dictionary.js";

let dir: string;
let file: string;
let stdout: string[];
let stderr: string[];
let stdoutSpy: ReturnType<typeof vi.spyOn>;
let stderrSpy: ReturnType<typeof vi.spyOn>;

function readFile(): Record<string, unknown> {
  return JSON.parse(readFileSync(file, "utf-8"));
}

beforeEach(() => {
  dir = mkdtempSync(path.join(tmpdir(), "nota-dictionary-cli-"));
  file = path.join(dir, "dictionary.json");
  stdout = [];
  stderr = [];
  stdoutSpy = vi.spyOn(process.stdout, "write").mockImplementation((chunk) => {
    stdout.push(String(chunk));
    return true;
  });
  stderrSpy = vi.spyOn(process.stderr, "write").mockImplementation((chunk) => {
    stderr.push(String(chunk));
    return true;
  });
});

afterEach(() => {
  stdoutSpy.mockRestore();
  stderrSpy.mockRestore();
  rmSync(dir, { recursive: true, force: true });
});

describe("dictionaryList", () => {
  it("prints only the header when the file is absent", () => {
    dictionaryList(file);
    expect(stdout.join("")).toBe("");
    // Header goes to stderr so stdout stays scriptable.
    expect(stderr.join("")).toContain("TERM\tSPOKEN\tSOURCE\tSTARRED\tADDED");
  });

  it("prints one tab-separated row per term", () => {
    dictionaryAdd("genc2rust", { spoken: ["gency to rust"], star: true }, file);
    dictionaryAdd("Nota", {}, file);
    stdout.length = 0;

    dictionaryList(file);
    const rows = stdout.join("").trimEnd().split("\n");
    expect(rows).toHaveLength(2);
    expect(rows[0]).toMatch(
      /^genc2rust\tgency to rust\tmanual\ttrue\t\d{4}-\d{2}-\d{2}T/,
    );
    // A term with no spoken forms still emits five columns.
    expect(rows[1].split("\t")).toHaveLength(5);
    expect(rows[1]).toMatch(/^Nota\t-\tmanual\tfalse\t/);
  });

  it("warns and prints nothing for a corrupt file", () => {
    writeFileSync(file, "{not json");
    dictionaryList(file);
    expect(stdout.join("")).toBe("");
    expect(stderr.join("")).toContain("is not valid JSON");
  });
});

describe("dictionaryAdd", () => {
  it("writes the v1 schema exactly", () => {
    dictionaryAdd("genc2rust", { spoken: ["gency to rust"] }, file);
    const parsed = readFile();
    expect(Object.keys(parsed).sort()).toEqual(["terms", "version"]);
    expect(parsed.version).toBe(DICTIONARY_VERSION);
    const terms = parsed.terms as DictionaryTerm[];
    expect(terms).toHaveLength(1);
    // Field names are the Swift/TS contract — see DictionaryStore.swift.
    expect(Object.keys(terms[0]).sort()).toEqual([
      "addedAt",
      "source",
      "spokenForms",
      "starred",
      "term",
    ]);
    expect(terms[0]).toMatchObject({
      term: "genc2rust",
      spokenForms: ["gency to rust"],
      source: "manual",
      starred: false,
    });
    expect(Date.parse(terms[0].addedAt)).not.toBeNaN();
  });

  it("dedupes case-insensitively, merging spoken forms and keeping addedAt", () => {
    dictionaryAdd("nota", { spoken: ["note uh"] }, file);
    const firstAddedAt = loadDictionary(file)[0].addedAt;

    dictionaryAdd("Nota", { spoken: ["knowta", "note uh"] }, file);
    const terms = loadDictionary(file);
    expect(terms).toHaveLength(1);
    // Last spelling wins; forms are unioned without duplicates.
    expect(terms[0].term).toBe("Nota");
    expect(terms[0].spokenForms).toEqual(["note uh", "knowta"]);
    expect(terms[0].addedAt).toBe(firstAddedAt);
    expect(stderr.join("")).toContain('Updated "Nota"');
  });

  it("keeps a star sticky across a later plain add", () => {
    dictionaryAdd("genc2rust", { star: true }, file);
    dictionaryAdd("genc2rust", {}, file);
    expect(loadDictionary(file)[0].starred).toBe(true);
  });

  it("rejects a blank term or one containing a tab", () => {
    expect(() => dictionaryAdd("   ", {}, file)).toThrow(
      /Invalid dictionary term/,
    );
    expect(() => dictionaryAdd("a\tb", {}, file)).toThrow(
      /Invalid dictionary term/,
    );
  });

  it("leaves no temp file behind (atomic write)", () => {
    dictionaryAdd("genc2rust", {}, file);
    expect(readdirSync(dir)).toEqual(["dictionary.json"]);
  });

  it("backs a corrupt file up before starting a new one", () => {
    // A truncated file still holds the user's terms; reading it as empty and
    // writing the new term over it would destroy all of them.
    const corrupt = '{"version":1,"terms":[{"term":"alpha"},{"term":"beta"}';
    writeFileSync(file, corrupt);

    dictionaryAdd("gamma", {}, file);

    expect(loadDictionary(file).map((t) => t.term)).toEqual(["gamma"]);
    const backups = readdirSync(dir).filter((name) =>
      name.startsWith("dictionary.json.corrupt-"),
    );
    expect(backups).toHaveLength(1);
    expect(readFileSync(path.join(dir, backups[0]), "utf-8")).toBe(corrupt);
    expect(stderr.join("")).toMatch(/backed it up to/);
  });

  it("keeps the good entries when only one is damaged", () => {
    // Same tolerance as the Swift decoder: one hand-edited typo must not read
    // as an empty dictionary and get overwritten.
    writeFileSync(
      file,
      JSON.stringify({
        version: 1,
        terms: [{ term: "alpha" }, { trem: "typo" }, "nope", { term: "beta" }],
      }),
    );

    dictionaryAdd("gamma", {}, file);

    expect(loadDictionary(file).map((t) => t.term)).toEqual([
      "alpha",
      "beta",
      "gamma",
    ]);
    expect(readdirSync(dir)).toEqual(["dictionary.json"]);
  });
});

describe("dictionaryRemove", () => {
  it("removes case-insensitively", () => {
    dictionaryAdd("genc2rust", {}, file);
    dictionaryAdd("Nota", {}, file);
    dictionaryRemove("GENC2RUST", file);

    const terms = loadDictionary(file);
    expect(terms.map((t) => t.term)).toEqual(["Nota"]);
    expect(stderr.join("")).toContain('Removed "GENC2RUST"');
  });

  it("throws when the term is absent (so the CLI exits non-zero)", () => {
    dictionaryAdd("Nota", {}, file);
    expect(() => dictionaryRemove("missing", file)).toThrow(
      /not in the dictionary/,
    );
    expect(loadDictionary(file)).toHaveLength(1);
  });

  it("backs a corrupt file up and reports the term as absent", () => {
    const corrupt = '{"version":1,"terms":[{"term":"alpha"}';
    writeFileSync(file, corrupt);

    expect(() => dictionaryRemove("alpha", file)).toThrow(
      /is not in the dictionary/,
    );
    // Nothing was written, so the corrupt original is still in place next to
    // its backup.
    expect(readFileSync(file, "utf-8")).toBe(corrupt);
    expect(
      readdirSync(dir).filter((name) =>
        name.startsWith("dictionary.json.corrupt-"),
      ),
    ).toHaveLength(1);
  });
});

describe("loadDictionary", () => {
  it("reads a file written by the Swift store", () => {
    // Byte-for-byte shape of DictionaryStore.save (sorted keys, pretty).
    writeFileSync(
      file,
      JSON.stringify(
        {
          terms: [
            {
              addedAt: "2026-07-26T10:00:00.000Z",
              source: "harvested",
              spokenForms: ["gency to rust"],
              starred: true,
              term: "genc2rust",
            },
          ],
          version: 1,
        },
        null,
        2,
      ),
    );
    expect(loadDictionary(file)).toEqual([
      {
        term: "genc2rust",
        spokenForms: ["gency to rust"],
        source: "harvested",
        starred: true,
        addedAt: "2026-07-26T10:00:00.000Z",
      },
    ]);
  });

  it("degrades unknown sources and missing optionals instead of failing", () => {
    writeFileSync(
      file,
      JSON.stringify({
        version: 1,
        terms: [
          { term: "keep", source: "from-the-future" },
          { notATerm: true },
          "nope",
        ],
      }),
    );
    const terms = loadDictionary(file);
    expect(terms).toHaveLength(1);
    expect(terms[0]).toMatchObject({
      term: "keep",
      source: "manual",
      starred: false,
      spokenForms: [],
    });
  });

  it("collapses duplicates present in a hand-edited file", () => {
    writeFileSync(
      file,
      JSON.stringify({
        version: 1,
        terms: [
          { term: "Nota", addedAt: "a" },
          { term: "nota", addedAt: "b" },
          { term: "   ", addedAt: "c" },
        ],
      }),
    );
    const terms = loadDictionary(file);
    expect(terms.map((t) => t.term)).toEqual(["Nota"]);
  });
});

describe("pure helpers", () => {
  const base: DictionaryTerm = {
    term: "Nota",
    spokenForms: ["note uh"],
    source: "manual",
    starred: false,
    addedAt: "2026-01-01T00:00:00.000Z",
  };

  it("mergeTerm appends an unrelated term", () => {
    const merged = mergeTerm(
      { ...base, term: "genc2rust", spokenForms: [] },
      [base],
    );
    expect(merged.map((t) => t.term)).toEqual(["Nota", "genc2rust"]);
  });

  it("mergeTerm promotes a learned source over manual", () => {
    const merged = mergeTerm({ ...base, source: "learned" }, [base]);
    expect(merged[0].source).toBe("learned");
  });

  it("normalizeTerms trims and dedupes spoken forms", () => {
    const [term] = normalizeTerms([
      { ...base, spokenForms: [" note uh ", "NOTE UH", ""] },
    ]);
    expect(term.spokenForms).toEqual(["note uh"]);
  });
});
