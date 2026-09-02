/**
 * `nota voiceprint-serve` — one process, one model load, many turns (ADR 0008).
 *
 * The macOS app has no ML runtime of its own: every embedding in this project
 * is computed here, in Node, by `src/pipeline/embed.ts` against a 27 MB
 * WeSpeaker ONNX model. The app's existing pattern is a fresh `nota` process
 * per operation (`EnrollQueue`), which during a meeting would reload those
 * 27 MB every few seconds. This verb is started once with the session, loads
 * the backend once, and then answers turns until its stdin closes.
 *
 * ## The protocol
 *
 * Newline-delimited JSON. One request object per line on **stdin**, one
 * response object per line on **stdout**, each response echoing the request's
 * `id` so the caller can match them. stdout carries nothing else — every
 * diagnostic goes to stderr.
 *
 * Requests are handled **one at a time, in order**, and the helper stops
 * reading stdin while it works: a caller cannot outrun the model and grow an
 * unbounded queue inside this process.
 *
 * ### The ready line — the first thing written, and the health answer
 *
 *     {"type":"ready","protocol":1,"ok":true,"speakers":2,"voiceprints":3}
 *     {"type":"ready","protocol":1,"ok":false,"reason":"…"}
 *
 * It is written only after the model has loaded *and* run once, so a caller
 * that has seen `ok:true` knows a turn will be answered rather than waiting
 * behind a 27 MB read. `ok:false` means no request will ever produce a name;
 * the helper stays up anyway and answers every match with `name:null` without
 * touching the model. That is deliberate: the caller then owns the lifetime
 * in exactly one way (close stdin), and never has to tell a self-exit apart
 * from a crash mid-meeting.
 *
 * `speakers` / `voiceprints` are the enrolled counts. Zero of them means no
 * name can ever be drawn this session — ADR 0008 accepts that the column
 * simply stays empty.
 *
 * ### match — a turn's audio in, a confident name or nothing out
 *
 *     {"id":"7","op":"match","pcm":"<base64>"}
 *
 * `pcm` is base64 of **16 kHz mono signed 16-bit little-endian** samples —
 * exactly what the Swift side already holds in memory, and host byte order on
 * every platform Nota ships to. Base64 on the line is chosen for being
 * obvious and dependency-free; the ceiling it buys is
 * {@link MAX_PCM_SECONDS} seconds of audio (~1.9 MB raw, ~2.6 MB encoded) per
 * request, with {@link MAX_LINE_BYTES} as the hard stop on any single line.
 * A turn longer than the ceiling is embedded from its leading
 * {@link MAX_PCM_SECONDS} seconds and the answer says `truncated:true`: a turn
 * is one speaker's, so the head identifies them as well as the whole, and a
 * refusal would cost a monologue its name for no gain.
 *
 *     {"id":"7","ok":true,"name":"Kenny Kim","score":0.71}
 *     {"id":"7","ok":true,"name":null,"reason":"tentative"}
 *
 * **A name is returned only for a confident match** (`MATCH_THRESHOLD`, 0.65),
 * because ADR 0008 forbids a guess on screen. A tentative-band match
 * (`TENTATIVE_THRESHOLD`, 0.50) answers `name:null`, and no `"Speaker 1"`-style
 * label is ever invented here — that was proposed and rejected. `score`
 * crosses the boundary only when a name does, so nothing in this protocol can
 * be rendered as a guess; it is there for logging, not for re-thresholding.
 * The threshold decision is made here, once, by the same code the batch
 * pipeline uses.
 *
 * `reason` says why there is no name, and none of these is an error:
 *
 * - `insufficient-speech` — the turn was too short to embed
 *   (`InsufficientSpeechError`). Normal; ADR 0008 names it.
 * - `tentative` — a match in [0.50, 0.65).
 * - `no-match` — nothing reached the tentative floor, or the open-set margin
 *   gate rejected it.
 * - `no-voiceprints` — nobody is enrolled. Short-circuited before the model.
 * - `unavailable` — the backend never loaded (see the ready line).
 *
 * ### reload — re-read the voiceprint store
 *
 *     {"id":"8","op":"reload"}
 *     {"id":"8","ok":true,"speakers":2,"voiceprints":4}
 *
 * The store is read once at startup, so an enrollment that lands while the
 * helper is up is otherwise invisible to it.
 *
 * ### Failure
 *
 *     {"id":"9","ok":false,"error":"…"}
 *     {"id":null,"ok":false,"error":"malformed JSON"}
 *
 * A bad request answers with an error and the helper keeps serving: a meeting
 * must not lose naming for the rest of its length because one turn was
 * unreadable. Blank lines are ignored. A line over the byte cap is dropped,
 * answered with an error carrying `"id":null`, and the reader resynchronizes
 * at the next newline rather than trying to parse the tail as a request.
 *
 * ### Shutdown
 *
 * Closing stdin ends the process — that is the only way it ends, so the parent
 * dying (which closes the pipe) takes the helper with it and there is nothing
 * to leak.
 *
 * ## Seams
 *
 * `serveVoiceprints` takes injectable `input`/`out`/`write`/`backend`/
 * `loadStore` the way `src/cli/storage.ts` takes `ask`/`write`/`out`, so every
 * branch above is driven from a test with no microphone, no ONNX model, and
 * no `~/.nota`.
 */

