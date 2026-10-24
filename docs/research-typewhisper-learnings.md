# TypeWhisper: how it captures and recognises speech, and ideas for Verse

Source read: `github.com/TypeWhisper/typewhisper-mac`, shallow clone at commit `fe1b1b8` (2026-10-13), in the session scratchpad. Nothing was run or built from it.
Installed app on this Mac: `com.typewhisper.mac` 1.7.0; the cloned HEAD is newer than the installed build, so line numbers are for HEAD and installed behaviour is confirmed only where stated.
License: GPL-3.0. This file records *ideas and facts*; no code or text was copied into Verse. Paths below are relative to the repo root; `Plugins/` means `TypeWhisperPluginSDK/Plugins/`.
Not read, as instructed: TypeWhisper's history, audio, dictionary stores and any keys.

## 0. What the owner's own setup actually does for Turkish

- Defaults show `language = tr`, `selectedEngine = groq`, Groq model `whisper-large-v3`, Apple Speech plugin enabled, Parakeet disabled.
- The Apple Speech plugin only offers locales from `SpeechTranscriber.supportedLocales` (`Plugins/SpeechAnalyzerPlugin/SpeechAnalyzerPlugin.swift:266-273`). `tr` is absent on this Mac (see `bench/speech/RESULTS_speech.md`), so the plugin cannot serve Turkish.
- The whole repo contains **no** `DictationTranscriber` and no `SFSpeechRecognizer` (grep over all `*.swift`: zero hits). The installed plugin binary also has no such string (`strings -a` on `SpeechAnalyzerPlugin.bundle`, 14 hits, all `SpeechTranscriber/SpeechAnalyzer`). So **TypeWhisper has no fallback to DictationTranscriber**; Turkish dictation on this machine is Groq cloud, batch.
- Consequence for Verse: TypeWhisper has no local streaming Turkish path that we could copy or beat. Our DictationTranscriber+`frequentFinalization` (last word p50 523 ms) is already faster than anything TypeWhisper does for Turkish (see section 3, live preview = batch re-decode every 3 s).

## 1. Audio capture

Dictation mic (`TypeWhisper/Services/AudioRecordingService.swift`):
- Engine: `AVAudioEngine`, tap on the input node requesting `bufferSize: 256` frames (`:593`, install at `:2847`). Whether CoreAudio actually delivers 256-frame buffers was not measured; it often enlarges small requests.
- Output format: always 16 kHz mono Float32 (`:584`), converted with `AVAudioConverter` (`:2815`). Multi-channel input is reduced to mono by picking the strongest channel per slice (doc comment around `:226-229`, `normalizedInputBuffer` `:3198`).
- Voice processing is **not** the default. It is switched on only when the default input is the built-in mic reporting exactly 3 channels, with AGC on (`enableVoiceProcessingIfNeeded` `:3164-3181`). The pre-roll feature refuses to run with it because "a voice-processing engine ducks other apps' audio for as long as it runs" (`:1014-1019`).
- Software gain ("microphone boost", `:114-232`): per-buffer RMS, target RMS 0.1, max gain 20x, only above RMS 0.0015, attack 0.45 / release 0.06, peak ceiling 0.96, soft limiter above 0.8. Gain is held through near-silence so room noise is not pumped between words.
- Pre-roll: optional 0.5 s ring buffer filled while the mic is "armed" between dictations, drained and prepended on the next start (`:586`, `handOffPrerollToRecording` `:1676`, `Services/MicrophonePrerollRingBuffer.swift`). Engine is also prewarmed (`engine.prepare()`) so the first buffer arrives fast. Bluetooth inputs get a readiness wait of up to 5 s (`:593` area).
- Dead-input detection: a recording of exact zeros is "digital silence"; at >= 1 s it is discarded with a "mic sent only silence" message instead of being sent to a recognizer (`ViewModels/DictationViewModel.swift:5690-5707`). Quiet-clip policy: peak < 0.006 counts as no speech except short clips with peak >= 0.003 (`:5675-5731`).
- Tail padding before the final batch transcription: 0.3 s of zeros, or pad to 0.75 s for very short clips (`:5734`).

