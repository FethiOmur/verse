# Verse v1: meeting assistant (design)

Status: draft for the owner's review, 2026-10-14. Implementation starts after approval.
Sources: `~/Workspace/Textream_Analiz/textream_architecture_and_rebuild.md`,
`~/Workspace/Textream_Analiz/model_login_options.md`, brainstorming answers on 2026-10-14.

## 1. Goal and audience

Verse is a native macOS app that listens to an online meeting and, without being asked, shows short,
source-backed help in a notch overlay. It suggests answer points for questions put to Alex, recalls facts from
his own notes and recent work, keeps a live list of decisions and actions, and explains unfamiliar terms.

v1 is for the owner's own daily use on his MacBook (macOS 26, Apple Silicon). Distribution to other users, a
teleprompter mode and an iOS app are later specs (section 10).

## 2. What Alex decided (2026-10-14)

| Topic | Decision |
|---|---|
| v1 focus | Meeting assistant first; teleprompter later |
| Meetings | Online (Google Meet, Zoom, Teams); English, Italian, Turkish |
| What it shows | Reminders from own notes; answer points for questions asked; live summary and actions; term explanations |
| Trigger | Fully automatic (no hotkey needed) |
| Knowledge sources | knowledge-vault vault via `beyin.py`; a per-meeting prep note; commit history of repos chosen per meeting |
| Brain | **Claude, paid only from the Claude Max membership's monthly API credit** (Individual Org API key). No local-model fallback for generation |
| Speed | First words almost immediately; Haiku opener first, Sonnet 5.5 (effort medium) continues (2026-10-14) |
| Stack | Swift (not Rust, not a Textream fork) |
| Name | Verse |

## 3. Constraints

- **Max membership, sanctioned route only.** Calls use an API key from "Personal API Org", which draws on
  the Max monthly API credit. No Claude.ai/Max OAuth, no Max plan credentials in the app: the Claude Code legal page
  says Anthropic does not permit third-party apps to offer Claude.ai login or route requests through Free, Pro or
  Max credentials (read 2026-10-14). The org has no payment method, so spend stops when the credit runs out.
- **No audio is stored.** Audio stays in memory long enough to transcribe it. Transcripts and suggestions are
  saved locally only (`~/Library/Application Support/Verse/sessions/`). At the end of a meeting a summary is written to
  the vault only if Alex confirms.
- **What leaves the Mac:** transcript turns, the meeting pack (prep note, retrieved vault snippets, commit
  summaries) and prompts go to the Anthropic API. Nothing else.
- **Positioning:** a meeting assistant, not marketed as undetectable. Use in job interviews or exams is not a
  design target.
- **The API key** lives in the macOS Keychain and is passed to the brain process as an environment variable at
  launch. It is never written to disk or logs.
- **Models:** `claude-haiku-5-5` for the fast tiers and `claude-sonnet-5-5` (effort medium) for the deep tier
  and prep. Everything streams.

## 4. Approaches considered

| Option | Verdict | Reason |
|---|---|---|
| **Swift app + Python brain sidecar** | **Chosen** | Native audio, speech and overlay APIs; the official Anthropic Python SDK; `beyin.py` is Python; fast prompt iteration |
| All Swift | Later | No official Anthropic Swift SDK (raw HTTP); slower prompt iteration. Port the brain once prompts are stable |
| Rust core | Rejected | Liquid Glass, notch panel, ScreenCaptureKit and SpeechAnalyzer are Swift/ObjC APIs; FFI cost. Revisit only for Windows |
| Textream fork / Director demo | Rejected | The files that would change are its largest and most coupled; the demo would be thrown away |
| Max OAuth login | Not allowed | Anthropic policy above |
| Hotkey-only trigger | Rejected by Alex | Chose fully automatic |

## 5. Speed architecture (the core of v1)

the owner's requirement (2026-10-14): 3.5 s is far too slow. The first usable words must appear almost
immediately, then a strong model continues with better sentences. This section was revised after an adversarial
critique (`2026-10-14-speed-critique.md`, blocking items B1–B12, improvements I1–I8). The labels in brackets
point to it.

Four principles:
1. Do the slow, smart work **before** the meeting.
2. Start working **while** the question is still being asked.
3. Show the cheapest *correct* thing first.
4. Never let a fast guess make a wrong answer look more confident.

