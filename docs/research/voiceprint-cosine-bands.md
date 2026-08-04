# Voiceprint cosine bands on real data (XIA-407)

Measured on 2026-08-04 with `npx tsx scripts/research/cosine-bands.ts` against
the owner's live store (`~/.nota`). Read-only: no store, clip, or model writes.

## Verdict (for the map reader)

**Keep MATCH = 0.65 and TENTATIVE = 0.50.** No threshold movement and no
per-speaker bands are justified by this data, and neither would have fixed the
incident that motivated this ticket. The measurement shows:

- **The confident band has never produced a false positive in this dataset.**
  Every clip↔voiceprint pair at/above 0.65 that is not already labeled
  intra-speaker is a same-audio or same-person artifact (identical clips
  persisted across history records, or a clip that was the source of the
  voiceprint it matched at 1.000). The true inter-speaker ceiling is **0.371**
  (enrolled↔enrolled cross-name), leaving 0.28 of margin below 0.65.
- **Real matches live in the tentative band.** The motivating near-miss is
  reproduced exactly: Kenny Kim's 2026-08-03 meeting audio scores **0.623**
  against his own 2026-07-17 voiceprint — intra-speaker, in `[0.5, 0.65)`,
  and it was silently dropped in no-TTY runs. One intra pair even sits below
  the tentative floor (0.434 vs the 07-14 voiceprint).
- **The failure mode is enrollment-condition variance, not band placement.**
  Same-name enrolled↔enrolled cosines span **0.025 → 0.623**: Brian's two
  enrollments agree at 0.025 (one is effectively garbage), Kenny's three
  pairwise agree at 0.434 / 0.528 / 0.623 (cross-session channel drift).
  No choice of thresholds fixes a 0.434 same-person score; per-speaker bands
  are unestimable with 1–3 voiceprints per person, and they would bake the
  variance in instead of removing it.

Concrete implications for the UX trust levels (XIA-408/XIA-411 consume this):

| Band | What the data says lives here | UX treatment |
| --- | --- | --- |
| ≥ 0.65 (confident) | Correct matches only (0/14 false positives; 7/9 intra ≥ 0.65) | Auto-label, no prompt |
| [0.50, 0.65) (tentative) | Correct-but-weak matches (Kenny 0.623) — **no cross-name pair observed** | Must surface for confirmation; never silently drop |
| < 0.50 | Inter-speaker noise, plus intra against stale/bad voiceprints (0.434) | Unmatched; re-enroll path |

The durable fixes are (a) an **enrollment-consistency gate** — warn or reject
a new voiceprint that scores < ~0.5 against an existing same-name voiceprint
(flags Brian's 0.025 and Kenny's 0.434/0.528 additions), and (b) **surfacing
tentative matches** instead of dropping them, which is where the 0.623 case
was lost. `max`-over-voiceprints already mitigates: today the same Kenny clip
scores 1.000 against his 08-03 voiceprint and would be confident — the
incident happened because that voiceprint did not exist yet.

If a reader still wants to move the bands: **MATCH = 0.60** would have caught
the 0.623 case with 0.23 of margin over the observed inter ceiling (0.371),
but n = 9 intra pairs makes that unsafe, and the 0.434 case fails under any
sane floor. Do not move; fix enrollment quality and the tentative path.

## Methodology

**What was compared.** Every enrolled schema-v4 voiceprint (n = 6) from
`~/.nota/speakers.json` × every stored per-speaker clip (n = 21) from
`~/.nota/history/*.assets/*.pcm`, plus all voiceprint↔voiceprint pairs
(n = 15). Clips are the exact 16 kHz mono s16le buffers `writeSpeakerClip`
persists; embeddings reuse `computeEmbedding`/`cosine` from
`src/pipeline/embed.ts` (WeSpeaker ResNet34-LM, L2-normalized). Thresholds
read from the same module the pipeline uses (0.65 / 0.50).

**Ground truth.** A clip's person is determinable from its history record
when (1) the clip key is a person name (renamed by `renameRecordSpeaker`),
(2) the diarized label still appears in `segments[].speaker` (never resolved),
or (3) exactly one resolved segment name remains unclaimed after renamed
clips are accounted for. 7 of 21 clips are determinable (6 Freya Wu, 1 Kenny
Kim; 0 Brian Demsky); the other 14 stay **unlabeled** and are compared against
all voiceprints but counted in the inter distribution only. No clip was
unreadable or unembeddable (0/21 failures).

