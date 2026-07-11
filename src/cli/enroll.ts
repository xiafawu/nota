import { access, readFile } from "node:fs/promises";
import {
  DEFAULT_SPEAKERS_FILE,
  encodeProfile,
  loadProfiles,
  saveProfiles,
} from "../pipeline/speakers.js";
import {
  loadHistoryRecord,
  speakerClipPath,
  DEFAULT_HISTORY_DIR,
  type HistoryRecord,
} from "../pipeline/history.js";
import {
  isEagleAvailable,
  enrollProfile,
  InsufficientSpeechError,
} from "../pipeline/eagle.js";

export interface EnrollOptions {
  storePath?: string;
  historyDir?: string;
  /** Picovoice AccessKey; falls back to PICOVOICE_ACCESS_KEY. */
  accessKey?: string;
}

// Exit codes (the macOS EnrollQueue maps these to chip indicators):
//   0 success
//   2 history record not found
//   3 stored speaker clip missing
//   4 Eagle unavailable (no AccessKey)
//   5 insufficient speech to enroll
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
  const accessKey = options?.accessKey ?? process.env.PICOVOICE_ACCESS_KEY;

  // 0. Eagle must be available (exit 4).
  if (!isEagleAvailable(accessKey)) {
    throw new EnrollError(
      "PICOVOICE_ACCESS_KEY is required for Eagle enrollment. " +
        "Get a free key at https://console.picovoice.ai.",
      4,
    );
  }

  // 1. Load history record (exit 2 if not found).
  let record: HistoryRecord;
  try {
    record = await loadHistoryRecord(historyId, historyDir);
  } catch (error) {
    throw new EnrollError(
      error instanceof Error ? error.message : String(error),
      2,
    );
  }

  // 2. Resolve the stored clip for this label (exit 3 if missing).
  const rel = record.speakerClips?.[label];
  const clipPath = rel
    ? speakerClipPath(record.id, label, historyDir)
    : null;
  if (!clipPath || !(await fileExists(clipPath))) {
    const labels = Object.keys(record.speakerClips ?? {});
    throw new EnrollError(
      `No stored audio clip for label "${label}" in history "${historyId}". ` +
        `Available labels with clips: ${labels.join(", ") || "(none)"}`,
      3,
    );
  }

  // 3. Decode the stored PCM and build an Eagle profile (exit 5 if too little
  //    speech, exit 1 for any other Eagle failure).
  const buf = await readFile(clipPath);
  const pcm = new Int16Array(buf.length / 2);
  for (let i = 0; i < pcm.length; i++) pcm[i] = buf.readInt16LE(i * 2);

  let profileBytes: Uint8Array;
  try {
    profileBytes = await enrollProfile(accessKey!, pcm);
  } catch (error) {
    if (error instanceof InsufficientSpeechError) {
      throw new EnrollError(error.message, 5);
    }
    throw new EnrollError(
      error instanceof Error ? error.message : String(error),
      1,
    );
  }

  // 4. Append the voiceprint to the named profile (v3 pointer model).
  const store = await loadProfiles(storePath);
  const now = new Date().toISOString();
  const voiceprint = {
    id: now,
    profile: encodeProfile(profileBytes),
    enrolledAt: now,
    source: record.sourceName,
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
