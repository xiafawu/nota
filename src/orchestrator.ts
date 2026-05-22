import path from "node:path";
import ora from "ora";
import type { AppConfig } from "./config.js";
import { OVERLAP_DURATION } from "./constants.js";
import {
  validateInput,
  checkPython,
  checkHuggingFaceToken,
} from "./pipeline/validate.js";
import { runDiarization, alignSpeakers } from "./pipeline/diarize.js";
import { chunkAudio } from "./pipeline/chunk.js";
import { transcribeChunks } from "./pipeline/transcribe.js";
import { mergeTranscriptions } from "./pipeline/merge.js";
import { summarizeTranscript } from "./pipeline/summarize.js";
import { writeOutput, defaultOutputPath } from "./pipeline/write.js";
import { getAudioDuration } from "./utils/ffmpeg.js";
import { resolveCaptureDate } from "./utils/capture-date.js";
import { unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { transcribeWithAssemblyAI } from "./pipeline/assemblyai.js";
import {
  completeHistoryRecord,
  createHistoryRecord,
  type HistoryOptions,
} from "./pipeline/history.js";
import {
  extractEmbeddings,
  loadProfiles,
  saveProfiles,
  matchSpeakers,
  clusterLabels,
  promptForSpeakerNames,
  applySpeakerNames,
} from "./pipeline/speakers.js";

const execFileAsync = promisify(execFile);

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

function historyOptions(config: AppConfig): HistoryOptions {
  return {
    language: config.language,
    diarize: config.diarize,
    identify: config.identify,
    numSpeakers: config.numSpeakers,
    model: config.summaryModel,
  };
}

export async function runPipeline(options: PipelineOptions): Promise<string> {
  const { inputPath, config } = options;
  const outputPath = options.outputPath ?? defaultOutputPath(inputPath);
  const verbose = config.verbose;

  // 1. Validate and get duration
  let spinner = log(verbose, "Validating input...");
  await validateInput(inputPath);
  let durationMinutes: number;
  try {
    const duration = await getAudioDuration(inputPath);
    durationMinutes = Math.round(duration / 60);
  } catch {
    durationMinutes = 0;
  }
  spinner?.succeed("Input validated");

  if (config.provider === "assemblyai") {
    return runAssemblyAIPipeline(
      inputPath,
      outputPath,
      durationMinutes,
      config,
    );
  }
  return runWhisperPipeline(inputPath, outputPath, durationMinutes, config);
}

async function runAssemblyAIPipeline(
  inputPath: string,
  outputPath: string,
  durationMinutes: number,
  config: AppConfig,
): Promise<string> {
  const verbose = config.verbose;

  // 1b. Pre-convert .qta to .wav if speaker identification is needed
  //     (the original file may be a temp file that gets deleted during transcription)
  let localAudioPath: string | null = null;
  if (config.identify && path.extname(inputPath).toLowerCase() === ".qta") {
    const spinner0 = log(
      verbose,
      "Converting audio for speaker identification...",
    );
    localAudioPath = path.join(tmpdir(), `nota-local-${Date.now()}.wav`);
    await execFileAsync("ffmpeg", [
      "-y",
      "-i",
      inputPath,
      "-ar",
      "16000",
      "-ac",
      "1",
      localAudioPath,
    ]);
    spinner0?.succeed("Audio converted");
  }

  try {
    return await runAssemblyAIPipelineInner(
      inputPath,
      outputPath,
      durationMinutes,
      config,
      localAudioPath,
    );
  } finally {
    if (localAudioPath) {
      await unlink(localAudioPath).catch(() => {});
    }
  }
}

async function runAssemblyAIPipelineInner(
  inputPath: string,
  outputPath: string,
  durationMinutes: number,
  config: AppConfig,
  localAudioPath: string | null,
): Promise<string> {
  const verbose = config.verbose;

  // 2. Transcribe + diarize (single API call)
  let spinner = log(verbose, "Transcribing and diarizing with AssemblyAI...");
  const result = await transcribeWithAssemblyAI(inputPath, {
    apiKey: config.assemblyaiApiKey!,
    numSpeakers: config.numSpeakers,
    language: config.language,
  });
  spinner?.succeed("Transcription and diarization complete");

  // 2b. Identify speakers by voice (if enabled)
  let segments = result.segments;
  if (config.identify) {
    const audioForEmbeddings = localAudioPath ?? inputPath;
    segments = await identifySpeakers(audioForEmbeddings, segments, verbose);
  }

  const capturedAt = await resolveCaptureDate(inputPath);

  // 2c. Save transcript history before summarization so the transcript survives
  //     even if the GPT summary step fails.
  let historyId: string | undefined;
  if (config.history) {
    spinner = log(verbose, "Saving transcript history...");
    const history = await createHistoryRecord({
      sourcePath: inputPath,
      provider: config.provider,
      options: historyOptions(config),
      durationMinutes,
      transcriptText: result.text,
      segments,
      outputPath,
      capturedAt: capturedAt ? capturedAt.toISOString() : null,
    });
    historyId = history.id;
    spinner?.succeed(`History saved as ${history.id}`);
  }

  // 3. Summarize
  spinner = log(verbose, "Summarizing with GPT-4o...");
  const summary = await summarizeTranscript(
    result.text,
    config.openaiApiKey,
    config.summaryModel,
    segments,
  );
  spinner?.succeed("Summary generated");

  // 4. Write
  spinner = log(verbose, "Writing output...");
  const transcribedDate = new Date().toISOString().split("T")[0];
  const capturedDate = capturedAt
    ? capturedAt.toISOString().split("T")[0]
    : null;
  const source = path.basename(inputPath);

  await writeOutput(
    {
      summary,
      segments,
      capturedDate,
      transcribedDate,
      duration: durationMinutes,
      source,
    },
    outputPath,
  );
  if (historyId) {
    await completeHistoryRecord(historyId, { summary, outputPath });
  }
  spinner?.succeed(`Output written to ${outputPath}`);

  return outputPath;
}

async function identifySpeakers(
  inputPath: string,
  segments: import("./pipeline/transcribe.js").TranscriptSegment[],
  verbose: boolean,
): Promise<import("./pipeline/transcribe.js").TranscriptSegment[]> {
  let spinner = log(verbose, "Extracting speaker voiceprints...");
  try {
    const embeddings = await extractEmbeddings(inputPath, segments);
    spinner?.succeed("Speaker voiceprints extracted");

    // Collapse near-duplicate diarizer labels (e.g. one person split into
    // "Speaker 1" and "Speaker 2") before matching or enrollment so a single
    // real speaker doesn't produce two profiles.
    const { canonicalOf, merged } = clusterLabels(embeddings);
    const profiles = await loadProfiles();
    const matches = matchSpeakers(merged, profiles);

    // Build name mapping from confident matches only. Tentative matches go
    // into a separate map and are resolved interactively below.
    const nameMap: Record<string, string> = {};
    const tentative: Record<string, { name: string; confidence: number }> = {};
    for (const [label, match] of Object.entries(matches)) {
      if (match.tentative) {
        tentative[label] = { name: match.name, confidence: match.confidence };
        if (verbose) {
          console.log(
            `  Tentative: ${label} ~ ${match.name} (${Math.round(match.confidence * 100)}%)`,
          );
        }
      } else {
        nameMap[label] = match.name;
        if (verbose) {
          console.log(
            `  Matched ${label} → ${match.name} (${Math.round(match.confidence * 100)}%)`,
          );
        }
      }
    }

    // Find unmatched canonical speakers (excludes tentative — those are
    // resolved by the confirmation pass inside promptForSpeakerNames).
    const canonicalSpeakers = [
      ...new Set(
        (segments.map((s) => s.speaker).filter(Boolean) as string[]).map(
          (s) => canonicalOf[s] ?? s,
        ),
      ),
    ];
    const unmatchedSpeakers = canonicalSpeakers.filter(
      (s) => !nameMap[s] && !tentative[s],
    );

    // Prompt for tentative + unmatched speakers (if interactive terminal).
    // Rewrite segments to canonical labels first so prompt samples and the
    // prompt ids match what was actually clustered.
    const canonicalSegments = applySpeakerNames(segments, {}, canonicalOf);
    const needsPrompt =
      unmatchedSpeakers.length > 0 || Object.keys(tentative).length > 0;
    if (needsPrompt && process.stdin.isTTY) {
      const { names: newNames, enroll } = await promptForSpeakerNames(
        canonicalSegments,
        unmatchedSpeakers,
        tentative,
      );
      Object.assign(nameMap, newNames);

      // Only enroll labels the user typed fresh — tentative confirmations
      // (`y` to existing candidate) reuse the existing profile without
      // overwriting its embedding.
      for (const [label, name] of Object.entries(enroll)) {
        const embedding = merged[label] ?? embeddings[label];
        if (embedding) {
          profiles.speakers[name] = {
            embedding,
            enrolledAt: new Date().toISOString(),
            source: path.basename(inputPath),
          };
        }
      }
      if (Object.keys(enroll).length > 0) {
        await saveProfiles(profiles);
      }
    }

    return applySpeakerNames(segments, nameMap, canonicalOf);
  } catch (error) {
    spinner?.fail("Speaker identification unavailable (using generic labels)");
    if (verbose) {
      console.error(
        `  ${error instanceof Error ? error.message : String(error)}`,
      );
    }
    return segments;
  }
}

async function runWhisperPipeline(
  inputPath: string,
  outputPath: string,
  durationMinutes: number,
  config: AppConfig,
): Promise<string> {
  const verbose = config.verbose;

  // 1b. Validate diarization requirements
  if (config.diarize) {
    let spinner = log(verbose, "Checking diarization requirements...");
    await checkPython();
    checkHuggingFaceToken();
    spinner?.succeed("Diarization requirements met");
  }

  // 2. Chunk
  let spinner = log(verbose, "Checking if chunking is needed...");
  const chunks = await chunkAudio(inputPath);
  spinner?.succeed(
    chunks.length === 1
      ? "File within size limit, no chunking needed"
      : `Split into ${chunks.length} chunks`,
  );

  // 3. Transcribe (and diarize in parallel if enabled)
  spinner = log(
    verbose,
    config.diarize
      ? `Transcribing ${chunks.length} chunk(s) and diarizing speakers...`
      : `Transcribing ${chunks.length} chunk(s)...`,
  );

  const [transcriptions, diarization] = await Promise.all([
    transcribeChunks(chunks, config.openaiApiKey, config.language),
    config.diarize ? runDiarization(inputPath) : Promise.resolve(null),
  ]);
  spinner?.succeed(
    config.diarize
      ? "Transcription and diarization complete"
      : "Transcription complete",
  );

  // 4. Merge
  spinner = log(verbose, "Merging transcripts...");
  let merged = mergeTranscriptions(transcriptions, OVERLAP_DURATION);
  spinner?.succeed("Transcripts merged");

  // 4b. Align speakers
  if (diarization) {
    spinner = log(verbose, "Aligning speaker labels...");
    merged = {
      ...merged,
      segments: alignSpeakers(merged.segments, diarization),
    };
    spinner?.succeed("Speaker labels aligned");
  }

  const capturedAt = await resolveCaptureDate(inputPath);

  // 4c. Save transcript history before summarization so the transcript survives
  //     even if the GPT summary step fails.
  let historyId: string | undefined;
  if (config.history) {
    spinner = log(verbose, "Saving transcript history...");
    const history = await createHistoryRecord({
      sourcePath: inputPath,
      provider: config.provider,
      options: historyOptions(config),
      durationMinutes,
      transcriptText: merged.text,
      segments: merged.segments,
      outputPath,
      capturedAt: capturedAt ? capturedAt.toISOString() : null,
    });
    historyId = history.id;
    spinner?.succeed(`History saved as ${history.id}`);
  }

  // 5. Summarize
  spinner = log(verbose, "Summarizing with GPT-4o...");
  const summary = await summarizeTranscript(
    merged.text,
    config.openaiApiKey,
    config.summaryModel,
    diarization ? merged.segments : undefined,
  );
  spinner?.succeed("Summary generated");

  // 6. Write
  spinner = log(verbose, "Writing output...");
  const transcribedDate = new Date().toISOString().split("T")[0];
  const capturedDate = capturedAt
    ? capturedAt.toISOString().split("T")[0]
    : null;
  const source = path.basename(inputPath);

  await writeOutput(
    {
      summary,
      segments: merged.segments,
      capturedDate,
      transcribedDate,
      duration: durationMinutes,
      source,
    },
    outputPath,
  );
  if (historyId) {
    await completeHistoryRecord(historyId, { summary, outputPath });
  }
  spinner?.succeed(`Output written to ${outputPath}`);

  return outputPath;
}
