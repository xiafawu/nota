import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import type { Provider } from "../config.js";
import type { TranscriptSegment } from "./transcribe.js";
import type { MeetingSummary } from "./summarize.js";

export type HistoryStatus = "transcribed" | "completed";

export interface HistoryOptions {
  language?: string;
  diarize: boolean;
  identify: boolean;
  numSpeakers?: number;
  model: string;
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
  durationMinutes: number;
  transcriptText: string;
  segments: TranscriptSegment[];
  summary?: MeetingSummary;
  outputPath?: string;
  status: HistoryStatus;
}

export interface CreateHistoryInput {
  sourcePath: string;
  provider: Provider;
  options: HistoryOptions;
  durationMinutes: number;
  transcriptText: string;
  segments: TranscriptSegment[];
  capturedAt?: string | null;
  contentHash?: string;
  outputPath?: string;
}

export interface CompleteHistoryInput {
  summary: MeetingSummary;
  outputPath: string;
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
    durationMinutes: input.durationMinutes,
    transcriptText: input.transcriptText,
    segments: input.segments,
    outputPath: input.outputPath,
    status: "transcribed",
  };

  await mkdir(historyDir, { recursive: true });
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
    status: "completed",
  };

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
