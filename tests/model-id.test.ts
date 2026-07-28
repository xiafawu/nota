import { describe, expect, it } from "vitest";
import {
  DEFAULT_EXECUTION,
  deriveProvider,
  isExecutionKind,
  isModelProvider,
  namespaceOf,
  resolveExecutionKind,
  wireModelId,
} from "../src/model-id.js";

describe("namespaceOf", () => {
  it("returns the first path segment of a namespaced id", () => {
    expect(namespaceOf("openrouter/anthropic/claude-sonnet-5")).toBe("openrouter");
    expect(namespaceOf("openrouter/z-ai/glm-5.2")).toBe("openrouter");
  });

  it("returns undefined for a flat id", () => {
    expect(namespaceOf("gpt-5-mini")).toBeUndefined();
    expect(namespaceOf("deepseek-v4-flash")).toBeUndefined();
    expect(namespaceOf("universal")).toBeUndefined();
  });

  it("does not treat a leading slash as a namespace", () => {
    // "" is not a provider, and an id that starts with the separator has no
    // first segment to name one.
    expect(namespaceOf("/gpt-5-mini")).toBeUndefined();
  });
});

describe("deriveProvider", () => {
  it("takes the provider from the namespace of a namespaced id", () => {
    expect(deriveProvider("openrouter/anthropic/claude-sonnet-5")).toBe("openrouter");
    expect(deriveProvider("openrouter/meta-llama/llama-4-maverick")).toBe("openrouter");
  });

  it("lets the namespace win over a disagreeing declared provider", () => {
    // The id is the single source of truth (ADR 0001): a stored provider field
    // that contradicts it is the invalid state the design exists to prevent.
    expect(deriveProvider("openrouter/anthropic/claude-sonnet-5", "openai")).toBe(
      "openrouter",
    );
  });

  it("rejects an unknown namespace instead of falling back", () => {
    expect(deriveProvider("bedrock/anthropic/claude-sonnet-5")).toBeUndefined();
    // Even with a perfectly good declared provider: an id naming a provider
    // Nota does not have is not a model Nota can run.
    expect(deriveProvider("bedrock/anthropic/claude", "openai")).toBeUndefined();
  });

  it("keeps the lookup-table derivation for flat ids", () => {
    expect(deriveProvider("gpt-5-mini", "openai")).toBe("openai");
    expect(deriveProvider("gemini-3.6-flash", "gemini")).toBe("gemini");
    expect(deriveProvider("gpt-5-mini")).toBeUndefined();
    expect(deriveProvider("gpt-5-mini", "nonesuch")).toBeUndefined();
  });

  it("knows exactly the five providers", () => {
    for (const p of ["assemblyai", "openai", "gemini", "deepseek", "openrouter"]) {
      expect(isModelProvider(p)).toBe(true);
    }
    expect(isModelProvider("bedrock")).toBe(false);
    expect(isModelProvider(undefined)).toBe(false);
  });
});

describe("wireModelId", () => {
  it("strips the provider namespace, leaving the provider's own slug", () => {
    expect(wireModelId("openrouter/anthropic/claude-sonnet-5")).toBe(
      "anthropic/claude-sonnet-5",
    );
    expect(wireModelId("openrouter/z-ai/glm-5.2")).toBe("z-ai/glm-5.2");
  });

  it("strips exactly one segment — the rest of the path is the vendor's id", () => {
    expect(wireModelId("openrouter/a/b/c")).toBe("a/b/c");
  });

  it("passes flat ids and unknown namespaces through untouched", () => {
    expect(wireModelId("gpt-5-mini")).toBe("gpt-5-mini");
    expect(wireModelId("bedrock/anthropic/claude")).toBe("bedrock/anthropic/claude");
  });
});

describe("execution kind", () => {
  it("defaults to http when unstated", () => {
    expect(DEFAULT_EXECUTION).toBe("http");
    expect(resolveExecutionKind(undefined)).toBe("http");
    expect(resolveExecutionKind(null)).toBe("http");
  });

  it("accepts the two known kinds", () => {
    expect(resolveExecutionKind("http")).toBe("http");
    expect(resolveExecutionKind("cli")).toBe("cli");
    expect(isExecutionKind("cli")).toBe(true);
  });

  it("refuses an unrecognized kind rather than guessing http", () => {
    // A build that does not understand a kind must not assume it is safe to
    // run; callers turn undefined into "drop this entry".
    expect(resolveExecutionKind("wasm")).toBeUndefined();
    expect(resolveExecutionKind(7)).toBeUndefined();
    expect(isExecutionKind("wasm")).toBe(false);
  });
});