Meeting recorder (`TypeWhisper/Services/AudioRecorderService.swift`):
- Remote/system side: **ScreenCaptureKit** `SCStream`, audio only (2x2 video, 1 fps), 48 kHz stereo, `excludesCurrentProcessAudio = true` (`:1338-1359`). No Core Audio process tap anywhere (grep for `AudioHardwareCreateProcessTap`/`CATapDescription`: none).
- Mic side: engine tap of 4096 frames (`:1103`), voice processing only for the same 3-channel built-in case (`:1285`).
- Echo/bleed handling is post-capture: a mic "ducking" gain driven by the system-audio envelope. Aggressive profile: min mic gain 0.18, thresholds 0.006 / 0.025, hold 0.12 s, envelope attack 8 ms / release 60 ms, gain attack 20 ms / release 280 ms (`:1714-1725`); medium profile 0.42 / 0.01 / 0.04 / 0.08 s (`:1727-1735`). No correlation or delay search.

VAD, silence and noise:
- No always-on VAD gating the recognizer during dictation. Instead:
  - Live preview audio gate: 100 ms frames, speech RMS floor 0.004, text updates suppressed once quiet for 1.4 s or before any speech was seen (`ViewModels/StreamingHandler.swift:46-48`, gate struct `:60-95`). Reason: text produced during silence is likely hallucination.
  - Recorder path uses Apple's built-in SoundAnalysis speech classifier (no model download; "about 2.5 s for 33 minutes"): 1 s windows, 50 % overlap, speech threshold 0.03, evidence threshold 0.06, 1.5 s padding, only removes stretches >= 3 s (`Services/SpeechOnlyAudio.swift:30-45, 74-80`). Stated purpose: stop Whisper-family engines writing credits or dictionary words for silence. Tuned on telephone-band, 12 kbit/s Opus and pink noise at about 5 dB below speech.
- No denoiser/noise suppression beyond AGC and the optional voice processing.

## 2. Engine plugin architecture

- Engines are plugins behind `TranscriptionEnginePlugin` (`TypeWhisperPluginSDK/Sources/TypeWhisperPluginSDK/TypeWhisperPlugin.swift:~940-957`): `transcribe(audio, language, translate, prompt)` batch, plus an optional `onProgress` variant, `supportsStreaming`, `supportedLanguages`. Real live engines additionally implement `LiveTranscriptionCapablePlugin` / `LiveTranscriptionSession` (`appendAudio(samples:)`, `finish()`, `cancel()`, `:~810-815`). Plugins declare whether progress text is a `completeSnapshot` or a `rollingWindow`.
- The host (`Services/ModelManagerService.swift`) picks the engine, normalises the language against the plugin's `supportedLanguages` (`:1456-1472`), prewarms the model when recording starts (`beginDictationModelPrewarm` `:1194`), and unloads idle models after 600 s by default (`:99`).
- First-party plugin sources: `Plugins/{SpeechAnalyzerPlugin,WhisperKitPlugin,ParakeetPlugin,GroqPlugin,Qwen3Plugin,VoxtralPlugin,...}`. In this install only `SpeechAnalyzerPlugin.bundle` is inside the app; `Groq` and `Parakeet` sit in `~/Library/Application Support/TypeWhisper/Plugins/`. There is **no WhisperKit plugin bundle installed** (see `bench/whisper/RESULTS_whisper.md`).
- Hedged recovery: the app can race the primary engine against a fallback engine; the fallback request is only sent after a user threshold (1-15 s) with the primary still running, first success wins, the loser is cancelled but never awaited (`ViewModels/DictationViewModel.swift:3734` ff., threshold cap `:3716`). Whole final phase has a deadline of 60 s + audio length (`:194`).

## 3. Streaming vs batch per engine