**t = 0 is the acoustic end of the other person's question** [B1]. Every target is measured from there, with
per-stage logs.

### 5.1 Time tiers

| Tier | Typical time after t = 0 | Source | Shows |
|---|---|---|---|
| **P: Prepared** | ≤ 0.4 s (p90) | Local match against the answer bank built before the meeting | Pre-written opener + points + deep answer (written by Sonnet, with sources) [I2] |
| **C: Fact chips** | ≤ 0.4 s (p90) | Local lookup in the fact sheet for names and terms in the question | Grounded numbers, dates and names with their source, at no cost [I4] |
| **S: Speculative** | ≤ 0.5 s (p90) | Haiku 5.5 calls fired while the question forms | Opener + 2 points |
| **F: Fast** | p50 ≤ 2.0 s, p90 ≤ 2.8 s | Haiku 5.5 on the endpoint text, when no S call fits | Opener + 2 points |
| **D: Deep** | p50 ≤ 2.0 s, p90 ≤ 3.0 s | Sonnet 5.5, effort medium | Self-contained detail points with sources [B3] |

The overlay never waits for D. On a strong bank hit, D is skipped or reduced to a short "anything to add?" call
[I2].

### 5.2 Before the meeting: Prep stage

From the prep note, the vault (`beyin.py context`) and the selected repos' commits, Claude Sonnet 5.5 (effort high,
not latency-bound) builds:

- **An answer bank.** 40–120 likely questions. Each entry has a canonical question, at least 3 paraphrases per
  meeting language, a one-line opener, 3 points, an ~100-word deep answer and sources.
- **A fact sheet.** Numbers, dates and names with sources.
- **A glossary.** One line per term.
- **A snippet set.** Top-k vault snippets per bank entry and glossary term [B8].

**Grounding rule: no live `beyin.py` calls during the meeting** [B8]. All retrieval happens here, so the live
tiers state facts only from the fact sheet, the prep note and the snippet set. This also removes the vault
writes and the 0.3–0.45 s subprocess cost from the live path. `beyin.py` runs with `--no-sync` even at prep.

Alex can read and correct the bank before the call.

### 5.3 Matching the bank [B7]

- **Local index:** character 3–5-gram TF-IDF over questions and paraphrases (this copes with Turkish
  morphology). Add NaturalLanguage sentence embeddings where the language is supported, and test
  `NLContextualEmbedding` for Turkish (unconfirmed quality).
- **When a hit counts:** it needs a margin over the second candidate and must persist across 2 consecutive
  partials. It shows faintly while the question is spoken.
- **At t = 0** the S/F Haiku call also returns `BANK: <id>|none`. The bank entry turns solid only if Haiku
  agrees; otherwise it is struck through and replaced within one render.

### 5.4 While the question is being asked: Speculation [B2, I1, I3, I5]

- **Signals:** language-aware question cues.
  - Turkish: the `mı/mi/mu/mü` particle, `nasıl / neden / ne zaman`, and verb-final position.
  - English: word order and wh-words.
  - Italian: rising pitch (yes/no questions differ from statements only by intonation), plus `come / perché /
    quando / può`.
  - A hesitation guard ("um", "ehm", "şey") stops early fires.
- **Haiku speculation:** up to **3 calls in flight; none are cancelled early** [I1]. A new call fires when the
  partial changes meaningfully (at least 300 ms after the previous one). At t = 0 the call whose input is closest
  to the endpoint text wins; the rest are closed. Extra cost is about $0.0004 per call.
- **Early Sonnet** [I3]: when a partial stays stable and matches a bank entry or a clear question for ≥ 700 ms,
  D fires before t = 0. It saves 0.5–1.5 s when the guess is right and wastes about $0.01–0.02 when it is wrong.
- **Volatile text, not final text** [B4]: reuse checks and D's input use the latest volatile transcript with
  its `audioTimeRange`. Finalized text arrives later and only corrects the transcript log.
- **Barge-in:** if the other person keeps talking, S calls already in flight keep running but are not shown. If
  Alex starts speaking (verified mic speech, see 5.7), the turn is over.

### 5.5 Who is the question for? [B12]

The remote channel mixes everyone, so the assistant checks the addressee:
- the owner's name,
- second-person forms (`sen/siz`, `tu/Lei`, `you`),
- a question directly after the owner's own turn,
- a pause held open for Alex.

