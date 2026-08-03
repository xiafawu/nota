import { beforeEach, describe, it, expect, vi } from "vitest";

// Mock the OpenAI client so generateTags/summarizeOnly never hit the network.
// The prompt-builder and parser tests below are pure and unaffected.
const createMock = vi.hoisted(() => vi.fn());
vi.mock("openai", () => ({
  default: class MockOpenAI {
    chat = { completions: { create: createMock } };
  },
}));

import {
  buildMemoPrompt,
  buildSummaryPrompt,
  buildSpeakerLabeledTranscript,
  buildTagsPrompt,
  generateTags,
  parseMemoResponse,
  parseSummaryResponse,
  parseTags,
  sampleTranscriptForTags,
  summarizeOnly,
  summarizeTranscript,
} from "../../src/pipeline/summarize.js";
import type { TranscriptSegment } from "../../src/pipeline/transcribe.js";

function gptResponse(content: string, promptTokens = 100, completionTokens = 20) {
  return {
    choices: [{ message: { content } }],
    usage: { prompt_tokens: promptTokens, completion_tokens: completionTokens },
  };
}

describe("buildSummaryPrompt", () => {
  it("includes the transcript in the prompt", () => {
    const prompt = buildSummaryPrompt("Hello, this is a test meeting.");
    expect(prompt).toContain("Hello, this is a test meeting.");
    expect(prompt).toContain("Key Topics");
    expect(prompt).toContain("Action Items");
    expect(prompt).toContain("Decisions Made");
  });

  it("asks for a title and tags", () => {
    const prompt = buildSummaryPrompt("Some transcript.");
    expect(prompt).toContain("### Title");
    expect(prompt).toContain("### Tags");
  });

  it("omits the tags block when includeTags is false", () => {
    const prompt = buildSummaryPrompt("Some transcript.", false, {
      includeTags: false,
    });
    expect(prompt).not.toContain("### Tags");
    // Everything else is intact.
    expect(prompt).toContain("### Title");
    expect(prompt).toContain("### Action Items");
  });

  it("includes the tags block when includeTags is explicitly true", () => {
    const prompt = buildSummaryPrompt("Some transcript.", false, {
      includeTags: true,
    });
    expect(prompt).toContain("### Tags");
  });
});

describe("buildTagsPrompt", () => {
  it("embeds the text and asks for a single comma-separated line", () => {
    const prompt = buildTagsPrompt("We discussed hiring and the roadmap.");
    expect(prompt).toContain("We discussed hiring and the roadmap.");
    expect(prompt).toContain("3 to 6 short, lowercase topical tags");
    expect(prompt).toContain("comma-separated");
  });
});

describe("parseSummaryResponse", () => {
  it("extracts title and tags alongside the other sections", () => {
    const response = `### Title
Q3 Planning Sync

### Summary
We aligned on the roadmap.

### Key Topics
- **Roadmap** — Q3 priorities

### Decisions Made
- Ship feature X first

### Action Items
- [ ] Draft spec — assigned to Alice

### Tags
planning, roadmap, hiring`;

    const result = parseSummaryResponse(response);
    expect(result.title).toBe("Q3 Planning Sync");
    expect(result.tags).toEqual(["planning", "roadmap", "hiring"]);
    expect(result.narrative).toBe("We aligned on the roadmap.");
    expect(result.keyTopics).toEqual(["**Roadmap** — Q3 priorities"]);
  });

  it("strips wrapping quotes from the title and lowercases/dedupes tags", () => {
    const response = `### Title
"Kickoff Meeting"

### Summary
Intro.

### Tags
- Kickoff
- Planning
- planning`;

    const result = parseSummaryResponse(response);
    expect(result.title).toBe("Kickoff Meeting");
    expect(result.tags).toEqual(["kickoff", "planning"]);
  });

  it("defaults title to empty and tags to [] when absent", () => {
    const response = `### Summary
Just a summary, no title.`;
    const result = parseSummaryResponse(response);
    expect(result.title).toBe("");
    expect(result.tags).toEqual([]);
  });
});