**Exclusions / artifacts.** Three history records from 2026-07-14
(17:57/17:59/19:09) are the same recording persisted three times — their six
clips are pairwise identical (cosine 1.0000) and appear 3× in every
distribution. The 18:53 and 20:04 records of 2026-08-03 are the same
recording processed twice (their clips are pairwise identical); in the 18:53
run the Kenny clip was renamed and enrolled, in the 20:04 run it stayed a
diarized label. The report keeps all clips and calls out the inflation.

## Distributions

### 1. Clip × enrolled voiceprint — intra-speaker (n = 9, 7 unique clips)

```
min=0.434 p25=0.724 median=0.822 mean=0.767 p75=0.836 p90=1.000 max=1.000
  [0.40, 0.45) ######### 1     ← Kenny clip vs Kenny 07-14 voiceprint
  [0.60, 0.65) ######### 1     ← Kenny clip vs Kenny 07-17 voiceprint = 0.623
  [0.70, 0.75) ######### 1     ← Freya (07-18 meeting)
  [0.75, 0.80) ######### 1     ← Freya (07-17 meeting)
  [0.80, 0.85) #################################### 4   ← Freya (3× identical 07-14 audio + 08-03)
  [0.95, 1.00) ######### 1     ← Kenny clip vs Kenny 08-03 voiceprint (same audio)
```

2 of 9 intra pairs fall below MATCH (0.623, 0.434); 1 of 9 falls below
TENTATIVE (0.434). Both are Kenny vs his older voiceprints.

### 2. Clip × enrolled voiceprint — inter-speaker (n = 117; unlabeled clips included)

```
min=-0.176 p25=0.076 median=0.146 mean=0.247 p75=0.380 p90=0.814 max=1.000
  [-0.20, -0.15) ######## 6
  [-0.15, -0.10) ####### 5
  [-0.10, -0.05) # 1
  [-0.05, 0.00) # 1
  [0.00, 0.05) ############ 9
  [0.05, 0.10) #################### 15
  [0.10, 0.15) #################################### 27
  [0.15, 0.20) ##### 4
  [0.20, 0.25) ############# 10
  [0.25, 0.30) ### 2
  [0.30, 0.35) #### 3
  [0.35, 0.40) ########### 8
  [0.40, 0.45) ######## 6
  [0.50, 0.55) ##### 4
  [0.60, 0.65) ### 2
  [0.70, 0.75) # 1
  [0.80, 0.85) ######## 6
  [0.85, 0.90) # 1
  [0.95, 1.00) ######## 6
```

**This distribution is polluted and must not be read as "inter-speaker".**
All 14 pairs at/above 0.65 are same-person artifacts: 1.000-scoring pairs are
clips that are the enrollment source of the voiceprint they match (Kenny
07-14 test calls vs Kenny 07-14 enrollment; Kenny 07-17 clip vs Kenny 07-17
enrollment; Brian 07-18 clip vs Brian enrollment; the duplicated 08-03 audio
vs Kenny 08-03 enrollment), and the 0.80–0.85 pairs are unlabeled clips of
two-person meetings matching one of the two named speakers (e.g. 07-22
record: "Speaker 2" matches Freya at 0.840, "Speaker 1" matches Brian at
0.809). The single candidate true cross-speaker pair above 0.65 is the 5 s
test clip "Okay, this is a test for nota app." matching Freya at 0.715 —
almost certainly the owner testing her own app. The honest inter ceiling is
distribution 3's cross-name number, **0.371**.

### 3. Enrolled × enrolled (n = 15)

Same name (re-enrollment stability), n = 4:

```
min=0.025 p25=0.434 median=0.528 mean=0.403 p75=0.623 p90=0.623 max=0.623
  Brian Demsky (07-14) vs Brian Demsky (07-21) = 0.025   ← one enrollment is garbage
  Kenny Kim    (07-14) vs Kenny Kim    (08-03) = 0.434
  Kenny Kim    (07-14) vs Kenny Kim    (07-17) = 0.528
  Kenny Kim    (07-17) vs Kenny Kim    (08-03) = 0.623   ← the same 0.623 that was dropped
```