Questions for someone else get a small "for others" style with no SAY line and no D call. Per-voice clustering
is a later option.

### 5.6 Opener and deep points [B3]

- **D does not continue Haiku's sentence.** It writes self-contained detail points. It gets the shown opener
  only as context: "already shown; don't repeat it; if it's wrong for this question, say so first".
- **D's first line is `OPENER_OK` or `OPENER_WRONG`.** On `OPENER_WRONG` the overlay strikes through and
  replaces the opener. This way a fast guess can never make a wrong answer look more confident.
- **Live grounding check** [I8]: every number and proper name rendered on screen is checked against the
  meeting pack. One that isn't there is greyed and labelled "not in your notes".

### 5.7 Audio [B5, B6]

- **Remote side:** captured with Core Audio process taps (`AudioHardwareCreateProcessTap`) on all processes of
  the meeting app (Brave helpers, Zoom, Teams). This needs the audio-recording permission and gives one remote
  stream. ScreenCaptureKit is the fallback. Proving the Brave route is spike item #1.
- **the owner's mic:** AVAudioEngine with voice processing (`setVoiceProcessingEnabled`) for echo suppression, plus
  a bleed gate: mic speech whose energy envelope correlates with the remote channel shifted by 0–80 ms is
  discarded. When output goes to the speakers, a chip suggests headphones.
- **Audio format** comes from `SpeechAnalyzer.bestAvailableAudioFormat` rather than a fixed 16 kHz. The
  language is chosen per session (en, it or tr); no automatic language ID is assumed.

### 5.8 Making every call fast [B9, B10, B11, I6, I7]

- **Fixed prompt layout per route** (prefix-cached). Explicit `cache_control` breakpoints only; no top-level auto
  caching:
  1. Frozen system instructions.
  2. Meeting pack → **breakpoint 1**.
  3. Finalized transcript turns as **append-only** message blocks → **breakpoint 2** on the newest finalized
     turn, moved forward at most every few turns so it stays inside the lookback window.
  4. The partial or question text, after the last breakpoint.
- **One fixed settings tuple per route,** used byte-for-byte by the pre-warm and the keep-alive too:
  - S/F: `claude-haiku-5-5`, effort low, thinking disabled.
  - D: `claude-sonnet-5-5`, effort medium, thinking `between_tools` unless the eval shows adaptive thinking is
    clearly better (adaptive likely misses p90).
- **Pre-warm** both models at session start (`max_tokens: 0`, non-streaming). Re-warm with a keep-alive before the
  5-minute TTL during long silences. Log `cache_read_input_tokens` on every call; use the cache-diagnosis beta
  while tuning.
- **Plain-text streamed output, not JSON** [I6]: lines like `SAY: …`, `- …`, `BANK: …`, `OPENER_OK`. They can be
  parsed and rendered word by word, and pre-warming stays allowed (structured outputs can't use
  `max_tokens: 0`).
- **Warm transport** [B10]: `httpx.AsyncClient(http2=True)` with `keepalive_expiry` around 300 s, passed to the SDK
  client, plus a periodic tiny keep-alive. The Python side runs unbuffered (`-u`, explicit flush), and only
  deltas cross the IPC.
- **Rate limits** [B11]: a client-side token bucket per model, kept below the org's limit. `max_retries=0` on S
  and F, because a stale opener is worse than none; one retry on D. Measure the credit-only org's tier on day 1.
- **Optional later** [I7]: move the S/F path to Swift (raw HTTP streaming). The latency gain is small; the value
  is removing a failure surface.

### 5.9 Reading flow on screen

```
┌─ Verse ────────────────────────────────────── ◉ en · for you ─┐
│ SAY  "In my last role I built exactly that pipeline —"        │  ← P / S / F opener (large)
│  • schema-validated extraction + one retry                    │
│  • low-confidence fields go to an operator                    │
│  [€42K budget · prep note]  [ARGO · glossary]                 │  ← C fact chips
│ ┄ Sonnet ┄ • for credit data the decision stays in code (prep)│  ← D points (OPENER_OK)
└───────────────────────────────────────────────────────────────┘
```

Text appears without entrance animations, because a spring adds 150–300 ms of perceived delay. Later the
teleprompter's voice-activated scroll follows the owner's voice through this text.

### 5.10 Units and interfaces

