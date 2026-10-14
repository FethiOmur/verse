# Verse interview simulation plan

Goal: a practice-interview mode built from the user's experience and a job posting (spec approved by Alex 2026-10-14).
Spec: docs/specs/2026-10-14-verse-interview-sim-design.md
Approach: extend prep with a sim pack, add a half-duplex `sim` runtime and a report builder to the brain, add a
Swift voice module and a posting fetcher, then wire a setup window, the practice capsule and the report window
into the app.
Global constraints:
- Brain calls only through the existing Anthropic transport and route tuples in `brain/verse_brain/runtime/settings.py`
  (Haiku for ask/judge/coach, Sonnet for sim prep and grading). No spend cap (Alex).
- Keys only from the Keychain: `verse-anthropic` (brain reads it), `verse-elevenlabs`, `verse-openai` (Swift reads them);
  account = login user name. Never logged, printed, written, or passed on a command line.
- No audio written anywhere. English first; `lang` stays a parameter.
- macOS 26, Swift 6 language mode; Python ≥ 3.12 with `brain/.venv` (lives only in the main checkout; worktrees
  symlink it, untracked).
- Commits: each package on its own branch in its own worktree, pushed; the orchestrator merges.
Packages: 6. S1, S2, S3, S4a, S5 run in parallel (disjoint files, separate worktrees). S4 starts after S2, S3,
S4a and S5 are merged.

Checklist:
- [ ] S1 Sim prep · [ ] S2 Sim runtime · [ ] S3 Voices · [ ] S4a Posting fetch · [ ] S5 Report · [ ] S4 App integration

## Shared contracts (every package uses these names exactly)

**Session folder** `~/Library/Application Support/Verse/sessions/sim-<YYYYMMDD-HHMM>-<company-slug>/`:

