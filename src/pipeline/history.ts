import { access, mkdir, readFile, readdir, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import type { Provider } from "../config.js";
import type { MeetingSummary } from "./summarize.js";
import type { TranscriptSegment } from "./transcribe.js";
import type { SpeakerSuggestion, SuggestionState } from "./speakers.js";

export type HistoryStatus = "transcribed" | "completed";

/**
 * What a history record represents. `"meeting"` = live session, `"file"` =
 * transcribed audio file, `"memo"` = quick-memo live session. Optional on the
 * record because records written before the redesign shipped predate the
 * field; consumers treat absent as legacy and infer by source (see the macOS
 * `HistoryRecordInfo.kindsAndStatusesByOutputPath`).
 */
export type HistoryKind = "meeting" | "file" | "memo";

export interface HistoryOptions {
  language?: string;
  diarize: boolean;
  identify: boolean;
  numSpeakers?: number;
  model: string;
}

/**
 * Token / duration usage for a single processing step (transcription or
 * summary). Emitted at capture time; cost is computed via costForUsage.
 * `costUSD` is null when the model is unknown or inputs are absent (never
 * zero — "free" is semantically different from "unknown").
 */
export interface UsageEntry {
  modelId: string;
  task: "transcription" | "summary";
  provider: Provider;
  calls: number;
  tokensIn?: number;
  tokensOut?: number;
  durationMin?: number;
  costUSD: number | null;
  estimated: boolean;
  /** ISO timestamp of the catalog snapshot used for cost computation. */
  pricedAsOf?: string;
}

export interface HistoryRecord {
  id: string;
  createdAt: string;
  updatedAt: string;
  capturedAt: string | null;
  sourcePath: string;
  sourceName: string;
  /**
   * SHA-256 of the source audio bytes, used to detect duplicate ingests.
   * Optional because records written before duplicate detection shipped
   * predate the field; treat `undefined` as "unknown / never matches".
   */
  contentHash?: string;
  provider: Provider;
  options: HistoryOptions;
  /**
   * Record kind ("meeting" | "file" | "memo"). Optional: records written
   * before the home-redesign kind field shipped lack it; legacy records are
   * treated by source at read time.
   */
  kind?: HistoryKind;
  durationMinutes: number;
  transcriptText: string;
  segments: TranscriptSegment[];
  /**
   * Map of diarized speaker label → path (relative to the history dir) of the
   * captured PCM clip for that speaker. Lets `nota enroll` build a voiceprint
   * later, after the original (often temp) audio has been deleted.
   */
  speakerClips?: Record<string, string>;
  /**
   * Per-step usage entries (transcription + summary). Optional because
   * records written before the feature shipped predate the field.
   */
  usage?: UsageEntry[];
  summary?: MeetingSummary;
  /**
   * True when the summary narrative was last edited by hand (edited-is-
   * protected: regeneration then requires --force). Optional because records
   * written before enrichment shipped predate the field; absent means false.
   */
  summaryEdited?: boolean;
  /**
   * True when the tags were last touched by hand. Protected the same way;
   * tag regeneration over edited tags merges rather than replaces, so manual
   * tags are never silently dropped.
   */
  tagsEdited?: boolean;
  /**
   * True when the user pinned this record in the macOS app's history drawer
   * (pinned rows render above chronology). Managed by the app, which edits
   * the JSON in place; the CLI never writes it. Absent means unpinned.
   */
  pinned?: boolean;
  /**
   * Tentative-band speaker suggestions from the run that created this record
   * (decision 3 of the speaker-workflow spec): one entry per diarized label
   * whose best cosine landed in [0.50, 0.65), carrying its decision state.
   * Optional: legacy records predate the field and simply have no suggestions.
   */
  suggestions?: SpeakerSuggestion[];
  /**
   * True when a speaker rename/accept landed on a record that already has a
   * summary: the narrative still references the old label, so the app shows
   * a one-click "Regenerate summary" affordance until used or dismissed
   * (decision 5). Cleared whenever a fresh summary is set. Absent means false.
   */
  summaryOutdated?: boolean;
  outputPath?: string;
  status: HistoryStatus;
}

export interface CreateHistoryInput {
  sourcePath: string;
  provider: Provider;
  options: HistoryOptions;
  /** Record kind; omitted records stay kind-less (legacy shape). */
  kind?: HistoryKind;
  durationMinutes: number;
  transcriptText: string;
  segments: TranscriptSegment[];
  capturedAt?: string | null;
  contentHash?: string;
  /**
   * Per-speaker PCM clips to persist alongside the record. Written under
   * `<id>.assets/<label>.pcm`; the resulting relative paths populate the
   * record's `speakerClips`.
   */
  speakerClipsPcm?: Record<string, Int16Array>;
  /**
   * Transcription usage to persist on the record at creation time.
   * Present when usage tracking is enabled.
   */
  usage?: UsageEntry[];
  /**
   * Tentative-band speaker suggestions computed during recognition, persisted
   * so the macOS chip can offer accept/dismiss without re-running the model.
   */
  suggestions?: SpeakerSuggestion[];
  outputPath?: string;
}

export interface CompleteHistoryInput {
  summary: MeetingSummary;
  outputPath: string;
  /** Summary usage entries to append to the record's usage array on completion. */
  usage?: UsageEntry[];
}

export const DEFAULT_HISTORY_DIR = path.join(homedir(), ".nota", "history");

function makeHistoryId(createdAt: string): string {
  const stamp = createdAt
    .replace(/[-:]/g, "")
    .replace(/\.\d{3}Z$/, "Z")
    .replace("T", "-");
  return `${stamp}-${randomUUID().slice(0, 8)}`;
}

function historyPath(id: string, historyDir: string): string {
  return path.join(historyDir, `${id}.json`);
}

/** Absolute path of a captured per-speaker PCM clip for a record. */
export function speakerClipPath(
  id: string,
  label: string,
  historyDir = DEFAULT_HISTORY_DIR,
): string {
  return path.join(historyDir, `${id}.assets`, `${label}.pcm`);
}

/**
 * Persist a speaker's PCM clip under `<id>.assets/<label>.pcm`.
 * Returns the path relative to `historyDir` (what is stored in the record).
 */
export async function writeSpeakerClip(
  id: string,
  label: string,
  pcm: Int16Array,
  historyDir = DEFAULT_HISTORY_DIR,
): Promise<string> {
  const abs = speakerClipPath(id, label, historyDir);
  await mkdir(path.dirname(abs), { recursive: true });
  await writeFile(abs, Buffer.from(pcm.buffer, pcm.byteOffset, pcm.byteLength));
  return path.relative(historyDir, abs);
}

async function readHistoryFile(filePath: string): Promise<HistoryRecord> {
  const raw = await readFile(filePath, "utf-8");
  return JSON.parse(raw) as HistoryRecord;
}

export async function createHistoryRecord(
  input: CreateHistoryInput,
  historyDir = DEFAULT_HISTORY_DIR,
): Promise<HistoryRecord> {
  const now = new Date().toISOString();
  const record: HistoryRecord = {
    id: makeHistoryId(now),
    createdAt: now,
    updatedAt: now,
    capturedAt: input.capturedAt ?? null,
    sourcePath: input.sourcePath,
    sourceName: path.basename(input.sourcePath),
    contentHash: input.contentHash,
    provider: input.provider,
    options: input.options,
    kind: input.kind,
    durationMinutes: input.durationMinutes,
    transcriptText: input.transcriptText,
    segments: input.segments,
    outputPath: input.outputPath,
    usage: input.usage,
    suggestions: input.suggestions,
    status: "transcribed",
  };

  await mkdir(historyDir, { recursive: true });

  // Persist any captured per-speaker clips first so the record's
  // `speakerClips` pointers are written atomically with the record itself.
  if (input.speakerClipsPcm) {
    const clips: Record<string, string> = {};
    for (const [label, pcm] of Object.entries(input.speakerClipsPcm)) {
      clips[label] = await writeSpeakerClip(record.id, label, pcm, historyDir);
    }
    record.speakerClips = clips;
  }

  await writeFile(
    historyPath(record.id, historyDir),
    JSON.stringify(record, null, 2),
    "utf-8",
  );
  return record;
}

export async function completeHistoryRecord(
  id: string,
  input: CompleteHistoryInput,
  historyDir = DEFAULT_HISTORY_DIR,
): Promise<HistoryRecord> {
  const filePath = historyPath(id, historyDir);
  const record = await readHistoryFile(filePath);
  const updated: HistoryRecord = {
    ...record,
    updatedAt: new Date().toISOString(),
    summary: input.summary,
    outputPath: input.outputPath,
    usage: [...(record.usage ?? []), ...(input.usage ?? [])],
    status: "completed",
  };

  await writeFile(filePath, JSON.stringify(updated, null, 2), "utf-8");
  return updated;
}

/**
 * Merge existing (manual-first) and freshly generated tags per E3-c:
 * lowercase-normalized union — manual tags keep their order, generated tags
 * append, case-insensitive dedup, capped at 8. Manual tags are never
 * silently dropped by regeneration.
 */
export function mergeTags(manual: string[], generated: string[]): string[] {
  const merged: string[] = [];
  const seen = new Set<string>();
  for (const tag of [...manual, ...generated]) {
    const normalized = tag.trim().toLowerCase();
    if (!normalized || seen.has(normalized)) continue;
    seen.add(normalized);
    merged.push(normalized);
  }
  return merged.slice(0, 8);
}

function emptySummary(): MeetingSummary {
  return {
    title: "",
    tags: [],
    narrative: "",
    keyTopics: [],
    decisions: [],
    actionItems: [],
  };
}

export interface SetSummaryInput {
  summary: MeetingSummary;
  /** New value for the edited flag (false after regeneration); omitted = keep. */
  summaryEdited?: boolean;
  tagsEdited?: boolean;
  /** Usage entries to append (e.g. the generation's summary usage). */
  usage?: UsageEntry[];
  outputPath?: string;
}

/**
 * Set (or replace) a record's summary. Record-first write ordering (E3-f):
 * this persists the record; the caller rewrites the derived `.md` afterwards.
 * A record that carries a summary is `completed` (E3-d).
 */
export async function setRecordSummary(
  id: string,
  input: SetSummaryInput,
  historyDir = DEFAULT_HISTORY_DIR,
): Promise<HistoryRecord> {
  const filePath = historyPath(id, historyDir);
  const record = await readHistoryFile(filePath);
  const updated: HistoryRecord = {
    ...record,
    updatedAt: new Date().toISOString(),
    summary: input.summary,
    outputPath: input.outputPath ?? record.outputPath,
    usage: input.usage ? [...(record.usage ?? []), ...input.usage] : record.usage,
    // A freshly set summary is never stale (decision 5): any previous
    // rename-induced staleness is resolved by this very summary.
    summaryOutdated: false,
    status: "completed",
  };
  if (input.summaryEdited !== undefined) updated.summaryEdited = input.summaryEdited;
  if (input.tagsEdited !== undefined) updated.tagsEdited = input.tagsEdited;

  await writeFile(filePath, JSON.stringify(updated, null, 2), "utf-8");
  return updated;
}

export interface SetTagsInput {
  tags: string[];
  /** New value for the edited flag; omitted = keep the current value. */
  tagsEdited?: boolean;
  /** Usage entries to append (e.g. the tags call's usage). */
  usage?: UsageEntry[];
}

/**
 * Set a record's tags (creating a stub summary container on a transcript-only
 * record). Tags alone do not complete a record — `status` is untouched, only
 * a summary flips it (E3-d). Record-first ordering as in
 * {@link setRecordSummary}.
 */
export async function setRecordTags(
  id: string,
  input: SetTagsInput,
  historyDir = DEFAULT_HISTORY_DIR,
): Promise<HistoryRecord> {
  const filePath = historyPath(id, historyDir);
  const record = await readHistoryFile(filePath);
  const updated: HistoryRecord = {
    ...record,
    updatedAt: new Date().toISOString(),
    summary: { ...(record.summary ?? emptySummary()), tags: input.tags },
    usage: input.usage ? [...(record.usage ?? []), ...input.usage] : record.usage,
  };
  if (input.tagsEdited !== undefined) updated.tagsEdited = input.tagsEdited;

  await writeFile(filePath, JSON.stringify(updated, null, 2), "utf-8");
  return updated;
}

/**
 * Stdin payload of `nota history apply-enrichment` (the hidden plumbing verb
 * the macOS app persists edits through). `summary` is the replacement
 * narrative text; `tags` replace verbatim — an edit is the user's list,
 * merging only applies to regeneration.
 */
export interface EnrichmentPatch {
  summary?: string;
  tags?: string[];
  summaryEdited?: boolean;
  tagsEdited?: boolean;
  /**
   * New value for the record's `summaryOutdated` flag; omitted = keep the
   * current value. The app dismisses the "Regenerate summary" affordance
   * through this (decision 5).
   */
  summaryOutdated?: boolean;
}

/**
 * Apply a manual-edit patch to a record: record-first (E3-f), edited flags
 * set exactly as given. A non-empty summary flips `status` to `completed`
 * (E3-d); tags alone never do.
 */
export async function applyEnrichmentToRecord(
  id: string,
  patch: EnrichmentPatch,
  historyDir = DEFAULT_HISTORY_DIR,
): Promise<HistoryRecord> {
  const filePath = historyPath(id, historyDir);
  const record = await readHistoryFile(filePath);
  const updated: HistoryRecord = {
    ...record,
    updatedAt: new Date().toISOString(),
  };
  if (patch.summary !== undefined || patch.tags !== undefined) {
    const summary = { ...(record.summary ?? emptySummary()) };
    if (patch.summary !== undefined) summary.narrative = patch.summary;
    if (patch.tags !== undefined) summary.tags = patch.tags;
    updated.summary = summary;
  }
  if (patch.summary !== undefined && patch.summary.trim().length > 0) {
    updated.status = "completed";
  }
  if (patch.summaryEdited !== undefined) updated.summaryEdited = patch.summaryEdited;
  if (patch.tagsEdited !== undefined) updated.tagsEdited = patch.tagsEdited;
  if (patch.summaryOutdated !== undefined) {
    updated.summaryOutdated = patch.summaryOutdated;
  }

  await writeFile(filePath, JSON.stringify(updated, null, 2), "utf-8");
  return updated;
}

export async function listHistoryRecords(
  historyDir = DEFAULT_HISTORY_DIR,
): Promise<HistoryRecord[]> {
  let entries: string[];
  try {
    entries = await readdir(historyDir);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      return [];
    }
    throw error;
  }

  const records = await Promise.all(
    entries
      .filter((entry) => entry.endsWith(".json"))
      .map((entry) => readHistoryFile(path.join(historyDir, entry))),
  );

  return records.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
}

