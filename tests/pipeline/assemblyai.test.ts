import { describe, it, expect, vi, beforeEach } from "vitest";

const mockTranscribe = vi.fn();

vi.mock("assemblyai", () => {
  return {
    AssemblyAI: class {
      transcripts = { transcribe: mockTranscribe };
    },
  };
});

import { transcribeWithAssemblyAI } from "../../src/pipeline/assemblyai.js";

describe("transcribeWithAssemblyAI", () => {
  beforeEach(() => {
    mockTranscribe.mockReset();
  });

  it("maps utterances to TranscriptSegment format", async () => {
    mockTranscribe.mockResolvedValue({
      status: "completed",
      text: "Hello everyone. Let's begin.",
      utterances: [
        { start: 0, end: 5000, text: "Hello everyone.", speaker: "A" },
        { start: 5500, end: 10000, text: "Let's begin.", speaker: "B" },
      ],
    });

    const result = await transcribeWithAssemblyAI("/fake/audio.mp3", {
      apiKey: "test-key",
    });

    expect(result.text).toBe("Hello everyone. Let's begin.");
    expect(result.segments).toHaveLength(2);
    expect(result.segments[0]).toEqual({
      start: 0,
      end: 5,
      text: "Hello everyone.",
      speaker: "Speaker 1",
    });
    expect(result.segments[1]).toEqual({
      start: 5.5,
      end: 10,
      text: "Let's begin.",
      speaker: "Speaker 2",
    });
  });

  it("converts speaker letters to Speaker N format", async () => {
    mockTranscribe.mockResolvedValue({
      status: "completed",
      text: "One. Two. Three.",
      utterances: [
        { start: 0, end: 1000, text: "One.", speaker: "A" },
        { start: 1000, end: 2000, text: "Two.", speaker: "C" },
        { start: 2000, end: 3000, text: "Three.", speaker: "B" },
      ],
    });

    const result = await transcribeWithAssemblyAI("/fake/audio.mp3", {
      apiKey: "test-key",
    });

    expect(result.segments[0].speaker).toBe("Speaker 1");
    expect(result.segments[1].speaker).toBe("Speaker 3");
    expect(result.segments[2].speaker).toBe("Speaker 2");
  });

  it("converts milliseconds to seconds", async () => {
    mockTranscribe.mockResolvedValue({
      status: "completed",
      text: "Test.",
      utterances: [
        { start: 62500, end: 125000, text: "Test.", speaker: "A" },
      ],
    });

    const result = await transcribeWithAssemblyAI("/fake/audio.mp3", {
      apiKey: "test-key",
    });

    expect(result.segments[0].start).toBe(62.5);
    expect(result.segments[0].end).toBe(125);
  });

  it("handles empty utterances", async () => {
    mockTranscribe.mockResolvedValue({
      status: "completed",
      text: "Some text.",
      utterances: null,
    });

    const result = await transcribeWithAssemblyAI("/fake/audio.mp3", {
      apiKey: "test-key",
    });

    expect(result.segments).toEqual([]);
    expect(result.text).toBe("Some text.");
  });

  it("throws on transcription error", async () => {
    mockTranscribe.mockResolvedValue({
      status: "error",
      error: "Audio too short",
    });

    await expect(
      transcribeWithAssemblyAI("/fake/audio.mp3", { apiKey: "test-key" })
    ).rejects.toThrow("AssemblyAI transcription failed: Audio too short");
  });

  it("passes speakers_expected when numSpeakers provided", async () => {
    mockTranscribe.mockResolvedValue({
      status: "completed",
      text: "",
      utterances: [],
    });

    await transcribeWithAssemblyAI("/fake/audio.mp3", {
      apiKey: "test-key",
      numSpeakers: 3,
    });

    expect(mockTranscribe).toHaveBeenCalledWith(
      expect.objectContaining({ speakers_expected: 3 })
    );
  });

  it("passes the selected speech model via speech_models", async () => {
    mockTranscribe.mockResolvedValue({
      status: "completed",
      text: "",
      utterances: [],
    });

    await transcribeWithAssemblyAI("/fake/audio.mp3", {
      apiKey: "test-key",
      speechModel: "slam-1",
    });

    expect(mockTranscribe).toHaveBeenCalledWith(
      expect.objectContaining({ speech_models: ["slam-1"] }),
    );
  });

  it("passes language_code when language provided", async () => {
    mockTranscribe.mockResolvedValue({
      status: "completed",
      text: "",
      utterances: [],
    });

    await transcribeWithAssemblyAI("/fake/audio.mp3", {
      apiKey: "test-key",
      language: "es",
    });

    expect(mockTranscribe).toHaveBeenCalledWith(
      expect.objectContaining({ language_code: "es" })
    );
  });
});
