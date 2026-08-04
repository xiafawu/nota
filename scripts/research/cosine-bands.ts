#!/usr/bin/env tsx
/**
 * XIA-407 — voiceprint cosine-band measurement (research, read-only).
 *
 * Measures the real cosine-similarity distributions of the speaker-identity
 * pipeline on the owner's enrolled data:
 *
 *   - every enrolled voiceprint in `~/.nota/speakers.json` (schema v4),
 *   - every per-speaker clip under `~/.nota/history/*.assets/*.pcm` (raw
 *     s16le, 16 kHz mono — exactly what `writeSpeakerClip` persists),
 *
 * and reports intra-speaker vs inter-speaker distributions, the enrolled↔
 * enrolled distribution, every pair that lands in the tentative band
 * [0.5, 0.65), and a clip-duration sensitivity table. It changes nothing:
 * the store, clips, and model cache are only read.
 *
 * Run: npx tsx scripts/research/cosine-bands.ts
 */

import { readFile, readdir, stat } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import {
  computeEmbedding,
  cosine,
  MATCH_THRESHOLD,
  TENTATIVE_THRESHOLD,
} from "../../src/pipeline/embed.js";
import { loadProfiles } from "../../src/pipeline/speakers.js";

const HISTORY_DIR = path.join(os.homedir(), ".nota", "history");
/** A still-diarized label: `Speaker N`. Anything else is a person name. */
const DIARIZED_LABEL = /^Speaker \d+$/;
/** Full clip duration cap for the duration-sensitivity sweep. */
const PREFIX_SECONDS = [5, 10, 15, 20];

interface EnrolledVp {
  name: string;
  id: string;
  embedding: number[];
}

interface Clip {
  recordId: string;
  label: string;
  /** Ground-truth person when determinable from the record; null otherwise. */
  person: string | null;
  clipPath: string;
  seconds: number;
}

async function loadEnrolled(): Promise<EnrolledVp[]> {
  const store = await loadProfiles();
  const vps: EnrolledVp[] = [];
  for (const [name, profile] of Object.entries(store.speakers)) {
    for (const vp of profile.voiceprints) {
      vps.push({ name, id: vp.id, embedding: vp.embedding });
    }
  }
  return vps;
}

/**
 * Reconstruct each clip's ground-truth person from the record, when the
 * record alone determines it:
 *
 *   - a clip keyed by a person name was renamed by `renameRecordSpeaker`
 *     (segments AND clip moved) → person = that name;
 *   - a diarized clip key still present in `segments[].speaker` was never
 *     resolved → person = null;
 *   - a diarized clip key absent from `segments` was resolved to exactly one
 *     remaining person name (all other names are already claimed by renamed
 *     clips) → person = that name;
 *   - otherwise the original label→name map is lost → person = null
 *     (conservative: the clip is still compared against every enrolled
 *     voiceprint, but only as an inter-speaker sample).
 */
function mapClipsToPersons(
  record: { id: string; speakerClips?: Record<string, string> },
  segments: Array<{ speaker?: string | null }>,
): Array<{ label: string; person: string | null }> {
  const clipLabels = Object.keys(record.speakerClips ?? {});
  if (clipLabels.length === 0) return [];

  const segLabels = new Set(
    segments.map((s) => s.speaker).filter((s): s is string => !!s),
  );
  const resolvedNames = [...segLabels].filter((l) => !DIARIZED_LABEL.test(l));
  const claimedByRenamed = clipLabels.filter((l) => !DIARIZED_LABEL.test(l));
  const remaining = resolvedNames.filter((n) => !claimedByRenamed.includes(n));

  return clipLabels.map((label) => {
    if (!DIARIZED_LABEL.test(label)) return { label, person: label };
    if (segLabels.has(label)) return { label, person: null };
    if (remaining.length === 1) return { label, person: remaining[0] };
    return { label, person: null };
  });
}

