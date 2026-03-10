import { createReadStream } from "node:fs";
import OpenAI from "openai";
import pLimit from "p-limit";

export interface TranscriptSegment {
  start: number;
  end: number;
  text: string;
}

export interface TranscriptionResult {
  segments: TranscriptSegment[];
  text: string;
}

export function formatTimestamp(seconds: number): string {
  const mins = Math.floor(seconds / 60);
  const secs = Math.floor(seconds % 60);
  return `[${String(mins).padStart(2, "0")}:${String(secs).padStart(2, "0")}]`;
}

export async function transcribeChunks(
  chunkPaths: string[],
  apiKey: string,
  language?: string
): Promise<TranscriptionResult[]> {
  const client = new OpenAI({ apiKey });
  const limit = pLimit(3);

  const results = await Promise.all(
    chunkPaths.map((chunkPath) =>
      limit(async () => {
        const response = await client.audio.transcriptions.create({
          file: createReadStream(chunkPath),
          model: "whisper-1",
          response_format: "verbose_json",
          timestamp_granularities: ["segment"],
          ...(language ? { language } : {}),
        });

        const segments: TranscriptSegment[] = (
          (response as any).segments ?? []
        ).map((seg: any) => ({
          start: seg.start,
          end: seg.end,
          text: seg.text.trim(),
        }));

        return {
          segments,
          text: response.text,
        };
      })
    )
  );

  return results;
}
