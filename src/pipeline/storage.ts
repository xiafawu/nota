/**
 * What a Nota record costs on disk, and the only two code paths that make it
 * cost less (XIA-436).
 *
 * The visible figure IS the retention policy. Nota records audio for as long as
 * the owner keeps recording and never reclaims a byte on its own: no sweep, no
 * scheduled cleanup, no deletion on failure. The deal the owner is asked to
 * accept — unbounded growth — is only fair if they can always see the number
 * and always delete by hand, which is what this module is for. Nothing here is
 * ever called on a timer; every function below is downstream of a verb the
 * owner typed or a button they pressed.
 *
 * **The containment rule governs everything here.** Deleting the transcript
 * deletes the audio; deleting the audio never touches the transcript. One
 * direction. `deleteRecordAudio` leaves the record — transcript, segments,
 * summary, speaker clips, markers — exactly as it found it minus two fields;
 * `deleteRecord` takes the whole record and its assets folder. There is no
 * cascade upward, and no partial delete that leaves an assets folder behind.
 *
 * **The exported `.md` is never deleted.** It lives outside `~/.nota` (usually
 * beside the owner's own audio), Nota does not own it, and `deleteRecord`
 * reports its path rather than removing it.
 */

import { readdir, rm, stat, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  DEFAULT_HISTORY_DIR,
  listHistoryRecords,
  loadHistoryRecord,
  type HistoryRecord,
} from "./history.js";
import type { HistoryStatus } from "./history-status.js";

// MARK: - Sizes

/** One record's footprint inside the store. */
export interface RecordStorage {
  id: string;
  createdAt: string;
  sourceName: string;
  status: HistoryStatus;
  /**
   * Bytes of the kept recording, or `null` when this record keeps no audio —
   * either a legacy record written before record-first recording (it has only
   * a `sourcePath` pointing at the owner's own file, which is NOT ours to
   * count or to delete) or one whose audio the owner already deleted. Read as
   * "audio not kept": quietly, once, never as an error.
   */
  audioBytes: number | null;
  /** The whole `<id>.assets/` folder: the recording plus any speaker clips. */
  assetsBytes: number;
  /** The record JSON itself. */
  recordBytes: number;
  /** What deleting this record would reclaim: `assetsBytes + recordBytes`. */
  totalBytes: number;
}

/**
 * The store's totals. `count`, `totalBytes`, `oldestCreatedAt` and
 * `thisMonthBytes` are exactly the four figures the Usage sheet shows — the
 * app decodes this object rather than recomputing it, so the sheet and
 * `nota history storage` can never disagree.
 */
export interface StorageSummary {
  /** Oldest first. */
  records: RecordStorage[];
  count: number;
  totalBytes: number;
  /** Σ of the audio alone: what `delete-audio` on everything would reclaim. */
  audioBytes: number;
  oldestCreatedAt: string | null;
  /** Σ over records created in the calendar month of `now`. */
  thisMonthBytes: number;
}

/** A record's own assets folder: `<historyDir>/<id>.assets`. */
export function recordAssetsDir(id: string, historyDir = DEFAULT_HISTORY_DIR): string {
  return path.join(historyDir, `${id}.assets`);
}

/** Total bytes of a directory tree; 0 when it does not exist. */
async function directoryBytes(dir: string): Promise<number> {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return 0;
    throw error;
  }
  let total = 0;
  for (const entry of entries) {
    const child = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      total += await directoryBytes(child);
    } else {
      total += await fileBytes(child);
    }
  }
  return total;
}

/** Size of one file; 0 when it is missing. */
async function fileBytes(file: string): Promise<number> {
  try {
    return (await stat(file)).size;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return 0;
    throw error;
  }
}