import {
  computeEmbedding,
  InsufficientSpeechError,
  MATCH_THRESHOLD,
} from "../pipeline/embed.js";
import {
  loadProfiles,
  matchProfiles,
  type SpeakerStore,
} from "../pipeline/speakers.js";
import { SAMPLE_RATE } from "../utils/pcm.js";

/** Protocol version carried on the ready line. Bump on a breaking change. */
export const PROTOCOL_VERSION = 1;

/** Longest span of a turn that is embedded; the rest is dropped. */
export const MAX_PCM_SECONDS = 60;

/** Byte ceiling on the decoded PCM of one request. */
export const MAX_PCM_BYTES = SAMPLE_RATE * 2 * MAX_PCM_SECONDS;

/**
 * Hard stop on a single stdin line, comfortably above the base64 of
 * {@link MAX_PCM_BYTES} (~2.6 MB). A writer that never sends a newline may
 * not grow this process without bound.
 */
export const MAX_LINE_BYTES = 4 * 1024 * 1024;

/**
 * The one label `match` scores under. `matchProfiles` is written for a
 * document's whole set of diarized labels; a live turn is a set of one, which
 * it handles unchanged — and using it rather than a private comparison is
 * what keeps a live name and the name the seal computes from disagreeing for
 * no reason. The open-set margin gate comes with it: a person with two very
 * similar voiceprints can be gated out here exactly as they are in the batch
 * path, which is the same answer rather than a new one.
 */
const TURN_LABEL = "turn";

export type NoNameReason =
  | "insufficient-speech"
  | "tentative"
  | "no-match"
  | "no-voiceprints"
  | "unavailable";

/**
 * A `match` answer. The union is the protocol's one promise made structural:
 * a `score` exists only on the branch that carries a `name`, so no edit can
 * put a number on the wire for a turn Nota is not confident about.
 */
export type MatchResponse =
  | { ok: true; name: string; score: number; truncated?: boolean }
  | { ok: true; name: null; reason: NoNameReason; truncated?: boolean };

/** The model, behind one seam so a test never loads 27 MB. */
export interface VoiceprintBackend {
  /** Load and warm the model. Throws with a reportable reason. */
  load(): Promise<void>;
  embed(pcm: Int16Array): Promise<Float32Array>;
}

export interface VoiceprintServeIO {
  /** Request lines. Defaults to the real stdin. */
  input?: AsyncIterable<string | Uint8Array>;
  /** stdout — protocol lines only, newline appended by the caller. */
  out?: (line: string) => void;
  /** stderr — diagnostics. */
  write?: (message: string) => void;
  backend?: VoiceprintBackend;
  /** Defaults to the real `~/.nota/speakers.json` through `loadProfiles`. */
  loadStore?: () => Promise<SpeakerStore>;
}

// MARK: - The default backend

/**
 * Half a second of deterministic low-amplitude noise. The warm-up embeds it
 * so readiness means "the model loaded *and* ran", not "the file exists":
 * a broken native runtime or a failed first-run download is then reported on
 * the ready line instead of on the meeting's first turn. Noise rather than
 * silence because `computeEmbedding` rejects a zero-length embedding, which
 * digital silence can produce.
 */
