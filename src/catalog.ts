/**
 * Model catalog — the self-updating source of summary-model ids, labels, and
 * pricing. On CLI startup, if the local cache at `~/.nota/models-catalog.json`
 * is missing or stale (>7 days), background-fetches the upstream catalog at
 * https://models.dev/api.json, filters through the allowlist, validates, and
 * atomically writes a few-KB cache. A baked snapshot shipped in-repo is the
 * no-cache fallback.
 *
 * This module replaces the curated summary-model entries in `src/registry.ts`.
 * Transcription models are never sourced from the catalog.
 *
 * @see .eval-loop/registry-refresh/ for the full research record
 */

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

import {
  deriveProvider,
  resolveExecutionKind,
  type ExecutionKind,
} from "./model-id.js";
import { CLI_ENGINE_MODELS } from "./cli-engines.js";
import { OPENROUTER_MODELS } from "./openrouter.js";

// ── Types ────────────────────────────────────────────────────────────────────

export interface CostTier {
  thresholdTokens: number;
  input: number;
  output: number;
  cacheRead?: number;
}

export interface CatalogCost {
  input: number;
  output: number;
  cacheRead?: number;
  tiers: CostTier[];
}

export interface CatalogModelLimit {
  context: number;
  output?: number;
  input?: number;
}

/**
 * Where an entry came from — see {@link mergeCurated}. `auto` is the weekly
 * models.dev admit; `curated` and `cli` are both hand-written in code and merged
 * at read time, and they are kept apart only so a reader of `nota models list`
 * can tell an HTTP shortlist entry from a local subprocess engine at a glance.
 */
export type CatalogEntryOrigin = "auto" | "curated" | "cli";

export interface CatalogModelEntry {
  id: string;
  provider: string;
  label: string;
  task: "summary";
  /**
   * Absent when Nota stores no pricing for this model. Absent is not zero:
   * callers must print {@link CatalogModelEntry.costNote} rather than "$0.00".
   */
  cost?: CatalogCost;
  /** What to print instead of a dollar figure when `cost` is absent. */
  costNote?: string;
  limit: CatalogModelLimit;
  /** How the model runs. Absent means `http` (everything auto-admitted). */
  execution?: ExecutionKind;
  /** `auto` (weekly allowlist) or `curated` (hand-picked). Absent means auto. */
  origin?: CatalogEntryOrigin;
}

export interface CatalogCache {
  schemaVersion: number;
  source: string;
  etag: string;
  fetchedAt: string;
  costUnit: "usd_per_1m_tokens";
  /**
   * Version of the allowlist/mapping code that produced this cache. A cache
   * written by an older filter must not be revalidated via etag: a 304 would
   * re-bless entries filtered by buggy/outdated predicates. Absent (legacy
   * caches) counts as stale.
   */
  filterVersion?: number;
  models: CatalogModelEntry[];
}

/** Bump whenever filterCatalog's predicates or field mapping change. */
export const FILTER_VERSION = 2;

// ── Cache / baked paths ──────────────────────────────────────────────────────

const CACHE_BASENAME = "models-catalog.json";
const CACHE_DIR = path.join(homedir(), ".nota");
const CACHE_PATH = path.join(CACHE_DIR, CACHE_BASENAME);

/** 7 days in ms. */
const CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1000;


// ── Allowlist predicates ─────────────────────────────────────────────────────

interface RawModelEntry {
  id: string;
  family?: string;
  status?: string;
  modalities?: {
    input?: string[];
    output?: string[];
  };
  tool_call?: boolean;
  name?: string;
  cost: {
    input: number;
    output: number;
    cache_read?: number;
    tiers?: Array<{
      input: number;
      output: number;
      cache_read?: number;
      tier: { type: string; size: number };
    }>;
  };
  limit?: {
    context: number;
    output?: number;
    input?: number;
  };
}

interface RawProviderData {
  models: Record<string, RawModelEntry>;
}

interface RawCatalog {
  openai?: RawProviderData;
  google?: RawProviderData;
  deepseek?: RawProviderData;
}


