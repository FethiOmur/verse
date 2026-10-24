# Verse: memory package (Ask across meetings, pre-meeting brief, people and companies)

Status: decided 2026-10-21. the owner approved building it ("tüm toplantılarda kaynaklı Ask, aynı kişiyle görüşme öncesi özet, kişi/şirket
görünümü", 21 Oct); after this spec, build. No open question blocks a package (section 11). Plan:
`docs/plans/2026-10-21-verse-memory-package-plan.md`.

Builds on `2026-10-20-verse-five-features-design.md` (transcript, Ask this meeting, folders, interface language; cited below as **5F**),
`2026-10-20-ask-panel-motion.md` (the Ask panel's look and motion; **AM**), the UI redesign (`2026-10-16-verse-ui-redesign-design.md`:
tokens, `HomeTheme`, the leave-out list) and anytime calls (`2026-10-16-verse-anytime-calls-design.md`: the me layer, EmbeddingGemma).

## 1. Goal

1. **Ask across meetings, with sources.** One question over every past meeting and call: their transcripts, summaries, prep packs and
   per-meeting chats. Every claim cites the meeting, its date and the transcript line's timestamp; a click opens that meeting's transcript
   at that line. The same panel can be scoped to one person or company ("Ask about Marta").
2. **Pre-meeting brief.** Before meeting someone Verse has met before: what was discussed, what each side promised, what is still open, and
   how they like to work. Every point is cited to past meetings. It shows on the prepared session, in Prepare's Up next, on the person's
   page, and it goes into the live model's pack under a token cap.
3. **People and companies.** A sidebar page lists the people and companies of the owner's meetings. Each has a page: the meetings timeline,
   the latest brief, open follow-ups and "Ask about <name>". Identity comes from calendar attendees (email), session folders and session
   names; merge and rename are by hand.

### 1.1 What exists (read for this spec)

- **Ask this meeting** (5F 2.2, 3.2, 3.3; `brain/verse_brain/runtime/ask.py`, `AskSession.swift`, `AskPanel.swift`, `AskAnswerText.swift`,
  `ChatLog.swift`). A child process per open panel, `python -u -m verse_brain.runtime` whose first line is `ask_start`. One cached grounding
  block (meeting line, ABOUT ME, MEETING PREP without STYLE GUIDE, SUMMARY, TRANSCRIPT rows sent by Swift), history from `chat.jsonl`
  after the last `reset` (12 pairs), full mode up to 180k tokens, else a TRANSCRIPT INDEX plus BM25 excerpts. Haiku/Sonnet/Opus routes in
  `runtime/settings.py ask_params`, prices in `prep/model.py` (`PRICES`, Haiku long tier), the key only through `prep.keychain.read_api_key()`
  in `ask.make_client()` (a test greps for other credential paths). `FakeAskClient` scripts streams and token counts. Streaming
  `ask_delta` / `ask_done` / `ask_error`; citations are `[m:ss]` stamps that exist in the transcript. Swift: `AskSession` (process, idle
  stop after 10 min, `SpendLedger.record(kind: "ask")` per panel opening), `AskEvent.parse`, `AskAvailability`, `ChatLog.parse` (hides pairs
  before a reset, drops retried failures). `AskPanel`: 340 pt inspector column, header title + ⋯ menu (Model, This chat cost, Clear chat) +
  ✕, superscript stamps and a Sources row, a hover card with the cited line, `AskMotion` constants (`settle` 0.34/1.0, `quick` 0.26/1.0,
  `enter` 260 ms, `tint`/`crossfade` 150 ms), Reduce Motion crossfades. `HomeSessionsPage` hosts list | detail | panel; selecting another
  session closes the panel; ⌘⇧A toggles it.
- **Transcript** (`TranscriptDocument.swift`, `TranscriptView.swift`): the single source of rows, runs, elapsed stamps (`m:ss`, `h:mm:ss`)
  and speakers; `askRows` feed Ask; `TranscriptJump.reveal(stamp:in:)` scrolls to a row and flashes it. The detail switches to the
  Transcript tab when the jump's `serial` changes.
- **Folders** (`SessionFolders.swift`): `<sessions root>/folders.json` (`folders`, `assign`, `dismissed`), written only by the app;
  `FolderSuggester` (whole-word folded matching over folder-name words, `conversation.company`, `sim.json company`, title, FACTS names).
- **Trash** (`SessionTrash.swift`): Move to Trash with `FileManager.trashItem`, no confirmation, Undo restores the folder, its folder
  assignment, dismissed suggestions and its `EventSessionMap` entries; `hooks.sessionsChanged()` runs after both.
- **Calendar**: `MeetingEvent` has `attendees: [Attendee{name?, email?}]` and no current-user field (EventKit's `CalendarEntry.currentUser`
  is dropped in `CalendarSource.events`). `EventSessionMap` (`Verse/event-sessions.json`) keeps event id → session name only; `meta.json`
  keeps no attendees (its `prep_note` lists attendee names). `HomeUpNextModel` lists events in the next 36 h with their `MeetingEvent` and
  `prepareSession(for:)` is the one event-prep path (Up next and Practice's Upcoming).
- **Session folders** (`~/Library/Application Support/Verse/sessions/<name>/`): `meta.json` (prep stats, `languages`, `prep_note`,
  `prep_spend_usd` $0.33–$1.03 on this Mac), `pack.md`, `bank.jsonl`, `facts.jsonl`, `glossary.jsonl`, `snippets.jsonl`, `review.md`,
  after a call `transcript.jsonl` (`turn_id`, `speaker` me|remote|room, `text`, `kind`, `addressee`, `t_audio_end`, `lang`, forward:
  `run_start`, `t_wall`), `events.jsonl`, `summary.md` (`## Summary/Decisions/Actions/Open questions/Conflicts`), `spend.json`,
  `chat.jsonl`. Follow-up ticks live in UserDefaults `followUpDone.<session>` (`HomeChecklistStore`).
- **Embeddings already on this Mac**: EmbeddingGemma 2 (text 270M) on LiteRT-LM at
  `Verse/models/embeddinggemma-2-text-270m-litert/`, loaded by `runtime/embed.py LiteRtEmbedder` (bank paraphrase matcher) and by
  `prep/me.py` (me library, float16 `.emb` keyed by model sha). Measured (`bench/embed/results/latency_runs.txt`): GPU p50 19–22 ms per
  text, load 0.4–0.6 s, RSS 340 MB; CPU p50 32–128 ms. `bench/embed/bench_embed.py PREFIX["asym"]` = query
  `"task: search query | text: "`, document `"task: search result | text: "`. The brain venv has `litert_lm` and Python's `sqlite3` is
  SQLite 3.54 with FTS5 (checked 21 Oct); numpy is **not** installed.
- **L10n**: `Localizable.xcstrings` (672 keys, en/it/tr), `L10n.tr`, `Text(…, bundle: .module)`, `app/scripts/l10n-sync.sh`,
  `l10n-check.py` (fails on missing it/tr), `LocalizationLintTests`, `docs/l10n-glossary.md`.

## 2. Decisions

### 2.1 The memory index

| Topic | Decision |
|---|---|
| Where | `~/Library/Application Support/Verse/memory/` (sibling of `sessions/`, `profile/`, `models/`): `index.sqlite` (+ `-wal`, `-shm`), `index.lock`, `people.json`, `briefs/`, `chats/`, `spend.json`. `MemoryPaths(base:)` makes it injectable (tests use a temp dir). Nothing here is ever in the repo. |
| Who writes it | The brain, in a short-lived child process whose first line is `memory_index_start` (a fourth mode of `python -u -m verse_brain.runtime`). One writer at a time (`flock` on `index.lock`); a second indexer answers `status busy` and exits. Readers (the memory Ask runtime, the brief) open it read-only (`mode=ro`); WAL lets them read during a write. |
| What Swift sends | Transcript rows come from Swift's `TranscriptDocument.askRows`, as for Ask this meeting (5F 2.6: one implementation of runs and stamps). The brain reads `summary.md`, `pack.md` (STYLE GUIDE stripped with `prep.voice.strip_voice`) and `chat.jsonl` itself from the session folder. |
| Which sessions | Meetings and calls (`HomeSession.Kind.meeting`, `.call`) and prepared sessions (pack only). **Not** practice runs (`sim-*`, mock interviews are not meetings), not `general-core`, and not the session being recorded (it joins after Stop). |
| Incremental | Swift computes a fingerprint per session: SHA-256 over `MemoryIndexFormat.version` (1), the owner name (speaker labels depend on it), and `name:size:mtime_ns` of `transcript.jsonl`, `events.jsonl`, `summary.md`, `pack.md`, `chat.jsonl`, `meta.json` (missing files contribute `name:-`). Each sync sends the complete manifest; the brain drops sessions absent from it, re-indexes those whose fingerprint differs, and updates labels without re-indexing. |
| When it syncs | `MemoryService.requestSync(_:)`, coalesced (one run at a time, a request during a run schedules one more): 15 s after launch; 20 s after a call stops (`controller.running` true → false, so `summary.md` is written); at once after Move to Trash and after Undo (`SessionTrashHooks.sessionsChanged`); after an entity change (labels only); when the Ask panel opens in a memory scope (the panel waits up to 5 s, then asks the index as it is and says "Updating memory"). |
| Two phases | Phase 1 per session: rows, chunks and FTS in one transaction, then `put_done`. Phase 2: vectors for every chunk that has none for the current model sha, newest session first, in batches of 32, with `embed_progress`. A killed process loses nothing: the fingerprint is written in phase 1's transaction and phase 2 resumes on the next run. |
| Deletes | Trash: the next sync's manifest lacks the session, so the brain deletes its rows, chunks, FTS entries and vectors in one transaction with `PRAGMA secure_delete = ON`, then `PRAGMA wal_checkpoint(TRUNCATE)`, so the deleted text is overwritten in the file and the WAL. Undo: the folder is back, the sync re-indexes it (about 1 s plus embedding). No tombstone, no vector cache: nothing derived from a trashed session stays in the index. |
| Corruption | `sqlite3.DatabaseError` on open, or `user_version` ≠ the schema version: the file is renamed `index.sqlite.unreadable-<yyyyMMdd-HHmmss>` (not deleted; it is derived data, and the owner can remove it) and rebuilt from the sessions. A new embedding model sha only clears `vectors`. |

**Embeddings: yes, local, with the model Verse already ships.** Retrieval is hybrid: SQLite FTS5 (BM25) plus EmbeddingGemma 2 vectors,
fused by reciprocal rank. Why it is worth it at tens to hundreds of sessions:

- the owner's meetings run in English, Italian and Turkish, and he asks in any of them. BM25 cannot match "Marta ne söz verdi?" to "I'll send
  the pilot plan by Friday"; a multilingual embedding can. This is the main reason.
- Speech recognition mishears words and people paraphrase ("pay", "salary", "compensation"); BM25 misses those.
- The cost is small and already paid: the model is on disk, `litert_lm` is a brain dependency, the loader exists (`LiteRtEmbedder`), and it
  sends nothing anywhere (no new third party, no download). Measured 19–22 ms per chunk on the GPU: a 60-minute call (about 460 rows, about
  60 chunks) embeds in about 1.3 s; 300 sessions (about 18k chunks) backfill in about 6 min once, in the background.
- Search cost: a brute-force cosine in pure Python, measured on this Mac on 21 Oct: 10k vectors × 768 dims in 0.125 s, float16 unpacking
  of 2k vectors in 0.017 s. 18k chunks ≈ 0.4 s per question, against 2–5 s of model time. No numpy, no sqlite-vec.
- If `litert_lm` or the model is missing, or the engine fails, retrieval is FTS only and nothing else changes (the bank matcher's rule).

Rejected: **Apple `NLEmbedding`** (its sentence embedding covers a handful of languages, and Turkish is not among them as far as known;
not re-checked for this spec, and the decision does not depend on it, because EmbeddingGemma is already here and tuned);
**`NLContextualEmbedding`** (token vectors that need pooling, no retrieval tuning, a second model in the app); **a new Python model**
(a download and a new dependency for nothing EmbeddingGemma lacks); **FTS only plus a Haiku query rewrite** (an extra paid call and about
1 s on every question to do what a local vector does for free).

### 2.2 Chunks, retrieval and the citation format

| Topic | Decision |
|---|---|
| Chunks | `turn`: consecutive rows, at most 8 rows or 1,200 characters, cut on row boundaries (a longer row is a chunk of its own); the text is `[m:ss] Speaker: text` lines. `summary`: one chunk per `summary.md` section (`label` = its heading). `prep`: `pack.md` without STYLE GUIDE, cut at `## ` headings into ≤ 1,200-character chunks. `chat`: one chunk per answered Q/A pair of the session's `chat.jsonl` after the last reset (`Q: … A: …`). |
| FTS | `chunks_fts` holds `fold(text)` (`runtime/ask.fold`: lowercase, İ/I/ı → i, diacritics out, the Swift `TextFold.fold`), tokenizer `unicode61 remove_diacritics 2`. A query is its folded words minus a small stopword list (en/it/tr, `memory/search.py STOPWORDS`), each word double-quoted and OR-joined (no FTS syntax from the question ever reaches `MATCH`). |
| Vectors | One per chunk: `PREFIX["asym"]` document prefix + the chunk text, unit length, float16 little-endian, with the model sha (`prep.me.model_sha`). The query gets the query prefix. |
| Fusion | Top 60 by BM25 and top 60 by cosine inside the scope; score = Σ 1/(60 + rank) over both lists × source weight (`turn` 1.0, `summary` 1.2, `prep` 0.6, `chat` 0.5). The query is the question plus the previous question of the chat, as in 5F. |
| Packing | Best first into `MEMORY_EXCERPT_TOKENS` = 16,000 (estimated at 3.5 characters per token, `ask.est_tokens`), at most 6,000 per session so one long call cannot take everything. Then rendered by session, **newest session first**, chunks in time order inside it, `[...]` between non-adjacent chunks. |
| Session key | Each indexed session has a stable citation key: `s` + the first 6 characters of the SHA-256 of its folder name in lowercase Crockford base32 (`0123456789abcdefghjkmnpqrstvwxyz`), for example `sk3f9qa`. On a collision with an existing key, the newcomer uses 8 characters. The key depends only on the name, so an undone trash gets the same key back and old citations work again. |
| Citation forms | `[sk3f9qa 12:34]` a transcript line; `[sk3f9qa summary]`, `[sk3f9qa prep]`, `[sk3f9qa chat]` the other sources. Regex (both sides): `\[(s[0-9a-hjkmnp-tv-z]{6,8}) (\d{1,2}:\d{2}(?::\d{2})?\|summary\|prep\|chat)\]`. |
| Validation | A citation is valid when its key belongs to a session in the question's scope and, for a stamp, the `rows` table has that stamp for that session (so a stamp the model saw in an earlier answer still validates). Invalid ones stay plain text. `ask_done.citations` lists the valid ones in order of first appearance as objects (3.4) with the cited row's speaker and text, so the hover card needs no file read. |
| Jump | A turn citation opens Sessions on that session, switches the detail to Transcript and reveals the **first** row with that stamp (`TranscriptJump.reveal(stamp:in:)`, unchanged). `summary` opens the Summary tab; `prep` and `chat` select the session only (the hover card already shows the text). A stamp no longer in the transcript opens it at the top with the note "That line is no longer in this transcript." |

### 2.3 Ask across meetings

| Topic | Decision |
|---|---|
| Scopes | `AskScope`: `.session(name)` (today's Ask this meeting, unchanged), `.entity(id)` (one person or company: their sessions, 2.5), `.all` (every indexed session). Titles: "Ask this meeting", "Ask about Marta Velin", "Ask all meetings". |
| Process | `.session` keeps its `ask_start` process. `.entity` and `.all` start their own child process whose first line is `memory_ask_start` (`runtime/memory_ask.py MemoryAskRuntime`, a subclass of `AskRuntime` that reuses its streaming, cancel, chat file, cost and error mapping). Lifetime as in 5F: started when the panel opens in that scope, ended on close, on a scope change, when the window closes, or after 10 min idle. |
| Grounding | Cached block (breakpoint 1): `SESSION CATALOG`, one line per in-scope session, newest first, at most 400 (`sk3f9qa · Mon 19 Oct 2026 · meeting · Halden kickoff · with Marta Velin (Halden Works)`), plus ABOUT ME when "Use my profile in every session" is on. Uncached tail per question: `EXCERPTS` (2.2) then `QUESTION`. History: the last 6 Q/A pairs (`MEMORY_HISTORY_PAIRS`), text only (earlier excerpts are not resent). Top-level automatic `cache_control` as in 5F. |
| Trashed sources in history | A history pair whose answer cites a session no longer in the index is not sent to the model (the brain checks each pair's stored citations against `sessions`). On screen the pair stays; its tokens for that session are dimmed and say "In the Trash" on hover. |
| Models | The same picker and routes as Ask this meeting (`ask_params`), the same `AppSettings.askModel`. Billing: the Keychain key via `ask.make_client()`; never OAuth, never a claude.ai login. |
| Chat files | `memory/chats/all.jsonl` and `memory/chats/<entity-id>.jsonl`, written only by the memory Ask runtime, the 5F 3.3 line shapes plus `scope` and object citations (3.7). Clear chat appends `reset`. |
| Spend | Each panel opening is one run in `memory/spend.json` (`SpendLedger` codec, `kind: "ask"`), updated after every answer. `SpendLedger.thisMonth` adds `memory/spend.json` to the session folders, so Settings' "This month" includes it. |
| Empty and stale index | No indexed session in scope: the empty state says "Verse has no past meetings to search yet." (all) or "No meetings with Marta Velin are in Verse yet." (entity), and the composer is disabled. A sync running: a caption under the header "Updating memory · 3 of 12" (phase 1) or nothing (phase 2 only changes vectors); questions are allowed. |
| Answer language | The question's language. |

System prompt (frozen; `{owner}`, `{OWNER}` and `{scope}` are the only variables; `{scope}` is "all of {owner}'s past meetings" or "{owner}'s
past meetings with {name}"):

> You answer {owner}'s questions about {scope}. Use only the material in this conversation: the SESSION CATALOG (every meeting in scope,
> with its key, date and who was there), the EXCERPTS (the parts of those meetings that match the question: transcript lines with
> timestamps, summaries written after each meeting, his prep, and his earlier chats about a meeting) and ABOUT {OWNER}. Rules: 1) Ground
> every statement about what was said and cite it exactly in one of these forms: [<key> <timestamp>] for a transcript line, like
> [sk3f9qa 12:34], or [<key> summary], [<key> prep], [<key> chat]; at most three citations per claim. 2) Say which meeting and when ("on
> 19 Oct"), and who said it: {owner}, or the other side by name when the catalog gives one ("Other" and "Room" lines may be either).
> 3) If the material does not contain the answer, say so in one sentence; the excerpts are a selection, so say "in the parts I can see"
> when absence matters. Never guess names, numbers, dates or commitments. 4) The transcript comes from speech recognition, so words can be
> wrong; when a key word looks misheard, say so. 5) Prep and chat are not evidence that something was said: mark them "(from your prep)",
> "(from an earlier chat)"; ABOUT {OWNER} is marked "(from your profile)". 6) When meetings disagree, the newer one wins; say so. 7) Answer
> in the language of the question. Answer directly first, then at most five "- " bullets. Plain text, no headings, no tables.