Different people, n = 11:

```
min=-0.125 p25=0.070 median=0.105 mean=0.117 p75=0.154 p90=0.238 max=0.371
  full pair list: -0.125, 0.010, 0.070, 0.089, 0.093, 0.105, 0.140, 0.146, 0.154, 0.238, 0.371
```

Same-person enrollment spread (0.025–0.623) is 17× the cross-person spread
(≤ 0.371). Speaker confusability is not the problem; enrollment-condition
variance is. Kenny's three sessions agree with each other at tentative-band
or below — yet each of his voiceprints matches its own source clip at 1.000.

### Where 0.623 sits

Three distinct pairs land at 0.623, all same-person:
1. Kenny clip (08-03 meeting, renamed record) vs Kenny 07-17 voiceprint —
   **intra, the motivating incident**;
2. the same 08-03 audio under its diarized label (20:04 re-run record) vs
   Kenny 07-17 voiceprint;
3. Kenny 07-17 voiceprint vs Kenny 08-03 voiceprint (enrolled↔enrolled).

## Tentative band [0.50, 0.65): every pair

```
20260714-175752Z Speaker 1 (unlabeled) vs Kenny Kim 07-17 = 0.528   (identical ×3 records)
20260717-004104Z Speaker 2 (unlabeled) vs Kenny Kim 07-14 = 0.528
20260717-004104Z Speaker 2 (unlabeled) vs Kenny Kim 08-03 = 0.623
20260803-185339Z Kenny Kim (Kenny Kim) vs Kenny Kim 07-17 = 0.623  [intra — the incident]
20260803-200454Z Speaker 2 (unlabeled) vs Kenny Kim 07-17 = 0.623
```

Every occupant is a Kenny-vs-Kenny pair against a stale voiceprint. No
cross-name pair has ever been observed in this band.

## Sensitivity to clip duration

Determinable intra clips only, embedded again from 5/10/15/20 s prefixes and
scored against the ground-truth person's best voiceprint:

```
                               5s     10s    15s    20s    full
Freya 07-14 (identical ×3)    0.729  0.807  0.815  0.831  0.836
Freya 07-17                    0.706  0.770  0.785  0.788  0.793
Freya 07-18                    0.682  0.663  0.710  0.724  0.724
Freya 08-03                    0.645  0.776  0.785  0.817  0.822
Kenny 08-03 (enrollment audio) 0.830  0.909  0.947  0.978  1.000
mean (n=7)                     0.722  0.792  0.810  0.829  —
```

Monotone improvement with duration (mean +0.107 from 5 s to 20 s; largest
jump 5→10 s, +0.070). Even 5 s prefixes of Freya's clips stay ≥ 0.645 — above
tentative, close to confident — while the same-prefix Kenny clip is already
confident. Short clips are not the accuracy risk here; enrollment quality is.

## Appendix — real script output

Full output of `npx tsx scripts/research/cosine-bands.ts` (2026-08-04), exit 0:

