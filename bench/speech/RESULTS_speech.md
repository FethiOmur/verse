# P0-B results: speech recognition latency and languages

Run: 2026-10-14, `swift run -c release SpeechBench --all` on MacBook (Mac16,1, Apple M4), macOS 26.6.2 (25G83), Xcode 27.0, Swift 6.4.
Raw data: `results/speech-2026-10-14T004101Z.json` (original run, includes every raw result event with its arrival time) and
`results/speech-2026-10-14T004101Z.reanalyzed.json` (same events, metrics recomputed by `SpeechBench --reanalyze` after the "loose" word-lag
metric was added; the tables below come from this file). The first file only lacks the loose word-lag fields.

## Verdict in five lines

1. `tr_TR` is **absent from `SpeechTranscriber`** (not in `supportedLocales`, `AssetInventory.status` = `unsupported`,
   `bestAvailableAudioFormat` returns nil, the session fails). `en_US` and `it_IT` are installed. Turkish does work through the older
   `DictationTranscriber` (`tr_TR` already installed, 18 % WER on a clean-sounding Turkish voice), so whisper.cpp is a fallback to consider, not yet a necessity.
2. Without `.fastResults`, `SpeechTranscriber` volatile text trails the audio by about 2 s (Samantha control: last word p50 1.9 s / p90 3.2 s). **With `.fastResults` it drops to p50 0.28 s / p90 0.83 s** for the last word. The spec's endpoint design needs `.fastResults`.
3. Finalized results arrive 1.0 s (p50) to 1.3 s (p90) after the acoustic end for English with `.fastResults`, but **Italian finals are much slower** (p50 3.5 s, p90 8.7 s for the clean Alice voice).
4. A `?` shows up in the text about 0.9 s **after** the acoustic end (English, fast). It was visible at or before the acoustic end in 0 % of Samantha questions. Punctuation is not an early cue on `SpeechTranscriber`.
5. `DictationTranscriber` without `frequentFinalization` holds finals until the stream is flushed (3 finals for 20 questions); with it, volatile text is as quick as `SpeechTranscriber`+fast.

## Locale status

| locale | SpeechTranscriber | DictationTranscriber | Status |
|---|---|---|---|
| en_US | supported, installed | supported, installed | **available** |
| it_IT | supported, installed | supported, not installed | **available** (SpeechTranscriber) |
| tr_TR | **not in `supportedLocales`**, `AssetInventory.status` = unsupported, `bestAvailableAudioFormat` = nil | supported, installed | **absent for SpeechTranscriber**; available via DictationTranscriber |

No model download was needed or started (en_US and it_IT were already in `installedLocales`; the tr_TR dictation model was already installed).
Oddities, unexplained: `SpeechTranscriber.supportedLocale(equivalentTo: tr_TR)` returns `tr_TR` although `supportedLocales` does not list it, and
`AssetInventory.status(forModules:)` returns `supported` (not `installed`) for en_US and it_IT although both are in `installedLocales`. I treated
`supportedLocales` / `installedLocales` plus the failed session as the evidence. `supportedLocales` has 30 entries (de, en variants, es, fr, it_IT/it_CH, ja, ko, pt, yue, zh); no Turkish.
The Turkish run of `SpeechTranscriber` failed with: `bestAvailableAudioFormat returned nil`.

## Main table (loose word lag, see method)

All lags are milliseconds, p50 / p90. n = 20 questions per language. "last-word lag" is the first time the last word of the question appears in the running text
(finalized + volatile) minus the energy-based acoustic end of the utterance (t = 0). "final lag" is the arrival of the last finalized result of the question minus t = 0.
"volatile coverage" is the share of words that were seen in volatile text before their final arrived.