export async function loadHistoryRecord(
  idOrPrefix: string,
  historyDir = DEFAULT_HISTORY_DIR,
): Promise<HistoryRecord> {
  const exactPath = historyPath(idOrPrefix, historyDir);
  try {
    return await readHistoryFile(exactPath);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
      throw error;
    }
  }

  const matches = (await listHistoryRecords(historyDir)).filter((record) =>
    record.id.startsWith(idOrPrefix),
  );
  if (matches.length === 1) {
    return matches[0];
  }
  if (matches.length > 1) {
    throw new Error(`History id prefix is ambiguous: ${idOrPrefix}`);
  }
  throw new Error(`History record not found: ${idOrPrefix}`);
}

export interface RenameSpeakerResult {
  record: HistoryRecord;
  /** How many transcript segments carried the old label. */
  segmentsRenamed: number;
  /** True when the stored `.pcm` clip was moved to the new label's path. */
  clipRenamed: boolean;
  /** True when the output markdown existed and its transcript lines changed. */
  outputRewritten: boolean;
}

/**
 * Rename a diarized speaker label everywhere the record's text carries it:
 * `segments[].speaker`, the stored clip (file + `speakerClips` map entry),
 * and the `**<label>:**` transcript lines of the output markdown. The
 * labelless `transcriptText` and any existing summary are untouched — a
 * summary regenerated after this rename reads the renamed segments and picks
 * the name up for free, which is the whole point.
 *
 * Merging into a name that already labels another speaker is allowed (two
 * diarized labels can be the same person); in that case the target's clip is
 * left alone and the source clip stays addressable under its old key.
 */