### 2.4 Pre-meeting brief

| Topic | Decision |
|---|---|
| Content | Five sections with fixed English headings in the file (the UI shows localized titles, as 5F does for summary headings): `DISCUSSED`, `PROMISED BY THE USER` (the owner name, upper case), `PROMISED BY THEM`, `STILL OPEN`, `TONE AND PREFERENCES`. At most 5 points each, at most 25 words each; every point ends with 1–3 citations in the 2.2 forms. A point without a valid citation is dropped and counted (`dropped_uncited`), the repo's "no unsourced points" rule. `- (none)` and `- (nothing clear yet)` are allowed without a citation. |
| Inputs | The target entity's past sessions that have a transcript or a summary, newest first, at most 8 (`BRIEF_MAX_SESSIONS`), excluding the session the brief is for. Per session: the whole summary (`summary` chunks), its first 4 and last 8 rows (openers and closing commitments), and the top chunks of three fixed probe queries scoped to that session (commitments, open questions, preferences; each written in en, it and tr in `memory/brief.py PROBES`), up to `BRIEF_EXCERPT_TOKENS` = 18,000 in all, split evenly between sessions. Prep and chat chunks are not inputs (they are plans and model answers, not what was said). Plus an `UPCOMING` line (title, start, attendee names) when there is one. Attendee emails are never sent. |
| Process | A one-shot child process whose first line is `brief_start` (`memory/brief.py`). Its own Anthropic client through `ask.make_client()`. Model: **Sonnet** (`brief_params()` = `ask_params("sonnet")` with `max_tokens` 1,500). Not Haiku: the brief is about who promised what, where a wrong reading is costly; not Opus: twice the price for one short read. |
| Language | `lang` from the request: the upcoming session's `meta.json languages[0]`, else the language most of the input sessions' rows have (`lang` of the transcript lines), else `en`. Brain-written text is not translated (5F 2.5). |
| Trigger | **Automatic only when the owner prepares a session** (Up next or Practice's Upcoming, the `prepareSession(for:)` path) and the event's primary entity (below) has at least one past session with a transcript or summary: one brief right after the prep finishes. Prep already costs $0.33–$1.03 on this Mac, so a ≈ $0.05 brief adds 5–15 % to a spend he chose. **Manual** everywhere else: "Make brief" / "Update" on the person's page, "Brief" on an Up next item without a session, "Update" on a prepared session. **Never** in the background for calendar events he has not prepared: a meeting he skips would still cost. |
| Primary entity | Of an event: its attendees (minus the owner, 2.5) resolved to entities. One company shared by all of them → the company; else exactly one person → that person; else the person with the most past sessions (ties: most recent). The brief covers that entity's sessions (for a company, its people's sessions too). Other attendees are named in `UPCOMING`. |
| Freshness | A brief records `newest_session` (the newest input session). It is **stale** when the entity has a newer session with a transcript or summary; the UI then says "Made before your 19 Oct meeting" with **Update**. A brief is never regenerated without a click, except the one automatic brief on prepare. |
| Where it is stored | `memory/briefs/<entity-id>.json` (the latest per entity; the previous file is overwritten). A brief made for a prepared session is also written to that session's folder as `brief.json` (same content) and `brief.md` (for the live model, below). |
| Where it shows | The person's or company's page (latest brief); a prepared session's detail ("Before this meeting", above the prepared card); a past session that had one (a collapsed "Your brief before this meeting" at the end of its Summary tab); Prepare's Up next (a line and a **Brief** button, 5.4). |
| Into the live model | `brief.md` in the session folder, at most 2,400 characters (`BRIEF_PACK_CHARS`, about 600 tokens), cut at whole lines, citations removed (the live model must not cite them). `protocol.load_session` reads it into `Session.brief`; `Session.pack_for_model` = pack + a blank line + the brief block, and the engine's two `build_request` calls use it. Everything else that reads `session.pack` (follow lines, conflicts, snippet refs, the unprepared test) is unchanged, and without a `brief.md` every request byte is what it was (golden). Block heading: `PAST MEETINGS WITH <name> (from Verse's memory, as of <d Mon yyyy>; background only: what was said before, not facts of this meeting)`. |
| Spend | A brief for a prepared session is a run of kind `"brief"` in that session's `spend.json` (so the session row's spend includes it); a brief from the person's page or an Up next item without a session goes into `memory/spend.json`. |

Brief system prompt (frozen; `{owner}`, `{OWNER}`, `{name}`, `{lang}`):

> You write {owner}'s short brief before he meets {name} again. Use only PAST MEETINGS: summaries written after each meeting and transcript
> excerpts with timestamps, newest meeting first. Write exactly these five headings, each on its own line, in this order: DISCUSSED,
> PROMISED BY {OWNER}, PROMISED BY THEM, STILL OPEN, TONE AND PREFERENCES. Under each, at most five lines starting with "- ", each at most 25
> words, each ending with one to three citations exactly as given, like [sk3f9qa 12:34] for a transcript line or [sk3f9qa summary] for a
> summary. A line without a citation is discarded. Rules: 1) A promise is something a person said they would do; say who, and by when if
> it was said. A plan, a wish or a maybe is not a promise. 2) STILL OPEN: questions asked and not answered, decisions left for later.
> 3) TONE AND PREFERENCES: how {name} likes to work and talk (pace, detail, language, format, what to avoid), only when said or clearly
> shown; otherwise "- (nothing clear yet)". 4) The transcript comes from speech recognition; when a key word looks misheard, say so.
> 5) When meetings disagree, the newer one wins; write "changed on <date>" when it matters. 6) A section with nothing: "- (none)".
> 7) Write in {lang}. No other text.

### 2.5 People and companies

| Topic | Decision |
|---|---|
| Entity | `MemoryEntity`: `id` (`e-` + 8 random lowercase base-36 characters, like folder ids), `kind` (`person` \| `company`), `name`, `emails` (lowercased), `domains` (companies), `aliases`, `company` (a person's company id), `folders` (folder ids whose sessions belong to it), `namedBy` (`auto` \| `user`), `hidden`, `createdAt`. Stored in `memory/people.json` (3.6), written only by the app, on the main actor, atomically. |
| Sessions of an entity | Computed, never stored as a list (`EntityResolver.sessions(of:)`). A session belongs to E when (a) it is in one of `E.folders` (folders.json), or (b) one of its recorded attendees' emails is in `E.emails`, or its non-freemail email domain is in `E.domains`, or (c) `links[session]` contains E (a manual Add); and (d) `unlinks[session]` does not contain E. A company's page also shows its people's sessions. Moving a session between folders therefore moves it between entities with no extra write. |
| Recorded attendees | `people.json attendees[session]` = the event's attendees minus the owner, written when a session is prepared from an event: Up next and Practice's Upcoming (`afterPrepare`), and the meeting prompt's Start from invite (`MeetingCoordinator`, which creates the session as the call starts). The owner is the event's `currentUser` (new optional `MeetingEvent.currentUser`, filled from `CalendarEntry.currentUser`) and every email in `people.json ownerEmails` (each `currentUser` email seen is added). Skipped: addresses containing `resource.calendar.google.com`, `group.calendar.google.com`, `noreply`, `no-reply`, `calendar-notification`. |
| Backfill | Once, best effort: for each `EventSessionMap` entry whose session has no recorded attendees, `CalendarSource.event(id:)` (it searches a day back and two weeks ahead, so only recent and recurring events are found). Nothing is asked of the owner; misses stay unlinked. |
| Automatic entities | `EntityResolver.reconcile` (on load and after every change; it creates and never deletes): each folder that no entity lists → an entity with that name; kind `person` when the folded folder name equals a recorded attendee's folded name in that folder's sessions, else `company`. Each recorded attendee email that no entity has → a `person` (name = attendee name, else the email's local part split on `.`/`_` and capitalized). Its domain, when not on the freemail list (`EntityResolver.freemail`: gmail.com, googlemail.com, outlook.com, hotmail.com, live.com, msn.com, icloud.com, me.com, mac.com, yahoo.com, ymail.com, proton.me, protonmail.com, pm.me, gmx.com, gmx.de, gmx.net, libero.it, virgilio.it, tiscali.it, alice.it, yandex.com, yandex.ru, mail.ru, hey.com, fastmail.com), → the company whose `domains` has it, else the company whose folded name equals the domain's first label, else a new `company` named after that label, capitalized (`halden.example` → "Halden"); the person's `company` is set when empty. |
| Weak signals | Session title words, folder-name words, `meta.json conversation.company` and FACTS name lines (the folder suggester's haystack, `FolderSuggester.haystack`) that contain an entity's folded name or alias as whole words → a **suggestion** on the entity page ("Maybe also"), never a link. Add → `links`; Not this → `dismissed[entity]`. Same rule as folders: nothing moves without a click. |
| Rename | Inline on the entity page (⋯ → Rename…): trimmed, 1–80 characters, unique per kind after folding (`TextFold.fold`); sets `namedBy = user`. A folder rename renames an entity whose name came from that folder only while `namedBy == auto`. |
| Change kind | ⋯ → "Make This a Company" / "Make This a Person". A person losing its kind keeps its emails; a company becoming a person loses its `domains` into `aliases` (a domain is not a person's). |
| Merge | ⋯ → "Merge Into…" → a searchable popover of entities of the same kind → a confirmation ("Merge “M. Velin” into “Marta Velin”?" / "Its meetings, emails and names move to “Marta Velin”. Its brief and chat are kept on disk and no longer shown."). The survivor gets the union of `emails`, `domains`, `aliases` (plus the loser's name), `folders`; `links`, `unlinks`, `dismissed` are rewritten to the survivor; `merged[loser] = survivor` so old router selections, chat scopes and brief ids resolve. Undo (⌘Z and the toast) restores the whole `people.json` snapshot taken before the merge. Rename and kind changes are undoable the same way. Cross-kind merge is not offered. |
| Suggest a merge | Two entities of one kind whose folded names are equal, or whose names share the first word and one is a single word (`Marta` / `Marta Velin`), → an inline line on the newer one's page: "Same person as Marta Velin?" with **Merge** (secondary) and Not this. Never automatic. |
| Hide | ⋯ → "Hide from People" (an assistant, a room, a mailing list): `hidden = true`; hidden entities are left out of the list and of resolution; a "Hidden" section at the end of the list (collapsed) brings them back. |
| Listed | Entities with at least one session or one upcoming event (Up next's 36 h), not hidden. An entity without either stays in the file (its emails keep resolving) and comes back when a session links. |
| Contacts | No Contacts import (a permission prompt, and the calendar already carries names and emails). |
| Labels for the index | Each session's entity names (person, then company) are sent in the sync manifest as `labels`; the brain shows them in the catalog line ("with Marta Velin (Halden Works)"). Changing an entity's name updates labels without re-indexing. |

### 2.6 Rejected

- **Swift owning the SQLite index.** Retrieval, prompts and tests live in Python already; two writers (Swift FTS, Python vectors) would need
  a protocol anyway. Swift sends rows; the brain owns the file.
- **One long-lived memory process for index, ask and brief.** Different lifetimes (a sync is seconds, a panel minutes, a brief one call);
  three small modes of the existing CLI are simpler and fail independently.
- **Indexing practice runs.** Mock interviews would answer "what did Marta ask me" with the sim's questions.
- **A vector cache that survives trash.** Vectors are derived from the text; keeping them keeps the meeting.
- **Per-question session-local `[m:ss]` stamps in memory answers.** They are ambiguous across meetings; the key + stamp form keeps the
  stamp exact and adds the meeting.
- **Automatic briefs for every calendar event.** Cost without a decision by the owner (2.4).
- **Haiku for the brief by default.** Cheap but the wrong place to save $0.045.
- **Entities as folders.** A session has one folder but often a person and a company; folders stay the owner's filing, entities read them.
- **Auto-merging by similar names.** Two Martas at two companies are common; merge is a click.
- **A People mode inside the Sessions list.** The entity page needs the full detail column, and the Sessions list already has Folders ·
  Recent; a sidebar page is one click and leaves Sessions unchanged.
- **Leave-out list (UI)**: dashboard card grids and stat tiles ("12 meetings", "3 open"), CRM-style tables with columns (company, title,
  phone, last contact), relationship scores or health meters, sparkline or activity charts, coloured or photo avatars, rainbow initial
  badges, tag-pill clouds, emoji chips, "AI" sparkle icons and gradient "magic" buttons, opaque chat bubbles, a coloured model picker, a
  second accent colour.

## 3. Data and protocol (additive; current messages and files unchanged)

### 3.1 Files

```
~/Library/Application Support/Verse/
  memory/index.sqlite      brain only (memory_index_start writes; memory_ask_start and brief_start read)
  memory/index.lock        flock by the indexer
  memory/people.json       app only (EntityStore)
  memory/briefs/<id>.json  brain writes (brief_start); app reads
  memory/chats/all.jsonl   brain writes (memory_ask_start); app reads
  memory/chats/<id>.jsonl  idem, per entity
  memory/spend.json        app writes (SpendLedger codec)
  sessions/<name>/brief.json, brief.md   brain writes (brief_start with session_out); app and the live runtime read
