import path from "node:path";
import ora from "ora";
import type { AppConfig } from "./config.js";
import { OVERLAP_DURATION } from "./constants.js";
import { validateInput, checkPython, checkHuggingFaceToken } from "./pipeline/validate.js";
import { runDiarization, alignSpeakers } from "./pipeline/diarize.js";
import { chunkAudio } from "./pipeline/chunk.js";
import { transcribeChunks } from "./pipeline/transcribe.js";
import { mergeTranscriptions } from "./pipeline/merge.js";
import { summarizeTranscript } from "./pipeline/summarize.js";
import { writeOutput, defaultOutputPath } from "./pipeline/write.js";
import { getAudioDuration } from "./utils/ffmpeg.js";

export interface PipelineOptions {
  inputPath: string;
  outputPath?: string;
  config: AppConfig;
}

function log(verbose: boolean, message: string) {
  if (verbose) {
    const spinner = ora(message).start();
    return spinner;
  }
  return null;
}

export async function runPipeline(options: PipelineOptions): Promise<string> {
  const { inputPath, config } = options;
  const outputPath = options.outputPath ?? defaultOutputPath(inputPath);
  const verbose = config.verbose;

  // 1. Validate and get duration early (before file access might change)
  let spinner = log(verbose, "Validating input...");
  await validateInput(inputPath);
  let durationMinutes: number;
  try {
    const duration = await getAudioDuration(inputPath);
    durationMinutes = Math.round(duration / 60);
  } catch {
    durationMinutes = 0; // fallback if duration can't be determined
  }
  spinner?.succeed("Input validated");

  // 1b. Validate diarization requirements
  if (config.diarize) {
    spinner = log(verbose, "Checking diarization requirements...");
    await checkPython();
    checkHuggingFaceToken();
    spinner?.succeed("Diarization requirements met");
  }

  // 2. Chunk
  spinner = log(verbose, "Checking if chunking is needed...");
  const chunks = await chunkAudio(inputPath);
  spinner?.succeed(
    chunks.length === 1
      ? "File within size limit, no chunking needed"
      : `Split into ${chunks.length} chunks`
  );

  // 3. Transcribe (and diarize in parallel if enabled)
  spinner = log(verbose, config.diarize
    ? `Transcribing ${chunks.length} chunk(s) and diarizing speakers...`
    : `Transcribing ${chunks.length} chunk(s)...`
  );

  const [transcriptions, diarization] = await Promise.all([
    transcribeChunks(chunks, config.openaiApiKey, config.language),
    config.diarize ? runDiarization(inputPath) : Promise.resolve(null),
  ]);
  spinner?.succeed(config.diarize
    ? "Transcription and diarization complete"
    : "Transcription complete"
  );

  // 4. Merge
  spinner = log(verbose, "Merging transcripts...");
  let merged = mergeTranscriptions(transcriptions, OVERLAP_DURATION);
  spinner?.succeed("Transcripts merged");

  // 4b. Align speakers
  if (diarization) {
    spinner = log(verbose, "Aligning speaker labels...");
    merged = { ...merged, segments: alignSpeakers(merged.segments, diarization) };
    spinner?.succeed("Speaker labels aligned");
  }

  // 5. Summarize
  spinner = log(verbose, "Summarizing with GPT-4o...");
  const summary = await summarizeTranscript(
    merged.text,
    config.openaiApiKey,
    config.summaryModel,
    diarization ? merged.segments : undefined
  );
  spinner?.succeed("Summary generated");

  // 6. Write
  spinner = log(verbose, "Writing output...");
  const date = new Date().toISOString().split("T")[0];
  const source = path.basename(inputPath);

  await writeOutput(
    { summary, segments: merged.segments, date, duration: durationMinutes, source },
    outputPath
  );
  spinner?.succeed(`Output written to ${outputPath}`);

  return outputPath;
}