```
[AudioCapture: process tap + mic(VP)] → [Transcriber] → volatile partials → [Matcher] [FactChips] [Addressee]
                                               │                                         │
                                               └→ [TurnDetector: predictive endpoint] ───┤
                                                                                         ↓
                     [Brain (Python, Anthropic SDK): Speculator(≤3) · Fast · Deep · Summarizer]
                                               ↑                                         │ text-line deltas
                 [Prep stage → AnswerBank · FactSheet · Glossary · Snippets · MeetingPack]  ↓
                                                                                   [Overlay (SwiftUI)]
```

- **IPC:** stdin/stdout, one JSON envelope per line, carrying text deltas. Swift → brain: `partial`, `turn`,
  `bank_hit`, `addressee`, `control`. Brain → Swift: `delta{id, tier, line}`, `opener_status{id, ok}`,
  `actions`, `status`.
- **Settings:** API key from Personal API Org (Keychain), languages, repos, vault path, thresholds, and spend
  this month (from `usage`).

## 6. Latency targets (from acoustic end; per-stage logs)

| Path | p50 | p90 |
|---|---|---|
| Bank hit or fact chips visible | ≤ 0.3 s | ≤ 0.4 s |
| Correct speculation → opener visible | ≤ 0.3 s | ≤ 0.5 s |
| No hit, fresh Haiku → first word | ≤ 2.0 s | ≤ 2.8 s |
| Sonnet deep points, first words (thinking off) | ≤ 2.0 s | ≤ 3.0 s |

Stage estimates from the critique, partly measured on this Mac:
- request floor on a reused connection: ~165 ms (measured);
- a cold connection: +60–160 ms (measured);
- endpoint decision: ~300 ms;
- Haiku server time to first token, cached: ~300 ms (unconfirmed);
- Sonnet with `between_tools`: ~600 ms (unconfirmed).

**Day-1 benchmark, before any UI is built:**
- Haiku and Sonnet time to first token, cold and warm, thinking on and off;
- SpeechAnalyzer partial delay for en, it and tr (and whether Turkish is available);
- the org's rate-limit tier;
- the Brave process-tap capture.

If any target is out of reach, the spec is revised with the measured numbers before building on.

Estimated cost (critique, unmeasured): about $2–4 per meeting including prep, against the $200 monthly credit.


### 6.1 Phase 0 outcome (2026-10-14, accepted by Alex)

Measured in `bench/RESULTS.md`. The F target was revised from 1.1 / 1.8 s to **2.0 / 2.8 s**: the measured sum is
ASR lag 0.3–0.8 s + endpoint 0.3 s + Haiku first line 1.1 s. P and S remain the paths that beat it. Decisions now
fixed:
- D uses `thinking: {type: "between_tools"}`; adaptive thinking is rejected (p90 2.4 s, one 6.4 s stall).
- S/F send `thinking: {type: "disabled"}` explicitly; without it Haiku thinks on every call (+1.1 s).
- **Transport:**
  - A warm HTTP/2 client per model via `anthropic.DefaultAsyncHttpxClient(http2=True, limits=…keepalive_expiry=300)`;
    SDK 1.x runs on `httpx2`.
  - A `count_tokens` ping every ~30 s.
  - No new connection at t = 0.
  - A hedged duplicate request if there is no first byte after 1.5 s: 5–8 % of fresh connections stall 10–50 s
    on this network.
- **Cache keep-alive** (`max_tokens: 0`) every ~4 minutes of silence; entries expired after a 390 s idle.
- **Act on volatile text only.** Italian finals take 3.5–8.7 s. `?` is not a cue (it arrives 0.9–1.6 s late).
- **Turkish** uses DictationTranscriber with `.frequentFinalization` (SpeechTranscriber has no tr_TR on this Mac),
  unless the WhisperKit bench wins.
- **Remote audio:** a Core Audio process tap matched by bundle ID; Brave's audio comes from a helper process.
- **Billing:** org `00000000-0000-0000-0000-000000000000`, confirmed by Alex as "Personal API Org".

## 7. Error handling

- **No network or API error:** the overlay shows a small "offline" chip. Turns are queued; only the latest
  question is retried once on reconnect.
- **Refusal (`stop_reason: "refusal"`, e.g. security or AI topics):** Haiku has no server-side fallback, so the
  fast tier shows nothing for that turn and D (Sonnet, with `fallbacks: "default"`) still answers.
