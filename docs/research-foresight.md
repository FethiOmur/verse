# Google AI Edge Foresight: how it does what Verse needs, and ideas for Verse

Date: 2026-10-14. Research only. No commits, no code or text copied from Foresight, nothing downloaded or installed.
Subject: `/Applications/Foresight.app` (`com.google.AIEdgeForesight` 1.0.0, build `1.0.0.28.20261005`, Developer ID Google LLC, notarized, arm64 only).
Verse context read first: spec `docs/specs/2026-10-14-verse-meeting-assistant-v1-design.md` (section 5), `bench/RESULTS.md`, `bench/stt-local/RESULTS_stt_local.md`, plan `docs/plans/2026-10-14-verse-v1.md`.

Confidence tags used below:
- **[M]** read on this Mac from non-code bundle metadata or files the app wrote.
- **[P]** Google public source (page, model card, blog).
- **[T]** third party. The longest one is by talat, a **competing product**: it did static analysis of the installer and watched the network. Treat as useful but interested.
- **[I]** my inference from the above.
- **[U]** unconfirmed.

## 0. Legal boundary and what was actually done

Allowed and done: `Info.plist`, `codesign -d --entitlements`, `otool -L` and load-command listing (header level), file inventory of `Contents/`, listing of the helper tarball (names only), Flutter `macos_prod.assets` manifests and the two plain-text/JSON assets, the NOTICES licence file, `ps`/`lsof` of the already-running helper, the schema (DDL only, `sqlite3 -readonly`, 0 rows in every table) of the database the app created, public web sources.

Not done: no disassembly, decompilation or Dart-snapshot decoding; no `strings` on any executable or dylib (I ran `strings` only on `AssetManifest.bin`, a data manifest); the app was not launched and its UI not touched; REA tools were not used at all; nothing from the app was sent anywhere. The NOTICES file was decompressed into the session scratchpad, not into the project.

Side finding for the user: `ForesightHelper` (pid 61999) has been running for ~16 h since the first launch on 2026-10-13 20:32, idle at 3.6 MB RSS, no audio device open [M: `ps`, `lsof`]. I did not touch it.

## 1. Terms and licence relevant to studying it

- **No Foresight-specific EULA or terms page found** in public sources. The developer page `developers.google.com/edge/foresight` links none [P]. Google's list of services with service-specific terms (cached 2026-10-13) names the sibling app "Google AI Edge Eloquent" (Terms of Service plus Generative AI Prohibited Use Policy) but not Foresight [P]. Most likely Foresight falls under the general **Google Terms of Service (effective 2026-07-30)** and Privacy Policy [I]. In-app terms shown at onboarding were **not read** (would need the UI) [U]. The setup screen reportedly mentions "de-identified usage data" collection [T].
- Clauses in the Google ToS that touch this work [P, `policies.google.com/terms`]:
  - It forbids reverse engineering the services or their underlying technology (ML models are named) to extract trade secrets or other proprietary information, unless applicable law allows it.
  - It says users may not copy, modify, distribute, sell or lease any part of the services or software; the software licence is personal, non-assignable, non-exclusive.
  - It forbids using AI-generated content from the services to develop ML models.
  - It states that legally guaranteed rights cannot be limited by the terms.
- Reading for Verse (not legal advice): observing functionality, public docs and file metadata to learn ideas and principles sits inside the EU software-directive exception the user named and is not "extracting trade secrets". Stay clear of: decompiling, decoding the Dart snapshot, copying prompts, the shipped model files, icons, sounds, or the UI look.
- The models underneath are **open and separate from the app's licence**: Gemma 4 and EmbeddingGemma 2 are Apache 2.0 with the Gemma Prohibited Use Policy [P: HF `google/embeddinggemma-2`, Gemma docs]. Using those weights in Verse does not depend on Foresight's terms.

## 2. What Foresight is (one paragraph)

A free, experimental Flutter macOS app from the Google AI Edge team, launched 2026-10-06. Left pane: your shorthand notes; right pane: AI-enhanced notes, a transcript tab, an Ask chat, and a live panel. It records mic and system audio, transcribes locally, embeds your files with EmbeddingGemma 2, and answers with Gemma 4 through LiteRT-LM. Everything runs on-device except Google sign-in (optional, for Drive/Calendar) and usage analytics [P, T]. Optimized for Apple Silicon; the app declares macOS 14.2 as minimum [M].

