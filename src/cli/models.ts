/**
 * CLI verbs for the self-updating model catalog.
 *
 * `nota models list`   — print the effective summary catalog as TSV
 * `nota models refresh` — force a fetch from models.dev, show diff
 */

import { effectiveCatalog, readCache, refreshCatalog } from "../catalog.js";

/**
 * `nota models list` — print effective summary catalog rows to stdout.
 * Tab-separated columns: id, provider, label, source, fetchedAt.
 *
 * Source is per entry, not per catalog: "cache" or "baked" for the weekly
 * auto-admitted half, and "curated" for a hand-picked entry (the OpenRouter
 * shortlist), which lives in code and is therefore as fresh as the build
 * whatever `fetchedAt` says about the rest. Header on stderr.
 */
export async function modelsList(): Promise<void> {
  const { catalog, source } = effectiveCatalog();
  const sourceLabel = source === "baked" ? "baked" : "cache";

  process.stderr.write("id\tprovider\tlabel\tsource\tfetchedAt\n");
  for (const m of catalog.models) {
    const origin = m.origin === "curated" ? "curated" : sourceLabel;
    process.stdout.write(`${m.id}\t${m.provider}\t${m.label}\t${origin}\t${catalog.fetchedAt}\n`);
  }
}

/**
 * `nota models refresh` — force a fetch from models.dev, validate, and write
 * a fresh cache. Prints added/removed ids to stdout, confirmation/errors on
 * stderr. Exits non-zero on validation failure.
 */
export async function modelsRefresh(): Promise<void> {
  const prevCache = readCache() ?? undefined;

  const result = await refreshCatalog({
    etag: prevCache?.etag,
    configuredIds: [],
    prevCache: prevCache ?? undefined,
  });

  if (!result.ok) {
    for (const err of result.errors) {
      process.stderr.write(`error: ${err}\n`);
    }
    process.exit(1);
  }

  if (result.added.length > 0) {
    process.stdout.write("added:\n");
    for (const id of result.added) {
      process.stdout.write(`  + ${id}\n`);
    }
  }
  if (result.removed.length > 0) {
    process.stdout.write("removed:\n");
    for (const id of result.removed) {
      process.stdout.write(`  - ${id}\n`);
    }
  }
  if (result.added.length === 0 && result.removed.length === 0) {
    process.stdout.write("(no changes)\n");
  }

  process.stderr.write(`catalog refreshed: ${result.cache.fetchedAt}\n`);
}