/** Structural gate: a chat text model outputs text, takes no audio input, and supports tool calls. */
function isChatTextModel(m: RawModelEntry): boolean {
  const out = m.modalities?.output ?? [];
  if (out.length !== 1 || out[0] !== "text") return false;
  const input = m.modalities?.input ?? [];
  if (input.includes("audio")) return false;
  return m.tool_call === true;
}

/**
 * OpenAI: mainline gpt-* chat models, generation 5 and later. The floor
 * matters: models.dev still lists gpt-4 / gpt-4.1(-mini), which match a bare
 * `gpt-\d+` pattern and would resurrect the old generation in the pickers.
 */
const OPENAI_MAINLINE = /^gpt-([5-9]|\d{2,})(\.\d+)?(-mini)?$/;

function openaiAdmit(m: RawModelEntry): boolean {
  return isChatTextModel(m) && OPENAI_MAINLINE.test(m.id);
}

/**
 * Google: stable Gemini flash/pro, no preview/latest/deprecated.
 *
 * Deliberately does NOT use isChatTextModel: Gemini chat models are
 * multimodal on INPUT (text+image+audio+video+pdf), so the no-audio-input
 * gate — meant to exclude OpenAI realtime models — would reject every
 * Gemini model. Text-only OUTPUT is the discriminator that matters here.
 */
function googleAdmit(m: RawModelEntry): boolean {
  if (m.family !== "gemini-flash" && m.family !== "gemini-pro") return false;
  const out = m.modalities?.output ?? [];
  if (out.length !== 1 || out[0] !== "text") return false;
  // Reject preview and floating -latest aliases
  if (/preview/.test(m.id)) return false;
  if (/latest/.test(m.id)) return false;
  // Reject deprecated models
  if (m.status === "deprecated") return false;
  return true;
}

/** DeepSeek: v4+ flash/pro via version pattern in id. */
const DEEPSEEK_VN = /^deepseek-v([4-9]|\d{2,})-(flash|pro)$/;

function deepseekAdmit(m: RawModelEntry): boolean {
  return DEEPSEEK_VN.test(m.id);
}

type AdmitPredicate = (m: RawModelEntry) => boolean;

const PROVIDER_ADMIT: Record<string, AdmitPredicate> = {
  openai: openaiAdmit,
  google: googleAdmit,
  deepseek: deepseekAdmit,
};

/** Provider name mapping: catalog key → Nota provider name. */
const CATALOG_PROVIDER_TO_NOTA: Record<string, string> = {
  openai: "openai",
  google: "gemini",
  deepseek: "deepseek",
};

/**
 * Filter a raw api.json feed through the allowlist, returning the admitted
 * entries flattened into our cache format. Pure function (no I/O).
 */
export function filterCatalog(raw: RawCatalog): CatalogModelEntry[] {
  const result: CatalogModelEntry[] = [];

  for (const [provKey, admit] of Object.entries(PROVIDER_ADMIT)) {
    const providerData = raw[provKey as keyof RawCatalog];
    if (!providerData?.models) continue;

    const notaProvider = CATALOG_PROVIDER_TO_NOTA[provKey] ?? provKey;

    for (const [id, entry] of Object.entries(providerData.models)) {
      if (!admit(entry)) continue;

      const cost = entry.cost;
      const tiers: CostTier[] = [];
      if (cost.tiers) {
        for (const t of cost.tiers) {
          if (t.tier.type === "context" && t.tier.size > 0) {
            tiers.push({
              thresholdTokens: t.tier.size,
              input: t.input,
              output: t.output,
              cacheRead: t.cache_read,
            });
          }
        }
      }

      result.push({
        id,
        provider: notaProvider,
        label: entry.name ?? id,
        task: "summary",
        cost: {
          input: cost.input,
          output: cost.output,
          cacheRead: cost.cache_read,
          tiers,
        },
        limit: {
          context: entry.limit?.context ?? 0,
          output: entry.limit?.output,
          input: entry.limit?.input,
        },
      });
    }
  }

  return result.sort((a, b) => a.id.localeCompare(b.id));
}

/**
 * Validate a catalog cache for structural integrity and numeric sanity.
 * Returns an array of error messages (empty = valid).
 */
