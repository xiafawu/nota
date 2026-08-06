/**
 * `nota history storage | delete-audio | delete` — the figure that makes the
 * store findable, and the only two verbs that shrink it (XIA-436).
 *
 * There is no scheduled or automatic form of any of this, and there may not
 * be: Nota never reclaims a byte on its own. Every function here runs because
 * the owner typed a verb or pressed a button.
 *
 * Repo CLI conventions, followed exactly: scriptable rows on **stdout**,
 * human confirmation and header lines on **stderr**, non-zero exit when a
 * referenced record is missing. The prompt is injectable (`ask`/`write`/`out`)
 * the same way `resolveSpeakersInteractively` is, so every branch below is
 * driven from a test without a TTY.
 */

import { createInterface } from "node:readline";
import {
  computeStorage,
  deleteRecord,
  deleteRecordAudio,
  formatBytes,
  parseOlderThan,
  selectOlderThan,
  type RecordStorage,
  type StorageSummary,
} from "../pipeline/storage.js";
import { DEFAULT_HISTORY_DIR, loadHistoryRecord } from "../pipeline/history.js";

export class StorageError extends Error {
  constructor(
    message: string,
    readonly exitCode = 1,
  ) {
    super(message);
    this.name = "StorageError";
  }
}

export interface StorageIO {
  historyDir?: string;
  now?: Date;
  /** stdout — scriptable rows. */
  out?: (line: string) => void;
  /** stderr — headers, confirmations, totals. */
  write?: (message: string) => void;
  /** Returns the owner's raw answer to a yes/no question. */
  ask?: (question: string) => Promise<string>;
  /** Whether a human is there to answer. Defaults to the real stdin. */
  isTTY?: boolean;
}

function stdout(io: StorageIO): (line: string) => void {
  return io.out ?? ((line: string) => process.stdout.write(`${line}\n`));
}

function stderr(io: StorageIO): (message: string) => void {
  return io.write ?? ((message: string) => process.stderr.write(`${message}\n`));
}

// MARK: - storage

/**
 * `nota history storage` — per-record and total sizes, oldest first.
 * Read-only: this verb deletes nothing and has no flag that could.
 *
 * With `--json` it emits the whole `StorageSummary` instead, which is what the
 * macOS Usage sheet decodes. The app does NOT recompute these figures; that is
 * the point of the flag — one computation, in one place, so the sheet and this
 * verb can never disagree about how big the store is.
 */
export async function storageCommand(
  options: StorageIO & { json?: boolean } = {},
): Promise<StorageSummary> {
  const historyDir = options.historyDir ?? DEFAULT_HISTORY_DIR;
  const summary = await computeStorage(historyDir, options.now ?? new Date());
  const out = stdout(options);
  const write = stderr(options);

  if (options.json) {
    out(JSON.stringify(summary, null, 2));
    return summary;
  }

  write("Created\tID\tAudio\tTotal\tSource");
  if (summary.count === 0) {
    write("No Nota history records found.");
    return summary;
  }
  for (const row of summary.records) {
    out(
      [
        row.createdAt,
        row.id,
        // A record that keeps no audio says so in words rather than as a zero:
        // "0 B" would read as a recording that exists and is empty.
        row.audioBytes === null ? "audio not kept" : formatBytes(row.audioBytes),
        formatBytes(row.totalBytes),
        row.sourceName,
      ].join("\t"),
    );
  }
  write(
    `${summary.count} record(s), ${formatBytes(summary.totalBytes)} total ` +
      `(${formatBytes(summary.audioBytes)} of it audio).`,
  );
  write("Nota never deletes recordings on its own.");
  return summary;
}

// MARK: - Shared selection + confirmation

interface DeletionRequest {
  id?: string;
  olderThan?: string;
  yes?: boolean;
}

/**
 * Resolve what a delete verb will act on: either the one named record, or
 * every record older than the given age. Exactly one of the two is required —
 * a delete verb with no target is a mistake, and one with both is ambiguous
 * about which the owner meant.
 */
async function resolveTargets(
  request: DeletionRequest,
  options: StorageIO,
): Promise<RecordStorage[]> {
  const historyDir = options.historyDir ?? DEFAULT_HISTORY_DIR;
  const now = options.now ?? new Date();

  if (request.id && request.olderThan) {
    throw new StorageError(
      "Give either a record id or --older-than, not both.",
    );
  }
  if (!request.id && !request.olderThan) {
    throw new StorageError("Give a record id, or --older-than <age> (e.g. 90d).");
  }

  const summary = await computeStorage(historyDir, now);

  if (request.id) {
    // Resolved through loadHistoryRecord so an id PREFIX works here exactly as
    // it does for every other history verb, and so a missing record throws
    // (exit non-zero) rather than silently selecting nothing.
    const record = await loadHistoryRecord(request.id, historyDir);
    const row = summary.records.find((candidate) => candidate.id === record.id);
    if (!row) {
      throw new StorageError(`History record not found: ${request.id}`);
    }
    return [row];
  }

  return selectOlderThan(summary.records, parseOlderThan(request.olderThan!, now));
}

