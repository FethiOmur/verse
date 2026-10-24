# Verse: five features (transcript, Ask this meeting, folders, spoken mock interview, interface language)

Status: decided 2026-10-20. The rule applies: after a spec, build. No open question blocks any package (section 9).
Requested by the owner on 19 Oct. Builds on the UI redesign (`2026-10-16-verse-ui-redesign-design.md`: tokens, home window,
"leave out" list), anytime calls (`2026-10-16-verse-anytime-calls-design.md`: me layer, adhoc sessions, `events.jsonl`,
`general-core`) and the interview sim (`2026-10-14-verse-interview-sim-design.md`).

Spikes run for this spec (scratch package, not committed), on this Mac (Swift 6.4, Xcode 27.0, macOS 26):

- `swift build` compiles a `.xcstrings` resource into `<lang>.lproj/Localizable.strings` inside the target's resource
  bundle. **Confirmed.**
- `Text("key", bundle: .module)` follows `.environment(\.locale, …)` at run time: en/it/tr switch without a relaunch.
  **Confirmed** (rendered widths matched the reference strings).
- `String(localized: LocalizedStringResource(key, locale: L, bundle: .atURL(Bundle.module.bundleURL)))` returns the
  string in language L. `String(localized:bundle:locale:)` does **not** (its `locale` only formats). **Confirmed.**
- `swift build` writes `.stringsdata` files with every key used through `Text(_:bundle:)`, `LocalizedStringKey` parameters
  (including interpolations, as `%lld`), `String(localized:)` and a helper that takes `String.LocalizationValue`.
  `xcrun xcstringstool sync <catalog> --stringsdata …` merges them into the catalog. **Confirmed.**
- The generated `Bundle.module` accessor looks in `Bundle.main.resourceURL` first, and `bundle-app.sh` already copies
  every `*.bundle` next to the binary into `Verse.app/Contents/Resources/`. **Confirmed from the generated accessor**;
  that the localized bundle survives `codesign --verify --strict` is checked by the L0 acceptance step.
- The test Mac's preferred languages include `tr-TR, it-IT`. "Follow the system" therefore shows Verse in **Turkish** on first
  launch after L1 ships. the owner switches to English in Settings if he prefers.

## 1. Goal

1. **Transcript in the app.** The Sessions page shows a meeting's full transcript: speakers, timestamps, search, the
   cards that fired at that moment, copy and export.
2. **Ask this meeting.** A chat panel on the session page. A Claude agent answers questions about that one meeting from
   its transcript, summary, prep and the owner's me layer, streams, cites timestamps, shows the cost per answer and keeps the
   chat on disk.
3. **Folders by company or person.** the owner makes folders ("Acme", "Lena Vance"), moves sessions into them, and the
   Sessions list groups by them. Verse suggests a folder; renaming or deleting a folder never touches a session.
4. **Spoken mock interview before a meeting.** Practice runs a mock interview built from a prepared meeting session.
   The notch asks the questions aloud in the chosen voice, the owner answers aloud, and the sim's STT, feedback and report are
   reused. The next question is synthesized while he answers.
5. **Interface language.** The whole app UI in English, Italian or Turkish, switchable at run time. The default follows
   the system. Call and answer languages are unchanged.

### 1.1 What already exists (found while writing this spec)

Feature 4 is mostly built already. The spec adds the parts that are missing and does not rebuild these:

- `VerseVoice` has `AppleVoice` (AVSpeechSynthesizer), `OpenAIVoice` (`gpt-4o-mini-tts`, voice `marin`, WAV),
  `ElevenLabsVoice` (`eleven_flash_v2_5`, MP3), `TextVoice` and `FallbackVoice` (a failed cloud sentence is spoken by the
  Apple voice and a chip is shown).
- Keys are already user-entered in Settings → Practice interview and live in the Keychain as `verse-openai` and
  `verse-elevenlabs`. They are written through `security -i` on stdin and are never on argv or in a log
  (`VoiceKeys.swift`, `HomePracticeVoiceSection`).
- The sim (`runtime/sim.py`, `SimRunner.swift`) already speaks the interviewer's lines sentence by sentence and listens
  half-duplex on the mic. ⌥Space ends an answer. Coach and Realistic feedback and `report.html` already work. The notch
  shows practice capsule states 6 and 6b.

What is missing: a mock interview built from a **meeting session** (today it needs a job posting), **pre-synthesis**
(today each sentence is fetched only when its turn to play comes), and it/tr fixed lines. Section 2.4 covers these.

## 2. Decisions

### 2.1 Transcript in the app

| Topic | Decision |
|---|---|
| Where | The Sessions detail gets a segmented control under the header: **Summary · Transcript**. It appears when the session has both, and otherwise only the existing tab shows. Default: Summary when `summary.md` exists. The last choice is remembered app-wide (`sessionsDetailTab`). Practice runs keep their report and get no Transcript tab, because their report already lists every Q&A. |
| Model | New `TranscriptDocument` (Swift, VerseUI) is built from `transcript.jsonl`, plus `events.jsonl` when present and `AppSettings.ownerName`. It is the single source of truth for rows, timestamps and speakers. Ask (2.2) receives its rows from Swift and never recomputes them in Python. |
| Runs | One session folder can hold several runs (restarts, a re-Start of the same session; measured: `ironwood-lena` has 5 `start` events and its `t_audio_end` resets 3 times). **Forward:** every transcript line gains `run_start` (the runner's `wall0`, Unix seconds, 3 decimals) and `t_wall` (= `wall0 + t_audio_end`). **Legacy files** (no `run_start`): a new run starts when a `turn_id` repeats inside the current run or `t_audio_end` drops more than 30 s below the run's maximum. |
| Timestamp | Elapsed time since the session's first run started: `m:ss` under an hour, `h:mm:ss` from an hour. Forward: `t_wall − min(run_start)`. Legacy with `events.jsonl` `start` events: transcript runs are aligned to the **last** N starts (early starts without speech have no lines), and elapsed = `(start_k − first aligned start) + t_audio_end`. Legacy without events, or with fewer starts than runs: cumulative (run k begins where run k−1's last line ended). Inside a run, rows are ordered by `t_audio_end` (a stable sort: the me and remote channels interleave by audio end). If one run has the same `turn_id` twice, the later text replaces the earlier one in the earlier one's position (today's `questions()` rule). |
| Speakers | `me` → `ownerName` ("the owner"). `remote` → "Other" (localized). `room`: relabelled from `events.jsonl` `room_text` finals: `label:"me"` → the owner; `label:"split"` with the new `me_words` → two rows (the first `me_words` words are the owner, the rest stays room); a split without `me_words` (legacy) stays room. An unrelabelled `room` row is labelled **"Room"**, because before phase D the one mic holds both voices and "Other" would be wrong whenever the owner spoke freely. Rows of phase D's split route arrive as `me`/`remote` already. |
| Cards inline | From `events.jsonl` only, and only when wall times are known (forward files, or legacy files with aligned starts). One card per turn, shown under the row it answered: SAY = the last `say` line of the turn, points = every point line of the turn in order without repeats, and a tier list such as "F · D". A card whose turn id has no row (`now-<n>`, follow cards) attaches under the last row whose wall time ≤ the card's `t`. **Forward:** the brain writes a new `card_done{turn,tier,id,say,points}` event when a call finishes, with each line clipped at 240 characters. Today only the first line of each call is logged, at 60 characters. Legacy cards show those 60 characters with "…". A **Cards** toggle in the transcript toolbar is on by default and hidden when the session has no events. |
| Search | A field in the transcript toolbar; ⌘F focuses it. Matching is case- and accent-insensitive with Turkish folding (`TextFold.fold`: lowercase with the root locale, strip diacritics, `ı`→`i`), so "istanbul" finds "İstanbul" and "perche" finds "perché". It searches row text and speaker names, not card text. "3 of 17" with ↑/↓ buttons; ⏎ or ⌘G goes to the next match, ⇧⏎ or ⇧⌘G to the previous one; Esc clears. Matches get a `VT.mint` 35 % background and the current match a full `VT.mint` fill with `VT.onMint` text, the analogue of the system's find highlight with the one accent. Rows stay on screen (no filtering), so context is kept. |
| Copy / export | **Copy** (secondary) copies the whole transcript as plain text, `[m:ss] Name: text` per row, without cards. Row text is also selectable (`.textSelection(.enabled)`). **Export…** (secondary, a menu) offers Markdown (`.md`) or Plain text (`.txt`) through an `NSSavePanel` named `<title> transcript.<ext>`. Markdown: `# <title>`, a meta line (date, route or kind, turn count), then `**m:ss Name:** text` paragraphs, with cards (when the toggle is on) as `> Card (F · D): <SAY>` plus `> - point` lines. Nothing is written anywhere except the place the owner picks. |
| Header changes | The header's "Transcript" button (it opened Finder) goes away. "Show in Finder" moves into a "More" menu (`ellipsis.circle`, neutral) in the header. "Use for Start" and "Save to vault" stay. |
| Summary headings | `summary.md` stays English (it is also saved to the vault). The detail maps its known headings (Summary, Decisions, Actions → "Follow up", Open questions → "Still open", Conflicts) to localized titles (L1). |

