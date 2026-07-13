import { AssemblyAI, type TranscribeParams } from "assemblyai";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import type { TranscriptSegment, TranscriptionResult } from "./transcribe.js";

const execFileAsync = promisify(execFile);

const QTA_EXTENSIONS = new Set([".qta"]);

async function convertToM4a(inputPath: string): Promise<string> {
  const tmpPath = path.join(
    tmpdir(),
    `nota-${Date.now()}${Math.random().toString(36).slice(2)}.m4a`
  );
  await execFileAsync("ffmpeg", [
    "-y",
    "-i", inputPath,
    "-acodec", "aac",
    "-q:a", "4",
    tmpPath,
  ]);
  return tmpPath;
}

function speakerLabel(letter: string): string {
  // AssemblyAI returns "A", "B", "C" etc. → "Speaker 1", "Speaker 2", ...
  const index = letter.charCodeAt(0) - "A".charCodeAt(0) + 1;
  return `Speaker ${index}`;
}

export interface AssemblyAIOptions {
  apiKey: string;
  /** AssemblyAI speech_model id (e.g. "universal", "slam-1", "nano"). */
  speechModel?: string;
  numSpeakers?: number;
  language?: string;
}

export async function transcribeWithAssemblyAI(
  inputPath: string,
  options: AssemblyAIOptions
): Promise<TranscriptionResult> {
  const client = new AssemblyAI({ apiKey: options.apiKey });

  // Convert unsupported formats (e.g. .qta) to .m4a
  const ext = path.extname(inputPath).toLowerCase();
  let uploadPath = inputPath;
  let tmpFile: string | null = null;

  if (QTA_EXTENSIONS.has(ext)) {
    tmpFile = await convertToM4a(inputPath);
    uploadPath = tmpFile;
  }

  try {
    const params = {
      audio: uploadPath,
      speaker_labels: true,
      ...(options.speechModel ? { speech_model: options.speechModel } : {}),
      ...(options.numSpeakers ? { speakers_expected: options.numSpeakers } : {}),
      ...(options.language ? { language_code: options.language } : {}),
    } as TranscribeParams;

    const transcript = await client.transcripts.transcribe(params);

    if (transcript.status === "error") {
      throw new Error(`AssemblyAI transcription failed: ${transcript.error}`);
    }

    const segments: TranscriptSegment[] = (transcript.utterances ?? []).map(
      (utterance) => ({
        start: utterance.start / 1000, // ms → seconds
        end: utterance.end / 1000,
        text: utterance.text,
        speaker: speakerLabel(utterance.speaker),
      })
    );

    return {
      segments,
      text: transcript.text ?? "",
    };
  } finally {
    if (tmpFile) {
      await unlink(tmpFile).catch(() => {});
    }
  }
}
