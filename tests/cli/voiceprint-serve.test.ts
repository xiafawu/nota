import { describe, it, expect } from "vitest";
import {
  serveVoiceprints,
  splitLines,
  decodePcm,
  MAX_LINE_BYTES,
  MAX_PCM_BYTES,
  type VoiceprintBackend,
  type VoiceprintServeIO,
} from "../../src/cli/voiceprint-serve.js";
import { InsufficientSpeechError } from "../../src/pipeline/embed.js";
import type { SpeakerStore } from "../../src/pipeline/speakers.js";

// A store with two people, one voiceprint each, on orthogonal unit vectors:
// an embedding equal to one of them scores 1.0 against it and 0.0 against the
// other, which clears MATCH_THRESHOLD and the open-set margin at once.
function store(...entries: [name: string, embedding: number[]][]): SpeakerStore {
  return {
    version: 4,
    speakers: Object.fromEntries(
      entries.map(([name, embedding], index) => [
        name,
        {
          voiceprints: [
            {
              id: `vp-${index}`,
              embedding,
              enrolledAt: "2026-09-02T00:00:00.000Z",
              source: "test",
            },
          ],
        },
      ]),
    ),
  };
}

const KENNY = [1, 0, 0, 0];
const OTHER = [0, 0, 1, 0];
/** cos θ = 0.55 against KENNY — inside the tentative band [0.50, 0.65). */
const NEAR_KENNY = [0.55, Math.sqrt(1 - 0.55 * 0.55), 0, 0];

function backend(
  embed: (pcm: Int16Array) => Promise<Float32Array>,
  load: () => Promise<void> = async () => {},
): VoiceprintBackend {
  return { load, embed };
}

function returning(embedding: number[]): VoiceprintBackend {
  return backend(async () => Float32Array.from(embedding));
}

async function* lines(...requests: string[]): AsyncGenerator<string> {
  for (const request of requests) yield `${request}\n`;
}

/** Some audio; every backend here is a stub, so the samples are never read. */
function pcm(samples = 8000): string {
  return Buffer.from(new Int16Array(samples).fill(1000).buffer).toString("base64");
}

interface Run {
  code: number;
  responses: Record<string, unknown>[];
  ready: Record<string, unknown>;
  stderr: string[];
}

async function run(
  io: Omit<VoiceprintServeIO, "out" | "write">,
): Promise<Run> {
  const out: Record<string, unknown>[] = [];
  const stderr: string[] = [];
  const code = await serveVoiceprints({
    ...io,
    out: (line) => out.push(JSON.parse(line) as Record<string, unknown>),
    write: (message) => stderr.push(message),
  });
  const [ready, ...responses] = out;
  return { code, ready, responses, stderr };
}