| lang | module | q | word lag p50 / p90 | last-word lag p50 / p90 | final lag p50 / p90 | WER | volatile coverage | `?` in final | `?` first seen in volatile | `?` visible at or before acoustic end |
|---|---|---|---|---|---|---|---|---|---|---|
| en (Albert) | SpeechTranscriber | 20 | 2374 / 3900 (w=205) | 1848 / 3371 | 1919 / 3513 | 32.7% | 53% | 80% | 30% | 0% |
| en (Albert) | SpeechTranscriber+fastResults | 20 | 874 / 2960 (w=211) | 714 / 1406 | 961 / 1579 | 40.3% | 62% | 95% | 70% | 5% |
| en (Albert) | DictationTranscriber | 20 | 9203 / 23426 (w=132) | 8116 / 21019 | 21371 / 47037 | 44.4% | 14% | 25% | 55% | 10% |
| en (Albert) | DictationTranscriber+frequentFinalization | 20 | 580 / 1286 (w=132) | 248 / 2246 | 2020 / 3211 | 44.4% | 71% | 55% | 35% | 90% (unreliable, see notes) |
| it (Alice+Eddy) | SpeechTranscriber | 20 | 5882 / 10741 (w=150) | 5128 / 10164 | 8289 / 13190 | 28.0% | 56% | 45% | 45% | 5% |
| it (Alice+Eddy) | SpeechTranscriber+fastResults | 20 | 764 / 2564 (w=139) | 694 / 1037 | 3351 / 8465 | 31.9% | 68% | 40% | 45% | 0% |
| tr (Yelda) | SpeechTranscriber | - | failed: bestAvailableAudioFormat returned nil | | | | | | | |
| tr (Yelda) | DictationTranscriber | 20 | 8252 / 20699 (w=134) | 8069 / 18333 | 19530 / 41989 | 18.1% | 16% | 0% | 0% | 0% |
| tr (Yelda) | DictationTranscriber+frequentFinalization | 20 | 504 / 817 (w=134) | 523 / 646 | 2256 / 2321 | 18.1% | 81% | 0% | 0% | 0% |
| en control (Samantha) | SpeechTranscriber | 20 | 2266 / 3679 (w=196) | 1944 / 3242 | 2151 / 3429 | 0.5% | 100% | 100% | 90% | 0% |
| en control (Samantha) | SpeechTranscriber+fastResults | 20 | 705 / 998 (w=196) | 276 / 827 | 978 / 1305 | 0.5% | 100% | 100% | 100% | 0% |

`en control (Samantha)` is an extra run, not in the brief's voice list. I added it because Albert and Eddy are recognized poorly (see WER), which pollutes the lag numbers.

### Per voice (same runs; per-question WER = edits within the question window / script words)

The mixed Italian row above hides that Alice is recognized perfectly and Eddy is not. Lags for the clean voices are the trustworthy ones.

| lang | module | voice | word lag p50 / p90 | last-word lag p50 / p90 | final lag p50 / p90 | WER | volatile coverage | `?` first-seen minus end p50 / p90 (n) |
|---|---|---|---|---|---|---|---|---|
| it | SpeechTranscriber+fastResults | Alice | 799 / 2586 (w=94) | 794 / 1107 | 3551 / 8664 | 0% | 67% | 1578 / 2141 (7) |
| it | SpeechTranscriber+fastResults | Eddy | 740 / 1068 (w=45) | 491 / 1019 | 3273 / 8420 | 67% | 69% | 1347 / 1382 (3) |
| it | SpeechTranscriber (no fast) | Alice | 6930 / 10584 (w=94) | 5128 / 8984 | 7621 / 13759 | 0% | 48% | 7599 / 13407 (6) |
| it | SpeechTranscriber (no fast) | Eddy | 4264 / 10837 (w=56) | 5753 / 10164 | 10323 / 13020 | 59% | 70% | 2940 / 8265 (6) |

### Strict word-lag variant

"Strict" requires the same word at the same index of the running text; it is thrown off by any earlier misrecognition. It agrees with the loose variant on the clean runs (Samantha 705 / 998 vs 705 / 998 ms fast).

| lang | module | word lag strict p50 / p90 | last-word lag strict p50 / p90 | first final lag p50 / p90 | `?` first-seen minus end p50 / p90 (n) | questions whose final arrived only at stream flush |
|---|---|---|---|---|---|---|
| en | SpeechTranscriber | 2487 / 3960 | 1882 / 3431 | 1919 / 3513 | 1919 / 3439 (16) | 0 |
| en | SpeechTranscriber+fastResults | 939 / 3058 | 883 / 1579 | 932 / 1579 | 881 / 1496 (19) | 0 |
| en | DictationTranscriber | 15991 / 42313 | 14820 / 41144 | 21371 / 47037 | 7847 / 20140 (13) | 3 |
| en | DictationTranscriber+frequentFinalization | 735 / 3359 | 814 / 2246 | -3966 / 2619 | -4002 / -2499 (18) | 0 |
| it | SpeechTranscriber | 6392 / 13127 | 6406 / 10580 | 8289 / 13190 | 6497 / 8602 (12) | 2 |
| it | SpeechTranscriber+fastResults | 837 / 4899 | 903 / 2929 | 3351 / 8465 | 1473 / 1884 (10) | 0 |
| tr | DictationTranscriber | 14816 / 36825 | 14058 / 35485 | 19530 / 41989 | none | 3 |
| tr | DictationTranscriber+frequentFinalization | 538 / 3182 | 595 / 2284 | 2256 / 2321 | none | 0 |
| en control | SpeechTranscriber | 2266 / 3679 | 1944 / 3242 | 2151 / 3429 | 2094 / 3429 (20) | 0 |
| en control | SpeechTranscriber+fastResults | 705 / 998 | 276 / 827 | 978 / 1305 | 911 / 1188 (20) | 0 |

