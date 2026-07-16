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
  describeSpeaker,
  listSpeakers,
  mergeSpeakers,
  reassignVoiceprint,
  renameSpeaker,
  showSpeaker,
} from "./cli/speakers.js";
import { enrollSpeaker, EnrollError } from "./cli/enroll.js";
import { printConfig } from "./cli/config.js";
import { preflightCommand } from "./cli/preflight.js";
import { applyEnvFile } from "./utils/env-file.js";
import { summarizeHistory } from "./cli/summarize-history.js";
import {
  settingsGet,
  settingsList,
  settingsSet,
  settingsUnset,
} from "./cli/settings.js";

const program = new Command();

// The top-level command and several subcommands (e.g. `history summarize`) both
// define `-m, --model`. Without positional options, the parent's `-m` greedily
// captures the flag before a subcommand sees it, so `nota history summarize <id>
// -m gemini-2.5-flash` would silently fall back to the parent default (gpt-4o).
// Positional options scope each `-m` to the command it follows.
program.enablePositionalOptions();

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
  .option(
    "-m, --model <model>",
    "Summary model id (overrides settings.json; see `nota settings`)",
  )
  .option(
    "--transcribe-model <model>",
    "Transcription model id (overrides settings.json and --provider)",
  )
  .option("-v, --verbose", "Show progress for each pipeline stage")
  .option(
    "--provider <name>",
    "Back-compat alias seeding the transcription model: assemblyai or whisper",
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
  .option(
    "--no-summary",
    "Transcribe only; skip the LLM summary",
  )
  .option(
    "--no-verify-speakers",
    "Skip the LLM cross-check on voiceprint speaker labels",
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
        output: options.output,
        transcribeModel: options.transcribeModel,
        model: options.model,
        verbose: options.verbose,
        diarize: options.diarize,
        numSpeakers: options.numSpeakers,
        identify: options.identify,
        summary: options.summary,
        verifySpeakers: options.verifySpeakers,
        history: options.history,
        force: options.force,
        skipPreflight: options.skipPreflight,
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

history
  .command("summarize")
  .description(
    "Summarize a saved transcript (recovers a transcribed-but-unsummarized record without re-transcribing)",
  )
  .argument("<id>", "History record id or unique prefix")
  .option(
    "-m, --model <model>",
    "Summary model id (defaults to the record's model, then settings, then the built-in default)",
  )
  .option("-o, --output <path>", "Output markdown path")
  .option("--force", "Re-summarize even if the record is already completed")
  .action(async (id: string, options) => {
    try {
      await summarizeHistory(id, {
        model: options.model,
        output: options.output,
        force: options.force,
      });
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
  .description("Show a speaker profile with voiceprint embedding dimensions")
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

function handleSettingsError(error: unknown): never {
  console.error(
    `Error: ${error instanceof Error ? error.message : String(error)}`,
  );
  process.exit(1);
}

const settings = program
  .command("settings")
  .description("View and edit non-secret model preferences (~/.nota/settings.json)");

settings
  .command("list")
  .description("Show effective model settings and their source")
  .action(() => {
    try {
      settingsList();
    } catch (error) {
      handleSettingsError(error);
    }
  });

settings
  .command("get")
  .description("Print the effective value at a dot-path (e.g. summary.model)")
  .argument("<path>", "Dot-path such as transcription.model or summary.model")
  .action((dotPath: string) => {
    try {
      settingsGet(dotPath);
    } catch (error) {
      handleSettingsError(error);
    }
  });

settings
  .command("set")
  .description("Set a model at a dot-path (validated against the registry)")
  .argument("<path>", "Dot-path such as transcription.model or summary.model")
  .argument("<value>", "Model id")
  .action((dotPath: string, value: string) => {
    try {
      settingsSet(dotPath, value);
    } catch (error) {
      handleSettingsError(error);
    }
  });

settings
  .command("unset")
  .description("Remove a setting at a dot-path, reverting to the default")
  .argument("<path>", "Dot-path such as transcription.model or summary.model")
  .action((dotPath: string) => {
    try {
      settingsUnset(dotPath);
    } catch (error) {
      handleSettingsError(error);
    }
  });

program
  .command("config")
  .description(
    "Show which API keys resolve and from where (masked value, secrets never printed)",
  )
  .action(printConfig);

program
  .command("preflight")
  .description(
    "Check readiness (tools, keys, model request shapes) before transcribing",
  )
  .option("--json", "Emit machine-readable JSON (consumed by the macOS app)")
  .option("--refresh", "Bypass the short-lived cache and re-run every check")
  .option(
    "-m, --model <model>",
    "Summary model id to check (defaults to settings, then the built-in default)",
  )
  .option(
    "--transcribe-model <model>",
    "Transcription model id to check (defaults to settings/provider)",
  )
  .option(
    "--provider <name>",
    "Back-compat alias seeding the transcription model: assemblyai or whisper",
  )
  .option("--identify", "Include speaker-identity readiness as configured")
  .action(async (options) => {
    try {
      // requireKeys:false so a missing key is reported as a failed check,
      // not thrown before preflight can render it.
      const config = loadConfig(
        {
          model: options.model,
          transcribeModel: options.transcribeModel,
          provider: options.provider,
          identify: options.identify,
        },
        undefined,
        { requireKeys: false },
      );
      const code = await preflightCommand(config, {
        json: options.json,
        refresh: options.refresh,
      });
      process.exit(code);
    } catch (error) {
      console.error(
        `\nError: ${error instanceof Error ? error.message : String(error)}`,
      );
      process.exit(1);
    }
  });

// Load ~/.nota/config once at bootstrap so every subcommand (run, history,
// speakers, config) sees file-provided keys. Real env vars still win.
applyEnvFile();

program.parse();