| File | Written by | Contents |
|---|---|---|
| `posting.txt` | S4 (app) / S1 CLI | the posting text the user confirmed |
| `sim.json` | S1 | the sim pack, schema below |
| `sim_pack.md` | S1 | deterministic markdown render of `sim.json` (the runtime's cache prefix; byte-identical for identical input) |
| `sim_results.json` | S2 | the transcript and coach notes, schema below |
| `grades.json`, `report.json`, `report.html` | S5 | the graded report |

`sim.json`:
```json
{"session_id": "...", "created_at": "ISO-8601", "lang": "en", "company": "...", "role": "...",
 "interview_type": "screening|manager|technical|mixed", "difficulty": "friendly|standard|tough", "length_min": 30,
 "posting": {"source_url": "https://...|null", "text_path": "posting.txt", "sha256": "..."},
 "competencies": [{"id": "c1", "name": "...", "posting_quote": "exact sentence from the posting"}],
 "evidence": [{"id": "e1", "kind": "project|metric|story|skill", "text": "...",
               "sources": [{"kind": "cv|note|vault|commit", "ref": "...", "quote": "..."}]}],
 "questions": [{"id": "q1", "kind": "opener|behavioural|role|technical|motivation", "text": "...",
                "competency_ids": ["c1"], "evidence_ids": ["e1"], "follow_ups": ["..."], "target_s": [60, 120]}],
 "rubric": {"c1": {"1": "...", "3": "...", "5": "..."}},
 "warnings": ["..."], "prep_model": "claude-sonnet-5-5", "prep_usage": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0}}
```

`sim_results.json`:
```json
{"session_id": "...", "mode": "coach|realistic", "voice": "apple|elevenlabs|openai|text", "started_at": "...", "ended_at": "...",
 "questions": [{"q_id": "q1", "asked": [{"id": "s1", "text": "interviewer line", "kind": "question|follow_up|push|repeat"}],
                "answers": [{"text": "...", "t_start": 0.0, "t_end": 0.0, "words": 0, "fillers": 0}],
                "coach": ["..."], "skipped": false}],
 "candidate_question": {"text": "...", "reply": "..."}, "usage_usd": 0.0}
```

**Protocol additions** (JSON lines on the existing brain stdin/stdout; meeting messages unchanged):
- Swift → brain: `{"type":"sim_start","session_dir":str,"mode":"coach|realistic","voice":str}`;
  `{"type":"answer","q_id":str,"text":str,"t_start":float,"t_end":float,"words":int,"fillers":int}`;
  `{"type":"control","action":"skip|repeat|end"}`; `{"type":"spoken","id":str}` (the app finished playing line `id`).
- Brain → Swift: `{"type":"say","id":str,"text":str,"final":bool}` (streamed by sentence; `final` on the last
  sentence of the line); `{"type":"listen","q_id":str}`; `{"type":"coach","q_id":str,"lines":[str]}`;
  `{"type":"sim_progress","q_index":int,"q_total":int}`; `{"type":"sim_report","path":str}`; `status` as today.

**Report builder** (S5 produces, S2 calls): `async def build_report(session_dir: Path, transport, *, model: str = SONNET) -> Path`
in `brain/verse_brain/sim/report.py`, returning the `report.html` path. Pure helpers in
`brain/verse_brain/sim/delivery.py`: `wpm(answers) -> float`, `filler_count(text, lang) -> int`, `longest_pause(answers) -> float`.

**Voice protocol** (S3 produces, S4 consumes), module `VerseVoice`:
```swift
public enum VoiceKind: String, Codable, Sendable { case apple, elevenlabs, openai, text }
public protocol VoiceEngine: Sendable {
    var kind: VoiceKind { get }
    /// Speaks one sentence; returns when playback ends. Throws VoiceError on failure.
    func speak(_ sentence: String) async throws
    func stop() async
}
public enum VoiceError: Error { case missingKey, network(String), audio(String) }
public struct VoiceFactory { public static func make(_ kind: VoiceKind, voiceID: String?) -> any VoiceEngine }
public struct FallbackVoice: VoiceEngine { /* primary, falling back to AppleVoice per sentence; reports fallbacks */ }
public enum VoiceKeys { public static func save(_ key: String, for: VoiceKind) throws; public static func remove(_ for: VoiceKind) throws;
                        public static func hasKey(_ for: VoiceKind) -> Bool; public static func last4(_ for: VoiceKind) -> String? }
```

**Posting fetch** (S4a produces, S4 consumes), module `VersePosting`:
`public struct Posting: Sendable { url: URL?; title: String; company: String?; text: String; source: PostingSource }`,
`public enum PostingSource: String, Sendable { case linkedin, ashby, greenhouse, lever, page, pasted }`,
`public enum PostingFetcher { public static func fetch(_ url: URL, session: URLSession = .shared) async throws -> Posting; public static func pasted(_ text: String) -> Posting }`.

## Package S1: Sim prep
Agent: worker-hard · Worktree `../Verse-wt-s1`, branch `sim-prep`.
Owns: `brain/verse_brain/prep/sim.py`, `brain/verse_brain/prep/sim_prompt.py`, `brain/verse_brain/prep/sim_pack.py`, the
`--sim` flags in `brain/verse_brain/prep/__main__.py`, `brain/tests/test_prep_sim.py`, `brain/tests/fixtures/sim/**`.
Do not touch: other prep modules except reusing them (sources.py, vault.py, git_digest.py, ground.py, model.py, keychain.py,
conflicts.py: import, don't edit; report needed changes), `brain/verse_brain/runtime/**` (S2), `brain/verse_brain/sim/**` (S5), `app/**`.
Read first: spec §5.1; this plan's Shared contracts; `brain/verse_brain/prep/pipeline.py` and `event.py` (F5's `--from-event`, the
pattern to follow for a new input kind), `ground.py` (source grounding rules).
Decisions:
- CLI: `python -m verse_brain.prep --sim --posting-file P [--posting-url U] [--cv FILE] [--note FILE] [--vault|--no-vault]
  [--repo PATH]... --type mixed --difficulty standard --length 30 --lang en [--fake]` → prints the new session folder.
- CV input: `.pdf` (text via the existing PDF path if prep has one, else `pypdf`; add it to the brain deps only if
  missing) or `.txt`/`.md`.
- One Sonnet call with prompt caching builds `sim.json`; grounding check: every evidence item has ≥ 1 source with a
  verbatim quote found in that source; drop items that fail and add a warning. Competencies must quote the posting
  verbatim (checked by substring after whitespace normalisation).
- Question count from length: 15 min → 5, 30 → 8, 45 → 11. Always one opener first and one motivation question.
- `--fake` produces a deterministic `sim.json` with no network (for S2/S4 tests).
Test cases: `test_sim_pack_deterministic` (same inputs → byte-identical `sim_pack.md`); `test_competencies_quote_posting`;
`test_evidence_grounded_or_dropped` (a fake model output with one ungrounded item → dropped, warning added);
`test_question_count_by_length`; `test_no_evidence_still_plans` (posting only → questions planned, evidence empty, warning);
`test_fake_mode_offline` (no Keychain, no network).
Acceptance: `cd brain && .venv/bin/python -m pytest tests/test_prep_sim.py -q` passes; one live run on
`brain/tests/fixtures/sim/posting_brightwave.txt` (write it from the Brightwave AI Engineer posting text; the public job page) + a fixture CV
→ a session folder with a sensible `sim.json`.
Done means: a sim pack exists for a real posting with grounded evidence.
Stop and ask if: prep modules need edits to be reused, or a PDF library would need a non-permissive licence.

## Package S2: Sim runtime
Agent: worker-xhard · Worktree `../Verse-wt-s2`, branch `sim-runtime`.
Owns: `brain/verse_brain/runtime/sim.py` (new), the sim message types in `brain/verse_brain/runtime/protocol.py` (additions only),
the dispatch to sim mode in `brain/verse_brain/runtime/__main__.py`, `brain/tests/test_runtime_sim.py`, `brain/tests/fixtures/sim_runtime/**`.
Do not touch: `engine.py`, `embed.py`, `summary.py` (meeting runtime; import shared transport/settings, don't edit), prep (S1),
`brain/verse_brain/sim/**` (S5; call `build_report` through the contract, stub it in tests), `app/**`.
Read first: spec §5.2; Shared contracts; `runtime/engine.py` (transport, caching layout, hedging, pre-warm), `transport.py`, `settings.py`.
Decisions:
- One brain process serves either a meeting (`start`) or a sim (`sim_start`); the first message decides.
- Prompt layout: system (interviewer persona by type/difficulty) → `sim_pack.md` (breakpoint 1) → transcript so far
  (breakpoint 2 every 2 questions) → the current instruction. Pre-warm at `sim_start`.
- Loop per question: `say` the planned question rephrased in persona (Haiku, streamed; emit each finished sentence as
  `say` immediately) → `listen` → on `answer`, Haiku `judge` returns one of `FOLLOW: <text>` / `PUSH: <text>` / `NEXT`
  (plain-text line protocol like the meeting runtime) → at most 2 follow-ups → Coach mode: Haiku `coach` (2–3 lines, may
  only use evidence ids from the pack; emit `coach`) → next question. Emit `sim_progress` at each question.
- `control skip|repeat|end`; 20 s with no `answer` after `listen` → say a short "Take your time — shall I repeat the
  question?" once.
- End: "Do you have any questions for us?" → one answer (Sonnet, posting only) → close line → write `sim_results.json`
  → `await build_report(...)` → emit `sim_report`.
- Tough difficulty: `PUSH` allowed after vague answers (no number, no "I"); friendly: no pushes.
Test cases (fake transport): `test_sim_say_listen_order`; `test_followups_capped_at_two`; `test_coach_only_in_coach_mode`;
`test_coach_uses_only_pack_evidence`; `test_skip_repeat_end`; `test_silence_prompt_once`; `test_results_schema`
(validates `sim_results.json` against the contract); `test_report_called_at_end` (stubbed builder); `test_meeting_mode_unchanged`
(a `start` session still behaves as before: run the existing runtime tests).
Acceptance: `cd brain && .venv/bin/python -m pytest tests/test_runtime*.py -q` all pass; one live 3-question scripted sim
(answers fed from a fixture) → plausible follow-ups and a `sim_results.json`.
Done means: a full sim can be driven over JSON lines end to end.
Stop and ask if: the meeting runtime needs edits to share the transport, or the line protocol can't express a judge decision.

## Package S3: Voices
Agent: worker-hard · Worktree `../Verse-wt-s3`, branch `sim-voices`.
Owns: `app/Sources/VerseVoice/**`, `app/Tests/VerseVoiceTests/**`, the `VerseVoice` library + test target entries in `app/Package.swift`
(additions only; the orchestrator resolves merges).
Do not touch: every other app target, `brain/**`, `eval/**`.
Read first: spec §5.3; Shared contracts (voice protocol); `app/Sources/VerseUI/KeychainStore.swift` (the Keychain pattern to mirror).
Decisions:
- `AppleVoice`: `AVSpeechSynthesizer`, picks the highest-quality installed voice for the language (premium > enhanced > default);
  exposes `availableVoices(lang:)` for Settings.
- `ElevenLabsVoice` and `OpenAIVoice`: HTTPS with the user's key; stream or fetch per sentence and play from memory
  (`AVAudioPlayer`/`AVAudioEngine` from `Data`, never a file). Confirm the current endpoints, model ids and audio formats from
  the providers' official docs at implementation time (firecrawl first, then Tavily or WebSearch/WebFetch), and cite the doc URLs
  in a header comment. List voices for Settings (`ElevenLabs`: the user's voices; `OpenAI`: the model's voice names).
- `TextVoice`: no-op `speak` that returns at once.
- `FallbackVoice`: tries the primary; on `VoiceError` speaks that sentence with `AppleVoice` and records the fallback.
- Keys: Keychain services `verse-elevenlabs`, `verse-openai`, account = login user name; `VoiceKeys` mirrors `KeychainStore`.
Test cases: `testFallbackOnError` (fake primary throws → AppleVoice-like fake called, fallback recorded);
`testTextVoiceInstant`; `testElevenLabsRequestShape` and `testOpenAIRequestShape` (URLProtocol stub: method, URL, headers carry the
key, body JSON fields; the key never appears in any log line); `testMissingKeyThrows`; `testKeysRoundTrip` (TEST service names, dummy
values); `testAppleVoiceSpeaks` (opt-in env `VERSE_AUDIO=1`, speaks one short sentence).
Acceptance: worktree `cd app && swift test --filter VerseVoiceTests` passes; with `VERSE_AUDIO=1`, one Apple sentence plays.
Done means: any of the four voices can speak a sentence through one protocol, with Apple fallback.
Stop and ask if: a provider requires a non-HTTPS/SDK-only integration, or its terms forbid desktop use with a user key.

## Package S4a: Posting fetch
Agent: worker · Worktree `../Verse-wt-s4a`, branch `sim-posting`.
Owns: `app/Sources/VersePosting/**`, `app/Tests/VersePostingTests/**` (+ fixtures), the `VersePosting` library + test target entries
in `app/Package.swift` (additions only).
Do not touch: everything else.
Read first: spec §5.1 (posting fetch); Shared contracts (posting API).
Decisions:
- LinkedIn `linkedin.com/jobs/view/<id>` → the public guest endpoint
  `https://www.linkedin.com/jobs-guest/jobs/api/jobPosting/<id>` (HTML fragment; extract title, company, description text).
- Ashby `jobs.ashbyhq.com/<org>/<id>` → `https://api.ashbyhq.com/posting-api/job-board/<org>` and match the id;
  Greenhouse `boards.greenhouse.io/<org>/jobs/<id>` → `https://boards-api.greenhouse.io/v1/boards/<org>/jobs/<id>`;
  Lever `jobs.lever.co/<org>/<id>` → `https://api.lever.co/v0/postings/<org>/<id>`. Verify each endpoint shape against one live
  public posting while building and record the fixture.
- Otherwise: the page HTML → readable text (strip nav/script/style; prefer `<main>`/`<article>`, JSON-LD `JobPosting` when present).
- Text is normalised (whitespace, bullets kept as "- "), capped at 30 000 characters.
- Errors are typed (`PostingError.unreadable`, `.network`) so the UI can ask for pasted text.
Test cases: one recorded fixture per source → expected title/company/first line; JSON-LD page; a page with no job content → `.unreadable`;
`pasted` trims and normalises; no network in unit tests (URLProtocol stub).
Acceptance: `cd app && swift test --filter VersePostingTests` passes; a manual fetch of the live Brightwave Ashby posting prints title and
company.
Done means: a pasted link becomes clean posting text for the four common sources and most other pages.
Stop and ask if: an endpoint needs auth or its terms forbid this use.

## Package S5: Report
Agent: worker-hard · Worktree `../Verse-wt-s5`, branch `sim-report`.
Owns: `brain/verse_brain/sim/**` (new package: `__init__.py`, `report.py`, `grade.py`, `delivery.py`, `render.py`, `templates/`),
`brain/tests/test_sim_report.py`, `brain/tests/fixtures/sim_report/**`.
Do not touch: `brain/verse_brain/prep/**` (S1), `brain/verse_brain/runtime/**` (S2), `app/**`.
Read first: spec §5.4 (report contents); Shared contracts (`sim.json`, `sim_results.json`, `build_report`); `runtime/transport.py` and
`settings.py` (how to call Sonnet with caching).
Decisions:
- `grade.py`: one Sonnet call over `sim_pack.md` + the transcript → `grades.json`
  `{"overall": 1-5, "competencies": {"c1": {"score": int, "rubric_line": str, "q_ids": [str]}},
    "questions": [{"q_id": str, "strong": [str], "missing": [str], "better_answer": [{"sentence": str, "evidence_ids": [str]}]}],
    "practise_next": [str, str, str]}`; parse defensively; every better-answer sentence that contains a number must cite an evidence
  id whose text contains that number, else the sentence is dropped.
- `delivery.py`: WPM over answer time, filler words (en: um, uh, like, you know, sort of, kind of, basically, actually; word-boundary,
  case-insensitive), longest pause between answers' words (from `t_start`/`t_end` gaps), answer length vs `target_s`.
- `render.py`: deterministic `report.html` (self-contained, inline CSS, dark `#050405` / `#eae5ec` with one muted accent, readable
  type, no JS needed) + `report.json`. Leave out: gradients, emoji, drop shadows, chart libraries.
Test cases: `test_delivery_numbers` (hand-computed WPM/fillers/pause on a fixture); `test_grade_parse_and_number_check`
(fake model output with an uncited number → sentence dropped); `test_render_deterministic`; `test_build_report_end_to_end_fake`
(fake transport → `report.html` exists and lists every question).
Acceptance: `cd brain && .venv/bin/python -m pytest tests/test_sim_report.py -q` passes; render the fixture report to PNG
(headless Chrome or `qlmanage`) and attach the path in the report.
Done means: a sim transcript becomes a graded, grounded HTML report.
Stop and ask if: grading needs data that `sim_results.json` lacks (report the field instead of changing the contract).

## Package S4: App integration (after S2, S3, S4a, S5 merge)
Agent: worker-xhard · main checkout (no other agent running in it then).
Owns: `app/Sources/VerseUI/Sim*.swift` (new), the sim menu item and window wiring in `VerseApp`, sim states in `OverlayState.swift` /
`OverlayView.swift`, Settings voice/keys section, a `SimRunner` in `app/Sources/VerseTurns/` that drives the brain's sim protocol
(mic channel only, half-duplex), and tests in `app/Tests/VerseUITests/` and `app/Tests/VerseTurnsTests/`.
Decisions (from the spec): setup window (posting link + paste + preview, CV picker, note, vault toggle, repos, type, difficulty, length,
mode, voice, hints) → runs S1 prep via the brain venv → Start; capsule `practice · Q3/8` + timer; caption toggle; ⌥Space ends an
answer; answer ends after 2.0 s mic silence; mic ignored while a line plays; hints on = the meeting card runs on interviewer lines;
report window shows `report.html`. Full brief written when S2/S3/S4a/S5 are merged.
