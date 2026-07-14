import { createHash } from "node:crypto";
import {
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { resolveModel } from "../../src/utils/model.js";

describe("resolveModel", () => {
  let home: string;
  let originalHome: string | undefined;

  beforeEach(async () => {
    home = await mkdtemp(path.join(tmpdir(), "nota-model-test-"));
    originalHome = process.env.HOME;
    process.env.HOME = home;
  });

  afterEach(async () => {
    vi.unstubAllGlobals();
    if (originalHome === undefined) delete process.env.HOME;
    else process.env.HOME = originalHome;
    await rm(home, { recursive: true, force: true });
  });

  it("downloads, verifies, and installs a model atomically", async () => {
    const bytes = Buffer.from("valid ONNX bytes");
    const sha256 = createHash("sha256").update(bytes).digest("hex");
    const fetchMock = vi
      .fn()
      .mockResolvedValue(new Response(bytes, { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    const resolved = await resolveModel({
      name: "speaker.onnx",
      url: "https://models.example/speaker.onnx",
      sha256,
    });

    expect(resolved).toBe(path.join(home, ".nota", "models", "speaker.onnx"));
    expect(await readFile(resolved)).toEqual(bytes);
    expect(fetchMock).toHaveBeenCalledOnce();
    expect(fetchMock).toHaveBeenCalledWith(
      "https://models.example/speaker.onnx",
    );
    expect(await readdir(path.dirname(resolved))).toEqual(["speaker.onnx"]);
  });

  it("returns an existing model without fetching it again", async () => {
    const target = path.join(home, ".nota", "models", "speaker.onnx");
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, "already installed");
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    await expect(
      resolveModel({
        name: "speaker.onnx",
        url: "https://models.example/speaker.onnx",
        sha256: "0".repeat(64),
      }),
    ).resolves.toBe(target);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("rejects a checksum mismatch without leaving a partial file", async () => {
    const bytes = Buffer.from("corrupt model bytes");
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(new Response(bytes, { status: 200 })),
    );

    await expect(
      resolveModel({
        name: "speaker.onnx",
        url: "https://models.example/speaker.onnx",
        sha256: "0".repeat(64),
      }),
    ).rejects.toThrow(/checksum mismatch/i);

    const modelDir = path.join(home, ".nota", "models");
    expect(await readdir(modelDir)).toEqual([]);
  });

  it("adds actionable context to network failures without leaving a partial file", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockRejectedValue(new Error("socket closed")),
    );

    await expect(
      resolveModel({
        name: "speaker.onnx",
        url: "https://models.example/speaker.onnx",
        sha256: "0".repeat(64),
      }),
    ).rejects.toThrow(
      "Failed to download model speaker.onnx from https://models.example/speaker.onnx: socket closed",
    );

    const modelDir = path.join(home, ".nota", "models");
    expect(await readdir(modelDir)).toEqual([]);
  });

  it("adds actionable context when reading the response body fails", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        statusText: "OK",
        arrayBuffer: vi.fn().mockRejectedValue(new Error("body interrupted")),
      }),
    );

    await expect(
      resolveModel({
        name: "speaker.onnx",
        url: "https://models.example/speaker.onnx",
        sha256: "0".repeat(64),
      }),
    ).rejects.toThrow(
      "Failed to download model speaker.onnx from https://models.example/speaker.onnx: body interrupted",
    );

    const modelDir = path.join(home, ".nota", "models");
    expect(await readdir(modelDir)).toEqual([]);
  });
});
