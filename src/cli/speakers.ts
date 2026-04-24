import {
  DEFAULT_SPEAKERS_FILE,
  loadProfiles,
  saveProfiles,
  type SpeakerProfile,
  type SpeakerStore,
} from "../pipeline/speakers.js";

export interface SpeakerCommandOptions {
  storePath?: string;
}

function resolveStorePath(options?: SpeakerCommandOptions): string {
  return options?.storePath ?? DEFAULT_SPEAKERS_FILE;
}

function l2Norm(vec: number[]): number {
  let sum = 0;
  for (const v of vec) sum += v * v;
  return Math.sqrt(sum);
}

function normalize(vec: number[]): number[] {
  const norm = l2Norm(vec);
  if (norm === 0) return vec.slice();
  return vec.map((v) => v / norm);
}

export function averageEmbeddings(a: number[], b: number[]): number[] {
  if (a.length !== b.length) {
    throw new Error(
      `Cannot average embeddings of different lengths (${a.length} vs ${b.length})`,
    );
  }
  const summed = a.map((value, index) => (value + b[index]) / 2);
  return normalize(summed);
}

function requireProfile(
  store: SpeakerStore,
  name: string,
): SpeakerProfile {
  const profile = store.speakers[name];
  if (!profile) {
    throw new Error(`Speaker "${name}" not found.`);
  }
  return profile;
}

export async function listSpeakers(
  options?: SpeakerCommandOptions,
): Promise<void> {
  const store = await loadProfiles(resolveStorePath(options));
  const entries = Object.entries(store.speakers);
  if (entries.length === 0) {
    process.stderr.write("No speakers enrolled.\n");
    return;
  }
  for (const [name, profile] of entries) {
    const line = [
      name,
      profile.enrolledAt,
      profile.source,
      String(profile.embedding.length),
    ].join("\t");
    process.stdout.write(`${line}\n`);
  }
}

export async function renameSpeaker(
  oldName: string,
  newName: string,
  options?: SpeakerCommandOptions,
): Promise<void> {
  const storePath = resolveStorePath(options);
  const store = await loadProfiles(storePath);
  const profile = requireProfile(store, oldName);
  if (oldName === newName) {
    process.stderr.write(`Speaker "${oldName}" already has that name.\n`);
    return;
  }
  if (store.speakers[newName]) {
    throw new Error(
      `Cannot rename: speaker "${newName}" already exists.`,
    );
  }
  delete store.speakers[oldName];
  store.speakers[newName] = profile;
  await saveProfiles(store, storePath);
  process.stderr.write(`Renamed "${oldName}" to "${newName}".\n`);
}

export async function deleteSpeaker(
  name: string,
  options?: SpeakerCommandOptions,
): Promise<void> {
  const storePath = resolveStorePath(options);
  const store = await loadProfiles(storePath);
  requireProfile(store, name);
  delete store.speakers[name];
  await saveProfiles(store, storePath);
  process.stderr.write(`Deleted speaker "${name}".\n`);
}

export async function mergeSpeakers(
  src: string,
  dst: string,
  options?: SpeakerCommandOptions,
): Promise<void> {
  if (src === dst) {
    throw new Error("Cannot merge a speaker into itself.");
  }
  const storePath = resolveStorePath(options);
  const store = await loadProfiles(storePath);
  const srcProfile = requireProfile(store, src);
  const dstProfile = requireProfile(store, dst);
  const merged = averageEmbeddings(srcProfile.embedding, dstProfile.embedding);
  store.speakers[dst] = {
    embedding: merged,
    enrolledAt: dstProfile.enrolledAt,
    source: dstProfile.source,
  };
  delete store.speakers[src];
  await saveProfiles(store, storePath);
  process.stderr.write(`Merged "${src}" into "${dst}".\n`);
}

export async function showSpeaker(
  name: string,
  options?: SpeakerCommandOptions,
): Promise<void> {
  const store = await loadProfiles(resolveStorePath(options));
  const profile = requireProfile(store, name);
  const view = {
    name,
    enrolledAt: profile.enrolledAt,
    source: profile.source,
    embeddingLength: profile.embedding.length,
    embeddingPreview: profile.embedding.slice(0, 8),
  };
  process.stdout.write(`${JSON.stringify(view, null, 2)}\n`);
}