- **Rate limit (429):** S/F are dropped silently (no retry); D retries once after `retry-after` if the answer is
  still relevant.
- **Credit exhausted (billing error):** stop calling, show "Max API credit used up until <reset date>", keep
  transcribing locally.
- **Speech recognition unavailable for a language:** fall back to the other language set if possible, otherwise
  show the error and stop the session cleanly.
- **Permission denied (audio recording / process tap, or mic):** a guided message with a deep link to System Settings; no
  silent failure.
- **Brain process crash:** Swift restarts it once with the same pack; on a second crash it stops and saves the
  transcript.
- **`beyin.py` or `git` failure at prep:** start anyway with the sources that worked, and list the missing
  ones in the overlay.

## 8. Test cases

Unit:
- TurnDetector: synthetic transcripts and silence timelines → the exact turn boundaries expected.
- IPC: schema round-trip; malformed lines are rejected without crashing.
- MeetingPack: prep note and repo fixtures → a deterministic pack under the size cap, with sources.
- Text-line parser: recorded streams (`SAY:`, `-`, `BANK:`, `OPENER_OK/WRONG`) → correct deltas; a `none` classification
  shows nothing.
- Matcher: blind paraphrases per language → hit/wrong-hit counts; a hit must survive 2 partials and Haiku's
  `BANK:` check.
- Bleed gate: remote audio played into the mic → no `me` turn.

Replay harness (main evaluation): feed recorded two- and three-speaker audio instead of live capture.
- Material: dialogues Alex records himself or generates with TTS, in en/it/tr, with labelled questions. No
  third-party recordings without consent.
- Measures: latency per step (section 6); question-detection precision and recall; whether each answer point is
  supported by its cited source (checked by an independent model plus spot checks by Alex); API cost per 30
  minutes.

Live:
- A real Google Meet call between the owner's Mac and a second device, once per language.

## 9. Done means (v1 spike, ~1 week)

- In replay and in one live Meet call per language, the targets in section 6 are met, or the measured numbers are
  recorded and accepted by Alex.
- On a **blind** paraphrase set (written by a person or model that never saw the bank), the bank hit rate is
  measured per language with a wrong-hit rate ≤ 5 % at the chosen threshold; Turkish is reported separately.
- Questions addressed to other participants trigger no SAY line in ≥ 90 % of cases on 3-speaker replays.
- Played through the MacBook speakers, the replay produces no false "me" turns from mic bleed.
- Question detection reaches ≥ 80 % precision and recall on the labelled replay set, counting only questions
  addressed to Alex.
- No suggestion states a number, date or fact that is absent from its cited source in the replay set.
- No audio file is written anywhere (checked by a filesystem watch during a session).
- The API key never appears in logs or files (grep check).
- The cost per 30-minute meeting is measured and shown in Settings.

## 10. Later specs (out of scope here)

- **Teleprompter mode:** voice-activated scroll, word tracking (port Textream's MIT `SpeechTextAlignment`,
  `VoiceActivityDetector` and language detection with the notice), and hide-from-screen-share tested against Meet,
  Zoom and Teams.
- **Other users' model access:** BYOK keys, OpenRouter OAuth, and ChatGPT sign-in if OpenAI approves (interest
  form).
- **iOS app:** mic-only (iOS cannot capture other apps' call audio), so the target is in-person meetings,
  presentations and on-camera recording.
- **Paid app where we choose the model:** a server-side proxy holds our Anthropic key and a StoreKit subscription
  gates access. Never embed a key in an app binary. Before using the owner's Max API credit to serve other users,
  check Anthropic's terms.
- **Brain in Swift:** port once prompts are stable (raw HTTP, no official SDK).

## 11. Open questions (to settle in the spike)

- Whether a Core Audio process tap captures Brave's Meet audio (spike item #1). If not, does ScreenCaptureKit?
- SpeechAnalyzer: is Turkish available on this macOS build, and what are the partial delays for en, it and tr?
- Haiku and Sonnet time to first token from this Mac, cached and cold; whether adaptive thinking on Sonnet is
  worth its latency.
- The rate-limit tier of the credit-only Individual Org.
- Turkish matching quality: does `NLContextualEmbedding` add anything over character n-grams?
- Whether closing a stream stops output billing immediately.
- Keep-alive defaults in the installed Anthropic SDK version (the critique saw 0.54 locally; pin to a current
  1.x version and pass the custom httpx client).
