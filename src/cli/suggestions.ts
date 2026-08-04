/**
 * `nota history suggestions|accept-suggestion|dismiss-suggestion` — the CLI
 * surface for tentative-band speaker suggestions (decision 7 of the
 * speaker-workflow spec). The record stores the suggestion; these verbs list
 * pending ones, apply accept (rename + enroll + state) / dismiss (state only)
 * semantics, and recompute an old record's suggestions from its stored clips
 * against today's store.
 *
 * Exit codes mirror `nota enroll` so the macOS chip can map them to its
 * indicators: 2 = record missing, 3 = stored clip missing, 4 = ONNX identity
 * unavailable, 5 = insufficient speech, 1 = other. Confirmations go to
 * stderr; stdout stays scriptable.
 */

import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { isIdentityAvailable, computeEmbeddings } from "../pipeline/embed.js";
import { DEFAULT_SPEAKERS_FILE, loadProfiles, computeSuggestions } from "../pipeline/speakers.js";
import {
  DEFAULT_HISTORY_DIR,
  listHistoryRecords,
  loadHistoryRecord,
  renameRecordSpeaker,
  setSuggestionState,
  speakerClipPath,
  type HistoryRecord,
} from "../pipeline/history.js";
import { enrollSpeaker, EnrollError } from "./enroll.js";

export interface SuggestionCommandOptions {
  storePath?: string;
  historyDir?: string;
}

/**
 * List every pending suggestion across all records as tab-separated rows
 * (record id, label, suggested name, score) on stdout, header on stderr.
 * Decided suggestions are omitted — the chip keeps them out of the user's
 * way the same way.
 */
export async function listSuggestions(
  options: SuggestionCommandOptions = {},
): Promise<void> {
  const historyDir = options.historyDir ?? DEFAULT_HISTORY_DIR;
  const records = await listHistoryRecords(historyDir);
  const rows: string[] = [];
  for (const record of records) {
    for (const suggestion of record.suggestions ?? []) {
      if (suggestion.state !== "pending") continue;
      rows.push(
        [record.id, suggestion.label, suggestion.suggestedName, suggestion.score.toFixed(3)].join("\t"),
      );
    }
  }
  process.stderr.write("Record ID\tLabel\tSuggested name\tScore\n");
  if (rows.length === 0) {
    process.stderr.write("No pending speaker suggestions.\n");
    return;
  }
  for (const row of rows) process.stdout.write(`${row}\n`);
}

/**
 * Recompute a record's suggestions from its stored per-speaker clips against
 * today's store (on-demand backfill — no migration sweep). Replaces the
 * record's whole suggestions array with fresh pending entries.
 */
export async function recomputeSuggestions(
  idOrPrefix: string,
  options: SuggestionCommandOptions = {},
): Promise<void> {
  const historyDir = options.historyDir ?? DEFAULT_HISTORY_DIR;
  const storePath = options.storePath ?? DEFAULT_SPEAKERS_FILE;

  let record: HistoryRecord;
  try {
    record = await loadHistoryRecord(idOrPrefix, historyDir);
  } catch (error) {
    throw new EnrollError(
      error instanceof Error ? error.message : String(error),
      2,
    );
  }

  const clips = record.speakerClips ?? {};
  const clipLabels = Object.keys(clips);
  if (clipLabels.length === 0) {
    throw new EnrollError(
      `History "${record.id}" has no stored speaker clips to recompute from.`,
      3,
    );
  }
  if (!(await isIdentityAvailable())) {
    throw new EnrollError(
      "ONNX speaker identity is unavailable. Check the model download and " +
        "onnxruntime-node installation, then retry.",
      4,
    );
  }

  const pcmByLabel: Record<string, Int16Array> = {};
  for (const label of clipLabels) {
    const abs = speakerClipPath(record.id, label, historyDir);
    let buf: Buffer;
    try {
      buf = await readFile(abs);
    } catch {
      throw new EnrollError(
        `Stored clip for label "${label}" in history "${record.id}" is missing on disk.`,
        3,
      );
    }
    const pcm = new Int16Array(buf.length / 2);
    for (let i = 0; i < pcm.length; i++) pcm[i] = buf.readInt16LE(i * 2);
    pcmByLabel[label] = pcm;
  }

  const labelEmbeddings = await computeEmbeddings(pcmByLabel);
  const store = await loadProfiles(storePath);
  const suggestions = computeSuggestions(labelEmbeddings, store);

  record = {
    ...record,
    updatedAt: new Date().toISOString(),
    suggestions,
  };
  await writeFile(
    path.join(historyDir, `${record.id}.json`),
    JSON.stringify(record, null, 2),
    "utf-8",
  );
  process.stderr.write(
    `Recomputed ${suggestions.length} suggestion(s) for history "${record.id}" from stored clips.\n`,
  );
}

/**
 * Accept a pending suggestion: rename the label to the suggested name
 * everywhere (segments, clip, output markdown) and enroll that record's clip
 * as a new voiceprint for the person. Enrollment runs first so a failed
 * enrollment (model unavailable, clip missing, too little speech) aborts the
 * accept with nothing changed. The suggestion is marked accepted last.
 */
export async function acceptSuggestion(
  idOrPrefix: string,
  label: string,
  options: SuggestionCommandOptions = {},
): Promise<void> {
  const historyDir = options.historyDir ?? DEFAULT_HISTORY_DIR;

  let record: HistoryRecord;
  try {
    record = await loadHistoryRecord(idOrPrefix, historyDir);
  } catch (error) {
    throw new EnrollError(
      error instanceof Error ? error.message : String(error),
      2,
    );
  }
  const suggestion = (record.suggestions ?? []).find(
    (s) => s.label === label && s.state === "pending",
  );
  if (!suggestion) {
    throw new EnrollError(
      `No pending suggestion for label "${label}" in history "${record.id}".`,
      1,
    );
  }

  // 1. Enroll from the stored clip under the original label. Exit codes
  //    2/3/4/5 propagate untouched; nothing has changed if this throws.
  await enrollSpeaker(record.id, label, suggestion.suggestedName, options);

  // 2. Rename the label everywhere (also marks the summary outdated when the
  //    record has one — decision 5). The clip was moved by the rename, so a
  //    later enroll finds it under the new name.
  const renamed = await renameRecordSpeaker(record.id, label, suggestion.suggestedName, historyDir);

  // 3. Record the decision on the record.
  await setSuggestionState(record.id, label, "accepted", historyDir);

  process.stderr.write(
    `Accepted "${suggestion.suggestedName}" for "${label}" in history "${record.id}" ` +
      `(${renamed.segmentsRenamed} segment(s) renamed, voiceprint enrolled).\n`,
  );
}

/**
 * Dismiss a pending suggestion: decision state only — the record's segments,
 * clips, and store are untouched.
 */
export async function dismissSuggestion(
  idOrPrefix: string,
  label: string,
  options: SuggestionCommandOptions = {},
): Promise<void> {
  const historyDir = options.historyDir ?? DEFAULT_HISTORY_DIR;
  const record = await setSuggestionState(idOrPrefix, label, "dismissed", historyDir);
  process.stderr.write(
    `Dismissed the suggestion for "${label}" in history "${record.id}".\n`,
  );
}
