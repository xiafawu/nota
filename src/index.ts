#!/usr/bin/env node

import { Command } from "commander";
import { loadConfig } from "./config.js";
import { runPipeline } from "./orchestrator.js";

const program = new Command();

function parsePositiveInteger(value: string): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new Error("--num-speakers must be a positive integer");
  }
  return parsed;
}

program
  .name("meetingsum")
  .description("Transcribe and summarize meeting audio files")
  .version("1.0.0")
  .argument("<audio-file>", "Path to audio file (.mp3, .wav, .m4a, etc.)")
  .option("-o, --output <path>", "Output file path (default: <input>.summary.md)")
  .option("-l, --language <lang>", "Audio language hint")
  .option("-m, --model <model>", "GPT model to use for summarization", "gpt-4o")
  .option("-v, --verbose", "Show progress for each pipeline stage")
  .option("--provider <name>", "Transcription provider: assemblyai or whisper", "assemblyai")
  .option("--num-speakers <n>", "Expected number of speakers (assemblyai only)", parsePositiveInteger)
  .option("--no-diarize", "Skip pyannote diarization for --provider whisper")
  .option("--identify", "Identify and remember speakers by voice across recordings")
  .action(async (audioFile: string, options) => {
    try {
      const config = loadConfig({
        ...options,
        diarize: options.diarize,
        numSpeakers: options.numSpeakers,
        identify: options.identify,
      });
      const outputPath = await runPipeline({
        inputPath: audioFile,
        outputPath: options.output,
        config,
      });
      console.log(`\nDone! Summary saved to: ${outputPath}`);
    } catch (error) {
      console.error(
        `\nError: ${error instanceof Error ? error.message : String(error)}`
      );
      process.exit(1);
    }
  });

program.parse();
