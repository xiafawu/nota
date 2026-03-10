const CHARS_PER_TOKEN = 4;
const MAX_TRANSCRIPT_TOKENS = 100_000;

export function estimateTokens(text: string): number {
  return Math.ceil(text.length / CHARS_PER_TOKEN);
}

export function shouldChunkTranscript(transcript: string): boolean {
  return estimateTokens(transcript) > MAX_TRANSCRIPT_TOKENS;
}

export function splitTranscriptIntoSections(
  transcript: string,
  maxTokensPerSection: number = 50_000
): string[] {
  const lines = transcript.split("\n");
  const sections: string[] = [];
  let current: string[] = [];
  let currentTokens = 0;

  for (const line of lines) {
    const lineTokens = estimateTokens(line);
    if (currentTokens + lineTokens > maxTokensPerSection && current.length > 0) {
      sections.push(current.join("\n"));
      current = [];
      currentTokens = 0;
    }
    current.push(line);
    currentTokens += lineTokens;
  }

  if (current.length > 0) {
    sections.push(current.join("\n"));
  }

  return sections;
}
