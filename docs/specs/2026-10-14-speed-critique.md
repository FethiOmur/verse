# Verse v1 speed architecture: adversarial critique

Date: 2026-10-14. Reviews `2026-10-14-verse-meeting-assistant-v1-design.md` (sections 5–6, checked against 3, 7–9, 11).
Read-only review: the spec itself is unchanged.

Local measurements made for this review (this Mac, 2026-10-14):

- `curl` to `https://api.anthropic.com/v1/models` (unauthenticated, 401 path): TCP connect 38–54 ms, TLS done at
  95–162 ms, first byte at 262–340 ms on a cold connection. On a **reused** HTTP/2 connection the request took
  **164–168 ms**. ICMP RTT to the edge (160.79.104.10) averaged 35.5 ms. So the edge is close, and about 130 ms of each
  request is spent behind it. The inference path may differ (see section 4).
- `python3 <retrieval-script> context --no-sync --json "<query>"`: **0.26–0.43 s** wall time per subprocess (3 runs). The default
  mode, without `--no-sync`, also syncs the vault and writes to vault and runtime state. I did not run it, so its time
  is not measured.
- Local `httpx` 0.28.1 sets `keepalive_expiry` to 5.0 s by default. The local `anthropic` 0.54 sets
  `DEFAULT_CONNECTION_LIMITS = httpx.Limits(max_connections=1000, max_keepalive_connections=100)` and leaves the
  expiry at that default.

---

## 1. Blocking problems (most severe first)

### B1. t = 0 is undefined, and the budget leaves out endpointing and ASR lag (§5.1, §6)
**Why it fails.** Every target is measured from "t = 0, the end of the other person's question". There are two
possible meanings. If t = 0 is the *acoustic* end of speech, then the 250–400 ms silence wait (§5.4) and the delay
before the last word shows up in a partial are both inside the budget. If t = 0 is the *moment the endpointer fires*,
the targets look good but the user feels about 0.3–0.6 s more than they show. Add the measured ~165 ms request floor
and a Haiku server TTFT of a few hundred ms, and **F p50 ≤ 0.9 s is out of reach if t = 0 is acoustic**. It is
borderline even under the other reading.
**How to show it.** In the replay harness, label the acoustic end of each question from the audio (the ground-truth
end of speech). Log per-stage timestamps: last audio frame of the question, last word in a volatile result, endpoint
decision, request sent, first byte, first opener word parsed, first frame rendered.
**Fix.** Define t = 0 as the acoustic end of speech from the labelled audio, and report each stage separately.
Change the F target to "first word p50 ≤ 1.1 s, p90 ≤ 1.7 s; full opener p50 ≤ 1.4 s" (section 3), or accept the
measured numbers.

### B2. The speculator policy ensures that nothing is ready at t = 0 (§5.3)
**Why it fails.** The policy is "at most one call in flight, the older one is cancelled, re-fire on a meaningful
change, debounced ~500 ms". To be ready at t = 0, a speculative call needs about 0.8–1.0 s (165 ms network, Haiku
TTFT, about 30 tokens of opener). The question changes meaningfully in its last second, which is when the object, the
negation or the verb arrives. Each such change cancels the call that would have finished and starts one that
cannot. The result is that S rarely beats F, so the "≤ 0.2 s" row seldom happens.
- Turkish is verb-final. The predicate and the `mı/mi/mu/mü` particle come last, so a partial taken before the end
  often lacks the part that decides the answer.
- Italian yes/no questions differ from statements only by intonation.
- Haiku 5.5 accepts only `temperature = 1` (the bundled docs say any other value is a 400). Each re-fire therefore
  produces a different opener, so a speculative opener shown before t = 0 will flicker even when the question has not
  changed.

