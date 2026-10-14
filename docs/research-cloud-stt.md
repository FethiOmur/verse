# Cloud real-time STT vs Apple on-device (English-first meeting assistant)

Date: 2026-10-14. Research only: no sign-ups, no API calls. "Vendor" = vendor's own claim; "Coval" = third-party benchmark (benchmarks.coval.ai, 30-day averages, open-source runner, shared VAD marks end of speech, connection setup excluded).

Baseline (measured here): Apple SpeechTranscriber + fastResults, EN: last word in volatile text p50 0.28 s / p90 0.83 s after acoustic end; WER 0.5 % (clean synthetic); finals ~1.0 s. Cloud adds ~165 ms RTT floor from this Mac, and 5-8 % of fresh TCP/TLS connects stall 10-50 s, so every option below must keep one warm WebSocket.

Scope note from Alex: OpenAI Realtime was already tried in Trailhead and felt slow, so it is kept in the table but not researched deeply. Italian/Turkish are a column only.

## Comparison

| Option (model) | Latency, published (how measured) | Partials / turn end | Price per hour (list) | Privacy / EU | it / tr (column only) | Integration |
|---|---|---|---|---|---|---|
| Deepgram Flux EN (`flux-general-en`, `/v2/listen`) | Coval TTFS p50 98 ms, avg 99 ms, WER 5.8 % (end-of-speech to final; excludes connect). Vendor: ~260 ms end-of-turn, EoT 100-500 ms; "transcription latency 150-300 ms" before network. | `Update` events about every 0.25 s of audio; model-integrated `EagerEndOfTurn`/`EndOfTurn`/`TurnResumed`; word timestamps | $0.39 (promo $0.0065/min; regular $0.0077/min = $0.46) | EU endpoint `api.eu.deepgram.com`; `mip_opt_out=true` to stay out of training; default retention not stated on pages read | it: Flux Multilingual yes (10 langs incl. it); tr: not in Flux list | WS, linear16 etc, 80 ms chunks recommended; Python SDK; Swift = raw URLSessionWebSocketTask |
| Deepgram Nova-3 (`/v1/listen`) | Coval TTFS avg 85 ms (p50 90), WER 5.3 % | interim results + endpointing (turn end is VAD-style, not model-integrated) | $0.29 (promo $0.0048/min; regular $0.46) | same as above | it/tr: unconfirmed for streaming | WS; same |
| AssemblyAI Universal-3.6 Pro Realtime | Coval TTFS avg 136 ms (p50 124), WER 2.2 % (best in table). Vendor blog: median endpoint latency 537 ms (sentence ambiguous, not re-verified); earlier U-3 Pro: ~150 ms p50 after VAD endpoint (vendor) | `Turn` messages repeated while speaking (partial words with `word_is_final`), `end_of_turn` with confidence; keyterms included | $0.45 (Universal-Streaming EN/multi $0.15) | EU Data Zone `wss://streaming.eu.assemblyai.com/v3/ws` (processing stays in EU, per docs); retention/training for streaming not stated on page read | it: Universal-Streaming Multilingual lists it; tr: unconfirmed (U-3.6 says 32 langs) | WS `/v3/ws`, binary PCM, key in header; billed on connection time, 3 h session cap, must send `Terminate` |
| Gemini 3.5 Transcribe Live (Gemini Live API, input transcription) | Coval TTFS avg 317 ms (p50 295), WER 3.0 % | `input_transcription` events in the Live stream; chunk granularity unconfirmed | ~$0.54 ($0.005/min audio in + ~$0.004/min text out; Google estimate $0.009/min) | Paid tier "used to improve our products: No"; free tier yes. EU residency on the Developer API: unconfirmed | it/tr: unconfirmed | WS (Trailhead already uses Gemini Live); 16 kHz PCM; ephemeral tokens for client auth |
| Speechmatics RT (Standard / Enhanced / Linden 1) | Vendor: partials < 500 ms, finals from `max_delay` 0.7 s (range 0.7-4 s, default 4). Coval (Linden 1): TTFS avg 270 ms, WER 3.9 % | `enable_partials`; partials revised; finals never revised; turn detection feature exists | Standard $0.45 ($0.30 with training opt-in discount); Enhanced $0.80; Linden 1 $0.30 | EU endpoint `wss://eu.rt.speechmatics.com/v2`; vendor: real-time inputs/outputs never stored, not used for training unless you opt into the discount | it: yes (long-standing); tr: unconfirmed | WS; `speechmatics-rt` Python; JS client |
| Google Cloud STT v2 Chirp 3 | Coval TTFS avg 768 ms (p50 758), WER 3.2 % | `interim_results` flag, endpointing sensitivity levels, voice-activity events; utterance-level timestamps in streaming | $0.96 ($0.016/min first 500k min) | `eu` multi-region GA; data logging opt-out reportedly +40 % (third party, unconfirmed) | it: unconfirmed here | gRPC streaming (no plain WS): awkward from Swift |
| OpenAI `gpt-live-transcribe` (Realtime, `type: transcription`) | Alex: slow in Trailhead. Coval has `gpt-realtime-whisper` TTFS 599 ms, WER 4.0 %; gpt-live-transcribe not in Coval list read. Vendor: `delay` setting minimal..xhigh trades latency for WER | `...transcription.delta` events; server/semantic VAD NOT supported on this model: client VAD + manual `input_audio_buffer.commit`; no timestamps/confidence/speakers | $1.02 ($0.017/min); EU residency +10 % | 30-day abuse logs by default; no training by default; ZDR by approval; `eu.api.openai.com` | `languages` hint, ISO codes | WS (server) or WebRTC; 24 kHz PCM |

