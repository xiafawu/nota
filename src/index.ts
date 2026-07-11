#!/usr/bin/env node

import { Command } from "commander";
import { loadConfig } from "./config.js";
import { runPipeline } from "./orchestrator.js";
import {
  formatHistoryList,
  listHistoryRecords,
  loadHistoryRecord,
} from "./pipeline/history.js";
import {
  deleteSpeaker,
  listSpeakers,
  mergeSpeakers,
  reassignVoiceprint,
  renameSpeaker,
  showSpeaker,
} from "./cli/speakers.js";
import { enrollSpeaker, EnrollError } from "./cli/enroll.js";

const program = new Command();

function parsePositiveInteger(value: string): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new Error("--num-speakers must be a positive integer");
  }
  return parsed;
}

program
  .name("nota")
  .description("Transcribe, diarize, and summarize audio files")
  .version("1.0.0")
  .argument("<audio-file>", "Path to audio file (.mp3, .wav, .m4a, etc.)")
  .option(
    "-o, --output <path>",
    "Output file path (default: <input>.summary.md)",
  )
  .option("-l, --language <lang>", "Audio language hint")
  .option("-m, --model <model>", "GPT model to use for summarization", "gpt-4o")
  .option("-v, --verbose", "Show progress for each pipeline stage")
  .option(
    "--provider <name>",
    "Transcription provider: assemblyai or whisper",
    "assemblyai",
  )
  .option(
    "--num-speakers <n>",
    "Expected number of speakers (assemblyai only)",
    parsePositiveInteger,
  )
  .option("--no-diarize", "Skip pyannote diarization for --provider whisper")
  .option(
    "--identify",
    "Identify and remember speakers by voice across recordings",
  )
  .option("--no-history", "Do not save this transcript to ~/.nota/history")
  .option(
    "--force",
    "Reprocess even if an identical audio file is already in history",
  )
  .action(async (audioFile: string, options) => {
    try {
      const config = loadConfig({
        ...options,
        diarize: options.diarize,
        numSpeakers: options.numSpeakers,
        identify: options.identify,
        history: options.history,
        force: options.force,
      });
      const outputPath = await runPipeline({
        inputPath: audioFile,
        outputPath: options.output,
        config,
      });
      console.log(`\nDone! Summary saved to: ${outputPath}`);
    } catch (error) {
      console.error(
        `\nError: ${error instanceof Error ? error.message : String(error)}`,
      );
      process.exit(1);
    }
  });

const history = program
  .command("history")
  .description("Inspect saved Nota transcript histories");

history
  .command("list")
  .description("List saved transcript histories")
  .option(
    "--limit <n>",
    "Maximum number of records to show",
    parsePositiveInteger,
    20,
  )
  .action(async (options) => {
    try {
      const records = await listHistoryRecords();
      console.log(formatHistoryList(records.slice(0, options.limit)));
    } catch (error) {
      console.error(
        `\nError: ${error instanceof Error ? error.message : String(error)}`,
      );
      process.exit(1);
    }
  });

history
  .command("show")
  .description("Show a saved transcript history record as JSON")
  .argument("<id>", "History id or unique id prefix")
  .action(async (id: string) => {
    try {
      const record = await loadHistoryRecord(id);
      console.log(JSON.stringify(record, null, 2));
    } catch (error) {
      console.error(
        `\nError: ${error instanceof Error ? error.message : String(error)}`,
      );
      process.exit(1);
    }
  });

function handleSpeakerError(error: unknown): never {
  console.error(
    `\nError: ${error instanceof Error ? error.message : String(error)}`,
  );
  process.exit(1);
}

const speakers = program
  .command("speakers")
  .description("Manage enrolled speaker voiceprints");

speakers
  .command("list")
  .description("List enrolled speaker profiles (tab-separated)")
  .action(async () => {
    try {
      await listSpeakers();
    } catch (error) {
      handleSpeakerError(error);
    }
  });

speakers
  .command("rename")
  .description("Rename an enrolled speaker profile")
  .argument("<old>", "Existing speaker name")
  .argument("<new>", "New speaker name")
  .action(async (oldName: string, newName: string) => {
    try {
      await renameSpeaker(oldName, newName);
    } catch (error) {
      handleSpeakerError(error);
    }
  });

speakers
  .command("delete")
  .description("Delete an enrolled speaker profile")
  .argument("<name>", "Speaker name to delete")
  .action(async (name: string) => {
    try {
      await deleteSpeaker(name);
    } catch (error) {
      handleSpeakerError(error);
    }
  });

speakers
  .command("merge")
  .description("Merge a source speaker into a destination speaker")
  .argument("<src>", "Source speaker (will be removed)")
  .argument("<dst>", "Destination speaker (kept)")
  .action(async (src: string, dst: string) => {
    try {
      await mergeSpeakers(src, dst);
    } catch (error) {
      handleSpeakerError(error);
    }
  });

speakers
  .command("reassign")
  .description(
    "Move a single voiceprint from its current speaker to another (creates the destination if missing)",
  )
  .argument(
    "<vp-id>",
    "Voiceprint id (the ISO timestamp shown by `nota speakers list`)",
  )
  .argument("<new-name>", "Destination speaker name")
  .action(async (vpId: string, newName: string) => {
    try {
      await reassignVoiceprint(vpId, newName);
    } catch (error) {
      handleSpeakerError(error);
    }
  });

speakers
  .command("show")
  .description("Show a speaker profile (embedding truncated to first 8 dims)")
  .argument("<name>", "Speaker name")
  .action(async (name: string) => {
    try {
      await showSpeaker(name);
    } catch (error) {
      handleSpeakerError(error);
    }
  });

program
  .command("enroll")
  .description(
    "Enroll a speaker from a history record into the voiceprint store",
  )
  .argument("<history-id>", "History record id or unique prefix")
  .argument("<speaker-label>", "Speaker label in the history record (e.g. 'Speaker 1')")
  .argument("<name>", "Name to enroll the speaker under")
  .action(async (historyId: string, label: string, name: string) => {
    try {
      await enrollSpeaker(historyId, label, name);
    } catch (error) {
      if (error instanceof EnrollError) {
        console.error(`\nError: ${error.message}`);
        process.exit(error.exitCode);
      }
      console.error(
        `\nError: ${error instanceof Error ? error.message : String(error)}`,
      );
      process.exit(1);
    }
  });

program.parse();