```
=== Voiceprint cosine-band measurement (XIA-407) ===
Thresholds (from src/pipeline/embed.ts): MATCH=0.65 TENTATIVE=0.50
Enrolled voiceprints: 6 (schema v4)
  Brian Demsky: 2 voiceprint(s)
  Freya Wu: 1 voiceprint(s)
  Kenny Kim: 3 voiceprint(s)
History records scanned: 32 | clips found: 21 (ground-truth person determinable: 7, unlabeled: 14) | unreadable: 0
  20260714-175752Z-4792cb33 Speaker 1 (24s) → unlabeled
  20260714-175752Z-4792cb33 Speaker 2 (24s) → Freya Wu
  20260714-175935Z-0626ff9f Speaker 1 (24s) → unlabeled
  20260714-175935Z-0626ff9f Speaker 2 (24s) → Freya Wu
  20260714-190916Z-51e32386 Speaker 1 (24s) → unlabeled
  20260714-190916Z-51e32386 Speaker 2 (24s) → Freya Wu
  20260715-234424Z-b4d22989 Speaker 1 (24s) → unlabeled
  20260715-234424Z-b4d22989 Speaker 2 (24s) → unlabeled
  20260717-004104Z-948262d9 Speaker 1 (24s) → Freya Wu
  20260717-004104Z-948262d9 Speaker 2 (24s) → unlabeled
  20260718-224137Z-ecad65af Speaker 1 (24s) → unlabeled
  20260718-224137Z-ecad65af Speaker 2 (24s) → Freya Wu
  20260722-230601Z-478f9eaf Speaker 1 (24s) → unlabeled
  20260722-230601Z-478f9eaf Speaker 2 (24s) → unlabeled
  20260725-073400Z-34b88662 Speaker 1 (24s) → unlabeled
  20260725-073400Z-34b88662 Speaker 2 (24s) → unlabeled
  20260726-164831Z-34550a93 Speaker 1 (5s) → unlabeled
  20260803-185339Z-9575ad52 Speaker 1 (24s) → Freya Wu
  20260803-185339Z-9575ad52 Kenny Kim (24s) → Kenny Kim
  20260803-200454Z-f99037fe Speaker 1 (24s) → unlabeled
  20260803-200454Z-f99037fe Speaker 2 (24s) → unlabeled
Embedded clips: 21 (failures: 0)
=== Distribution 1: clip vs enrolled voiceprint (intra-speaker) ===
  min=0.434 p25=0.724 median=0.822 mean=0.767 p75=0.836 p90=1.000 max=1.000
Intra-speaker cosine (clip of person X vs X's voiceprints) (n=9)
  [0.40, 0.45) ######### 1
  [0.60, 0.65) ######### 1
  [0.70, 0.75) ######### 1
  [0.75, 0.80) ######### 1
  [0.80, 0.85) #################################### 4
  [0.95, 1.00) ######### 1
=== Distribution 2: clip vs enrolled voiceprint (inter-speaker) ===
  min=-0.176 p25=0.076 median=0.146 mean=0.247 p75=0.380 p90=0.814 max=1.000
Inter-speaker cosine (clip vs other people's voiceprints; unlabeled clips counted here) (n=117)
  [-0.20, -0.15) ######## 6
  [-0.15, -0.10) ####### 5
  [-0.10, -0.05) # 1
  [-0.05, 0.00) # 1
  [0.00, 0.05) ############ 9
  [0.05, 0.10) #################### 15
  [0.10, 0.15) #################################### 27
  [0.15, 0.20) ##### 4
  [0.20, 0.25) ############# 10
  [0.25, 0.30) ### 2
  [0.30, 0.35) #### 3
  [0.35, 0.40) ########### 8
  [0.40, 0.45) ######## 6
  [0.50, 0.55) ##### 4
  [0.60, 0.65) ### 2
  [0.70, 0.75) # 1
  [0.80, 0.85) ######## 6
  [0.85, 0.90) # 1
  [0.95, 1.00) ######## 6
=== Distribution 3: enrolled × enrolled voiceprints ===
  intra-name pairs: 4, cross-name pairs: 11
  min=0.025 p25=0.434 median=0.528 mean=0.403 p75=0.623 p90=0.623 max=0.623
  min=-0.125 p25=0.070 median=0.105 mean=0.117 p75=0.154 p90=0.238 max=0.371
Enrolled↔enrolled, same person (re-enrollment stability) (n=4)
  [0.00, 0.05) #################################### 1
  [0.40, 0.45) #################################### 1
  [0.50, 0.55) #################################### 1
  [0.60, 0.65) #################################### 1
Enrolled↔enrolled, different people (n=11)
  [-0.15, -0.10) ############ 1
  [0.00, 0.05) ############ 1
  [0.05, 0.10) #################################### 3
  [0.10, 0.15) #################################### 3
  [0.15, 0.20) ############ 1
  [0.20, 0.25) ############ 1
  [0.35, 0.40) ############ 1
  Brian Demsky (2026-07-14…) vs Freya Wu (2026-07-14…) = -0.125
  Brian Demsky (2026-07-21…) vs Kenny Kim (2026-07-17…) = 0.010
  Brian Demsky (2026-07-14…) vs Brian Demsky (2026-07-21…) = 0.025 [same-name]
  Brian Demsky (2026-07-14…) vs Kenny Kim (2026-07-14…) = 0.070
  Freya Wu (2026-07-14…) vs Kenny Kim (2026-08-03…) = 0.089
  Brian Demsky (2026-07-21…) vs Kenny Kim (2026-08-03…) = 0.093
  Brian Demsky (2026-07-14…) vs Kenny Kim (2026-08-03…) = 0.105
  Freya Wu (2026-07-14…) vs Kenny Kim (2026-07-17…) = 0.140
  Brian Demsky (2026-07-14…) vs Kenny Kim (2026-07-17…) = 0.146
  Brian Demsky (2026-07-21…) vs Freya Wu (2026-07-14…) = 0.154
  Brian Demsky (2026-07-21…) vs Kenny Kim (2026-07-14…) = 0.238
  Freya Wu (2026-07-14…) vs Kenny Kim (2026-07-14…) = 0.371
  Kenny Kim (2026-07-14…) vs Kenny Kim (2026-08-03…) = 0.434 [same-name]
  Kenny Kim (2026-07-14…) vs Kenny Kim (2026-07-17…) = 0.528 [same-name]
  Kenny Kim (2026-07-17…) vs Kenny Kim (2026-08-03…) = 0.623 [same-name]
=== Every pair in the tentative band [0.50, 0.65) ===
  20260714-175752Z-4792cb33 Speaker 1 (unlabeled) vs Kenny Kim 2026-07-17… = 0.528 [unlabeled]
  20260714-175935Z-0626ff9f Speaker 1 (unlabeled) vs Kenny Kim 2026-07-17… = 0.528 [unlabeled]
  20260714-190916Z-51e32386 Speaker 1 (unlabeled) vs Kenny Kim 2026-07-17… = 0.528 [unlabeled]
  20260717-004104Z-948262d9 Speaker 2 (unlabeled) vs Kenny Kim 2026-07-14… = 0.528 [unlabeled]
  20260717-004104Z-948262d9 Speaker 2 (unlabeled) vs Kenny Kim 2026-08-03… = 0.623 [unlabeled]
  20260803-185339Z-9575ad52 Kenny Kim (Kenny Kim) vs Kenny Kim 2026-07-17… = 0.623 [intra]
  20260803-200454Z-f99037fe Speaker 2 (unlabeled) vs Kenny Kim 2026-07-17… = 0.623 [unlabeled]
=== Inter/unlabeled pairs at/above MATCH (14; near-certainly intra-in-truth) ===
  20260714-175752Z-4792cb33 Speaker 1 (unlabeled) vs Kenny Kim = 1.000
  20260714-175935Z-0626ff9f Speaker 1 (unlabeled) vs Kenny Kim = 1.000
  20260714-190916Z-51e32386 Speaker 1 (unlabeled) vs Kenny Kim = 1.000
  20260717-004104Z-948262d9 Speaker 2 (unlabeled) vs Kenny Kim = 1.000
  20260718-224137Z-ecad65af Speaker 1 (unlabeled) vs Brian Demsky = 1.000
  20260803-200454Z-f99037fe Speaker 2 (unlabeled) vs Kenny Kim = 1.000
  20260715-234424Z-b4d22989 Speaker 2 (unlabeled) vs Brian Demsky = 0.851
  20260725-073400Z-34b88662 Speaker 1 (unlabeled) vs Brian Demsky = 0.845
  20260722-230601Z-478f9eaf Speaker 2 (unlabeled) vs Freya Wu = 0.840
  20260803-200454Z-f99037fe Speaker 1 (unlabeled) vs Freya Wu = 0.822
  20260725-073400Z-34b88662 Speaker 2 (unlabeled) vs Freya Wu = 0.816
  20260715-234424Z-b4d22989 Speaker 1 (unlabeled) vs Freya Wu = 0.814
  20260722-230601Z-478f9eaf Speaker 1 (unlabeled) vs Brian Demsky = 0.809
  20260726-164831Z-34550a93 Speaker 1 (unlabeled) vs Freya Wu = 0.715
=== Clip × clip near-duplicates (cosine ≥ 0.995) ===
  20260714-175752Z-4792cb33/Speaker 1 ≡ 20260714-175935Z-0626ff9f/Speaker 1 (1.0000)
  20260714-175752Z-4792cb33/Speaker 1 ≡ 20260714-190916Z-51e32386/Speaker 1 (1.0000)
  20260714-175752Z-4792cb33/Speaker 2 ≡ 20260714-175935Z-0626ff9f/Speaker 2 (1.0000)
  20260714-175752Z-4792cb33/Speaker 2 ≡ 20260714-190916Z-51e32386/Speaker 2 (1.0000)
  20260714-175935Z-0626ff9f/Speaker 1 ≡ 20260714-190916Z-51e32386/Speaker 1 (1.0000)
  20260714-175935Z-0626ff9f/Speaker 2 ≡ 20260714-190916Z-51e32386/Speaker 2 (1.0000)
  20260803-185339Z-9575ad52/Speaker 1 ≡ 20260803-200454Z-f99037fe/Speaker 1 (1.0000)
  20260803-185339Z-9575ad52/Kenny Kim ≡ 20260803-200454Z-f99037fe/Speaker 2 (1.0000)
  near-duplicate clusters: 4
=== Band separation (clip × enrolled) ===
  min intra = 0.434 | max inter (incl. unlabeled) = 1.000
  intra pairs below MATCH: 2/9 | below TENTATIVE: 1/9
  inter pairs at/above MATCH: 14/117 | at/above TENTATIVE: 20/117
=== Top-1 acoustic name on determinable clips ===
  correct: 7/7
  20260714-175752Z-4792cb33 Speaker 2 truth=Freya Wu top1=Freya Wu (0.836) ✓
  20260714-175935Z-0626ff9f Speaker 2 truth=Freya Wu top1=Freya Wu (0.836) ✓
  20260714-190916Z-51e32386 Speaker 2 truth=Freya Wu top1=Freya Wu (0.836) ✓
  20260717-004104Z-948262d9 Speaker 1 truth=Freya Wu top1=Freya Wu (0.793) ✓
  20260718-224137Z-ecad65af Speaker 2 truth=Freya Wu top1=Freya Wu (0.724) ✓
  20260803-185339Z-9575ad52 Speaker 1 truth=Freya Wu top1=Freya Wu (0.822) ✓
  20260803-185339Z-9575ad52 Kenny Kim truth=Kenny Kim top1=Kenny Kim (1.000) ✓
=== Duration sensitivity (determinable intra clips only) ===
  20260714-175752Z-4792cb33/Speaker 2 truth=Freya Wu | 5s=0.729 | 10s=0.807 | 15s=0.815 | 20s=0.831 | full=0.836
  20260714-175935Z-0626ff9f/Speaker 2 truth=Freya Wu | 5s=0.729 | 10s=0.807 | 15s=0.815 | 20s=0.831 | full=0.836
  20260714-190916Z-51e32386/Speaker 2 truth=Freya Wu | 5s=0.729 | 10s=0.807 | 15s=0.815 | 20s=0.831 | full=0.836
  20260717-004104Z-948262d9/Speaker 1 truth=Freya Wu | 5s=0.706 | 10s=0.770 | 15s=0.785 | 20s=0.788 | full=0.793
  20260718-224137Z-ecad65af/Speaker 2 truth=Freya Wu | 5s=0.682 | 10s=0.663 | 15s=0.710 | 20s=0.724 | full=0.724
  20260803-185339Z-9575ad52/Speaker 1 truth=Freya Wu | 5s=0.645 | 10s=0.776 | 15s=0.785 | 20s=0.817 | full=0.822
  20260803-185339Z-9575ad52/Kenny Kim truth=Kenny Kim | 5s=0.830 | 10s=0.909 | 15s=0.947 | 20s=0.978 | full=1.000
  mean similarity by prefix length:
     5s: 7 clips, mean=0.722 (min=0.645, max=0.830)
    10s: 7 clips, mean=0.792 (min=0.663, max=0.909)
    15s: 7 clips, mean=0.810 (min=0.710, max=0.947)
    20s: 7 clips, mean=0.829 (min=0.724, max=0.978)
=== Done (read-only sweep; nothing written) ===
```
