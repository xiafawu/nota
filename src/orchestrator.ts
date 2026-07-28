import path from "node:path";
import ora from "ora";
import type { AppConfig } from "./config.js";
import { costForUsage, makeSummaryUsage } from "./pricing.js";
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
import { summarizeTranscript, type MeetingSummary } from "./pipeline/summarize.js";
import { writeOutput, defaultOutputPath } from "./pipeline/write.js";
import { getAudioDuration } from "./utils/ffmpeg.js";
import { hashFile } from "./utils/audio-hash.js";
import { resolveCaptureDate } from "./utils/capture-date.js";
import { access, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { transcribeWithAssemblyAI } from "./pipeline/assemblyai.js";
import { resolvePreflight } from "./cli/preflight.js";
import {
  completeHistoryRecord,
  createHistoryRecord,
  findHistoryByHash,
  type HistoryOptions,
  type UsageEntry,
} from "./pipeline/history.js";
import {
  loadProfiles,
  saveProfiles,
  matchProfiles,
  promptForSpeakerNames,
  applySpeakerNames,
} from "./pipeline/speakers.js";
import { applyVerdicts, verifySpeakers } from "./pipeline/verify-speakers.js";
import {
  computeEmbedding,
  computeEmbeddings,
  isIdentityAvailable,
} from "./pipeline/embed.js";
import { decodePcm, slicePcm, concatToSeconds, SAMPLE_RATE } from "./utils/pcm.js";
import type { TranscriptSegment } from "./pipeline/transcribe.js";

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

/**
 * Emit a machine-readable phase marker for GUI progress. Gated behind
 * NOTA_PROGRESS so plain CLI/test runs stay clean, and written to stderr so it
 * never collides with ora's stdout spinner frames. The macOS app streams these
 * lines live to drive its phase label; ora only reports a stage once it has
 * *finished*, and suppresses `.start()` text in a non-TTY pipe, so an explicit
 * "about to start <stage>" marker is the only accurate real-time signal.
 */
function emitPhase(stage: string) {
  if (process.env.NOTA_PROGRESS) {
    process.stderr.write(`##NOTA_PHASE:${stage}\n`);
  }
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
  emitPhase("validating");
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

  // 1c. Duplicate detection. Hash the raw bytes once and, unless --force or
  //     --no-history is set, short-circuit to the existing summary when this
  //     exact file was already processed. Done here in the shared funnel so it
  //     runs before any paid transcription call in either provider branch.
  //
  //     Note: there is no cross-process lock, so two concurrent invocations of
  //     the same file can both miss and both transcribe. That's an accepted
  //     limitation for a single-user CLI; the access() check below is likewise
  //     advisory (the resolved path is only printed, never read back by us).
  let contentHash: string | undefined;
  if (config.history) {
    spinner = log(verbose, "Checking for duplicate audio...");
    try {
      contentHash = await hashFile(inputPath);
    } catch {
      contentHash = undefined;
    }

    if (!contentHash) {
      // Hashing failed even though validateInput could access the file (e.g. a
      // transient read error). Don't abort — transcription can still run and
      // the transcript is still saved to history — but the run can't be
      // deduplicated and won't be matchable by future runs, so say so rather
      // than claiming "no duplicate found".
      spinner?.warn("Could not hash audio — skipping duplicate check");
      console.error(
        "Warning: could not hash audio; this run is not deduplicated and a " +
          "future run of the same file won't recognize it as a duplicate.",
      );
    } else {
      if (!config.force) {
        const duplicateOutput = await findDuplicateOutput(contentHash);
        if (duplicateOutput) {
          spinner?.succeed("Duplicate audio detected");
          console.error(
            `Duplicate audio: matches history ${duplicateOutput.id} ` +
              `(${duplicateOutput.sourceName}). Reusing existing summary ` +
              `(skipping transcription):\n` +
              `  ${duplicateOutput.outputPath}\n` +
              `Pass --force to transcribe and summarize it again.`,
          );
          return duplicateOutput.outputPath;
        }
      }
      spinner?.succeed("No duplicate found");
    }
  }

  // 1d. Preflight gate. Runs the readiness checks (tools, keys, model request
  //     shapes) right before the paid transcription so a deterministic failure
  //     — e.g. a summary model that will reject every request — aborts here
  //     instead of after money is spent. `unverified` (offline / couldn't
  //     reach a service) is a soft warning: this is a non-interactive path, so
  //     it proceeds. `--skip-preflight` bypasses the gate.
  if (!config.skipPreflight) {
    spinner = log(verbose, "Running preflight checks...");
    const preflight = await resolvePreflight(config);
    if (preflight.overall === "blocked") {
      spinner?.fail("Preflight failed");
      const failed = preflight.checks
        .filter((c) => c.blocking && c.status === "fail")
        .map((c) => `  ✖ ${c.label}: ${c.detail}`)
        .join("\n");
      throw new Error(
        `Preflight blocked this run (nothing was transcribed):\n${failed}\n` +
          `Fix the above, or pass --skip-preflight to bypass.`,
      );
    }
    if (preflight.overall === "unverified") {
      spinner?.warn("Preflight could not verify everything — continuing");
      for (const c of preflight.checks) {
        if (c.status === "unverified") {
          console.error(`Warning: ${c.label}: ${c.detail}`);
        }
      }
    } else {
      spinner?.succeed("Preflight passed");
    }
  }

  if (config.provider === "assemblyai") {
    return runAssemblyAIPipeline(
      inputPath,
      outputPath,
      durationMinutes,
      config,
      contentHash,
    );
  }
  return runWhisperPipeline(
    inputPath,
    outputPath,
    durationMinutes,
    config,
    contentHash,
  );
}

/**
 * Resolve a prior, reusable summary for an audio file by content hash.
 * Only a `completed` record whose output file still exists on disk counts —
 * a transcribed-but-failed run or a record whose `.md` was deleted should be
 * reprocessed, not silently skipped. Returns the matched id/name/outputPath
 * or `null` when there is nothing safe to reuse.
 */
async function findDuplicateOutput(
  contentHash: string,
): Promise<{ id: string; sourceName: string; outputPath: string } | null> {
  const prior = await findHistoryByHash(contentHash);
  if (!prior || prior.status !== "completed" || !prior.outputPath) {
    return null;
  }
  const outputExists = await access(prior.outputPath)
    .then(() => true)
    .catch(() => false);
  if (!outputExists) return null;
  return {
    id: prior.id,
    sourceName: prior.sourceName,
    outputPath: prior.outputPath,
  };
}

async function runAssemblyAIPipeline(
  inputPath: string,
  outputPath: string,
  durationMinutes: number,
  config: AppConfig,
  contentHash: string | undefined,
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
      contentHash,
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
  contentHash: string | undefined,
): Promise<string> {
  const verbose = config.verbose;

  // 2. Transcribe + diarize (single API call)
  emitPhase("transcribing");
  let spinner = log(verbose, "Transcribing and diarizing with AssemblyAI...");
  const result = await transcribeWithAssemblyAI(inputPath, {
    apiKey: config.transcriptionApiKey,
    speechModel: config.transcriptionModel,
    numSpeakers: config.numSpeakers,
    language: config.language,
  });
  spinner?.succeed("Transcription and diarization complete");
  const transcriptionDurationMin = result.durationSeconds
    ? result.durationSeconds / 60
    : durationMinutes;
  const transcriptionUsage: UsageEntry = {
    modelId: config.transcriptionModel,
    task: "transcription",
    provider: config.provider,
    calls: 1,
    durationMin: transcriptionDurationMin,
    costUSD: null,
    estimated: false,
  };
  transcriptionUsage.costUSD = costForUsage(transcriptionUsage);

  // 2b. Identify speakers by voice (if enabled)
  let segments = result.segments;
  let speakerClipsPcm: Record<string, Int16Array> | undefined;
  if (config.identify) {
    const audioForEmbeddings = localAudioPath ?? inputPath;
    const ident = await identifySpeakers(
      audioForEmbeddings,
      segments,
      config,
      verbose,
    );
    segments = ident.segments;
    // Persist clips so the macOS viewer can enroll a name later, after this
    // (often temporary) audio file is gone.
    speakerClipsPcm = ident.clips;
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
      contentHash,
      speakerClipsPcm,
      usage: [transcriptionUsage],
    });
    historyId = history.id;
    spinner?.succeed(`History saved as ${history.id}`);
  }

  // 3. Summarize (optional — --no-summary skips; when run, capture token usage)
  let summary: MeetingSummary | undefined;
  let summaryUsage: UsageEntry | undefined;
  if (config.summary) {
    emitPhase("summarizing");
    spinner = log(verbose, `Summarizing with ${config.summaryModel}...`);
    const summarized = await summarizeTranscript(
      result.text,
      config.summaryApiKey,
      config.summaryWireModel,
      segments,
      config.summaryBaseURL,
    );
    summary = summarized.summary;
    summaryUsage = makeSummaryUsage(config.summaryModel, config.provider, summarized.tokenUsage);
    spinner?.succeed("Summary generated");
  }

  // 4. Write
  emitPhase("writing");
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
  if (config.summary && historyId) {
    await completeHistoryRecord(historyId, {
      summary: summary!,
      outputPath,
      usage: summaryUsage ? [summaryUsage] : undefined,
    });
  }
  spinner?.succeed(`Output written to ${outputPath}`);

  return outputPath;
}

