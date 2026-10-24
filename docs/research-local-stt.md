# Local streaming STT for Apple Silicon: research and benchmark shortlist

Date: 2026-10-14. Research only: nothing downloaded or installed (HF file sizes read from the public HF API metadata, GitHub via `gh api`, pages via firecrawl).
Priority from the owner: **English first, Italian second, Turkish last (list only)**.
Baseline to beat (Apple SpeechTranscriber/DictationTranscriber, `bench/speech/RESULTS_speech.md`): en last-word lag p50 0.28 s / p90 0.83 s, WER 0.5 % (Samantha); it 0.79 / 1.11 s, WER 0 % (Alice); tr 0.52 / 0.65 s, WER 18 % (Yelda, Dictation).

## How to read the numbers

- "Self-reported" = vendor model card or vendor README. "Third-party" = someone else measured on Apple hardware. "Leaderboard" = Hugging Face Open ASR Leaderboard values copied into the model card (RTFx there is GPU, not Apple Silicon).
- A streaming model's **chunk size is a floor on latency, not the latency itself**: a 1.12 s chunk means a word can reach you up to ~1.12 s plus compute after it is spoken. None of the vendors publish "last word lag vs acoustic end" in our metric. That is exactly what the bench must measure.
- WERs are not comparable across rows unless the dataset matches (LibriSpeech test-clean is much easier than the Open ASR 8-set average, FLEURS is multi-domain with digits).

## Comparison table (English / Italian / Turkish)