```

### 3.2 `index.sqlite` schema (`user_version = 1`, `journal_mode = WAL`, `foreign_keys = ON`, `secure_delete = ON`)

```sql
CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);            -- 'embed_sha'
CREATE TABLE sessions(
  name TEXT PRIMARY KEY,            -- session folder name
  key TEXT NOT NULL UNIQUE,         -- citation key, 2.2
  title TEXT NOT NULL, date TEXT NOT NULL,   -- date: ISO 8601 with offset
  kind TEXT NOT NULL,               -- meeting | call | prepared
  lang TEXT NOT NULL DEFAULT '',
  labels TEXT NOT NULL DEFAULT '[]',         -- JSON array of entity names
  fingerprint TEXT NOT NULL,
  indexed_at TEXT NOT NULL);
CREATE TABLE rows(
  session TEXT NOT NULL REFERENCES sessions(name) ON DELETE CASCADE,
  ix INTEGER NOT NULL, stamp TEXT NOT NULL, speaker TEXT NOT NULL, text TEXT NOT NULL,
  PRIMARY KEY(session, ix));
CREATE INDEX rows_stamp ON rows(session, stamp);
CREATE TABLE chunks(
  id INTEGER PRIMARY KEY,
  session TEXT NOT NULL REFERENCES sessions(name) ON DELETE CASCADE,
  source TEXT NOT NULL,             -- turn | summary | prep | chat
  ord INTEGER NOT NULL,             -- order inside (session, source)
  stamp TEXT, stamp_end TEXT,       -- turn chunks: first and last row stamp
  row_first INTEGER, row_last INTEGER,
  label TEXT,                       -- summary heading / prep heading
  text TEXT NOT NULL, tokens INTEGER NOT NULL);
