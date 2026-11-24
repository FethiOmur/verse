# Follow my answer: how the divergence detector was tuned

Brain side of `docs/specs/2026-10-16-verse-follow-my-answer-design.md` (F1). Code: `brain/verse_brain/runtime/follow.py`
(the state machine), `follow_drive.py` (test and tuning drivers), `engine.py` (wiring). Every number below is a field of
`FollowParams` and can be re-measured with one command:

```
PYTHONPATH=brain brain/.venv/bin/python eval/tune_follow.py --out <scratch dir>        # about 8 minutes (part 5 alone about 50 s), needs the EmbeddingGemma model
```

## Fixtures

`brain/tests/fixtures/follow/cases.json`: 87 synthetic answers (spoken style, written by hand) against 8 cards taken from the
sample-interview pack (opener + points of b001, b004, b007, b008, b010, b013, b019, b020), plus the 104 lines of that pack
(bank openers and points, facts) as the margin reference.

| kind | n | meaning | expected |
|---|---|---|---|
| verbatim, verbatim_asr | 10 | the card read out, once with recognizer slips | stay |
| paraphrase | 32 | the same facts in other words (one point, or a loose summary) | stay |
| fillers | 4 | "so, um, yeah okay right, uh huh, mm hmm, well" | stay |
| off_pack | 16 | a topic of the pack that this card does not carry (accuracy, Compass, the 400-invoice set) | diverge |
| off_other | 17 | a topic that is not in the pack (running, cooking, an uncle's truck) | diverge |
| read_then_off | 8 | two card sentences, then a new topic | diverge |

Streaming model: words at 2.7 per second, delivered in 560 ms chunks (the recognizer's chunk size). Times below are measured from
the arrival of the first chunk that holds an off-card word. Small set, one author: treat the numbers as an operating point, not
as a guarantee. The same file drives the unit tests (with a concept-vector fake embedder) and an optional real-model check.

## What the lexical test alone would do (why there is no lexical fallback)

Count rule N unmatched content words in the last 8, or a run of unmatched words lasting T seconds (at least 3 words). Share of the
46 on-card answers it would flip (a sweep: the default T has since moved from 1.2 s to 4.0 s, see "Time and refresh limits"):

| N, T | would flip (of 46) | missed of 41 | detection median |
|---|---|---|---|
| 5, 1.2 s (the spec's numbers) | 26 | 0 | 2.8 s |
| 7, 2.0 s | 19 | 0 | 3.4 s |
| 9, 3.0 s | 15 | 1 | 3.9 s |
| 11, 4.0 s | 12 | 3 | 5.0 s |
| 13, 5.0 s | 12 | 4 | 6.2 s |

So the lexical test only raises suspicion; it cannot decide. Paraphrases routinely carry five or more words that match nothing
("typing", "went down", "spent", "invoice data"). A first version shipped an 11 words / 4 s fallback for when the embedder is
unavailable; review showed it flips legitimate paraphrases (12 of 46), the failure the owner named, so it is gone: **while the
embedder is not available (model missing, still loading, failed) nothing diverges and the card stays; coverage (striking points
through) keeps working**. A divergence check whose embedding does not come in `embed_wait_s` is asked again, never decided
without it. The brain says so once per change (`follow_embed_state` metric).

## What the embedding says

At each moment the lexical test is suspicious, the unmatched run (plus two words of context, at least six words) is embedded
(EmbeddingGemma, the bank matcher's model and "sentence similarity" prefix). Two numbers: the best cosine to a card line, and the
margin by which a line of the *rest of the pack* beats the card.

| | moments | card score p10 / median / p90 | margin p10 / median / p90 |
|---|---|---|---|
| stay: paraphrase | 140 | 0.818 / 0.856 / 0.896 | -0.020 / 0.010 / 0.029 |
| diverge: off_other | 168 | 0.775 / 0.801 / 0.834 | 0.000 / 0.027 / 0.058 |
| diverge: off_pack | 163 | 0.796 / 0.822 / 0.842 | 0.033 / 0.089 / 0.137 |
| diverge: read_then_off | 58 | 0.757 / 0.803 / 0.825 | 0.014 / 0.035 / 0.054 |

The card score alone does not separate: unrelated text already scores about 0.78 against anything, and a same-topic digression
(off_pack) scores 0.80 to 0.85, in the paraphrase range. A single threshold on it either flips paraphrases (floor 0.84:
15 of 46 false) or finds nothing (floor 0.78: 28 of 41 missed). The bank matcher's calibrated 0.865 is a question-to-question
score and is far too high for words-to-answer-line. The margin is what separates the same-topic digression: an off_pack answer is
closer to another line of the pack than to the card, a paraphrase never is.

Decision rule (first suspicious moment): diverged when card score < floor OR margin >= m.

| floor | margin | false (of 46) | missed (of 41) | detection median / p90 |
|---|---|---|---|---|
| 0.84 | any | 15 to 16 | 0 | 2.8 / 4.5 s |
| 0.82 | 0.04 | 5 | 1 | 3.4 / 5.0 s |
| **0.80** | **0.04** | **0** | **3** | **3.9 / 5.0 s** |
| 0.80 | 0.03 | 10 | 0 | 3.9 / 5.0 s |
| 0.80 | no margin | 0 | 11 | 5.0 / 6.7 s |
| 0.78 | 0.04 | 0 | 7 | 3.9 / 5.0 s |

Chosen: floor 0.80, margin 0.04. The margin is worth 8 detections at no false divergence. The floor is the edge: 0.82 buys one
detection for five false divergences.

## The full machine with these numbers

(`FollowParams()` defaults, the embedder in the loop, a window the embedding rescued is remembered as matched only when its
score is at least `sem_mark` 0.88; mark 0.82 missed 5 and flipped one paraphrase, 0.84 and 0.86 missed 3 and flipped one, 0.88 missed 3 and flipped none.)

* stay: 46 of 46 correct (verbatim 9/9, ASR 1/1, paraphrase 32/32, fillers 4/4).
* diverge: 39 of 41 (off_pack 15/16, off_other 16/17, read_then_off 8/8). The two misses are borderline by construction
  ("I tested both on a labelled sample first" under the card on small versus large models; "my manager liked simple things").
* detection: median 3.9 s, p90 5.0 s, max 7.8 s after the first chunk with an off-card word; in content words of the new topic:
  median 4, p90 7, max 9 (measured with the time rule at 1.2 s; the count rule decided most of these, so the 4.0 s default moves
  them little, but the figures were not re-measured). The spec's 5 content words / 1.2 s is reached by the lexical test on its own; the extra time is the
  evidence the embedding needs (a four-word stretch is ambiguous even to a person). `sem_floor_long` 0.83 for an unmatched run of
  9 or more words recovered one more miss without a false divergence.
* per card: 8/10 on b019, 9 or 10 of 10 on the rest.

Faster settings exist and are one parameter away: N=4, T=1.0 s with two-word runs, floor 0.80, margin 0.04 gave a 2.8 s median
with 3 false divergences and 2 misses in an earlier sweep (before `sem_mark`); N=3 gave the same 2.8 s with 2 to 4 false. The
default prefers zero false divergences, because a card that flips while the owner reads it is the failure he named.

## Time and refresh limits

| field | default | meaning |
|---|---|---|
| `diverge_s` | 4.0 | the time rule: the trailing run of unmatched content words (at least `time_min_words` = 3) spans this many seconds of his speech. Owner decision (2026-11-24): at least 4 s of his own speech before the card changes; the spec's first value was 1.2 s. |
| `count_min_s` | 4.0 | the count rule (`diverge_words` = 5 unmatched content words among his last `window` = 8) also needs those unmatched words to span this long: from the first unmatched word in the window to the newest content word in it. Owner rule: no card change in the first 4 s of his own speech, however fast he talks. |
| `max_refreshes_per_answer` | 2 | after the first follow card of an answer, at most this many further cards (3 in all). One replayed answer got 13 refreshes and one live answer 17 cards, so the card could never be read. |
| `min_card_show_s` | 8.0 | a follow card is not replaced before it has been on screen this long (from the moment its SAY line reached the machine, else from the launch of its call). The first follow card replaces the original card and only waits for the divergence rules. |

Both lexical rules now need 4 s: `diverge_s` for the time rule, `count_min_s` for the count rule, each measured between the arrival
times of words of his own speech, so the first card change cannot come before 4 s of his speech (the embedding check decides only
after a rule has raised suspicion, so it comes later still). The count rule's window holds 8 content words, so it can only see
speech slower than about 1.75 content words per second (its window must span 4 s); faster unmatched speech diverges through the
time rule, which watches the whole trailing run. Before `count_min_s` existed, five fast unmatched words could raise suspicion after
about 1.5 s. The refresh cap is a gate on top of the existing refresh rules (`refresh_gap_s`, `refresh_new_words`,
sentence ends only): it is checked last, so it only ever holds back a refresh that would otherwise have gone out. The counters start
again with every new remote question and when follow mode ends; a launch the engine refuses (rate bucket, halted) is not counted.

## Reading the log

The machine writes its decisions to the session's `events.jsonl` (the same writer and line shape as `card_mark`: `{"t": <unix s>,
"ev": <kind>, ...fields}`, `null` fields left out). Numbers, booleans and short enums only: no word of his or the other party's is
ever written. `turn` is the turn id of the question being answered.

`follow_diverged`: one line per divergence decision, written just before the follow call is launched.

| field | meaning |
|---|---|
| `rule` | the lexical rule that raised the suspicion: `lexical` (the count rule; also when both fired) or `time` (only the time rule) |
| `by_count`, `by_time` | whether each rule held |
| `decided_by` | always `embedding`: the lexical rules only raise suspicion |
| `embed_why` | what the embedding check said: `floor` (card score under `sem_floor`), `margin` (another pack line beat the card by `sem_margin`), `both` |
| `embed`, `margin` | best cosine of his words to a card line; best pack-line cosine minus that |
| `sem_floor`, `sem_margin` | the thresholds in force (the floor is `sem_floor_long` for a run of 9 or more words) |
| `unmatched`, `window`, `diverge_words` | unmatched content words among his last `window`, and the count threshold |
| `run_words`, `run_s`, `diverge_s`, `time_min_words` | words in the trailing unmatched run, the seconds it spans, and the time-rule thresholds |
| `count_span_s`, `count_min_s` | seconds the window's unmatched words span (first unmatched word to newest content word), and the count rule's minimum |
| `since_run_s`, `since_start_s` | seconds since the run's first word and since his first word of the answer |
| `words` | tokens of his answer so far |
| `reason` | the machine's label for the decision (`lexical+embed`) |

`follow_state`: one line per state change of follow mode; `reason` says why.

| `state` | `reason` | other fields |
|---|---|---|
| `entered` | `diverged` | `card` (follow card id), `c_calls`, `refreshes` |
| `refreshed` | `refresh` | same; `refreshes` counts this one |
| `launch_refused` | `halted`, `closing`, `no_session`, `no_turn`, `call_refused:<diverged\|refresh>` | `mode`, `c_calls` |
| `refresh_blocked` | `refresh_capped` or `refresh_too_soon` | `refreshes`, `max_refreshes`, `card_age_s`, `min_card_show_s`, `new_words`; at most once per sentence end |
| `ended` | `new_question`, `short_card`, `remote_spoke_again` | `mode`, `c_calls` |

`follow_embed_state`: the divergence check's embedding request. A check is asked for whenever a lexical rule is suspicious; it is not
written per token, but a long off-card answer that the embedding keeps on the card produces one `requested`/`arrived` pair per
recognizer update.

| `state` | fields |
|---|---|
| `requested` | `seq`, `wait_s` (`embed_wait_s`), `by_count`, `by_time`, `unmatched`, `run_words` |
| `arrived` | `seq`, `verdict` (`diverge`, `stay`, or `stale` when his words changed under the request, then asked again), `embed`, `margin`, `sem_floor`, `sem_margin`, `on_card`, `suspicious` |
| `timed_out` | `seq`, `waited_s`; the check is asked again, nothing is decided without the embedding |

To list one call's decisions: `jq -c 'select(.ev | startswith("follow_"))' events.jsonl`. The engine's metrics of the same names
(`follow_diverged`, `follow_state`, `follow_embed_state`) go to the app, not to this file.

## Coverage

A point is struck when most of its content stems occur close together in his speech (`cover_lex` 0.6 of its stems within
max(8, 2 x stems) words), or when a window of his words is at least `cover_score` close to it, is the best-scoring line of
the card for that window (within 0.01), has four content words, and, for a point that carries numbers, he said one of them.

| cover_score | struck correctly | struck wrongly | missed (of 48 labelled) |
|---|---|---|---|
| 0.82 | 47 | 15 | 1 |
| 0.84 | 47 | 4 | 1 |
| 0.86 | 47 | 1 | 1 |
| **0.88** | **44** | **0** | **4** |
| 0.90 | 40 | 0 | 8 |
| lexical only | 29 | 0 | 19 |

0.88: no point is ever struck that he did not say, 4 of 48 said points stay visible. A wrong strike hides a point he still owes;
a missed strike only leaves a said point on screen.

## Held-out check (2026-11-12, review E7)

Every threshold above was picked by sweeping the same 87 cases that then report "46 of 46" and "0 false divergences", so those
figures are in-sample. `eval/tune_follow.py --parts 5` (about 50 s with the model) repeats the choice honestly: 5 folds, stratified
by kind; on each fold the (floor, margin) pair and the `cover_score` are picked on the other four folds (fewest false divergences
first, then fewest misses; a wrong strike first, then a missed one) and scored on the fold left out (`eval/kfold.py`).

| | in-sample (above) | held-out, 5 folds |
|---|---|---|
| floor / margin chosen | 0.80 / 0.04 | 0.80 / 0.04 in all 5 folds |
| false divergences (of 46 stay) | 0 | 0, 95 % upper bound 6.3 % |
| missed (of 41 diverge), part 2 rule | 3 | 3 |
| points struck wrongly / correctly / missed (48 labelled) | 0 / 44 / 4 | 1 / 44 / 4 (cover_score 0.88 in four folds, 0.86 in one) |

The operating point is stable: the same pair wins whichever fifth is held out. The zero is a measured 0 of 46, which only says the
true rate of false divergences is below about 6 % (95 %), not that it is zero; the set is still 87 hand-written answers by one
author. `sem_mark` (0.88), `cover_best_gap` and the lexical N and T were not folded: they are chosen on the full machine, which part 5
does not re-run per fold. A held-out set written after this tuning is still the stronger test.

## Repeats (2026-10-29)

A live answer got four follow cards in 25 seconds that all said the same idea ("the big calls are mine to make") with the same two
points in other words. Three causes, three fixes (`runtime/repeat.py`, `follow.py`, `prompt.follow_tail`):

1. The prompt forced a SAY line every time and showed the model only the card on screen, not the earlier ones. It now lists every
   earlier follow card and detail line ("ALREADY SHOWN TO HIM THIS TURN") and allows the single word `NONE`.
2. Nothing checked the output. Every line of a new follow card is compared with all lines shown this turn and the last 8 sentences
   of his answer: a repeat is an embedding cosine >= 0.86 or >= 60 % of the shorter line's content stems (>= 3 stems) found in the
   other. A repeating SAY drops the card (the card on screen stays), a repeating point is dropped alone. The card is held until the
   call is over (about one more second than streaming it), because the check needs all of its lines.
3. The refresh counted any four content words as news. It now counts distinct content stems that he has not said earlier in the turn
   and that are on no card line of the turn, and each card that showed nothing (NONE, or only repeats) doubles the wait and the
   word count for the next refresh, up to three times the base values (`repeat_backoff_max`).

Threshold evidence (EmbeddingGemma 270M, sentence-similarity prefix, 13 hand-written fictional pairs, cosine):

| pairs | n | range |
|---|---|---|
| the same idea in other words | 6 | 0.85 to 0.94 |
| same topic, a different fact | 4 | 0.78 to 0.84 |
| unrelated | 3 | 0.74 to 0.80 |

0.86 catches five of the six paraphrases and none of the others. A missed repeat shows one more similar card; a wrong drop leaves the
earlier card on screen. Not yet measured on real calls: the live r114 answer is the evidence for the problem, not for the threshold.

## Not measured here

Real speech recognition output (the fixtures are clean text with the recognizer's chunk rhythm), Italian and Turkish (the
detector is off outside English: `Config.follow_langs`), and the quality of the follow card text (the live t03 run in
`docs/follow-live-t03.md`).