/**
 * Where a record's kept audio actually is, or `null` when it keeps none.
 *
 * Deliberately NOT `recordAudioPath` from history.ts. That helper falls back
 * to the absolute `sourcePath` so a legacy record can still be *played*, and
 * that path points at the owner's own file somewhere outside `~/.nota`. For
 * accounting it would count bytes the store does not hold, and for deletion it
 * would hand an unlink the owner's original recording. Storage and deletion
 * therefore see only what lives inside the record's own assets folder.
 */
export function keptAudioPath(
  record: Pick<HistoryRecord, "id" | "audioPath">,
  historyDir = DEFAULT_HISTORY_DIR,
): string | null {
  if (!record.audioPath) return null;
  const assets = recordAssetsDir(record.id, historyDir);
  const resolved = path.resolve(assets, record.audioPath);
  // `audioPath` is read off a JSON file on disk. A value that climbs out of
  // the assets folder is refused rather than followed: this path is handed to
  // unlink, and the one irreversible thing this app does may not be aimable at
  // an arbitrary file by editing a record.
  const withinAssets =
    resolved === assets || resolved.startsWith(assets + path.sep);
  return withinAssets ? resolved : null;
}

/** One record's footprint. */
export async function recordStorage(
  record: HistoryRecord,
  historyDir = DEFAULT_HISTORY_DIR,
): Promise<RecordStorage> {
  const recordBytes = await fileBytes(path.join(historyDir, `${record.id}.json`));
  const assetsBytes = await directoryBytes(recordAssetsDir(record.id, historyDir));
  const audio = keptAudioPath(record, historyDir);
  // The file on disk is the authority, not the stored `audioBytes` — an
  // interrupted record's field can lag what was actually captured. A record
  // that names an audio file that is no longer there keeps no audio.
  let audioBytes: number | null = null;
  if (audio) {
    const size = await fileBytes(audio);
    audioBytes = size > 0 ? size : null;
  }
  return {
    id: record.id,
    createdAt: record.createdAt,
    sourceName: record.sourceName,
    status: record.status,
    audioBytes,
    assetsBytes,
    recordBytes,
    totalBytes: assetsBytes + recordBytes,
  };
}

/** Every record's footprint plus the totals, oldest first. */
export async function computeStorage(
  historyDir = DEFAULT_HISTORY_DIR,
  now = new Date(),
): Promise<StorageSummary> {
  const records = await listHistoryRecords(historyDir);
  const rows = await Promise.all(
    records.map((record) => recordStorage(record, historyDir)),
  );
  // listHistoryRecords is newest-first; storage reads oldest-first because the
  // oldest records are the ones an owner is deciding about.
  rows.sort((a, b) => a.createdAt.localeCompare(b.createdAt));

  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1);
  let totalBytes = 0;
  let audioBytes = 0;
  let thisMonthBytes = 0;
  for (const row of rows) {
    totalBytes += row.totalBytes;
    audioBytes += row.audioBytes ?? 0;
    const created = new Date(row.createdAt);
    if (!Number.isNaN(created.getTime()) && created >= monthStart) {
      thisMonthBytes += row.totalBytes;
    }
  }

  return {
    records: rows,
    count: rows.length,
    totalBytes,
    audioBytes,
    oldestCreatedAt: rows[0]?.createdAt ?? null,
    thisMonthBytes,
  };
}

// MARK: - Deletion

export interface DeleteAudioResult {
  id: string;
  /** False when the record kept no audio — already in the asked-for state. */
  deleted: boolean;
  freedBytes: number;
}

/**
 * Delete a record's recording and nothing else.
 *
 * The record survives in full: transcript, segments, summary, tags, speaker
 * clips and the exported markdown are all untouched, and it goes on reading
 * exactly as it did in both the app and the CLI. Only `audioPath` and
 * `audioBytes` are cleared, which is how every reader learns the audio is no
 * longer kept (`RecordStorage.audioBytes === null` → "audio not kept").
 *
 * Idempotent: a record that keeps no audio is reported as `deleted: false`
 * rather than failing, and a legacy record's `sourcePath` — the owner's own
 * file, outside the store — is never touched. `keptAudioPath` is what makes
 * that structural rather than a convention.
 */
