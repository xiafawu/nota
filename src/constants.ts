export const SEGMENT_DURATION = 600; // 10 minutes in seconds
export const OVERLAP_DURATION = 30; // 30 seconds overlap
export const CHUNK_THRESHOLD_BYTES = 20 * 1024 * 1024; // 20MB

export const SUPPORTED_AUDIO_EXTENSIONS = [
  ".mp3",
  ".wav",
  ".m4a",
  ".aac",
  ".caf",
  ".aif",
  ".aiff",
  ".ogg",
  ".webm",
  ".flac",
  ".qta",
  ".mov",
  ".mp4",
] as const;