| Model | en | it | tr | Published WER (source) | Streaming + latency | Size on disk / RAM | Runtime + Swift path | Licence | Maturity |
|---|---|---|---|---|---|---|---|---|---|
| **Nemotron Speech Streaming 0.6B (en)** (NVIDIA) | yes | no | no | Open ASR 8-set avg 6.93 % @1.12 s, 7.07 @0.56, 7.67 @0.16, 8.43 @0.08 (NVIDIA card, self-reported). CoreML port on LibriSpeech test-clean: 2.28 % @560 ms, 2.28 % @1120 ms, 2.46 % @2240 ms, 100 files (FluidAudio, third-party) | Native cache-aware streaming; chunks 80/160/560/1120 ms (NVIDIA); FluidAudio ships 560/1120/2240 ms. RTFx 42 / 65 / 94 on M5 Pro (FluidAudio) | CoreML ~627 MB per tier folder; RAM not published (unconfirmed) | CoreML/ANE, **FluidAudio** SwiftPM (`StreamingNemotronAsrManager`), CLI `fluidaudiocli nemotron-benchmark` | NVIDIA Open Model License (commercial OK per NVIDIA, I did not read the full text) | New (2026), actively maintained |
| **Nemotron 3.5 ASR Streaming 0.6B** (NVIDIA, 2026-06-04) | yes | yes | yes (listed "transcription-ready") | FLEURS WER with language given: en 9.43 / 8.88 / 8.27 / 7.99 / 7.91 %, it 5.23 / 4.85 / 4.83 / 4.41 / 4.25 %, tr 12.34 / 12.33 / 12.05 / 11.34 / 11.17 % at 80 / 160 / 320 / 560 / 1120 ms (NVIDIA, self-reported). CoreML port, FLEURS full test: en 8.89 %, it 5.45 % @1 s tier; it 5.41 % @2 s tier (FluidAudio, third-party). tr not in the ship matrix of the CoreML port | Native cache-aware streaming, 80 ms to 1.12 s chunks. CoreML on M5 Pro: ~103-109 RTFx @1 s tier (Latin ships). speech-swift bundle: 320 ms chunk, p50 chunk latency 18.6 ms, RTF 0.068, RSS peak 1238 MB (third-party card, M5 Pro) | HF `nvidia/...`: 2.55 GB safetensors / 742 MB `q8_0.gguf`. CoreML Latin tier ~611 MB (566 encoder); CoreML INT8 (speech-swift) 612 MB; MLX 5-bit 564 MB; MLX 8-bit 768 MB | CoreML/ANE or MLX. **speech-swift** (`NemotronStreamingASR`, `speech transcribe --engine nemotron --language it-IT`), **FluidAudio** (`fluidaudiocli nemotron-multilingual-transcribe`), or NVIDIA **NeMo-Speech.cpp** (ggml, Metal build option) | OpenMDW-1.1, "ready for commercial use" (NVIDIA card) | Very new (4 months); two independent Swift ports |
| **Moonshine Medium/Small/Tiny Streaming** (Moonshine AI) | yes | **no** | no | Open ASR 8-set avg: Medium 6.65 %, Small 7.84 %, Tiny 12.00 % (float reference, Moonshine v2 paper/README, self-reported). Shipped quantized: LibriSpeech test-clean 2.17 / 2.61 / 4.83 % | Native streaming, sliding-window encoder. Time to final transcript after speech ends, MacBook Pro: Medium 59 ms, Small 38 ms, Tiny 18 ms (self-reported, measured with their own harness, not our metric) | Medium 245M params; HF safetensors 1.06 GB (fp32); shipped quantized `.ort` size not read (unconfirmed). RAM unconfirmed | ONNX Runtime C++ library; Swift package `moonshine-ai/moonshine-swift` (macOS/iOS), Python `pip install moonshine-voice`, CLI `moonshine-voice mic --language en` | MIT for code and all streaming models | Active (666 commits, 11k stars), v2 paper Feb 2026 |
| **Voxtral Mini 4B Realtime 2602** (Mistral) | yes | yes | **no** (13 langs: ar de en es fr hi it nl pt zh ja ko ru) | FLEURS WER @480 ms: en 4.90 %, it 3.27 %; @960 ms: en 4.34, it 2.46; @240 ms: en 5.91, it 4.41; offline sibling en 3.32 / it 2.17 (Mistral card, self-reported). Open ASR avg 7.68 (leaderboard entry on the card). Long-form en: E-22 12.30 %, TEDLIUM 3.17 % @480 ms | Native streaming, configurable delay 80 ms to 2.4 s, recommended 480 ms. Needs >12.5 tokens/s to keep up (Mistral). No Apple Silicon latency published (unconfirmed) | BF16 8.86 GB; MLX 6-bit 3.6 GB (`mlx-community/Voxtral-Mini-4B-Realtime-6bit`), 4-bit 3.1 GB. RAM > file size, unconfirmed | **MLX** via `awni/voxmlx` (Python, MIT, mic streaming CLI) or speech-swift `VoxtralASR` target; vLLM server is the vendor-recommended path. llama.cpp/Transformers support only recently added | Apache-2.0 | Weeks-to-months old, community MLX ports |
| **Parakeet Realtime EOU 120M** (NVIDIA) | yes | no | no | LS test-clean 3.61 %, test-other 7.79 %, Open ASR avg 9.30 % (NVIDIA, self-reported). CoreML: LS test-clean 4.88 % @320 ms, 8.23 % @160 ms (FluidAudio, M2, third-party) | Native streaming, 160/320/1280 ms; end-of-utterance token latency p50 160 ms / p90 280 ms (NVIDIA). RTFx 19 @320 ms on M2 | CoreML 440-450 MB per tier | CoreML/ANE, FluidAudio (`parakeet-eou`), speech-swift (`ParakeetStreamingASR`) | NVIDIA Open Model License | Stable since early 2026 |
| **Parakeet TDT 0.6B v3** (NVIDIA) | yes | yes | **no** (25 EU langs + ru, uk; no tr) | FLEURS: en 4.85 %, it 3.00 % (NVIDIA, self-reported); Open ASR avg 6.34 % (RTFx 3333 on GPU). FluidAudio on FLEURS (M-series, own measurement): it 4.0 %, en 5.4 % | **Not true streaming**: offline model; FluidAudio runs it as sliding window (~15 s chunks with overlap) | CoreML encoder 446 MB (int4 299 MB) + ~50 MB; MLX bf16/fp32 2.5 GB | CoreML/ANE via FluidAudio (`SlidingWindowAsrManager`), MLX `mlx-community/parakeet-tdt-0.6b-v3` (`parakeet-mlx`) | CC-BY-4.0 | Mature, widely shipped (VoiceInk, Spokenly etc.) |
| **Parakeet TDT v2 / Unified 0.6B** | yes (en only) | no | no | v2 Open ASR avg ~6.05 % (third-party summary, not re-read); Unified streaming LS test-clean 2.21 % (FluidAudio) | Unified streaming re-encodes `[left|chunk|right]` windows, default 2.08 s latency (FluidAudio doc); v2 is batch | v2 CoreML 446 MB | FluidAudio | CC-BY-4.0 (v2) | v2 mature, Unified new |
| **Kyutai STT 2.6B en / 1B en_fr** | en | no | no | 2.6B Open ASR avg 6.4 % (leaderboard, RTFx 88 on GPU). 1B en_fr WER not read | True streaming but **fixed delay 2.5 s (2.6B) or 0.5 s (1B en_fr)**; 1B has semantic VAD | MLX 2.6B 5.2 GB + Mimi 385 MB; 1B 2.0 GB + 385 MB | MLX Python (`moshi_mlx`), Rust server; no Swift package found | Weights CC-BY-4.0, code Apache-2.0 | Mid-2025, repo last pushed Jan 2026 |
| **Qwen3-ASR 0.6B / 1.7B** (Alibaba) | yes | yes | yes (30 languages listed) | Streaming vs offline (FLEURS-en / LibriSpeech etc.): 0.6B streaming 6.27 / 2.54 vs 4.55 / 2.11 offline; 1.7B streaming 4.51 / 1.95 (Qwen README, self-reported). Per-language it/tr rows in the appendix table are ambiguous in the text I could parse (unconfirmed) | "Offline / Streaming" unified (Qwen README); chunk latency not published | Not read (0.6B ~1.2 GB bf16 by param count, estimate) | speech-swift has `Qwen3ASR` target; `mlx-qwen3-asr` on PyPI; Swift on-device streaming quality unverified | Apache-2.0 (not re-read) | Jan 2026, fast-moving |
| **WhisperKit / Argmax OSS Swift** (Whisper large-v3-turbo, 626 MB CoreML) | yes | yes | yes | Whisper large-v3 FLEURS-en 4.08 % (Qwen table); WhisperKit paper: 2.2 % WER at 0.46 s on an English benchmark, "matches the lowest latency" vs cloud APIs (Argmax paper, **vendor**). Turkish/Italian WhisperKit numbers not found | "Streaming" = repeated re-decode over a rolling buffer (hypothesis text then confirmed); no native cache. Paper: 0.46 s latency | `openai_whisper-large-v3-v20240930_626MB` 626 MB | CoreML, **WhisperKit / argmax-oss-swift** SwiftPM, `argmax-cli transcribe --stream` | MIT | Most mature Swift option |
| whisper.cpp (CoreML/Metal), mlx-whisper, Canary, sherpa-onnx | - | - | - | **Not researched in depth** (time boxed). sherpa-onnx pretrained list searched: no Turkish streaming Zipformer seen in snippets (unconfirmed; page not fully read). Whisper family is offline with pseudo-streaming, not expected to beat the cache-aware models on latency | | | | | |

