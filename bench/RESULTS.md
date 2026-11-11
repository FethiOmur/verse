# Verse Phase 0 results and verdict (2026-10-14)

Detailed files: `api/RESULTS_api.md`, `speech/RESULTS_speech.md`, `audio/RESULTS_audio.md`,
`stt-local/RESULTS_stt_local.md` (the English recognition engine the app and the eval use). The WhisperKit Turkish
bench did not run: it is blocked because the model is not on disk (`whisper/RESULTS_whisper.md`). Updated 2026-11-11 (review items B1, B2): the English recognition rows now show both Apple voices and the
`stt-local` engine comparison, and the adaptive-thinking argument now shows both `between_tools` runs. No new
measurement was made; every new number below is copied from the file named in its Source column. The main session
checked the key results files, confirmed no
leftover processes, confirmed that no test audio remains, and confirmed that the API key appears in no file
under `bench/`.

## Measured inputs

| Stage | p50 | p90 | Source |
|---|---|---|---|
| Last word in volatile text: en, Apple SpeechTranscriber `.fastResults`, Samantha (clean control voice) | 0.28 s | 0.83 s | speech (WER 0.5 %) |
| Last word: en, Apple `.fastResults`, Albert (the voice in the brief) | 0.71 s | 1.41 s | speech (`en (Albert)` row: 714 / 1406 ms, WER 40.3 %); `stt-local` re-run gives 0.72 / 1.42 s |
| Last word: en, Nemotron 0.6B (CoreML, 560 ms chunk), Samantha / Albert | 0.15 s / 0.12 s | 0.37 s / 0.39 s | stt-local (main table: 145 / 370 and 124 / 386 ms; WER 0.0 % / 12.2 %) |
| Last word: en, Moonshine Medium Streaming, Samantha / Albert | 0.42 s / 0.79 s | 0.74 s / 0.98 s | stt-local (419 / 735 and 790 / 980 ms; WER 0.0 % / 37.2 %; 75-111 % of one core) |
| Nemotron final result (trailing `?` / `.`) | 3.1 s late | 3.3 s | stt-local (3127 / 3344 ms Samantha; the punctuation arrives when the next speech starts) |
| Nemotron model load | 16-21 s every process start, no warm benefit | | stt-local ("Model load time": 20.8 s cold; 15.6, 17.8, 21.5 s warm) |
| Last word: it (Alice, `.fastResults`) | 0.79 s | 1.11 s | speech |
| Last word: tr (Yelda, DictationTranscriber + `.frequentFinalization`) | 0.52 s | 0.65 s | speech (WER 18 %); **open decision, see item 8** |
| Final results, Italian | 3.5 s | 8.7 s | speech → never wait for finals |
| `?` punctuation after acoustic end | +0.9 s (en) / +1.6 s (it) | | speech → not a cue |
| Haiku 5.5 TTFT, warm, cached, thinking disabled | 0.93 s | 1.04 s | api |
| Haiku first `SAY:` line | 1.12 s | 1.42 s | api |
| Sonnet 5.5 `between_tools` TTFT, standalone run (n = 15) | 0.92 s | 1.05 s (max 1.05 s) | api (`api/results/api-20261014-025859.json`, `sonnet_between_tools`) |
| Sonnet 5.5 `between_tools` TTFT, interleaved with the other routes (`cmp:sonnet_bt`, n = 10) | 0.70 s | 2.52 s (max 2.83 s) | api (same file, `table_text` row `cmp:sonnet_bt`) |
| Sonnet `between_tools` first `- ` point | 1.62 s | 2.05 s | api |
| Sonnet adaptive (medium) TTFT (n = 15) | 0.80 s | 2.43 s (max 6.4 s) | api; thinking block on 3/15 calls, so adaptive is rejected (item 1), not because of the p90 alone |
| Haiku with adaptive thinking (low) | 2.0–2.3 s | | api → thinking must be disabled explicitly |
| Warm round trip with no inference | 0.24 s | | api |
| Fresh-connection stalls | 5–8 % of new connections stall 10–50 s | | api (curl reproduces it) |
| Remote audio via process tap (Brave helper) | +32 ms delivery | | audio |
| Rate limits (org `00000000…`) | 1,000 RPM, 2 M ITPM, 400 K OTPM | | api → B11 risk small |
| Cache | read on 30/30 warm calls; expired after a 390 s idle | | api |

## Verdict per spec §6 target (t = acoustic end)