describe("generateTags", () => {
  beforeEach(() => {
    createMock.mockReset();
  });

  it("parses tags from the model reply and reports usage", async () => {
    createMock.mockResolvedValue(gptResponse("planning, roadmap, hiring", 40, 8));

    const result = await generateTags("Some text.", "test-key", "gpt-5-mini");

    expect(result.tags).toEqual(["planning", "roadmap", "hiring"]);
    expect(result.tokenUsage).toEqual({ calls: 1, tokensIn: 40, tokensOut: 8 });
    // The prompt is the tags prompt, capped at 1024 output tokens (reasoning
    // models burn budget on reasoning tokens before emitting content).
    const request = createMock.mock.calls[0][0];
    expect(request.max_completion_tokens).toBe(1024);
    expect(request.messages[0].content).toContain("topical tags");
  });

  it("throws when the reply parses to no tags (never writes empty tags)", async () => {
    createMock.mockResolvedValue(gptResponse("   \n  "));

    await expect(
      generateTags("Some text.", "test-key", "gpt-5-mini"),
    ).rejects.toThrow(/no usable tags/);
  });

  it("throws on an entirely empty completion", async () => {
    createMock.mockResolvedValue(gptResponse(""));

    await expect(
      generateTags("Some text.", "test-key", "gpt-5-mini"),
    ).rejects.toThrow(/Empty response/);
  });
});

describe("summarizeOnly", () => {
  beforeEach(() => {
    createMock.mockReset();
  });

  it("uses the tag-less prompt and returns the parsed summary", async () => {
    createMock.mockResolvedValue(
      gptResponse("### Title\nSync\n\n### Summary\nWe met and decided things."),
    );

    const { summary } = await summarizeOnly("A transcript.", "test-key", "gpt-5-mini");

    expect(summary.narrative).toBe("We met and decided things.");
    const request = createMock.mock.calls[0][0];
    expect(request.messages[0].content).not.toContain("### Tags");
  });

  it("throws when the response yields an empty narrative", async () => {
    createMock.mockResolvedValue(gptResponse("### Title\nSync only, no summary."));

    await expect(
      summarizeOnly("A transcript.", "test-key", "gpt-5-mini"),
    ).rejects.toThrow(/empty summary/);
  });
});

describe("parseTags", () => {
  it("returns [] for whitespace-only content", () => {
    expect(parseTags("  \n ")).toEqual([]);
  });

  it("lowercases, dedupes, and caps at 8", () => {
    expect(parseTags("A, a, B, c, d, e, f, g, h, i")).toEqual([
      "a",
      "b",
      "c",
      "d",
      "e",
      "f",
      "g",
      "h",
    ]);
  });
});

describe("sampleTranscriptForTags", () => {
  it("returns short text unchanged", () => {
    expect(sampleTranscriptForTags("short transcript")).toBe("short transcript");
  });

  it("samples head, middle, and tail of an over-long transcript", () => {
    const head = "HEAD".repeat(30_000); // 120k chars
    const middle = "MIDL".repeat(30_000);
    const tail = "TAIL".repeat(30_000);
    const text = head + middle + tail; // 360k chars ≈ 90k tokens

    const sampled = sampleTranscriptForTags(text, 50_000);

    // Fits the 50k-token (≈200k chars) budget and keeps material from all
    // three regions.
    expect(sampled.length).toBeLessThanOrEqual(50_000 * 4 + 20);
    expect(sampled).toContain("HEAD");
    expect(sampled).toContain("MIDL");
    expect(sampled).toContain("TAIL");
  });
});

describe("buildSpeakerLabeledTranscript", () => {
  it("formats segments with speaker labels", () => {
    const segments: TranscriptSegment[] = [
      { start: 0, end: 5, text: "Hello", speaker: "Speaker 1" },
      { start: 5, end: 10, text: "Hi there", speaker: "Speaker 2" },
      { start: 10, end: 15, text: "Let's start" },
    ];
    const result = buildSpeakerLabeledTranscript(segments);
    expect(result).toContain("Speaker 1: Hello");
    expect(result).toContain("Speaker 2: Hi there");
    expect(result).toContain("Let's start");
    expect(result).not.toContain("undefined");
  });
});