export function validateCatalog(
  cache: CatalogCache,
  /** Ids of models currently configured in settings — used for blanking guard. */
  configuredIds: string[] = [],
  /** The previous cache to compare against for blanking guard. */
  prevCache?: CatalogCache,
): string[] {
  const errors: string[] = [];

  if (cache.schemaVersion !== 1) {
    errors.push(`unsupported schemaVersion: ${cache.schemaVersion}`);
  }

  if (cache.models.length === 0) {
    errors.push("catalog contains zero models");
  }

  for (const m of cache.models) {
    if (typeof m.id !== "string" || !m.id) {
      errors.push("model entry missing string id");
      continue;
    }

    // An entry may legitimately carry no pricing (the OpenRouter shortlist):
    // there is nothing to bounds-check, and the display path prints its
    // `costNote` rather than a figure. Absent is not the same as zero, so it
    // must not fall through into the numeric checks below.
    if (m.cost === undefined) continue;

    if (typeof m.cost.input !== "number" || typeof m.cost.output !== "number") {
      errors.push(`${m.id}: cost.input and cost.output must be numbers`);
      continue;
    }

    // Bounds: 0 ≤ input,output ≤ 5000 per 1M tokens
    if (m.cost.input < 0 || m.cost.input > 5000) {
      errors.push(`${m.id}: cost.input ${m.cost.input} out of bounds [0, 5000]`);
    }
    if (m.cost.output < 0 || m.cost.output > 5000) {
      errors.push(`${m.id}: cost.output ${m.cost.output} out of bounds [0, 5000]`);
    }

    // cacheRead ≥ 0 and ≤ input
    if (m.cost.cacheRead !== undefined) {
      if (m.cost.cacheRead < 0) {
        errors.push(`${m.id}: cost.cacheRead ${m.cost.cacheRead} must be ≥ 0`);
      } else if (m.cost.cacheRead > m.cost.input) {
        errors.push(`${m.id}: cost.cacheRead ${m.cost.cacheRead} exceeds cost.input ${m.cost.input}`);
      }
    }

    // Validate tiers
    for (let i = 0; i < m.cost.tiers.length; i++) {
      const t = m.cost.tiers[i];
      if (!Number.isInteger(t.thresholdTokens) || t.thresholdTokens <= 0) {
        errors.push(`${m.id}: tiers[${i}].thresholdTokens must be a positive integer`);
      }
      if (typeof t.input !== "number" || typeof t.output !== "number") {
        errors.push(`${m.id}: tiers[${i}] must have numeric input and output`);
      }
    }
  }

  // Blanking guard: a configured model's cost going 0/missing while the old
  // cache had it non-zero rejects the fetch.
  for (const id of configuredIds) {
    const newEntry = cache.models.find((m) => m.id === id);
    const oldEntry = prevCache?.models.find((m) => m.id === id);
    if (!newEntry) continue; // model absent from new cache → handled by zombie policy
    if (!oldEntry) continue; // no previous data to compare
    // An unpriced entry has no figure to blank; it was never priced.
    if (!newEntry.cost || !oldEntry.cost) continue;

    const newCost = newEntry.cost.input + newEntry.cost.output;
    const oldCost = oldEntry.cost.input + oldEntry.cost.output;

    if (newCost === 0 && oldCost > 0) {
      errors.push(
        `${id}: cost dropped to 0 (was ${oldCost.toFixed(4)}); blanking guard rejected`,
      );
    }
  }

  return errors;
}

/**
 * Validate the raw fetch response (structural/schema checks that run BEFORE
 * we convert to the cache format). Returns error messages.
 */
export function validateRawCatalog(raw: unknown): string[] {
  const errors: string[] = [];

  if (typeof raw !== "object" || raw === null) {
    return ["response is not a JSON object"];
  }

  const obj = raw as Record<string, unknown>;

  const requiredProviders = ["openai", "google", "deepseek"];
  for (const prov of requiredProviders) {
    const pd = obj[prov];
    if (typeof pd !== "object" || pd === null) {
      errors.push(`missing required provider: ${prov}`);
      continue;
    }
    const models = (pd as Record<string, unknown>).models;
    if (typeof models !== "object" || models === null) {
      errors.push(`${prov}.models is missing or not an object`);
    } else if (typeof Object.keys(models).length !== "number" || Object.keys(models).length === 0) {
      // Actually check length properly
      const len = Object.keys(models).length;
      if (len === 0) {
        errors.push(`${prov}.models is empty`);
      }
    }
  }

  return errors;
}

