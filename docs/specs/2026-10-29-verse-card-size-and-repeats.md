# Verse: card size follows the question, follow cards never repeat

Date 2026-10-29. Code: `brain/verse_brain/runtime/size.py`, `repeat.py`, `follow.py`, `engine.py`, `prompt.py`. Tests:
`brain/tests/test_runtime_card_size.py`, `brain/tests/test_follow_repeat.py`.

## Problems (one real call, fictional wording here)

1. Every card had one shape: a SAY line and two points. "Yes, can you hear me?" got a SAY line and two points about audio; a
   "walk me through the architecture" question got the same size.
2. In one answer the follow tier (C) wrote four cards in about 25 seconds, each restating the same idea with the same points in other
   words.

## A. Card size

A deterministic class of the question text (`size.card_size`), computed per call in the brain: the S call from the partial, F, D, the
statement probe and card-now from the final text. A speculative S or early D call of another class than the final text is not used.

| class | when | F / S card | D |
|---|---|---|---|
| short | a greeting, a hearing/seeing/connection check, readiness, a turn of <= 3 words; never when the turn also holds a real question | SAY only (<= 10 words), no points | not fired; follow mode ends at once for the turn |
| normal | everything else | SAY (<= 20 words) and 1 or 2 points | up to 2 points |
| deep | "walk me through", "tell me about", "describe/explain", "how did you design/build/decide ...", "why did you choose", trade-offs, behavioural questions ("a time when ..."), or >= 28 words | SAY <= 32 words and 2 points | 2 to 4 points as before |

English, Italian and Turkish phrases are in the lexicon; a question that holds both a pleasantry and a real question is classified by the
real one. The class is stated in the uncached tail as `CARD SIZE: ...` before the question (the cached prefix does not change) and the
point cap is also applied when the lines are parsed (`Call._on_text`, stage `point_capped`), so a model that ignores the rule shows no
more than the class allows. A session's `call.json` `card_lines` stays the hard cap on a whole card: it wins over `normal` and `deep`
in the prompt, and its point count (card_lines - 1) is enforced in code; `short` still applies. `Config.card_size = False` restores
every card to the old shape (no tail line, no cap, D always).

## B. No repeats

* Prompt (`prompt.follow_tail`): the model gets every earlier follow card and detail line ("ALREADY SHOWN TO HIM THIS TURN"), and may
  write the single word `NONE` when its SAY would only restate him or a shown line.
* Guard (`repeat.filter_card`, engine `_follow_gate`): a C call is held until it is over; each line is compared with all lines shown this
  turn (original, bank, D, earlier follow cards) and the last 8 sentences of his answer. Repeat = embedding cosine >= 0.86 (the follow
  machine's EmbeddingGemma path, same vector cache; 0.6 s budget, then lexical only) or >= 60 % of the shorter line's content stems
  (>= 3 stems) in the other. A repeating SAY drops the whole card, a repeating point is dropped alone, and when nothing is left the
  card on screen stays. Events: `point_dropped` / `card_suppressed` (`why: repeat`), metrics `follow_repeat`, `follow_empty`.
* Cadence (`follow.FollowMachine`): refresh needs 4 distinct content stems that are news (not said earlier in the turn, not on any card
  line of the turn); each follow card that showed nothing doubles, then triples, the refresh gap and the word count; a shown card resets
  it.

Cost: the follow card is on screen when the call is over, not word by word (about one second later), because the guard needs all of
its lines. Open: the 0.86 threshold rests on 13 hand-written pairs (`docs/follow-tuning.md`), not on real calls.
