/**
 * One-off maintenance: backfill LLM titles + tags into legacy `.summary.md`
 * files that predate the title feature (they carry the generic `# Nota Summary`
 * heading and no `**Tags:**` line).
 *
 * Usage:
 *   npx tsx scripts/backfill-titles.ts            # rewrite legacy files in place
 *   npx tsx scripts/backfill-titles.ts --dry-run  # preview, write nothing
 *
 * Honors NOTA_OUTPUT_DIR (defaults to ~/Documents/Nota), OPENAI_API_KEY, and
 * NOTA_BACKFILL_MODEL (defaults to gpt-4o).
 */
import { readFile, writeFile, readdir } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import OpenAI from "openai";
import { parseSummaryResponse } from "../src/pipeline/summarize.js";

const OUTPUT_DIR =
  process.env.NOTA_OUTPUT_DIR || path.join(os.homedir(), "Documents", "Nota");
const MODEL = process.env.NOTA_BACKFILL_MODEL || "gpt-4o";
const GENERIC_TITLE = "Nota Summary";
const DRY_RUN = process.argv.includes("--dry-run");

function buildBackfillPrompt(summaryMarkdown: string): string {
  return `Below is an existing meeting summary document. Generate a title and tags for it.

Use exactly these headers and nothing else:

### Title
A concise, descriptive title in at most 6 words. Plain text — no quotes, no trailing punctuation.

### Tags
3 to 6 short, lowercase topical tags on a single line, comma-separated.

## Document

${summaryMarkdown}`;
}

/** First `# ` heading in the header block, or null. Stops at the first `## `. */
function firstHeading(md: string): string | null {
  for (const raw of md.split("\n")) {
    const line = raw.trim();
    if (line.startsWith("## ")) break;
    if (line.startsWith("# ")) return line.slice(2).trim();
  }
  return null;
}

/** Rewrite the H1 and insert a `**Tags:**` line after `**Source:**`. */
function applyTitleAndTags(md: string, title: string, tags: string[]): string {
  const lines = md.split("\n");

  let h1Index = -1;
  let sourceIndex = -1;
  let hasTags = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.startsWith("## ")) break;
    if (h1Index === -1 && line.startsWith("# ")) h1Index = i;
    if (line.startsWith("**Source:**")) sourceIndex = i;
    if (line.startsWith("**Tags:**")) hasTags = true;
  }

  if (h1Index !== -1) {
    lines[h1Index] = `# ${title}`;
  }
  if (!hasTags && tags.length > 0) {
    const insertAt = sourceIndex !== -1 ? sourceIndex + 1 : h1Index + 1;
    lines.splice(insertAt, 0, `**Tags:** ${tags.join(", ")}`);
  }

  return lines.join("\n");
}

async function main(): Promise<void> {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    console.error("OPENAI_API_KEY is not set.");
    process.exit(1);
  }

  let names: string[];
  try {
    names = await readdir(OUTPUT_DIR);
  } catch (error) {
    console.error(`Cannot read ${OUTPUT_DIR}: ${(error as Error).message}`);
    process.exit(1);
  }

  const summaries = names.filter((n) => n.endsWith(".summary.md"));
  if (summaries.length === 0) {
    console.log(`No .summary.md files in ${OUTPUT_DIR}.`);
    return;
  }

  const client = new OpenAI({ apiKey });
  let updated = 0;
  let skipped = 0;

  for (const name of summaries) {
    const filePath = path.join(OUTPUT_DIR, name);
    const md = await readFile(filePath, "utf-8");
    const heading = firstHeading(md);

    // Already has a real (non-generic) title -> new-format file, leave it alone.
    if (heading && heading !== GENERIC_TITLE) {
      skipped++;
      console.log(`skip   ${name} (already titled: "${heading}")`);
      continue;
    }

    const response = await client.chat.completions.create({
      model: MODEL,
      max_tokens: 256,
      messages: [{ role: "user", content: buildBackfillPrompt(md) }],
    });
    const content = response.choices[0]?.message?.content ?? "";
    const { title, tags } = parseSummaryResponse(content);

    if (!title) {
      skipped++;
      console.log(`skip   ${name} (model returned no title)`);
      continue;
    }

    const rewritten = applyTitleAndTags(md, title, tags);
    if (DRY_RUN) {
      console.log(`would  ${name} -> "${title}"  [${tags.join(", ")}]`);
    } else {
      await writeFile(filePath, rewritten, "utf-8");
      console.log(`update ${name} -> "${title}"  [${tags.join(", ")}]`);
    }
    updated++;
  }

  const verb = DRY_RUN ? "would update" : "updated";
  console.log(`\nDone. ${verb} ${updated}, skipped ${skipped}.`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