describe("nota voiceprint-serve", () => {
  it("announces readiness once the model has loaded, then answers a turn with a confident name", async () => {
    let loads = 0;
    let embeds = 0;
    const result = await run({
      input: lines(
        JSON.stringify({ id: "a", op: "match", pcm: pcm() }),
        JSON.stringify({ id: 2, op: "match", pcm: pcm() }),
      ),
      loadStore: async () => store(["Kenny Kim", KENNY], ["Someone Else", OTHER]),
      backend: backend(
        async () => {
          embeds++;
          return Float32Array.from(KENNY);
        },
        async () => {
          loads++;
        },
      ),
    });

    expect(result.ready).toEqual({
      type: "ready",
      protocol: 1,
      ok: true,
      speakers: 2,
      voiceprints: 2,
    });
    // One process, one load, many turns — the whole reason this verb exists.
    expect(loads).toBe(1);
    expect(embeds).toBe(2);
    expect(result.responses).toEqual([
      { id: "a", ok: true, name: "Kenny Kim", score: 1 },
      { id: 2, ok: true, name: "Kenny Kim", score: 1 },
    ]);
    expect(result.code).toBe(0);
  });

  it("returns no name for a tentative-band match", async () => {
    const result = await run({
      input: lines(JSON.stringify({ id: "t", op: "match", pcm: pcm() })),
      loadStore: async () => store(["Kenny Kim", KENNY]),
      backend: returning(NEAR_KENNY),
    });

    expect(result.responses).toEqual([
      { id: "t", ok: true, name: null, reason: "tentative" },
    ]);
    // A guess never crosses the boundary, not even as a score.
    expect(JSON.stringify(result.responses)).not.toContain("Kenny");
  });

  it("returns no name when nothing reaches the tentative floor", async () => {
    const result = await run({
      input: lines(JSON.stringify({ id: "n", op: "match", pcm: pcm() })),
      loadStore: async () => store(["Kenny Kim", KENNY]),
      backend: returning(OTHER),
    });

    expect(result.responses).toEqual([
      { id: "n", ok: true, name: null, reason: "no-match" },
    ]);
  });

  it("treats a turn too short to embed as a quiet no-name, not an error", async () => {
    const result = await run({
      input: lines(
        JSON.stringify({ id: "short", op: "match", pcm: pcm(4) }),
        JSON.stringify({ id: "after", op: "match", pcm: pcm() }),
      ),
      loadStore: async () => store(["Kenny Kim", KENNY]),
      backend: backend(async (samples) => {
        if (samples.length < 400) throw new InsufficientSpeechError();
        return Float32Array.from(KENNY);
      }),
    });

    expect(result.responses[0]).toEqual({
      id: "short",
      ok: true,
      name: null,
      reason: "insufficient-speech",
    });
    // …and the session keeps naming afterwards.
    expect(result.responses[1]).toEqual({
      id: "after",
      ok: true,
      name: "Kenny Kim",
      score: 1,
    });
  });

  it("short-circuits before the model when nobody is enrolled", async () => {
    let embeds = 0;
    const result = await run({
      input: lines(JSON.stringify({ id: "e", op: "match", pcm: pcm() })),
      loadStore: async () => ({ version: 4, speakers: {} }),
      backend: backend(async () => {
        embeds++;
        return Float32Array.from(KENNY);
      }),
    });

    expect(result.ready).toMatchObject({ ok: true, speakers: 0, voiceprints: 0 });
    expect(result.responses).toEqual([
      { id: "e", ok: true, name: null, reason: "no-voiceprints" },
    ]);
    expect(embeds).toBe(0);
  });

  it("stays up and names nothing when the model never loaded", async () => {
    let embeds = 0;
    const result = await run({
      input: lines(JSON.stringify({ id: "u", op: "match", pcm: pcm() })),
      loadStore: async () => store(["Kenny Kim", KENNY]),
      backend: backend(
        async () => {
          embeds++;
          return Float32Array.from(KENNY);
        },
        async () => {
          throw new Error("onnxruntime-node could not be loaded");
        },
      ),
    });

    expect(result.ready).toEqual({
      type: "ready",
      protocol: 1,
      ok: false,
      reason: "onnxruntime-node could not be loaded",
    });
    expect(result.responses).toEqual([
      { id: "u", ok: true, name: null, reason: "unavailable" },
    ]);
    expect(embeds).toBe(0);
    expect(result.code).toBe(0);
    expect(result.stderr.join("\n")).toContain("onnxruntime-node");
  });

  it("keeps serving after a malformed request, a bad shape, an unknown op and unreadable audio", async () => {
    const result = await run({
      input: lines(
        "{not json",
        "[1,2,3]",
        JSON.stringify({ id: "x", op: "explode" }),
        JSON.stringify({ id: "y", op: "match", pcm: "not base64!!" }),
        JSON.stringify({ id: "z", op: "match" }),
        "",
        "   ",
        JSON.stringify({ id: "ok", op: "match", pcm: pcm() }),
      ),
      loadStore: async () => store(["Kenny Kim", KENNY]),
      backend: returning(KENNY),
    });

    expect(result.responses[0]).toEqual({
      id: null,
      ok: false,
      error: "malformed JSON",
    });
    expect(result.responses[1]).toEqual({
      id: null,
      ok: false,
      error: "request must be a JSON object",
    });
    expect(result.responses[2]).toEqual({
      id: "x",
      ok: false,
      error: 'unknown op "explode"',
    });
    expect(result.responses[3]).toMatchObject({ id: "y", ok: false });
    expect(result.responses[4]).toMatchObject({ id: "z", ok: false });
    // Blank lines answer nothing at all, and the good turn still lands.
    expect(result.responses).toHaveLength(6);
    expect(result.responses[5]).toEqual({
      id: "ok",
      ok: true,
      name: "Kenny Kim",
      score: 1,
    });
  });

  it("re-reads the store on reload, so an enrollment mid-session is seen", async () => {
    let reads = 0;
    const result = await run({
      input: lines(
        JSON.stringify({ id: 1, op: "match", pcm: pcm() }),
        JSON.stringify({ id: 2, op: "reload" }),
        JSON.stringify({ id: 3, op: "match", pcm: pcm() }),
      ),
      loadStore: async () => {
        reads++;
        return reads === 1
          ? { version: 4, speakers: {} }
          : store(["Kenny Kim", KENNY]);
      },
      backend: returning(KENNY),
    });

    expect(result.responses[0]).toMatchObject({ reason: "no-voiceprints" });
    expect(result.responses[1]).toEqual({
      id: 2,
      ok: true,
      speakers: 1,
      voiceprints: 1,
    });
    expect(result.responses[2]).toMatchObject({ name: "Kenny Kim" });
  });

  it("ends when stdin closes, and answers a final request that carried no newline", async () => {
    async function* unterminated(): AsyncGenerator<string> {
      yield JSON.stringify({ id: "last", op: "match", pcm: pcm() });
    }
    const result = await run({
      input: unterminated(),
      loadStore: async () => store(["Kenny Kim", KENNY]),
      backend: returning(KENNY),
    });

    expect(result.responses).toEqual([
      { id: "last", ok: true, name: "Kenny Kim", score: 1 },
    ]);
    expect(result.code).toBe(0);
  });

  it("refuses an over-long line and resynchronizes at the next newline", async () => {
    async function* flood(): AsyncGenerator<string> {
      yield `{"id":"huge","op":"match","pcm":"${"A".repeat(MAX_LINE_BYTES + 16)}`;
      yield `AAAA"}\n`;
      yield `${JSON.stringify({ id: "after", op: "match", pcm: pcm() })}\n`;
    }
    const result = await run({
      input: flood(),
      loadStore: async () => store(["Kenny Kim", KENNY]),
      backend: returning(KENNY),
    });

    expect(result.responses[0]).toMatchObject({ id: null, ok: false });
    expect(String(result.responses[0].error)).toContain("exceeds");
    expect(result.responses[1]).toEqual({
      id: "after",
      ok: true,
      name: "Kenny Kim",
      score: 1,
    });
    expect(result.responses).toHaveLength(2);
  });

  it("embeds a long turn's leading window and says it did", async () => {
    let seen = 0;
    const overCap = Buffer.alloc(MAX_PCM_BYTES + 2000).toString("base64");
    const result = await run({
      input: lines(JSON.stringify({ id: "long", op: "match", pcm: overCap })),
      loadStore: async () => store(["Kenny Kim", KENNY]),
      backend: backend(async (samples) => {
        seen = samples.length;
        return Float32Array.from(KENNY);
      }),
    });

    expect(seen).toBe(MAX_PCM_BYTES / 2);
    expect(result.responses).toEqual([
      { id: "long", ok: true, name: "Kenny Kim", score: 1, truncated: true },
    ]);
  });
});