## Word accuracy

WER = word edits of all finalized text of the run against all scripted words, lowercased with the language's locale, punctuation removed, no digits in any script.

| language | voice | module | WER |
|---|---|---|---|
| en | Albert | SpeechTranscriber / +fast | 32.7 % / 40.3 % |
| en | Samantha (control) | SpeechTranscriber / +fast | 0.5 % / 0.5 % |
| it | Alice | SpeechTranscriber+fast, per question | 0 % |
| it | Eddy | SpeechTranscriber+fast, per question | 67 % (59 % without fast) |
| it | both (as run) | SpeechTranscriber / +fast | 28.0 % / 31.9 % |
| tr | Yelda | DictationTranscriber (both modes) | 18.1 % |

Reading: the recognizer is accurate on clean voices (Samantha 0.5 %, Alice 0 %). Albert (en) and Eddy (it) are recognized badly, for example "main risk in the current" became "main risk to adore a", and several Eddy questions came back empty or as one word. I cannot separate how much of that is the voice's synthetic quality and how much is the recognizer, so these two WER values are **not** a statement about real meeting speech. The Turkish 18 % comes from a single voice and a different module (Dictation); typical errors are dropped suffix letters, doubled words ("ne zaman ne zaman") and "kasıma" -> "kasım". Real speakers, noise and overlapping talkers are not covered at all.

## What this means for the spec

- Spec §5.4 says to act on volatile text. That only works with `.fastResults` on `SpeechTranscriber`: last word at p50 0.28 s / p90 0.83 s (Samantha), 0.69 s / 1.4 s (Albert), 0.79 s / 1.1 s (Alice). Without it the last word trails by about 1.9 s / 3.2 s. Adopt `.fastResults`.
- The critique's B4 concern (final text too late) holds for Italian: Alice finals p50 3.5 s, p90 8.7 s even with `.fastResults`, and two of 20 questions finalized only at the stream flush in the non-fast run. English finals are about 1.0 s. D must run on volatile text in every language.
- `?` as an end-of-question cue: not usable as an early signal in English (arrives ~0.9 s after the end, 0 % at or before), and late in Italian (a `?` appeared for 7 of 10 Alice questions, ~1.6 s after the end). The word-order and particle cues in spec §5.4 have to do the early work.
- Turkish: `SpeechTranscriber` cannot be used. `DictationTranscriber` with `.frequentFinalization` gives last word p50 0.52 s / p90 0.65 s, finals ~2.3 s, no `?` in the output at all, and is inside the macOS speech stack. If its accuracy on real Turkish speakers is not good enough, whisper.cpp is the proposed fallback (not installed, not tested). Decision for Alex.
- Unlike `SpeechTranscriber`, DictationTranscriber needs `.frequentFinalization` to be usable for streaming at all (finals otherwise only at flush; volatile coverage is only 14-16 %, which suggests earlier volatile text is dropped, not verified).

## Method

