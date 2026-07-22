#!/usr/bin/env node
// Allowlist predicates for the models.dev catalog — "mainline chat only".
// Run: node allowlist.js [path-to-api.json]
const fs = require("fs");
const path = process.argv[2] || "./modelsdev.json";
const catalog = JSON.parse(fs.readFileSync(path, "utf8"));

// ---- structural helpers ---------------------------------------------------
const outputIsTextOnly = (m) => {
  const out = (m.modalities && m.modalities.output) || [];
  return out.length === 1 && out[0] === "text";
};
const inputHas = (m, mod) =>
  ((m.modalities && m.modalities.input) || []).includes(mod);

// A "chat text model": consumes text, emits text-only, can call tools.
// Excludes image generators (output image), realtime/tts (output/inhas audio),
// and embeddings (no tool_call, family text-embedding).
const isChatTextModel = (m) =>
  outputIsTextOnly(m) &&
  !inputHas(m, "audio") &&
  m.tool_call === true;

// ---- OpenAI: gpt-5.x mainline + gpt-5.x-mini ------------------------------
// Structural gate (isChatTextModel) removes image/realtime/embedding.
// id-regex isolates the mainline line within the gpt-5 series: bare
// `gpt-5`, `gpt-5.<minor>`, or the same with a `-mini` suffix. Any other
// suffix (-pro, -nano, -codex, -codex-*, -chat-latest, -sol/-luna/-terra)
// is a non-mainline variant and is rejected.
const OPENAI_MAINLINE = /^gpt-5(\.\d+)?(-mini)?$/;
const openaiAdmit = (m) => isChatTextModel(m) && OPENAI_MAINLINE.test(m.id);

// ---- Google: stable Gemini flash + pro ------------------------------------
// family field cleanly separates the product lines: only `gemini-flash` and
// `gemini-pro` are in scope (drops `gemini-flash-lite`, `gemini` (embedding/
// omni), and `gemma`). Then reject anything not text-out (image/tts/omni),
// any preview or floating `-latest` alias, and anything deprecated.
const googleAdmit = (m) =>
  (m.family === "gemini-flash" || m.family === "gemini-pro") &&
  outputIsTextOnly(m) &&
  !/preview/.test(m.id) &&
  !/latest/.test(m.id) &&
  m.status !== "deprecated";

// ---- DeepSeek: v4+ flash/pro ----------------------------------------------
// The legacy aliases (deepseek-chat / deepseek-reasoner) carry no version
// number; the curated ids are versioned `deepseek-v<N>-<flash|pro>` with N>=4.
// family is ambiguous here (deepseek-v4-pro and legacy deepseek-reasoner are
// both `deepseek-thinking`), so the version pattern in the id is the only
// reliable discriminator.
const DEEPSEEK_VN = /^deepseek-v([4-9]|\d{2,})-(flash|pro)$/;
const deepseekAdmit = (m) => DEEPSEEK_VN.test(m.id);

// ---- run ------------------------------------------------------------------
const PRED = { openai: openaiAdmit, google: googleAdmit, deepseek: deepseekAdmit };
const report = {};
for (const [prov, admit] of Object.entries(PRED)) {
  const models = catalog[prov].models;
  const ids = Object.keys(models).sort();
  const admitted = ids.filter((id) => admit(models[id]));
  const excluded = ids.filter((id) => !admit(models[id]));
  report[prov] = { admitted, excluded };
  console.log(`\n===== ${prov}: ADMITTED (${admitted.length}/${ids.length}) =====`);
  for (const id of admitted) console.log("  + " + id);
}

// ---- near-miss verification -----------------------------------------------
const NEAR_MISS = {
  openai: ["gpt-5.4-pro", "gpt-5.3-chat-latest", "gpt-5-nano", "gpt-5.1-codex",
           "gpt-5.6-sol", "gpt-realtime-2.1"],
  google: ["gemini-3-pro-preview", "gemini-3.1-flash-lite", "gemini-2.0-flash",
           "gemini-flash-latest", "gemini-2.5-flash-image", "gemma-4-31b-it"],
  deepseek: ["deepseek-chat", "deepseek-reasoner"],
};
console.log("\n===== NEAR-MISS CHECK (all must read EXCLUDED) =====");
let ok = true;
for (const [prov, ids] of Object.entries(NEAR_MISS)) {
  for (const id of ids) {
    const m = catalog[prov].models[id];
    const admitted = m ? PRED[prov](m) : null;
    const verdict = m == null ? "ABSENT" : admitted ? "ADMITTED(!)" : "excluded";
    if (admitted) ok = false;
    console.log(`  ${prov}/${id.padEnd(24)} -> ${verdict}`);
  }
}
console.log("\nNEAR-MISS RESULT:", ok ? "PASS (no near-miss admitted)" : "FAIL");
