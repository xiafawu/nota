import { describe, expect, it, vi } from "vitest";
import {
  requireSpeakerIntegrationEmbedding,
  resolveSpeakerIntegrationFixtures,
} from "./speaker-integration.js";

describe("resolveSpeakerIntegrationFixtures", () => {
  it("skips before inspecting fixtures when the model is absent", () => {
    const exists = vi.fn().mockReturnValue(false);

    expect(
      resolveSpeakerIntegrationFixtures(
        "/models/speaker.onnx",
        { NOTA_SPEAKER_TEST_ENROLL_WAV: "/private/enroll.wav" },
        exists,
      ),
    ).toEqual({ ready: false });
    expect(exists).toHaveBeenCalledOnce();
    expect(exists).toHaveBeenCalledWith("/models/speaker.onnx");
  });

  it("skips when all fixture variables are unconfigured", () => {
    expect(
      resolveSpeakerIntegrationFixtures("/models/speaker.onnx", {}, () => true),
    ).toEqual({ ready: false });
  });

  it("fails actionably when only some fixture variables are configured", () => {
    expect(() =>
      resolveSpeakerIntegrationFixtures(
        "/models/speaker.onnx",
        { NOTA_SPEAKER_TEST_ENROLL_WAV: "/private/enroll.wav" },
        () => true,
      ),
    ).toThrow(
      "Set all ONNX speaker integration fixtures; missing NOTA_SPEAKER_TEST_SAME_WAV, NOTA_SPEAKER_TEST_DIFFERENT_WAV",
    );
  });

  it("fails actionably when a configured fixture path does not exist", () => {
    expect(() =>
      resolveSpeakerIntegrationFixtures(
        "/models/speaker.onnx",
        {
          NOTA_SPEAKER_TEST_ENROLL_WAV: "/private/enroll.wav",
          NOTA_SPEAKER_TEST_SAME_WAV: "/private/missing.wav",
          NOTA_SPEAKER_TEST_DIFFERENT_WAV: "/private/different.wav",
        },
        (filePath) => filePath !== "/private/missing.wav",
      ),
    ).toThrow(
      "ONNX speaker integration fixture does not exist: NOTA_SPEAKER_TEST_SAME_WAV=/private/missing.wav",
    );
  });

  it("returns all fixture paths when the model and fixtures exist", () => {
    expect(
      resolveSpeakerIntegrationFixtures(
        "/models/speaker.onnx",
        {
          NOTA_SPEAKER_TEST_ENROLL_WAV: "/private/enroll.wav",
          NOTA_SPEAKER_TEST_SAME_WAV: "/private/same.wav",
          NOTA_SPEAKER_TEST_DIFFERENT_WAV: "/private/different.wav",
        },
        () => true,
      ),
    ).toEqual({
      ready: true,
      fixtures: {
        enroll: "/private/enroll.wav",
        same: "/private/same.wav",
        different: "/private/different.wav",
      },
    });
  });
});

describe("requireSpeakerIntegrationEmbedding", () => {
  it("fails actionably when an insufficient clip was omitted", () => {
    expect(() =>
      requireSpeakerIntegrationEmbedding({}, "SAME_SPEAKER", "same"),
    ).toThrow(
      "NOTA_SPEAKER_TEST_SAME_WAV produced no embedding; provide a longer speech clip",
    );
  });

  it("returns a computed embedding", () => {
    expect(
      requireSpeakerIntegrationEmbedding(
        { DIFFERENT_SPEAKER: [0.5, -0.5] },
        "DIFFERENT_SPEAKER",
        "different",
      ),
    ).toEqual([0.5, -0.5]);
  });
});