## 3. Answers to the five questions

### 3.1 Audio capture

| Finding | Evidence | Tag |
|---|---|---|
| System audio comes from a **Core Audio process/system tap**, mic from the normal input | `Info.plist` has `NSAudioCaptureUsageDescription` (the key Core Audio taps use) and `NSMicrophoneUsageDescription`; `LSMinimumSystemVersion` 14.2 (the OS that introduced taps); `otool -L` shows CoreAudio, AudioToolbox, AVFAudio, AVFoundation and **no ScreenCaptureKit**; entitlements `device.audio-input` and `device.microphone`, app not sandboxed. talat independently says "Foresight uses the same thing" (Core Audio taps) | [M] + [T]; exact API calls [U] |
| Permission UX | Two generic usage strings: one asks for microphone access to capture input, one for access to capture audio output from other apps. No screen-recording permission is needed. Recording is **started by hand** (a Start transcribing button); no meeting auto-detection, only a calendar reminder after Google sign-in | [M] strings; [T] manual start |
| Speaker separation | **None beyond two streams**: every line is "you" (mic) or "everyone else" (system). No names, no voice clustering. The DB transcript is one text blob per event plus `attendees`; no speaker column | [T]; schema [M] |
| Echo handling | **None.** On speakers every remote line appears twice (system copy and a worse mic copy); fine on headphones | [T] (competitor, with screenshot) |
| Noise | RNNoise is in the NOTICES list, so a denoiser/VAD may be bundled; its use is not shown | [M] list; use [U] |
| Audio stored? | Transcript kept, recording discarded | [T] |

### 3.2 ASR

- **Not Apple's.** No `Speech.framework` link (so not SFSpeechRecognizer/SpeechAnalyzer) [M]. It is Google's own pipeline.
- The native-asset manifest (macos_arm64) lists packages `asr` (plus `opencc`, a Chinese script converter), `speech_pipeline`, `speech_processor`, `speech_processor_litertlm` and `speech_processor_llm_engine`, next to `litert_lm_api`, `rag_pipeline` and `text_generator` [M]. The two `speech_processor_*` variants hint that the **LiteRT-LM engine, possibly Gemma's audio path, can serve as the speech processor** [I].
- Download split: setup pulls ~**800 MB of "speech and search" models** first (done in ~2 min), then a **3.41 GiB (3.66 GB) Gemma 4 E4B**. EmbeddingGemma 2 full is 485 MB, so the speech part is roughly 300-400 MB [T sizes; I split]. A dedicated small speech model is therefore more likely than Gemma E4B doing the live ASR [I]; exact model names and sizes **[U]** until onboarding is run (this Mac has no models yet).
- Behaviour: words appear in italics and "firm up a moment later" = volatile and final results, fast in English [T]. French comes out missing every accented letter; Arabic not followed; **no language setting found** [T]. So: English-first, multilingual by accident.
- For reference, Gemma 4 E2B/E4B/12B can do ASR themselves: 16 kHz mono, 25 tokens per second of audio, **30 s max per clip**, multilingual [P: Gemma audio docs]. Not streaming by itself.
- Latency numbers for ASR: none published [U].

### 3.3 LLM, knowledge base, trigger

Models [M unless noted]: `lib/assets/on_device_model_configure.json` lists three Gemma 4 sizes:

| Variant | `minDeviceMemoryInGb` | audio backend | vision backend | context | sampling |
|---|---|---|---|---|---|
| Gemma 4 12B | 30 | GPU | GPU (560 visual tokens) | **4096** | T 0.4, top-k 40, top-p 0.9, repeat 1.05 |
| Gemma 4 E4B (default) | 15 | CPU | GPU (280) | 4096 | same |
| Gemma 4 E2B | 6 | CPU | GPU (280) | 4096 | same |