/** Target / minimum seconds of speech captured per speaker for enrollment. */
export const CLIP_TARGET_SEC = 24;
export const CLIP_MIN_SEC = 5;

/**
 * Pick a speaker's longest utterances, in descending duration, until their
 * total covers `targetSec`. Longest-first maximizes clean speech for ONNX
 * embedding within a bounded clip.
 */
export function selectClipRanges(
  segments: TranscriptSegment[],
  label: string,
  targetSec: number,
): { start: number; end: number }[] {
  const mine = segments
    .filter((s) => s.speaker === label)
    .map((s) => ({ start: s.start, end: s.end }))
    .sort((a, b) => b.end - b.start - (a.end - a.start));
  const picked: { start: number; end: number }[] = [];
  let acc = 0;
  for (const r of mine) {
    if (acc >= targetSec) break;
    picked.push(r);
    acc += r.end - r.start;
  }
  return picked;
}

interface IdentifyOutput {
  segments: TranscriptSegment[];
  /** Per-label PCM clips (>= CLIP_MIN_SEC) to persist for later enrollment. */
  clips: Record<string, Int16Array>;
}

export async function identifySpeakers(
  inputPath: string,
  segments: TranscriptSegment[],
  config: AppConfig,
  verbose: boolean,
): Promise<IdentifyOutput> {
  let identityAvailable = false;
  try {
    identityAvailable = await isIdentityAvailable();
  } catch {
    // Availability is a soft gate: native runtime/model failures must never
    // abort transcription or summarization.
  }
  if (!identityAvailable) {
    console.error(
      "Speaker identity unavailable: the ONNX model or onnxruntime-node could " +
        "not be loaded. Check the model download and installation, then retry. " +
        "Using generic labels.",
    );
    return { segments, clips: {} };
  }
  const spinner = log(verbose, "Identifying speakers (ONNX)...");
  try {
    const pcm = await decodePcm(inputPath);
    const labels = [
      ...new Set(segments.map((s) => s.speaker).filter(Boolean) as string[]),
    ];

    // One representative clip per speaker (longest utterances first). Keep
    // only clips with enough speech to be worth enrolling later.
    const pcmByLabel: Record<string, Int16Array> = {};
    const clips: Record<string, Int16Array> = {};
    for (const label of labels) {
      const ranges = selectClipRanges(segments, label, CLIP_TARGET_SEC);
      const clip = concatToSeconds(
        ranges.map((r) => slicePcm(pcm, [r])),
        CLIP_TARGET_SEC,
      );
      pcmByLabel[label] = clip;
      if (clip.length >= CLIP_MIN_SEC * SAMPLE_RATE) clips[label] = clip;
    }

    // Compute each label vector once for the run. The same vector is reused
    // below if the user assigns a fresh name interactively.
    const labelEmbeddings = await computeEmbeddings(pcmByLabel);
    const store = await loadProfiles();
    const matches = matchProfiles(labelEmbeddings, store);
    spinner?.succeed("Speaker identification complete");

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

    // 2c. LLM cross-check: verify confident matches against speaker descriptions
    //     (gated behind --verify-speakers, which defaults to on with --identify).
    if (
      config.verifySpeakers &&
      Object.keys(nameMap).length > 0 &&
      config.summaryApiKey
    ) {
      if (verbose) console.log("  Verifying speaker labels...");
      const speakerContexts: Record<
        string,
        { name: string; description?: typeof store.speakers[string]["description"] }
      > = {};
      for (const [label, name] of Object.entries(nameMap)) {
        const profile = store.speakers[name];
        speakerContexts[label] = {
          name,
          description: profile?.description,
        };
      }
      const verdicts = await verifySpeakers(
        { segments, matches: Object.fromEntries(Object.entries(matches).filter(([, m]) => !m.tentative)), speakerContexts },
        config.summaryApiKey,
        config.summaryWireModel,
        config.summaryBaseURL,
      );
      const updated = applyVerdicts(matches, verdicts);
      for (const [label, match] of Object.entries(updated)) {
        const prev = matches[label];
        if (prev && prev.tentative !== match.tentative && match.tentative) {
          // Demoted: move from nameMap to tentative.
          if (nameMap[label]) {
            if (verbose) console.log(`  Demoted ${label}: "${nameMap[label]}" marked tentative after LLM cross-check`);
            delete nameMap[label];
            tentative[label] = { name: match.name, confidence: match.confidence };
          }
        }
      }
    }

    const unmatched = labels.filter((l) => !nameMap[l] && !tentative[l]);
    const needsPrompt =
      unmatched.length > 0 || Object.keys(tentative).length > 0;
    if (needsPrompt && process.stdin.isTTY) {
      const { names, enroll } = await promptForSpeakerNames(
        segments,
        unmatched,
        tentative,
      );
      Object.assign(nameMap, names);

      // Enroll freshly-typed names inline from their in-memory clip so a CLI
      // `--identify` run also persists voiceprints (the macOS viewer instead
      // enrolls post-hoc from the stored clip via `nota enroll`). Tentative
      // confirmations ("y") reuse the existing profile and are not in `enroll`.
      let enrolled = 0;
      for (const [label, name] of Object.entries(enroll)) {
        const clip = clips[label];
        if (!clip) continue; // too little speech — skip, don't fail
        try {
          const embedding =
            labelEmbeddings[label] ?? Array.from(await computeEmbedding(clip));
          const now = new Date().toISOString();
          const vp = {
            id: now,
            embedding,
            enrolledAt: now,
            source: path.basename(inputPath),
          };
          if (store.speakers[name]) store.speakers[name].voiceprints.push(vp);
          else store.speakers[name] = { voiceprints: [vp] };
          enrolled++;
        } catch (e) {
          if (verbose) {
            console.error(
              `  Could not enroll ${name}: ${e instanceof Error ? e.message : String(e)}`,
            );
          }
        }
      }
      if (enrolled > 0) await saveProfiles(store);
    }

    return { segments: applySpeakerNames(segments, nameMap), clips };
  } catch (error) {
    spinner?.fail("Speaker identification unavailable (using generic labels)");
    console.error(
      "Speaker identity unavailable: the ONNX model or onnxruntime-node failed. " +
        "Check the model download and installation. Using generic labels.",
    );
    if (verbose) {
      console.error(
        `  ${error instanceof Error ? error.message : String(error)}`,
      );
    }
    return { segments, clips: {} };
  }
}