| engine | what it really does | evidence |
|---|---|---|
| Apple SpeechAnalyzer plugin | The only true streaming engine in the owner's setup. `SpeechTranscriber(locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])`, a persistent `SpeechAnalyzer`, an `AsyncStream<AnalyzerInput>`; volatile results shown as `finalized + latest volatile`. **No `.fastResults`**, no `audioTimeRange` attribute. | `SpeechAnalyzerPlugin.swift:192-196`, live session `:545-632`. Batch variant uses `preset: .transcription` (`:147`). |
| WhisperKit | Batch only, no live session. `onProgress` is the decoder's token callback within one decode, not live audio. The "live preview" for WhisperKit (and Parakeet, Groq, any non-live engine) is a **fallback loop: every 3 s re-transcribe the most recent 10 s** and merge. | `StreamingHandler.swift:43-44, 459-504` (poll 3 s, window 10 s); WhisperKit `transcribe(... onProgress)` `WhisperKitPlugin.swift:355-396`. |
| Parakeet | `supportsStreaming` is true but `onProgress` is called once with the final text (`ParakeetPlugin.swift:167, 334`). Batch (FluidAudio `AsrManager`). | same |
| Groq | Cloud batch: audio is AAC-encoded (m4a, 48 kbit/s, 30 s encoder chunks), WAV fallback, request timeout 600 s. Models `whisper-large-v3` and `whisper-large-v3-turbo`. | `GroqPlugin.swift:11, 69-70, 108-126`; `HostServices.swift:781-784, 986-1000` |
| Voxtral / Qwen3 (local MLX) | Token streaming of a whole-clip decode, not live audio. | `VoxtralPlugin.swift:~315-345` |

- Live session cadence for real streaming engines: the host polls its sample buffer every 350 ms and appends the new samples (`StreamingHandler.swift:42, 433-457`). So TypeWhisper feeds Apple's analyzer in about 350 ms lumps, unlike our 50 ms buffers; this adds up to 350 ms to its own latency.
- The live preview is only started when an indicator preview or live-field mode is on (`DictationViewModel.swift:2233-2238`). Otherwise dictation = record, then one batch call.
- Text merge for repeated windows: confirmed prefix kept, new text appended via prefix/suffix overlap, fuzzy word overlap, "provider correction" detection by word coverage (>= 0.72 / 0.60) (`StreamingHandler.swift:686-830`). Preview is not allowed to shrink (`:631-645`).
- If a live session loses audio or returns nothing for 5 s of speech, the host discards it and re-transcribes the full recording (`:51, 262-300`).

## 4. Latency tricks seen

- Model prewarm at record start (host, `ModelManagerService.swift:1194`); WhisperKit loaded with `prewarm: false` then explicit `loadModels()` + `prewarmModels()` so Core ML compile happens at load, not on first use (`WhisperKitPlugin.swift:759, 795`). Auto-unload default 600 s.
- WhisperKit decode options: `temperature 0` with 3 fallbacks, `usePrefillPrompt` and `usePrefillCache` on, `chunkingStrategy: .vad` (VAD chunks, parallel batch decode, failed chunks retried serially), `detectLanguage` only when no language is set (`WhisperKitPlugin.swift:508-522, 399-496`).
- Mic input kept armed between dictations with 0.5 s pre-roll so no first syllable is lost and no engine start-up wait.
- Cloud upload shrunk with AAC 48 kbit/s mono 16 kHz.
- Final result reuses the live session's text instead of a second pass when the live session produced text (`DictationViewModel.swift:2834-2912`).

## 5. Custom vocabulary and prompt context

- Apple: `AnalysisContext.contextualStrings[.general]`, up to 100 terms (`SpeechAnalyzerPlugin.swift:16, 232-243`).
- WhisperKit: prompt tokens (`promptTokens` + prefill), max 500 chars. A bare comma list "reacts badly", so terms are wrapped in a sentence ("The audio may contain these names or technical terms: ...") (`WhisperKitPlugin.swift:27, 571-601`). The echoed prompt is stripped from the streamed text (`:603-617`).
- Parakeet: after decoding, a CTC keyword spotter (about 100 MB side model) rescoring pass swaps in dictionary terms (`ParakeetPlugin.swift:442-660`).
- Groq: dictionary terms are only sent if the user turns that option on (`GroqPlugin.swift:80-86`).