// ── Cost computation ─────────────────────────────────────────────────────────

/**
 * Compute the USD cost for a summary-model usage from the catalog.
 * Rates are per 1M tokens; the conversion factor (`/ 1_000_000`) is applied here.
 *
 * The tier with the largest `thresholdTokens ≤ promptTokens` is used; if none
 * matches, base rates apply.
 *
 * Returns `null` for an entry Nota stores no pricing for (the OpenRouter
 * shortlist). Callers print {@link costNoteFor} in place of a figure — a zero
 * would read as "this run was free".
 */
export function computeSummaryCost(
  entry: CatalogModelEntry,
  tokensIn: number,
  tokensOut: number,
): number | null {
  if (!entry.cost) return null;

  let inputRate = entry.cost.input;
  let outputRate = entry.cost.output;

  // Pick the tier with the largest thresholdTokens ≤ tokensIn
  let bestTier: CostTier | undefined;
  for (const t of entry.cost.tiers) {
    if (t.thresholdTokens <= tokensIn) {
      if (!bestTier || t.thresholdTokens > bestTier.thresholdTokens) {
        bestTier = t;
      }
    }
  }

  if (bestTier) {
    inputRate = bestTier.input;
    outputRate = bestTier.output;
  }

  return (tokensIn / 1_000_000) * inputRate + (tokensOut / 1_000_000) * outputRate;
}

/**
 * Look up an entry in a catalog by model id.
 */
export function findCatalogEntry(
  catalog: CatalogCache,
  modelId: string,
): CatalogModelEntry | undefined {
  return catalog.models.find((m) => m.id === modelId);
}

/**
 * The text a cost display must print instead of a dollar figure for `modelId`,
 * or `undefined` when the model is priced (or simply unknown — an unknown model
 * is an unknown cost, which is a different thing and already rendered as "—").
 */
export function costNoteFor(
  catalog: CatalogCache,
  modelId: string,
): string | undefined {
  const entry = findCatalogEntry(catalog, modelId);
  if (!entry || entry.cost) return undefined;
  return entry.costNote ?? "unpriced";
}

// ── Cache I/O ────────────────────────────────────────────────────────────────

/**
 * Default cache path. NOTA_CATALOG_PATH env var overrides (hermetic tests).
 */
export function defaultCachePath(): string {
  return process.env.NOTA_CATALOG_PATH ?? CACHE_PATH;
}

/**
 * Read the on-disk catalog cache. Returns `null` when the file is missing or
 * unparseable (caller falls back to baked snapshot).
 */
export function readCache(filePath = defaultCachePath()): CatalogCache | null {
  if (!existsSync(filePath)) return null;
  try {
    const raw = JSON.parse(readFileSync(filePath, "utf-8"));
    return raw as CatalogCache;
  } catch {
    return null;
  }
}

/**
 * Atomically write a catalog cache to disk (temp file + rename).
 */
export function writeCache(
  cache: CatalogCache,
  filePath = defaultCachePath(),
): void {
  mkdirSync(path.dirname(filePath), { recursive: true });
  const tmp = `${filePath}.tmp-${process.pid}-${Date.now()}`;
  writeFileSync(tmp, JSON.stringify(cache, null, 2) + "\n", "utf-8");
  renameSync(tmp, filePath);
}

// ── Baked snapshot ───────────────────────────────────────────────────────────

/**
 * The baked snapshot shipped in-repo. This is a typed constant embedded at build
 * time so no file I/O is needed (works from src/ and dist/ identically).
 */