export async function renameRecordSpeaker(
  idOrPrefix: string,
  label: string,
  newName: string,
  historyDir = DEFAULT_HISTORY_DIR,
): Promise<RenameSpeakerResult> {
  const trimmed = newName.trim();
  if (!trimmed) {
    throw new Error("New speaker name is empty.");
  }
  if (trimmed === label) {
    throw new Error(`New name is the same as the label: ${label}`);
  }

  const record = await loadHistoryRecord(idOrPrefix, historyDir);

  const known = new Set(
    record.segments.map((s) => s.speaker).filter((s): s is string => !!s),
  );
  for (const clipLabel of Object.keys(record.speakerClips ?? {})) {
    known.add(clipLabel);
  }
  if (!known.has(label)) {
    throw new Error(
      `No speaker labeled "${label}" in history "${record.id}". ` +
        `Known labels: ${[...known].join(", ") || "(none)"}`,
    );
  }

  let segmentsRenamed = 0;
  const segments = record.segments.map((seg) => {
    if (seg.speaker !== label) return seg;
    segmentsRenamed += 1;
    return { ...seg, speaker: trimmed };
  });

  // Move the stored clip so a later enroll from this record finds it under
  // the name the transcript now shows. On a merge (target clip already
  // exists) both entries are kept — never overwrite or delete a voice clip.
  let clipRenamed = false;
  let speakerClips = record.speakerClips;
  const clipRel = record.speakerClips?.[label];
  if (clipRel) {
    const from = speakerClipPath(record.id, label, historyDir);
    const to = speakerClipPath(record.id, trimmed, historyDir);
    const fromExists = await access(from).then(() => true, () => false);
    const toExists = await access(to).then(() => true, () => false);
    if (fromExists && !toExists) {
      await rename(from, to);
      speakerClips = { ...record.speakerClips };
      delete speakerClips[label];
      speakerClips[trimmed] = path.relative(historyDir, to);
      clipRenamed = true;
    }
  }

  // Rewrite the transcript's label grammar in the output markdown. Bold-colon
  // anchored on purpose: `**Speaker 2:**` is how write.ts renders a transcript
  // line, while a bare "Speaker 2" in the narrative belongs to the summary and
  // is regenerated rather than string-patched.
  let outputRewritten = false;
  if (record.outputPath) {
    try {
      const md = await readFile(record.outputPath, "utf-8");
      const rewritten = md.split(`**${label}:**`).join(`**${trimmed}:**`);
      if (rewritten !== md) {
        await writeFile(record.outputPath, rewritten, "utf-8");
        outputRewritten = true;
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        throw error;
      }
    }
  }

  const updated: HistoryRecord = {
    ...record,
    updatedAt: new Date().toISOString(),
    segments,
    speakerClips,
    // A rename never touches the existing summary, so a completed record's
    // narrative now references a stale label: surface the one-click
    // "Regenerate summary" affordance (decision 5).
    ...(record.summary ? { summaryOutdated: true } : {}),
  };
  await writeFile(
    historyPath(record.id, historyDir),
    JSON.stringify(updated, null, 2),
    "utf-8",
  );

  return { record: updated, segmentsRenamed, clipRenamed, outputRewritten };
}

