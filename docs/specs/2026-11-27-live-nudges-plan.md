# Live nudges: topic-triggered suggestions from the prep note

Status: final plan for v1, 27 Nov 2026. Merged from three independent advisor plans (Claude Fable, GPT Astra,
Claude Opus) and a read-only code map. Where they disagreed, the choice and its reason are stated.

## As built (differences from the plan below)

- Judge model: Sonnet by default (`VERSE_NUDGE_MODEL=sonnet|haiku`), `max_tokens` 100, output
  `NUDGE: <id> | "<quote>" | <them|me>`; the quote may be up to 30 words.
- The periodic sweep is off by default (`VERSE_NUDGE_SWEEP=N` turns it on). A result is dropped when older than
  8 seconds, not 3.
- Island: with a card open the nudge is the card's first point in amber, full text, no box or label. There is no
  lifetime: `ttl_s` is ignored. A nudge leaves on a newer nudge, `nudge_clear`, a tap, collapse/stop/reset, or a
  card for a later turn.
- Nudges do not run on the `room` route. A run whose room route was picked automatically moves to the meeting
  route once when a meeting app takes the microphone after Start (`QuickStart.MeetingRouteUpgrade`).
- Rehearsal: `app/scripts/rehearse.sh` and the menu's "Rehearse a line…" feed typed lines into a real session on
  a temporary copy. Post-call check: `python -m verse_brain.runtime.report SESSION_DIR`.

## What it does

Today Verse answers questions the other side asks. With nudges it also follows the conversation and, when the
moment a prepared suggestion was written for arrives, shows that suggestion in the island, even if nobody asked
anything. Example: the note says "when pay comes up, before any number is named, tell the story of X, like this:
...". When either speaker turns to pay, the island shows those lines.

Rules that outrank everything else:

1. Answers never get worse. A nudge never hides, delays or replaces an answer card, and a failure anywhere in
   the nudge path leaves the answer path exactly as it is today.
2. A wrong nudge is worse than a missed one. When in doubt, show nothing.
3. Nudge text is shown verbatim as written in the note. Nothing is generated live.
4. A session without a `nudges.jsonl` behaves exactly as today. `VERSE_NUDGES=0` turns the feature off.

## Naming

`cue` is already taken (the question cue on partials and turns: `cue`, `cue_why`, `cue_strong`, `st.cue`).
Code, file and wire use **nudge**: `nudges.jsonl`, events `nudge` / `nudge_clear`, model tier `K`.
In the note both `### Nudge:` and `### Cue:` headers are accepted.

## Authoring format

```markdown
### Nudge: Pay story
When: pay, salary or the commercial terms are being discussed now
Keys: salary, pay, commercials, compensation, package, budget
Who: any
Until: number
After: 0m
Say: First line to say or do.
  Second line.
  Third line.
```

- `When` (required): the condition in plain language, read by the judge model.
- `Keys` (required): comma-separated words or short phrases. Case-insensitive, matched on word prefixes
  ("compensat" matches "compensation"). They only nominate a nudge; they never fire it.
- `Say` (required): one to three lines, at most 45 words in total. Continuation lines are indented.
- `Who` (optional, default `any`): whose words may trigger it: `any`, `me`, `them`.
- `Until: number` (optional): retire the nudge once an amount of money has been said by anyone.
- `After: Nm` (optional, default 0): not before N minutes of audio.
- A block ends at the next line starting with `#` or at a `---` rule. At most 8 nudges. English only in v1.

Compiled record (`nudges.jsonl`, one per line, sorted by id):

```json
{"id":"n001","title":"Pay story","when":"...","keys":["salary","pay"],"who":"any","until":"number","after_s":0,"say":["...","..."],"ref":"prep:L120"}
```

A block without `When`, `Keys` or `Say`, over 45 words, or beyond the eighth is dropped with a warning in
`meta.warnings` and `review.md`; the others still compile. Nudge lines are blanked in the text the prep model
sees (line numbering kept), so no bank entry duplicates them; they stay in the `SourceBook`. Nudges are not
written into `pack.md`, so the cached prompt prefix is the same bytes with and without them.