const BAKED_SNAPSHOT: CatalogCache = {"schemaVersion":1,"source":"https://models.dev/api.json","etag":"\"baked-snapshot\"","fetchedAt":"2026-07-22T00:00:00Z","costUnit":"usd_per_1m_tokens","models":[{"id":"deepseek-v4-flash","provider":"deepseek","label":"DeepSeek V4 Flash","task":"summary","cost":{"input":0.14,"output":0.28,"cacheRead":0.0028,"tiers":[]},"limit":{"context":1000000,"output":384000}},{"id":"deepseek-v4-pro","provider":"deepseek","label":"DeepSeek V4 Pro","task":"summary","cost":{"input":0.435,"output":0.87,"cacheRead":0.003625,"tiers":[]},"limit":{"context":1000000,"output":384000}},{"id":"gemini-2.5-flash","provider":"gemini","label":"Gemini 2.5 Flash","task":"summary","cost":{"input":0.3,"output":2.5,"cacheRead":0.03,"tiers":[]},"limit":{"context":1048576,"output":65536}},{"id":"gemini-2.5-pro","provider":"gemini","label":"Gemini 2.5 Pro","task":"summary","cost":{"input":1.25,"output":10,"cacheRead":0.125,"tiers":[{"thresholdTokens":200000,"input":2.5,"output":15,"cacheRead":0.25}]},"limit":{"context":1048576,"output":65536}},{"id":"gemini-3.5-flash","provider":"gemini","label":"Gemini 3.5 Flash","task":"summary","cost":{"input":0.15,"output":0.6,"cacheRead":0.015,"tiers":[]},"limit":{"context":1048576,"output":65536}},{"id":"gemini-3.6-flash","provider":"gemini","label":"Gemini 3.6 Flash","task":"summary","cost":{"input":0.1,"output":0.4,"cacheRead":0.01,"tiers":[]},"limit":{"context":1048576,"output":65536}},{"id":"gpt-5","provider":"openai","label":"GPT-5","task":"summary","cost":{"input":1.25,"output":10,"cacheRead":0.125,"tiers":[]},"limit":{"context":1000000,"output":16384}},{"id":"gpt-5-mini","provider":"openai","label":"GPT-5 mini","task":"summary","cost":{"input":0.25,"output":2,"cacheRead":0.025,"tiers":[]},"limit":{"context":1000000,"output":16384}},{"id":"gpt-5.1","provider":"openai","label":"GPT-5.1","task":"summary","cost":{"input":2,"output":8,"cacheRead":0.5,"tiers":[]},"limit":{"context":1000000,"output":16384}},{"id":"gpt-5.2","provider":"openai","label":"GPT-5.2","task":"summary","cost":{"input":2.5,"output":10,"cacheRead":1.25,"tiers":[]},"limit":{"context":1000000,"output":16384}},{"id":"gpt-5.4","provider":"openai","label":"GPT-5.4","task":"summary","cost":{"input":1.25,"output":10,"cacheRead":0.125,"tiers":[]},"limit":{"context":1000000,"output":16384}},{"id":"gpt-5.4-mini","provider":"openai","label":"GPT-5.4 mini","task":"summary","cost":{"input":0.25,"output":2,"cacheRead":0.025,"tiers":[]},"limit":{"context":1000000,"output":16384}},{"id":"gpt-5.5","provider":"openai","label":"GPT-5.5","task":"summary","cost":{"input":1,"output":8,"cacheRead":0.1,"tiers":[]},"limit":{"context":1000000,"output":16384}},{"id":"gpt-5.6","provider":"openai","label":"GPT-5.6","task":"summary","cost":{"input":2.5,"output":10,"cacheRead":1.25,"tiers":[]},"limit":{"context":1000000,"output":16384}}]};

/** Load the baked snapshot. Returns the embedded constant. */
export function loadBakedSnapshot(): CatalogCache {
  return BAKED_SNAPSHOT;
}

// ── Effective catalog: sanitize, then merge the curated shortlist ────────────

/**
 * Drop entries this build cannot honestly serve, per entry rather than per
 * catalog: a namespaced id whose namespace is not a provider Nota has, and an
 * `execution` value this build does not recognize. Both can only arrive from a
 * cache written by a newer Nota, and both mean "we do not know how to run
 * this" — guessing would either send a request to nowhere or, for an unknown
 * execution kind, let a future non-HTTP engine leak into a picker that filters
 * on `http`. One bad entry costs only itself.
 */
