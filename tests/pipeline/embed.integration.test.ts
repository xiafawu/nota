import { mkdtemp, rm } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import path from "node:path";
import { expect, it } from "vitest";
import {
  computeEmbedding,
  computeEmbeddings,
  cosine,
  MATCH_THRESHOLD,
  MODEL_SPEC,
  TENTATIVE_THRESHOLD,
} from "../../src/pipeline/embed.js";
import {
  loadProfiles,
  matchProfiles,
  saveProfiles,
  type SpeakerStore,
} from "../../src/pipeline/speakers.js";
import { decodePcm } from "../../src/utils/pcm.js";
import {
  requireSpeakerIntegrationEmbedding,
  resolveSpeakerIntegrationFixtures,
} from "../helpers/speaker-integration.js";

const modelPath = path.join(homedir(), ".nota", "models", MODEL_SPEC.name);
const integrationGate = resolveSpeakerIntegrationFixtures(
  modelPath,
  process.env,
);

it.skipIf(!integrationGate.ready)(
  "enrolls speaker A, recognizes a separate A clip, and rejects speaker B",
  async () => {
    if (!integrationGate.ready) {
      throw new Error("ONNX speaker integration test ran without fixtures");
    }
    const fixtures = integrationGate.fixtures;
    const dir = await mkdtemp(path.join(tmpdir(), "nota-onnx-integration-"));

    try {
      const [enrollPcm, samePcm, differentPcm] = await Promise.all([
        decodePcm(fixtures.enroll),
        decodePcm(fixtures.same),
        decodePcm(fixtures.different),
      ]);
      const enrolledEmbedding = Array.from(await computeEmbedding(enrollPcm));
      const storePath = path.join(dir, "speakers.json");
      const store: SpeakerStore = {
        version: 4,
        speakers: {
          Alice: {
            voiceprints: [
              {
                id: "2026-07-13T00:00:00.000Z",
                embedding: enrolledEmbedding,
                enrolledAt: "2026-07-13T00:00:00.000Z",
                source: fixtures.enroll,
              },
            ],
          },
        },
      };
      await saveProfiles(store, storePath);

      const loaded = await loadProfiles(storePath);
      const embeddings = await computeEmbeddings({
        SAME_SPEAKER: samePcm,
        DIFFERENT_SPEAKER: differentPcm,
      });
      const sameEmbedding = requireSpeakerIntegrationEmbedding(
        embeddings,
        "SAME_SPEAKER",
        "same",
      );
      const differentEmbedding = requireSpeakerIntegrationEmbedding(
        embeddings,
        "DIFFERENT_SPEAKER",
        "different",
      );
      const sameMatch = matchProfiles(
        { SAME_SPEAKER: sameEmbedding },
        loaded,
      ).SAME_SPEAKER;
      const differentMatch = matchProfiles(
        { DIFFERENT_SPEAKER: differentEmbedding },
        loaded,
      ).DIFFERENT_SPEAKER;

      expect(sameMatch?.name).toBe("Alice");
      expect(sameMatch?.confidence).toBeGreaterThanOrEqual(MATCH_THRESHOLD);
      expect(sameMatch?.tentative).toBeUndefined();
      expect(differentMatch).toBeUndefined();

      // The absence above must be threshold rejection, not merely a name claimed
      // by the same-speaker label in a joint greedy assignment.
      const differentCosine = cosine(differentEmbedding, enrolledEmbedding);
      expect(differentCosine).toBeLessThan(TENTATIVE_THRESHOLD);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  },
);