All three: speculative decoding on, thinking off, `filterChannelContentFromKvCache` true (thinking/channel tokens kept out of the KV cache, my reading [I]).
- Quantization: not stated in the config. The E4B file the reviewer saw (3.41 GiB) matches the public `gemma-4-E4B-it.litertlm` (3.66 GB: 2.24 GB decoder weights, 0.67 GB memory-mapped embeddings; vision/audio encoders loaded on demand) [P: HF card; I: same file].
- Runtime [M]: LiteRT (`libLiteRt` 11.7 MB, XNNPACK CPU), `libLiteRtMetalAccelerator` 16.7 MB, `libLiteRtWebGpuAccelerator` 31.9 MB, and **GPU top-k samplers** for Metal (9.5 MB) and WebGPU (24.6 MB). So generation runs on the GPU including sampling. Telemetry has a `backend` field [T], so the backend is chosen at runtime.
- Embeddings: **EmbeddingGemma 2** (740M, text/image/video/audio in one 768-d space; Matryoshka 128/256/512/768; 100+ languages; 8K context; int4/int8 QAT) [P]. The 270M text-only part is a 165 MB file; text latency 9.5 ms GPU / 31 ms CPU for 128 tokens on an M5 MacBook Pro [P: litert-community card].
- Knowledge-base shape, from the table names and columns of the app's SQLite DB [M, DDL only]:
  - `source_text_table`: whole documents (content, source link, type, embedding model id, optional image bytes).
  - `context_source_text_table`: chunks (content, model id, token count).
  - `document_embeddings`: one BLOB per document plus 3-D projection coordinates (a "knowledge map" view).
  - GraphRAG: `nodes_table` and `edges_table` (entities with summary and embedding), `document_entities`, `graph_rag_document_state`.
  - `document_clusters` (label, summary, centroid) and `document_labels` (user-defined or auto, with a rationale).
  - `event_document_table` links calendar events to documents (pre-meeting briefing); `contacts_table` (email, name).
  - `processed_uri_table` for dedupe; `drive_file_subscription_table` for Drive change subscriptions (the entitlement `aps-environment` is push).
  - No vector-index table: search is probably in-process over BLOBs [I].
- A separate helper process, `ForesightHelper` (90 MB, Unix-socket server, version 1.0.3), hosts the **RAG service** ("RagServiceImpl ... Embedding, cache_dir, use_gpu: false" in its log) [M]. Embedding on the helper is configured with GPU off at least by default [M log].
- Ingested formats: PDF, Google Docs, Microsoft Office, plain text, Markdown, web bookmarks, images/diagrams, audio, local folders, Google Drive, calendar attachments [P, T: telemetry field `is_calendar_attachment`].
- **How the live answer is triggered:** Google says lightweight query-detection models spot spoken questions, and the app shows proactive context cards with exact citations when questions **or topics** from your files come up [P: bundled FAQ and the product page]. The detected question is stored with its answer (`event_insight_table`: event, timestamp, query, insight) [M]. Telemetry counts `questions_detected_count`, `live_assistant_enabled`, `audio_queries_enabled` [T]. The detector's model and rule are **[U]**. Google's EmbeddingGemma 2 post advertises zero-shot matching against label descriptions in milliseconds [P], a plausible but unproven fit [I]. Whether it checks that the question is addressed to you is **[U]**; with only two audio streams it can at most use "came from the remote channel" [I].
- Because the context window is **4096 tokens**, summaries use map-reduce and incremental passes (`summary_generated` has `is_incremental`, `used_map_reduce`) [T].

### 3.4 Notes enrichment UX and presentation

- Layout: a Granola-like two-pane editor (your shorthand left, AI right) [P, TechCrunch]. Tabs for transcript, Ask chat, live Q&A [P, T]. A "stats" page counts meetings, sources, chats and "tokens saved" [T].
- Live Enhance: expands each shorthand bullet using the transcript; style options (Standard, Concise); it can also list **topics discussed that your notes missed** (`missed_topics_count`, `missed_topics_shown` in telemetry) [T]. The DB keeps `enhanced_content` separate from `content`, with `last_enhanced` and `last_manual_edit` timestamps, so an enhancement need not overwrite manual edits [M, I].
- Failure seen in a first test: the panel said Live Enhance was on but did nothing until the note style was toggled; the chat answered a "summary so far" request three times with an apology; the final summary described a team meeting that did not exist (single speaker plus a video) [T]. Silent no-ops and small-model summaries are the weak spots.
- Live answers: a HUD / context card with citations (a figure plus the page it came from) [P, YouTube explainer paraphrasing Google]. **No notch or overlay behind the menu bar is mentioned** anywhere [U].
- Latency: **no number published** for live answers, ASR or enrichment [U]. Only anecdotes: transcription "quick" in English [T]; a reader comment that a 30-minute call would not transcribe and the app felt slow [P, unverified comment on 9to5Google]. Foresight's own telemetry records `ttft_ms`, but values are not public [T].
- Model speed for context: Gemma 4 E4B on an M4 Max GPU, 1024-token prompt: TTFT 0.4 s, prefill 2,560 tok/s, decode 101 tok/s, 3.2 GB memory; on CPU 3.7 s. Gemma 4 12B on an M4 Pro: TTFT 3.48 s; on a 16 GB M4 Air: 9.13 s, 15 tok/s [P: litert-community cards].

