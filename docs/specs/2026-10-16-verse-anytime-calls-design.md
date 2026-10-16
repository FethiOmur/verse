# Verse: anytime calls (manual start, "me" layer, phone calls, it/tr)

Status: decided 2026-10-16. the owner's rule applies: after a spec, build. The three questions in section 9 are the only
open points, and none of them blocks phase A.
Research and sources: `docs/research/2026-10-16-anytime-calls-research.md`.

## 1. Goal

Today Verse starts only when a meeting app takes the microphone, or from the menu, and only with a prepared session.
It listens in the session's one language, which in practice means English. Alex asked (16 Oct) for four changes:

1. **Start anytime.** Start Verse by hand, at once, from anywhere (menu bar, hotkey, island), with or without a
   prepared session. The example is a phone call he puts on speaker.
2. **A permanent "me" layer.** Verse always knows his experience, projects, skills, numbers and stories. Meeting prep
   (pack plus bank) still goes on top when he has prepared. An unprepared call runs on the me layer alone.
3. **Phone calls.** First (a), the iPhone call is answered on the Mac (Continuity), so the remote voice is a separate
   channel as in meetings. Second (b), the phone is on speaker next to the Mac, and Verse separates his voice from
   the other person's on the one mic.
4. **Languages.** Listening, question detection, follow-my-answer and the answers work in English, Italian and
   Turkish. Answers come in the language being spoken.

## 2. Decisions

### 2.1 Manual start

