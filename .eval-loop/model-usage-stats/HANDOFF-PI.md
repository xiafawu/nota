# PI Handoff — Wayfinder map "Per-model money/token usage stats"

Self-contained. Assume no prior conversation. You are working ONE ticket of a **wayfinder map** in the Nota repo (`/Users/xiafawu/Developer/Nota`), then stopping.

## What wayfinder is (read first)

A wayfinder map charts the *way* to a destination as a set of decision tickets, worked one at a time. **This map plans a spec; it does NOT build the feature.** You produce a research finding, not code changes to the app.

- The **map**: `.eval-loop/model-usage-stats/map.md` — destination, notes, decisions-so-far, fog, and a ticket table. Read it.
- **Tickets**: `.eval-loop/model-usage-stats/tickets/T*.md`. Each has a `## Question` and a `blocked-by` line.
- **Frontier** = open tickets whose `blocked-by` are all closed. Only frontier tickets are takeable.
- **HARD RULE: resolve at most ONE ticket, then stop.**

## Your scope — research tickets ONLY

You may work **only** these two (both frontier, both AFK research):

- **T2 — Per-call usage capture audit** (`tickets/T2-usage-capture.md`) — PRIMARY. Pure code-reading: audit `src/pipeline/summarize.ts`, `transcribe.ts`, `assemblyai.ts` and the OpenAI/AssemblyAI SDK response types. Document what usage each response exposes. No web needed. Start here.
- **T1 — Model pricing rates** (`tickets/T1-pricing-rates.md`) — ONLY if you have reliable web access for *current* provider pricing. If you can't verify live prices, SKIP T1 and leave it open (don't guess rates).

**Do NOT touch T3, T4, T5, T6.** They are HITL (human-in-the-loop: grilling/prototype) and require the human's live input. An agent that answers its own grilling questions violates the framework. T4/T5/T6 are also blocked.

## Hard constraints

- **No app code changes.** This is a planning map. You read code and write markdown only: the ticket's asset + ticket resolution + a one-line map update. Do not modify `src/**`, `macos/**`, or anything outside `.eval-loop/model-usage-stats/`.
- One ticket, then stop.

## Resolution protocol (local-markdown tracker)

When you finish T2 (repeat for T1 only if you did it):

1. **Claim** (do this first, before work): set `status: in-progress` in the ticket file.
2. **Produce the asset**: write the deliverable named in the ticket — for T2, `.eval-loop/model-usage-stats/capture-map.md` (one row per call site: provider, model, response fields exposed, tokens-in/out available?, duration available?, capture point; flag providers needing estimation fallback).
3. **Resolve the ticket**: append a `## Resolution` section to the ticket file with a tight summary of the answer + a link to the asset. Set `status: closed`.
4. **Update the map** (`map.md`):
   - Add one line under `## Decisions so far`: `- [T2 Per-call usage capture](tickets/T2-usage-capture.md) — <one-line gist>`.
   - In the `## Tickets` table, set T2 status to `closed`.
   - If your findings sharpen a fog item under `## Not yet specified` (e.g. exactly which providers need estimation fallback), you MAY graduate it into a new ticket file + table row — but do not resolve that new ticket.
5. **Stop.** Report what you closed and the asset path. Do not start another ticket.

## Verify

- `capture-map.md` covers all three call sites + names each provider's usage fields.
- Ticket `status: closed`, map `Decisions so far` has the new line, no app source touched (`git status` shows only `.eval-loop/**`).