## English: what the evidence says

1. Best published accuracy at low delay: **Voxtral Realtime** (FLEURS-en 4.90 % @480 ms, 4.34 % @960 ms, Open ASR avg 7.68 %) but it is a 4B model (3.6 GB at 6-bit) with no Apple Silicon latency published; real-time on a MacBook is unproven.
2. **Nemotron Speech Streaming en** has the best accuracy-per-size among cache-aware models (Open ASR 6.93 % @1.12 s, 8.43 % at 80 ms), a CoreML port that runs 42-94x real time on M5 Pro, and it is a drop-in via FluidAudio.
3. **Moonshine Medium Streaming** is the smallest/fastest (Open ASR 6.65 % float, 59 ms to final on a MacBook Pro, MIT). Its caveat: the 6.65 % is measured on float weights in Transformers; quantized LibriSpeech test-clean is within 0.31 % of float, so the gap is small.
4. Kyutai 2.6B is out for us: fixed 2.5 s delay and 5 GB. Parakeet EOU 120M is the cheap fallback (9.30 % Open ASR avg, EOU p50 160 ms) but clearly less accurate.

## Italian: what the evidence says

- No Moonshine Italian model exists (current list: en, ar, de, ja, zh, es, tg, vi, ko, uk).
- Candidates with Italian: **Voxtral Realtime** (FLEURS it 3.27 % @480 ms, 2.46 % @960 ms, self-reported), **Nemotron 3.5** (FLEURS it 4.25 % @1.12 s NVIDIA; 5.41-5.45 % in the CoreML port, third-party, no ITN so digits inflate), **Parakeet TDT v3** (FLEURS it 3.00 % NVIDIA; offline sliding window, not streaming), Qwen3-ASR (lists Italian; numbers unconfirmed), WhisperKit (no number found).
- Apple SpeechTranscriber it is already 0 % WER on a clean synthetic voice, so the question for Italian is latency of finals (Apple p50 3.5 s) and accuracy on real speech, not synthetic WER.

## Turkish (deprioritised, list only)