Sources: OpenAI docs (realtime-transcription, models/gpt-live-transcribe, your-data); developers.deepgram.com (flux quickstart/state/language-prompting, MIP); deepgram.com/pricing; assemblyai.com/pricing and docs (streaming quickstart, endpoints-and-data-zones); docs.speechmatics.com (realtime quickstart/output); speechmatics.com/pricing; ai.google.dev pricing (via search snippet) and Live API capabilities; docs.cloud.google.com Chirp 3; benchmarks.coval.ai/benchmarks/time-to-final-segment.

## Reading the numbers honestly

- Coval TTFS = end-of-speech (their shared VAD) to FINAL transcript, runner location unknown, connect excluded. Our Apple number = acoustic end to last word visible in a volatile (partial) result, from this Mac. Not the same metric, and not the same network path.
- Rough cloud estimate for a partial showing the last word: audio chunking (50-80 ms) + uplink/downlink (~80-165 ms) + model delay (~100-300 ms) = about 0.25-0.55 s p50. A cloud FINAL (Deepgram ~0.1 s + RTT) is about 0.2-0.3 s, versus Apple finals at ~1.0 s.
- Tails: Coval max TTFS for Nova-3 19 s, Flux 17 s, U-3.6 13 s, Gemini 5 s (these are rare outliers, but they exist). Add this Mac's 5-8 % fresh-connect stalls (so reconnect logic and a warm standby socket are needed).

## Verdict

1. Beating 0.28 s p50 last-word lag with a cloud API: unlikely. The best candidates (Deepgram Nova-3/Flux, AssemblyAI U-3.6) have ~0.1 s model-side latency, but 80-165 ms network plus chunking leaves them about level with Apple at best (my estimate, not measured), and tails are worse. Do not switch the live-caption path to cloud for speed.
2. Where cloud does win: finals. Deepgram/AssemblyAI finals could land ~0.2-0.4 s after speech end against Apple's ~1.0 s, plus Flux's model-based end-of-turn. If the product needs fast, reliable turn-end for the brain, that is the real gain.
3. Best accuracy fallback for noisy/compressed meeting audio: AssemblyAI Universal-3.6 Pro Realtime (Coval WER 2.2 % across mixed datasets including phone-codec, far-field, noise; $0.45/h; EU data zone). Runner-up: Gemini 3.5 Transcribe Live (3.0 %, ~$0.54/h, already integrated in Trailhead, but EU/retention terms need checking). Cheapest sensible: Deepgram Nova-3 at $0.29/h (5.3 %, fastest finals). Best privacy posture on paper: Speechmatics (no storage of real-time audio, EU endpoint), at $0.45/h.
4. Recommended shape: Apple on-device stays primary (free, private, 0.28 s). Cloud STT is an opt-in "high accuracy" mode only, one persistent WebSocket, run in parallel on selected meetings. Needs explicit owner consent for audio leaving the Mac, and it is extra cost outside the Claude Max credit (about $0.29-0.54 per meeting hour; a 20 h/month user pays about $6-11).
5. Before any decision, run a 30-minute bake-off on the owner's own recorded meeting audio (needs keys, so not done here).

## Unconfirmed (where I looked)

- Per-dataset WER for noisy/codec audio: only the Coval aggregate was read; the per-dataset WER table was not scraped.
- gpt-live-transcribe measured latency: not in Coval list read; the owner's Trailhead experience is the only data point.
- Whether Gemini Live input transcription streams word by word; Developer API EU residency; Gemini language coverage for it/tr (ai.google.dev model page for Transcribe Live returned 404; pricing came from a search snippet of the pricing page).
- AssemblyAI streaming retention/training policy (EU data-zone page is silent); the "537 ms median endpoint latency" sentence is from a search snippet only.
- Deepgram default retention period and whether training is default-on (MIP page implies opt-out but does not say so directly); Nova-3 streaming it/tr support.
- Turkish for every vendor; Italian for Chirp 3 and OpenAI (not checked, per instruction).
- Chirp 3 15-second billing rounding and +40 % logging opt-out surcharge (third-party articles only).
- Promo prices (Deepgram Nova-3/Flux) are "limited-time"; regular rates are shown in the table.
