/**
 * The lifecycle a Nota record moves through, as one persisted string.
 *
 * The record is created at sample zero and the status is what says where it
 * got to (XIA-430). This vocabulary is the CONTRACT between the CLI and the
 * macOS app: `macos/Nota/App/HistoryStatus.swift` mirrors it exactly — the
 * same raw strings, the same legacy mapping, the same legal transitions — so
 * `nota history show <id>` reports the status the app is displaying. Neither
 * half may add a value the other cannot name.
 *
 *     recording → transcribing → transcribed → summarizing → done
 *                     ↓              ↓             ↓
 *                            failed:<stage>
 *
 * `transcribed` is the rest state between the two halves, and the terminal
 * state of a transcript-only live meeting. It is deliberately not `done`:
 * `nota history summarize` refuses a finished record without `--force`, and
 * calling a never-summarized transcript finished would put every live meeting
 * behind that flag.
 */
export type HistoryStage = "recording" | "transcribing" | "summarizing";

export type HistoryStatus =
  | "recording"
  | "transcribing"
  | "transcribed"
  | "summarizing"
  | "done"
  | "failed:recording"
  | "failed:transcribing"
  | "failed:summarizing";

export const HISTORY_STAGES: readonly HistoryStage[] = [
  "recording",
  "transcribing",
  "summarizing",
];

export const HISTORY_STATUSES: readonly HistoryStatus[] = [
  "recording",
  "transcribing",
  "transcribed",
  "summarizing",
  "done",
  "failed:recording",
  "failed:transcribing",
  "failed:summarizing",
];

/** The one-string form of `failed(stage:)`. */
export function failedStatus(stage: HistoryStage): HistoryStatus {
  return `failed:${stage}` as HistoryStatus;
}

/** The stage a failure happened in, or null for every non-failure status. */
export function failureStage(status: HistoryStatus): HistoryStage | null {
  if (!status.startsWith("failed:")) return null;
  const stage = status.slice("failed:".length) as HistoryStage;
  return HISTORY_STAGES.includes(stage) ? stage : null;
}

/**
 * True while a process is supposed to be working on this record. A record
 * found in one of these at launch with nothing behind it was interrupted —
 * see `resolveInterrupted`.
 */
export function isInFlight(status: HistoryStatus): boolean {
  return (
    status === "recording" ||
    status === "transcribing" ||
    status === "summarizing"
  );
}

/** True when nothing more will happen to this record on its own. */
export function isTerminal(status: HistoryStatus): boolean {
  return status === "done" || failureStage(status) !== null;
}

/**
 * The status an interrupted record resolves to: the failure of whatever stage
 * it was in the middle of. Terminal and rest states resolve to nothing — a
 * record that already finished was not interrupted by the process dying.
 */
export function resolveInterrupted(status: HistoryStatus): HistoryStatus | null {
  if (!isInFlight(status)) return null;
  return failedStatus(status as HistoryStage);
}

/**
 * Whether `to` is a legal next status for `from`. Terminal statuses accept
 * nothing; every in-flight status may fail. Kept total (rather than throwing)
 * so a caller can assert the machine without a try.
 */
export function canAdvance(from: HistoryStatus, to: HistoryStatus): boolean {
  if (isTerminal(from)) return false;
  if (from === to) return false;
  const stage = failureStage(to);
  if (stage !== null) {
    // A record may only fail in the stage it is actually in; the rest state
    // `transcribed` fails as the summary it was waiting for.
    if (from === "transcribed") return stage === "summarizing";
    return stage === from;
  }
  switch (from) {
    case "recording":
      return to === "transcribing";
    case "transcribing":
      return to === "transcribed" || to === "summarizing";
    case "transcribed":
      return to === "summarizing";
    case "summarizing":
      return to === "done";
    default:
      return false;
  }
}

/**
 * May a summary write complete this record?
 *
 * The one guard the CLI's write path owes the machine. `nota history
 * summarize` (and every other verb that lands a summary) used to write `done`
 * onto whatever it found, so a record still saying `recording` — a live
 * session in progress, or one whose process went away — could be declared
 * finished by a summary of a transcript it does not have.
 *
 * It is expressed through `canAdvance` rather than beside it, so there is one
 * definition of the lifecycle and not two. Three cases are admitted on top of
 * "may reach `summarizing`", and each is a real user action:
 *   - `summarizing` — the write that finishes the stage it is in.
 *   - `done` — a regeneration (`--force`), which is the flag's whole purpose.
 *   - `failed:summarizing` — a retry of the one stage that can be retried,
 *     on a record that still holds its audio and its transcript.
 * A record that never reached a transcript is refused in every case.
 */
export function canCompleteWithSummary(status: HistoryStatus): boolean {
  if (canAdvance(status, "summarizing")) return true;
  return (
    status === "summarizing" ||
    status === "done" ||
    status === "failed:summarizing"
  );
}

/**
 * Read a status off a record that may predate this vocabulary.
 *
 * Tolerant per the repo's decoding convention: a record on disk is never
 * refused for a field it was written before. Legacy `"completed"` is `done`;
 * legacy `"transcribed"` keeps its name (it means the same thing it always
 * did). An absent or unrecognized value resolves by what the record actually
 * HAS — a summary means the work finished, no summary means it stopped after
 * transcription — never by assuming a live stage, which would make every old
 * record look interrupted at the next launch.
 */
export function normalizeHistoryStatus(
  raw: unknown,
  options: { hasSummary: boolean },
): HistoryStatus {
  if (typeof raw === "string") {
    if ((HISTORY_STATUSES as readonly string[]).includes(raw)) {
      return raw as HistoryStatus;
    }
    if (raw === "completed") return "done";
  }
  return options.hasSummary ? "done" : "transcribed";
}

/**
 * Human-facing text for a status. `interrupted` is the record's own flag,
 * written by the launch sweep: a failure that happened because the process
 * went away reads as "Interrupted" rather than naming a stage that never got
 * a chance to fail on its own.
 *
 * `paused` is the record's other flag (XIA-447), and it is deliberately a FLAG
 * rather than a status: a paused live session is still `recording` to every
 * consumer — it owns a record and holds an audio file open — and the one thing
 * a decoder cannot be tolerant about is the vocabulary itself.
 * `normalizeHistoryStatus` resolves an unrecognized value by what the record
 * HAS, so a `"paused"` status read by an older build would come back as
 * `transcribed`: a *rest* state, which `isInFlight` refuses and the launch
 * sweep therefore never revisits. A paused session whose process went away
 * would have become a finished transcript with no transcript in it.
 *
 * So the machine is untouched, and a **failure wins over the flag**: an
 * interrupted paused record resolves to `failed:recording` + `interrupted` and
 * reads "Interrupted", which is what happened to it. `macos/Nota/App/
 * HistoryStatus.swift`'s `presentation(interrupted:paused:)` is the same
 * function on the other side.
 */
export function describeHistoryStatus(
  status: HistoryStatus,
  options?: { interrupted?: boolean; paused?: boolean },
): string {
  const stage = failureStage(status);
  if (stage !== null) {
    if (options?.interrupted) return "Interrupted";
    return `Failed (${stage})`;
  }
  if (options?.paused && status === "recording") return "Paused";
  switch (status) {
    case "recording":
      return "Recording";
    case "transcribing":
      return "Transcribing";
    case "transcribed":
      return "Transcribed";
    case "summarizing":
      return "Summarizing";
    case "done":
    default:
      return "Done";
  }
}
