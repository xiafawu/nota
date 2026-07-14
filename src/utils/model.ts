import { createHash, randomUUID } from "node:crypto";
import { access, mkdir, rename, unlink, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";

export interface ModelSpec {
  name: string;
  url: string;
  sha256: string;
}

export async function resolveModel(spec: ModelSpec): Promise<string> {
  const modelDir = path.join(homedir(), ".nota", "models");
  const targetPath = path.join(modelDir, spec.name);

  try {
    await access(targetPath);
    return targetPath;
  } catch {
    // Download the model when it is not already installed.
  }

  await mkdir(modelDir, { recursive: true });

  let response: Response;
  try {
    response = await fetch(spec.url);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(
      `Failed to download model ${spec.name} from ${spec.url}: ${detail}`,
      { cause: error },
    );
  }
  if (!response.ok) {
    throw new Error(
      `Failed to download model ${spec.name} from ${spec.url}: HTTP ${response.status} ${response.statusText}`,
    );
  }

  let bytes: Buffer;
  try {
    bytes = Buffer.from(await response.arrayBuffer());
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(
      `Failed to download model ${spec.name} from ${spec.url}: ${detail}`,
      { cause: error },
    );
  }
  const tempPath = path.join(modelDir, `.${spec.name}.${randomUUID()}.tmp`);
  let installed = false;

  try {
    await writeFile(tempPath, bytes);

    const actualSha256 = createHash("sha256").update(bytes).digest("hex");
    if (actualSha256 !== spec.sha256.toLowerCase()) {
      throw new Error(
        `Checksum mismatch for model ${spec.name}: expected ${spec.sha256}, got ${actualSha256}`,
      );
    }

    await rename(tempPath, targetPath);
    installed = true;
    return targetPath;
  } finally {
    if (!installed) {
      await unlink(tempPath).catch(() => undefined);
    }
  }
}