function warmUpPcm(): Int16Array {
  const pcm = new Int16Array(SAMPLE_RATE / 2);
  let seed = 1;
  for (let i = 0; i < pcm.length; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    pcm[i] = (seed % 2048) - 1024;
  }
  return pcm;
}

const defaultBackend: VoiceprintBackend = {
  load: async () => {
    await computeEmbedding(warmUpPcm());
  },
  embed: computeEmbedding,
};

// MARK: - Line framing

export type InputLine =
  | { kind: "line"; text: string }
  | { kind: "overflow"; bytes: number };

/**
 * Split a byte stream into lines, refusing any line over `maxLineBytes`.
 * An over-long line yields one `overflow` and is then discarded through to
 * the next newline, so the tail of a runaway write is never parsed as a
 * request of its own. Chunks are kept unconcatenated until a line completes,
 * because a 2.6 MB request arrives as ~40 stdin reads and growing one buffer
 * per read is quadratic.
 */
export async function* splitLines(
  input: AsyncIterable<string | Uint8Array>,
  maxLineBytes = MAX_LINE_BYTES,
): AsyncGenerator<InputLine> {
  let chunks: Buffer[] = [];
  let size = 0;
  let discarding = false;

  for await (const raw of input) {
    let buf = typeof raw === "string" ? Buffer.from(raw, "utf8") : Buffer.from(raw);
    while (buf.length > 0) {
      const newline = buf.indexOf(0x0a);
      if (newline === -1) {
        if (discarding) break;
        if (size + buf.length > maxLineBytes) {
          const bytes = size + buf.length;
          chunks = [];
          size = 0;
          discarding = true;
          yield { kind: "overflow", bytes };
          break;
        }
        chunks.push(buf);
        size += buf.length;
        break;
      }

      const head = buf.subarray(0, newline);
      buf = buf.subarray(newline + 1);
      if (discarding) {
        discarding = false;
        continue;
      }
      if (size + head.length > maxLineBytes) {
        const bytes = size + head.length;
        chunks = [];
        size = 0;
        yield { kind: "overflow", bytes };
        continue;
      }
      chunks.push(head);
      size += head.length;
      const text = Buffer.concat(chunks, size).toString("utf8");
      chunks = [];
      size = 0;
      yield { kind: "line", text };
    }
  }

  if (!discarding && size > 0) {
    yield { kind: "line", text: Buffer.concat(chunks, size).toString("utf8") };
  }
}

// MARK: - PCM decoding

const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;

export class RequestError extends Error {}

/**
 * Decode a request's `pcm` field into samples. Refuses garbage loudly rather
 * than embedding it: `Buffer.from(…, "base64")` silently skips characters it
 * does not recognize, so a corrupted field would otherwise produce a shorter
 * clip and a confident-looking wrong answer.
 */
export function decodePcm(field: unknown): { pcm: Int16Array; truncated: boolean } {
  if (typeof field !== "string" || field.length === 0) {
    throw new RequestError("match requires a base64 `pcm` field");
  }
  if (!BASE64.test(field)) {
    throw new RequestError("`pcm` is not valid base64");
  }
  const decoded = Buffer.from(field, "base64");
  if (decoded.length === 0) {
    throw new RequestError("`pcm` decoded to no audio");
  }
  if (decoded.length % 2 !== 0) {
    throw new RequestError("`pcm` must be a whole number of 16-bit samples");
  }

  const truncated = decoded.length > MAX_PCM_BYTES;
  // Copy rather than view: a pooled Buffer's byteOffset need not be even, and
  // an Int16Array cannot be laid over an odd offset.
  const bytes = Uint8Array.from(
    truncated ? decoded.subarray(0, MAX_PCM_BYTES) : decoded,
  );
  return {
    pcm: new Int16Array(bytes.buffer, bytes.byteOffset, bytes.length / 2),
    truncated,
  };
}

// MARK: - The server

function countVoiceprints(store: SpeakerStore): number {
  return Object.values(store.speakers).reduce(
    (total, profile) => total + profile.voiceprints.length,
    0,
  );
}

function responseId(raw: unknown): string | number | null {
  return typeof raw === "string" || typeof raw === "number" ? raw : null;
}

function defaultOut(line: string): void {
  process.stdout.write(`${line}\n`);
}

