# Verse memory package plan

Goal: Ask across meetings with sources, a cited pre-meeting brief, and a People page, as specified.
Spec: `docs/specs/2026-10-21-verse-memory-package-design.md` (cited as **spec**; 5F = `docs/specs/2026-10-20-verse-five-features-design.md`,
AM = `docs/specs/2026-10-20-ask-panel-motion.md`).
Approach: the brain owns a local SQLite index (FTS5 + EmbeddingGemma vectors) written by a short `memory_index_start` process from rows
Swift sends; two more brain modes answer memory questions (`memory_ask_start`) and write briefs (`brief_start`). The app keeps the index in
sync, owns `people.json` and the People page, and extends the Ask panel to entity and all-meetings scopes.

Global constraints (every package):

- Personal data never enters the repo. Fixtures are fictional: Marta Velin and Joe Arkwright (Halden Works, `halden.example`), Giulia
  Ferri (Corvo Studio, `corvo.example`, Italian), Emre Kaya (Tarla Labs, `tarla.example`, Turkish), owner "Dana Reyes". Never copy text,
  names or emails from `~/Library/Application Support/Verse/`.
- No audio is read, written or indexed.
- Claude calls only through `verse_brain.runtime.ask.make_client()` (Keychain key, `prep.keychain.read_api_key`); never OAuth, never
  `ANTHROPIC_AUTH_TOKEN`. Attendee emails never go to the brain or the model.
- Logs carry names, counts and timings, never meeting text, questions, answers or emails.
- UI: `HomeTheme`/`VT` tokens, dark mode first, one lime primary per page at most, motion only from `AskMotion` (spec 5.5). Leave out:
  dashboard card grids and stat tiles, CRM tables with columns, relationship scores, charts, coloured or photo avatars, tag-pill clouds,
  emoji chips, "AI" sparkles, opaque chat bubbles, a second accent.
- Every UI string goes through `Text(…, bundle: .module)` / `L10n.tr`, with it and tr written in `Localizable.xcstrings` following
  `docs/l10n-glossary.md` and spec 5.7; `python3 scripts/l10n-check.py` must pass.
- Python: `VERSE_PY=/Users/user/Desktop/ProjectExamples/CursorExamples/Verse/brain/.venv/bin/python` (worktrees have no venv; in
  the main checkout it is `brain/.venv/bin/python`).
- Executor hygiene: read only `tail -60` of build and test logs or grep their result and error lines; never run the full test suite; stop
  and report after 5 failed attempts at the acceptance command.
- Worktrees: `git worktree add ../Verse-wt-<pkg> -b <pkg> main`, created after the packages it depends on have merged. Commit on the
  branch; do not push; the main session merges.

Packages: 5.

| # | Package | Agent | Depends on | Wave |
|---|---|---|---|---|
| P1 | Brain: memory index and search | worker-hard | none | 1 |
| P2 | App: memory service, sync and brief runner | worker-hard | none | 1 |
| P3 | Brain: memory Ask, brief, live pack | worker-hard | P1 | 2 |
| P4 | App: people model and People page | worker-hard | P2 | 2 |
| P5 | App: Ask in memory scopes and brief placements | worker-hard | P2, P3, P4 | 3 |

- Wave 1: P1 ∥ P2 (brain vs app, no shared file). Wave 2: P3 ∥ P4 (brain vs app, no shared file). Wave 3: P5 alone.
- Merge order: **P1 → P2 → P3 → P4 → P5.** After each merge the main session re-runs that package's acceptance command, plus
  `cd app && swift build -c release` for app packages, on the merged tree.

Shared files and their order:

| File | Packages | Rule |
|---|---|---|
| `brain/verse_brain/runtime/__main__.py`, `runtime/protocol.py`, `runtime/settings.py` | P1, P3 | P1 first; P3 branches from main after P1 merged. Both append; neither edits the meeting, sim or ask lines except adding types to `IN_TYPES`. |
| `app/Sources/VerseUI/HomeWindow.swift` | P2, P4, P5 | P2 adds `HomeContext.memory`; P4 adds the People page, `HomeContext.people`, label and attendee wiring; P5 extends `afterPrepare` with the automatic brief. Sequential. |
| `app/Sources/VerseUI/HomeRender.swift` | P4, P5 | P4 then P5, each edits it last after rebasing. |
| `app/Sources/VerseUI/Resources/Localizable.xcstrings` | P2, P4, P5 | Sequential by construction (P2 merges before P4 starts; P5 after P4). Each runs `./scripts/l10n-sync.sh` then writes it/tr. |
| `app/Sources/VerseUI/HomeModels.swift` | P2 | P2 only (the `afterPrepare` hook). P4 and P5 only call `HomeChecklistStore` and `HomeUpNextModel`. |
| `app/Sources/VerseUI/HomeRouter.swift` | P4 | P4 only; P5 consumes its API. |
| `app/Sources/VerseUI/MeetingCoordinator.swift`, `app/Sources/VerseMeet/*` | P4 | P4 only (one closure property; `currentUser`). |

Package checklist (tick on acceptance): [ ] P1 [ ] P2 [ ] P3 [ ] P4 [ ] P5

---

### Package P1: Brain memory index and search

Agent: worker-hard
Owns:
- new `brain/verse_brain/memory/__init__.py`
- new `brain/verse_brain/memory/index.py` (schema, open, keys, chunking, sync/put/drop/relabel, vectors)
- new `brain/verse_brain/memory/search.py` (FTS query, hybrid search, packing, rendering, citation regex and resolution)
- new `brain/verse_brain/memory/indexer.py` (`IndexRuntime`, the `memory_index_start` mode)
- `brain/verse_brain/runtime/__main__.py` (dispatch `memory_index_start`)
- `brain/verse_brain/runtime/protocol.py` (add `memory_index_start`, `sync`, `put`, `drop`, `end` to the accepted input types; new
  `MEMORY_INDEX_OUT_TYPES` after the ask block)
- `brain/verse_brain/runtime/settings.py` (append the P1 constants below)
- new tests `brain/tests/test_memory_index.py`, `brain/tests/test_memory_search.py`, `brain/tests/test_runtime_memory_index.py`
- new fixtures `brain/tests/fixtures/memory/sessions/{halden-kickoff,halden-pilot-review,corvo-design-call,tarla-intro,halden-weekly-prep}/`
  (each: `rows.json` = the rows Swift would send, plus `summary.md`, `pack.md` with a STYLE GUIDE section, `chat.jsonl` with a `reset`,
  as the session's kind needs; `halden-weekly-prep` has `pack.md` only; `corvo-design-call` is Italian, `tarla-intro` Turkish, the rest
  English)
Do not touch: anything under `app/` (P2, P4, P5), `runtime/ask.py`, `runtime/engine.py`, `runtime/prompt.py` (P3 owns engine edits).
Read first: spec 2.1, 2.2, 3.1–3.3, 7; `runtime/ask.py` (`fold`, `fold_words`, `est_tokens`, `Row`, BM25 helpers), `runtime/embed.py`
(`LiteRtEmbedder`, `unit`), `prep/me.py` (`model_sha`, `HashEmbedder`, the `.emb` float16 codec), `bench/embed/bench_embed.py PREFIX`,
`runtime/__main__.py` (mode dispatch), `prep/voice.py strip_voice`.

