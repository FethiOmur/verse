# Research: anytime calls (manual start, phone calls, it/tr, speakerphone)

Date: 2026-10-16. For `docs/specs/2026-10-16-verse-anytime-calls-design.md`.
Tools: firecrawl search/scrape first. It returned HTTP 429 halfway through, so the last two searches used Tavily.
Local evidence: the pinned FluidAudio checkout (`app/.build/checkouts/FluidAudio`, tag `v0.17.7`), `bench/RESULTS.md`,
`bench/whisper/RESULTS_whisper.md`, the running process list on this Mac, and `~/Library/Application Support/Verse/`.
Items marked **UNCONFIRMED** have no source that settles them. Each one says where I looked.

## 1. Remote audio of an iPhone call relayed to the Mac (Continuity)

Findings:
- With "Calls on Other Devices" on, the Mac places and answers cellular calls through the FaceTime app
  (support.apple.com/en-us/102405). The Mac's microphone and speakers carry the call.
- macOS has system daemons for this. `callservicesd` (TelephonyUtilities) and `avconferenced` (AV conferencing)
  were both running on this Mac at the time of writing (`ps`, 2026-10-16). The FaceTime app itself is not always
  running.
- Verse's capture already supports two tap routes (`VerseAudio/ProcessTapSource.swift`): bundle-ID taps
  (`CATapDescription.bundleIDs`) and PID-list taps. Core Audio also offers a global output tap that excludes chosen
  processes (`CATapDescription(stereoGlobalTapButExcludeProcesses:)`, macOS 14.2+). It needs the same "System Audio
  Recording" permission that Verse already holds, and no new entitlement.

**UNCONFIRMED:**
- Which process renders the remote voice of a relayed cellular call. `avconferenced` is the likely one, with
  `com.apple.FaceTime` as the other candidate.
- Whether a process tap on that daemon delivers samples. Apple may exclude system daemons or protected call audio
  from taps.

Where I looked: Apple Support pages on Continuity calls and FaceTime call recording, recapmycalls.com (it says
"mic and system-audio permission" but names no mechanism), Apple Developer Forums (ScreenCaptureKit tag), and the
general web. No source names the process or reports a tap on it.

Consequence for the spec:
- A 10-minute spike (B0) during one real call lists which audio process objects are running output.
- The design does not depend on its answer. The phone route uses a **global output tap that excludes Verse's own
  process**, and B0 can only narrow that to one PID.
- If B0 shows that nothing can be tapped, the phone route falls back to the speakerphone path (phase D).

Side note: macOS 26 FaceTime has its own call recording, which announces itself to both parties
(support.apple.com/guide/facetime/fctmb53ce460/mac). Verse doesn't record, so this doesn't apply.

## 2. On-device multilingual STT (en / it / tr)

| Option | Languages | Streaming | Measured or published numbers | RAM / size | Verdict |
|---|---|---|---|---|---|
| Apple `SpeechTranscriber` (+`.fastResults`) | en, it (no tr_TR on this Mac, P0-B) | yes | it last-word lag p50 0.79 s / p90 1.11 s; Italian finals 3.5–8.7 s (bench/RESULTS.md) | system-managed, outside our process | **Keep for it now** (already wired in `TranscriptionEngine.swift`) |
| Apple `DictationTranscriber` (+`.frequentFinalization`) | tr | yes | tr last-word lag p50 0.52 s / p90 0.65 s, WER 18.1 % on TTS (Yelda) questions (bench) | system-managed | **Keep for tr now** (already wired) |
| NVIDIA Nemotron 3.5 ASR streaming 0.6B (FluidAudio CoreML port) | 40 locales incl. it-IT and tr-TR, plus `auto` language ID | yes, cache-aware, chunks 80–1120 ms (NVIDIA); FluidAudio builds 560/1120/2240/4480 ms | NVIDIA FLEURS WER: it 4.41 % (560 ms), tr 11.34 % (560 ms), auto-detect within ~0.2 pp. CoreML port FLEURS it 5.68 % at 560 ms, RTFx 59 (`latin`); the `multilingual` (full-vocab) model RTFx 23 at 560 ms on M5 Pro | int8 + 6-bit palettized encoder (~55 % smaller than FP16); exact RAM not published | **Target engine for it/tr (C3)**, behind a bench gate. It is already in the pinned FluidAudio 0.17.7 (`StreamingNemotronMultilingualAsrManager`, `setLanguage`, `detectedLanguage()`). Italian routes to the `latin` folder, Turkish to `multilingual`. |
| Parakeet TDT 0.6B v3 | 25 European languages, **no Turkish** | batch-first | – | 0.6B | Rejected: no tr |
| Whisper large-v3-turbo (WhisperKit) | 99 languages | no native streaming (rolling re-decode; TypeWhisper polls every 3 s) | not benched: model not on disk (bench/whisper/RESULTS_whisper.md) | 1.5–3.2 GB | Rejected: latency and RAM next to Gemma + EmbeddingGemma |