CREATE INDEX chunks_session ON chunks(session, source, ord);
CREATE VIRTUAL TABLE chunks_fts USING fts5(body, content='', contentless_delete=1,
  tokenize='unicode61 remove_diacritics 2');   -- rowid = chunks.id, body = fold(text)
CREATE TABLE vectors(
  chunk INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
  model_sha TEXT NOT NULL, dim INTEGER NOT NULL, vec BLOB NOT NULL);   -- float16 LE, unit length
```

The contentless FTS table has no cascade: `drop` deletes `chunks_fts` rows by rowid in the same transaction before the session row.

### 3.3 Index protocol (Swift → `python -u -m verse_brain.runtime`, first line `memory_index_start`)

```json
{"type":"memory_index_start","db":"/…/memory/index.sqlite","embed":true}
{"type":"sync","sessions":[{"name":"halden-kickoff","fp":"9c1e…","labels":["Marta Velin","Halden Works"]}]}
{"type":"put","name":"halden-kickoff","dir":"/…/sessions/halden-kickoff","fp":"9c1e…","title":"Halden Kickoff",
 "date":"2026-10-19T17:00:00+02:00","kind":"meeting","lang":"en","labels":["Marta Velin","Halden Works"],
 "rows":[{"stamp":"0:18","speaker":"the owner","text":"…"}]}
{"type":"end"}
```

Brain → Swift:

```json
{"type":"status","state":"ready","context":{"sessions":12,"chunks":731,"vectors":700,"embed":"on|off"}}
{"type":"sync_plan","need":["halden-kickoff"],"dropped":["old-session"],"relabelled":3}
{"type":"put_done","name":"halden-kickoff","key":"sk3f9qa","chunks":61,"ms":38}
{"type":"embed_progress","done":120,"total":183}
{"type":"index_error","name":"halden-kickoff","kind":"unreadable|bad_request|db","message":"…"}
{"type":"status","state":"done","context":{"sessions":12,"chunks":744,"vectors":744,"embed":"on"}}
```

`status busy` when the lock is held (Swift retries after 30 s). The process exits after `done` (or on stdin EOF after finishing the
current transaction). `embed:false` (renders, `--no-embed`) skips phase 2; `--fake` uses `prep.me.HashEmbedder`. Logs carry names and
counts, never text.

### 3.4 Memory Ask protocol (first line `memory_ask_start`)

```json
{"type":"memory_ask_start","db":"/…/memory/index.sqlite","chat":"/…/memory/chats/e-8hz1p0qq.jsonl","owner_name":"the owner",
 "me":{"core":"/…/profile/me.md"},"scope":{"kind":"entity","id":"e-8hz1p0qq","name":"Marta Velin",
 "sessions":["halden-kickoff","halden-pilot-review"]},"model":"sonnet"}