Nudges-only compile, to add nudges to an existing session without rebuilding its answers:

```
python -m verse_brain.prep.nudges NOTE.md SESSION_DIR
```

## Detection

Evaluated on **final turns of both speakers** (`me`, `remote`). Partials are not used in v1 (Opus; Fable and
Astra wanted partials for lower latency, left for later: fewer races, no extra load while a question is open).
The `room` route (one microphone) is excluded.

**Window.** The last two turns, or the last 25 seconds of audio if longer, capped at 60 words, speaker-labelled.

**Stage A, local gate, no model call.** A still-armed nudge becomes a candidate when one of its `Keys` occurs
in the newest turn and its `Who`, `After` and `Until` gates pass. In addition a sweep nominates all armed
nudges every 6 final turns without an evaluation. No embedding in v1 (thresholds are uncalibrated and the
embedding thread belongs to bank matching).

**Until: number.** A deterministic money regex (digits with a currency word or symbol, "k", "thousand",
"francs", "euros", "dollars", and number words followed by "thousand") runs over every final turn from session
start. A hit retires the nudge; if it is on screen the brain sends `nudge_clear`.

**Stage B, Haiku confirm (tier K).** Same request tuple as the fast tier, so system prompt, pack and transcript
prefix are byte-identical and cached; only the uncached tail is new. `max_tokens` 40. At most 3 candidates with
their `When`. One call in flight; while one is in flight a new evaluation is skipped, not queued. The tail says:
only the last two turns count; fire only if the topic is being discussed now, not a passing mention ("we'll
get to pay later") and not a past event. Output, exactly one line:

```
NUDGE: n003 | "<at most 12 words copied from the last two turns>"
NUDGE: none
```

**A nudge fires only if all hold:** the id is a candidate and armed; the quote is a normalised substring of the
window (live grounding, from Opus: this is the main guard against firing on something said minutes ago); the
gates still pass; no nudge fired in the last 60 seconds; the result is younger than 3 seconds.

**Lifecycle.** Each nudge fires once per call. No re-arm in v1.

**Guards.**
- Skip K when the Haiku rate bucket has less than half left.
- K runs on lane 1, never hedged, and its errors are silent (no status on the island).
- The hook is wrapped: any exception turns nudges off for the session and logs one metric.

**Rejected.**
- Embedding threshold alone (all three): a trigger is a state of the conversation, not a paraphrase.
- A model call on every turn or partial: competes with the answer tiers for the same bucket.
- Putting nudges into the answer prompts: changes the answers.

## Wire

Brain to app:

```json
{"type":"nudge","id":"n001","title":"Pay story","lines":["...","..."],"turn_id":41,"ttl_s":25}
{"type":"nudge_clear","id":"n001"}
```

No change to `start`. The app already ignores unknown event types.

## Island behaviour

`state.nudge` is separate from `state.card`; it never enters answer history, regenerate, marks or the prompter.

- **No card open:** the nudge is the island body: amber accent, small "CUE" label, title, lines.
- **Card open:** an amber strip of at most two lines at the top of the card (title in the label, then the
  lines, truncated if needed). The answer stays fully usable; the card's deep points give way first.
- A new answer card keeps the nudge (the pay question is exactly when the pay nudge matters).
- Lifetime 25 seconds (`ttl_s`). Tapping the strip or the nudge body dismisses only the nudge. `nudge_clear`,
  collapse, stop and reset clear it.
- While the prompter, simulation or a status panel is showing, the nudge is dropped.

Fable proposed letting the nudge take over the body when the card is stale; Astra proposed dropping nudges
while a card is present. The strip (Opus) wins: cards never expire, so "drop" would hide nearly every nudge,
and a takeover hides an answer.

## Code changes

Brain (Python), package A:
- `prep/nudges.py` (new): `parse_nudges(lines)`, lint, writer, `__main__` for the nudges-only compile.
- `prep/pipeline.py`: parse, blank nudge lines for the model input, write `nudges.jsonl`, stats count,
  warnings into `review.md`.
- `runtime/nudges.py` (new): `NudgeTracker` (window, gates, money regex, candidate choice, output parse,
  quote check, cooldown), tolerant `load(path)`. Pure state.
- `runtime/prompt.py`: `nudge_tail` beside `follow_tail`.
- `runtime/engine.py`: tolerant load on start (a malformed file means no nudges, never `BAD_SESSION`); hook
  after `self._on_turn(msg)` in `on_turn` so it sees `me` turns and cannot abort answer handling; tier `K`
  (route, max tokens, lane 1, lines collected without deltas, silent error branch, dispatch on call done,
  bucket gate); `_ev` lines `nudge_gate`, `nudge_judge`, `nudge_fire`, `nudge_retire`.
- `runtime/protocol.py`: document the events.
- `eval/run_nudges.py` (new): arm A (fake transport, a recorded transcript fed twice, nudges on and off,
  non-nudge event streams must be identical) and arm B (real Haiku, tracker over a recorded transcript with
  `t_audio_end` pacing compressed by `--speed`, prints per nudge the fire turn, quote, latency and K calls).

App (Swift), package B:
- `VerseUI/OverlayState.swift`: `OverlayNudge`, reducer cases `nudge` / `nudge_clear`, deadline in `tick`,
  clearing rules.
- `VerseUI/IslandViews.swift`, `OverlayView.swift`: `IslandKind.nudge`, `NudgeBodyView`, the strip in
  `CardView`, tap handling.
- Localization entry for the label.

## Tests

No golden model outputs: fakes, structure, replay statistics.

Brain: parser (fields, continuation, block end, drops, stable ids, nudges-only CLI writes one file); blanking
keeps numbering and `pack.md` is identical with and without nudge blocks; tolerant loader; tracker (once only,
cooldown, `Who`, `After`, `Until` retire and clear, quote not in window is rejected, garbage line is none,
stale result dropped); engine (an exception in the hook leaves S/F/D launches unchanged; a K error emits no
`status`; no K under a low bucket; no file means no K calls; a K request's cached prefix equals an F request's
at the same transcript).

Swift: reducer (set, expire, `nudge_clear`, a new card keeps it, ended clears, dropped under prompter) and
island tables (resolve order, kind name, width).

Install gate (replay, run by the maintainer on recorded calls):
- arm A: zero differences in non-nudge events;
- arm B, three runs: zero fires outside the hand-marked turn ranges on the labelled call; at most one fire in
  total across the other recorded calls used as distractors; at least two thirds of labelled moments caught in
  the marked turn or the next; median turn end to `nudge` 2 seconds or less; at most one K call per 2 minutes
  of audio on average.

## Known risks for a first live call

- The recogniser mishears a key word; list synonyms. The sweep catches it late.
- A nudge and the answer card for the same moment disagree; the author keeps them consistent in v1.
- The owner starts the story himself before the nudge shows.
- Long monologues: the nudge comes only when the turn ends.
- Recorded calls are few; thresholds are judged on thin evidence.

## Voice

A nudge is the owner's next sentence, not an instruction to him. `Say` lines are written in the first person
as words he can say as they stand: friendly, short, clear, and ending in a concrete next step. In v1 the author
writes them that way by hand. Later the prep step drafts them from the session's voice profile (the STYLE GUIDE
already built for answers) and from positions the owner has stated (things he does and does not ask for), so
suggestions follow how he speaks and what he wants; the owner approves drafts before they compile.

Nudges are for moments where taking the initiative pays, such as money and contract terms. A question from the
other side gets its normal answer; a session should carry a handful of nudges, not one per topic.

## Later

Partial checkpoints, re-arm, prep-drafted keys, embedding gate, other languages, `room` audio, auto-clear when
the owner has said it, a prep warning when a nudge contradicts a bank answer, after-call marks (useful/wrong),
nudges in the summary, a settings toggle.