describe("splitLines", () => {
  it("reassembles a line split across chunks and drops the trailing empty read", async () => {
    async function* chunks(): AsyncGenerator<string> {
      yield '{"a":';
      yield "1}\n{";
      yield '"b":2}\n';
    }
    const seen = [];
    for await (const line of splitLines(chunks())) seen.push(line);
    expect(seen).toEqual([
      { kind: "line", text: '{"a":1}' },
      { kind: "line", text: '{"b":2}' },
    ]);
  });

  it("reports one overflow per over-long line, whatever it took to arrive", async () => {
    async function* chunks(): AsyncGenerator<string> {
      yield "x".repeat(30);
      yield "x".repeat(30);
      yield "x".repeat(30);
      yield "\nshort\n";
    }
    const seen = [];
    for await (const line of splitLines(chunks(), 40)) seen.push(line);
    expect(seen).toEqual([
      { kind: "overflow", bytes: 60 },
      { kind: "line", text: "short" },
    ]);
  });

  it("counts bytes, not characters", async () => {
    async function* chunks(): AsyncGenerator<string> {
      yield "€€€\n"; // 3 bytes each in UTF-8
    }
    const seen = [];
    for await (const line of splitLines(chunks(), 8)) seen.push(line);
    expect(seen).toEqual([{ kind: "overflow", bytes: 9 }]);
  });
});

describe("decodePcm", () => {
  it("refuses a field that is missing, empty, not base64, or an odd byte count", () => {
    expect(() => decodePcm(undefined)).toThrow(/base64 `pcm`/);
    expect(() => decodePcm("")).toThrow(/base64 `pcm`/);
    expect(() => decodePcm(42)).toThrow(/base64 `pcm`/);
    expect(() => decodePcm("not base64!!")).toThrow(/not valid base64/);
    // "AA" decodes to a single byte — half a sample.
    expect(() => decodePcm("AA")).toThrow(/16-bit samples/);
  });

  it("decodes little-endian samples the Swift side would have written", () => {
    const source = Int16Array.from([0, 1, -1, 32767, -32768]);
    const { pcm, truncated } = decodePcm(
      Buffer.from(source.buffer).toString("base64"),
    );
    expect(Array.from(pcm)).toEqual(Array.from(source));
    expect(truncated).toBe(false);
  });
});