function defaultWrite(message: string): void {
  process.stderr.write(`${message}\n`);
}

/**
 * Serve until `input` ends. Resolves with the process exit code — always 0
 * for a clean end, including a backend that never loaded, because the ready
 * line is where that is reported and an exit code cannot carry a reason.
 */
export async function serveVoiceprints(io: VoiceprintServeIO = {}): Promise<number> {
  const out = io.out ?? defaultOut;
  const write = io.write ?? defaultWrite;
  const backend = io.backend ?? defaultBackend;
  const load = io.loadStore ?? (() => loadProfiles());

  if (!io.out) {
    // The parent going away closes our stdout; an EPIPE would otherwise
    // surface as an unhandled error event and a non-zero exit for a shutdown
    // that is entirely normal.
    process.stdout.on("error", () => process.exit(0));
  }

  const emit = (payload: Record<string, unknown>): void => {
    out(JSON.stringify(payload));
  };

  let store: SpeakerStore = { version: 4, speakers: {} };
  try {
    store = await load();
  } catch (error) {
    // A store we cannot read is a session with no names, never a dead helper.
    write(`voiceprint-serve: could not read the speaker store: ${describe(error)}`);
  }

  let available = true;
  try {
    await backend.load();
  } catch (error) {
    available = false;
    write(`voiceprint-serve: speaker model unavailable: ${describe(error)}`);
    emit({
      type: "ready",
      protocol: PROTOCOL_VERSION,
      ok: false,
      reason: describe(error),
    });
  }
  if (available) {
    emit({
      type: "ready",
      protocol: PROTOCOL_VERSION,
      ok: true,
      speakers: Object.keys(store.speakers).length,
      voiceprints: countVoiceprints(store),
    });
  }

  async function match(field: unknown): Promise<MatchResponse> {
    if (!available) return { ok: true, name: null, reason: "unavailable" };
    if (countVoiceprints(store) === 0) {
      // Cheaper than the model, and the answer cannot be anything else.
      return { ok: true, name: null, reason: "no-voiceprints" };
    }

    const { pcm, truncated } = decodePcm(field);
    let embedding: Float32Array;
    try {
      embedding = await backend.embed(pcm);
    } catch (error) {
      if (error instanceof InsufficientSpeechError) {
        return {
          ok: true,
          name: null,
          reason: "insufficient-speech",
          ...(truncated ? { truncated } : {}),
        };
      }
      throw error;
    }

    const result = matchProfiles(
      { [TURN_LABEL]: Array.from(embedding) },
      store,
    )[TURN_LABEL];
    const extra = truncated ? { truncated } : {};
    if (!result) return { ok: true, name: null, reason: "no-match", ...extra };
    if (result.confidence < MATCH_THRESHOLD) {
      // `matchProfiles` flags this `tentative`; the threshold is re-read here
      // so the one thing this protocol promises is checked against the
      // number itself, not against a boolean somebody could stop setting.
      return { ok: true, name: null, reason: "tentative", ...extra };
    }
    return { ok: true, name: result.name, score: result.confidence, ...extra };
  }

  for await (const line of splitLines(io.input ?? process.stdin)) {
    if (line.kind === "overflow") {
      emit({
        id: null,
        ok: false,
        error: `request line exceeds ${MAX_LINE_BYTES} bytes (${line.bytes})`,
      });
      continue;
    }
    if (line.text.trim().length === 0) continue;

    let request: Record<string, unknown>;
    try {
      const parsed: unknown = JSON.parse(line.text);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        emit({ id: null, ok: false, error: "request must be a JSON object" });
        continue;
      }
      request = parsed as Record<string, unknown>;
    } catch {
      emit({ id: null, ok: false, error: "malformed JSON" });
      continue;
    }

    const id = responseId(request.id);
    try {
      switch (request.op) {
        case "match":
          emit({ id, ...(await match(request.pcm)) });
          break;
        case "reload":
          store = await load();
          emit({
            id,
            ok: true,
            speakers: Object.keys(store.speakers).length,
            voiceprints: countVoiceprints(store),
          });
          break;
        default:
          emit({
            id,
            ok: false,
            error: `unknown op ${JSON.stringify(request.op ?? null)}`,
          });
      }
    } catch (error) {
      emit({ id, ok: false, error: describe(error) });
    }
  }

  return 0;
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
