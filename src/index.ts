#!/usr/bin/env node

import { Command } from "commander";
import { loadConfig } from "./config.js";
import { runPipeline } from "./orchestrator.js";

const program = new Command();

program
  .name("meetingsum")
  .description("Transcribe and summarize meeting audio files")
  .version("1.0.0")
  .argument("<audio-file>", "Path to audio file (.mp3, .wav, .m4a, etc.)")
  .option("-o, --output <path>", "Output file path (default: <input>.summary.md)")
  .option("-l, --language <lang>", "Audio language hint for Whisper")
  .option("-m, --model <model>", "Claude model to use", "claude-sonnet-4-20250514")
  .option("-v, --verbose", "Show progress for each pipeline stage")
  .action(async (audioFile: string, options) => {
    try {
      const config = loadConfig(options);
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
