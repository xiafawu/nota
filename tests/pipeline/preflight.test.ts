import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { tmpdir } from "node:os";
import path from "node:path";
import { rm, readFile } from "node:fs/promises";
import {
  classifyError,
  overallOf,
  type PreflightCheck,
  type PreflightResult,
} from "../../src/pipeline/preflight.js";
import { isOutputLimitError, summaryTokenLimit } from "../../src/pipeline/summarize.js";
import {
  readCache,
  writeCache,
  fingerprint,
  CACHE_TTL_MS,
} from "../../src/pipeline/preflight-cache.js";
import type { AppConfig } from "../../src/config.js";

function check(partial: Partial<PreflightCheck>): PreflightCheck {
  return {
    id: "x",
    label: "X",
    status: "ok",
    detail: "",
    blocking: true,
    ...partial,
  };
}

describe("classifyError — red vs yellow", () => {
  it("treats a 4xx HTTP status as deterministic (red)", () => {
    const c = classifyError({ status: 401, message: "invalid key" });
    expect(c.kind).toBe("deterministic");
    expect(c.httpStatus).toBe(401);
  });

  it("treats a 400 as deterministic (red)", () => {
    expect(classifyError({ status: 400, message: "bad param" }).kind).toBe(
      "deterministic",
    );
  });

  it("treats a 5xx as network/unverified (yellow)", () => {
    const c = classifyError({ status: 503, message: "service unavailable" });
    expect(c.kind).toBe("network");
    expect(c.httpStatus).toBe(503);
  });

  it("treats a connection-refused cause as network (yellow)", () => {
    const err = Object.assign(new Error("fetch failed"), {
      cause: { code: "ECONNREFUSED" },
    });
    expect(classifyError(err).kind).toBe("network");
  });

  it("treats an OpenAI APIConnectionError by name as network (yellow)", () => {
    const err = Object.assign(new Error("Connection error."), {
      name: "APIConnectionError",
    });
    expect(classifyError(err).kind).toBe("network");
  });

  it("treats a bare AssemblyAI auth-error string as deterministic (red)", () => {
    // AssemblyAI throws a plain Error with no status; an auth message is a
    // will-not-self-heal failure.
    expect(
      classifyError(new Error("Authentication error, API token missing")).kind,
    ).toBe("deterministic");
  });
});

describe("overallOf", () => {
  it("is blocked when any blocking check fails", () => {
    expect(
      overallOf([check({ status: "ok" }), check({ status: "fail" })]),
    ).toBe("blocked");
  });

  it("is NOT blocked when a non-blocking check fails", () => {
    // an optional row is never blocking; a failing optional should not block
    expect(
      overallOf([check({ status: "ok" }), check({ status: "fail", blocking: false })]),
    ).toBe("ready");
  });

  it("is unverified when a check can't be verified and none hard-fail", () => {
    expect(
      overallOf([check({ status: "ok" }), check({ status: "unverified" })]),
    ).toBe("unverified");
  });

  it("prefers blocked over unverified", () => {
    expect(
      overallOf([
        check({ status: "unverified" }),
        check({ status: "fail" }),
      ]),
    ).toBe("blocked");
  });

  it("is ready when everything is ok or optional", () => {
    expect(
      overallOf([check({ status: "ok" }), check({ status: "optional", blocking: false })]),
    ).toBe("ready");
  });
});

describe("summaryTokenLimit — provider-correct key", () => {
  it("uses max_completion_tokens for OpenAI models", () => {
    expect(summaryTokenLimit("gpt-5-mini", 1)).toEqual({ max_completion_tokens: 1 });
  });
  it("uses max_tokens for Gemini models", () => {
    expect(summaryTokenLimit("gemini-2.5-flash", 4096)).toEqual({ max_tokens: 4096 });
  });
});

describe("isOutputLimitError — truncation is a canary PASS, shape bug is not", () => {
  it("treats an output-limit 400 as truncation (pass)", () => {
    expect(
      isOutputLimitError(
        new Error(
          "400 Could not finish the message because max_tokens or model output limit was reached.",
        ),
      ),
    ).toBe(true);
  });

  it("does NOT treat the unsupported-parameter shape error as truncation", () => {
    expect(
      isOutputLimitError(
        new Error(
          "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.",
        ),
      ),
    ).toBe(false);
  });

  it("does NOT treat an auth error as truncation", () => {
    expect(isOutputLimitError(new Error("Incorrect API key provided"))).toBe(false);
  });
});

describe("preflight cache", () => {
  const cacheFile = path.join(tmpdir(), `nota-pf-cache-${process.pid}.json`);
  const config = {
    provider: "assemblyai",
    transcriptionModel: "universal",
    summaryModel: "gpt-5-mini",
    identify: false,
    diarize: true,
  } as AppConfig;

  function result(overall: PreflightResult["overall"], checkedAt: string): PreflightResult {
    return { overall, checks: [], checkedAt };
  }

  beforeEach(() => {
    process.env.NOTA_PREFLIGHT_CACHE = cacheFile;
  });
  afterEach(async () => {
    delete process.env.NOTA_PREFLIGHT_CACHE;
    await rm(cacheFile, { force: true });
  });

  it("round-trips a fresh ready result", async () => {
    const now = Date.now();
    const r = result("ready", new Date(now).toISOString());
    await writeCache(config, r);
    expect(await readCache(config, now + 1000)).toEqual(r);
  });

  it("misses once the TTL has elapsed", async () => {
    const now = Date.now();
    await writeCache(config, result("ready", new Date(now).toISOString()));
    expect(await readCache(config, now + CACHE_TTL_MS + 1)).toBeNull();
  });

  it("never caches a blocked result", async () => {
    await writeCache(config, result("blocked", new Date().toISOString()));
    // file is cleared to {}, so a read misses
    expect(await readCache(config)).toBeNull();
    expect(await readFile(cacheFile, "utf-8")).toBe("{}");
  });

  it("misses when the model fingerprint changes", async () => {
    const now = Date.now();
    await writeCache(config, result("ready", new Date(now).toISOString()));
    const changed = { ...config, summaryModel: "gpt-4o" } as AppConfig;
    expect(fingerprint(changed)).not.toBe(fingerprint(config));
    expect(await readCache(changed, now + 1000)).toBeNull();
  });
});