**Transcript tab layout.** It is one reading plate (`HomeGroup(plate: true)`), as today's Summary is.

- **Toolbar**, inside the plate's top, 20 pt padding, 32 pt tall, a hairline separator (`ink.separator`) below it:
  - leading: the search field (240 pt, `magnifyingglass` glyph, placeholder "Search transcript"), then the match counter
    and chevrons (caption, `ink.secondary`, monospaced digits);
  - trailing: the **Cards** toggle (a neutral button with a checkmark when on), **Copy**, **Export…**.
- **Rows** in a `LazyVStack` inside a `ScrollViewReader`, 20 pt side padding.
  - A *block* is consecutive rows of one speaker less than 60 s apart.
  - Block header: the timestamp in a 52 pt gutter (11 medium, `ink.tertiary`, monospaced digits, right-aligned), then the
    name (12 semibold; the owner in `ink.primary`, Other and Room in `ink.secondary`).
  - Each row's text: 13 regular, `ink.primary`, line spacing 4. A row's own timestamp shows in the gutter on hover.
  - Spacing: 14 pt between blocks, 6 pt between rows.
- **Card**: an inset fill (`ink.fill`, radius 9, padding 10/12) indented to the text column.
  - Caption line: `text.bubble` 10 pt + "Card · F · D" (`VT.Font.caption`, `ink.tertiary`).
  - SAY: 13 medium, `ink.primary`. Points: "– " lines, 12 regular, `ink.secondary`.
- **Empty state**: "No transcript was saved for this session." (body, `ink.secondary`).
- **Jump target** (used by Ask): the row scrolls to the centre and gets `ink.selection` for 1.5 s, then fades out in
  300 ms. Under Reduce Motion it has no fade: it is removed after 1.5 s.

### 2.2 Ask this meeting