/**
 * Find the newest history record whose source audio has the given content
 * hash, or `null` if none. Records without a `contentHash` (written before
 * duplicate detection shipped) never match. The caller decides what to do
 * with a hit (e.g. only skip reprocessing when the match is `completed` and
 * its output file still exists).
 */
export async function findHistoryByHash(
  contentHash: string,
  historyDir = DEFAULT_HISTORY_DIR,
): Promise<HistoryRecord | null> {
  // Reject empty (legacy/unknown) and malformed hashes so a garbage value can
  // never coincidentally match. A SHA-256 digest is exactly 64 lowercase hex
  // chars; legacy records have `contentHash === undefined` and never match.
  if (!/^[a-f0-9]{64}$/.test(contentHash)) return null;
  // listHistoryRecords already returns newest-first.
  const records = await listHistoryRecords(historyDir);
  return records.find((record) => record.contentHash === contentHash) ?? null;
}

export function formatHistoryList(records: HistoryRecord[]): string {
  if (records.length === 0) {
    return "No Nota history records found.";
  }

  const rows = records.map((record) =>
    [
      record.createdAt,
      record.id,
      record.provider,
      record.status,
      record.sourceName,
    ].join("\t"),
  );
  return ["Created\tID\tProvider\tStatus\tSource", ...rows].join("\n");
}

