import path from "node:path";
import { access } from "node:fs/promises";
import {
  DEFAULT_SPEAKERS_FILE,
  extractEmbeddings,
  loadProfiles,
  saveProfiles,
} from "../pipeline/speakers.js";
import {
  loadHistoryRecord,
  DEFAULT_HISTORY_DIR,
  type HistoryRecord,
} from "../pipeline/history.js";

export interface EnrollOptions {
  storePath?: string;
  historyDir?: string;
}

// Exit codes per spec:
//   0 success
//   2 history record not found
//   3 audio file missing
//   4 python/pyannote unavailable
//   1 other

class EnrollError extends Error {
  constructor(
    message: string,
    readonly exitCode: number,
  ) {
    super(message);
    this.name = "EnrollError";
  }
}

async function fileExists(filePath: string): Promise<boolean> {
  try {
    await access(filePath);
    return true;
  } catch {
    return false;
  }
}

export async function enrollSpeaker(
  historyId: string,
  label: string,
  name: string,
  options?: EnrollOptions,
): Promise<void> {
  const storePath = options?.storePath ?? DEFAULT_SPEAKERS_FILE;
  const historyDir = options?.historyDir ?? DEFAULT_HISTORY_DIR;

  // 1. Load history record (exit 2 if not found)
  let record: HistoryRecord;
  try {
    record = await loadHistoryRecord(historyId, historyDir);
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    throw new EnrollError(msg, 2);
  }

  // 2. Filter segments by speaker label
  const filteredSegments = record.segments.filter(
    (seg) => seg.speaker === label,
  );
  if (filteredSegments.length === 0) {
    throw new EnrollError(
      `Speaker label "${label}" not found in history record "${historyId}". ` +
        `Available labels: ${[...new Set(record.segments.map((s) => s.speaker).filter(Boolean))].join(", ") || "(none)"}`,
      1,
    );
  }

  // 3. Verify audio file exists (exit 3 if missing)
  const audioPath = record.sourcePath;
  if (!(await fileExists(audioPath))) {
    throw new EnrollError(
      `Audio file not found: ${audioPath}`,
      3,
    );
  }

  // 4. Extract embeddings (exit 4 on python/pyannote unavailable)
  let embeddings: Record<string, number[]>;
  try {
    embeddings = await extractEmbeddings(audioPath, filteredSegments);
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    // Distinguish pyannote/python unavailability from other extraction errors.
    // extractEmbeddings spawns PYTHON_BIN; if it fails to start or exits with
    // a message about pyannote/import errors we map to exit 4.
    const isPythonError =
      msg.includes("ENOENT") ||
      msg.includes("No such file") ||
      msg.includes("ModuleNotFoundError") ||
      msg.includes("ImportError") ||
      msg.includes("pyannote");
    throw new EnrollError(msg, isPythonError ? 4 : 1);
  }

  const embedding = embeddings[label];
  if (!embedding) {
    throw new EnrollError(
      `Embedding extraction returned no result for label "${label}". ` +
        `Available keys: ${Object.keys(embeddings).join(", ") || "(none)"}`,
      1,
    );
  }

  // 5–7. Append voiceprint to the named profile (v2 pointer model)
  const store = await loadProfiles(storePath);
  const now = new Date().toISOString();
  const voiceprint = {
    id: now,
    embedding,
    enrolledAt: now,
    source: path.basename(audioPath),
  };

  const existing = store.speakers[name];
  if (existing) {
    existing.voiceprints.push(voiceprint);
  } else {
    store.speakers[name] = { voiceprints: [voiceprint] };
  }

  await saveProfiles(store, storePath);

  process.stderr.write(
    `Enrolled "${label}" from history "${historyId}" as "${name}".\n`,
  );
}

export { EnrollError };