Notes:
- The FluidInference CoreML repo is **gated**: "To grant access please join the server … and message Sisyphu"
  (HF model card). FluidAudio's downloader cannot fetch it without access. This is a question for Alex.
- At the 560 ms tier, punctuation gets sparse over long sessions (FluidAudio `NemotronMultilingual.md`, issue #687);
  the words are unaffected. Verse doesn't use `?` as a cue (bench: it arrives 0.9–1.6 s late), so this is acceptable.
  The fix is to reset the stream at long silences.
- With `auto`, the model emits a language tag (`<tr-TR>`) and the manager exposes `detectedLanguage()`. This enables
  "answer in the language being spoken" for mixed calls without a manual switch.
- **UNCONFIRMED:**
  - The RAM of the CoreML multilingual model.
  - Turkish latency of the `multilingual` folder. Only en/zh/ja RTFx are published for that folder.
  - Turkish WER of the CoreML port. NVIDIA's 11.3 % is for the original weights, and it is not comparable with our
    18.1 % TTS figure (a different test set).
- **UNCONFIRMED:** whether macOS 26.x added tr_TR to `SpeechTranscriber`. P0-B (14 Oct) found none on this Mac. The
  engine factory already checks `supportedLocales` at runtime.

Sources: huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b;
huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML;
github.com/FluidInference/FluidAudio (Documentation/ASR/NemotronMultilingual.md, Documentation/Benchmarks.md,
Documentation/Models.md, issue #744); build.nvidia.com/nvidia/nemotron-asr-streaming/modelcard;
huggingface.co/nvidia/parakeet-tdt-0.6b-v3; openvoxai.com/blog/best-local-stt-transcription-models-2026; local
checkout `StreamingNemotronMultilingualAsrManager+Shared.swift` (`languageDirectory`: en/es/fr/it/pt/de → `latin`,
everything else → `multilingual`).

## 3. Speaker separation on a single mic (speakerphone)

Findings:
- FluidAudio (already a dependency, v0.17.7) ships three diarizers. Their trade-offs, from
  Documentation/Diarization/GettingStarted.md:

  | Diarizer | Streaming update | Speakers | Strengths | Weaknesses |
  |---|---|---|---|---|
  | **Sortformer** (NVIDIA streaming) | every 480 ms, 560 ms tentative | up to 4 | "Best" in background noise and for pre-enrolled speaker mapping | "Poor" for speech from another room and for whispers; "may miss quiet speech" |
  | **LS-EEND** | every 100 ms, ~900 ms tentative | up to 10 | "Best" for whispers and overlap | "Weak" pre-enrolled mapping |
  | **Pyannote/WeSpeaker** (`DiarizerManager`) | – | – | – | "the slowest streaming option" |

- Enrollment APIs exist in the pinned checkout: `SortformerDiarizer.enrollSpeaker(withAudio:named:…)`
  (`Diarizer/Sortformer/SortformerDiarizer.swift:258`), `LSEENDDiarizer.enrollSpeaker`, and
  `DiarizerManager.extractSpeakerEmbedding(from:)` (`Diarizer/Core/DiarizerManager.swift:92`), which returns a
  WeSpeaker embedding.
- Enrollment by audio needs the audio at every session start. Verse's rule is that no audio is written, so a stored
  clip conflicts with it. The spec therefore stores only an embedding centroid (a vector of numbers, not audio) and
  maps diarizer slots to "me / other" by cosine similarity. Whether a short voice clip may be kept is a question for
  Alex.
- Accuracy expectations:
  - WeSpeaker ResNet34 reaches 0.72 % EER on VoxCeleb1-O (clean, with AS-Norm; wenet-e2e/wespeaker).
  - Short and far-field audio degrade it sharply. One ResNet34 system went from 1.45 % EER on full utterances to
    2.74 % at 2 s and 6.77 % at 1 s on VoxCeleb, and to 10–17 % on far-field VOiCES (Gusev et al., Odyssey 2020).
  - So decide per diarizer slot over ≥ 2 s of speech, never per 0.5 s frame.
- Expected latency: Sortformer's 480 ms update plus 560 ms tentative window means holding the audio about 0.6 s
  before routing it, so roughly +0.6 s ASR lag on both channels.
- **UNCONFIRMED:**
  - How Sortformer handles a phone loudspeaker that is quieter than the near voice. The docs warn it "may miss quiet
    speech", so the spec benches Sortformer against LS-EEND on recorded speakerphone fixtures.
  - The RAM of the diarizer models. The docs say "~100MB for Core ML models" for the classic pipeline.

Sources: github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md;
huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2; arxiv.org/html/2507.18446v1 (Streaming Sortformer);
github.com/wenet-e2e/wespeaker; isca-archive.org/odyssey_2020/gusev20_odyssey.pdf;
mixpeek.com/model/pyannote/wespeaker-voxceleb-resnet34-LM.

## 4. EmbeddingGemma for it/tr (bank matching, follow detection, me-library retrieval)

Findings:
- Verse runs EmbeddingGemma 2 text 270M (LiteRT). Google reports "100+ languages" and MTEB multilingual v2 mean
  61.36 (EmbeddingGemma 1: 61.15) (huggingface.co/google/embeddinggemma-2). EmbeddingGemma 1 was the top open
  multilingual embedder under 500M on MTEB at launch (developers.googleblog.com).
- **UNCONFIRMED:**
  - No per-language score for Turkish or Italian was found; I looked at the model card, the Google blog and MTEB
    write-ups.
  - Cross-lingual quality (a Turkish question against English material) is unmeasured.
  - Verse's thresholds (0.865 top-1, margin 0.02) were tuned on English only (`settings.py`).
- Consequence for the spec:
  - Per-language thresholds are calibrated on committed fictional paraphrase fixtures before `embed_langs` and
    `follow_langs` include it/tr.
  - Until then, it/tr sessions run without the paraphrase matcher and follow mode. Today's behaviour, no regression.
- **UNCONFIRMED:** whether EmbeddingGemma 2 keeps v1's retrieval prompts (`task: search result | query: …` /
  `title: … | text: …`). Verse uses the symmetric similarity prompt today. The me-library unit keeps that prompt
  unless a check against the model card says otherwise.

## 5. Prompt caching facts used by the spec (claude-api skill, cached 2026-10-06)

| Fact | Value |
|---|---|
| Breakpoints per request | at most 4 |
| Minimum cacheable prefix, Claude Haiku 5.5 and Sonnet 5.5 | 512 tokens (the skill says "check the docs before relying on") |
| Cache write cost, 5-minute TTL | 1.25× |
| Cache write cost, 1-hour TTL | 2× (entries with the longer TTL must come first) |
| Cache read cost | ~0.1× |
| Lookback window | 20 blocks |
| Haiku 5.5 price | $0.10 / $0.50 per MTok (≤ 100K-token prompts) |
| Sonnet 5.5 price | $2 / $10 per MTok |

## 6. Local facts checked

- `~/Library/Application Support/Verse/profile/` holds `voice.md` (556 words, the 7 text-style sections),
  `voice.meta.json` (source: `~/Downloads/ENGINEERING_PROFILE.md`) and backups. **No acoustic enrollment
  exists.** The V1 voice profile is text style only.
- `ENGINEERING_PROFILE.md`: about 21.5k characters, 12 sections (engineering mindset, AI design preferences,
  project context, communication).
- knowledge-vault `🏰 300-Projects`: `Projects.md` plus one top note per project. The `AgentLogs/` subtree is 165 notes and
  1.35 MB of agent output. Other top folders (Body, Mind, Vault, daily, receipts, Companion) are personal and are not
  me-layer sources. Contents were not read beyond sizes and headings.
- Meeting packs are 9.7–29.6 KB, about 2.5k–7.5k tokens; the cap is 12k tokens (`prep/pack.py`).
- No global start hotkey exists on `main`. ⌥⌘V appears only as text in the UI redesign spec. Start requires a
  prepared session (`VerseController.start`).