describe("buildMemoPrompt", () => {
  it("asks for a cleaned note, not meeting scaffolding", () => {
    const prompt = buildMemoPrompt("So, um, we should ship the thing, you know.");
    expect(prompt).toContain("So, um, we should ship the thing, you know.");
    expect(prompt).toContain("### Note");
    expect(prompt).toContain("remove filler");
    // Memo template has no Key Topics / Decisions / Tags scaffolding.
    expect(prompt).not.toContain("### Key Topics");
    expect(prompt).not.toContain("Decisions Made");
    expect(prompt).not.toContain("### Tags");
    // Memo-length title instruction (shorter than the meeting's 6-word cap).
    expect(prompt).toContain("at most 4 words");
  });

  it("keeps action items optional", () => {
    const prompt = buildMemoPrompt("Some dictation.");
    expect(prompt).toContain("### Action Items");
    expect(prompt).toContain("Only include this section when");
  });
});

describe("parseMemoResponse", () => {
  it("extracts title and note; topics/decisions stay empty", () => {
    const response = `### Title
Grocery run

### Note
Picked up groceries. Need to water the plants.

### Action Items
- [ ] Water the plants — me
`;
    const summary = parseMemoResponse(response);
    expect(summary.title).toBe("Grocery run");
    expect(summary.narrative).toContain("Picked up groceries");
    expect(summary.actionItems).toEqual(["[ ] Water the plants — me"]);
    expect(summary.keyTopics).toEqual([]);
    expect(summary.decisions).toEqual([]);
    expect(summary.tags).toEqual([]);
  });

  it("collapses the no-action-items marker to an empty list", () => {
    const response = `### Title
Quick thought

### Note
Just a thought, nothing to do.

### Action Items
No action items.
`;
    const summary = parseMemoResponse(response);
    expect(summary.actionItems).toEqual([]);
  });

  it("leaves a memo without an Action Items section with an empty list", () => {
    const response = `### Title
Quick thought

### Note
Just a thought, nothing to do.
`;
    const summary = parseMemoResponse(response);
    expect(summary.actionItems).toEqual([]);
    expect(summary.title).toBe("Quick thought");
  });
});

describe("summarizeTranscript memo kind", () => {
  it("parses a memo-model response with the memo parser (cleaned note)", async () => {
    createMock.mockResolvedValueOnce(
      gptResponse(`### Title
Daily standup note

### Note
Everyone is blocked on the same API outage.

### Action Items
- [ ] Ping the provider — Sam
`),
    );
    const { summary } = await summarizeTranscript(
      "raw dictation text",
      "test-key",
      "gpt-5-mini",
      undefined,
      undefined,
      undefined,
      "memo",
    );
    expect(summary.title).toBe("Daily standup note");
    expect(summary.keyTopics).toEqual([]);
    expect(summary.decisions).toEqual([]);
    expect(summary.actionItems).toEqual(["[ ] Ping the provider — Sam"]);
    // The memo prompt (not the meeting prompt) was sent.
    const prompt = createMock.mock.calls.at(-1)![0].messages[0].content as string;
    expect(prompt).toContain("### Note");
    expect(prompt).not.toContain("### Key Topics");
  });

  it("defaults to the meeting template for meeting/file kinds (byte-identical)", async () => {
    createMock.mockResolvedValueOnce(
      gptResponse(`### Title
Sync

### Summary
We synced.

### Key Topics
- **Roadmap** — Q3

### Decisions Made
No explicit decisions were recorded.

### Action Items
No action items were identified.

### Tags
sync, roadmap
`),
    );
    const { summary } = await summarizeTranscript(
      "transcript",
      "test-key",
      "gpt-5-mini",
      undefined,
      undefined,
      undefined,
      "file",
    );
    expect(summary.keyTopics).toEqual(["**Roadmap** — Q3"]);
    // "No explicit decisions were recorded." is not a bullet line, so the
    // parser leaves the section empty (existing parseSummaryResponse
    // convention).
    expect(summary.decisions).toEqual([]);
    expect(summary.actionItems).toEqual([]);
    const prompt = createMock.mock.calls.at(-1)![0].messages[0].content as string;
    expect(prompt).toContain("### Key Topics");
    expect(prompt).not.toContain("### Note");
  });
});