| Topic | Decision |
|---|---|
| Process | A **third mode of the brain CLI**, run as **its own child process**: `python -u -m verse_brain.runtime` whose first line is `ask_start` (today the first line already picks meeting vs sim, `runtime/__main__.py`). It is started when the panel opens and ended when the panel closes, when another session is selected, when the window closes, or after 10 min idle (restarted lazily on the next question, with the history rebuilt from `chat.jsonl`). It is never a command inside a live meeting's brain process: that process is latency-critical and its rate bucket and keep-alive must not compete with a chat. A one-shot CLI per question was rejected because it would re-read the files and re-open TLS for every answer and could not stream with cancel as cleanly. |
| Key | The brain's own Keychain read (`prep/keychain.py`, service `verse-anthropic`, the Individual Org key funded by the API plan's credit). It never uses OAuth or a claude.ai login, and the key is never on argv or in a log. `--fake` uses canned answers (tests, and Settings → Testing → Fake brain). |
| When available | For meetings and adhoc calls with a non-empty transcript. It is disabled while that session is the one recording (help text: "Available when the call ends"). It is not offered for practice runs or prepared-but-unused sessions. |
| Grounding | One cached user block, in this order: `ABOUT ME` (`me.md`, only when "Use my profile in every session" is on; MY NOTES lead as PRIORITIES, as in the live runtime) → `MEETING PREP` (`pack.md` without its STYLE GUIDE section; "(none: unprepared call)" when empty) → `SUMMARY` (`summary.md`, or "(none yet)") → `TRANSCRIPT` (`[m:ss] Name: text`, one line per row, rows from Swift). |
| Prompt layout | `system` (frozen, English, about 450 tokens; see 3.2) → `messages[0]` user = [grounding block with `cache_control`] + [question 1] → assistant answer 1 → user question 2 → … Top-level automatic `cache_control` caches through the last message: two breakpoints in all. History: the last 12 Q/A pairs after the last `reset`. Older pairs drop from the front, which only invalidates history after the grounding block; the grounding block stays cached. |
| Long meetings | The tokens of the grounding block are counted once at `ask_start` with `count_tokens` (free) on Sonnet. ≤ **180,000 tokens** (about 15 hours of talk; a 30-minute call is about 20k): **full** mode, the whole transcript cached. Above that, **chunked** mode: the cached block holds me, prep, summary and a `TRANSCRIPT INDEX` (per 10-minute window: the stamp range and the first sentence of its first 3 turns). Each question's tail carries `TRANSCRIPT EXCERPTS`: chunks of about 6k tokens cut on turn boundaries, ranked by BM25 over accent-folded words of the question plus the previous question, the top ones up to 60k tokens, in time order. No extra model call. |
| Models | A picker in the panel: **Haiku · Sonnet · Opus**, default **Sonnet**, remembered app-wide (`AppSettings.askModel`). Ids come from `brain/verse_brain/prep/model.py` and the claude-api skill (cached 2026-10-06): `claude-haiku-5-5`, `claude-sonnet-5-5`, new `claude-opus-5-5`. Changing the model mid-chat is allowed. The next answer writes a new cache (caches are per model), and the panel says nothing about it. |
| Route tuples | `haiku`: max_tokens 1500, `thinking:{type:"disabled"}` (allowed on Haiku 5.5 at effort high or below), effort `medium`. `sonnet`: max_tokens 4000, thinking omitted (adaptive), effort `medium`, `betas:["server-side-fallback-2026-07-01"]` with `fallbacks:"default"` (like route D). `opus`: max_tokens 4000, thinking omitted (adaptive; Opus 5.5 rejects `disabled`), effort `medium` set explicitly (Opus 5.5's default), the same fallback beta. Streamed. |
| Streaming | Brain → Swift `ask_delta` text chunks; one `ask_done` with usage, cost, timings and citations; `ask_error` with a kind. Until the first text arrives, the panel shows "Thinking…" with a mint dot breathing at 0.9 s; thinking display is the default (omitted). `control cancel` stops the stream. |
| Citations | The model cites `[m:ss]` / `[h:mm:ss]` exactly as written on a transcript line. `citations` = the stamps in the answer (regex `\[(\d{1,2}:\d{2}(?::\d{2})?)\]`) that exist in the transcript, in order of first appearance. In the panel each valid stamp is a chip (caption 11 medium, `ink.secondary` on `ink.fill`, radius 7, 18 pt); a click switches the detail to Transcript and jumps to that row (2.1). Stamps that are not valid stay plain text. |
| Cost | Per answer: `spend_usd(model, usage)` with per-model prices (3.4), shown under the answer ("Sonnet · 2.4 s · $0.012"). The panel header shows "This chat: $0.04". The session's `spend.json` gets one run record per panel opening (`started_at` = panel open), with the new optional `"kind":"ask"`, updated after every answer, so "This month" in Settings includes Ask. A cancelled answer's cost comes from the `message_start` usage plus output estimated at characters / 4, flagged `cost_estimated`. Estimate for a 30-minute call (about 31k grounding tokens): Sonnet ≈ $0.08 for the first answer (cache write) and ≈ $0.01 after; Opus ≈ $0.16 then ≈ $0.015; Haiku ≈ $0.004 then ≈ $0.0005. |
| History | `chat.jsonl` in the session folder (3.3). It is written only by the ask runtime: the question line when received, the answer line when finished. Swift reads it to show the history. **Clear chat** (in the panel's ⋯ menu, with a confirmation) appends a `reset` line: earlier pairs are hidden and no longer sent. Nothing is deleted. |
| Answer language | The language of the question. The UI language does not matter. |

**Panel layout.** The Ask panel is an inspector column inside the Sessions page.

- **Opening and closing.**
  - Opened by **Ask** (`HomeSecondaryButton`, SF `bubble.left.and.text.bubble.right`) in the detail header, or by ⌘⇧A.
  - While it is open, the session list column hides (its width animates to 0 in 140 ms ease-out, with no animation under
    Reduce Motion). The detail takes the middle and the panel sits on the right at **340 pt**, with a 1 pt
    `ink.separator` line between them.
  - At the minimum window width (900) that is 220 (sidebar) + 340 (detail) + 340 (panel).
  - Closing (✕ or ⌘⇧A) brings the list back.
- **Panel contents** (top padding 26, side padding 16):
  - **Header row:** "Ask this meeting" (`VT.Font.title`) and a trailing ⋯ menu (Clear chat) and ✕. Under it: the model
    segmented control (`HomeSegmented`), then "This chat: $0.04" (caption, tertiary).
  - **Conversation:** one reading plate filling the height, scrolled to the bottom on new text.
    - A question is a right-aligned fill block (`ink.fill`, radius 9, max 85 % width, 13 medium).
    - An answer is plain 13 regular text, line spacing 4, with `- ` bullets rendered as a list and citation chips inline.
    - Under each answer, a meta line (caption, tertiary) and a copy glyph button.
    - When empty: three starter chips, neutral fills ("What did they ask me?", "What did I promise to do?",
      "Where was my answer weak?"). A click sends the starter.
  - **Composer** at the bottom:
    - a multi-line field (1–5 lines, grows; placeholder "Ask about this meeting");
    - ⏎ sends, ⇧⏎ adds a new line;
    - the primary **Ask** button (mint, the panel's one primary), which turns into a secondary **Stop** while an answer
      streams.
  - **Footnote** (caption, tertiary): "Answers use your Anthropic key and only this meeting's transcript, summary, prep
    and profile."
- **Errors:** `HomeNote(isError)` under the failed question, with a **Retry** button. Messages by kind: credit
  exhausted, offline, rate limited (with the retry-after time), key missing, refusal.

### 2.3 Folders by company or person

| Topic | Decision |
|---|---|
| On disk | An **index file**, `<sessions root>/folders.json` (3.5). It is written only by the app, on the main actor, with atomic writes. Session folders are not moved and their files are not changed. |
| Why not subdirectories | Session folder **names** are ids everywhere: `settings.sessionName`, `EventSessionMap` (event → name), `router.selectedSession`, the follow-up checklist keys, the brain's `session_dir`, prep's `--out <root>` (it creates `<root>/<id>/`), `SessionCatalog.list` (one level, `pack.md` required), `GeneralPrep` (`<root>/general-core`), and `prep/me.py`, which reads `facts.jsonl` one level down. Moving a folder while a call writes `transcript.jsonl` / `events.jsonl` would also break open handles. |
| Why not a `meta.json` field | `meta.json` is written by Python prep (calendar, conversation, sim) and rewritten by later prep steps (`conversation.py` rewrites it). Its shape differs per kind (adhoc has its own `AdhocMeta`), and a folder rename would rewrite N files. |
| Model | `SessionFolderStore` (`@MainActor ObservableObject`): `folders`, `folder(of:)`, `create(name:)`, `rename(_:to:)`, `delete(_:)` (removes the folder and its assignments only), `move(_ session:, to folder:)` (nil = no folder), `dismissSuggestion(_:for:)`. Names are trimmed, 1–60 characters and unique after folding (`TextFold.fold`). Errors: `emptyName`, `tooLong`, `duplicateName`. Assignments to session names that no longer exist are pruned on every write. A missing or unreadable file means no folders; an unreadable file is renamed `folders.json.unreadable-<stamp>` (not deleted) and a note is shown once. |
| Suggestion | `FolderSuggester` (pure). 1) **Auto-assign, no question:** a practice run built from a session (`sim.json` `source_session`, 2.4) whose source is in a folder goes into that folder the first time it is listed unfiled. 2) **Existing folder:** a folder matches when its folded name, as whole words in order, occurs in the session's *haystack*: its folder-name words (split on `-` and `_`), `meta.json` `conversation.company`, `sim.json` `company`, the session title, and the `name`-kind FACTS lines of `pack.md` (first 40). The longest name wins; on a tie, the folder used most recently. 3) **New folder:** only from `conversation.company` or `sim.json` `company`, and only when no existing folder matched. Dismissed suggestions are kept per session in `folders.json`. Calendar titles are not read: `EventSessionMap` keeps no titles and the calendar is not opened for this. |
| Where suggestions show | Only in rows under **No folder**: a trailing chip "→ Acme" (or "+ Acme" for a new folder) in caption, `ink.secondary` on `ink.fill`, radius 7. It is visible on hover and on the selected row; a click moves (or creates and moves). The row's context menu has "Not this folder" (dismiss). Nothing moves without a click except rule 1. |
| Sessions list | The 236 pt list column of the Sessions page is the place folders show. The home sidebar's "Recent" is unchanged. |

**List column layout** (`HomeSessionsList.swift`).

- **Title row:** "Sessions" (large title) and a trailing 24 pt neutral icon button `folder.badge.plus` (help "New folder").
- **Mode control:** under the title, 8 pt below, `HomeSegmented` **Folders · Recent**. It shows only when at least one
  folder exists. The default is Folders once a folder exists, and the choice is remembered (`sessionsListMode`).
- **Folders mode:**
  - One section per folder. Section header row, 28 pt: a disclosure chevron (9 pt, `ink.tertiary`), the folder name
    (12 semibold, `ink.secondary`, sentence case, never uppercase), and the count (caption, tertiary, monospaced digits).
  - Rows under it are today's rows with 8 pt more leading indent, newest first.
  - Sections are ordered by their newest session; empty folders come last, alphabetically. **No folder** is the last
    section.
  - Collapsed sections are remembered (`sessionsCollapsedFolders`).
- **Recent mode:** today's flat list. A filed row shows its folder name after the kind text ("Today · Meeting · Acme"),
  in caption, tertiary.
- **New folder:** an inline row at the top of the sections with a focused text field ("Folder name"). ⏎ creates, Esc or
  an empty ⏎ cancels. A validation error shows as a `HomeNote` under the field.
- **Rename** (header context menu "Rename…"): an inline text field replaces the name, with the same keys.
- **Delete** (header context menu "Delete folder…"): a confirmation dialog.
  - Title: "Delete the folder “Acme”?"
  - Message: "Its 4 sessions stay in Sessions, under No folder. No session is deleted."
  - Buttons: "Delete Folder" (destructive) and Cancel.
- **Move:**
  - Row context menu: "Move to" (a submenu of folders with a checkmark on the current one), "New Folder from This
    Session…" (prefilled with the suggestion), "Remove from Folder".
  - Drag a row onto a section header (`.draggable(name)` / `.dropDestination(for: String.self)`); the header shows
    `ink.selection` while hovered. A drop on No folder unfiles the session.

### 2.4 Spoken mock interview before a meeting

| Topic | Decision |
|---|---|
| Entry points | **Practice page:** a new first section **Practise for** with `HomeSegmented` **A meeting · A job posting**. The default is A meeting when a prepared session exists, else A job posting (today's flow, unchanged). **Prepare page, Up next:** prepared items get a secondary **Practise** button that opens Practice with that session selected. |
| A meeting: setup | `HomeRow` "Meeting": a popup of prepared sessions (non-empty `pack.md`; not `general-core`, `adhoc-*` or `sim-*`), newest first; the default is the nearest Up next item that has a session, else the newest. A preview row reads "From its prep: 14 likely questions · 9 facts" (non-empty lines of `bank.jsonl`, `[f…]` lines of FACTS). Then the existing **Interview** section (Type, Difficulty, Length, Feedback, Interviewer voice). The "Company" field and the **Your experience** section are hidden in this mode: the pack carries the evidence, and `me.md` is added when "Use my profile in every session" is on. Primary: **Build interview ⌘↩**, then **Start practice ⌘↩** as today. |
| Prep | `python -m verse_brain.prep --sim --from-session <DIR> [--me <me.md>] --type … --difficulty … --length … --out <root> [--fake]`. One Sonnet call (the existing sim prep tuple). **Questions are decided by code, not the model:** the opener (bank entry `b001` when its question asks about background, else the sim's `OPENER_TEXT`), then bank entries in bank order, cut to `question_count(length)`, each keeping `bank_id`. The model writes only the competencies (each quoting a pack line, checked against the pack text by `SourceBook` like posting quotes today), the rubric, and per question the `kind`, `competency_ids`, `evidence_ids` and 1–2 `follow_ups`. Evidence comes from the pack (and `me.md`), with sources verified as today. A bank with fewer than 3 entries means the model plans the remaining questions from the pack (the existing planning path). The output folder is `sim-YYYYMMDD-HHMM-<source session>`, holding `sim.json` (adds `"source":"session"` and `"source_session":"<name>"`; `posting_url` null), `source_pack.md` (the pack text used, in place of `posting.txt`) and `sim_pack.md`. Language: `meta.json` `languages[0]`, else `en`. |
| Voice without a key | The **macOS system voice (AVSpeechSynthesizer, `AppleVoice`)**, which is already the default and the per-sentence fallback. Speaking aloud is the point of this feature, the best installed Premium/Enhanced voice for the language is used, and it costs nothing. Text only stays a choice the user can make, not the fallback. |
| Providers | As built and confirmed again on 20 Oct (official docs): **OpenAI** `gpt-4o-mini-tts` (newest; `tts-1`, `tts-1-hd` older), 13 voices, default `marin`, Italian and Turkish listed; price about $0.015 per minute of audio ($0.60 / 1M text-in tokens, $12 / 1M audio-out tokens; third-party pages, the official pricing page snippet agrees). **ElevenLabs** `eleven_flash_v2_5` (about 75 ms, 32 languages including it/tr), about $0.05 per 1,000 characters on the API (third-party pages; the official page says 0.5–1 credit per character for Flash). A 30-minute mock (about 3,500 characters spoken) costs about $0.05 on OpenAI or $0.18 on ElevenLabs, billed to the user's own key, not the Anthropic API credit. `eleven_v4_turbo` (new, about 100 ms) is **not used**: the docs say v4 is served through the Text to Dialogue API, and whether the plain TTS endpoint accepts `eleven_v4_turbo` is **unconfirmed**. |
| Latency: sentences | Every queued `say` sentence starts its synthesis **at once** (sentence n+1 synthesizes while sentence n plays) through a new in-memory `PrefetchCache`. Today the next sentence is fetched only after the previous one has played. |
| Latency: next question | While the owner answers a planned question, the brain generates the **next planned question's line speculatively** (Haiku ASK, the tail adds "Do not refer to the candidate's previous answer; start with the question itself") and sends `say_prefetch{id,sentences}`. The line = a short acknowledgement from a fixed rotating list in the interview language ("Thank you.", "Okay.", "Got it.", …) + the question sentences. Swift synthesizes them into the cache. When JUDGE says NEXT (or on skip), the brain sends the normal `say` lines with the same id and identical text: a cache hit, so playback starts as soon as JUDGE returns. On FOLLOW or PUSH the follow-up streams as today, and the prefetched line waits for the next NEXT. A failed speculative ASK means the normal ASK runs at NEXT. Extra cost: one Haiku call (about $0.0003) only when the interview ends before the line is used. Apple voice lines are not pre-synthesized (it starts in tens of ms); the cache still holds `.live` entries so the flow is uniform. |
| Audio storage | **Memory only.** `PrefetchCache` holds at most 16 sentences and 8 MB (least recently used dropped first). It is cleared at the end of the interview, on `end`, and when the runner is released. Nothing is written to disk. The cache exists for the prefetch and for **repeat** (the same line replays without a second paid call). That is the justification, and it never outlives the session. |
| Languages | The interviewer speaks the session language. `runtime/sim.py`'s fixed lines (SILENCE, CANDIDATE_Q, CLOSE, CLOSE_EARLY, ANSWER_FALLBACK and the new ACK list) get Italian and Turkish versions (executor-written, the owner reviews). STT: `ListenSimMic(lang:)` with the Apple engines for it/tr, as in meetings. The filler count stays English-only; for it/tr the report says "Fillers are counted for English only". |
| Reused as is | Half-duplex turn-taking, the bleed rule, the ⌥Space done key, Coach and Realistic feedback, grading, `report.html`, the notch capsule states 6/6b, the 20 s silence prompt, and the voice fallback chip. |

### 2.5 Interface language

| Topic | Decision |
|---|---|
| Format | One String Catalog, `app/Sources/VerseUI/Resources/Localizable.xcstrings`, source language `en`, with `it` and `tr`. `Package.swift` gets `defaultLocalization: "en"` and `resources: [.process("Resources")]` on VerseUI. `swift build` compiles it into `Verse_VerseUI.bundle/Contents/Resources/{it,tr}.lproj/Localizable.strings`. `bundle-app.sh` already copies the bundle into `Verse.app/Contents/Resources`. |
| Views | Every user-visible literal in VerseUI and VerseApp goes through the module bundle: `Text("…", bundle: .module)`. `Home*` components take `LocalizedStringKey` (with `verbatim:` overloads for data such as session titles) and render `Text(key, bundle: .module)`. Buttons, Toggles and Labels with literal titles use their label-closure form with `Text(…, bundle: .module)`, or a `Home*` component. VerseApp uses the public `L10n.bundle`. |
| Non-view strings | `L10n.tr(_ v: String.LocalizationValue) -> String`, which builds `LocalizedStringResource(v, locale: L10n.locale, bundle: .atURL(Bundle.module.bundleURL))`. It is used for status lines, alerts, save panels, notes and island texts made in models. Its call sites are extracted (spike). |
| Run-time switch | Without a relaunch. `L10nState.shared` (`@MainActor ObservableObject`) publishes `locale`. Each window root applies `.environment(\.locale, L10nState.shared.locale)` and observes it: `HomeRoot`, the island root (`OverlayView` / `NotchPanel` host), `PrompterView`'s host, `SimOverlayView`, `MeetingPromptView`, and the `MenuBarExtra` content. Island strings already stored in the overlay state keep their language until the next state change. |
| Setting | Settings → Appearance, first row **Language**: a popup with **System (Türkçe)** (the resolved name in brackets), **English**, **Italiano**, **Türkçe**. Names are endonyms. `AppSettings.interfaceLanguage` takes `system` (default) \| `en` \| `it` \| `tr`. "System" = the first of `Locale.preferredLanguages` whose language code is en, it or tr, else en. |
| Dates and numbers | `HomeFormat` uses `L10n.formatLocale`: en → `en_GB` (keeps 24-hour time), it → `it_IT`, tr → `tr_TR`. This replaces the fixed `en_GB` and its comment "English whatever the system region". Currency stays USD. |
| Not translated | Brain-written content (cards, `summary.md` body, coach notes, the practice report's body text, Ask answers), session folder names, logs, CLIs, and exported transcript text (its headings are translated). The practice report's **headings** follow the UI language: `sim_start` gains `ui_lang` and `sim/render.py` gets a small heading table for en/it/tr. |
| Permission prompts | `Info.plist` gains `CFBundleDevelopmentRegion` `en` and `CFBundleLocalizations` `[en, it, tr]`. `app/Resources/Localization/{it,tr}.lproj/InfoPlist.strings` translate the microphone and audio-capture usage strings and are copied by `bundle-app.sh`. macOS shows these in the **system** language, not the in-app choice (a platform limit). |
| Extraction | `app/scripts/l10n-sync.sh`: `swift build` (debug), then collect every `*.stringsdata` under `.build` whose path contains `VerseUI` or `VerseApp` (the Swift Build backend puts them under `.build/out/Intermediates.noindex/…/Objects-normal/arm64/`), then `xcrun xcstringstool sync app/Sources/VerseUI/Resources/Localizable.xcstrings --stringsdata …`. |
| Check | `app/scripts/l10n-check.py [--allow-missing]` reads the catalog and reports keys without `it`/`tr`, stale keys, and placeholder mismatches (the count and kind of `%lld`, `%@`, `%.2f` must match `en`). It exits 1 on any non-stale key missing it or tr, unless `--allow-missing`. |
| Lint | `LocalizationLintTests` (L1) fails on a `Text("`, `Button("`, `Label("`, `Toggle("`, `.help("`, `confirmationDialog("` or `alert("` literal in VerseUI/VerseApp without `bundle:`, unless the line carries `// l10n:verbatim`. |
| Translation process | Executors write it and tr for every key (L1), following the glossary below. Italian uses "tu", like Apple's Italian UI. Turkish uses macOS-style imperatives ("Kaydet", "Sil") and avoids direct address. `app/scripts/l10n-review.py --lang tr\|it` writes `docs/l10n/review-<lang>.md` (key \| en \| translation \| file) for the user to skim. His corrections go into the catalog. This review does not block shipping. |

Glossary (fixed terms):

| en | it | tr |
|---|---|---|
| Prepare | Prepara | Hazırlık |
| Me | Profilo | Profil |
| Sessions | Sessioni | Oturumlar |
| Practice / Practise | Esercitazione / Esercitati | Pratik / Pratik yap |
| Scripts | Copioni | Metinler |
| Settings | Impostazioni | Ayarlar |
| Transcript | Trascrizione | Transkript |
| Summary | Riepilogo | Özet |
| Folder | Cartella | Klasör |
| Card | Scheda | Kart |
| Ask this meeting | Chiedi a questa riunione | Bu toplantıya sor |
| Unprepared | Non preparata | Hazırlıksız |
| Other (speaker) | Altro | Karşı taraf |
| Room (speaker) | Stanza | Oda |
| Follow up | Da fare | Yapılacaklar |

### 2.6 Rejected

- **Transcript rows recomputed in Python for Ask.** Two implementations of runs and timestamps would drift. Swift's
  `TranscriptDocument` is the one source, and Python gets its rows.
- **Ask inside the live meeting brain.** It competes with the latency-critical process (rate bucket, keep-alive, event
  loop), and that process only exists during a call.
- **One CLI call per question.** No streaming cancel, files re-read and TLS re-opened per answer, history to replay
  anyway.
- **A 1-hour cache TTL for the grounding block.** 2× write cost. Questions in one sitting come minutes apart, and a
  return after an hour pays one rewrite.
- **Embeddings for long-meeting chunks.** A ≥ 180k-token transcript is rare; BM25 needs no model and no wait.
- **Folders as real subdirectories, or a field in `meta.json`.** See 2.3.
- **Auto-moving sessions by suggestion.** the owner decides. Only derived practice runs follow their source.
- **Opaque chat bubbles, an "AI" sparkle button, a coloured model picker.** These are on the redesign's "leave out"
  list: neutral fills, one primary.
- **Caching TTS audio on disk.** It conflicts with "no audio is stored", and memory covers prefetch and repeat.
- **`eleven_v4_turbo`.** The model is not confirmed on the plain TTS endpoint.
- **Text only as the keyless fallback.** The interview is meant to be heard; the system voice is free and present.
- **Copying the `.lproj` files into `Verse.app/Contents/Resources` so plain `Text("…")` (main bundle) localizes.**
  Renders and `swift run` builds would not be localized, and the bundle-path dependency would be invisible. The explicit
  module bundle works in tests, renders and the app alike.
- **A relaunch to switch language.** Not needed: the spike showed run-time switching works.
- **Localizing brain output.** Out of scope: UI only.

## 3. Data and protocol (additive; current messages and files unchanged)

### 3.1 Session files

`transcript.jsonl` (Swift `VerseRunner.appendTranscript`), additive keys on every line:

```json
{"turn_id":"r12","speaker":"remote","text":"…","addressee":"me","kind":"question","t_audio_end":312.44,
 "lang":"en","run_start":1792420451.768,"t_wall":1792420764.208}
```

`events.jsonl` (brain `runtime/events.py`, `engine.py`), additive:

- `room_text` finals with `label:"split"` gain `"me_words": <int>`, the number of leading words that are his;
- new `card_done` when a card call finishes:
  `{"t":…,"ev":"card_done","turn":"r12","tier":"F","id":"f0012","say":"…","points":["…","…"]}`, each line at most 240
  characters (`CARD_FULL_CHARS = 240`); `card` keeps its 60-character first line.

`spend.json` runs gain an optional `"kind": "ask"`. Absent means a call run. `SpendLedger.Run` decodes it as optional.

### 3.2 Ask protocol (Swift ↔ `python -u -m verse_brain.runtime`)

Swift → brain (the first line decides the mode):

```json
{"type":"ask_start","session_dir":"/…/sessions/ironwood-lena","owner_name":"the owner",
 "title":"Ironwood Lena","date":"2026-10-19T17:00:00+02:00",
 "me":{"core":"/…/profile/me.md"} ,
 "transcript":[{"stamp":"0:18","speaker":"the owner","text":"…"},{"stamp":"1:33","speaker":"Other","text":"…"}],
 "model":"sonnet"}
{"type":"ask","id":"q4","text":"What did Lena ask about authoring?","model":"sonnet"}
{"type":"control","action":"cancel"}
{"type":"control","action":"stop"}
```

`me` is null when the profile toggle is off. `model` is one of `haiku|sonnet|opus`. Brain → Swift:

```json
{"type":"status","state":"ready","context":{"tokens":31240,"mode":"full","rows":459,"history":3}}
{"type":"ask_delta","id":"a4","q":"q4","text":"He asked whether "}
{"type":"ask_done","id":"a4","q":"q4","model":"claude-sonnet-5-5","usage":{"input":412,"output":388,"cache_read":31240,"cache_write":0},
 "cost_usd":0.0104,"ms_first_token":1840,"ms_total":4120,"citations":["12:34","25:02"],"stop_reason":"end_turn","cost_estimated":false}
{"type":"ask_error","id":"a4","q":"q4","kind":"credit_exhausted|offline|rate_limited|overloaded|auth|refusal|bad_request|error","message":"…","retry_after":12}
```

`status` states as in meetings (`warming`, `ready`, `offline`, `credit_exhausted`, `error`). Messages never carry key
material (`redact`). Unknown types are ignored on both sides.

System prompt (frozen; `{owner}` is the owner name):

> You answer {owner}'s questions about one past meeting or call. Use only the material in this conversation: the
> TRANSCRIPT (what was said, with timestamps), the SUMMARY written after the call, the MEETING PREP he made before it,
> and ABOUT {OWNER}. Rules: 1) Ground every statement about what was said in the transcript and cite the line's timestamp
> exactly as written, in square brackets, like [12:34]; at most three per claim. 2) Say who said it: {owner}, or the other
> side ("Other"; "Room" lines may be either). 3) If the material does not contain the answer, say so in one sentence.
> Never guess names, numbers, dates or commitments. 4) The transcript comes from speech recognition, so words can be
> wrong; when a key word looks misheard, say so. 5) The prep and profile tell you what {owner} knew and planned; they are
> not evidence that something was said. Mark what comes from them "(from your prep)" or "(from your profile)". 6) Answer
> in the language of the question. Answer directly first, then at most five "- " bullets. Plain text, no headings, no
> tables.