/** Decode a stored clip: raw little-endian s16 PCM at 16 kHz mono. */
function decodeClipPcm(buf: Buffer): Int16Array {
  const samples = Math.floor(buf.length / 2);
  const out = new Int16Array(samples);
  for (let i = 0; i < samples; i++) out[i] = buf.readInt16LE(i * 2);
  return out;
}

function quantiles(sorted: number[]): {
  n: number;
  min: number;
  p25: number;
  median: number;
  p75: number;
  p90: number;
  max: number;
  mean: number;
} {
  const n = sorted.length;
  const at = (p: number): number => {
    const idx = Math.min(n - 1, Math.max(0, Math.floor(p * n)));
    return sorted[idx];
  };
  const mean = sorted.reduce((a, b) => a + b, 0) / n;
  return {
    n,
    min: at(0),
    p25: at(0.25),
    median: at(0.5),
    p75: at(0.75),
    p90: at(0.9),
    max: at(n - 1),
    mean,
  };
}

/** Fixed 0.05-wide buckets over [0, 1] so distributions compare directly. */
function histogram(values: number[], label: string): void {
  if (values.length === 0) {
    console.log(`\n${label} — no samples`);
    return;
  }
  const bucket = 0.05;
  const counts = new Map<number, number>();
  for (const v of values) {
    const b = Math.min(0.95, Math.floor(v / bucket) * bucket);
    counts.set(b, (counts.get(b) ?? 0) + 1);
  }
  const max = Math.max(...counts.values());
  const width = 36;
  console.log(`\n${label} (n=${values.length})`);
  for (const [b, count] of [...counts.entries()].sort((x, y) => x[0] - y[0])) {
    const bar = "#".repeat(Math.round((count / max) * width));
    console.log(`  [${b.toFixed(2)}, ${(b + bucket).toFixed(2)}) ${bar} ${count}`);
  }
}

function printStats(sorted: number[], indent = "  "): void {
  const q = quantiles(sorted);
  console.log(
    `${indent}min=${q.min.toFixed(3)} p25=${q.p25.toFixed(3)} median=${q.median.toFixed(3)} ` +
      `mean=${q.mean.toFixed(3)} p75=${q.p75.toFixed(3)} p90=${q.p90.toFixed(3)} max=${q.max.toFixed(3)}`,
  );
}