- Audio: `say` (CLI) rendered each question to a temp 16 kHz mono WAV: en_US Albert; it_IT Alice and Eddy (alternating, 10 questions each); tr_TR Yelda; extra control en_US Samantha. 20 questions per language (`Sources/SpeechBench/Corpus.swift`): English wh and yes/no; Italian with 8 statement-order yes/no questions (intonation only) next to wh and inverted ones; Turkish with `mı / mi / mu / mü` questions. No digits, so numerals cannot count as errors.
- Timeline: per language one continuous stream: 1.0 s silence, then each question followed by 2.5 s silence, and 1.5 s more tail (4.0 s after the last). Converted to `SpeechAnalyzer.bestAvailableAudioFormat` (16 kHz, 1 ch, Float32 on this Mac) and cut into 50 ms `AnalyzerInput` buffers.
- Real-time feed: buffer i is delivered at `t0 + (i+1) * 50 ms` (absolute deadlines, ContinuousClock). Delivery lateness p50 3.7-6.9 ms; per-run maximum between 8.8 ms and 234.6 ms (a few single-buffer hiccups; raw values in the JSON, `feederLateMaxMs`).
- Results are consumed in a separate task and stamped on arrival with the same clock (stream clock, t = 0 at the start of the first buffer). `prepareToAnalyze` took 0.03-0.2 s per run (model already installed).
- t = 0 per question: energy-based acoustic end of the rendered file (10 ms frames, threshold 4 % of the loudest frame), placed on the stream.
- Configuration: `SpeechTranscriber(locale:, transcriptionOptions: [], reportingOptions: [.volatileResults] (+ `.fastResults`), attributeOptions: [.audioTimeRange])`; `DictationTranscriber(..., transcriptionOptions: [.punctuation], reportingOptions: [.volatileResults] (+ `.frequentFinalization`), attributeOptions: [.audioTimeRange])`. One `SpeechAnalyzer` per run.
- Running text per question = finalized words in the question window + the latest volatile result in that window. Question windows: from 1.25 s before the file starts to 1.25 s before the next file; a result's runs belong to a window by the midpoint of their `audioTimeRange`.
- Word lag: reference = the finalized words with the end time from their `audioTimeRange`. Lag = first time the word is present in the running text minus that end time. "Loose" = word present anywhere (count aware); "strict" = same word at the same index. Words never seen in volatile get their final's arrival time, which is what "volatile coverage" counts against.
- `question_end_cues`: first arrival of a `?` in the running text of the question, minus the acoustic end.
- Fixtures: all 80 WAV files (4 voices-sets x 20) were read into memory and the temp directory `fixtures/run-2026-10-14T004101Z` was deleted by the program right after synthesis, before any recognition ran. Recorded in the JSON (`fixtures`): 80 created, 80 deleted, directory absent afterwards. No audio file is left in `bench/speech`. Only timings and transcripts of synthetic speech are stored.
- Processes: only the `SpeechBench` binary and short-lived `say` children; none left running (checked with `pgrep`).

## Not confirmed / caveats

- One run per configuration, 20 questions, no repeats, the Mac was not idle (other sessions running). Percentiles over ~200 words / 20 questions are rough; p90 of the last-word and final lag rests on 2-3 samples.
- Word end times come from the recognizer's own alignment, not from forced alignment against the audio, so word lag can be biased small if the recognizer reports late word ends. The last-word lag against the energy-based acoustic end does not have that problem and is the number to use for t = 0.
- Synthetic voices only. No accents, noise, crosstalk, compressed meeting audio (Brave/Meet) or real conversation rhythm. The 50 ms buffers are my choice; a real mic tap with 85-170 ms buffers adds up to that much delay.
- Why Albert and Eddy are recognized so badly is not isolated (voice vs. recognizer); no control voice for Italian or Turkish was run (Alice, the only clean Italian voice, scored 0 %).
- Italian finals being slow: observed (p50 3.5 s, p90 8.7 s, Alice, fast), cause not investigated (could be the Italian model's own endpointing). The 2.5 s gap between questions means an Italian final often arrives after the next question has begun.
- `?` timing for `DictationTranscriber+frequentFinalization` (en, "visible before the end" 90 %, negative lags) is unreliable: the punctuation runs carry odd time ranges, so the window assignment puts them early. Turkish Dictation output contained no `?` at all (punctuation option was on).
- `SpeechTranscriber` with `transcriptionOptions: []` still produced punctuation and capitals; the effect of `.etiquetteReplacements` and `.alternativeTranscriptions` on latency was not measured. `fastResults` accuracy cost: Albert WER 32.7 % -> 40.3 %, Italian 28.0 % -> 31.9 % (single run each; Samantha unchanged at 0.5 %).
- `AnalyzerInput` buffers were created without `bufferStartTime`; result times start at 0 for the first buffer, which I assumed and the lag numbers (positive, consistent with the feed) support.
- Whether Apple's tr_TR absence is permanent or only a missing download: not confirmed. The framework exposes no download path for it on this build (status `unsupported`).

## Reproduce

```
cd bench/speech
swift run -c release SpeechBench --all            # about 20 minutes real time, writes results/speech-<ts>.json, prints tables
swift run -c release SpeechBench --locales        # locale status only
swift run -c release SpeechBench --lang tr --questions 3   # quick check
.build/release/SpeechBench --reanalyze results/speech-<ts>.json
```