### 3.3 `chat.jsonl` (one JSON object per line, append-only, written by the ask runtime only)

```json
{"type":"q","id":"q4","t":"2026-10-20T14:03:11Z","text":"…","model":"claude-sonnet-5-5"}
{"type":"a","id":"a4","q":"q4","t":"2026-10-20T14:03:15Z","text":"…","model":"claude-sonnet-5-5","usage":{…},"cost_usd":0.0104,
 "cost_estimated":false,"ms_first_token":1840,"ms_total":4120,"citations":["12:34"],"stop_reason":"end_turn","context":"full"}
{"type":"a_error","id":"a5","q":"q5","t":"…","kind":"offline","message":"…"}
{"type":"reset","t":"2026-10-20T15:00:00Z"}
```

A cancelled answer is an `a` with `stop_reason:"cancelled"` and the text so far. On `ask_start` the runtime rebuilds the
message history from the `q`/`a` pairs after the last `reset`, skipping `a_error` lines and their questions.

### 3.4 Prices (`prep/model.py`)

`OPUS = "claude-opus-5-5"`. `PRICES[model] = (input, output, cache_read)` in $/MTok: Haiku 5.5 (0.10, 0.50, 0.01),
Sonnet 5.5 (2.00, 10.00, 0.20), Opus 5.5 (4.00, 20.00, 0.20). Cache writes (5 min) = 1.25 × input. Haiku prompts over
100k tokens (input + cache read + cache write) cost (0.50, 2.50, 0.05). The 0.05 cache read and the write multiplier on
that long tier are derived, not stated by the skill: **unconfirmed**. `spend_usd` keeps its signature. Today's callers'
numbers do not change, because Haiku and Sonnet cache reads were already 0.1 × input.