### 3.5 Resource cost

| Item | Value | Tag |
|---|---|---|
| App download / on disk | 153 MB / 376 MB (this Mac: `du` 376 MB) | [T], [M] |
| Helper copy in Application Support | 90 MB; whole support folder 86 MB | [M] |
| Models on first run | ~800 MB speech and search, plus Gemma 4 E4B 3.41 GiB (default); total ~4.2 GB observed on the network; 12B file is 6.88 GB | [T], [P] |
| Setup time | ~8.5 min on a fast connection before the first recording | [T] |
| GPU memory | E4B ~3.2 GB (M4 Max), 12B ~7.9 GB | [P] |
| Offered by RAM | E2B at 6 GB, E4B at 15 GB, 12B at 30 GB (config thresholds) | [M] |
| Idle helper | 3.6 MB RSS | [M] |
| CPU/RAM during a meeting | not measured | [U] |
| Network | no audio/transcript seen leaving; ~74 analytics events in 2 min (meeting length, words, questions detected, model, doc counts, TTFT, tokens saved); no off switch found; Firebase Analytics is in the NOTICES list | [T] + [M] list |
| Background | reviewer reports a 4-hourly calendar-refresh job that relaunches the app after quit, plus a login item | [T] (not visible in `~/Library/LaunchAgents` here) |

## 4. Likely architecture (inferred, not proven)

```
mic + Core Audio tap -> two streams (you / others) -> streaming ASR (volatile -> final)
        |                                                    |
        |                                      query detector (small model) + topic match
        |                                                    |
   notes pane  <- Live Enhance (Gemma 4 E4B, 4K ctx)         v
                                      EmbeddingGemma 2 -> RAG service (helper) -> chunks + graph (SQLite)
                                                             v
                                      Gemma 4 answer + citations -> HUD card, saved as (query, insight)
```

## 5. Ideas for Verse, ranked

Ranked by gain per effort and by how well the evidence holds. "Where" uses spec sections and plan packages (P1-4 turn logic, P1-5 overlay, P1-6 replay/eval, prep = P1-1, brain = P1-2).