- **Nemotron 3.5** lists tr-TR as transcription-ready: FLEURS 12.34 % @80 ms down to 11.17 % @1.12 s (NVIDIA, self-reported). The speech-swift CoreML INT8 bundle has a `tr-TR` slot in `languages.json` (read). The FluidAudio CoreML repo's ship matrix does not benchmark tr.
- **Whisper large-v3 family via WhisperKit**: Turkish is supported; an academic study measured Whisper large-v2 at 0.08 WER on FLEURS-tr (MDPI Electronics 13(21) 4227, offline). Not streaming-native.
- **Qwen3-ASR** lists Turkish (numbers unconfirmed).
- `mihuai/turkish-stt` (HF): Turkish-only streaming CPU model, 13.9 % WER on its own read-speech set vs Whisper large-v3 7.08 % (vendor self-report; licence not read; Swift path none). Vosk-TR 34 % (same source).
- No Turkish in Parakeet v3, Voxtral, Moonshine, Kyutai. Sherpa-onnx Turkish streaming Zipformer not found (unconfirmed).
- Apple Dictation tr at 18 % (synthetic) is the number to beat; Nemotron 3.5 tr is the only streaming candidate with a published number.

## Shortlist to benchmark against Apple

### English (3)

| # | Candidate | Exact download | Size | Path to run in our bench |
|---|---|---|---|---|
| E1 | Nemotron Speech Streaming 0.6B en, CoreML | HF `FluidInference/nemotron-speech-streaming-en-0.6b-coreml`, folders `nemotron_coreml_1120ms` (trained chunk) and `nemotron_coreml_560ms` | 627 MB per folder | SwiftPM `https://github.com/FluidInference/FluidAudio` (Apache-2.0), `StreamingNemotronAsrManager` with `NemotronChunkSize.ms1120` / `.ms560`; quick CLI check `swift run -c release fluidaudiocli nemotron-benchmark --chunk 1120`. Feed 50 ms buffers in our existing real-time loop and stamp partials |
| E2 | Moonshine Medium Streaming | via library downloader (catalog `medium-streaming` en, auto-download on first `load()`); safetensors reference `moonshine-ai/moonshine-streaming-medium` (1.06 GB fp32) | quantized `.ort` size unconfirmed (est. ~250 MB) | SwiftPM `https://github.com/moonshine-ai/moonshine-swift` (macOS quickstart `MicTranscription`), or `pip install moonshine-voice` + `moonshine-voice mic --language en` for a first check. Look at `lastTranscriptionLatencyMs` and line-update events |
| E3 | Voxtral Mini 4B Realtime (accuracy ceiling) | HF `mlx-community/Voxtral-Mini-4B-Realtime-6bit` (`model.safetensors` + `tekken.json`); base `mistralai/Voxtral-Mini-4B-Realtime-2602` | 3.6 GB (4-bit variant `mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit` 3.1 GB) | Python `pip install voxmlx` (MIT), `voxmlx --audio file.flac`, or the library API fed by our 50 ms buffers; speech-swift `VoxtralASR` as the Swift route (untested). Test delay 480 ms (card default) and 960 ms |

Fallback if E3 cannot keep real time on this M4: Parakeet EOU 120M (HF `FluidInference/parakeet-realtime-eou-120m-coreml`, folder `320ms`, 448 MB, FluidAudio `parakeet-eou`).

### Italian (2)

| # | Candidate | Exact download | Size | Path |
|---|---|---|---|---|
| I1 | Nemotron 3.5 ASR Streaming 0.6B, Latin ship | HF `FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`, folder `latin/1120ms` (add `latin/560ms` if sub-second needed). Alternative with 320 ms chunk: `aufklarer/Nemotron-3.5-ASR-Streaming-0.6B-CoreML-INT8` | `latin/1120ms` ~611 MB; speech-swift bundle 612 MB | FluidAudio `fluidaudiocli nemotron-multilingual-transcribe --model-dir latin/1120ms --language it-IT`, or speech-swift `NemotronStreamingASR` (`speech transcribe x.wav --engine nemotron --language it-IT`). The FluidInference card says access needs Discord, but the HF API reports not gated (inconsistent, check at download) |
| I2 | Voxtral Mini 4B Realtime (same artefact as E3) | as E3 | 3.6 GB | as E3; this tests whether one model can serve en+it |