export function sanitizeCatalog(cache: CatalogCache): CatalogCache {
  const kept = cache.models.filter((m) => {
    if (deriveProvider(m.id, m.provider) === undefined) return false;
    if (resolveExecutionKind(m.execution) === undefined) return false;
    return true;
  });
  if (kept.length === cache.models.length) return cache;
  return { ...cache, models: kept };
}

/**
 * Every entry that lives in code rather than in the cache: the OpenRouter
 * shortlist and the CLI engines. One list because they are merged the same way
 * and for the same reason; two modules because one is an HTTP provider and the
 * other is a subprocess.
 */
export const CURATED_MODELS: readonly CatalogModelEntry[] = [
  ...OPENROUTER_MODELS,
  ...CLI_ENGINE_MODELS,
];

/**
 * Merge the curated shortlist into a catalog. Curated entries live in code, not
 * in the cache, which is exactly what makes them survive `nota models refresh`:
 * a refresh rewrites the auto-admitted cache, and the cache has never held
 * them. A cache entry with the same id wins (a real upstream listing beats our
 * hand-written stub).
 */
export function mergeCurated(
  cache: CatalogCache,
  curated: readonly CatalogModelEntry[] = CURATED_MODELS,
): CatalogCache {
  const present = new Set(cache.models.map((m) => m.id));
  const additions = curated.filter((m) => !present.has(m.id));
  if (additions.length === 0) return cache;
  const models = [...cache.models, ...additions].sort((a, b) =>
    a.id.localeCompare(b.id),
  );
  return { ...cache, models };
}

/**
 * Resolve the effective catalog: on-disk cache first, then baked snapshot,
 * sanitized, with the curated shortlist merged in. `source` describes where the
 * *auto-admitted* half came from; a curated entry carries `origin: "curated"`
 * and is labelled from that.
 */
export function effectiveCatalog(): {
  catalog: CatalogCache;
  source: "cache" | "baked";
} {
  const cached = readCache();
  if (cached) {
    return { catalog: mergeCurated(sanitizeCatalog(cached)), source: "cache" };
  }
  return {
    catalog: mergeCurated(sanitizeCatalog(loadBakedSnapshot())),
    source: "baked",
  };
}

/**
 * Check whether the cache is stale (older than 7 days).
 */
export function isCacheStale(cache: CatalogCache): boolean {
  const fetched = new Date(cache.fetchedAt).getTime();
  return Date.now() - fetched > CACHE_TTL_MS;
}

// ── Fetch & refresh ──────────────────────────────────────────────────────────

const FETCH_URL = "https://models.dev/api.json";
const FETCH_TIMEOUT_MS = 10_000;
const MAX_BODY_BYTES = 16 * 1024 * 1024;

export interface RefreshResult {
  ok: boolean;
  cache: CatalogCache;
  added: string[];
  removed: string[];
  errors: string[];
}

/**
 * Fetch the latest catalog upstream, filter, validate, and write a fresh cache.
 * Returns a summary of what changed.
 */