| # | Idea | Evidence | Where in Verse | Expected gain | Effort |
|---|---|---|---|---|---|
| 1 | **Add EmbeddingGemma 2 (text-only, 270M, 165 MB, Apache 2.0) as a candidate matcher** for bank questions, glossary and snippets, and test it as a zero-shot router (question cue, addressee, topic) on volatile partials | Foresight's retrieval stack; 9.5-31 ms per 128-token text; 100+ languages; MRL 128-768 d; spec 5.3 and 11 already ask whether `NLContextualEmbedding` beats char n-grams for Turkish | Spec 5.3 matcher and 5.4 signals; `Bank.swift`/`Cues.swift` (P1-4); blind paraphrase set in P1-6; also prep top-k retrieval | Higher hit rate on paraphrases in it/tr, an earlier hit before t = 0, one more cue for Italian where intonation-only questions have weak lexical cues | M. Run a 1-day bench first against the char n-gram TF-IDF baseline on the blind set; Turkish quality is **[U]** (Google warns performance is uneven across languages). Runtime options: LiteRT-LM (Swift API), MLX, or llama.cpp GGUF |
| 2 | **Topic trigger, not only question trigger**: proactively show a chip when the last ~10-15 s of remote speech embeds close to a fact-sheet entry or snippet, even without a question | Google FAQ says answers appear for questions or topics from your files | Spec 5.1 tier C (fact chips are lexical today), `Facts.swift` (P1-4) | Catches "so the budget is..." statements and prompts the owner without waiting for a question | S-M after #1. Needs a strict threshold and persistence over 2 partials (same rule as 5.3) to avoid noise; add a false-chip rate to the P1-6 report |
| 3 | **Prep-time consistency check**: one Sonnet pass over the fact sheet and snippets flags numbers or dates that disagree between sources, and marks them "conflict" instead of picking one | Foresight's wiki summaries flag contradictions such as mismatched budgets (bundled guide) | Spec 5.2 (fact sheet), 5.6 live grounding check; `brain/verse_brain/prep/ground.py` and `review.py` (P1-1) | Removes the worst failure (a confident wrong figure on the notch); also useful when vault and repo commits disagree | S. One extra prep call, fixtures with planted conflicts |
| 4 | **Rolling incremental summary** (Haiku, cached) every N finalized turns, merged at the end by Sonnet | Foresight summarizes incrementally and by map-reduce | Spec 5.10 Summarizer unit, `brain/verse_brain/runtime` (P1-2/P1-4) | Instant end-of-meeting summary and actions; the same rolling text can shrink D's context; low cost | S |
| 5 | **Calendar-linked prep**: use the event's title, attendees and attachments to choose vault notes and start Prep automatically; offer "Meet call detected, start Verse?" when the tap sees output from the meeting app | `event_document_table`, `contacts_table`, `calendar_event_id`, `attendees`, `is_calendar_attachment`; Foresight only reminds, a competitor auto-starts [T] | Spec 5.2 prep and 7 permission flow; P1-1 sources, P1-5 shell (`isRunningOutput` already exists in P1-3) | Removes the manual prep note step and the "forgot to start" failure | M. EventKit permission; attachment reading is an extra (PDFKit text) |
| 6 | **Local Gemma 4 E4B as a degraded-mode tier** (API down, 429, credit exhausted): bank hits plus a local opener instead of only an offline chip | Spec 7 currently stops calling and shows a chip; E4B is offered on 15 GB+ Macs; the owner's Mac is an M4 with 16 GB; E4B TTFT 0.4 s on M4 Max | Spec 2 and 7 (**a decision, not a default**), new route next to S/F in the brain | Resilience and zero cost when offline. **Not faster than Haiku**: my extrapolation for a base M4 is ~2 s TTFT per 1K prompt tokens and ~25 tok/s decode (unmeasured, +-50 %); 12B is out of range (9 s on a 16 GB Air). E4B needs ~3.7 GB disk and ~3.2 GB GPU memory next to Nemotron (0.6 GB) and Brave, and this Mac has 10 GiB free | L to build. First a 1-day measurement (TTFT with a 1.5K-token pack, quality on the 20 bank questions vs Haiku, memory pressure). the owner chose Max-credit-only on 2026-10-14; this stays a later option unless he reopens it |
| 7 | **Citation cards with a location**: every chip and point shows document plus page/heading/commit, one tap opens it | Foresight cards show the figure and the page it came from | Spec 5.9 chips; P1-5 overlay | Trust and faster verification in a call | S. Sources already carried in the pack; add anchors to `snippets` |
| 8 | **Visible state, never a silent no-op**: a tiny status ("listening / matched / generating / nothing to add / for others"), and a developer view that says why nothing was shown | Foresight's "Live Enhance ON" while doing nothing | P1-5 overlay, spec 5.5 "for others" | Debuggability, fewer "is it working?" moments | S |
| 9 | **Optional shorthand pad** in the overlay, expanded after the call with the transcript, plus "topics discussed but not in your notes" | Foresight's core UX and `missed_topics` | Later spec (not v1): summary-to-vault flow in spec 3 | Better post-call notes in the vault | M-L; skip for the spike |
| 10 | **Add Gemma 4 E2B/E4B audio ASR to the Turkish bench list** next to WhisperKit | Gemma audio docs: multilingual ASR, 30 s clips; Verse's Turkish path is DictationTranscriber at 18 % WER | `bench/stt-local`, `bench/whisper` | Possibly lower Turkish WER, but not streaming and 3.66 GB; low prior | S bench; **[U]** Turkish quality |
| 11 | **Policy items for the shell**: write real permission strings (what is captured, that audio is never stored, that text goes to Anthropic); no hidden launch agent or relaunch after quit; no telemetry beyond the Anthropic call | Foresight's generic strings, the relaunch job and the analytics trickle [T] | P1-5 app shell, spec 3 | Trust; avoids the criticism Foresight got | S |