async function runWhisperPipeline(
  inputPath: string,
  outputPath: string,
  durationMinutes: number,
  config: AppConfig,
  contentHash: string | undefined,
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
    transcribeChunks(
      chunks,
      config.transcriptionApiKey,
      config.language,
      config.transcriptionModel,
    ),
    config.diarize ? runDiarization(inputPath) : Promise.resolve(null),
  ]);
  spinner?.succeed(
    config.diarize
      ? "Transcription and diarization complete"
      : "Transcription complete",
  );
  const transcriptionTotalSeconds = transcriptions.reduce(
    (sum, t) => sum + (t.durationSeconds ?? 0), 0
  );
  const whisperDurationMin = transcriptionTotalSeconds > 0
    ? transcriptionTotalSeconds / 60
    : durationMinutes;
  const transcriptionUsageW: UsageEntry = {
    modelId: config.transcriptionModel,
    task: "transcription",
    provider: config.provider,
    calls: 1,
    durationMin: whisperDurationMin,
    costUSD: null,
    estimated: false,
  };
  transcriptionUsageW.costUSD = costForUsage(transcriptionUsageW);

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
      contentHash,
      usage: [transcriptionUsageW],
    });
    historyId = history.id;
    spinner?.succeed(`History saved as ${history.id}`);
  }

  // 5. Summarize (optional — --no-summary skips; when run, capture token usage)
  let summary: MeetingSummary | undefined;
  let summaryUsageW: UsageEntry | undefined;
  if (config.summary) {
    spinner = log(verbose, `Summarizing with ${config.summaryModel}...`);
    const summarized = await summarizeTranscript(
      merged.text,
      config.summaryApiKey,
      config.summaryWireModel,
      diarization ? merged.segments : undefined,
      config.summaryBaseURL,
    );
    summary = summarized.summary;
    summaryUsageW = makeSummaryUsage(config.summaryModel, config.provider, summarized.tokenUsage);
    spinner?.succeed("Summary generated");
  }

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
  if (config.summary && historyId) {
    await completeHistoryRecord(historyId, {
      summary: summary!,
      outputPath,
      usage: summaryUsageW ? [summaryUsageW] : undefined,
    });
  }
  spinner?.succeed(`Output written to ${outputPath}`);

  return outputPath;
}