**How to show it.** In replay, count the share of questions where a finished S output exists at t = 0 and passes
the reuse check. Do this under the spec's policy and under the fix below.
**Fix.** Do not cancel on change. Keep up to 3 speculative calls in flight, each tagged with the partial it saw.
Cancel only on barge-in, at turn end, or when a call is more than 2 partials stale. At t = 0, pick the call whose
input best covers the final text. Do not show speculative text before t = 0. Show only the faint
"likely: <question>" line. Cost is negligible: about 30k cached input tokens ≈ $0.0003 a call, plus about 100
output tokens ≈ $0.00005.

### B3. The opener-then-continue design races and spreads errors (§5.1 D row, §5.4, §5.6)
**Why it fails.** D fires at t = 0 "with … the opener already on screen". When S guessed wrong, F's opener does not
exist yet at t = 0; it appears around +1.0–1.4 s. D therefore continues either nothing or the wrong S opener. Three
more problems:
- the owner will paraphrase rather than read word for word. A "continuation" of words he did not say reads oddly.
- If the opener is wrong (bank false positive, or a wrong S guess that was kept), D is told "the owner is already saying
  this; continue naturally". That pushes D to elaborate the wrong answer in a confident tone.
- No prefill exists, so the continuation is only as coherent as the instruction-following. It also costs D extra
  tokens to re-state the context.