Decisions:
- Schema exactly spec 3.2, `user_version = 1`, `PRAGMA journal_mode=WAL; foreign_keys=ON; secure_delete=ON`.
- Readers open with `sqlite3.connect(f"file:{path}?mode=ro", uri=True)`.
- Unreadable file or wrong `user_version`: rename to `index.sqlite.unreadable-<yyyyMMdd-HHmmss>` and create a new one. Never delete it.
- Session key: `"s" + crockford(sha256(name.encode()))[:6]`, alphabet `0123456789abcdefghjkmnpqrstvwxyz` over the digest's bits from the
  most significant; on a collision with another session's key, the newcomer takes `[:8]`.
- Chunking (`MEMORY_CHUNK_ROWS = 8`, `MEMORY_CHUNK_CHARS = 1_200`): turn chunks of consecutive rows cut on row boundaries, a row longer
  than the cap alone; text `[m:ss] Speaker: text` per line; `stamp`/`stamp_end`, `row_first`/`row_last` set. Summary: one chunk per
  `## ` section, `label` = heading, the `_generated…_` and `> DRAFT` lines skipped. Prep: `strip_voice(pack)` cut at `## ` headings and
  then at 1,200 characters on line boundaries. Chat: one chunk per answered pair after the last `reset` (reuse `ask.load_history` with
  `limit` large), text `Q: …\nA: …`.
- FTS body = `ask.fold(text)`; `fts_query` = folded words minus `STOPWORDS` (≤ 40 common words each for en, it, tr), each wrapped in
  double quotes (inner quotes removed), joined with ` OR `; `None` when nothing is left (then the FTS branch is skipped).
- Search: top `MEMORY_CANDIDATES = 60` from `bm25(chunks_fts)` and from cosine, both restricted to the scope; RRF with
  `MEMORY_RRF_K = 60`; × `MEMORY_SOURCE_WEIGHTS = {"turn": 1.0, "summary": 1.2, "prep": 0.6, "chat": 0.5}`; pack best-first into
  `MEMORY_EXCERPT_TOKENS = 16_000` with at most `MEMORY_SESSION_EXCERPT_TOKENS = 6_000` per session (`ask.est_tokens`); render newest
  session first, chunks in (source, ord) time order, `[...]` between non-adjacent turn chunks.
- Vectors: document prefix `"task: search result | text: "`, query prefix `"task: search query | text: "` (bench `PREFIX["asym"]`);
  `unit()`; float16 LE blobs; pure-Python dot products with `sum(map(operator.mul, …))`; vectors of the scope loaded once per search
  call. Phase 2 embeds newest sessions first in batches of `MEMORY_EMBED_BATCH = 32`. With no embedder, everything works FTS-only.
- `IndexRuntime` follows spec 3.3 to the letter; `flock(LOCK_EX | LOCK_NB)` on `index.lock`; busy → `status busy` and exit 0.
- `--fake` → `HashEmbedder`; `--no-embed` or `memory_index_start.embed == false` → no phase 2; otherwise
  `LiteRtEmbedder(cfg.embed_model, cfg.embed_backend)`, and an `EmbedUnavailable` makes `embed: "off"`.

Interfaces (Produces, used by P3):
- `memory.index.SCHEMA_VERSION: int`, `session_key(name: str, taken: set[str]) -> str`
- `memory.index.MemoryIndex.open(path: Path, *, readonly: bool = False) -> MemoryIndex`
- `MemoryIndex.plan_sync(manifest: list[dict]) -> SyncPlan` (`need: list[str]`, `dropped: list[str]`, `relabelled: int`; drops and
  relabels are already committed)
- `MemoryIndex.put(*, name, dir: Path, fp, title, date, kind, lang, labels: list[str], rows: list[ask.Row]) -> PutResult(key: str, chunks: int)`
- `MemoryIndex.drop(names: list[str]) -> None` (secure delete, then `wal_checkpoint(TRUNCATE)`)
- `MemoryIndex.pending_vectors(model_sha: str, limit: int) -> list[tuple[int, str]]`, `store_vectors(model_sha, items: list[tuple[int, list[float]]])`
- `MemoryIndex.sessions(scope: list[str] | None) -> list[SessionInfo]` (newest first; `SessionInfo(name, key, title, date, kind, lang, labels)`),
  `session_by_key(key) -> SessionInfo | None`, `rows_at(name, stamp) -> list[ask.Row]`, `chunks_of(name, source) -> list[ChunkHit]`,
  `first_last_rows(name, first: int, last: int) -> list[ask.Row]`
- `memory.search.search(index, query: str, *, scope: list[str] | None, embedder: QueryEmbedder | None, budget_tokens: int = MEMORY_EXCERPT_TOKENS,
  per_session_tokens: int = MEMORY_SESSION_EXCERPT_TOKENS, sources: tuple[str, ...] = ("turn", "summary", "prep", "chat")) -> list[SessionExcerpt]`
- `memory.search.render_excerpts(excerpts: list[SessionExcerpt]) -> str` (header line per session:
  `== sk3f9qa · Mon 19 Oct 2026 · meeting · Halden Kickoff · with Marta Velin (Halden Works)`; summary chunks as
  `SUMMARY (<label>): …`, prep as `PREP (<label>): …`, chat as `EARLIER CHAT: …`)
- `memory.search.CITE_RE` = `re.compile(r"\[(s[0-9a-hjkmnp-tv-z]{6,8}) (\d{1,2}:\d{2}(?::\d{2})?|summary|prep|chat)\]")`
- `memory.search.resolve_citations(index, text: str, scope: list[str] | None) -> list[dict]` (spec 3.4 objects, order of first
  appearance, invalid ones dropped)
- `memory.search.QueryEmbedder(embedder)` with `.query(text) -> list[float]` and `.document(text) -> list[float]`

Test cases:
- schema: a new file has `user_version` 1, WAL, the five tables; reopening keeps data.
- unreadable: a file of garbage bytes is renamed `index.sqlite.unreadable-*` and a fresh index opens.
- key: `session_key("halden-kickoff", set())` is `s` + 6 chars of the alphabet and stable across runs; with that key in `taken` it returns 8 chars.
- chunking: 20 short rows → 3 turn chunks (8, 8, 4); a 2,000-character row is a chunk alone; summary with 4 sections → 4 chunks with
  labels; pack STYLE GUIDE text appears in no chunk; chat pairs before `reset` appear in no chunk.
- plan_sync: manifest without `tarla-intro` → it is in `dropped` and gone from `sessions`, `rows`, `chunks`, `chunks_fts`, `vectors`;
  changed fp → in `need`; changed labels only → `relabelled` 1, not in `need`.