### 3.5 `folders.json` (`<sessions root>/folders.json`)

```json
{"version":1,
 "folders":[{"id":"f-3k9xq2ma","name":"Acme","created_at":"2026-10-20T10:00:00Z","used_at":"2026-10-20T10:05:00Z"}],
 "assign":{"ironwood-lena":"f-3k9xq2ma"},
 "dismissed":{"adhoc-20261017-1415-room":["Acme"]}}
```

Ids are `f-` followed by 8 random lowercase base-36 characters. `used_at` is updated on every move into the folder (the
suggester's tie-break). Unknown keys are ignored on read. `SessionCatalog.list` is unaffected, because it lists only
directories that hold a `pack.md`.

### 3.6 Sim protocol and files (additive)

- Brain → Swift `say_prefetch{"id":"l0007","q_id":"q4","sentences":["Thank you.","Now, how did you …?"]}`. Older Swift
  builds ignore it.
- `sim_start` gains `ui_lang` (`en|it|tr`, report headings only; L1).
- `sim.json` gains `"source":"posting"|"session"` (absent = posting), `"source_session"` and per question an optional
  `"bank_id"`.

### 3.7 Settings keys (UserDefaults suite `dev.example.verse`)

`interfaceLanguage` (`system`), `askModel` (`sonnet`), `sessionsDetailTab` (`summary`), `sessionsListMode`
(`folders` once a folder exists, else `recent`), `sessionsCollapsedFolders` ([folder id]).

## 4. Units and packages

Executors work in their own worktree from `main` (`git worktree add ../Verse-wt-<pkg> -b <pkg> main`, after the
packages they depend on have merged). Python: `VERSE_PY=<repo>/brain/.venv/bin/python`
(worktrees have no venv). No package runs the full test suite. Every package writes new UI strings in the localizable form
(2.5) from the start, and none edits `Localizable.xcstrings` except L0 (creates it) and L1 (fills it). Each brief names
its files and nothing more.

### L0: localization groundwork and the Sessions page split (size M, `worker-hard`)

Files:

- `app/Package.swift` (`defaultLocalization`, VerseUI resources);
- new `app/Sources/VerseUI/Resources/Localizable.xcstrings` (empty catalog, `sourceLanguage: en`);
- new `app/Sources/VerseUI/L10n.swift`: `InterfaceLanguage`, `L10nState`, `L10n.locale`, `L10n.formatLocale`,
  `L10n.tr`, `L10n.bundle` (public), `TextFold.fold`;
- `app/Sources/VerseUI/AppSettings.swift` (`interfaceLanguage`);
- `app/Sources/VerseUI/HomeTheme.swift`: component titles as `LocalizedStringKey` with `verbatim:` overloads, and the
  call sites that pass dynamic strings switched to `verbatim:`. This is a compile-driven sweep: no visual change.
- `app/Sources/VerseUI/HomeSessionsPage.swift` split, a pure move with no behaviour change: the page container stays;
  new `HomeSessionsList.swift` (the list column, `UnpreparedTag`) and new `HomeSessionDetailView.swift` (the detail);
- new `app/scripts/l10n-sync.sh`, `app/scripts/l10n-check.py`;
- `app/Sources/VerseApp/Info.plist` (`CFBundleDevelopmentRegion`, `CFBundleLocalizations`);
- new test `app/Tests/VerseUITests/L10nTests.swift`, plus a test-only key "Sessions" in the catalog with it/tr values.

Tests:

- `L10n.tr("Sessions")` gives Sessions / Sessioni / Oturumlar for en/it/tr;
- `system` resolves to the first supported preferred language, with en as the fallback (injected list);
- `TextFold.fold("İstanbul") == TextFold.fold("istanbul")` and `fold("perché") == fold("perche")`;
- `HomeWindowTests` stays green (the split changed nothing);
- the sync script adds a new key from a source file to the catalog (run in a temp copy).

Acceptance:

```
cd app && swift test --filter 'VerseUITests.L10nTests|VerseUITests.HomeWindowTests' && swift build -c release && ./scripts/l10n-sync.sh && python3 scripts/l10n-check.py --allow-missing && ./scripts/bundle-app.sh && ls build/Verse.app/Contents/Resources/Verse_VerseUI.bundle/Contents/Resources/tr.lproj/Localizable.strings
```

The last steps also prove `codesign --verify --strict` passes with the bundle inside.

### F1: transcript (size M, `worker-hard`)

Files:

- new `app/Sources/VerseUI/TranscriptDocument.swift` (runs, timestamps, speakers, room relabel, cards, search, plain
  text, markdown);
- new `app/Sources/VerseUI/TranscriptView.swift` (the tab, toolbar, rows, cards, jump target API
  `TranscriptJump` as an `ObservableObject` holding the row id to reveal);
- `app/Sources/VerseUI/HomeSessionDetailView.swift` (tabs, header changes, More menu);
- `app/Sources/VerseTurns/VerseRunner.swift` (`run_start`, `t_wall` in `appendTranscript`);
- `brain/verse_brain/runtime/events.py` (`CARD_FULL_CHARS`);
- `brain/verse_brain/runtime/engine.py` (`card_done` on call finish, `me_words` on split `room_text`);
- `app/Sources/VerseUI/HomeRender.swift` (a fixture with transcript + events, render name `home-sessions-transcript-*`),
  **done last, after rebasing on main** (see conflicts);
- tests: new `app/Tests/VerseUITests/TranscriptDocumentTests.swift`, `TranscriptViewTests.swift`; extend
  `app/Tests/VerseTurnsTests/RunnerSinkTests.swift`; new `brain/tests/test_runtime_events_cards.py`; extend
  `brain/tests/test_runtime_room_reading.py` (`me_words`).
- Fixtures: the shapes of real files with fictional text (`app/Tests/VerseUITests/Fixtures/transcript-legacy-5starts/`,
  `transcript-forward/`, `transcript-room/`). Never copy the owner's session text.

Tests:

- legacy segmentation: ids restarting and a 30 s time drop each start a run; within-run duplicates keep the later text;
- alignment to the last N starts; cumulative timing without events; forward timing from `t_wall`;
- stamps: 59.4 s → "0:59", 3,725 s → "1:02:05";
- speakers: me → owner name, remote → Other, room → Room; `room_text` me → the owner; a split with `me_words` 3 → two rows;
  a legacy split stays one Room row;
- cards: the last say + deduplicated points under the right row; `now-1` attaches by time; legacy 60-character text ends
  with "…"; no cards without wall times;
- search folding (İ/ı, accents), match order, the counter, wrap-around;
- plain text and markdown golden files;
- `appendTranscript` writes `run_start` and `t_wall`, and its other keys are unchanged (golden);
- brain: `card_done` holds the full say and points clipped at 240; `me_words` equals the prefix word count.

Acceptance:

```
cd app && swift test --filter 'VerseUITests.TranscriptDocumentTests|VerseUITests.TranscriptViewTests|VerseTurnsTests.RunnerSinkTests' && cd ../brain && $VERSE_PY -m pytest tests/test_runtime_events_cards.py tests/test_runtime_room_reading.py -q
```

Then `cd app && swift build && .build/debug/Verse --render-home <scratch> sessions`. Read
`home-sessions-transcript-light.png` and `-dark.png` with the Read tool and judge them against 2.1.

### F2a: Ask runtime, brain (size M, `worker-hard`)

Files:

- new `brain/verse_brain/runtime/ask.py`:
  - `AskRuntime`, the grounding render, history from `chat.jsonl`, full/chunked modes, BM25 chunks, citations, cost;
  - the model client on the Anthropic SDK: `beta.messages` stream for sonnet/opus (fallback beta), `messages` stream for
    haiku, errors mapped with `transport.map_sdk_error`;
  - a fake responder.
- `brain/verse_brain/runtime/__main__.py` (the `ask_start` mode);
- `brain/verse_brain/runtime/protocol.py`: `ASK_IN_TYPES`, `ASK_OUT_TYPES`, **appended after `STATUS_STATES`** (do not
  edit the SIM lines);
- `brain/verse_brain/runtime/settings.py` (`ASK_ROUTES`, `ask_params(model)`, `ASK_CONTEXT_MAX_TOKENS = 180_000`,
  `ASK_EXCERPT_TOKENS = 60_000`, `ASK_HISTORY_PAIRS = 12`);
- `brain/verse_brain/prep/model.py` (`OPUS`, the 3-tuple prices, the Haiku long tier);
- new tests `brain/tests/test_runtime_ask.py`, `brain/tests/test_prep_prices.py`;
- fixtures `brain/tests/fixtures/ask/` (a fictional "Dana Reyes" session: `pack.md`, `summary.md`, a 40-row transcript
  JSON, and a `chat.jsonl` with a reset).

Tests:

- the grounding block is byte-identical for the same inputs; breakpoints ≤ 4; the system prompt is frozen (golden);
- history: pairs after the last `reset` only; an `a_error` and its question are skipped; capped at 12 pairs;
- the chunked switch at the threshold (inject a fake token counter); BM25 picks the chunk that holds the question's rare
  word; excerpts are in time order and within budget;
- citations: valid stamps kept in order, invalid ones dropped;
- `ask_delta` → `ask_done` ordering with the fake model; `control cancel` gives `stop_reason:"cancelled"` with an
  estimated cost; credit/offline/refusal map to `ask_error` kinds;
- params per model: haiku has `thinking.disabled` and no betas; opus has no `thinking` key and has effort medium plus the
  fallback beta;
- prices: the Opus cache read is 0.20/MTok; Haiku over 100k uses the long tier; today's Sonnet/Haiku numbers are
  unchanged (regression);
- `chat.jsonl` lines match 3.3 exactly;
- the meeting and sim modes are unchanged (`test_runtime_ipc.py`).

Acceptance:

```
cd brain && $VERSE_PY -m pytest tests/test_runtime_ask.py tests/test_prep_prices.py tests/test_runtime_ipc.py tests/test_runtime_sim.py -q
```

Then one live question per model on the fixture session (the owner's key, under $0.10 in total). The report quotes each
`ask_done` line.

### F2b: Ask panel, app (size M, `worker-hard`; after F1 and F2a merge)

Files:

- new `app/Sources/VerseUI/AskSession.swift` (a `BrainProcess` with `ask_start`, reconnect, idle stop, the event
  stream, `SpendLedger` updates);
- new `app/Sources/VerseUI/AskPanel.swift` (the 2.2 layout, citation chips, the starters, the composer, errors);
- new `app/Sources/VerseUI/ChatLog.swift` (reads `chat.jsonl`);
- `app/Sources/VerseUI/HomeSessionsPage.swift` (container: list | detail | panel, list hiding, ⌘⇧A);
- `app/Sources/VerseUI/HomeSessionDetailView.swift` (the Ask button; citation jump wiring through `TranscriptJump`);
- `app/Sources/VerseUI/AppSettings.swift` (`askModel`);
- `app/Sources/VerseUI/Sessions.swift` (`SpendLedger.Run.kind` optional);
- new tests `app/Tests/VerseUITests/AskSessionTests.swift`, `AskPanelTests.swift`.

Tests:

- the `ask_start` JSON golden, with transcript rows taken from `TranscriptDocument`;
- the fake brain (`--fake`) streams and the panel model accumulates deltas;
- `ask_done` adds cost to the session's `spend.json` run `kind: ask`;
- cancel sends `control cancel`; the idle timer stops the process and the next question restarts it;
- the Ask button is disabled for the running session and for sessions without a transcript;
- `ChatLog` hides pairs before a reset;
- a citation chip sets `TranscriptJump` to the matching row id.

Acceptance:

```
cd app && swift test --filter 'VerseUITests.AskSessionTests|VerseUITests.AskPanelTests|VerseUITests.TranscriptViewTests' && swift build -c release
```

Then a render `home-sessions-ask-*` (Read, judged against 2.2) and one live question in the bundled app on a real session.
The report quotes the shown cost and compares it with `spend.json`.

### F3: folders (size M, `worker-hard`)

Files:

- new `app/Sources/VerseUI/SessionFolders.swift` (`SessionFolderStore`, the `folders.json` codec, `FolderSuggester`);
- `app/Sources/VerseUI/HomeSessionsList.swift` (the 2.3 list layout, context menus, drag and drop, inline
  create/rename, delete dialog, suggestion chips);
- `app/Sources/VerseUI/HomeModels.swift` (`HomeSessionsModel`: the store, grouping, list mode, the auto-assign of
  derived practice runs);
- `app/Sources/VerseUI/HomeRender.swift` (fixtures with two folders and render `home-sessions-folders-*`), **done last,
  after F1 merged**;
- new tests `app/Tests/VerseUITests/SessionFolderTests.swift`, `FolderSuggesterTests.swift`.

Tests:

- create/rename/delete/move round trips through the file; delete leaves every session folder and file untouched
  (directory listing and hashes before and after);
- duplicate names after folding are refused; empty and over-60-character names are refused;
- pruning of vanished sessions; an unreadable file is renamed, not deleted;
- grouping order (newest session, empty folders last, No folder last);
- suggester: "ironwood-lena" matches the folder "Ironwood"; `conversation.company` "Northwind Labs" suggests a new
  folder when none matches; the longest match wins; a dismissed one is not suggested again; a sim with `source_session`
  auto-assigns;
- `SessionCatalog.list` output is unchanged with `folders.json` present.

Acceptance:

```
cd app && swift test --filter 'VerseUITests.SessionFolderTests|VerseUITests.FolderSuggesterTests|VerseUITests.HomeWindowTests'
```

Then the render (Read, judged against 2.3).

### F4a: voice prefetch (size S, `worker`)

Files:

- `app/Sources/VerseVoice/Contract.swift` (`SynthesizedSpeech`, `synthesize`/`play` with a default `speak`);
- `OpenAIVoice.swift`, `ElevenLabsVoice.swift` (synthesize = today's fetch; play = today's playback);
- `AppleVoice.swift`, `TextVoice.swift` (`.live`);
- `FallbackVoice.swift` (synthesis falls back to Apple);
- new `app/Sources/VerseVoice/PrefetchCache.swift` (actor, LRU of 16 sentences / 8 MB, ≤ 2 synthesizing at once, memory
  only);
- `app/Sources/VerseTurns/SimRunner.swift` (prefetch on `say` and `say_prefetch`, `take` in `pump`, clear on end, the
  `tts_gap_ms` metric);
- tests in `app/Tests/VerseVoiceTests/PrefetchTests.swift` and `app/Tests/VerseTurnsTests/SimRunnerTests.swift`.

Tests:

- with a fake engine whose synthesis takes 300 ms, two queued sentences play back to back with < 50 ms between them;
- `say_prefetch` then `say` with the same text synthesizes once;
- the LRU bound holds; `clear()` empties it; a failed prefetch falls back to Apple at play time;
- no file is created under the temp and caches directories during a run (the `NoAudioWrittenTests` pattern);
- keys never appear in logs (the existing grep).

Acceptance:

```
cd app && swift test --filter 'VerseVoiceTests|VerseTurnsTests.SimRunnerTests|VerseTurnsTests.SimBrainSmokeTests'
```

### F4b: sim from a session, brain (size M, `worker-hard`)

Files:

- `brain/verse_brain/prep/sim.py` (`--from-session` path: code-built question list, pack as the quoted source,
  `source_pack.md`);
- `brain/verse_brain/prep/sim_prompt.py` (the session variant of the system prompt and params);
- `brain/verse_brain/prep/__main__.py` (`--from-session`, `--me`);
- `brain/verse_brain/runtime/sim.py` (speculative ASK, `say_prefetch`, the ACK list, it/tr fixed lines);
- `brain/verse_brain/runtime/protocol.py` (**only** the `SIM_OUT_TYPES` line: add `say_prefetch`);
- new tests `brain/tests/test_prep_sim_session.py`; extend `brain/tests/test_runtime_sim.py`;
- fixtures: a fictional prepared session `brain/tests/fixtures/sim_session/`.

Tests:

- the question list = opener + bank entries in order, cut to `question_count`, each with `bank_id`; a model reply that
  reorders them is ignored;
- competency quotes not in the pack are dropped (warning); with fewer than 3 bank entries the model plans the rest;
- the output folder name and the `sim.json` source fields;
- runtime with the fake model: `say_prefetch` for q+1 comes after `listen` for q and before `answer`; on NEXT the `say`
  lines carry the same id and text; on FOLLOW the follow-up comes first and the prefetched line follows at the next
  NEXT; a failed speculative ASK falls back to a normal ASK; `end` drops it;
- `lang:"it"` uses the Italian fixed lines.

Acceptance:

```
cd brain && $VERSE_PY -m pytest tests/test_prep_sim_session.py tests/test_prep_sim.py tests/test_runtime_sim.py tests/test_sim_report.py -q
```

### F4c: Practice from a meeting, app (size M, `worker-hard`; after F4a and F4b merge)

Files:

- `app/Sources/VerseUI/SimSetupView.swift` (the Practise for section, the meeting popup, the preview row, hidden
  sections);
- `app/Sources/VerseUI/SimController.swift` (source mode, session selection, `--from-session`/`--me` arguments);
- `app/Sources/VerseUI/SimSession.swift` (`SimSetup.prepArguments` for the session source);
- `app/Sources/VerseUI/ConversationSetupView.swift` (the Up next **Practise** button);
- `app/Sources/VerseUI/HomeRouter.swift` (`showPractice(session:)`);
- tests in `app/Tests/VerseUITests/PracticeFromSessionTests.swift`.

Tests:

- the prep arguments golden for the session source (no key, no profile text on argv);
- the popup lists prepared sessions only (`general-core`, adhoc and sim are excluded); the default pick is the nearest
  Up next item;
- the preview counts come from fixture `bank.jsonl` and FACTS;
- the Up next Practise opens Practice with the session selected;
- the job posting mode is unchanged (`SimUITests` green).

Acceptance:

```
cd app && swift test --filter 'VerseUITests.PracticeFromSessionTests|VerseUITests.SimUITests' && swift build -c release
```

Then a render `home-practice-meeting-*` (Read). Then one live 5-minute mock in the bundled app from a real prepared
session, run once with the Apple voice and once with OpenAI if the key is saved (the owner, about 10 min). The report
quotes `tts_gap_ms` for the prefetched questions.

### L1: localization sweep and translations (size L, `worker-hard`; after every other package merges)

Files:

- every view file in `app/Sources/VerseUI/` and `app/Sources/VerseApp/VerseApp.swift`: literals to the 2.5 forms,
  `L10n.tr` for model strings, the window roots' `.environment(\.locale, …)`;
- `app/Sources/VerseUI/HomeModels.swift` and `HomeSessionsPage.swift`-family files where `HomeFormat` and the summary
  heading mapping live;
- `app/Sources/VerseUI/SettingsView.swift` (the Language row);
- `app/Sources/VerseUI/Resources/Localizable.xcstrings` (synced, it/tr written);
- new `app/Resources/Localization/{it,tr}.lproj/InfoPlist.strings`;
- `app/scripts/bundle-app.sh` (copy the InfoPlist.strings);
- new `app/scripts/l10n-review.py` and its output `docs/l10n/review-{it,tr}.md`;
- `brain/verse_brain/sim/render.py` (heading table) and `brain/verse_brain/runtime/sim.py` (accept `ui_lang`);
- `app/Sources/VerseUI/SimController.swift` (send `ui_lang`);
- `app/Sources/VerseUI/HomeRender.swift` (`VERSE_RENDER_LANG=it|tr`);
- new test `app/Tests/VerseUITests/LocalizationLintTests.swift`; extend `brain/tests/test_sim_report.py`.

Tests:

- the lint test is green over VerseUI and VerseApp;
- `l10n-check.py` reports zero missing keys and zero placeholder mismatches;
- switching `interfaceLanguage` en → it → tr changes a rendered `HomeRow` title without a relaunch (render or
  `ImageRenderer` width check, as in the spike);
- `HomeFormat.day` for it/tr gives "oggi"/"Bugün";
- the report headings are in Turkish for `ui_lang:"tr"`.

Acceptance:

```
cd app && swift test --filter 'VerseUITests.LocalizationLintTests|VerseUITests.L10nTests|VerseUITests.HomeWindowTests' && ./scripts/l10n-sync.sh && python3 scripts/l10n-check.py && ./scripts/bundle-app.sh && cd ../brain && $VERSE_PY -m pytest tests/test_sim_report.py -q
```

Then `VERSE_RENDER_LANG=it` and `=tr` renders of prepare, sessions, practice and settings (light only), each read with
the Read tool. Look for truncated labels: Italian and Turkish run up to about 30 % longer. Fix with `lineLimit` /
`minimumScaleFactor` ≥ 0.9 only where a row would clip, never by shrinking whole pages.

### 4.1 Conflicts, parallel groups, merge order

| File | Packages | Resolution |
|---|---|---|
| `HomeSessionsPage.swift` (one file today) | F1, F2b, F3 | L0 splits it into container / list / detail. F3 owns the list, F1 the detail, F2b the container and the detail's Ask button (after F1). |
| `HomeRender.swift` | F1, F3, L1 | F1 and F3 make their render edit last. F3 rebases on main after F1 merges, then edits. L1 is last. |
| `runtime/protocol.py` | F2a, F4b | F2a appends after `STATUS_STATES`; F4b edits only the `SIM_OUT_TYPES` line. Non-adjacent hunks. |
| `AppSettings.swift` | L0, F2b | L0 merges first. |
| `HomeModels.swift` | F3, L1 | F3 owns it in wave 1; L1 is last. F1 must not touch it (`TranscriptDocument` reads the folder itself). |
| `SimController.swift` | F4c, L1 | sequential. |
| `runtime/sim.py` | F4b, L1 | sequential. |
| All view files | L1 | L1 runs alone at the end. |

Groups:

- **Wave 0:** L0.
- **Wave 1** (parallel, disjoint apart from the rules above): F1, F2a, F3, F4a, F4b.
- **Wave 2** (parallel): F2b (needs F1 + F2a), F4c (needs F4a + F4b).
- **Wave 3:** L1.

Merge order: **L0 → F2a → F4a → F4b → F1 → F3 → F2b → F4c → L1.** After each merge the main loop re-runs that package's
acceptance command and `swift build -c release` on the merged tree (no full suites).

Fan-out: at most 5 executors at once (wave 1), within the 10-agent limit.

## 5. Tests (cross-cutting)

- **Privacy:**
  - a filesystem watch during an F4c live mock shows no audio file written;
  - `chat.jsonl` and `folders.json` hold text only;
  - no key in any log (the existing grep check over `FileLog` output and brain stderr after F2b's live question);
  - fixtures are fictional.
- **Billing:** every Claude call in F2a goes through `read_api_key()` (a test asserts that the client is constructed with
  the Keychain key and that no `ANTHROPIC_AUTH_TOKEN` / OAuth path exists in `ask.py`: grep in the test).
- **Regression:**
  - `test_runtime_layout.py` golden requests unchanged (F1's `engine.py` edit adds only events);
  - `SessionCatalog.list` unchanged;
  - the job-posting sim unchanged (`SimUITests`, `test_prep_sim.py`).
- **Cache:** in F2a's live check, `cache_read_input_tokens` ≥ the grounding block's tokens on the second question of the
  same model.

## 6. Done means

- **Transcript:**
  - on `ironwood-lena` (5 starts, 4 runs) the Transcript tab shows every turn with elapsed stamps that never go
    backwards between runs;
  - the owner and Other are labelled, and an adhoc room call shows his read-aloud card text as the owner;
  - cards appear under the questions that fired them;
  - search finds an accented Italian word typed without its accent;
  - Copy and Export (.md, .txt) produce the 2.1 formats.
- **Ask:**
  - on a real call, "What did they ask me about X?" streams an answer in Sonnet with timestamp chips that jump to the
    right rows;
  - the shown cost matches the `ask_done` usage at the 3.4 prices;
  - closing and reopening the panel shows the history from `chat.jsonl`;
  - Haiku and Opus answer from the picker;
  - every call used the Keychain key.
- **Folders:**
  - the owner creates "Ironwood", Verse suggests it for `ironwood-lena`, one click files it, and the list groups it;
  - renaming changes only the name;
  - deleting the folder leaves the session in No folder, with its files byte-identical.
- **Mock interview:**
  - from Up next → Practise on a prepared session, the owner builds and runs a spoken mock whose questions are that
    session's likely questions;
  - with no voice key it speaks in the Apple voice;
  - with an OpenAI key, prefetched questions start playing within about 1.2 s of his answer ending (JUDGE time, not TTS
    time), as measured by `tts_gap_ms`;
  - no audio file exists afterwards;
  - the report is written as today.
- **Language:**
  - Settings → Appearance → Language switches the home window, island chrome and menu between English, Italiano and
    Türkçe at once, without a relaunch;
  - System follows macOS (Turkish on this Mac);
  - `l10n-check.py` passes;
  - cards, summaries and answers stay in the call's language.

## 7. Later (not this spec)

- Practice-run transcripts (from `sim_results.json`).
- A per-session counterpart name instead of "Other" (from the pack's people or the calendar attendees).
- Ask across sessions (a folder-level "Ask Acme"), on top of folders.
- Streaming TTS playback (chunked PCM) for follow-up lines that cannot be prefetched.
- `eleven_v4_turbo`, once it is confirmed on the TTS endpoint.

## 8. What changes for the user day to day

- After a call he opens Sessions, reads or searches the transcript, and asks the meeting what he promised.
- He keeps calls in folders per company or person, mostly with one click on a suggestion.
- Before a meeting he presses Practise on Up next and rehearses the likely questions aloud.
- Verse speaks Turkish, Italian or English to him in its own UI, whatever language the call is in.

## 9. Questions only the owner can answer

None block the build. One default to be aware of: "System" makes the UI Turkish on this Mac (preferred languages
`tr-TR, it-IT`). If he wants English as the default instead, it is one line (`interfaceLanguage` default `en`).