| Topic | Decision |
|---|---|
| Triggers | **⌥⌘V** (Carbon hot key, registered at launch and always on). Also: menu bar "Start now" and the island's idle state (click). A Start on the meeting prompt (state 0) works as before. |
| ⌥⌘V while running | First press shows the island status "Press ⌥⌘V again to stop" for 2 s. A second press inside that window stops the session (summary as usual). One stray press never ends a call. |
| Session choice | If a prepared session is linked to a calendar event within ±15 min of now (the existing `eventMap`), use it. Otherwise start **unprepared**: create `sessions/adhoc-YYYYMMDD-HHMM-<route>/` with `meta.json {"kind":"adhoc","mode":"unprepared","route":…,"lang":…}` and an empty `pack.md`. Nothing is prepared and there is no wait. |
| Audio route | Picked automatically at start, in this order: **phone** (a Continuity call is active, phase B) → **meeting** (a known meeting app holds the mic, today's detector) → **room** (mic only). The island start card shows the route chip. A click changes it before or during the session (an engine restart, ≈ 1 s gap). |
| Room route before phase D | The mic feeds the **remote** pipeline with speaker label `room`, and there is no `me` channel. Auto cards fire only for turns with a question cue and ≥ 6 words. The **card-now** hot key covers everything else. Follow mode is off in room route. D replaces this with real separation. |
| Card now | **⌥⌘↩**, registered only while a session runs (like `SimHotKey`). It answers the latest remote/room turn at once: the current partial if one is open, otherwise the last final. This skips cue, kind and addressee gates. The brain gets `control{action:"card_now"}`. |
| Language at start | Settings → Meetings → "Default call language" (en, default). The island's language chip (EN/IT/TR, plus AUTO once C3 ships) switches it during a session: an engine restart plus `control{action:"lang"}`. No hot key: the free ⌥⌘ combinations clash with Finder. |
| Labelling | The island's right wing shows "Unprepared" for adhoc sessions. Sessions page rows carry an "Unprepared" tag and the route ("Phone", "Room", "Meeting"). |

### 2.2 The me layer

| Topic | Decision |
|---|---|
| Files (never committed) | `~/Library/Application Support/Verse/profile/`: `me.md` (the core, human-readable, editable), `me.meta.json` (model, spend, built_at, token count, per-source sha256, generated line hashes, deleted ids), `me.sources.json` (the source list), `me.notes.md` (free notes Alex types in the home window), `me.facts.jsonl` (the NUMBERS lines in the `facts.jsonl` schema, for Swift's fact chips and the grounding check), `me.library.jsonl` plus `me.library.emb` (retrieval chunks and their EmbeddingGemma vectors, float16, keyed by model sha). Test fixtures use a fictional person, "Dana Reyes". |
| Default sources | `~/Downloads/ENGINEERING_PROFILE.md`; the vault (read-only, plain file reads, never `beyin.py`, never a write): `🏰 300-Projects/Projects.md` and the top-level note of each project folder except `AgentLogs/` (1.35 MB of agent output) and `Archive-Private/`; `facts.jsonl` of every non-sample session (not bank answers: those are meeting-specific); `me.notes.md`. Never the vault's `400-Private`, `700-Health`, `800-Journal`, `850-Notes`, `daily`, `receipts` or Inbox. Alex adds or removes any source in the home window (.md, .txt, .pdf through the existing `pypdf` reader). |
| Distillation | `python -m verse_brain.prep me build` runs Sonnet 5.5 at effort high, the prep tuple, in one call over all `core` sources (≈ 15k tokens in, ≤ 4k out, ≈ $0.07). Every line must carry a source quote that `prep/sources.py` verifies in the source text. A line that fails verification is dropped, except MY NOTES. |
| Refresh | `prep me refresh` rebuilds only when a source sha256 changed, and keeps the owner's edits. A line whose current sha256 differs from its generated hash counts as edited and is kept verbatim. Ids he deleted stay deleted. Runs from the home window's **Refresh** button. At launch, if a source changed and the last build is older than 7 days, the Me page shows "Sources changed · Refresh". Refresh never runs or spends on its own. |
| Format (`me.md`) | Sections in this order, one line per item with an id, in the pack's style: `## WHO I AM` (3–5 lines `[m0xx]`), `## EXPERIENCE` (`[m1xx] years \| role \| org \| one line \| src`), `## PROJECTS` (`[m2xx] name \| what \| my role \| stack \| numbers \| src`), `## SKILLS` (`[m3xx] skill \| evidence \| src`), `## NUMBERS` (`[m4xx] kind \| text \| value \| src`), `## STORIES` (`[m5xx] title \| situation, action, result ≤ 60 words \| src`), `## LOOKING FOR` (`[m6xx]`: role, location, availability, only what the sources state), `## MY NOTES` (his lines, src `owner`, never regenerated). English. Answers translate at call time. |
| Size | The core is ≤ **3,500 tokens** (counted with `count_tokens` at build, written to meta). Trim order when over: STORIES tail, SKILLS tail, PROJECTS tail, EXPERIENCE tail. NUMBERS, WHO I AM and MY NOTES are never trimmed; if they alone exceed the cap, the build fails with a message. |
| Library (when too big) | Sources are split by heading into chunks of ≤ 1,500 chars, at most 400 chunks, and embedded at build time. At runtime the brain's existing embedding thread retrieves the top 3 chunks (cosine ≥ 0.80, start value, tuned in A1 tests) for the current remote turn. It runs on the same partials as the bank matcher (≥ 5 words), and the hits are kept per turn. **F never waits**: it uses the hits that exist at its endpoint. D waits ≤ 150 ms for a final-text retrieval. Chunks go into the **uncached tail** as `FROM USER'S FILES:` (≤ 1,200 tokens). In prepared sessions it is at most 2 chunks, and chunks whose source is already a pack snippet are skipped. |
| Cache layout | system → **ABOUT OWNER block (BP0)** → MEETING PACK block + transcript header (BP1) → finalized turns (BP2 every 4) → tail. That is 3 breakpoints of the 4 allowed. Without a pack, the pack block is the fixed line `(none: unprepared call)`. The ABOUT OWNER block is `me.md` read once at `start` (edits apply from the next session), plus the STYLE GUIDE (`voice.md`) **only when the pack has none**. It is byte-identical across sessions, so a session that starts within the TTL of another reuses BP0. Both blocks use the 5-minute TTL with the existing keep-alive: no 1-hour TTL, because the keep-alive already holds the cache warm. |
| Cost | The core adds ≤ 3.5k cached tokens per call: a Haiku read is ≈ $0.00004, a Sonnet write per session ≈ $0.009. Retrieval adds ≤ 1.2k uncached Haiku tokens per call, ≈ $0.00012. No cap (Alex). |
| Merge with a pack | Both always go in. **The meeting pack wins on conflict.** It was built and checked for this meeting, and the system prompt says so. At `start` the brain compares me NUMBERS with pack FACTS: a pair counts when its labels share ≥ 50 % of content words (Jaccard) and its numbers differ. It sends `notice{kind:"me_conflicts",items}`. The Me page and the session report list them. Nothing is rewritten at runtime. |
| Grounding | Live tiers may state numbers, dates and names from ABOUT OWNER, the pack, or retrieved chunks, and cite them (`me:m412`, `lib:<chunk id>`). Swift's fact chips and the "not in your notes" check load `me.facts.jsonl` next to the session's `facts.jsonl`. |
| Toggle | Settings → Meetings → "Use my profile in every session" (default **on**). Off: `start.me` is null and the prefix is today's. |
| Local fallback (G1 Gemma) | Prefix budget stays 9,500 chars. With a pack: me WHO I AM + NUMBERS + PROJECTS ≤ 3,000 chars, and the pack is cut to 6,500 by the existing trim. Unprepared: me core ≤ 9,500 chars by the same trim order. |
| UI | A new home-window page, **Me** (sidebar between Prepare and Sessions, SF Symbol `person.text.rectangle`). Rows follow the redesign's grouped-row pattern: the sections of `me.md` (inline edit per line, delete, add a note), Sources (toggle, Add file…, Add note), "Built 16 Oct · 3,140 tokens · $0.07", **Refresh**, and Conflicts from the last session. No separate mockup: tokens and patterns come from the UI redesign spec. |

### 2.3 Unprepared calls

| Topic | Decision |
|---|---|
| What is answered | Remote `question` turns: S/F/D as today, grounded in the me layer. Remote `statement` turns of ≥ 4 words go to the existing statement probe (KIND line). Its NONE/acknowledgement rule already fits general conversation. Fragments: nothing. Card-now: always. |
| Bank | None. The F answer's BANK line is `none`. Swift's n-gram matcher and the embed matcher are idle. |
| D | Runs as in prepared sessions, citing `me:`/`lib:` refs. |
| Summary | As today, into the adhoc session folder. The vault save stays opt-in. |

### 2.4 Phone calls

| Topic | Decision |
|---|---|
| (a) Continuity, phase B | The phone route captures the remote voice with a **global output tap that excludes Verse's own process** (`CATapDescription(stereoGlobalTapButExcludeProcesses:)`), same permission as today. Spike B0 lists the processes running output during a real call. If it finds exactly one Apple process that carries the call, the route narrows to a PID tap on it (the existing `pidList` route). Otherwise it stays global and the island says "Pause other audio during the call". The mic is the `me` channel with the existing bleed gate. |
| Detection | `MeetingApp.known` gains "Phone" (`com.apple.FaceTime` plus whatever B0 finds). Mic input by it raises the meeting prompt with "Phone call · Start ↩". |
| If B0 finds nothing tappable | The phone route is withdrawn. The island then suggests "Put the call on the Mac speaker" and uses the room route (phase D separation). Only the B1 unit is dropped; B0's evidence goes into the research note. |
| (b) Speakerphone, phase D | The room route splits the one mic into `me` and `remote` by voice. |
| Voiceprint | Settings → Voice → "Teach Verse your voice": three prompted sentences of ~8 s (any of his languages). WeSpeaker embeddings are computed in memory; only `profile/voiceprint.json` (model id, dim, centroid, count, created_at) is written. **No audio is stored** (the v1 rule). |
| Separation | FluidAudio streaming diarizer on the mic, which gives up to 4 slots. Each slot is labelled after ≥ 2.0 s of its speech: cosine of the slot's WeSpeaker embedding (`DiarizerManager.extractSpeakerEmbedding`) to the centroid, ≥ θ (tuned on D0, start 0.55) → `me`, else `other`. The label is re-checked every 10 s of slot speech. Frames of `me` slots feed the me pipeline and all other frames feed the remote pipeline, after a 0.6 s hold; overlap goes to remote. The bleed gate and EchoGuard are **off** in split mode, because both channels come from the same mic and would cancel each other. Everything else downstream (TurnEngine, follow) is unchanged. |
| Diarizer pick | D0 benches Sortformer and LS-EEND on the recorded speakerphone fixtures. The higher frame accuracy wins; on a tie, Sortformer. The docs warn that Sortformer may miss quiet speech, and a phone speaker is quiet. |
| Without a voiceprint | Room route stays as in 2.1 (no split), and the island offers "Teach Verse your voice". |

### 2.5 Languages

| Topic | Decision |
|---|---|
| STT now (C2) | The Apple engines already wired: it → `SpeechTranscriber`+`.fastResults` (last-word lag p50 0.79 s), tr → `DictationTranscriber`+`.frequentFinalization` (p50 0.52 s, WER 18 % on TTS). en stays Nemotron EN. |
| STT target (C3) | Nemotron 3.5 ASR streaming multilingual (FluidAudio `StreamingNemotronMultilingualAsrManager`, already in pinned 0.17.7). It covers it and tr, and AUTO, from one model with language ID. Italian uses the `latin` folder, Turkish and AUTO use `multilingual`, at the 560 ms tier with a stream reset after ≥ 2 s of silence. Model files are read from `~/Library/Application Support/Verse/models/nemotron-3.5-multilingual/<folder>/560ms/` and never downloaded by the app (the same policy as Nemotron EN). **Switch rule:** per language, C3 replaces the Apple engine only when, on the existing 20-question bench corpus, its last-word lag p90 ≤ Apple's + 0.1 s and its WER ≤ Apple's. Otherwise Apple stays. Blocked on model access (question 1). |
| Rejected STT | Whisper (no native streaming, 1.5–3.2 GB next to Gemma + EmbeddingGemma); Parakeet v3 (no Turkish). |
| Answer language | Per turn. `turn`/`partial` carry an optional `lang` (C3's detected tag, or the session language). The brain uses the turn's lang, else the session's. The system prompts become language-neutral ("simple B1–B2 level in the answer language"), a one-time cache change. The tail keeps `Language: <name>`. ABOUT OWNER, bank and STYLE GUIDE stay English and are answered from in the turn's language: names and numbers unchanged, everything else translated. |
| Question detection | `Cues` it/tr lists grow. **it:** `come, perché, perche, quando, dove, quale, quali, chi, cosa, che cosa, quanto, quanti, può, puoi, potrebbe, potresti, mi racconti, mi parli, raccontami, parlami, secondo te, sapresti`. **tr:** the question particle in every person (`mı mi mu mü` and `-sın/-sin/-sun/-sün/-sınız/-siniz/-sunuz/-sünüz` attached forms such as `mısınız`), `ne, neden, niye, nasıl, nerede, nereden, hangi, kim, kaç, ne zaman, acaba, anlatır mısın, anlatabilir misin, bahseder misin`. Addressee second-person forms: it `tu/ti/te/Lei/La/Le`, tr `sen/siz/sana/size/seni/sizi`. The statement probe remains the safety net. |
| Paraphrase matcher and follow in it/tr | Per-language thresholds (`embed_threshold_by_lang`, `embed_margin_by_lang`, follow thresholds) are calibrated on committed fictional fixtures (30 paraphrase pairs and 10 distractors per language, plus follow cases). A language joins `embed_langs` / `follow_langs` only when its fixtures pass (wrong-hit ≤ 5 %, follow detector cases green). Until then it/tr run without them, as today. `follow.py` gains it/tr stop and filler lists and a stemmer per language: Italian light suffix stripping; Turkish the first 5 letters after lowercasing with Turkish İ/ı rules. |

### 2.6 Rejected

- **Start only with a prepared session.** Sudden calls are the point.
- **Putting the me layer inside each pack at prep.** Every pack would need a rebuild after each edit, and unprepared
  calls would have nothing. A separate block keeps one stable cached prefix.
- **The whole vault in the prefix.** It is far over budget and mostly irrelevant. Distil a core and retrieve the
  rest.
- **Live `beyin.py` retrieval.** v1 rule B8: no subprocess and no vault access on the live path.
- **1-hour TTL for ABOUT OWNER.** The keep-alive already holds the 5-minute cache. 2× write cost for nothing.
- **ScreenCaptureKit for phone audio.** Process and global taps are already the capture path and need no screen
  permission.
- **Storing an enrollment voice clip** (default; see question 2). It conflicts with "no audio is stored".
- **Language hot key.** ⌥⌘L and the number keys collide with Finder. The island chip and the menu are enough.
- **Per-frame (0.5 s) speaker verification.** Short-segment EER is several times worse. Decide per diarizer slot over
  ≥ 2 s.

## 3. Protocol (additive; current messages unchanged)

Swift → brain:
- `start` gains:
  - `"mode": "prepared"|"unprepared"` (absent = prepared);
  - `"route": "meeting"|"phone"|"room"` (absent = meeting);
  - `"me": {"core": "<path to me.md>", "library": "<path to me.library.jsonl>", "facts": "<path to me.facts.jsonl>"}`
    or `null` (absent = null: today's behaviour);
  - `"room_auto": "questions"|"off"` (room route only; default `questions`).
- `partial` / `turn` gain:
  - optional `"lang"` (`en|it|tr`);
  - `speaker` may be `"room"` (room route before D; the brain treats it like `remote`, but `addressee` is always
    `unknown` and statement probes are skipped when `room_auto` is `questions`).
- `control{action:"card_now"}`: answer the latest remote/room turn now.
- `control{action:"lang","lang":"it"}`: the session language from now on (the engines restart on the Swift side).

Brain → Swift:
- `notice{kind:"me_conflicts","items":[{"me":"m412","pack":"f003","topic":str}]}`, once after `start`.
- `notice{kind:"me_missing"}` when `start.me` paths don't exist: the session runs without the layer.
- The `ready` status gains `me:{tokens:int,built_at:str}` (or `me:null`).
- `metric` stages: `me_retrieval` (ms, hits, top score), `card_now` (ms to first token).
- Cards from card-now are normal `delta`s on a new turn id `now-<n>`, so the overlay needs no new card type.

Swift's brain-event decoder must ignore unknown types. A test asserts that `notice` does not break an older build of
the reducer.

CLI (brain prep):
- `python -m verse_brain.prep me build|refresh [--fake] [--budget-usd 0.5]`: stdout is the profile dir. The cost is in
  meta.
- `python -m verse_brain.prep me show`: prints token count, sections, sources and stale sources.
- Keys come from the environment as today, never argv.

## 4. Phases and units

Each phase ships on its own. Executors are Sonnet (`worker` / `worker-hard`). Briefs name the files below and nothing
more. Python runs as `VERSE_PY=/Users/user/Desktop/ProjectExamples/CursorExamples/Verse/brain/.venv/bin/python`.
Each executor works in its own worktree from `main`.

**Budget:** the weekly window is at 87 % until 19 Oct 21:00. A1 (brain) and A2 (Swift, non-UI) fit before the reset.
A3 (UI) waits until `ui-home` / `ui-island` merge, because it touches their files. B0 needs Alex on a real call for
about 10 min. C and D start after the reset. B and C touch disjoint files and may run in parallel.

### Phase A: manual start and the me layer (English). Size: M (3 packages)

**A1 brain** (`worker-hard`):

Files:
- new `prep/me.py` (build, refresh, chunking, verification through `sources.py`, trim, meta, facts export);
- `prep/__main__.py` (the `me` subcommand);
- new `runtime/me.py` (load, render the ABOUT OWNER block, library retrieval on the embedding thread, conflicts);
- `runtime/prompt.py` (the ABOUT OWNER block with BP0, the empty-pack line, `FROM USER'S FILES` in the tail, a
  `card_now_tail`, system prompts that name ABOUT OWNER as grounding and "the meeting pack wins on conflict");
- `runtime/engine.py` (start fields, card_now, lang control, `room` speaker, notices, metrics);
- `runtime/protocol.py`, `runtime/settings.py` (retrieval thresholds and caps), `runtime/local_llm.py` (the
  fallback budget split), `runtime/fake.py`;
- new tests `tests/test_prep_me.py`, `tests/test_runtime_me.py`, `tests/test_runtime_unprepared.py`;
- fixtures `tests/fixtures/me/` (fictional Dana Reyes: a profile .md, two vault-style notes, one facts.jsonl).

Tests:
- build with a fake model: a line whose quote is not in the source is dropped;
- the trim order holds at the cap; NUMBERS are never trimmed;
- refresh keeps an edited line and a deleted id, and skips unchanged sources;
- `me.facts.jsonl` is in the `facts.jsonl` schema;
- the rendered block is byte-identical for the same input, and every request in a session shares it (layout test,
  as `test_runtime_layout.py` does for the pack);
- breakpoint count ≤ 4 on every route;
- an empty pack gives the `(none: unprepared call)` line and still 3 breakpoints;
- retrieval with a fake embedder: top-3 above the floor, F never awaits it, D waits ≤ 150 ms, and pack-snippet sources
  are skipped;
- conflicts: a differing number on a shared label gives one notice item; equal numbers give none;
- `card_now` with an open partial answers the partial; with none, the last final; with no remote turn, a status
  message;
- a `room` speaker turn without a cue in `questions` mode fires nothing; with a cue and ≥ 6 words it fires F;
- `start.me` null → requests are byte-identical to today's (golden request from `test_runtime_layout.py`);
- the G1 fallback prompt stays ≤ 9,500 pack chars with the me layer.

Acceptance: `cd brain && $VERSE_PY -m pytest tests/test_prep_me.py tests/test_runtime_me.py
tests/test_runtime_unprepared.py tests/test_runtime_layout.py tests/test_runtime_ipc.py -q`

Then one live build on the owner's real sources (writes only to his profile dir; prints tokens and cost) and one live
unprepared replay of `eval/twotrack/t03.json` with the pack removed. The report quotes the first card and checks its
numbers against `me.md` by hand.

**A2 Swift core** (`worker-hard`):

Files:
- `VerseTurns/Wire.swift` (`start` fields, `card_now`, `lang` controls; decoder ignores unknown brain events);
- `VerseTurns/VerseRunner.swift` (RunOptions `mode`, `route`, `me`, `roomAuto`);
- `VerseTurns/TurnEngine.swift` (the `room` speaker path: remote pipeline, addressee unknown, cue gate);
- `VerseSpeech/ListenTypes.swift` (`ListenConfig.micAsRemote`) and `ListenSession.swift`;
- new `VerseUI/QuickStart.swift` (route pick, session pick, adhoc folder creation through `SessionCatalog`);
- new `VerseUI/GlobalHotKeys.swift` (⌥⌘V always, ⌥⌘↩ during a session; the Carbon pattern of `SimHotKey`);
- `VerseUI/VerseController.swift` (start without a prepared session; the stop-confirm window);
- `VerseUI/AppSettings.swift` (`useMeProfile`, `defaultCallLanguage`, `roomAutoCards`);
- tests in `VerseTurnsTests`, `VerseSpeechTests`, `VerseUITests`.

Tests:
- route pick for a fake environment (phone flag, meeting app holding the mic, neither → room);
- session pick: an event within ±15 min with a mapped session → prepared; none → an adhoc folder with meta.json and
  an empty pack.md;
- `start` JSON golden with all fields;
- room route: a mic-only memory clip produces `room` turns and no `me` turns;
- double-press stop logic with an injected clock;
- settings persistence.

Acceptance: `cd app && swift test --filter 'VerseTurnsTests|VerseSpeechTests|VerseUITests.QuickStart|VerseUITests.Settings'`
and `swift build -c release`.

**A3 Swift UI** (`worker-hard`; starts after `ui-home` and `ui-island` are merged into `main`):

Files:
- the island start card and wing chips (route, language, "Unprepared") in the redesign's `OverlayView` / state model;
- the menu bar "Start now ⌥⌘V" with Route and Language submenus;
- the home window **Me** page (new `VerseUI/MePage.swift` + `MeModel.swift`, which runs `prep me build|refresh|show`
  with the existing prep-runner pattern, keys never on argv);
- the Sessions list "Unprepared" tag;
- Settings → Meetings rows (2.2 toggle, default language, room auto cards).

Tests:
- `MeModel` parses `me.md` into sections and lines; an inline edit writes the file and keeps ids;
- runner (fake) refresh flow;
- one offscreen render each of the Me page (light and dark) and the island start card in room route, unprepared,
  looked at.

Acceptance: `cd app && swift test --filter 'VerseUITests'` and `swift build -c release`, plus the two renders read
with the Read tool.

### Phase B: Continuity phone calls. Size: S spike + M package

**B0 spike** (`worker`, about 10 min of the owner's time):

- Add `verse-listen --probe-output SECONDS`. Once a second it prints every Core Audio process object with pid,
  bundle ID, IsRunningInput and IsRunningOutput. No audio is read.
- Alex answers one real cellular call on the Mac (his second number or a person who agreed). The output goes into
  the research note, section 1.
- Then `verse-listen --route phone --seconds 60` (global output tap) during a second call. It must print remote
  transcript lines.

Decision rule: one Apple process carrying the call output → PID route; else global. No samples from either → the
phone route is withdrawn (2.4).

**B1** (`worker-hard`):

Files:
- new `VerseAudio/GlobalOutputTapSource.swift` (global tap excluding Verse's own process object; same aggregate-device
  pattern as `ProcessTapSource`, no output sub-device);
- `VerseAudio/ProcessTapSource.swift` (a process-name match for the PID route if B0 found a daemon);
- `VerseSpeech/ListenTypes.swift` (`remoteRoute: .meetingApps([String]) | .phone | .none`);
- `VerseMeet/MeetingDetector.swift` (the Phone entry);
- `VerseUI/MeetingPrompt.swift` ("Phone call");
- `VerseUI/QuickStart.swift` (phone flag);
- tests in `VerseAudioTests` / `VerseMeetTests`.

Tests:
- route selection;
- the detector fires "Phone" for a fake process list holding input;
- the global tap's exclude list contains our own process object;
- the island hint when other output is playing (fake level).

Acceptance: `cd app && swift test --filter 'VerseAudioTests|VerseMeetTests|VerseUITests.QuickStart'`, then one live
call (Alex): remote questions on the remote channel, his answers on `me`, and no false `me` turns from speaker bleed
in the 2-minute check (bleed gate log).

### Phase C: Italian and Turkish. Size: S + M, plus a gated M

**C1 brain** (`worker-hard`):

Files:
- `runtime/prompt.py` (language-neutral system prompts, per-turn language in tails);
- `runtime/engine.py` (turn `lang`);
- `runtime/settings.py` (per-language thresholds, `embed_langs` / `follow_langs` driven by them);
- `runtime/follow.py` (it/tr stop, filler and stemmer);
- new fixtures `tests/fixtures/lang/{it,tr}/` (fictional, committed: 30 paraphrase pairs + 10 distractors per
  language for the bank; 5 follow cases per language as in `test_follow_detector.py`);
- new tests `tests/test_runtime_lang.py`, `tests/test_follow_lang.py`;
- `eval/tune_follow.py` and a new `eval/tools/calibrate_embed_lang.py`. These run EmbeddingGemma live, once, and write
  the thresholds into `settings.py` with the numbers in `docs/follow-tuning.md`.

Tests:
- a turn with `lang:"tr"` gets `Language: Turkish` in every tail;
- a missing `lang` uses the session's;
- the system prompts contain no "English" style rule;
- stemmer cases: tr "anlattım/anlatır/anlatmak" → one stem, it "progetti/progetto" → one stem;
- the follow detector cases per language (reading the card verbatim → no divergence; off-card → divergence within 5
  content words);
- calibration: wrong-hit ≤ 5 % at the chosen threshold, recorded;
- a language below the bar is kept out of `embed_langs`.

Acceptance: `cd brain && $VERSE_PY -m pytest tests/test_runtime_lang.py tests/test_follow_lang.py
tests/test_follow_detector.py tests/test_runtime_follow.py -q`

**C2 Swift** (`worker`):

Files:
- `VerseTurns/Cues.swift` (the lists in 2.5, Turkish attached question suffixes);
- `VerseTurns/TurnEngine.swift` (addressee forms; `lang` on partial/turn);
- `VerseTurns/Wire.swift`;
- `VerseUI/VerseController.swift` (the language switch: stop the listen session, restart with the new lang, send
  `control lang`);
- tests in `VerseTurnsTests`.

Tests:
- cue tables (each listed form → cue; ten Italian and ten Turkish statements → no cue);
- the addressee forms;
- the language switch emits one `control lang`, and no turn is lost across the restart (memory clip).

Acceptance: `cd app && swift test --filter 'VerseTurnsTests'`, then one live 5-minute call per language (Alex; a
second device or TTS on a speaker): questions detected, answers in the call's language.

**C3 Nemotron multilingual** (`worker-hard`; **blocked on question 1**):

Files:
- new `VerseSpeech/NemotronMultilingualEngine.swift` (wraps `StreamingNemotronMultilingualAsrManager`, `setLanguage`
  with `it-IT`/`tr-TR`/`auto`, reset after ≥ 2 s silence, exposes `detectedLanguage()` per result as `lang`);
- `VerseSpeech/TranscriptionEngine.swift` (the `nemotronMultilingual` kind; `.auto` for it/tr uses it when the bench
  gate file says so);
- `VerseSpeech/SwitchingEngine.swift` (it/tr like en);
- `bench/stt-local` (the it/tr corpus run: last-word lag p50/p90, WER, RSS);
- the island AUTO chip.

Tests:
- engine factory routing (it → latin, tr/auto → multilingual);
- a missing model folder → the Apple engine with an `engine_fallback` status;
- the gate file is read.

Acceptance: `cd app && swift test --filter 'VerseSpeechTests'` and the bench run, with its table appended to
`bench/RESULTS.md`. The switch rule in 2.5 decides per language.

### Phase D: speakerphone separation. Size: L (spike + 2 packages)

**D0 fixtures and bench** (`worker-hard`, with about 20 min of the owner's time):
- Six 2-minute speakerphone recordings from a fictional script: Alex on the Mac mic, the other side a TTS voice
  played through the iPhone speaker on a call, 2 each in en/it/tr.
- They are stored outside the repo at `~/Library/Application Support/Verse/fixtures/speakerphone/`. They are test
  material Alex records on purpose, not session audio.
- Hand labels: who speaks when (`labels.json`).
- Bench Sortformer vs LS-EEND (`bench/diar/`): frame accuracy for me/other, added latency, RSS. The winner per 2.4.

**D1 voiceprint** (`worker`):

Files:
- new `VerseSpeech/VoicePrint.swift` (enrollment from in-memory buffers, centroid, JSON store, no audio file);
- the Settings → Voice row and the enrollment sheet (3 prompts, a level meter, "Done");
- tests.

Tests: centroid math; the file holds no samples (size bound and schema); re-enrollment replaces the centroid.

**D2 split** (`worker-hard`):

Files:
- new `VerseSpeech/SpeakerSplitSource.swift` (mic → diarizer → slot labelling → two `AudioCaptureSource`s with a
  0.6 s hold);
- `ListenEnvironment` (room route with a voiceprint → split);
- `VerseUI/QuickStart.swift` (the "Teach Verse your voice" hint);
- tests with D0 fixtures loaded as memory clips (skipped when the folder is absent).

Tests:
- a slot labelled `me` after 2 s of enrolled-voice audio;
- a stranger slot labelled `other`;
- overlap frames go to remote;
- labels re-checked at 10 s;
- an end-to-end memory run turns remote questions into `remote` turns and the owner's answers into `me` turns.

Acceptance: `cd app && swift test --filter 'VerseSpeechTests.SpeakerSplit|VerseSpeechTests.VoicePrint'`, then the
D0 replay (`verse-run --file` on each fixture with `--route room`). Pass when frame me/other accuracy ≥ 90 %,
question turns attributed to remote ≥ 90 %, and added ASR lag ≤ 0.8 s p90.

## 5. Tests (summary)

The unit tests are listed per package above. Cross-cutting:

- **Privacy:**
  - a filesystem watch during an A2 room session and a D2 split session shows no audio file written;
  - `profile/` and `fixtures/` never appear in `git status` (they are outside the repo);
  - no key in logs (the existing grep check).
- **Cache:** across 5 consecutive F calls in an unprepared replay, `cache_read_input_tokens` ≥ the ABOUT OWNER block's
  tokens on calls 2–5 (from the `metric` usage).
- **Regression:** with `start.me` null and mode prepared, the existing replay `eval/run_twotrack.py` t02 gives the same
  card count and no new follow calls.

## 6. Done means

- **A:**
  - with no prepared session, ⌥⌘V starts listening in under 2 s;
  - an unprepared replay's first card cites `me:` facts that match `me.md`;
  - Alex edits a line on the Me page, presses Refresh, and the edit survives;
  - ⌥⌘↩ answers the last thing the other person said.
- **B:** on a real Continuity call, the remote voice transcribes on its own channel and questions get cards as in a
  Meet call. Or B0's evidence shows it can't be done, and the phone route is withdrawn with the reason recorded.
- **C:** a live Italian and a live Turkish call each get cards in that language. it/tr join the paraphrase matcher and
  follow mode only where their fixtures passed. With model access, C3's bench decides the engine per language.
- **D:** on the speakerphone fixtures, Verse separates Alex from the other person at ≥ 90 % frame accuracy, and the
  island shows the same cards as on a headset call, at most 0.8 s later.

## 7. Later (not this spec)

- Calendar and Notes as me-layer sources (Alex, 16 Oct, follow spec).
- A per-meeting "role" for the me layer (interview vs client call) that picks which sections lead.
- Auto language without C3 (Apple language ID): not planned, because C3 covers it.
- Phone-speaker cue (telephone band energy) as a second feature for D's labelling, if D0 shows slot errors.

## 8. What changes for Alex day to day

- He presses ⌥⌘V at the start of any call.
- He prepares as before when he has time; when he hasn't, Verse still knows him.
- He keeps the Me page right, and Refresh picks up his new projects.

## 9. Questions only Alex can answer

1. **Nemotron 3.5 multilingual model access.** FluidInference gates the CoreML repo on Hugging Face ("join the
   Discord and message Sisyphu"). Will you request access, or should Verse stay on the Apple engines for it/tr (C3
   skipped)? Phases A–D don't depend on it.
2. **Voice enrollment storage.** The default stores only a voiceprint (numbers, no audio). Keeping a ~25 s voice clip
   in the profile folder would allow Sortformer's native pre-enrollment, which is likely more accurate, but it breaks
   the "no audio stored" rule for that one file. Keep the default?
3. **Live test calls.** B0/B1 need one real cellular call answered on the Mac, and C2 and D0 need short calls in
   it/tr. Who is on the other end: your second number, or a person who agreed? And when?