async function main(): Promise<void> {
  console.log("=== Voiceprint cosine-band measurement (XIA-407) ===");
  console.log(
    `Thresholds (from src/pipeline/embed.ts): MATCH=${MATCH_THRESHOLD.toFixed(2)} ` +
      `TENTATIVE=${TENTATIVE_THRESHOLD.toFixed(2)}`,
  );

  // ---- Data inventory ------------------------------------------------------
  const enrolled = await loadEnrolled();
  console.log(`\nEnrolled voiceprints: ${enrolled.length} (schema v4)`);
  const byName = new Map<string, EnrolledVp[]>();
  for (const vp of enrolled) {
    byName.set(vp.name, [...(byName.get(vp.name) ?? []), vp]);
  }
  for (const [name, vps] of [...byName.entries()].sort()) {
    console.log(`  ${name}: ${vps.length} voiceprint(s)`);
  }

  const historyFiles = (await readdir(HISTORY_DIR)).filter((f) => f.endsWith(".json"));
  const clips: Clip[] = [];
  let unreadable = 0;
  for (const file of historyFiles.sort()) {
    const recordId = file.replace(/\.json$/, "");
    let record: { speakerClips?: Record<string, string> } & { segments: Array<{ speaker?: string | null }> };
    try {
      record = JSON.parse(await readFile(path.join(HISTORY_DIR, file), "utf-8"));
    } catch (error) {
      console.warn(`  [warn] unreadable history record ${file}: ${(error as Error).message}`);
      unreadable += 1;
      continue;
    }
    const mapped = mapClipsToPersons(record, record.segments ?? []);
    for (const { label, person } of mapped) {
      const clipPath = path.join(HISTORY_DIR, `${recordId}.assets`, `${label}.pcm`);
      try {
        const clipStat = await stat(clipPath);
        clips.push({
          recordId,
          label,
          person,
          clipPath,
          seconds: Math.floor(clipStat.size / 2 / 16000),
        });
      } catch {
        unreadable += 1;
        console.warn(`  [warn] missing clip ${recordId}.assets/${label}.pcm`);
      }
    }
  }
  const labeled = clips.filter((c) => c.person !== null);
  console.log(
    `History records scanned: ${historyFiles.length} | clips found: ${clips.length} ` +
      `(ground-truth person determinable: ${labeled.length}, unlabeled: ${clips.length - labeled.length}) ` +
      `| unreadable: ${unreadable}`,
  );
  for (const c of clips) {
    console.log(
      `  ${c.recordId} ${c.label} (${c.seconds}s) → ${c.person ?? "unlabeled"}`,
    );
  }

  if (enrolled.length === 0 || clips.length === 0) {
    console.log("\nNothing to compare (no enrolled voiceprints or no clips). Exiting 0.");
    return;
  }

  // ---- Embed all clips ------------------------------------------------------
  const embedded = new Map<string, number[]>(); // clipPath -> embedding
  let embedFailures = 0;
  for (const clip of clips) {
    try {
      const buf = await readFile(clip.clipPath);
      const pcm = decodeClipPcm(buf);
      embedded.set(clip.clipPath, Array.from(await computeEmbedding(pcm)));
    } catch (error) {
      embedFailures += 1;
      console.warn(
        `  [warn] skipping ${clip.recordId}/${clip.label}: ${(error as Error).message}`,
      );
    }
  }
  const embeddedClips = clips.filter((c) => embedded.has(c.clipPath));
  console.log(`\nEmbedded clips: ${embeddedClips.length} (failures: ${embedFailures})`);

  // ---- Clip × enrolled-voiceprint similarities -------------------------------
  interface Pair {
    clip: Clip;
    vpName: string;
    vpId: string;
    score: number;
    kind: "intra" | "inter" | "unlabeled";
  }
  const pairs: Pair[] = [];
  for (const clip of embeddedClips) {
    const emb = embedded.get(clip.clipPath)!;
    for (const vp of enrolled) {
      const score = cosine(emb, vp.embedding);
      const kind = clip.person === null ? "unlabeled" : clip.person === vp.name ? "intra" : "inter";
      pairs.push({ clip, vpName: vp.name, vpId: vp.id, score, kind });
    }
  }
  const intra = pairs.filter((p) => p.kind === "intra").map((p) => p.score).sort((a, b) => a - b);
  const inter = pairs
    .filter((p) => p.kind === "inter" || p.kind === "unlabeled")
    .map((p) => p.score)
    .sort((a, b) => a - b);

  console.log("\n=== Distribution 1: clip vs enrolled voiceprint (intra-speaker) ===");
  printStats(intra);
  histogram(intra, "Intra-speaker cosine (clip of person X vs X's voiceprints)");

  console.log("\n=== Distribution 2: clip vs enrolled voiceprint (inter-speaker) ===");
  printStats(inter);
  histogram(
    inter,
    "Inter-speaker cosine (clip vs other people's voiceprints; unlabeled clips counted here)",
  );

  // ---- Enrolled × enrolled ----------------------------------------------------
  const vpPairs: Array<{ a: string; aId: string; b: string; bId: string; score: number; same: boolean }> = [];
  for (let i = 0; i < enrolled.length; i++) {
    for (let j = i + 1; j < enrolled.length; j++) {
      const a = enrolled[i];
      const b = enrolled[j];
      vpPairs.push({
        a: a.name,
        aId: a.id,
        b: b.name,
        bId: b.id,
        score: cosine(a.embedding, b.embedding),
        same: a.name === b.name,
      });
    }
  }
  vpPairs.sort((x, y) => x.score - y.score);
  const vpSame = vpPairs.filter((p) => p.same).map((p) => p.score);
  const vpCross = vpPairs.filter((p) => !p.same).map((p) => p.score);

  console.log("\n=== Distribution 3: enrolled × enrolled voiceprints ===");
  console.log(`  intra-name pairs: ${vpSame.length}, cross-name pairs: ${vpCross.length}`);
  if (vpSame.length) printStats(vpSame);
  if (vpCross.length) printStats(vpCross);
  histogram(vpSame, "Enrolled↔enrolled, same person (re-enrollment stability)");
  histogram(vpCross, "Enrolled↔enrolled, different people");
  for (const p of vpPairs) {
    console.log(
      `  ${p.a} (${p.aId.slice(0, 10)}…) vs ${p.b} (${p.bId.slice(0, 10)}…) = ${p.score.toFixed(3)} ${p.same ? "[same-name]" : ""}`,
    );
  }

  // ---- Tentative band -----------------------------------------------------------
  const inBand = pairs
    .filter((p) => p.score >= TENTATIVE_THRESHOLD && p.score < MATCH_THRESHOLD)
    .sort((x, y) => x.score - y.score);
  console.log(`\n=== Every pair in the tentative band [${TENTATIVE_THRESHOLD.toFixed(2)}, ${MATCH_THRESHOLD.toFixed(2)}) ===`);
  if (inBand.length === 0) console.log("  (none)");
  for (const p of inBand) {
    console.log(
      `  ${p.clip.recordId} ${p.clip.label} (${p.clip.person ?? "unlabeled"}) vs ${p.vpName} ` +
        `${p.vpId.slice(0, 10)}… = ${p.score.toFixed(3)} [${p.kind}]`,
    );
  }

  // ---- Inter pairs at/above MATCH (suspected mislabeled intra) ----------------------
  const interHigh = pairs
    .filter((p) => (p.kind === "inter" || p.kind === "unlabeled") && p.score >= MATCH_THRESHOLD)
    .sort((x, y) => y.score - x.score);
  console.log(
    `\n=== Inter/unlabeled pairs at/above MATCH (${interHigh.length}; near-certainly intra-in-truth) ===`,
  );
  for (const p of interHigh) {
    console.log(
      `  ${p.clip.recordId} ${p.clip.label} (${p.clip.person ?? "unlabeled"}) vs ${p.vpName} = ${p.score.toFixed(3)}`,
    );
  }

  // ---- Clip×clip near-duplicates (same audio persisted across records) -------------
  console.log("\n=== Clip × clip near-duplicates (cosine ≥ 0.995) ===");
  const clipList = embeddedClips.map((c) => ({ clip: c, emb: embedded.get(c.clipPath)! }));
  const dupClusters: string[][] = [];
  for (let i = 0; i < clipList.length; i++) {
    for (let j = i + 1; j < clipList.length; j++) {
      const s = cosine(clipList[i].emb, clipList[j].emb);
      if (s >= 0.995) {
        const a = `${clipList[i].clip.recordId}/${clipList[i].clip.label}`;
        const b = `${clipList[j].clip.recordId}/${clipList[j].clip.label}`;
        const hit = dupClusters.find((c) => c.includes(a) || c.includes(b));
        if (hit) {
          if (!hit.includes(b)) hit.push(b);
        } else {
          dupClusters.push([a, b]);
        }
        console.log(`  ${a} ≡ ${b} (${s.toFixed(4)})`);
      }
    }
  }
  if (dupClusters.length === 0) console.log("  (none)");
  console.log(`  near-duplicate clusters: ${dupClusters.length}`);

  // ---- Band-separation summary ----------------------------------------------------
  const minIntra = intra.length ? intra[0] : NaN;
  const maxInter = inter.length ? inter[inter.length - 1] : NaN;
  console.log("\n=== Band separation (clip × enrolled) ===");
  console.log(
    `  min intra = ${Number.isNaN(minIntra) ? "—" : minIntra.toFixed(3)} | max inter (incl. unlabeled) = ${Number.isNaN(maxInter) ? "—" : maxInter.toFixed(3)}`,
  );
  const intraBelowMatch = intra.filter((s) => s < MATCH_THRESHOLD).length;
  const intraBelowTent = intra.filter((s) => s < TENTATIVE_THRESHOLD).length;
  const interAboveMatch = inter.filter((s) => s >= MATCH_THRESHOLD).length;
  const interAboveTent = inter.filter((s) => s >= TENTATIVE_THRESHOLD).length;
  console.log(
    `  intra pairs below MATCH: ${intraBelowMatch}/${intra.length} | below TENTATIVE: ${intraBelowTent}/${intra.length}`,
  );
  console.log(
    `  inter pairs at/above MATCH: ${interAboveMatch}/${inter.length} | at/above TENTATIVE: ${interAboveTent}/${inter.length}`,
  );

  // ---- Top-1 classification on determinable clips ------------------------------------
  const top1Correct: Array<{ clip: Clip; best: string; score: number; correct: boolean }> = [];
  for (const clip of embeddedClips) {
    if (clip.person === null) continue;
    const emb = embedded.get(clip.clipPath)!;
    let bestName = "";
    let bestScore = -Infinity;
    for (const vp of enrolled) {
      const s = cosine(emb, vp.embedding);
      if (s > bestScore) {
        bestScore = s;
        bestName = vp.name;
      }
    }
    top1Correct.push({
      clip,
      best: bestName,
      score: bestScore,
      correct: bestName === clip.person,
    });
  }
  const nCorrect = top1Correct.filter((t) => t.correct).length;
  console.log("\n=== Top-1 acoustic name on determinable clips ===");
  console.log(`  correct: ${nCorrect}/${top1Correct.length}`);
  for (const t of top1Correct) {
    console.log(
      `  ${t.clip.recordId} ${t.clip.label} truth=${t.clip.person} top1=${t.best} (${t.score.toFixed(3)}) ${t.correct ? "✓" : "✗"}`,
    );
  }

  // ---- Duration sensitivity ----------------------------------------------------------
  console.log("\n=== Duration sensitivity (determinable intra clips only) ===");
  const byLen = new Map<number, number[]>();
  for (const clip of embeddedClips) {
    if (clip.person === null) continue;
    const targetVps = byName.get(clip.person) ?? [];
    if (targetVps.length === 0) continue;
    const full = embedded.get(clip.clipPath)!;
    const fullBest = Math.max(...targetVps.map((vp) => cosine(full, vp.embedding)));
    const rows: string[] = [`${clip.recordId}/${clip.label} truth=${clip.person}`];
    const buf = await readFile(clip.clipPath);
    const pcm = decodeClipPcm(buf);
    for (const seconds of PREFIX_SECONDS.filter((s) => s < clip.seconds)) {
      const prefix = pcm.subarray(0, seconds * 16000);
      let score: number | null = null;
      try {
        const emb = Array.from(await computeEmbedding(prefix));
        score = Math.max(...targetVps.map((vp) => cosine(emb, vp.embedding)));
        byLen.set(seconds, [...(byLen.get(seconds) ?? []), score]);
      } catch {
        // Too little speech in the prefix — keep the row blank.
      }
      rows.push(`${seconds}s=${score === null ? "—" : score.toFixed(3)}`);
    }
    console.log(`  ${rows.join(" | ")} | full=${fullBest.toFixed(3)}`);
  }
  console.log("  mean similarity by prefix length:");
  for (const seconds of PREFIX_SECONDS) {
    const vals = byLen.get(seconds) ?? [];
    if (vals.length === 0) continue;
    const mean = vals.reduce((a, b) => a + b, 0) / vals.length;
    console.log(
      `    ${String(seconds).padStart(2)}s: ${vals.length} clips, mean=${mean.toFixed(3)} ` +
        `(min=${Math.min(...vals).toFixed(3)}, max=${Math.max(...vals).toFixed(3)})`,
    );
  }

  console.log("\n=== Done (read-only sweep; nothing written) ===");
}

main().catch((error) => {
  console.error(`cosine-bands failed: ${(error as Error).stack ?? error}`);
  process.exit(1);
});
