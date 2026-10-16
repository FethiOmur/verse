# Follow my answer: live t03 run (real Haiku)

Fixture `eval/twotrack/t03.json`, run with `eval/run_follow.py --live` on a scratch copy of the sample-interview session whose
pack carries the owner's STYLE GUIDE section (`prep.voice.with_voice`; the copy is not in the repo). Question b001 ("Can you tell me
about yourself and your background?"); Alex says the opening of the card and then leaves it for another topic of the pack:

> Sure, I'll give you the short version. What I'm happiest about is the accuracy of Lantern. On the held out set we got ninety six
> point four percent on totals, and the evaluation set was a frozen set of four hundred invoices.

Delivery: a synthetic streaming recognizer (cumulative partial every 560 ms, words spread evenly over the `say` clip), see
`run_follow.py`. No recognition errors, no Swift.

The card on screen (S, Haiku): SAY "Sure, I'll give you the short version of what I've worked on." with the Lantern, 11 to 2
minutes and courier points.

## Run 2 (current prompt)

Detection at 13.79 s on the file clock (time rule: a run of 3 unmatched content words lasting 2.3 s; best card score 0.823, margin 0.061:
the pack has a line closer than the card). Follow event 14.45 s, first sentence complete 14.64 s (0.85 s after the decision).

```
C c0004 (diverged)
SAY: Lantern's accuracy is the part I'm happiest with, so let me get to the numbers.
- On the held-out set, accuracy was 96.4 percent for totals and 91 percent for line items.
- Fields below 0.8 confidence go to a human operator; that was about 7 percent of invoices.
```

He then says the 96.4 percent: point 0 is struck (`covered`, lexical, 18.17 s); point 1 stays. At his sentence end (22.19 s, 11
new content words) the refresh:

```
C c0005 (refresh)
SAY: Let me also say how we kept that accuracy honest over time.
- Every prompt change was rerun on the frozen set of 400 invoices before release.
- The model never guesses a total; extraction is schema-validated with one retry, then escalated.
```

## Run 1 (first prompt, kept as evidence for the change)

```
C c0004 (diverged)   SAY: Right, and the part I'm proudest of is how well the extraction holds up.
                     - Accuracy on the held-out set was 96.4 percent for totals and 91 percent for line items.
                     - Fields below 0.8 confidence go to a human operator, about 7 percent of invoices.
C c0005 (refresh)    SAY: The part I'm proudest of is that the extraction stays reliable, and I can show why.
                     - Lantern ran on 38,000 invoices a month, with fields below 0.8 confidence going to a human.
                     - Evaluation used a frozen set of 400 invoices, rerun on every prompt change before release.
```

Problems seen: the SAY opened with a reaction word ("Right,"), the refresh reused the first card's SAY pattern and repeated a point
from the card on screen, and its second point was what he had just said. The prompt (`follow_tail`) now forbids a reaction
opener, requires "nothing he already said, not even in other words" and "new SAY, new points, nothing from the card on screen".

## Judgement

* Continues his line: yes for the points and for the refresh SAY; the first SAY mostly restates his sentence ("accuracy is the part
  I'm happiest with") before moving on. A weak sentence, not a wrong one.
* Grounded: every number traces to the pack (96.4 and 91 percent = f012, f013; 0.8 and 7 percent = f014, f015; 400 invoices = f018;
  schema validation with one retry = bank b010). Nothing invented.
* STYLE GUIDE: short, spoken, contractions, no hype, no em dash, plain words, "honest over time" matches the guide's tone. The
  restating first SAY is the only line I would not use.
* Not yet right: the refresh point "rerun on the frozen set of 400 invoices" repeats half of what he had just said. Haiku at low
  effort does not fully obey "nothing he already said"; a check that drops C points already covered by his words (the machine can
  compute it) is the next step if this shows up on real calls.
* Timing: first sentence on screen 3.7 s after the first chunk that carried an off-card word (2.9 s to the decision, 0.85 s for
  Haiku). The spec's "within ~3 s" is not met; see `docs/follow-tuning.md` for why detection is the long part.
* Spend: $0.026 per run in total (pre-warm of both models $0.0156, the S and D cards, the Sonnet merge at stop); the two C calls
  cost $0.0004 together.
