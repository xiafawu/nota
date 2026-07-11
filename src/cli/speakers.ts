import {
  DEFAULT_SPEAKERS_FILE,
  decodeProfile,
  loadProfiles,
  saveProfiles,
  type SpeakerProfile,
  type SpeakerStore,
  type Voiceprint,
} from "../pipeline/speakers.js";

export interface SpeakerCommandOptions {
  storePath?: string;
}

function resolveStorePath(options?: SpeakerCommandOptions): string {
  return options?.storePath ?? DEFAULT_SPEAKERS_FILE;
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

/**
 * Locate the (name, voiceprint, index) tuple for a given voiceprint id by
 * scanning every profile. Voiceprint ids are ISO timestamps issued at
 * enrollment, so they are globally unique across the store under normal
 * usage; first hit wins. Returns `null` so callers can craft a targeted
 * error message instead of throwing here.
 */
function findVoiceprint(
  store: SpeakerStore,
  vpId: string,
): { name: string; voiceprint: Voiceprint; index: number } | null {
  for (const [name, profile] of Object.entries(store.speakers)) {
    const index = profile.voiceprints.findIndex((vp) => vp.id === vpId);
    if (index >= 0) {
      return { name, voiceprint: profile.voiceprints[index], index };
    }
  }
  return null;
}

export async function listSpeakers(
  options?: SpeakerCommandOptions,
): Promise<void> {
  // One row per voiceprint: name \t vp-id \t enrolledAt \t source \t dim.
  // `reassign` operates on voiceprint id, so the id has to be visible here.
  // Name repeats across rows when a profile holds multiple voiceprints — the
  // tab format stays grep/awk-friendly without inventing nested formatting.
  const store = await loadProfiles(resolveStorePath(options));
  const entries = Object.entries(store.speakers);
  if (entries.length === 0) {
    process.stderr.write("No speakers enrolled.\n");
    return;
  }
  for (const [name, profile] of entries) {
    if (profile.voiceprints.length === 0) {
      // Defensive: an empty-voiceprint profile shouldn't persist after any
      // CLI mutation, but if one slipped in (manual edit), still surface it
      // so the user can clean up.
      process.stdout.write(`${name}\t\t\t\t0\n`);
      continue;
    }
    for (const vp of profile.voiceprints) {
      const line = [
        name,
        vp.id,
        vp.enrolledAt,
        vp.source,
        String(decodeProfile(vp.profile).length),
      ].join("\t");
      process.stdout.write(`${line}\n`);
    }
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

  // Concat voiceprints, dedup by id so a no-op re-merge (or migration race)
  // can't double-count the same enrollment. Order preserved: dst first,
  // then src — keeps the original dst voiceprints addressable at their
  // existing indices in any UI that displays them.
  const seen = new Set<string>();
  const merged: Voiceprint[] = [];
  for (const vp of [...dstProfile.voiceprints, ...srcProfile.voiceprints]) {
    if (seen.has(vp.id)) continue;
    seen.add(vp.id);
    merged.push(vp);
  }

  store.speakers[dst] = { voiceprints: merged };
  delete store.speakers[src];
  await saveProfiles(store, storePath);
  process.stderr.write(
    `Merged "${src}" into "${dst}" (${merged.length} voiceprint${merged.length === 1 ? "" : "s"}).\n`,
  );
}

export async function reassignVoiceprint(
  vpId: string,
  newName: string,
  options?: SpeakerCommandOptions,
): Promise<void> {
  // Pointer-level fix for the "silent mis-attribute" failure mode: one
  // voiceprint was filed under the wrong name. Move just that voiceprint
  // to the correct name without touching any embeddings.
  const storePath = resolveStorePath(options);
  const store = await loadProfiles(storePath);

  const found = findVoiceprint(store, vpId);
  if (!found) {
    throw new Error(`Voiceprint "${vpId}" not found.`);
  }
  const { name: srcName, voiceprint, index } = found;
  if (srcName === newName) {
    process.stderr.write(
      `Voiceprint "${vpId}" already belongs to "${newName}".\n`,
    );
    return;
  }

  // Remove from source first so a destination-collision throw doesn't leave
  // the store in a partially-mutated state (only relevant if we later add
  // dst-side validation that can throw).
  store.speakers[srcName].voiceprints.splice(index, 1);
  if (store.speakers[srcName].voiceprints.length === 0) {
    // Last voiceprint left the profile — drop the name entirely so `list`
    // doesn't show a ghost profile with zero voiceprints.
    delete store.speakers[srcName];
  }

  const dstProfile = store.speakers[newName];
  if (dstProfile) {
    // Append. If id collides with an existing dst voiceprint (extremely
    // unlikely — ISO timestamp at ms resolution from same instant), skip
    // the move silently to keep dst dedup invariant.
    if (!dstProfile.voiceprints.some((vp) => vp.id === vpId)) {
      dstProfile.voiceprints.push(voiceprint);
    }
  } else {
    store.speakers[newName] = { voiceprints: [voiceprint] };
  }

  await saveProfiles(store, storePath);
  process.stderr.write(
    `Reassigned voiceprint "${vpId}" from "${srcName}" to "${newName}".\n`,
  );
}

export async function showSpeaker(
  name: string,
  options?: SpeakerCommandOptions,
): Promise<void> {
  const store = await loadProfiles(resolveStorePath(options));
  const profile = requireProfile(store, name);
  const view = {
    name,
    voiceprintCount: profile.voiceprints.length,
    voiceprints: profile.voiceprints.map((vp) => ({
      id: vp.id,
      enrolledAt: vp.enrolledAt,
      source: vp.source,
      profileBytes: decodeProfile(vp.profile).length,
    })),
  };
  process.stdout.write(`${JSON.stringify(view, null, 2)}\n`);
}