/**
 * Print the full list and the total, then ask — the standing shape for
 * `--older-than`, and used for a single id too, because deletion is the one
 * irreversible thing this app does and a preview costs nothing.
 *
 * Returns whether to proceed. `--yes` skips the question; without it and with
 * no TTY the answer is NO and the caller exits non-zero, because a
 * non-interactive run that cannot be asked must never be assumed to consent.
 */
async function confirm(
  rows: RecordStorage[],
  bytes: number,
  what: string,
  stays: string,
  request: DeletionRequest,
  options: StorageIO,
): Promise<boolean> {
  const out = stdout(options);
  const write = stderr(options);

  write(`Created\tID\t${what === "audio" ? "Audio" : "Total"}\tSource`);
  for (const row of rows) {
    out(
      [
        row.createdAt,
        row.id,
        formatBytes(what === "audio" ? (row.audioBytes ?? 0) : row.totalBytes),
        row.sourceName,
      ].join("\t"),
    );
  }
  write(
    `${rows.length} record(s), ${formatBytes(bytes)} to delete. ${stays} ` +
      "This cannot be undone.",
  );

  if (request.yes) return true;

  const isTTY = options.isTTY ?? Boolean(process.stdin.isTTY);
  if (!isTTY && !options.ask) {
    throw new StorageError(
      "Refusing to delete without confirmation. Re-run with --yes to confirm non-interactively.",
    );
  }

  const rl = options.ask
    ? null
    : createInterface({ input: process.stdin, output: process.stderr });
  const ask =
    options.ask ??
    ((question: string) =>
      new Promise<string>((resolve) => rl!.question(question, resolve)));
  try {
    const answer = (await ask("Delete? [y/N] ")).trim().toLowerCase();
    return answer === "y" || answer === "yes";
  } finally {
    rl?.close();
  }
}

// MARK: - delete-audio

/**
 * `nota history delete-audio <id> | --older-than <age>` — remove the kept
 * recording and leave everything else.
 *
 * The record survives: transcript, summary, segments, speaker clips and the
 * exported markdown are all still there and still readable by both the app and
 * the CLI. This is the containment rule's safe direction, and the reason the
 * verb exists at all — audio is almost all of the store's size and almost none
 * of its value once a transcript has been made.
 */
export async function deleteAudioCommand(
  request: DeletionRequest,
  options: StorageIO = {},
): Promise<void> {
  const historyDir = options.historyDir ?? DEFAULT_HISTORY_DIR;
  const write = stderr(options);
  const selected = await resolveTargets(request, options);

  // Records keeping no audio are already in the state this verb produces.
  // Named quietly and skipped — never an error (a legacy record simply has no
  // audio of ours), and never counted into the bytes we promise to free.
  const withAudio = selected.filter((row) => row.audioBytes !== null);
  const skipped = selected.length - withAudio.length;
  if (skipped > 0) {
    write(`${skipped} record(s) keep no audio — nothing to delete there.`);
  }
  if (withAudio.length === 0) {
    write("No audio to delete.");
    return;
  }

  const bytes = withAudio.reduce((sum, row) => sum + (row.audioBytes ?? 0), 0);
  const proceed = await confirm(
    withAudio,
    bytes,
    "audio",
    "The transcript, summary and markers stay.",
    request,
    options,
  );
  if (!proceed) {
    write("Cancelled. Nothing was deleted.");
    return;
  }

  let freed = 0;
  for (const row of withAudio) {
    const result = await deleteRecordAudio(row.id, historyDir);
    freed += result.freedBytes;
    write(
      `Deleted audio for ${row.id} (${formatBytes(result.freedBytes)}). Record kept.`,
    );
  }
  write(`Freed ${formatBytes(freed)}. ${withAudio.length} record(s) kept.`);
}

// MARK: - delete

/**
 * `nota history delete <id> | --older-than <age>` — remove the record JSON and
 * its whole assets folder, audio included.
 *
 * The containment rule's downward direction, and the only verb that takes a
 * transcript. The exported `.md` is NOT deleted — it lives outside `~/.nota`,
 * often beside the owner's own audio, and Nota does not own it. Each one that
 * survives is named on stderr so the owner knows where their notes still are.
 */
export async function deleteRecordCommand(
  request: DeletionRequest,
  options: StorageIO = {},
): Promise<void> {
  const historyDir = options.historyDir ?? DEFAULT_HISTORY_DIR;
  const write = stderr(options);
  const selected = await resolveTargets(request, options);

  if (selected.length === 0) {
    write("No records matched.");
    return;
  }

  const bytes = selected.reduce((sum, row) => sum + row.totalBytes, 0);
  const proceed = await confirm(
    selected,
    bytes,
    "record",
    "The transcript and its audio both go; the exported .md file stays.",
    request,
    options,
  );
  if (!proceed) {
    write("Cancelled. Nothing was deleted.");
    return;
  }

  let freed = 0;
  const kept: string[] = [];
  for (const row of selected) {
    const result = await deleteRecord(row.id, historyDir);
    freed += result.freedBytes;
    if (result.outputPath) kept.push(result.outputPath);
    write(`Deleted record ${row.id} (${formatBytes(result.freedBytes)}).`);
  }
  write(`Freed ${formatBytes(freed)}. ${selected.length} record(s) deleted.`);
  for (const output of kept) {
    write(`Kept exported markdown: ${output}`);
  }
}
