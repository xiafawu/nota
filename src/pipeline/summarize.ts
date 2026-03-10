import Anthropic from "@anthropic-ai/sdk";
import { shouldChunkTranscript, splitTranscriptIntoSections } from "../utils/tokens.js";

export interface MeetingSummary {
  narrative: string;
  keyTopics: string[];
  decisions: string[];
  actionItems: string[];
}

export function buildSummaryPrompt(transcript: string): string {
  return `You are an expert meeting summarizer. Analyze the following meeting transcript and produce a structured summary.

## Transcript

${transcript}

## Instructions

Produce the following sections in your response. Use exactly these headers:

### Summary
Write a concise 2-4 sentence narrative summary of the meeting.

### Key Topics
List each major topic discussed as a bullet point in the format:
- **Topic name** — brief description

### Decisions Made
List each decision made during the meeting:
- Decision — context and rationale

If no decisions were made, write "No explicit decisions were recorded."

### Action Items
List each action item as a checkbox:
- [ ] Action item — assigned to Person (if identifiable from the transcript)

If no action items were identified, write "No action items were identified."`;
}

function buildRollupPrompt(sectionSummaries: string[]): string {
  const combined = sectionSummaries
    .map((s, i) => `## Section ${i + 1}\n\n${s}`)
    .join("\n\n---\n\n");

  return `You are an expert meeting summarizer. The following are summaries of consecutive sections of a long meeting. Combine them into a single coherent summary.

${combined}

## Instructions

Produce a unified summary with these sections using exactly these headers:

### Summary
Write a concise 2-4 sentence narrative summary of the entire meeting.

### Key Topics
Merge and deduplicate topics across all sections:
- **Topic name** — brief description

### Decisions Made
Merge all decisions:
- Decision — context and rationale

### Action Items
Merge all action items, deduplicating:
- [ ] Action item — assigned to Person`;
}

export function parseSummaryResponse(response: string): MeetingSummary {
  const sections = {
    narrative: "",
    keyTopics: [] as string[],
    decisions: [] as string[],
    actionItems: [] as string[],
  };

  const summaryMatch = response.match(
    /### Summary\s*\n([\s\S]*?)(?=\n### |$)/
  );
  if (summaryMatch) sections.narrative = summaryMatch[1].trim();

  const topicsMatch = response.match(
    /### Key Topics\s*\n([\s\S]*?)(?=\n### |$)/
  );
  if (topicsMatch) {
    sections.keyTopics = topicsMatch[1]
      .trim()
      .split("\n")
      .filter((l) => l.startsWith("- "))
      .map((l) => l.slice(2));
  }

  const decisionsMatch = response.match(
    /### Decisions Made\s*\n([\s\S]*?)(?=\n### |$)/
  );
  if (decisionsMatch) {
    sections.decisions = decisionsMatch[1]
      .trim()
      .split("\n")
      .filter((l) => l.startsWith("- "))
      .map((l) => l.slice(2));
  }

  const actionsMatch = response.match(
    /### Action Items\s*\n([\s\S]*?)(?=\n### |$)/
  );
  if (actionsMatch) {
    sections.actionItems = actionsMatch[1]
      .trim()
      .split("\n")
      .filter((l) => l.startsWith("- "))
      .map((l) => l.slice(2));
  }

  return sections;
}

async function callClaude(
  client: Anthropic,
  model: string,
  prompt: string
): Promise<string> {
  const message = await client.messages.create({
    model,
    max_tokens: 4096,
    messages: [{ role: "user", content: prompt }],
  });

  const block = message.content[0];
  if (block.type !== "text") throw new Error("Unexpected response type");
  return block.text;
}

export async function summarizeTranscript(
  transcript: string,
  apiKey: string,
  model: string
): Promise<MeetingSummary> {
  const client = new Anthropic({ apiKey });

  if (!shouldChunkTranscript(transcript)) {
    const prompt = buildSummaryPrompt(transcript);
    const response = await callClaude(client, model, prompt);
    return parseSummaryResponse(response);
  }

  // Long transcript: section-by-section then roll up
  const sections = splitTranscriptIntoSections(transcript);
  const sectionSummaries: string[] = [];

  for (const section of sections) {
    const prompt = buildSummaryPrompt(section);
    const response = await callClaude(client, model, prompt);
    sectionSummaries.push(response);
  }

  const rollupPrompt = buildRollupPrompt(sectionSummaries);
  const finalResponse = await callClaude(client, model, rollupPrompt);
  return parseSummaryResponse(finalResponse);
}