## 6. Language handling, Turkish, Parakeet

- Language is a setting: exact code, a hint list, or auto. For WhisperKit `nil` = Whisper language detection (`detectLanguage: language == nil`); exact code skips it. Plugins that do not accept hints just take the first code (`ModelManagerService.swift:1456-1472`).
- Turkish specifics found in the app: Turkish-aware case folding (dotted/dotless i) in the dictionary and filler-word plugins (`TypeWhisperTests/AppVocabularyImportTests.swift:177-194`, `Plugins/FillerWordsPlugin/FillerWordsPlugin.swift:165, 230`). No Turkish number-word normaliser (`Services/NumberNormalization/` has zh, nl, en, fr, de, ja, es only). Nothing Turkish in capture or engine selection.
- **Parakeet TDT 0.6b v3 does not support Turkish.** The plugin's `supportedLanguages` for v3 and "ultra" is 25 European languages: bg hr cs da nl en et fi fr de el hu it lv lt mt pl pt ro sk sl es sv ru uk; v2 is English only (`ParakeetPlugin.swift:1157-1162`). Confirmed independently against the NVIDIA model card language list on Hugging Face (fetched 2026-10-14): no `tr`.
- Other local engines in the plugin set that list `tr`: Qwen3-ASR (MLX, `Qwen3Plugin.swift:865`) and Voxtral (`VoxtralPlugin.swift:260-263`). For Voxtral Mini 4B Realtime the Hugging Face card lists 13 languages **without** Turkish, so TypeWhisper's own `tr` entry looks unreliable. Qwen3-ASR Turkish support was not verified (card has no language field in the API response).

## 7. Ideas for Verse, ranked

Verse constraint recap: audio never leaves the Mac (spec section 3), so the cloud route TypeWhisper uses for Turkish is out.