export type SuggestionDecision = Extract<SuggestionState, "accepted" | "dismissed">;

/**
 * Apply a user decision to a pending suggestion on a record (decision 4):
 * `accepted`/`dismissed` are written with a `decidedAt` stamp and the record
 * is persisted. Only pending suggestions are decid(e)able — an already
 * decided or unknown label throws. Dismissal touches nothing else; acceptance
 * is composed by the CLI verb (rename + enroll), not by this helper.
 */
export async function setSuggestionState(
  idOrPrefix: string,
  label: string,
  state: SuggestionDecision,
  historyDir = DEFAULT_HISTORY_DIR,
): Promise<HistoryRecord> {
  const record = await loadHistoryRecord(idOrPrefix, historyDir);
  const suggestions = record.suggestions ?? [];
  const target = suggestions.find(
    (s) => s.label === label && s.state === "pending",
  );
  if (!target) {
    const pending = suggestions
      .filter((s) => s.state === "pending")
      .map((s) => s.label);
    throw new Error(
      `No pending suggestion for label "${label}" in history "${record.id}". ` +
        `Pending suggestions: ${pending.join(", ") || "(none)"}`,
    );
  }
  const updated: HistoryRecord = {
    ...record,
    updatedAt: new Date().toISOString(),
    suggestions: suggestions.map((s) =>
      s === target
        ? { ...s, state, decidedAt: new Date().toISOString() }
        : s,
    ),
  };
  await writeFile(
    historyPath(record.id, historyDir),
    JSON.stringify(updated, null, 2),
    "utf-8",
  );
  return updated;
}
