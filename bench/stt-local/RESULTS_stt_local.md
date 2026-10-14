# Local streaming STT vs Apple SpeechTranscriber (English)

Run: 2026-10-14, MacBook (Mac16,1, Apple M4, 10 cores), macOS 26.6.2, Xcode 27 / Swift 6.4.
Engines: Nemotron Speech Streaming 0.6B en (CoreML, 560 ms chunk) via FluidAudio 0.17.7; Moonshine Medium Streaming (quantized ORT, `moonshine-voice` 0.1.5, Python sidecar); Apple `SpeechTranscriber` + `.fastResults` as the control, re-run in the same session.
Raw data: `results/*.json` (every raw event with its arrival time, per-question metrics), logs `results/run_all.log`, `run_moonshine_again.log`, `run_quiet.log`, system CPU-idle samples `results/cpu-*.log`. Tables below: `.venv/bin/python -I report.py`.

## Verdict

1. **Nemotron has by far the lowest last-word lag** (p50 0.15 s, p90 0.37 s on the clean voice; Apple 0.30 / 0.82 s, Moonshine 0.42 / 0.74 s) and the best accuracy on the bad voice (Albert WER 12.2 % vs Apple 40.3 % vs Moonshine 37.2 %). It costs 3 % CPU and 0.6 GB RAM (ANE does the work).
2. **But Nemotron's "final" is ~3.1 s late**, because the model emits the trailing `?`/`.` only when the next speech starts (about 3 s after the question ended; the last question of a stream never got one). Words are final as soon as they appear (greedy RNN-T output is never revised), so for Verse the usable signal is the last word at ~0.15 s; punctuation as an end-of-question cue does not work on this model (`?` arrives 3.2 s after the end, Apple 0.9 s).
3. **Moonshine is accurate on the clean voice (0 % WER) and its finals are close behind its words** (final p50 0.77 s, p90 0.92 s, better than Apple's 0.96 / 1.29 s), but it is **CPU-bound**: 75-110 % of one core (ORT), 1.1-1.4 GB RAM, RTF 0.15-0.25. Under CPU contention it degrades badly (see caveat 1): last-word p90 rose from 0.7 s to 3.4 s and a pass blocked up to 6.4 s.
4. Apple stays the cheapest (1 % CPU in our process, 60 MB; the model lives in a system service so its true cost is not visible here).
5. On the bad synthetic voice (Albert) only Nemotron is clearly better than Apple. Moonshine is about equal to Apple. All of this is synthetic `say` speech; real speakers are not covered.

## Main table

20 English questions per voice, real-time feed in 50 ms buffers, same corpus and metric code as `bench/speech`. Lags in ms, p50 / p90, n = 20 questions. These are the lighter-load runs (see caveat 1): Apple `rerun1`, Nemotron `rerun1`, Moonshine `rerun2` (warm second run) and Moonshine with a 0.2 s update interval `rerun1`.

| engine | voice | last-word lag p50 / p90 | final lag p50 / p90 | WER | RTF | CPU % | peak RSS (MB) |
|---|---|---|---|---|---|---|---|
| Apple SpeechTranscriber + fastResults (control) | Samantha | 297 / 823 | 955 / 1288 | 0.5 % | n/a | 1 % * | 61 * |
| Apple SpeechTranscriber + fastResults (control) | Albert | 717 / 1417 | 940 / 1559 | 40.3 % | n/a | 1 % * | 61 * |
| Nemotron 0.6B en, 560 ms CoreML | Samantha | 145 / 370 | 3127 / 3344 | 0.0 % | 0.05 | 3 % | 612 |
| Nemotron 0.6B en, 560 ms CoreML | Albert | 124 / 386 | 3271 / 3665 | 12.2 % | 0.08 | 3 % | 612 |
| Moonshine Medium Streaming (update 0.5 s, library default) | Samantha | 419 / 735 | 770 / 917 | 0.0 % | 0.15 | 75 % | 1097 |
| Moonshine Medium Streaming (update 0.5 s, library default) | Albert | 790 / 980 | 825 / 980 | 37.2 % | 0.25 | 111 % | 1097 |
| Moonshine Medium Streaming (update 0.2 s) | Samantha | 454 / 627 | 793 / 942 | 0.0 % | 0.17 | 81 % | 1400 |
| Moonshine Medium Streaming (update 0.2 s) | Albert | 630 / 929 | 750 / 929 | 36.7 % | 0.24 | 109 % | 1400 |

\* Apple runs out of process (speech service); only our process is measured. RTF is not measurable there.
Definitions: **last-word lag** = first time the last word of the question appears in the running text (final + volatile) minus the energy-based acoustic end (loose, count-aware variant, as in `bench/speech`). **Final lag** = arrival of the last finalized result of the question minus the acoustic end. **WER** = word edits of all finalized text of the run vs all scripted words. **RTF** = wall seconds spent in engine calls / audio seconds (Nemotron: `process()` calls; Moonshine: `add_audio` + `stop` in the worker). **CPU %** = CPU seconds of the engine's own process during the stream / stream wall seconds (100 % = one core). **Peak RSS** = lifetime `ru_maxrss` of that process (Moonshine: the Python worker).

## First run vs warm, and heavy-load vs lighter-load

`run1` = first full run of the engine, `run2` = second run (warm). Both ran while another session's iOS Simulator kept the machine at load average 70-100 (caveat 1). `rerun*` were taken afterwards at a much lower load. Last-word / final lag p50 / p90 in ms:

| engine | run | Samantha last-word | Samantha final | Albert last-word | Albert final | WER Samantha / Albert |
|---|---|---|---|---|---|---|
| Apple | run1 | 303 / 824 | 966 / 1256 | 713 / 1415 | 940 / 1564 | 0.5 / 40.3 % |
| Apple | run2 | 306 / 826 | 968 / 1255 | 717 / 1400 | 919 / 1548 | 0.5 / 40.3 % |
| Apple | rerun1 | 297 / 823 | 955 / 1288 | 717 / 1417 | 940 / 1559 | 0.5 / 40.3 % |
| Nemotron | run1 | 153 / 375 | 3145 / 3333 | 119 / 386 | 3267 / 3654 | 0.0 / 12.2 % |
| Nemotron | run2 | 151 / 364 | 3136 / 3346 | 127 / 392 | 3264 / 3660 | 0.0 / 12.2 % |
| Nemotron | rerun1 | 145 / 370 | 3127 / 3344 | 124 / 386 | 3271 / 3665 | 0.0 / 12.2 % |
| Moonshine 0.5 s | run1 (loaded) | 582 / 2625 | 951 / 2625 | 647 / 1189 | 843 / 1189 | 0.0 / 44.4 % |
| Moonshine 0.5 s | run2 (loaded) | 779 / 3407 | 848 / 3589 | 1031 / 3513 | 1162 / 3513 | 0.5 / 40.3 % |
| Moonshine 0.5 s | rerun1 | 448 / 775 | 858 / 945 | 780 / 1038 | 830 / 1039 | 0.0 / 37.2 % |
| Moonshine 0.5 s | rerun2 | 419 / 735 | 770 / 917 | 790 / 980 | 825 / 980 | 0.0 / 37.2 % |
| Moonshine 0.2 s | run1 (loaded) | 663 / 2931 | 847 / 2931 | 1613 / 7594 | 1613 / 7594 | 0.0 / 39.3 % |
| Moonshine 0.2 s | rerun1 | 454 / 627 | 793 / 942 | 630 / 929 | 750 / 929 | 0.0 / 36.7 % |

Apple and Nemotron are indifferent to the load (same numbers in all three runs) and to first-run vs warm. Moonshine varies by 2-3x with load; its WER on Albert moves 36.7-44.4 % between runs (VAD line splitting is not deterministic).

## Model load time

| engine | first-ever load (cold) | later loads (warm) |
|---|---|---|
| Apple SpeechTranscriber | model already installed; `prepareToAnalyze` 0.09-0.18 s per run | same |
| Nemotron 560 ms (CoreML, ANE) | **20.8 s** (smoke run, first load after download; includes the ANE/CoreML compile and FluidAudio's encoder probe) | 15.6, 17.8, 21.5 s: **no warm benefit**, loading the 590 MB int8 encoder costs ~16-21 s every process start |
| Moonshine Medium (worker spawn to ready) | 1.56 s (smoke run, first load; files freshly written) | 1.18-1.95 s (library-reported model load 0.95-1.4 s) |

## What the numbers do and do not mean

- **Acoustic end is biased late**: it is the last 10 ms frame above 4 % of the loudest frame, which is after the real end of the last word. Every engine shows negative last-word lags for some questions (Samantha: Nemotron 6 of 20, Apple 2, Moonshine 1; minimum -0.21 s). So all last-word lags are biased low by an unquantified amount (at least ~0.2 s for some questions). The ranking is unaffected, but "Nemotron last word at 0.15 s" means "about at the end of the acoustic energy", not "0.15 s after the word was spoken".
- **Nemotron has no volatile/final split.** I report after every decoded chunk (560 ms) the words so far for questions not yet final (the last word may be a partial word, as in a live display) as volatile events. A question's final is one event stamped at the chunk that emitted its last token. This is built after the run from the arrival log (no information from the future is used for the arrival times). Consequence: final lag includes the late punctuation token. The last-word lag column is the number to read for "when can the app act".
- **Nemotron word-to-question assignment** uses the token time (encoder frame index). On Albert, a few words are emitted more than 1.25 s after their question ended and fall into the next question's window, which distorts per-question numbers (WER is global and unaffected). Albert's Nemotron `?` timing is therefore not reported. Use Samantha for lag, Albert for WER.
- **Moonshine `?` is not an end cue**: it appears on partial hypotheses long before the end (median 1.4 s before the acoustic end on Samantha), then may disappear or move. Same data in the JSON (`qMarkVolatileRelSec`).
- Moonshine has no word timestamps in the default config, so word-level lag (the other Apple-bench metric) is not reported for the local engines.
- Moonshine's line = one VAD segment; `LineCompleted` is the final. `return_audio_data` was set to false (we do not need the PCM back), everything else default. Both `LineUpdated` and `LineTextChanged` events are in the raw events (duplicates are harmless to the metrics).

## Method

- **Audio**: unchanged `bench/speech` code (copied verbatim: `Analyze.swift`, `Audio.swift`, `Corpus.swift`, `Session.swift`). `say` renders the same 20 English questions: Albert (voice of the old bench) and Samantha (clean control), 16 kHz mono, laid out on one continuous stream per voice: 1.0 s silence, each question followed by 2.5 s silence, 4.0 s tail. Fixtures: 40 WAV files created and deleted by the program right after loading into memory in every process start (`FIXTURES deleted: 40/40, dir absent: true` in each log, also stored in each JSON). No audio file is left in `bench/`.
- **Real-time feed**: chunk i (50 ms = 800 samples) is delivered at `t0 + (i+1) * 50 ms` with absolute deadlines. Results are stamped on arrival with the same clock. Feeder lateness p50 3.7-8 ms for Apple/Nemotron; for Moonshine the feeder blocks when the worker stalls longer than the pipe buffer (1 s of audio), which then shows up as lateness up to seconds (it is the stall, reproduced faithfully).
- **Nemotron**: `StreamingNemotronAsrManager(requestedChunkSize: .ms560)`, models loaded from the local folder with `loadModels(from:)` (no ModelHub download), CoreML `cpuAndNeuralEngine`. The feeder pushes 50 ms buffers into a queue; a consumer task calls `process(audioBuffer:)` (the manager runs a chunk whenever 560 ms have accumulated) and reads the token timings after each call.
- **Moonshine**: `moonshine_worker.py` (Python, venv inside `bench/stt-local/.venv`) holds a `Transcriber(MEDIUM_STREAMING, update_interval 0.5)`; the Swift process spawns it, writes PCM frames to its stdin at real-time pace and stamps every JSON line the worker prints on arrival, so the numbers include the pipe hop (sub-millisecond). The library's `add_audio` runs the transcription pass inline, as an app would.
- **Apple**: `SpeechTranscriber(reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])`, identical to the old bench. The control numbers reproduce the old bench: Samantha last-word 0.28 / 0.83 s then vs 0.30 / 0.82 s now, WER 0.5 % both; Albert 0.71 / 1.41 s then vs 0.72 / 1.42 s now, WER 40.3 % both.
- One OS process per engine run (peak RSS is per engine), both voices in sequence, runs strictly sequential. Apple/Nemotron/Moonshine each ran twice (first/warm), Moonshine more times because of the load problem.

## Caveats

1. **The machine was not quiet.** During `run1`/`run2` another session's iOS Simulator (poster-extension processes, ~95 % CPU each, restarting every few seconds) held the load average at 70-100 on 10 cores. That is why Moonshine's `run1`/`run2` are slow and unstable (a single pass blocked up to 6.4 s, p90 last-word up to 7.6 s). I did not touch those processes. The `rerun*` runs were taken after it eased (load 4-17), but the CPU-idle samples (`results/cpu-*.log`) still show a mean of 36-56 % system idle during them, so even those are not clean-room numbers. A truly idle machine would likely help Moonshine (CPU-bound) more than Nemotron/Apple, which did not change at all.
2. Synthetic voices only: no accents, noise, crosstalk or meeting-codec audio. Albert is poorly recognized by Apple and Moonshine and much better by Nemotron; whether this carries over to real speech is unknown.
3. 20 questions per voice, p90 rests on 2 samples. Nemotron's chunk is 560 ms; the 1120 ms and 2240 ms tiers were not downloaded or tested, and a 80/160/320 ms Nemotron (NVIDIA lists them) is not available in the CoreML port we have.
4. Apple's real compute cost (speech service) and its RAM are not visible from our process; CPU and RAM for Apple are not comparable to the other two.
5. Moonshine used the quantized ORT model the library downloads by default (`quantized_26_08_21`, 257 MB), not the 1.06 GB fp32 safetensors of `moonshine-ai/moonshine-streaming-medium`; same model name/architecture ("medium-streaming"), but accuracy of the shipped quantization vs fp32 was not checked by us. ORT ran CPU-only (the library default); the CoreML execution provider option (`ort_providers`) was not tried.
6. Nemotron's trailing-punctuation lateness could depend on the test layout (long silences after each question); in continuous conversation the next speech would arrive sooner. Not tested.

## Licences

| component | licence | evidence |
|---|---|---|
| FluidAudio (SwiftPM 0.17.7) | Apache-2.0 | `LICENSE` read on GitHub; the package also pulls the prebuilt `NemoTextProcessing` xcframework (FluidInference/text-processing-rs v0.3.1), licence not read |
| Nemotron Speech Streaming 0.6B CoreML weights | HF metadata of both `FluidInference/...-coreml` and base `nvidia/nemotron-speech-streaming-en-0.6b`: "nvidia-open-model-license" (commercial use per NVIDIA's summary; full text not read). **Inconsistency**: the FluidInference README says "Apache 2.0 (following NVIDIA's original license)". Treat it as the NVIDIA Open Model License until clarified | HF API + README |
| `moonshine-voice` 0.1.5 (PyPI wheel, used) | MIT (PyPI metadata). The repo README states code is MIT except `core/third-party`, and all Moonshine models are MIT | PyPI + GitHub README |
| `moonshine-ai/moonshine-swift` (not used) | repo has no LICENSE file in the API listing (`license: null`); main repo MIT. Not used because its README says the xcframework only has iOS slices and macOS needs a locally built dylib (README only; not verified by download) | GitHub API + README |
| Moonshine medium-streaming model files | MIT (HF card `license: mit`, repo README) | HF API |
| Bundled/other Python deps (numpy, sounddevice, requests, onnxruntime dylib inside the wheel, ...) | not audited | |

## Disk

| item | size |
|---|---|
| `bench/stt-models/nemotron/nemotron_coreml_560ms` | 626,449,022 bytes (597 MiB on disk); all 22 files verified against the HF file list (size + sha256) |
| `bench/stt-models/moonshine/.../quantized_26_08_21` | 269,141,623 bytes (257 MiB on disk); 8 files verified against the library manifest (size, CRC32C checked by the downloader) |
| models total | 854 MiB (du) |
| `bench/stt-local/.venv` | 104 MB; `bench/stt-local/.build` 972 MB (both gitignored) |
| free disk | 12-13 GiB at start, 7.5 GiB at the end (other sessions also write); never below the 6 GiB stop line |

## Reproduce

```
cd bench/stt-local
swift build -c release
.build/release/SttLocal --engine apple|nemotron|moonshine [--moon-interval 0.5] --tag NAME   # about 4.5 min real time, writes results/<engine>-<tag>-<ts>.json
.venv/bin/python -I report.py                                                                 # tables
```
Setup done once: `python3 -m venv .venv && .venv/bin/pip install moonshine-voice`; models downloaded to `bench/stt-models/` (Nemotron: the 22 files of `nemotron_coreml_560ms` from the HF repo; Moonshine: `moonshine_voice.download.download_model_from_info(..., cache_root=bench/stt-models/moonshine)`).
Scripts used for the full set: `run_all.sh`, `run_moonshine_again.sh`, `run_quiet.sh`.
