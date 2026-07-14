import { existsSync } from "node:fs";

export const SPEAKER_INTEGRATION_FIXTURE_ENV = {
  enroll: "NOTA_SPEAKER_TEST_ENROLL_WAV",
  same: "NOTA_SPEAKER_TEST_SAME_WAV",
  different: "NOTA_SPEAKER_TEST_DIFFERENT_WAV",
} as const;

export type SpeakerIntegrationFixtures = Record<
  keyof typeof SPEAKER_INTEGRATION_FIXTURE_ENV,
  string
>;

export type SpeakerIntegrationGate =
  | { ready: false }
  | { ready: true; fixtures: SpeakerIntegrationFixtures };

export function resolveSpeakerIntegrationFixtures(
  modelPath: string,
  env: NodeJS.ProcessEnv,
  exists: (filePath: string) => boolean = existsSync,
): SpeakerIntegrationGate {
  // The offline path must never inspect fixtures or trigger model resolution.
  if (!exists(modelPath)) return { ready: false };

  const entries = Object.entries(SPEAKER_INTEGRATION_FIXTURE_ENV);
  if (!entries.some(([, variable]) => env[variable] !== undefined)) {
    return { ready: false };
  }

  const missing = entries
    .filter(([, variable]) => !env[variable])
    .map(([, variable]) => variable);
  if (missing.length > 0) {
    throw new Error(
      `Set all ONNX speaker integration fixtures; missing ${missing.join(", ")}`,
    );
  }

  const fixtures = Object.fromEntries(
    entries.map(([role, variable]) => [role, env[variable] as string]),
  ) as SpeakerIntegrationFixtures;
  for (const [role, fixturePath] of Object.entries(fixtures)) {
    if (!exists(fixturePath)) {
      const variable =
        SPEAKER_INTEGRATION_FIXTURE_ENV[
          role as keyof typeof SPEAKER_INTEGRATION_FIXTURE_ENV
        ];
      throw new Error(
        `ONNX speaker integration fixture does not exist: ${variable}=${fixturePath}`,
      );
    }
  }

  return { ready: true, fixtures };
}

export function requireSpeakerIntegrationEmbedding(
  embeddings: Record<string, number[]>,
  label: string,
  role: keyof typeof SPEAKER_INTEGRATION_FIXTURE_ENV,
): number[] {
  const embedding = embeddings[label];
  if (!embedding) {
    throw new Error(
      `${SPEAKER_INTEGRATION_FIXTURE_ENV[role]} produced no embedding; provide a longer speech clip`,
    );
  }
  return embedding;
}