export async function deleteRecordAudio(
  idOrPrefix: string,
  historyDir = DEFAULT_HISTORY_DIR,
): Promise<DeleteAudioResult> {
  const record = await loadHistoryRecord(idOrPrefix, historyDir);
  const audio = keptAudioPath(record, historyDir);
  if (!audio) {
    return { id: record.id, deleted: false, freedBytes: 0 };
  }

  const freedBytes = await fileBytes(audio);
  try {
    await unlink(audio);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }

  // Spread-and-delete, never a rebuild: the CLI and the app both write fields
  // this function does not model, and a delete verb may not drop them.
  const updated: HistoryRecord = { ...record, updatedAt: new Date().toISOString() };
  delete updated.audioPath;
  delete updated.audioBytes;
  await writeFile(
    path.join(historyDir, `${record.id}.json`),
    JSON.stringify(updated, null, 2),
    "utf-8",
  );

  return { id: record.id, deleted: true, freedBytes };
}

export interface DeleteRecordResult {
  id: string;
  freedBytes: number;
  /**
   * The exported markdown this record pointed at, if any. Reported so the
   * caller can say it was KEPT — Nota never deletes it. It lives outside
   * `~/.nota`, often beside the owner's source audio.
   */
  outputPath: string | null;
}

/**
 * Delete a record: its JSON and its whole `<id>.assets/` folder, audio
 * included. This is the containment rule's one downward direction.
 *
 * The assets folder goes wholesale rather than file by file, so no partial
 * delete can leave an orphaned folder behind — that is the acceptance
 * condition, and a per-file loop would fail it the first time a future asset
 * type appeared. The exported `.md` is returned, never removed.
 */
export async function deleteRecord(
  idOrPrefix: string,
  historyDir = DEFAULT_HISTORY_DIR,
): Promise<DeleteRecordResult> {
  const record = await loadHistoryRecord(idOrPrefix, historyDir);
  const storage = await recordStorage(record, historyDir);

  await rm(recordAssetsDir(record.id, historyDir), { recursive: true, force: true });
  try {
    await unlink(path.join(historyDir, `${record.id}.json`));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }

  return {
    id: record.id,
    freedBytes: storage.totalBytes,
    outputPath: record.outputPath ?? null,
  };
}

// MARK: - `--older-than`

const AGE_UNIT_DAYS: Record<string, number> = {
  d: 1,
  w: 7,
  // Calendar months and years vary; these are the plain fixed readings, and
  // the help text says so. An age filter is a coarse instrument — the list is
  // always printed in full before anything is deleted, so the owner sees
  // exactly which records the number selected.
  m: 30,
  y: 365,
};

/**
 * `"90d"` → the instant 90 days before `now`. Records created strictly before
 * the returned date are the ones the filter selects.
 */
export function parseOlderThan(spec: string, now = new Date()): Date {
  const match = /^(\d+)\s*([dwmy])$/i.exec(spec.trim());
  if (!match) {
    throw new Error(
      `Invalid --older-than value "${spec}". Use a number followed by d, w, m or y (e.g. 90d).`,
    );
  }
  const amount = Number(match[1]);
  const days = AGE_UNIT_DAYS[match[2].toLowerCase()];
  return new Date(now.getTime() - amount * days * 24 * 60 * 60 * 1000);
}

/** The records created strictly before `cutoff`, oldest first. */
export function selectOlderThan(
  rows: RecordStorage[],
  cutoff: Date,
): RecordStorage[] {
  return rows
    .filter((row) => {
      const created = new Date(row.createdAt);
      // An unparseable timestamp is never selected: a destructive filter may
      // not sweep up a record it cannot date.
      return !Number.isNaN(created.getTime()) && created < cutoff;
    })
    .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
}

// MARK: - Formatting

/** `1536` → `"1.5 KB"`. Binary units, one decimal above KB. */
export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(1)} ${units[unit]}`;
}