Keep out of Verse: GraphRAG, 3-D knowledge map, multimodal (image/video) ingestion, Drive sync, "tokens saved" stats. They serve a general second-brain app; Verse's prep pack already does the targeted version.

## 6. What Verse already does better

| Area | Foresight | Verse |
|---|---|---|
| Echo / bleed | none; remote lines doubled on speakers [T] | bleed gate on envelope correlation; voice-processing ducking measured in P1-3 and avoided (spec 5.7) |
| Addressee | unknown, two streams only | explicit check: name, second person, turn order, pause (spec 5.5), "for others" style |
| Speed design | no latency target or stage log published | t = 0 at acoustic end, per-stage logs, tiers P/C/S/F/D, volatile-text-only acting, warm HTTP/2, hedging (spec 5, bench) |
| Answer quality | 4K-context Gemma E4B; reviewer saw empty and invented summaries | Haiku/Sonnet 5.5 with prefix caching, a prepared Sonnet answer bank, opener correction `OPENER_OK/WRONG` |
| Grounding | citations shown; no number check described | every number and name checked against the pack and greyed if absent (spec 5.6 I8) |
| Languages | English-first; French accents dropped; no language setting [T] | en/it/tr chosen per session; Turkish via DictationTranscriber, Italian via SpeechAnalyzer with measured lags |
| Own voice | mic = you, no gate | verified mic speech ends the turn (barge-in) |
| Behaviour | relaunches itself, analytics trickle [T] | none planned; spend and permissions explicit |

Where Foresight is simply ahead: fully offline and nothing leaves the Mac (Verse sends transcript turns and the pack to Anthropic); multimodal knowledge ingestion and Drive/Calendar connectors; shorthand-notes enrichment; free.

## 7. Unconfirmed items and how to close them

A runtime observation would settle ASR model names and sizes, the exact audio mechanism, RAM/CPU in a meeting, and the HUD look. It needs the owner, and a ~4.2 GB model download (this Mac has 10 GiB free, so clean up first):

1. Open Foresight, finish onboarding (models download), then start a 2-minute test: play a YouTube video through the speakers, say two shorthand lines, enable Live Assistance, ask a spoken question about one imported file.
2. Tell me when it is running. I would then only observe passively: `log stream --predicate 'subsystem contains "com.apple.coreaudio"'`, `ps`/`vmmap -summary` RSS and CPU, `ls -la` of the model folders under `~/Library`, and the helper log. No UI interaction by me.

Still unknown even then: the query detector's model, and whether the answer path checks addressee.

## 8. Sources

- Google: `developers.google.com/edge/foresight`; `developers.googleblog.com/google-ai-edge-with-embeddinggemma-2/` (2026-10-06); `blog.google/.../embeddinggemma-2`; HF `google/embeddinggemma-2`; HF `litert-community/embeddinggemma-2-740m-litert-lm`, `gemma-4-E4B-it-litert-lm`, `gemma-4-12B-it-litert-lm`; `ai.google.dev/gemma/docs/capabilities/audio` and `/core`; `policies.google.com/terms` (effective 2026-07-30) and `/terms/service-specific`.
- Press: TechCrunch 2026-10-08; The Verge; 9to5Google 2026-10-06; How-To Geek 2026-10-08; explainx.ai (2026-10-08, summary of Google's post).
- Third party: talat.app/blog/google-ai-edge-foresight (competitor; 2026-10-09, updated 10-11; static analysis and network trace); YouTube "Foresight Explained in 5 Minutes" (2026-10-10, repeats Google and talat figures); PlayCISO checklist (generic, no measurements). GitHub issues `google-ai-edge/litert-lm#2181`, `#2498` (speculative decoding on macOS) and a community benchmark where speculative decoding on Metal was ~12 % slower for E2B on an M4 Max.
- Local: `Contents/Info.plist`, `codesign -d --entitlements -`, `otool -L`, `Resources/macos_prod.assets/NativeAssetsManifest.json`, `lib/assets/on_device_model_configure.json`, `lib/assets/about.txt`, `NOTICES.Z`, `~/Library/Application Support/com.google.AIEdgeForesight/` (schema only).