- put twice for one session → chunk count equals one put's, FTS matches once.
- secure delete: after `drop`, the bytes of `index.sqlite` and its `-wal` do not contain a distinctive fixture sentence (closed file).
- vectors: `pending_vectors` lists every chunk; after `store_vectors` none; a new model sha lists them all again.
- FTS folding: query "istanbul" finds a row "İstanbul"; "perche" finds "perché"; a question containing `"`, `*`, `NEAR(` and `-` does not raise.
- scope: a scope of one session never returns another's chunks.
- fusion: with a scripted embedder (Turkish query vector equal to an English chunk's vector), the English chunk is in the results although
  FTS finds nothing; without an embedder the same search returns only FTS hits.
- weights: equal ranks → the summary chunk ranks before the prep chunk.
- packing: total ≤ 16,000 estimated tokens, no session over 6,000; render puts the newer session first and `[...]` between gaps.
- citations: `CITE_RE` matches all four forms and not `[s12 1:00]` or `[sk3f9qa]`; `resolve_citations` keeps a valid stamp, drops an
  unknown stamp, an out-of-scope key and an unknown key, and fills `speaker`/`text` from the first row with that stamp.
- runtime (`python -m verse_brain.runtime --fake` fed lines): start → `status ready`; sync → `sync_plan`; put → `put_done` with key; end
  → `embed_progress` then `status done` and exit 0; a held `index.lock` → `status busy`; captured stderr contains no fixture sentence.
- live, gated by `VERSE_LIVE_EMBED=1` (skipped otherwise): index the fixture with the real `LiteRtEmbedder`; the Turkish question "Marta
  pilot planını ne zaman göndereceğimi söyledi?" ranks a `halden-*` turn chunk in the top 3. The report quotes the ranks.

Acceptance: `cd brain && $VERSE_PY -m pytest -q tests/test_memory_index.py tests/test_memory_search.py tests/test_runtime_memory_index.py tests/test_runtime_ipc.py tests/test_runtime_ask.py`
→ all pass, 0 failed (the live test skipped). Then once: `cd brain && VERSE_LIVE_EMBED=1 $VERSE_PY -m pytest -q tests/test_memory_search.py -k live`.
Done means: the commands above pass; the meeting, sim and ask modes are unchanged (`test_runtime_ipc.py`, `test_runtime_ask.py` green).
Stop and ask if: SQLite in the venv lacks FTS5 or `contentless_delete`; the real embedder's vector dimension is not constant; the live
cross-lingual check ranks no Halden chunk in the top 10 (report the ranks, do not tune prefixes beyond trying `PREFIX["sym"]` once).

---

### Package P2: App memory service, sync and brief runner

Agent: worker-hard
Owns:
- new `app/Sources/VerseUI/MemoryService.swift` (`MemoryPaths`, `MemoryIndexFormat`, `MemoryManifest`, `MemoryIndexer`, `MemoryService`)
- new `app/Sources/VerseUI/BriefStore.swift` (`BriefFile`, `BriefRequest`, `BriefStore`)
- `app/Sources/VerseUI/Sessions.swift` (`SpendLedger.thisMonth` adds the memory dir)
- `app/Sources/VerseUI/SessionTrash.swift` (`SessionTrashHooks.window(…, memory:)`)
- `app/Sources/VerseUI/HomeWindow.swift` (only `HomeContext`: a `memory: MemoryService` property and init parameter, `attach(controller:)`)
- `app/Sources/VerseUI/HomeModels.swift` (only `HomeUpNextModel`: the `afterPrepare` init parameter)
- `app/Sources/VerseUI/Resources/Localizable.xcstrings` (its few strings)
- new tests `app/Tests/VerseUITests/MemoryManifestTests.swift`, `MemoryServiceTests.swift`, `BriefStoreTests.swift`,
  `SpendLedgerMemoryTests.swift`; fixtures `app/Tests/VerseUITests/Fixtures/memory/` (a fictional sessions tree with a transcript,
  summary, pack and chat, and one `brief.json` of spec 3.5)
Do not touch: `brain/` (P1, P3), `HomeRouter.swift`, `EntityStore.swift`, People views (P4), `AskSession.swift`, `AskPanel.swift`,
`ChatLog.swift`, `HomeSessionsPage.swift`, `HomeSessionDetailView.swift`, `ConversationSetupView.swift` (P5).
Read first: spec 2.1, 2.4 (Trigger, Where stored, Spend), 3.1, 3.3, 3.5; `AskSession.swift` (process lifecycle, `AskWire`), `BrainProcess`
(`app/Sources/VerseTurns/BrainProcess.swift`), `HomeSessionsPage.makeBrainProcess`, `TranscriptDocument.load`/`askRows`, `HomeSession.load`,
`SessionCatalog`, `SpendLedger`, `SessionTrash.swift` (`SessionTrashHooks.window`), `HomeWindow.swift` (`HomeContext`), `HomeModels.swift`
(`HomeUpNextModel.prepareSession`).

Decisions:
- Paths: `MemoryPaths(base: URL)`; `.live` = Application Support `Verse/memory`. `dir`, `db` (`index.sqlite`), `people` (`people.json`),
  `briefs`, `brief(entity:)` (`briefs/<id>.json`), `chats`, `chat(named:)` (`chats/<name>.jsonl`), `spendDir` (= `dir`). Created lazily.
- Manifest: `SessionCatalog.list(root:)` minus `GeneralPrep.isGeneral`, minus `sim-*`, minus the recording session; kinds from
  `HomeSession.Kind` (`meeting`, `call`, `prepared`). Fingerprint per spec 2.1 (`MemoryIndexFormat.version = 1`), hex SHA-256 via CryptoKit.
  `date` = ISO 8601 with local offset of `HomeSession.date`; `lang` = `meta.json languages[0]` or `""`; `labels` from the injected closure.
- The indexer process: `BrainProcess(brainDir:extraArgs:)` (`--fake` when `controller.fakeBrain`), first line `memory_index_start`
  (`embed: true`, false in renders), then `sync`; for each `need` name, rows from `TranscriptDocument.load(sessionDir:ownerName:).askRows`
  built on a detached task, sent as `put` one at a time (wait for `put_done` or `index_error` before the next); then `end`; the process
  exits after `status done`. Keys sorted in every JSON line (`AskWire.line`).
- Coalescing: one run at a time; requests during a run set a flag for exactly one more run. `status busy` → retry after 30 s (injectable
  delay). Launch trigger 15 s after `attach`, call-end trigger 20 s after `controller.running` goes false (both injectable).
- Brief runner: one `brief_start` process per request (spec 3.5), at most one per entity (a second request for the same entity awaits
  the first's result). Result read from the `out` file after `brief_done`. Spend: `sessionOut` set → `SpendLedger.record(sessionDir:
  sessionOut, startedAt:, costUSD:, kind: "brief")`; else into `paths.spendDir`. Errors map to `ChatFailure(kind:message:retryAfter:)`
  (the 5F kinds plus `no_sessions`, `start_failed`). `cancelBrief(entity:)` sends `control stop`, kills the process if it has not ended
  in 2 s, and records nothing unless `brief_error` reported usage.
- `SpendLedger.thisMonth(root:now:calendar:extraDirs:)` with `extraDirs` defaulting to `[MemoryPaths.live.spendDir]`.
- `SessionTrashHooks.window(controller:sim:settings:router:memory:)`: `sessionsChanged` also calls `memory?.requestSync(.sessionsChanged)`.
- `HomeUpNextModel.init(…, afterPrepare: @escaping @MainActor (MeetingEvent, String) -> Void = { _, _ in })`, called in
  `prepareSession(for:)` after `onPrepared` with the event and the new folder name.

Interfaces (Produces):
```swift
struct MemoryPaths: Sendable { init(base: URL); static var live: MemoryPaths; var dir, db, people, briefs, chats, spendDir: URL
  func brief(entity id: String) -> URL; func chat(named: String) -> URL }
enum MemoryIndexFormat { static let version = 1 }
struct MemoryManifest: Equatable { struct Entry: Equatable, Sendable { var name, fp: String; var labels: [String]; var title, date, kind, lang: String }
  var entries: [Entry]
  static func build(root: URL, ownerName: String, recording: String?, labels: (String) -> [String]) -> MemoryManifest
  static func fingerprint(dir: URL, ownerName: String) -> String }
@MainActor final class MemoryService: ObservableObject {
  enum Phase: Equatable { case idle, indexing(done: Int, total: Int), embedding(done: Int, total: Int), failed(String) }
  enum SyncReason: Sendable { case launch, callEnded, sessionsChanged, labelsChanged, askOpened }
  @Published private(set) var phase: Phase
  @Published private(set) var indexedSessions: Int
  @Published private(set) var briefsInFlight: Set<String>
  let paths: MemoryPaths
  var labels: (String) -> [String]          // P4 wires EntityStore
  var recordingSession: () -> String?
  init(paths: MemoryPaths = .live, sessionsRoot: URL = SessionCatalog.root, ownerName: @escaping () -> String,
       makeBrain: @escaping () throws -> any SimBrainTransport)
  func attach(controller: VerseController)
  func requestSync(_ reason: SyncReason)
  func syncNow(timeout: Duration?) async -> Bool        // true when a run finished within the timeout
  func makeBrief(_ request: BriefRequest) async -> Result<BriefFile, ChatFailure>
  func cancelBrief(entity id: String) }
struct BriefRequest: Equatable, Sendable { struct Entity: Equatable, Sendable { var id, kind, name: String; var company: String? }
  struct Upcoming: Equatable, Sendable { var title: String; var start: Date; var attendees: [String] }
  var entity: Entity; var sessions: [String]; var upcoming: Upcoming?; var lang: String; var sessionOut: URL?; var model = "sonnet" }
struct BriefFile: Codable, Equatable, Sendable {      // spec 3.5, snake_case keys on disk
  struct SessionRef: Codable, Equatable, Sendable { var name, key, title, date: String }
  struct Cite: Codable, Equatable, Sendable { var key, session, kind: String; var stamp: String? }
  struct Point: Codable, Equatable, Sendable { var text: String; var cites: [Cite] }
  struct Section: Codable, Equatable, Sendable { var id: String; var points: [Point] }   // ids: discussed, promised_owner, promised_them, open, tone
  var version: Int; var entity, name: String; var madeAt: Date; var lang, model: String; var newestSession: String
  var forSession: String?; var sessions: [SessionRef]; var sections: [Section]; var costUSD: Double; var droppedUncited: Int
  func isStale(newestSession: String?) -> Bool }       // true when newestSession is non-nil and differs from self.newestSession
enum BriefStore { static func load(entity id: String, paths: MemoryPaths) -> BriefFile?; static func load(sessionDir: URL) -> BriefFile? }
```

Test cases:
- fingerprint: changing the size or mtime of each of the six files changes it; changing the owner name changes it; an unrelated file
  (`review.md`) does not; a missing file is stable.
- manifest: `sim-*`, `general-core` and the recording session are absent; a prepared-only session has kind `prepared`; labels come from
  the closure.
- sync (scripted fake transport): the first line is `memory_index_start`, the second the `sync` manifest (golden JSON); `sync_plan` with
  one `need` → exactly one `put` whose `rows` equal `TranscriptDocument.askRows` of the fixture (golden); then `end`; `phase` goes
  indexing(0,1) → indexing(1,1) → embedding(…) → idle.
- coalescing: three `requestSync` calls during a run → exactly one extra run.
- busy: `status busy` → a second process 30 s later (injected 0.05 s).
- trash: `HomeSessionsModel.trash` with fake `SessionTrashOps` and the window hooks → the next manifest lacks the session; `restore` →
  it is back.
- start failure: `makeBrain` throws → `phase == .failed`, no crash, the next request tries again.
- brief: request line golden (spec 3.5 keys, sorted); `brief_done` → returns the decoded `out` file; spend lands in the session's
  `spend.json` with `kind: "brief"` when `sessionOut` is set, else in `memory/spend.json`; `brief_error` credit → `ChatFailure(kind:
  "credit_exhausted")`; two requests for one entity start one process.
- BriefStore: decodes the fixture `brief.json`; `isStale` true for a newer session name, false for the same or nil; a missing or garbage
  file → nil.
- thisMonth: a run in `memory/spend.json` this month is counted, last month's is not.
- afterPrepare: `HomeUpNextModel.prepareSession` with a fake `prepare` calls `afterPrepare` once with the event and folder name.

Acceptance: `cd app && swift test --filter 'VerseUITests.MemoryManifestTests|VerseUITests.MemoryServiceTests|VerseUITests.BriefStoreTests|VerseUITests.SpendLedgerMemoryTests|VerseUITests.SessionTrashTests|VerseUITests.KeychainAndSpendTests|VerseUITests.HomeWindowTests' && swift build -c release && ./scripts/l10n-sync.sh && python3 scripts/l10n-check.py`
→ all tests pass, release build succeeds, `l10n-check.py` exits 0.
Done means: the commands pass; nothing in the app calls the memory service except `HomeContext` wiring and the trash hook (no UI yet).
Stop and ask if: `SimBrainTransport` cannot carry a process whose first line is not `ask_start`/`sim_start` without changing VerseTurns;
`HomeContext`'s init change breaks a call site outside the files you own (list it).

---

### Package P3: Brain memory Ask, brief and live pack

Agent: worker-hard
Owns:
- new `brain/verse_brain/runtime/memory_ask.py` (`MemoryAskRuntime`, `MEMORY_SYSTEM_TEMPLATE`, `render_catalog`)
- new `brain/verse_brain/memory/brief.py` (`BRIEF_SYSTEM_TEMPLATE`, `PROBES`, `BriefRuntime`, `parse_brief`, `render_brief_md`)
- `brain/verse_brain/runtime/__main__.py` (dispatch `memory_ask_start` and `brief_start`)
- `brain/verse_brain/runtime/protocol.py` (accept `memory_ask_start`, `brief_start`; `Session.brief`, `Session.pack_for_model`,
  `load_session` reads `brief.md`)
- `brain/verse_brain/runtime/settings.py` (append the P3 constants and `brief_params()`)
- `brain/verse_brain/runtime/engine.py` (only the two `build_request(…, self.session.pack, …)` calls → `self.session.pack_for_model`)
- new tests `brain/tests/test_runtime_memory_ask.py`, `brain/tests/test_memory_brief.py`, `brain/tests/test_runtime_brief_pack.py`
- fixtures: reuse P1's `brain/tests/fixtures/memory/`; add `brain/tests/fixtures/memory/brief/` (scripted model outputs)
Do not touch: `memory/index.py`, `memory/search.py`, `memory/indexer.py` beyond bug fixes reported to the main session; `runtime/ask.py`
(subclass it, do not edit it); `runtime/prompt.py`; anything under `app/`.
Read first: spec 2.3, 2.4, 3.4, 3.5, 3.7, 4; P1's `memory/index.py` and `memory/search.py` interfaces (in the plan's P1 section and the
code); `runtime/ask.py` entirely; `runtime/protocol.py load_session`; `engine.py` around its `build_request` calls; `test_runtime_layout.py`.

Decisions:
- `MemoryAskRuntime(AskRuntime)`: overrides start (open the index read-only, load `chat` path from the message, scope sessions, catalog
  grounding with ABOUT OWNER as in `ask.py`, `mode = "memory"`), `chat_path` (the message's `chat`), `build_request` (cached block =
  catalog; tail = `render_excerpts(search(…))` + `"\n\nQUESTION\n" + question`, the query = question + previous question), history
  (`MEMORY_HISTORY_PAIRS = 6`, skipping pairs whose stored citations name a session not in the index), and `_finish` (citations from
  `resolve_citations`, stored as full objects in the chat `a` line, `excerpt_tokens` in `ask_done`). Streaming, cancel, errors, cost:
  inherited unchanged.
- System prompt: spec 2.3 verbatim (golden). Catalog line format of P1's `render_excerpts` header; at most `MEMORY_CATALOG_MAX = 400`
  newest, then `(and N older meetings, searched but not listed)`.
- The query embedder: `LiteRtEmbedder` loaded at start unless `--fake` (`HashEmbedder`) or `--no-embed`; failure → FTS only.
- `BriefRuntime`: reads `brief_start`; sessions filtered to those in the index with a transcript or summary chunk, newest first, at most
  `BRIEF_MAX_SESSIONS = 8`; none → `brief_error{kind:"no_sessions"}`. Inputs per spec 2.4 (summary chunks; first 4 and last 8 rows; for
  each of the three `PROBES` the top chunks of `search(…, scope=[session], sources=("turn","summary"))`), budget
  `BRIEF_EXCERPT_TOKENS = 18_000` split evenly. Request: `brief_params()` = `ask_params("sonnet")` with `max_tokens = BRIEF_MAX_TOKENS
  = 1_500`; system = spec 2.4 verbatim; user = optional `UPCOMING: <title> · <d Mon yyyy HH:mm> · with <names>` then `PAST MEETINGS
  (newest first)` + the excerpts. Through `ask.make_client()`; streamed and collected.
- `parse_brief`: headings matched case-insensitively; lines `- …`; citations by `CITE_RE`, validated with `resolve_citations` against
  the request's sessions; a line without a valid citation is dropped and counted unless it is `(none)` / `(nothing clear yet)`; at most 5
  points per section kept. Writes `out` (spec 3.5 JSON) and, with `session_out`, `brief.json` + `brief.md` there.
- `render_brief_md`: the spec 3.5 layout, citations removed, sections with no points left out, cut at whole lines to
  `BRIEF_PACK_CHARS = 2_400`.
- `load_session`: `brief.md` read when present (UTF-8 errors → empty), capped again at 2,400 characters; `pack_for_model` = pack when
  brief is empty, else `pack.rstrip() + "\n\n" + brief`.

Interfaces:
- Consumes (P1): `MemoryIndex.open`, `.sessions`, `.session_by_key`, `.chunks_of`, `.first_last_rows`, `search`, `render_excerpts`,
  `CITE_RE`, `resolve_citations`, `QueryEmbedder`.
- Produces (P5 relies on the wire format): spec 3.4 and 3.5 messages and files exactly; `status` context `{"tokens", "mode": "memory",
  "sessions", "history"}`.

Test cases:
- memory ask, scripted `FakeAskClient`: the system prompt equals the spec text (golden); the cached block is the catalog and is
  byte-identical across two questions; each question's tail holds EXCERPTS then QUESTION; entity scope never includes another session's
  text.
- citations: an answer with `[sk… 12:34]` (valid), `[sk… 99:99]`, `[szzzzzz summary]` (well-formed, unknown key) → `ask_done.citations` holds one
  object with `speaker` and `text`; the chat `a` line holds the same object.
- history: after `drop` of a cited session (P1 API on a copy of the index), the next request omits that pair; pairs before `reset` are
  never sent; capped at 6.
- `ask_delta` → `ask_done` ordering, cancel → `stop_reason:"cancelled"` with estimated cost, error kinds: inherited behaviour holds in
  the memory mode (one test each).
- privacy: no request payload contains `@`; captured stderr contains no fixture sentence; a grep test asserts `memory_ask.py` and
  `brief.py` call no credential source other than `make_client` (the `test_runtime_ask.py` pattern).
- brief: a scripted reply with five sections, one uncited line and one line with an out-of-scope key → JSON has the cited points,
  `dropped_uncited == 2`; `(none)` stays as an empty section; sixth point in a section dropped; `out`, `brief.json`, `brief.md` written;
  no sessions → `brief_error no_sessions`; the request uses `claude-sonnet-5-5` with `max_tokens` 1500; the UPCOMING line lists names
  and no email.
- brief.md: ≤ 2,400 characters, ends at a line boundary, contains no `[s` citation.
- live pack: a session folder with `brief.md` → the layout's pack block ends with the PAST MEETINGS block; without `brief.md` every
  request is byte-identical to today (`test_runtime_layout.py` unchanged and green).

Acceptance: `cd brain && $VERSE_PY -m pytest -q tests/test_runtime_memory_ask.py tests/test_memory_brief.py tests/test_runtime_brief_pack.py tests/test_runtime_layout.py tests/test_runtime_ask.py tests/test_runtime_ipc.py tests/test_memory_search.py`
→ all pass. Then live, once, with the Keychain key (under $0.20): index the fixture tree with P1's runtime, ask one Sonnet question in
`all` scope and make one brief for Marta Velin; the report quotes the `ask_done` and `brief_done` lines (cost, citations, dropped count).
Done means: the commands pass and the live check returns at least one valid citation in the answer and at least one cited point in three
of the five brief sections.
Stop and ask if: the layout golden changes without a `brief.md`; a P1 interface is missing or behaves differently from the plan (report,
do not patch P1's files beyond a one-line fix); the live brief drops more than half of its points as uncited.

---

### Package P4: App people model and People page

Agent: worker-hard
Owns:
- new `app/Sources/VerseUI/EntityStore.swift` (`MemoryEntity`, `PeopleFile`, `EntityStore`, `EntityError`)
- new `app/Sources/VerseUI/EntityResolver.swift` (pure: sessions of an entity, reconcile, primary entity, suggestions, freemail list)
- new `app/Sources/VerseUI/PeoplePage.swift` (container and list column), `app/Sources/VerseUI/EntityPageView.swift` (the entity page,
  rename field, merge popover, Maybe also, Same person as), `app/Sources/VerseUI/BriefView.swift` (the brief rendering of spec 5.1, reused
  by P5)
- `app/Sources/VerseUI/HomeRouter.swift` (`HomePage.people`, `selectedEntity`, `AskScope`, `SessionReveal`, `askRequest`, `showAsk`,
  `showSession`, `showEntity`)
- `app/Sources/VerseUI/HomeWindow.swift` (the People page case; `HomeContext.people`; `memory.labels` wired to the store; `afterPrepare`
  records attendees; `requestSync(.labelsChanged)` after entity changes)
- `app/Sources/VerseMeet/MeetingEvent.swift`, `app/Sources/VerseMeet/CalendarSource.swift` (optional `currentUser`)
- `app/Sources/VerseUI/MeetingCoordinator.swift` (only an `onPreparedFromEvent: (@MainActor (MeetingEvent, String) -> Void)?` property,
  called next to `eventMap.remember` in the Start-from-invite path; wired in `HomeContext` through `controller.meeting` to record attendees)
- `app/Sources/VerseUI/HomeRender.swift` (people fixtures and the `people` render; edit last)
- `app/Sources/VerseUI/Resources/Localizable.xcstrings`, `docs/l10n-glossary.md` (spec 5.7 terms)
- new tests `app/Tests/VerseUITests/EntityStoreTests.swift`, `EntityResolverTests.swift`, `PeoplePageTests.swift`,
  `app/Tests/VerseMeetTests/MeetingEventCurrentUserTests.swift`; update `HomeWindowTests.swift` and `L10nSweepTests.swift` page-title lists
Do not touch: `brain/`; `MemoryService.swift`, `BriefStore.swift`, `Sessions.swift`, `SessionTrash.swift`, `HomeModels.swift` (P2);
`AskSession.swift`, `AskPanel.swift`, `AskAnswerText.swift`, `ChatLog.swift`, `HomeSessionsPage.swift`, `HomeSessionsList.swift`,
`HomeSessionDetailView.swift`, `ConversationSetupView.swift` (P5).
Read first: spec 2.4 (Primary entity, Freshness), 2.5, 3.6, 5.1, 5.5–5.7, 6; `SessionFolders.swift` (store, codec, unreadable rule,
`FolderSuggester.haystack`), `HomeSessionsList.swift` (row and section metrics to match), `HomeSessionDetailView.swift` (header, plates,
follow-up rows), `AskAnswerText.swift` (citation rendering to reuse), `AskPanel.swift` (`AskMotion`), P2's `MemoryService`/`BriefStore`,
`HomeRouter.swift`, `HomeWindow.swift`, `HomeRender.swift`, `docs/l10n-glossary.md`.

Decisions:
- Store rules are spec 2.5 and 3.6 exactly: main actor, atomic writes, ids `e-` + 8 base-36, names 1–80 characters unique per kind after
  `TextFold.fold`, unreadable file renamed with a one-time note, `merged` redirects resolved everywhere (`EntityStore.resolve(id:)`).
- Undo: rename, kind change, merge, hide and link edits register a snapshot restore of the whole `PeopleFile` on the window's
  `UndoManager`; merge also shows the Sessions-style toast "Merged into <name>" with Undo.
- Resolver is pure and synchronous; inputs: `PeopleFile`, `FoldersFile`, the session list (`[HomeSession]`), `HomeChecklistStore` done
  sets for follow-ups, and upcoming `[HomeUpNextItem]`. It never writes.
- Kinds of sessions shown on a page: meetings and calls in the timeline; prepared sessions only under "Upcoming" when an Up next item
  points at them.
- `MeetingEvent.currentUser: Attendee?` decodes as nil when absent (old JSON) and is filled in `CalendarSource.events` from
  `CalendarEntry.currentUser`; `jsonData()` keeps working for the brain (extra key ignored by `prep/event.py`, which reads with `.get`).
- Brief UI: `BriefView(brief: BriefFile, availableSessions: Set<String>, onCitation: (BriefFile.Cite) -> Void)` renders spec 5.1's ready
  state with `AskAnswerText` marks and Sources rows; points whose cites are all unavailable are hidden. The entity page owns the none /
  making / stale / failed states and calls `MemoryService.makeBrief`.
- Attendees are recorded from `afterPrepare` (Up next, Practice's Upcoming) and from `onPreparedFromEvent` (the meeting prompt's
  Start from invite; no automatic brief there, the call is starting). Backfill runs once per launch, after the store loads and calendar
  access is already granted (never requested here): for each `EventSessionMap` entry whose session has no `attendees` entry,
  `CalendarSource.event(id:)`; misses are ignored.
- "Ask about <name>" calls `router.showAsk(.entity(id))`; P5 makes the Sessions page honour it (until then it only switches pages).
- Meetings timeline click → `router.showSession(name, reveal: .none)`; brief citation click → `router.showSession(name, reveal:
  .stamp(s))` or `.summary`.
- Renders: `--render-home DIR people` writes `home-people-{brief,stale,nobrief,empty}-{light,dark}.png` from fixture data (fictional).

Interfaces:
- Consumes (P2): `MemoryService.makeBrief`, `.cancelBrief`, `.briefsInFlight`, `.labels`, `.requestSync(.labelsChanged)`, `MemoryPaths`,
  `BriefRequest`, `BriefFile`, `BriefStore`, `HomeUpNextModel(afterPrepare:)`.
- Produces (P5 relies on these):
```swift
public enum AskScope: Hashable, Sendable { case session(String), entity(String), all }
public enum SessionReveal: Equatable, Sendable { case none, summary, stamp(String) }
public struct SessionRevealRequest: Equatable, Sendable { public var session: String; public var reveal: SessionReveal; public var serial: Int }
extension HomeRouter {  // @Published stored properties live in the class
  // @Published public var selectedEntity: String?
  // @Published public var askRequest: AskScope?            (the Sessions page consumes and clears it)
  // @Published public private(set) var revealRequest: SessionRevealRequest?
  func showAsk(_ scope: AskScope)                            // page = .sessions, askRequest = scope
  func showSession(_ name: String, reveal: SessionReveal)    // page = .sessions, selectedSession = name, revealRequest serial += 1
  func showEntity(_ id: String) }                            // page = .people, selectedEntity = id
struct MemoryEntity: Codable, Equatable, Identifiable, Sendable { enum Kind: String, Codable, Sendable { case person, company }
  var id: String; var kind: Kind; var name: String; var emails, domains, aliases, folders: [String]; var company: String?
  var namedBy: String; var hidden: Bool; var createdAt: Date }
@MainActor final class EntityStore: ObservableObject {
  @Published private(set) var file: PeopleFile
  init(paths: MemoryPaths)
  func resolve(id: String) -> MemoryEntity?                       // follows `merged`
  func entities(of session: String, folders: FoldersFile) -> [MemoryEntity]   // person(s) first, then company
  func recordAttendees(_ attendees: [Attendee], owner: Attendee?, session: String)
  func rename(_ id: String, to name: String) throws(EntityError)
  func setKind(_ id: String, _ kind: MemoryEntity.Kind) throws(EntityError)
  func merge(_ loser: String, into survivor: String) throws(EntityError)
  func setHidden(_ id: String, _ hidden: Bool)
  func link(_ session: String, to id: String); func unlink(_ session: String, from id: String)
  func dismiss(_ session: String, for id: String)
  func snapshot() -> PeopleFile; func restore(_ snapshot: PeopleFile) }
enum EntityResolver {
  static let freemail: Set<String>
  static func reconcile(_ file: PeopleFile, folders: FoldersFile, sessions: [HomeSession]) -> PeopleFile
  static func sessions(of id: String, file: PeopleFile, folders: FoldersFile, sessions: [HomeSession]) -> [HomeSession]  // newest first, company includes its people
  static func primaryEntity(for event: MeetingEvent, file: PeopleFile, folders: FoldersFile, sessions: [HomeSession]) -> MemoryEntity?
  static func pastSessions(of id: String, excluding: String?, file: PeopleFile, folders: FoldersFile, sessions: [HomeSession]) -> [HomeSession]  // with transcript or summary
  static func suggestions(for id: String, file: PeopleFile, folders: FoldersFile, sessions: [HomeSession]) -> [String]
  static func mergeSuggestion(for id: String, file: PeopleFile) -> MemoryEntity? }
struct BriefView: View { init(brief: BriefFile, ownerName: String, availableSessions: Set<String>, onCitation: @escaping (BriefFile.Cite) -> Void) }
```
  (`BriefFile.Cite` is P2's type.)

Test cases:
- codec: round trip of the spec 3.6 example; unknown keys ignored; garbage file renamed `people.json.unreadable-*` with the note.
- names: empty, 81 characters and a folded duplicate of the same kind are refused; the same name as a company and a person is allowed.
- reconcile: a folder "Halden Works" → a company entity listing that folder; a folder "Marta Velin" whose session has attendee "Marta
  Velin" → a person; attendee `marta@halden.example` → a person with company "Halden" created from the domain (or the existing company
  whose folded name is "halden"); `x@gmail.com` → a person without a company; owner and `resource.calendar.google.com` addresses → no
  entity; running reconcile twice changes nothing.
- sessions of: folder membership, email, domain, manual link and unlink each decide as spec 2.5; moving a session to another folder
  moves it between entities; a company lists its people's sessions.
- primary entity: two attendees at one company → the company; one person → that person; two people at two companies → the one with
  more past sessions.
- merge: emails, aliases (with the loser's name), folders unioned; links rewritten; `merged` redirect resolves; snapshot restore brings
  back the exact file; cross-kind merge throws.
- folder rename: renames an `auto`-named entity, not a `user`-named one.
- suggestions: a session titled "Halden pricing call" not otherwise linked is suggested for "Halden Works"; after dismiss it is not.
- merge suggestion: "Marta" and "Marta Velin" (both persons) → suggested; "Marta Velin" and "Marta Rossi" → not.
- currentUser: `MeetingEvent` JSON without `currentUser` decodes; with it round-trips.
- attendees: `recordAttendees` drops the owner (by `currentUser` and by `owner_emails`) and resource addresses, and adds a new owner email
  to `owner_emails`; the backfill with a fake calendar records one mapped session and ignores a missing event.
- People page model: list order (upcoming first, then last met), search by alias and email, hidden section; entity page states by
  fixture: brief ready, stale, none, making, failed, no past meetings (no plate).
- HomeWindowTests / L10nSweepTests: page titles now include People / Persone / Kişiler after Sessions.
- Renders (Read each PNG, judge against spec 5.1 and the leave-out list): `home-people-brief-dark`, `-light`, `home-people-stale-dark`,
  `home-people-nobrief-dark`, `home-people-empty-dark`.

Acceptance: `cd app && swift test --filter 'VerseUITests.EntityStoreTests|VerseUITests.EntityResolverTests|VerseUITests.PeoplePageTests|VerseUITests.HomeWindowTests|VerseUITests.L10nSweepTests|VerseMeetTests.MeetingEventCurrentUserTests|VerseMeetTests.CalendarSourceTests' && swift build -c release && ./scripts/l10n-sync.sh && python3 scripts/l10n-check.py`
→ all pass; then `swift build && .build/debug/Verse --render-home <scratch> people`, and Read the five PNGs.
Done means: the commands pass, the renders match spec 5.1 in dark and light, and the report lists any place the render departs from the spec.
Stop and ask if: P2's `BriefFile` lacks a field the brief UI needs; a VerseMeet change breaks `CalendarPrepTests`; the People page needs
a token `HomeTheme` lacks (do not add colours).

---

### Package P5: App Ask in memory scopes and brief placements

Agent: worker-hard
Owns:
- `app/Sources/VerseUI/AskSession.swift` (an `AskTarget` for session and memory scopes; `MemoryAskContext`; spend dir per target)
- `app/Sources/VerseUI/ChatLog.swift` (object citations → `ChatAnswer.sources`; `ChatLog.load(url:)`)
- `app/Sources/VerseUI/AskAnswerText.swift` (memory citation marks: ordinals, Sources tokens, unavailable sources)
- `app/Sources/VerseUI/AskPanel.swift` (title per scope, Scope section in the ⋯ menu, starters, footnote, "Updating memory" caption,
  empty index state)
- `app/Sources/VerseUI/HomeSessionsPage.swift` (entry from `router.askRequest`, ⌘⇧A last scope, panel stays open across selection in
  memory scopes, `revealRequest` handling, citation → `router.showSession`)
- `app/Sources/VerseUI/HomeSessionsList.swift` (only the title-row "Ask all meetings" icon button)
- `app/Sources/VerseUI/HomeSessionDetailView.swift` ("Before this meeting", the past-brief disclosure, the People row and its
  Add person popover)
- `app/Sources/VerseUI/ConversationSetupView.swift` (Up next caption line, Brief button, popover, making state)
- `app/Sources/VerseUI/HomeWindow.swift` (`afterPrepare`: after P4's attendee recording, the automatic brief per spec 2.4)
- `app/Sources/VerseUI/HomeRender.swift` (memory Ask and brief placement renders; edit last)
- `app/Sources/VerseUI/Resources/Localizable.xcstrings`
- new tests `app/Tests/VerseUITests/AskMemoryScopeTests.swift`, `BriefPlacementTests.swift`, `MemoryEndToEndTests.swift`; extend
  `AskPanelTests.swift` (parser cases)
Do not touch: `brain/`; P2's files (`MemoryService.swift`, `BriefStore.swift`, `Sessions.swift`, `SessionTrash.swift`, `HomeModels.swift`);
P4's files (`EntityStore.swift`, `EntityResolver.swift`, `PeoplePage.swift`, `EntityPageView.swift`, `BriefView.swift`, `HomeRouter.swift`,
`MeetingCoordinator.swift`, VerseMeet).
Read first: spec 2.3, 2.4 (Trigger, Primary entity, Where it shows), 3.4, 3.7, 5.2–5.6; AM entirely; `AskSession.swift`, `ChatLog.swift`,
`AskPanel.swift`, `AskAnswerText.swift`, `HomeSessionsPage.swift`, `HomeSessionDetailView.swift`, `ConversationSetupView.swift`
(`HomeUpNextGroup`); P2's `MemoryService`; P4's `HomeRouter` additions, `EntityStore`, `EntityResolver`, `BriefView`.

Decisions:
- `.session` scope behaves exactly as today (process, `chat.jsonl`, string citations, spend in the session folder, closing on another
  selection). Memory scopes: process first line `memory_ask_start` (spec 3.4), chat at `MemoryPaths.chat(named: "all")` or
  `chat(named: <entity id>)`, spend in `MemoryPaths.spendDir` (`kind: "ask"`), scope sessions from `EntityResolver.sessions(of:)`.
- Opening a memory scope calls `memory.syncNow(timeout: .seconds(5))` first; the panel shows while it waits, with the "Updating memory ·
  done of total" caption from `MemoryService.phase` while `phase` is `.indexing`.
- Scope change: close the process, load that scope's history, start the new process; remember the scope in `askMemoryScope` when it is a
  memory scope.
- Citation parsing in memory scopes uses P1's regex (spec 2.2) on the Swift side; marks are ordinals per answer; tokens per spec 5.2; a
  source whose session is not in `HomeSessionsModel.sessions` is dimmed with help "In the Trash" and not clickable.
- Reveal: `router.showSession(name, reveal:)`; the page selects the session, loads its `TranscriptDocument`, then
  `TranscriptJump.reveal(stamp:in:)`; `.summary` sets the Summary tab; a stamp not found shows the note "That line is no longer in this
  transcript." (detail `message`).
- Automatic brief (`afterPrepare`): primary entity via `EntityResolver.primaryEntity(for:)`; past sessions via `pastSessions(of:excluding:)`;
  when non-empty, `MemoryService.makeBrief` with `sessionOut` = the new session folder, `upcoming` from the event (names only), `lang`
  = the new session's `meta.json languages[0]`; a failure is shown on that prepared session's detail with Retry.
- Up next and session detail use P4's `BriefView` for every brief rendering.

Interfaces:
- Consumes: P2 (`MemoryService`, `MemoryPaths`, `BriefRequest`, `BriefFile`, `BriefStore`), P3 wire formats (spec 3.4, 3.5), P4
  (`AskScope`, `SessionReveal`, `SessionRevealRequest`, `HomeRouter.showAsk/showSession/showEntity/askRequest/revealRequest`,
  `EntityStore`, `EntityResolver`, `BriefView`).
- Produces: `struct AskSource: Equatable, Sendable { var key, session, title: String; var date: Date?; var kind: String; var stamp,
  speaker, text: String? }`; `ChatAnswer.sources: [AskSource]` (empty for session scope); `MemoryAskContext.startLine(model:) -> String`.

Test cases:
- start line golden for `all` and `entity` scopes (spec 3.4 keys, sorted, `me` null when the profile toggle is off, entity sessions
  from the resolver).
- `AskEvent.parse` of an `ask_done` with object citations → `sources` filled, `citations` empty; with string citations → as today.
- `ChatLog` reads a memory chat with object citations and a reset; history before the reset hidden.
- scripted fake transport: memory scope streams deltas into the turn; `ask_done` adds cost to `memory/spend.json` with `kind: "ask"`,
  not to a session folder.
- selection: in a memory scope, changing `router.selectedSession` keeps the panel open; in session scope it closes it (regression).
- reveal: a source tap calls `showSession` with `.stamp("12:34")`; the page's jump target receives the row id of the fixture row; a
  stamp that does not exist sets the detail note.
- trashed source: a source whose session is absent renders dimmed and its tap does nothing.
- scope menu: lists This meeting (when available), the selected session's entities, All meetings; choosing one restarts the process
  with the new first line.
- automatic brief: `afterPrepare` with an event whose attendee resolves to an entity with one past session → one `makeBrief` with
  `sessionOut` set and no email in `upcoming`; an entity with no past sessions → no call.
- placements: a prepared session with `brief.json` shows "Before this meeting"; a stale one shows Update; a past session with
  `brief.json` shows the collapsed disclosure; an Up next item with past meetings shows the caption line and a Brief button.
- end to end (`MemoryEndToEndTests`, skipped when the brain dir or its venv is missing): `MemoryService` with the real
  `python -m verse_brain.runtime --fake` indexes a temp fixture tree; a memory-scope `AskSession` gets an answer whose `sources` resolve
  to a fixture session; Move to Trash of that session plus a sync → the same question returns no source from it; Undo plus a sync → it
  does again, with the same key.
- Renders (Read each, judge against spec 5.2–5.4 and AM): `home-sessions-ask-memory-all-{dark,light}`, `home-sessions-ask-memory-entity-dark`
  (Sources row and a hover card), `home-sessions-prepared-brief-dark`, `home-prepare-upnext-brief-dark` (popover open).

Acceptance: `cd app && swift test --filter 'VerseUITests.AskMemoryScopeTests|VerseUITests.BriefPlacementTests|VerseUITests.MemoryEndToEndTests|VerseUITests.AskSessionTests|VerseUITests.AskPanelTests|VerseUITests.TranscriptViewTests|VerseUITests.HomeWindowTests' && swift build -c release && ./scripts/l10n-sync.sh && python3 scripts/l10n-check.py`
→ all pass (the end-to-end test runs, not skipped, in the main checkout's merged tree); then `swift build && .build/debug/Verse
--render-home <scratch> sessions prepare` with the memory fixtures, and Read the five PNGs. Then, in the bundled app on the owner's real
sessions, one "Ask all meetings" question in Sonnet whose source opens the right transcript row; the report quotes the shown cost and the
`memory/spend.json` record.
Done means: the commands pass, renders match spec 5.2–5.4, and the live question's citation lands on the right row.
Stop and ask if: P4's router API or `BriefView` differs from the plan; keeping the panel open across selection needs a change to
`HomeSessionDetailView`'s Ask contract beyond what this package owns; the live answer cites no source.

---

## Coverage check (spec section → package)

| Spec | Package |
|---|---|
| 2.1 index location, writer, incremental, triggers, phases, deletes, corruption; embeddings | P1 (brain side), P2 (manifest, triggers, trash hook) |
| 2.2 chunks, FTS, vectors, fusion, packing, keys, citation forms, validation | P1; jump behaviour P5 |
| 2.3 scopes, process, grounding, history, models, chat files, spend, empty and stale states | P3 (brain), P5 (app); spend total P2 |
| 2.4 brief content, inputs, process, language, trigger, primary entity, freshness, storage, placements, live pack, spend | P3 (brain, live pack), P2 (runner, spend, store), P4 (entity page, primary entity), P5 (automatic brief, placements) |
| 2.5 entities, linking, attendees, backfill, reconcile, suggestions, rename, kind, merge, hide, labels | P4 (backfill included: one pass over `EventSessionMap` with `CalendarSource.event(id:)`, best effort) |
| 3.x files and protocols | P1 (3.2, 3.3), P3 (3.4, 3.5, 3.7), P2 (3.5 runner, spend), P4 (3.6), P5 (3.4 client, 3.8 `askMemoryScope`) |
| 5.1 People page | P4 |
| 5.2 Ask panel memory scopes | P5 |
| 5.3 session detail | P5 |
| 5.4 Up next | P5 |
| 5.5–5.7 motion, accessibility, strings | P4 and P5, each for its views |
| 6 privacy | every package's privacy tests (P1 logs, P3 payloads and grep, P5 end to end) |
| 7 edge cases | P1 (index), P3 (answers, brief), P4 (entities), P5 (UI states) |

`peopleCollapsedHidden` (spec 3.8) belongs to P4.