```

`scope.kind` is `all` (then `sessions` is null: every indexed session) or `entity`. `me` is null when the profile toggle is off. `ask`,
`control cancel|reset|stop` as in 5F 3.2. Brain → Swift as in 5F 3.2 (`status` with `context:{tokens,mode:"memory",sessions,history}`,
`ask_delta`, `ask_error`), and `ask_done` carries object citations:

```json
{"type":"ask_done","id":"a3","q":"q3","model":"claude-sonnet-5-5","usage":{…},"cost_usd":0.041,"ms_first_token":2100,"ms_total":5200,
 "stop_reason":"end_turn","cost_estimated":false,"excerpt_tokens":15820,
 "citations":[{"key":"sk3f9qa","session":"halden-kickoff","title":"Halden Kickoff","date":"2026-10-19T17:00:00+02:00",
   "kind":"turn","stamp":"12:34","speaker":"Marta","text":"We'd need the pilot plan by Friday."},
  {"key":"sp0m2vx","session":"halden-pilot-review","title":"Halden Pilot Review","date":"2026-10-24T10:00:00+02:00",
   "kind":"summary","stamp":null,"speaker":null,"text":"Actions: Send the revised budget"}]}
```

Per-session Ask (`ask_start`) keeps string citations; Swift tells the two apart by element type.

### 3.5 Brief protocol (first line `brief_start`; one request, then the process exits)

```json
{"type":"brief_start","db":"/…/memory/index.sqlite","owner_name":"the owner",
 "entity":{"id":"e-3k9xq2ma","kind":"person","name":"Marta Velin","company":"Halden Works"},
 "sessions":["halden-pilot-review","halden-kickoff"],
 "upcoming":{"title":"Halden weekly","start":"2026-10-28T10:00:00+01:00","attendees":["Marta Velin","Joe Arkwright"]},
 "lang":"en","out":"/…/memory/briefs/e-3k9xq2ma.json","session_out":"/…/sessions/halden-weekly","model":"sonnet"}
```

`upcoming` and `session_out` may be null. Brain → Swift: `status warming|ready|error`, then `brief_done{path,cost_usd,usage,points,
dropped_uncited,ms_total}` or `brief_error{kind,message,retry_after?}` (kinds as `ask_error`, plus `no_sessions`).

`brief.json` (both locations):

```json
{"version":1,"entity":"e-3k9xq2ma","name":"Marta Velin","made_at":"2026-10-21T09:12:00Z","lang":"en","model":"claude-sonnet-5-5",
 "newest_session":"halden-pilot-review","for_session":"halden-weekly",
 "sessions":[{"name":"halden-pilot-review","key":"sp0m2vx","title":"Halden Pilot Review","date":"2026-10-24T10:00:00+02:00"}],
 "sections":[{"id":"discussed","points":[{"text":"The pilot covers two teams, not four","cites":[
   {"key":"sp0m2vx","session":"halden-pilot-review","kind":"turn","stamp":"4:10"}]}]},
  {"id":"promised_owner","points":[]},{"id":"promised_them","points":[]},{"id":"open","points":[]},{"id":"tone","points":[]}],
 "usage":{…},"cost_usd":0.048,"dropped_uncited":1}