Honorable mention, not streaming: Parakeet TDT v3 (`FluidInference/parakeet-tdt-0.6b-v3-coreml`, encoder 446 MB, CC-BY-4.0) as an accuracy reference for Italian finals.

### Turkish (optional, 1)

| # | Candidate | Download | Path |
|---|---|---|---|
| T1 | Nemotron 3.5 via speech-swift | HF `aufklarer/Nemotron-3.5-ASR-Streaming-0.6B-CoreML-INT8` (612 MB), `--language tr-TR` | speech-swift `NemotronStreamingASR`. Same artefact as I1's alternative, so Turkish costs one extra run |

## Verdict per language

**English**: Nemotron en (E1) is the first thing to run: published, FluidAudio gives a Swift path today, and it is accurate at 560-1120 ms chunks. Moonshine Medium (E2) is the speed/size challenger, probably the only one likely to match Apple's 0.28 s last-word lag. Voxtral (E3) sets the accuracy ceiling but is 4B and unproven in real time on Apple Silicon. Expect a streaming chunk floor of 0.56-1.12 s for Nemotron, so beating Apple's p50 0.28 s is unlikely there; only Moonshine or Nemotron 3.5 at 80-320 ms could. Apple stays the latency reference; the question is whether punctuation/accuracy on real speech justifies the swap.
**Italian**: Apple is accurate (0 % WER on Alice) but finals are slow (p50 3.5 s). Voxtral has the best published Italian WER (3.27 % @480 ms) and Nemotron 3.5 the smallest, native-streaming option (4.25-5.45 %). Benchmark both on finals latency.
**Turkish**: Only Nemotron 3.5 (and Whisper offline, Qwen3-ASR unconfirmed) lists Turkish with a number (11-12 % FLEURS); stay on Apple Dictation unless it fails on real speakers.
**Cross-language**: Nemotron 3.5 on one 0.6B CoreML model covers en+it+tr; its CoreML tr path is the least verified part.
**Hardware/risk**: all numbers above come from M5 Pro / M2 in third-party cards; our M4 results may differ, and synthetic `say` voices do not predict real meeting audio.

## Not confirmed / where I looked

- No vendor publishes last-word lag against acoustic end; every latency figure above is a chunk size, time-to-final, or RTFx.
- RAM use: only the speech-swift Nemotron INT8 card (RSS 1.0-1.2 GB, M5 Pro) and MLX 4-bit card (RSS ~750 MB peak) state it; other rows unconfirmed.
- Voxtral on Apple Silicon: no published latency; `voxmlx` README does not give numbers (read). ExecuTorch macOS demo exists (`mistral-labs/Voxtral-Mini-4B-Realtime-2602-ExecuTorch`, not read).
- Moonshine quantized `.ort` sizes and Swift package licence (repo shows none; main repo is MIT) not confirmed. Moonshine Italian and Turkish models do not exist in the catalog page I read.
- Qwen3-ASR it/tr numbers: appendix table text was ambiguous, left unconfirmed. Qwen3-ASR licence, size not read.
- WhisperKit Italian/Turkish accuracy and its real streaming latency on M4: not found; only the vendor paper's English 0.46 s / 2.2 % WER.
- Not researched: whisper.cpp CoreML/Metal, mlx-whisper, Canary, distil-whisper, sherpa-onnx model list beyond a search snippet, Turkish-only models beyond `mihuai/turkish-stt`.
- NVIDIA Open Model License and OpenMDW-1.1 full texts not read; "commercial OK" is from the model cards.
- FluidInference Nemotron 3.5 CoreML repo: card says gated via Discord, HF API says `gated: false` (checked 2026-10-14).
- Sources: HF model cards (nvidia/parakeet-tdt-0.6b-v3, nvidia/nemotron-3.5-asr-streaming-0.6b, nvidia/nemotron-speech-streaming-en-0.6b, nvidia/parakeet_realtime_eou_120m-v1, kyutai/stt-2.6b-en, mistralai/Voxtral-Mini-4B-Realtime-2602, FluidInference/*-coreml, aufklarer/Nemotron-3.5-*); GitHub READMEs/docs (FluidInference/FluidAudio Documentation/Models.md and Benchmarks.md, soniqo/speech-swift, moonshine-ai/moonshine docs, awni/voxmlx, kyutai-labs/delayed-streams-modeling, NVIDIA/NeMo-Speech.cpp, QwenLM/Qwen3-ASR); arXiv 2507.10860 (WhisperKit), 2602.12241 (Moonshine v2), 2601.21337 (Qwen3-ASR).
