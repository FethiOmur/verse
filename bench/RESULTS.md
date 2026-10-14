# Verse Phase 0 results and verdict (2026-10-14)

Detailed files: `api/RESULTS_api.md`, `speech/RESULTS_speech.md`, `audio/RESULTS_audio.md`. The WhisperKit Turkish
bench is pending in `whisper/RESULTS_whisper.md`. The main session checked the key results files, confirmed no
leftover processes, confirmed that no test audio remains, and confirmed that the API key appears in no file
under `bench/`.

## Measured inputs

| Stage | p50 | p90 | Source |
|---|---|---|---|
| Last word in volatile text: en (Samantha, `.fastResults`) | 0.28 s | 0.83 s | speech |
| Last word: it (Alice, `.fastResults`) | 0.79 s | 1.11 s | speech |
| Last word: tr (Yelda, DictationTranscriber + `.frequentFinalization`) | 0.52 s | 0.65 s | speech (WER 18 %) |
| Final results, Italian | 3.5 s | 8.7 s | speech → never wait for finals |
| `?` punctuation after acoustic end | +0.9 s (en) / +1.6 s (it) | | speech → not a cue |
| Haiku 5.5 TTFT, warm, cached, thinking disabled | 0.93 s | 1.04 s | api |
| Haiku first `SAY:` line | 1.12 s | 1.42 s | api |
| Sonnet 5.5 `between_tools` TTFT | 0.92 s | 1.05 s | api |
| Sonnet `between_tools` first `- ` point | 1.62 s | 2.05 s | api |
| Sonnet adaptive (medium) TTFT | 0.80 s | 2.43 s (max 6.4 s) | api → reject adaptive |
| Haiku with adaptive thinking (low) | 2.0–2.3 s | | api → thinking must be disabled explicitly |
| Warm round trip with no inference | 0.24 s | | api |
| Fresh-connection stalls | 5–8 % of new connections stall 10–50 s | | api (curl reproduces it) |
| Remote audio via process tap (Brave helper) | +32 ms delivery | | audio |
| Rate limits (org `00000000…`) | 1,000 RPM, 2 M ITPM, 400 K OTPM | | api → B11 risk small |
| Cache | read on 30/30 warm calls; expired after a 390 s idle | | api |

## Verdict per spec §6 target (t = acoustic end)

| Target | Verdict | Realistic number | Change |
|---|---|---|---|
| Bank hit / fact chips: 0.3 / 0.4 s | **met when the question is recognised from its early words**; otherwise ASR lag + endpoint | en ~0.3–0.6 s, it ~0.8–1.1 s | None in design. In Italian the hit usually shows before t = 0 only with early matching |
| Correct speculation → opener: 0.3 / 0.5 s | **met only if S fired ≥ ~1.4 s before the end** (Haiku first SAY line is 1.1 s p50 after the request, plus ASR lag) | long questions yes, short ones no | Fire S earlier (≥ 4 words plus a question cue), up to 3 in flight |
| Fresh Haiku: 1.1 / 1.8 s | **out of reach** | ASR 0.3–0.8 + endpoint 0.3 + Haiku 1.1 ≈ **1.7–2.2 s p50, ~2.8 s p90** | New target p50 ≤ 2.0 s, p90 ≤ 2.8 s; P and S are the paths meant to beat it |
| Sonnet points: 2.0 / 3.0 s | **met with early Sonnet** (fired on a stable partial, I3); otherwise ~2.4 s p50 | 1.6 s after request | Keep the target; fire D early |

## Design decisions from the measurements

1. **Sonnet D uses `thinking: {type: "between_tools"}`.** Adaptive thinking gave p90 2.4 s and a 6.4 s stall.
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
6. **Act only on volatile text,** never on finals. Italian finals take 3.5–8.7 s.
7. **Question-end cues** come from words and pitch, not from `?`.
8. **Turkish recognition** uses DictationTranscriber (`.frequentFinalization`) unless WhisperKit wins the
   pending bench. SpeechTranscriber has no Turkish on this Mac.
9. **The process tap is matched by bundle ID** (Brave's audio comes from a helper process, and the main process
   runs from a code-sign clone path). Tell "no permission" from "silence" via the TCC status plus
   `isRunningOutput`.

## Open items

- Alex: confirm that org `00000000-0000-0000-0000-000000000000` is "Personal API Org" (Console → Settings).
- Optional: is output billed after a cancel? Compare `req_000000000000000000000000` (cancelled) and
  `req_000000000000000000000000` (control) in the Console logs.
- Not yet tested: the mic-bleed test on speakers, silence while paused, the bundle-ID tap route, and the
  permission prompt for a fresh app identity.
- WhisperKit Turkish bench and TypeWhisper learnings: pending.
- Spend so far: about $0.60 (Phase 0 API).