export async function refreshCatalog(opts?: {
  etag?: string;
  configuredIds?: string[];
  prevCache?: CatalogCache;
}): Promise<RefreshResult> {
  const prevCache = opts?.prevCache ?? readCache() ?? undefined;
  const configuredIds = opts?.configuredIds ?? [];

  // Build headers. The etag shortcut is only valid when the previous cache
  // was produced by the CURRENT filter code — a 304 skips refiltering, so a
  // stale-filtered cache must take the full fetch path instead.
  const headers: Record<string, string> = {
    Accept: "application/json",
  };
  if (opts?.etag && prevCache?.filterVersion === FILTER_VERSION) {
    headers["If-None-Match"] = opts.etag;
  }

  let response: Response;
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
    response = await fetch(FETCH_URL, {
      headers,
      signal: controller.signal,
      redirect: "error",
    });
    clearTimeout(timer);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    const fallback = prevCache ?? loadBakedSnapshot();
    return {
      ok: false,
      cache: fallback,
      added: [],
      removed: [],
      errors: [`fetch failed: ${msg}`],
    };
  }

  // 304 Not Modified — keep cache, bump clock
  if (response.status === 304) {
    const kept = prevCache ?? loadBakedSnapshot();
    // Bump freshness clock by rewriting the cache with current timestamp
    if (prevCache) {
      const bumped = { ...prevCache, fetchedAt: new Date().toISOString() };
      writeCache(bumped);
      return { ok: true, cache: bumped, added: [], removed: [], errors: [] };
    }
    return { ok: true, cache: kept, added: [], removed: [], errors: [] };
  }

  if (!response.ok) {
    const fallback = prevCache ?? loadBakedSnapshot();
    return {
      ok: false,
      cache: fallback,
      added: [],
      removed: [],
      errors: [`fetch returned ${response.status}`],
    };
  }

  // Validate content-type
  const ct = response.headers.get("content-type") ?? "";
  if (!ct.includes("json")) {
    const fallback = prevCache ?? loadBakedSnapshot();
    return {
      ok: false,
      cache: fallback,
      added: [],
      removed: [],
      errors: [`unexpected content-type: ${ct}`],
    };
  }

  // Read body with size cap
  let body: string;
  try {
    const reader = response.body?.getReader();
    if (!reader) {
      throw new Error("no response body");
    }
    const chunks: Uint8Array[] = [];
    let total = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > MAX_BODY_BYTES) {
        reader.cancel();
        const fallback = prevCache ?? loadBakedSnapshot();
        return {
          ok: false,
          cache: fallback,
          added: [],
          removed: [],
          errors: [`response exceeded ${MAX_BODY_BYTES} byte limit`],
        };
      }
      chunks.push(value);
    }
    body = new TextDecoder().decode(
      chunks.length === 1 ? chunks[0] : Buffer.concat(chunks),
    );
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    const fallback = prevCache ?? loadBakedSnapshot();
    return { ok: false, cache: fallback, added: [], removed: [], errors: [`read body failed: ${msg}`] };
  }

  // Parse JSON
  let raw: unknown;
  try {
    raw = JSON.parse(body);
  } catch {
    const fallback = prevCache ?? loadBakedSnapshot();
    return { ok: false, cache: fallback, added: [], removed: [], errors: ["response is not valid JSON"] };
  }

  // Validate raw structure
  const rawErrors = validateRawCatalog(raw);
  if (rawErrors.length > 0) {
    const fallback = prevCache ?? loadBakedSnapshot();
    return { ok: false, cache: fallback, added: [], removed: [], errors: rawErrors };
  }

  // Filter through allowlist
  const filteredModels = filterCatalog(raw as RawCatalog);

  // Every provider must survive filtering with at least one model. A filter
  // bug that silently empties one provider (e.g. an audio-input gate wiping
  // all of Gemini, whose chat models are multimodal on input) must reject
  // the fetch and keep serving the previous cache.
  const emptyProviders = ["openai", "gemini", "deepseek"].filter(
    (prov) => !filteredModels.some((m) => m.provider === prov),
  );
  if (emptyProviders.length > 0) {
    const fallback = prevCache ?? loadBakedSnapshot();
    return {
      ok: false,
      cache: fallback,
      added: [],
      removed: [],
      errors: emptyProviders.map((p) => `no models admitted for provider: ${p}`),
    };
  }

  // Build new cache
  const etag = response.headers.get("etag") ?? "";
  const newCache: CatalogCache = {
    schemaVersion: 1,
    source: FETCH_URL,
    etag,
    fetchedAt: new Date().toISOString(),
    costUnit: "usd_per_1m_tokens",
    filterVersion: FILTER_VERSION,
    models: filteredModels,
  };

  // Validate the filtered cache
  const cacheErrors = validateCatalog(newCache, configuredIds, prevCache);
  if (cacheErrors.length > 0) {
    const fallback = prevCache ?? loadBakedSnapshot();
    return { ok: false, cache: fallback, added: [], removed: [], errors: cacheErrors };
  }

  // Compute diff vs previous cache
  const prevIds = new Set((prevCache?.models ?? []).map((m) => m.id));
  const newIds = new Set(filteredModels.map((m) => m.id));
  const added = [...newIds].filter((id) => !prevIds.has(id)).sort();
  const removed = [...prevIds].filter((id) => !newIds.has(id)).sort();

  // Atomic write
  writeCache(newCache);

  return { ok: true, cache: newCache, added, removed, errors: [] };
}