| # | Idea | Where in Verse | Expected gain | Evidence level |
|---|---|---|---|---|
| 1 | **Do not let voice processing duck the meeting audio.** TypeWhisper avoids VP for this reason (`AudioRecordingService.swift:1014-1019`) and uses it only for the 3-channel built-in mic. Spec 5.7 plans `setVoiceProcessingEnabled` on the user's mic. Plan to set the ducking configuration to minimum (`voiceProcessingOtherAudioDuckingConfiguration`, from my knowledge of the macOS 14+ API, not tested here) or drop VP and rely on the bleed gate. Add a spike test: remote volume with and without VP. | spec 5.7, mic capture unit | Avoids the meeting volume dropping while Verse runs; a real-world failure, not a number | source comment verified; Verse API behaviour not tested |
| 2 | **Dead-stream detector** for the process tap / SCK stream: exact-zero audio for >= 1 s means "tap delivers silence" (Brave route is spike item #1). Show a clear chip instead of an empty transcript. | spec 5.7 spike item #1, capture health | Turns a silent failure into an immediate, diagnosable state | pattern verified (`DictationViewModel.swift:5690-5707`) |
| 3 | **Keep the Turkish recognizer on DictationTranscriber+`frequentFinalization`; do not copy TypeWhisper's Turkish route.** Its Turkish path is cloud batch; its local "live" path for non-Apple engines is a 3 s poll of a 10 s window, which cannot meet a sub-second last-word target. | spec 5.4 / section 11 open question on Turkish | Saves time: no TypeWhisper trick will beat 523 ms p50 for Turkish locally | verified in source |
| 4 | **WhisperKit as an offline corrector, not the live path.** After an utterance endpoint, re-decode that <= 10 s utterance with `large-v3-turbo`, language fixed to `tr`, prefill cache on, and replace text in the saved transcript/summary only (never t = 0 decisions). Mirrors the host's "live text first, better final later" and the hedged-race pattern. | transcript log / summary stage | Lower Turkish WER in what is saved (DictationTranscriber measured 18 % on a synthetic voice); zero latency cost on the live path | **not measured** (model absent, see RESULTS_whisper.md) |
| 5 | **Gate silence away from Whisper-family decoders** (cheap energy gate: 100 ms frames, RMS floor about 0.004, 1.4 s sustained quiet) and optionally the free SoundAnalysis speech classifier for post-hoc cleanup. Prevents hallucinated text between questions when WhisperKit is used. | any WhisperKit stage | Fewer phantom words; protects section 6 reuse checks | thresholds verified in source; effect on our audio unmeasured |
| 6 | **Feed the recognizer straight from the tap callback.** TypeWhisper polls every 350 ms and still looks usable, but it adds up to 350 ms; Verse's 50 ms feed (bench) or the native tap size should be kept, not batched. | audio-to-ASR plumbing | Up to about 350 ms back on every turn compared with a polled design | verified in source; Verse bench already uses 50 ms |
| 7 | **Meeting-pack terms as recognizer context**: `AnalysisContext.contextualStrings` (<= 100 terms) for Apple modules; for Whisper a sentence-style prompt <= 500 chars ("The audio may contain these names..."), not a bare list. Prep stage already knows names and project words. | spec 5.2 Prep stage -> ASR setup | Fewer proper-noun misses; does not fix Turkish suffix errors (`kasıma`->`kasım`). Whether `DictationTranscriber` honours `AnalysisContext` is unconfirmed | patterns verified; effect unmeasured |
| 8 | **Bleed gate: add hold time to the envelope check.** TypeWhisper ducks mic by the system-audio envelope with 120 ms hold and 8 ms / 60 ms envelope attack/release; Verse's correlation gate (0-80 ms shift) is more precise but a hold avoids chopping the owner's first syllables. Cheap second criterion. | spec 5.7 bleed gate | Fewer false "the owner is speaking" / missed barge-ins | parameters verified; Verse behaviour untested |
| 9 | **Pre-roll ring buffer (0.5 s)** on the remote stream so speculation and the recognizer see the start of a turn; costs one small buffer. | capture unit | Avoids clipped first words after silence; small | mic-side only in TypeWhisper |
| 10 | **Stabilised merging for any rolling-window decode**: keep a confirmed prefix, append only new tail, ignore shrinking updates. Needed only if WhisperKit is later run in overlapping windows. | only if idea 4 grows into streaming | Prevents flicker/regression in partial text | pattern verified |
| 11 | **Load and prewarm models during Prep, never auto-unload in a meeting** (TypeWhisper defaults to unloading after 600 s and prewarms on record start). Use explicit `prewarmModels()` after load. | Prep stage | First-question cold-start penalty removed | pattern verified; cold-start cost for large-v3-turbo unmeasured |

## 8. Unconfirmed

- Installed behaviour of the 1.7.0 plugins is checked only by string search in the SpeechAnalyzer bundle and by defaults; I did not decompile anything (REA skipped: all needed behaviour is visible in the source, and the one open point, "does it use DictationTranscriber", is answered by the absence of any such string in both source and binary).
- Source is HEAD (2026-10-13) while the app is 1.7.0. The WhisperKit model id in defaults is `openai_whisper-large-v3-turbo` (hyphen) but current source uses `openai_whisper-large-v3_turbo` (underscore) (`WhisperKitPlugin.swift:1286`), so the stored value comes from an older plugin version.
- Whether the 256-frame tap request is honoured, Voxtral's real Turkish support, and Qwen3-ASR's Turkish quality were not checked.
- Ideas 4, 5, 7, 11 depend on measurements that need the WhisperKit model (blocked).
- I incidentally listed the *file names* (not contents) of `~/Library/Application Support/TypeWhisper/dictation-recovery/` while looking for model folders; I did not open any audio, history or dictionary file.