| Target | Verdict | Realistic number | Change |
|---|---|---|---|
| Bank hit / fact chips: 0.3 / 0.4 s | **met when the question is recognised from its early words**; otherwise ASR lag + endpoint | en ~0.3–0.6 s with Apple (Nemotron's last word is 0.15 / 0.37 s, see Measured inputs), it ~0.8–1.1 s | None in design. In Italian the hit usually shows before t = 0 only with early matching |
| Correct speculation → opener: 0.3 / 0.5 s | **met only if S fired ≥ ~1.4 s before the end** (Haiku first SAY line is 1.1 s p50 after the request, plus ASR lag) | long questions yes, short ones no | Fire S earlier (≥ 4 words plus a question cue), up to 3 in flight |
| Fresh Haiku: 1.1 / 1.8 s | **out of reach** | ASR 0.3–0.8 + endpoint 0.3 + Haiku 1.1 ≈ **1.7–2.2 s p50, ~2.8 s p90** | New target p50 ≤ 2.0 s, p90 ≤ 2.8 s; P and S are the paths meant to beat it |
| Sonnet points: 2.0 / 3.0 s | **met with early Sonnet** (fired on a stable partial, I3); otherwise ~2.4 s p50 | 1.6 s after request | Keep the target; fire D early |

## Design decisions from the measurements

1. **Sonnet D uses `thinking: {type: "between_tools"}`.** Adaptive thinking emitted a thinking block on 3 of 15 calls
   and had one 6.4 s stall without thinking; `between_tools` emitted none (0/15) and its worst TTFT in that run was
   1.05 s (`api/results/api-20261014-025859.json`: 3 of the 15 `sonnet_ad` calls list `thinking` in `block_types`, none of the
   `sonnet_bt` calls do). The p90 is **not** the argument: `between_tools` has p90 1.05 s in the standalone run (n = 15) but
   2.52 s (max 2.83 s) in the interleaved `cmp:sonnet_bt` run (n = 10), about adaptive's 2.43 s. With 10-15 calls per row
   the p90 difference is noise. The decision does not change.
2. **Haiku uses `thinking: {type: "disabled"}` explicitly.** Without it Haiku thinks on every call (+1.1 s).
3. **Haiku is not faster to the first token than Sonnet `between_tools`** (both ~0.9 s). It is twice as fast per
   output token and 20× cheaper. Keep it for S/F, where the fan-out and cost matter.
4. **Never open a connection at t = 0.**
   - Keep a warm HTTP/2 connection per model (`anthropic.DefaultAsyncHttpxClient(http2=True, limits=…keepalive_expiry=300)`;
     the SDK 1.x needs `httpx2`, not plain `httpx`).
   - Ping it with `count_tokens` every ~30 s.
   - **Hedge:** if a call has no first byte after 1.5 s, fire a duplicate on a second warm connection and take the
     first one to answer. This covers the 10–50 s stalls.
5. **Cache keep-alive** with a `max_tokens: 0` request every ~4 minutes during silence. Entries expire after 5
   minutes (an idle of 390 s missed).
6. **Act only on volatile text,** never on finals. Italian finals take 3.5–8.7 s (Apple); Nemotron's finals are 3.1 s late in English.
7. **Question-end cues** come from words and pitch, not from `?` (Apple: `?` +0.9 s; Nemotron: `?` ~3.2 s after the end, `stt-local`).
8. **Turkish recognition is an open decision.** DictationTranscriber (`.frequentFinalization`) is the only measured Turkish
   engine (0.52 / 0.65 s last word, WER 18 %, Yelda; `speech/RESULTS_speech.md`). The WhisperKit comparison could not be run:
   the model is not on disk and was not downloaded (`whisper/RESULTS_whisper.md`, "BLOCKED"). SpeechTranscriber has no Turkish
   on this Mac. Nemotron and Moonshine were measured on English only (`stt-local`). The owner has not chosen a Turkish engine.
9. **The process tap is matched by bundle ID** (Brave's audio comes from a helper process, and the main process
   runs from a code-sign clone path). Tell "no permission" from "silence" via the TCC status plus
   `isRunningOutput`.
10. **English recognition engine: Nemotron 0.6B (CoreML, 560 ms chunk), not Apple SpeechTranscriber.** Evidence: `stt-local/RESULTS_stt_local.md`
    (last word 0.15 / 0.37 s against Apple's 0.30 / 0.82 s on the clean voice; Albert WER 12.2 % against Apple 40.3 % and Moonshine 37.2 %;
    3 % CPU, 0.6 GB RAM). Costs: a 16-21 s load at every process start (the eval gives each dialogue a lead-in for that, `eval/report.py` Setup) and finals that
    arrive ~3.1 s late, which is why item 6 holds. Synthetic `say` voices only. The Apple rows above are the control, not the engine the app uses (`eval/report.py` Setup).

## Open items

- the owner: confirm that org `00000000-0000-0000-0000-000000000000` is "Personal API Org" (Console → Settings).
- Optional: is output billed after a cancel? Compare `req_000000000000000000000000` (cancelled) and
  `req_000000000000000000000000` (control) in the Console logs.
- Not yet tested: the mic-bleed test on speakers, silence while paused, the bundle-ID tap route, and the
  permission prompt for a fresh app identity.
- Turkish recognition engine: open decision (item 8). The WhisperKit bench needs the model reinstalled (`whisper/RESULTS_whisper.md`,
  "What is needed to unblock"). TypeWhisper learnings: pending.
- Spend so far: about $0.60 (Phase 0 API).