```

Section ids: `discussed`, `promised_owner`, `promised_them`, `open`, `tone`. `(none)` lines are stored as no points.

`brief.md` (session folder only):

```
PAST MEETINGS WITH Marta Velin (from Verse's memory, as of 21 Oct 2026; background only: what was said before, not facts of this meeting)
Discussed: The pilot covers two teams, not four. …
Promised by the owner: Send the revised budget by Friday (24 Oct). …
Promised by them: …
Still open: …
Tone and preferences: …
```

### 3.6 `people.json`

```json
{"version":1,
 "entities":[
  {"id":"e-3k9xq2ma","kind":"person","name":"Marta Velin","emails":["marta@halden.example"],"domains":[],"aliases":[],
   "company":"e-8hz1p0qq","folders":[],"named_by":"auto","hidden":false,"created_at":"2026-10-21T09:00:00Z"},
  {"id":"e-8hz1p0qq","kind":"company","name":"Halden Works","emails":[],"domains":["halden.example"],"aliases":["Halden"],
   "company":null,"folders":["f-3k9xq2ma"],"named_by":"user","hidden":false,"created_at":"2026-10-21T09:00:00Z"}],
 "attendees":{"halden-kickoff":[{"name":"Marta Velin","email":"marta@halden.example"}]},
 "owner_emails":["owner@example.com"],
 "links":{"conv-20261012-0930-halden":["e-8hz1p0qq"]},
 "unlinks":{},
 "dismissed":{"e-3k9xq2ma":["adhoc-20261017-1415-room"]},
 "merged":{"e-old00001":"e-3k9xq2ma"}}
```

Unknown keys are ignored. An unreadable file is renamed `people.json.unreadable-<stamp>` and a note shows once (the folders rule). Keys of
`links`, `unlinks` and `dismissed` lists for sessions that no longer exist are pruned on every write. `attendees` is never pruned
automatically: an Undo of Move to Trash needs it back, the resolver only ever looks at sessions that exist, and the same emails live on in
the entities anyway.

### 3.7 Memory chat lines

As 5F 3.3, with `"scope":"all"` or `"scope":"e-…"` on `q` lines, and `a` lines whose `citations` are the full 3.4 objects (with `speaker`
and `text`, so the hover card works on reopened history without a lookup). History rebuild skips pairs that cite a session no longer
indexed (2.3).

### 3.8 Settings keys (UserDefaults suite `dev.example.verse`)

`peopleCollapsedHidden` (true), `askMemoryScope` (`all`; the last memory scope used from the Sessions page). No other new key.

## 4. Costs (USD; gross = net: Anthropic bills API usage in USD to the Individual Org key with no tax line in Verse's ledger)

Prices from `prep/model.py` ($/MTok input, output, cache read; cache write 1.25 × input): Haiku 0.10/0.50/0.01, Sonnet 2.00/10.00/0.20,
Opus 4.00/20.00/0.20.

| What | Tokens (estimate) | Sonnet | Haiku | Opus |
|---|---|---|---|---|
| Ask across meetings, first question | cache write 2.5k (system + catalog of 60 sessions), tail 16k, out 0.5k | ≈ $0.043 gross / $0.043 net | ≈ $0.002 / $0.002 | ≈ $0.087 / $0.087 |
| Ask across meetings, next questions | cache read 2.5k + history ≈ 2k, tail 16k, out 0.5k | ≈ $0.038 / $0.038 | ≈ $0.002 / $0.002 | ≈ $0.075 / $0.075 |
| Catalog of 400 sessions (≈ 12k tokens) | extra cache write once per 5 min, then reads | + $0.030 once, + $0.0024 per question | + $0.0015 | + $0.060 |
| Brief | in ≈ 19k (system 0.9k, upcoming 0.3k, excerpts ≤ 18k), out ≈ 0.9k | ≈ $0.047 / $0.047 (Sonnet is the brief model) | (≈ $0.0024) | (≈ $0.094) |
| Brief in the live pack | 600 tokens in the cached prefix | write ≈ $0.0015 once, ≈ $0.00012 per call: ≈ $0.012 per 100 calls | negligible | |
| Indexing and embeddings | local | $0 | | |

A month at the owner's pace (60 prepared meetings → 60 automatic briefs, 60 questions across meetings on Sonnet, the live pack add-on):
≈ $2.82 + $2.30 + $0.50 ≈ **$5.60 gross / $5.60 net**. The panel shows each answer's cost and "This chat" as today; the brief's cost shows
under it ("Sonnet · $0.05").

## 5. UI flows and states

Tokens, glass and the one accent are the redesign's (`HomeTheme`, `VT`); motion constants are `AskMotion` (AM 2); dark mode is designed
first and checked in light. One primary (lime) button per page at most.

### 5.1 Sidebar and People page

- **Sidebar**: a new page **People** (`HomePage.people`, SF `person.2`) after Sessions: Prepare, Me, Sessions, People, Practice, Scripts,
  Settings.
- **Layout**: like Sessions: a 254 pt list column (18 pt margin) and the entity page in the detail column. No inspector.
- **List column**:
  - Title row: "People" (large title).
  - A search field under it (`magnifyingglass`, placeholder "Search people and companies"), filtering by folded name, alias, email,
    company; ⌘F focuses it; Esc clears.
  - Sections "People" and "Companies" (section header style of the Sessions folders: 12 semibold, `ink.secondary`, sentence case, a count
    in caption tertiary monospaced digits), then a collapsed "Hidden" section when any exist.
  - Row (44 pt): a monogram (24 pt; a circle for people, a 6 pt-radius rounded square for companies; `ink.fill`, initials 10.5 semibold
    `ink.secondary`; no colour, no photo), the name (13 medium, `ink.primary`), a second line (caption, `ink.tertiary`): person "Halden
    Works · 3 meetings · 19 Oct", company "2 people · 5 meetings · 24 Oct". An upcoming meeting replaces the date with "Tomorrow 10:00"
    in `ink.secondary` (text, not a badge).
  - Order: upcoming first (soonest), then last met, newest first. Selection uses the Sessions row selection fill; ↑/↓ move it.
- **Entity page** (scrolls; side padding as the Sessions detail: 20 leading, 28 trailing, 26 top):
  - **Header**: monogram 44 pt, name (20 bold, tracking −0.3), meta line (callout, `ink.secondary`): "Person · Halden Works ·
    marta@halden.example" / "Company · halden.example · 2 people". Actions: **Ask about Marta** (`HomeSecondaryButton`,
    `bubble.left.and.text.bubble.right`) and a ⋯ menu (Rename…, Make This a Company / Person, Merge Into…, Hide from People, Show Folder
    in Sessions when it has one).
  - **Next** (only with an upcoming event): one row, "Next · Halden weekly · Tomorrow 10:00", with **Prepare** (secondary) when the event
    has no session, or "Prepared" (caption) when it does.
  - **Brief** plate (`HomeGroup(plate: true)`), title "Brief" plus a caption "Made 21 Oct · Sonnet · $0.05":
    - ready: the five sections with localized titles (Discussed, You promised, They promised, Still open, Tone and preferences; "You" is
      the owner), points as 13 regular text with superscript citation marks and a Sources row per section (the Ask answer rendering,
      `AskAnswerText`, so citations look and behave the same: hover card, click opens the session at the line);
    - stale: a line above it "Made before your 24 Oct meeting." with **Update** (secondary);
    - none: "No brief yet. Verse can sum up your 3 past meetings with Marta: what was said, what was promised and what is still open."
      with **Make brief** (the page's one primary) and the caption "About $0.05 on your Anthropic key.";
    - making: "Making the brief…" breathing like Ask's Thinking line (1.1 s half cycle; static under Reduce Motion), Cancel (secondary);
    - failed: `HomeNote(isError)` with the Ask error texts by kind, and **Retry**;
    - no past meeting with a transcript or summary: the plate is not shown.
  - **Follow up** plate: the unticked `Actions` items of the entity's sessions' summaries, newest session first, each a checkbox row (the
    session detail's follow-up rows, same `HomeChecklistStore` keys, so ticking here ticks there) with a caption "Halden Kickoff · 19 Oct".
    Ticked items leave the list after 1.2 s (opacity, `tint`). Empty: the plate is not shown.
  - **Meetings** plate (the timeline):
    - grouped by month ("October 2026", 12 semibold `ink.secondary`);
    - each row: a 52 pt date gutter ("19 Oct", 11 medium `ink.tertiary`, monospaced digits, right-aligned, the transcript gutter's metrics),
      a 1 pt `ink.separator` rule at the gutter's edge running the length of the group, then the title (13 medium), a caption (kind or
      route, "· Brief" when it had one), and the first sentence of its Summary section (12 regular `ink.secondary`, one line, truncated);
    - upcoming events on top under "Upcoming";
    - a click selects the session in Sessions (`router.showSession(name)`); the row tints on hover in 150 ms.
  - **Maybe also** (only with suggestions): rows "Halden pricing call · 12 Oct" with **Add** and **Not this** (both neutral, small).
  - **Same person as …?** (only with a merge suggestion): one line with **Merge** (secondary) and Not this.
- **Empty page** (no entity at all): centred, "People appear here from your calendar invites and your session folders." and **Open
  Sessions** (secondary). Calendar off: a second line "Turn on “Use my calendar” in Settings to add the people you meet."
- **Rename**: the header name becomes a text field (same font), ⏎ saves, Esc cancels; errors as `HomeNote` under it (empty, too long,
  "There is already a person named “Marta Velin”.").
- **Merge Into…**: a popover (320 pt) with a search field and the same-kind entities as list rows; choosing one shows the confirmation
  dialog (2.5). After merging, the survivor is selected and a toast "Merged into Marta Velin" with Undo (the Sessions trash toast).

### 5.2 Ask panel in memory scopes (on the Sessions page)

- **Entry points**: (1) a 24 pt neutral icon button `bubble.left.and.text.bubble.right` in the Sessions list title row, before
  `folder.badge.plus`, help "Ask all meetings"; (2) **Ask about Marta** on an entity page: it switches to Sessions, selects the entity's
  newest session and opens the panel scoped to the entity; (3) ⌘⇧A: opens the panel in the scope used last on this page
  (`.session` when that session offers Ask, else `askMemoryScope`).
- **Panel**: the AM panel, unchanged in size, motion and composer. Differences:
  - title: "Ask all meetings" / "Ask about Marta Velin" / "Ask this meeting";
  - ⋯ menu gains a **Scope** section above Model: "This meeting" (when the selected session offers Ask), one item per entity of the
    selected session ("Marta Velin", "Halden Works"), "All meetings"; a checkmark on the current one. Changing scope ends the process, shows
    that scope's history and starts the new one (one `crossfade`, 150 ms, of the conversation; the panel does not move);
  - under the title, only while a sync's phase 1 runs: "Updating memory · 3 of 12" (caption, tertiary);
  - starters (memory scopes): all: "What did I promise, and to whom?", "What is still open across my meetings?", "Which meetings talked
    about pricing?", "What did people ask me most often?"; entity: "What did we agree last time?", "What did I promise Marta?", "What is
    still open with Marta?", "How does Marta like to work?";
  - the empty-state privacy line: "Answers use your Anthropic key and the meetings in Verse's memory on this Mac.";
  - **citations**: in memory scopes the superscript mark is the source's ordinal (1, 2, 3 in order of first citation in that answer), and
    the Sources row lists tokens "1 Halden Kickoff · 19 Oct · 12:34" (summary: "2 Halden Pilot Review · 24 Oct · Summary"). The hover
    card shows the session title and date as its caption line, then the speaker and the cited text. A token whose session is no longer in
    the index is dimmed (`ink.tertiary`), not clickable, help "In the Trash". VoiceOver: "Source 1: Halden Kickoff, 19 October, at 12
    minutes 34 seconds", with the custom action "Show in the transcript".
- **Selection**: in memory scopes, selecting another session (by click or by a citation) keeps the panel open. In `.session` scope the 5F
  rule stays (another session closes it).
- **Citation click**: `router.showSession(name, reveal: .stamp("12:34"))` (or `.summary`, `.none`); the detail of that session loads,
  then `TranscriptJump` reveals the row and flashes it (AM 13). The list column stays hidden while the panel is open.

### 5.3 Session detail

- **Prepared session with a brief** (`brief.json` in its folder, or the latest brief of its primary entity when it has no own): a "Before
  this meeting" plate above the prepared card, the 5.1 Brief rendering, with "Update" when stale. Without one but with past meetings for
  its entity: a line "You've met Marta 3 times. Make a brief?" with **Make brief** (secondary; the prepared card keeps its primary).
- **Past session that had a brief**: at the end of the Summary tab, a disclosure "Your brief before this meeting" (collapsed by default,
  remembered per session in view state only).
- **People row**: under the meta line, the session's entities as plain text links ("Marta Velin · Halden Works", callout,
  `ink.secondary`, underline on hover) that open their People page; a trailing "Add person…" (caption) opens a popover to link an
  existing entity (`links`) or remove one (`unlinks`).

### 5.4 Prepare: Up next

- An item whose primary entity has past meetings gets a second caption line "Met 3 times · last 19 Oct" (tertiary).
- Trailing actions: unchanged (Prepare / Start / Practise), plus **Brief** (secondary, `text.document`):
  - a fresh brief exists → opens a popover (380 pt wide, max 520 pt tall, scrolls) with the 5.1 Brief rendering and "Open Marta's page";
  - none and the item has no session → it makes an entity brief (button shows a small spinner and "Brief…"; help "About $0.05 on your
    Anthropic key"), then opens the popover;
  - preparing an item makes the automatic brief after prep (2.4); its row says "Preparing…" then "Making brief…" until both finish.
- Practice's Upcoming uses the same `prepareSession(for:)`, so its prepare also makes the automatic brief; it shows no brief UI.

### 5.5 Motion (all from `AskMotion`; nothing new)

| What | Motion | Reduce Motion |
|---|---|---|
| People row selection, hover | fill in `tint` (150 ms) | same |
| Entity page change | the page crossfades in `crossfade` (150 ms); no slide (a selection, not a navigation) | same |
| Brief appears (made or updated) | each section: opacity 0→1 and 6 pt up, `enter` (260 ms), 40 ms stagger, at most 5 | opacity 150 ms, no stagger |
| Making the brief | the Thinking breath (1.1 s per half cycle) | static line |
| Follow-up ticked | the row fades out after 1.2 s in `tint` | same |
| Merge popover | the system popover | system |
| Scope change in the panel | the conversation crossfades (150 ms) | same |
| Memory citation jump | AM 13 (the transcript flash) | AM 13 |

### 5.6 Accessibility

Rows are buttons with the name and the second line as label and value; monograms are hidden. The brief reads section by section; each
citation is a custom action. Increase Contrast and Reduce Transparency follow the token sets. Every control has a label; "Brief ready" is
announced when a brief finishes.

### 5.7 Strings (en / it / tr)

New glossary terms (added to `docs/l10n-glossary.md`):

| en | it | tr |
|---|---|---|
| People (the page) | Persone | Kişiler |
| Person / Company | Persona / Azienda | Kişi / Şirket |
| Brief (noun) / Make brief | Briefing / Prepara briefing | Brifing / Brifing hazırla |
| Ask all meetings | Chiedi a tutte le riunioni | Tüm toplantılara sor |
| Ask about %@ | Chiedi su %@ | %@ hakkında sor |
| Memory (Verse's index) | Memoria | Hafıza |
| Merge / Merge Into… | Unisci / Unisci a… | Birleştir / Şununla Birleştir… |
| Rename… | Rinomina… | Yeniden Adlandır… |
| Hide from People | Nascondi da Persone | Kişiler’den Gizle |
| You promised / They promised | Hai promesso / Hanno promesso | Söz verdiklerin / Söz verdikleri |
| Tone and preferences | Tono e preferenze | Üslup ve tercihler |

Every other new string is written by the executor in en, it and tr following the glossary, and `l10n-check.py` must pass. Brain-written
brief and answer text is not translated.

## 6. Privacy

- Everything stays in `~/Library/Application Support/Verse/` on this Mac; nothing new is ever committed. Tests use fictional people at
  `.example` domains (RFC 2606): Marta Velin and Joe Arkwright (Halden Works, `halden.example`), Giulia Ferri (Corvo Studio,
  `corvo.example`, an Italian call), Emre Kaya (Tarla Labs, `tarla.example`, a Turkish call), owner "Dana Reyes" (the existing fictional
  owner). Never a real session's text, name or email.
- **No audio** is read, written or indexed: only the text files listed in 2.1.
- **No new third party.** Embeddings run locally (EmbeddingGemma on LiteRT, already on disk). Anthropic receives meeting text only when
  the owner asks a question in a memory scope or a brief is made (his click, or his Prepare), exactly the material in 2.3/2.4, through the
  Keychain key; never OAuth.
- Attendee **emails never leave the Mac**: the brain receives names only (labels, `upcoming.attendees`); a test asserts that no request
  payload contains an `@` from the fixture's attendees.
- The index holds copies of meeting text. Trash removes them with secure delete and a WAL truncate (2.1). Briefs and memory chats are
  derived text: a point or answer that cites a trashed session is hidden on screen and left out of the model history; the files keep it
  until the brief is updated or the chat is cleared, the same exposure as the session folder sitting in the Trash.
- Logs (`FileLog`, brain stderr) carry names, counts, keys and timings, never meeting text, questions, answers or emails (the existing
  redaction rule; tests grep a run's logs for fixture sentences).
- `people.json`, briefs and chats are excluded from "Save to vault" (it writes the summary only, unchanged).

## 7. Edge cases

| Case | Behaviour |
|---|---|
| Session renamed or moved outside Verse | Drop plus a new put: a new key; old citations become plain text. |
| A call restarted (a new run appended) | New fingerprint, re-put; stamps of the old rows do not change (5F timestamps are elapsed since the first run). |
| Duplicate stamp in one session | Validation passes; the jump goes to the first row with it (5F behaviour). |
| Prepared session that never ran | Indexed with `prep` chunks only; it never counts as a past meeting for briefs. |
| Transcript without summary, or the reverse | Indexed with what exists; briefs accept either. |
| Recording session | Not in the manifest until it stops; its old index entry (a re-Start of the same session) stays searchable meanwhile. |
| Embedding model missing, `litert_lm` missing, engine failure | FTS only, `embed: off` in status, no UI; vectors backfill when the model appears. |
| Model file replaced (new sha) | `vectors` cleared and re-embedded on the next sync. |
| Index unreadable or schema changed | Renamed and rebuilt (2.1); questions during the rebuild see an empty or partial index (the "Updating memory" caption). |
| Two indexers (a second app instance) | `flock`: the second answers `status busy` and exits; Swift retries in 30 s. |
| 1,000 sessions | Catalog capped at 400 newest with a line "(and 600 older meetings, searched but not listed)"; search ≈ 0.6 s. |
| Question in Turkish, meetings in English | Vectors find them; FTS adds nothing; the answer is in Turkish. |
| Scope with no indexed session (all trashed) | Empty state (2.3), composer disabled. |
| Citation to a trashed session | Token dimmed, "In the Trash"; after Undo and a sync it works again (same key). |
| Merged entity id in a chat scope, router selection or brief | Resolved through `merged`. |
| Same person with two emails | Two entities until merged; the merge suggestion shows when the names fold equal. |
| A person at a freemail address | A person without a company; the owner can put the session in a folder or merge. |
| Event with only the owner | No primary entity, no brief UI. |
| Event with people from two companies | Primary entity per 2.4; the others are named in UPCOMING only. |
| Key missing, credit exhausted, offline | Ask: the 5F errors. Brief: `brief_error` shown on the plate with Retry; the automatic brief on prepare fails quietly and the prepared session shows "The brief could not be made: <reason>" with Retry. |
| Brief cancelled (Cancel while making) | The process is stopped; nothing is written; the partial cost (from `message_start` usage) goes to the ledger, flagged estimated. |
| A brief is being made when another is requested for the same entity | The second request waits for the first and then opens it (no second call). |
| Up next attendees change after a brief | The brief stays; the primary entity is recomputed on refresh. |

## 8. Test plan (cross-cutting; each package's tests are in the plan)

- **Brain unit tests** (pytest, `FakeAskClient`, `HashEmbedder`, a fixture sessions tree under `brain/tests/fixtures/memory/`): schema,
  keys, chunking, sync/put/drop/relabel, secure delete leaves no fixture sentence in the database file bytes, FTS folding (İ/ı, accents),
  hybrid fusion, scope filtering, packing budgets, citation regex and validation, catalog and prompt goldens, history filtering, brief parse
  and the uncited drop, `brief.md` cap, `pack_for_model`, layout goldens unchanged.
- **App unit tests** (XCTest): manifest and fingerprints, the sync driver against a scripted fake transport, triggers (launch, stop, trash,
  undo, entity change), `people.json` codec, resolver (folders, emails, domains, freemail, links/unlinks, merge, suggestions, owner
  exclusion), `MeetingEvent.currentUser` decode compatibility, spend totals, Ask scopes and object citations, brief placement rules.
- **Renders** (light and dark, read with the Read tool and judged against section 5): `home-people-*` (list + entity page with brief, with
  stale brief, without brief, empty), `home-sessions-ask-memory-*` (panel in all and entity scope, Sources tokens, hover card),
  `home-sessions-prepared-brief-*`, `home-prepare-upnext-brief-*`.
- **End to end with `--fake`**: Swift `MemoryService` → real `python -m verse_brain.runtime --fake` index → memory ask → citation objects →
  the panel model; Move to Trash → sync → a search no longer returns the trashed session; Undo → it returns with the same key.
- **Live (the owner's key, under $0.30 in all)**: one Sonnet question across the fixture tree and one brief; the reports quote `ask_done` and
  `brief_done`. One Turkish question over English fixture text must cite the right meeting (cross-lingual check of EmbeddingGemma).
- **Privacy**: no `@` of fixture attendees in any captured request; no fixture sentence in logs; no audio file in the memory dir.
- **Billing**: the existing grep test extended to `runtime/memory_ask.py` and `memory/brief.py` (only `ask.make_client()`).

## 9. Done means

- Ask all meetings: on the user's real sessions, "What did I promise last week?" streams a Sonnet answer whose Sources open the right meeting
  at the right line; a Turkish question finds an English meeting; the cost matches `ask_done` at the 3.4 prices and lands in
  `memory/spend.json`.
- Moving a meeting to the Trash removes it from answers at once; Undo brings it back with working citations.
- Preparing an Up next meeting with someone met before makes a brief within about 15 s of the prep; it shows on the prepared session and
  on the person's page with five cited sections, and the live model's pack carries its `brief.md` (seen in the brain's request log as the
  PAST MEETINGS block).
- People lists the people and companies of his calendar invites and folders; a person's page shows the meetings timeline, the brief, the
  open follow-ups (ticks shared with the session detail) and Ask about; rename, kind change, merge and their Undo work.
- Everything is localized in en/it/tr (`l10n-check.py` passes) and reads well in dark and light renders.

## 10. Later (not this spec)

- Settings → Memory: indexed count, Rebuild, Forget everything.
- Copying a brief into an adhoc session started from an event that has an entity brief.
- A brief per attendee group instead of the primary entity.
- Contacts import, photos.
- Practice-run transcripts in memory.
- A date filter in questions ("last week") applied before retrieval rather than left to the model.

## 11. Questions only the owner can answer

None block the build. Defaults he may want to change later: the automatic brief on Prepare (one line to turn off), Sonnet as the brief
model, the 16k-token excerpt budget per question (the main cost lever: 8k halves it at some recall cost).