**How to show it.** Replay with forced wrong openers (swap in another question's opener). Count D outputs that build
on the wrong opener instead of correcting it.
**Fix.** D writes **self-contained detail points** that answer the question, not a continuation of the sentence. It
receives the shown opener only as "already shown; do not repeat it; if it is wrong for this question, say so first".
D then emits a leading `OPENER_OK` or `OPENER_WRONG` line, and the overlay strikes through and replaces the opener on
`OPENER_WRONG`. If the continuation style is kept, D must start after F's opener has finished, which adds about
0.3–0.5 s to D. The budget still fits with thinking off.

### B4. "Final text" is used where only volatile text arrives in time (§5.4, §5.7 item 2)
**Why it fails.** The reuse check ("final text differs from the last speculated text") and D's input both use the
*final* question. SpeechAnalyzer's finalized results arrive later than the volatile ones, and the delay is
unmeasured. It could be 0.5–2 s, which would break the ≤ 0.2 s rows and add the same delay to D.
**How to show it.** In the day-1 benchmark, measure the volatile lag and the finalization lag separately, per
language, with `.fastResults` on and off (`SpeechTranscriber.ReportingOption.fastResults` exists, confirmed on Apple
docs).
**Fix.** At the endpoint, act on the latest volatile text (with `audioTimeRange`). Treat the final result as a later
correction. Re-fire F or D only if the final changes content words, not punctuation or casing.

### B5. Mic bleed on speakers breaks turn detection (§5.3 barge-in, §5.7 item 1)
**Why it fails.** The mic is captured raw through AVAudioEngine. Meet and Zoom run echo cancellation on *their*
mic stream, not on Verse's. On laptop speakers, the remote voice comes back through Verse's mic channel. It gets
transcribed as the owner, so "if the owner starts speaking, the turn is over" fires in the middle of the question. It also
creates duplicate transcript lines and wrong summaries.
**How to show it.** Play the replay set through the MacBook speakers with the mic open. Count false the owner turns and
cancelled speculations.
**Fix.** v1 options:
- Require headphones, detect the output route, and show a chip when output is speakers.
- Or enable AVAudioEngine voice processing (`setVoiceProcessingEnabled`) on the mic and verify the echo
  suppression.
- In either case, gate the owner-VAD: discard mic speech whose energy envelope correlates with the remote channel
  shifted by 0–80 ms.

### B6. Capturing the remote side from Brave is unproven, and the chosen API is the heavier one (§5.7 item 1, §11)
**Why it fails.**
- Browser audio is spread over several processes (main, renderer, audio-service helpers). Recall.ai describes this
  for Chrome-family browsers. It is not established that a ScreenCaptureKit per-app filter on Brave picks up the
  helper process that actually plays the audio. If it does not, the remote channel is silent and nothing works.
- The fallback, all system audio, mixes in every other sound and every other tab.
- ScreenCaptureKit also needs Screen Recording permission, which brings the recording indicator and the periodic
  re-approval prompts on recent macOS.

**How to show it.** Day-1 test: a Meet call in Brave with the per-app filter. Check for non-zero audio buffers and
measure capture latency.
**Fix.** Use **Core Audio process taps** (`AudioHardwareCreateProcessTap`, macOS 14.2/14.4+). Tap every PID under
`Brave Browser.app`, helpers included, behind an aggregate device. This is audio only, needs the system-audio
recording permission instead of Screen Recording, and gives one remote stream. Keep ScreenCaptureKit as a fallback.
Zoom and Teams native apps tap by bundle the same way.

### B7. Answer-bank matching fails in Turkish, gives confident false hits, and its acceptance metric is circular (§5.2, §5.3, §9)
**Why it fails.**
- `NLEmbedding.sentenceEmbedding` covers English, Spanish, French, German, Italian, Portuguese and Simplified
  Chinese. **Turkish is not covered** (per the WWDC20 session summary).
- Plain BM25 on agglutinative Turkish ("projede / projeyi / projelerimizde") without stemming misses the
  paraphrases.
- Each embedding is one language's space, so an Italian question cannot be compared with an English paraphrase.
- Volatile partials are rewritten as speech continues, so a faint hit flickers.
- A false hit is the worst failure in the design. It shows a polished, Sonnet-written, source-cited answer to a
  different question, faintly *before* t = 0 and solid after. The spec does not say how a wrong hit is taken back.
- §9's "≥ 50 % hit rate" is measured on a replay set the owner writes himself after reviewing the bank, so it is inflated.
  It measures no precision at all.

**How to show it.** Build held-out paraphrases written blind, by another person or model that never saw the bank.
Measure hit rate **and** wrong-hit rate per language at the chosen threshold. Measure the Turkish set separately.
**Fix.**
- Matching: character 3–5-gram TF-IDF (handles Turkish morphology), plus `NLContextualEmbedding` mean-pooled for
  Turkish (test the quality; it is not trained for sentence similarity), plus required per-language paraphrases.
- A hit needs a margin between the top two candidates and must persist across 2 consecutive partials.
- At t = 0, the S/F Haiku call also returns `BANK: <id>|none`, and the bank entry turns solid only if Haiku agrees.
- On disagreement: strike through and replace within one render.
- Acceptance: hit rate ≥ X **with** wrong-hit rate ≤ 5 % on the blind set.

### B8. Live retrieval breaks the grounding rule and costs 0.3–0.45 s through a subprocess (§5.2 vs §5.3/§5.4, §11)
**Why it fails.**
- §5.2 says the live tiers may state only facts from the fact sheet or the prep note. §5.3/§5.4 feed D "retrieved
  snippets" from the retrieval script's `context` command at meeting time. Either those snippets cannot be used (wasted latency), or the
  rule is broken.
- The subprocess cost is measured at 0.26–0.43 s even in `--no-sync` mode.
- The default mode syncs the vault, which writes to the vault and runtime state during the meeting.
- "Key nouns" extraction is not specified.
- When speculation did not fire, D waits for retrieval after t = 0.

**How to show it.** Time D with and without retrieval in replay, and check where D's cited sources come from.
**Fix.** No live retrieval-script calls. At prep, pull a broader snippet set (top-k per bank entry and per glossary term)
into the cached meeting pack. At runtime, retrieve in-process from the pack: Python BM25 over a few hundred snippets
takes well under 10 ms. If live vault retrieval stays, import the engine in-process with `read_only=True` (the CLI's
`--no-sync` path). Then widen the rule to "pack + retrieved snippets, each with a source id", and show snippet ids as
source chips.

### B9. The cache layout is unspecified, and the likely layouts silently miss or overpay (§5.5)
**Why it fails.** §5.5 caches "the static prefix" but does not say where the rolling transcript and the partial go.
- If the transcript is in the system prompt or before the breakpoint, every turn rewrites the cache.
- If top-level automatic caching is used, the breakpoint lands after the unique partial. Every re-fire then pays a
  1.25× write that is never read, which the bundled caching guide calls a pure surcharge.
- If the transcript sits after the breakpoint uncached, prefill grows through the meeting and so does TTFT.
- "Structured JSON lines" with `output_config.format` cannot be pre-warmed: `max_tokens: 0` rejects
  `output_config.format`, so the warm entry may not match the real calls.
- Thinking or effort mismatches between pre-warm and real calls give a separate entry. D's thinking setting is
  "decided in the spike", so the pre-warm and keep-alive must change in step with it.
- A Summarizer with different effort or thinking settings is a third entry.
- Haiku 5.5 doubles its rate card above 100K prompt tokens.

**How to show it.** Log `cache_read_input_tokens` and `cache_creation_input_tokens` on every call in the benchmark.
Add the cache-diagnosis beta (`cache-diagnosis-2026-04-07`) while tuning.
**Fix.** Fixed layout per route:
1. Frozen system instructions.
2. Meeting pack, with explicit breakpoint 1.
3. Finalized transcript turns as **append-only** message blocks, with explicit breakpoint 2 on the newest finalized
   turn, moved forward at most every few turns so it stays inside the 20-block lookback.
4. The partial or question text after the last breakpoint.

Also:
- No top-level auto caching.
- A plain-text output format, not `output_config.format` (improvement I6).
- One settings tuple per route: S/F share Haiku, low effort, thinking disabled. D gets Sonnet, medium effort, with
  either `between_tools` or adaptive (whichever the spike picks). Pre-warm and keep-alive copy that tuple byte for
  byte.
- Cap the pack plus transcript at about 80K Haiku tokens, counted with `count_tokens` (Haiku 5.5 has a new tokenizer
  that uses ~30 % more tokens).

### B10. Connections go cold between questions, and Python stdout buffering can hold tokens (§5.5 "one long-lived client", §5.7 item 5)
**Why it fails.**
- With the httpx default (`keepalive_expiry = 5.0`, confirmed locally; anthropic 0.54 does not override it), any gap
  over 5 s between calls on a model closes the pooled connection. Gaps that long are normal in meetings. The next
  call then pays TCP and TLS again: **+60–160 ms measured** from this Mac.
- httpx speaks HTTP/1.1 unless `http2=True`. Concurrent S, F, D and Summarizer calls therefore open extra connections,
  each with a handshake.
- On the IPC side, Python block-buffers stdout when it is a pipe. Without `flush=True` or `python -u`, the JSON lines
  for streamed tokens sit in an 8 KB buffer and reach Swift in bursts, or only at the end.

**How to show it.** Benchmark TTFT after a 10 s idle gap versus back to back. Timestamp IPC lines on both sides.
**Fix.** Pass a custom `http_client=httpx.AsyncClient(http2=True, limits=httpx.Limits(keepalive_expiry=300, ...))`.
Pre-open one connection per model at session start and touch it every ~30 s. A cheap `GET /v1/models` keeps the
socket alive; whether the server keeps an idle HTTP/2 connection is unconfirmed. Run the brain with `-u`, flush every
line, and read with a line-buffered `FileHandle.readabilityHandler` on the Swift side.

### B11. Rate limits on a credit-only org can fail exactly at t = 0 (§3, §5.3, §7)
**Why it fails.**
- The org has no payment method, so its rate-limit tier is unknown and may be the lowest.
- Peak load during one question can be 2 speculative calls a second (or 3 in flight after B2), plus F, D, the
  Summarizer and keep-alives.
- A 429 at t = 0 kills the answer. Worse, the SDK default `max_retries = 2` with backoff turns it into a late, stale
  answer several seconds later.

**How to show it.** Read the org's per-model RPM, ITPM and OTPM on the Console limits page before the spike. Run a
synthetic 30-minute replay at peak question density.
**Fix.** A client-side token bucket per model, below the limit. `max_retries=0` for S and F: a stale opener is worse
than none. Speculation drops out first under pressure. §7 should treat 429 separately from "offline".

### B12. The remote channel mixes everyone, so questions to other people trigger answers (§1, §5.3, §5.7 item 1)
**Why it fails.** With several remote participants, all of them arrive on one channel and nothing labels the
speaker. A question addressed to a colleague ("Marco, what's the timeline?") triggers S/F/D and a confident "SAY"
line. That is a wrong answer on screen, and it costs Sonnet calls. §9's question-detection precision does not
measure whether the question was addressed to the user.
**How to show it.** Use replay dialogues with 3 speakers where some questions are addressed to others. Measure
precision restricted to questions addressed to the user.
**Fix.**
- Addressee cues: the owner's name, second-person forms (`sen/siz`, `tu/Lei`, `you`), a question right after the owner's own
  turn, and silence held for the user.
- Questions not addressed to him get a small "for others" style without a SAY line, and no D call.
- Optional: per-voice clustering on the remote channel (the spec mentions none).

**Non-blocking but worth noting:**
- Haiku 5.5 has safety classifiers with **no server-side fallback** (refusal = HTTP 200 + `stop_reason: "refusal"`).
  Security or AI-model talk in the owner's meetings could hit `cyber` or `frontier_llm`, and §7 has no branch for it.
- The 16 kHz conversion should use `SpeechAnalyzer.bestAvailableAudioFormat` rather than a fixed format.
- "Language … auto": SpeechTranscriber takes one locale, and I found no built-in language ID (unconfirmed).
  Turkish meetings full of English terms will need per-session locale choice or an external language ID.

---

## 2. Improvements (gain / cost)

| # | Improvement | Expected gain | Cost |
|---|---|---|---|
| I1 | **Speculative fan-out without cancellation**: up to 3 Haiku calls in flight, choose at t = 0 (B2) | S-ready-at-t = 0 rate rises from "rare" to a large share of English/Italian questions (estimate, to be measured); the ≤ 0.2 s path actually occurs | ~$0.0004 per extra call; 2–3× the Haiku RPM during questions (watch B11) |
| I2 | **Use the bank's deep answer directly on a strong hit**: it is already Sonnet-written with sources, so show it at t ≈ 0 and skip D, or run D only as a short "adapt to the exact wording" pass | Deep content at ~0 s instead of ~2–3 s on every bank hit; fewer Sonnet calls | None; less spend |
| I3 | **Speculative D on a stable partial**: when S has re-fired twice on the same core question, or the bank hit is solid, fire Sonnet before t = 0 | D first words ~0.5–1.5 s earlier when right | ~$0.01–0.02 per wasted Sonnet call; cap at 1 in flight |
| I4 | **Local fact chips at t ≈ 0**: char-n-gram BM25 of the question over the fact sheet and glossary, rendered instantly as source chips (numbers, names, dates the owner can cite) | Grounded, useful content within ~20 ms for every question, a time-buying trick that never invents anything; also a grounding anchor for S/F | Local only; a few ms |
| I5 | **Language-aware endpointing and question detection**: Turkish `mı/mi/mu/mü` plus verb-final finish; English aux inversion and wh-words; Italian F0 rise from a small YIN/vDSP pitch tracker on the remote channel (SpeechAnalyzer gives no pitch); a per-speaker silence threshold learned in the first minutes; a hesitation guard (`um/eh/ehm/şey`) | 100–200 ms off the endpoint wait when the cue is strong; fewer premature fires on slow or non-native speakers | ~1–2 days of DSP and rules; tune on replay |
| I6 | **Plain-text line protocol instead of JSON**: the model writes `SAY: …` then `- …` lines; Swift renders on the first token; IPC sends deltas `{id, seq, field, text}` rather than the full object each time | First word renders after ~2 tokens; no partial-JSON parser; compatible with `max_tokens: 0` pre-warm (B9) | Trivial |
| I7 | **Swift-native fast path**: S/F as raw HTTP SSE over `URLSession` (HTTP/2, pre-opened, keep-warm) in Swift; Python keeps prep, D and the Summarizer | Honest gain is small for IPC (a pipe hop is < 1 ms once flushed). The real gain is removing the cold-connection (B10) and buffering failure modes from the hottest path, and one fewer process on the critical path | ~1–2 days; Swift has no official SDK, so raw HTTP is the sanctioned route |
| I8 | **Runtime grounding guard**: before rendering, check every number, date and proper noun in a live suggestion against the pack, fact sheet and transcript. Unmatched spans are dimmed with "unverified" or dropped. D additionally cites snippet ids that must exist | Enforces §5.2's rule live, not only in the offline eval (§9); prevents the most damaging on-screen errors | A few ms; a regex plus set lookup |

Not proposed: a local model for generation (forbidden by §2). Local matching and retrieval only (I4, B7, B8) stays
inside the "API credit only for generation" rule.

---

## 3. Revised latency budget (realistic; t = 0 = acoustic end of the question)

Stage estimates. Measured values are marked (m); everything else is an estimate to confirm in the day-1 benchmark.

| Stage | p50 | p90 | Notes |
|---|---|---|---|
| Endpoint decision after acoustic end | 300 ms | 450 ms | 250–400 ms silence; overlaps with ASR lag; I5 can cut ~100–150 ms with a strong cue |
| Last word visible in a volatile partial | 200 ms | 500 ms | unmeasured; runs in parallel with the silence wait |
| Swift → Python IPC (flushed) | < 2 ms | 5 ms | only if B10 is fixed; otherwise unbounded |
| Request floor, warm HTTP/2 (m) | 165 ms | 200 ms | measured on the 401 path; inference path unconfirmed |
| Extra cost of a cold connection (m) | +60 ms | +160 ms | after > 5 s idle with httpx defaults |
| Haiku 5.5 server TTFT, cached prefix, thinking off | 300 ms | 600 ms | unconfirmed; no published figure found |
| Haiku opener complete (~30 tokens) | +150 ms | +300 ms | unconfirmed output speed |
| Sonnet 5.5 server TTFT, `between_tools`, cached | 600 ms | 1200 ms | unconfirmed |
| Sonnet with adaptive thinking at medium | +1–4 s | +6 s | thinking display `omitted` = a silent pause |
| Parse + IPC back + SwiftUI render | 20 ms | 50 ms | no entrance animation on text arrival; a spring adds 150–300 ms of perceived delay |

Paths (summing the rows above):

| Path | Spec target | Realistic p50 | Realistic p90 | Verdict |
|---|---|---|---|---|
| Bank hit → points visible | before t = 0 / ≤ 0.2 s | ≤ 0.2 s (solid at the endpoint, ~0.3 s) | 0.5 s | Plausible for **display**; the open question is precision (B7). Measured from acoustic end it is ~0.3 s, because "solid" waits for the endpoint |
| Speculation correct → opener visible | ≤ 0.2 s | 0.3 s | 0.5 s | Plausible only when S was fired ≥ ~1 s before the end **and** survived (B2); otherwise this path does not occur |
| S wrong, no bank hit → Haiku opener first word | p50 ≤ 0.9 s, p90 ≤ 1.5 s | **~0.8–1.0 s** | **~1.5–1.9 s** | Misses p90; p50 borderline. Full opener ≈ +0.15–0.3 s |
| Sonnet first words (thinking off, independent points per B3) | p50 ≤ 3.0 s, p90 ≤ 4.5 s | ~1.1–1.4 s | ~2.0–2.5 s | Comfortable, and room left to wait for F's opener (+0.3–0.5 s) |
| Sonnet first words (adaptive thinking, medium) | same | ~2.5–4.5 s | 6 s+ | Likely misses p90; choose `between_tools` unless the eval shows a large quality gap |
| Bank hit → deep answer (I2) | — | ~0.3 s | 0.5 s | New path; makes D optional on hits |
| Fact chips (I4) | — | ~0.3 s (shown with the endpoint) | 0.5 s | New path; every question gets grounded content at the endpoint |

Proposed §6 targets after the fixes: bank or fact chips ≤ 0.4 s p90; S-hit opener ≤ 0.5 s p90; F first word p50
≤ 1.1 s, p90 ≤ 1.8 s; D first words p50 ≤ 2.0 s, p90 ≤ 3.0 s (thinking off). All measured from the acoustic end,
with per-stage logs.

Cost check: not the binding constraint, provided caching works. Rough figures:
- Live meeting: S/F ≈ $0.15 per 30 min; D ≈ $0.02–0.03 per call, so ~$0.7–1.5 per 30 min.
- Prep: Sonnet at high effort, ~$1 per meeting.
- Total: about $2–4 per meeting against $200 a month.

The real risks are B9 (silent cache misses, which raise latency more than cost) and B11 (rate limits).

---

## 4. Unconfirmed items (and where I looked)

- **SpeechAnalyzer Turkish:** a third-party guide (antongubarenko.substack.com, "iOS 26: SpeechAnalyzer Guide") lists
  `tr_TR` and `it_IT` in `SpeechTranscriber.supportedLocales`. Another (blog.addpipe.com) lists the 10 launch
  languages without Turkish, so Turkish was probably added in a later release. Confirm with `supportedLocales` and
  asset install on the user's macOS 26 build.
- **SpeechAnalyzer partial and final latency:** no measured figures found. Searched the WWDC25 session 277 page,
  Apple docs (`ReportingOption`: `volatileResults`, `fastResults`, `alternativeTranscriptions` confirmed), and
  forasoft.com (generic on-device ASR claims, not SpeechAnalyzer-specific). Day-1 benchmark item.
- **No built-in language auto-detect in SpeechTranscriber:** inferred from `init(locale:)` and from a Medium article
  that builds external language ID. Not stated by Apple in anything I read.
- **NLEmbedding sentence-embedding languages** (en, es, fr, de, it, pt, zh-Hans; no Turkish): from a GitHub summary of
  WWDC20 session 10657, not from Apple's reference page. NLContextualEmbedding covers "27 languages across three
  scripts" (WWDC23 10042 page), but I did not confirm Turkish in the list, nor its quality for sentence similarity.
- **ScreenCaptureKit per-app capture of Brave helper-process audio:** not confirmed either way. Recall.ai's process-tap
  article confirms the multi-process audio layout for browsers. Apple's Core Audio taps article confirms
  `AudioHardwareCreateProcessTap`. The exact TCC permission name for process taps is unconfirmed.
- **Haiku 5.5 / Sonnet 5.5 TTFT and output speed:** no published figures; the bundled docs give none.
- **The inference path behind the edge:** whether it has the same ~165 ms floor as the 401 path I measured is
  unknown. My location was not verified (assumed Milan).
- **Whether closing a stream stops output billing immediately:** the spec claims it; the bundled docs do not say. A
  cancelled call still pays its full input (prefill).
- **The anthropic SDK 1.x HTTP client keep-alive defaults:** I checked only the local 0.54 + httpx 0.28.1. The bundled
  upgrade guide mentions an `httpx2` move in 1.x, so its defaults may differ.
- **Idle HTTP/2 connection lifetime on the API side:** unknown, so the keep-warm interval needs measuring.
- **Rate-limit tier of "Personal API Org":** unknown. Check the Console limits page.
- **AVAudioEngine voice processing on macOS:** whether its echo reference covers audio played by other apps (Brave)
  is unconfirmed.
- **Cost figures in section 3:** estimates from the per-MTok prices given in the brief and the bundled docs, with
  assumed token counts. Not measured.
