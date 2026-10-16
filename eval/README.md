# Verse replay harness and eval (P1-6)

English-only replay of synthetic dialogues through the real `verse-run --file` and the live brain, scored against labels.

```
# once: build the runner in this worktree
cd app && swift build -c release

# the brain venv exists only in the main checkout (read-only use)
export VERSE_BRAIN_DIR=$HOME/Desktop/ProjectExamples/CursorExamples/Verse/brain
PY=$VERSE_BRAIN_DIR/.venv/bin/python

cd eval
$PY -m pytest tests -q                                   # unit tests (no network, no audio)
$PY run_replay.py --run live1                            # all 12 dialogues, live brain (spend is tracked in out/spend.json, cap $1.50)
$PY run_replay.py --run dev --dialogues d01 --fake-brain # plumbing only
$PY score.py --run live1 --judge                         # scores.json + grounding judge (Haiku, Sonnet second opinion)
$PY report.py --run live1                                # writes ../docs/eval-report-v1.md and runs the secret scan
```

- `dialogues/*.json`: labels (regenerate with `tools/make_dialogues.py`; audio is never stored).
- `run_replay.py`: builds the audio in a temp dir with `say`, runs `verse-run`, records every stdout line with its wall time in `out/<run>/<id>.jsonl`, watches the session folder for audio files, deletes the audio.
- `score.py`, `grounding.py`, `judge.py`, `grounding_run.py`: scoring. `report.py`: the table against spec section 9.
- Dev runs: set `VERSE_EVAL_OUT` to keep them out of the repo (the spend ledger always stays in `out/spend.json`).
- Times are measured from the true acoustic end of each utterance (known from the generated audio), not from the recognizer's estimate.

## Two-track replay (me channel and speaker bleed)

```
export VERSE_EVAL_OUT=/some/scratch VERSE_BRAIN_DIR=$PWD/../brain
cd eval
python3 run_twotrack.py --fixture t01 --name clean                                   # Ingrid on the remote track, Alex on the me track (fake brain)
python3 run_twotrack.py --name b25 --bleed-db 25 --bleed-delay-ms 40 --noise-dbfs -55   # me track = the remote track 25 dB down, 40 ms late, room noise
python3 run_twotrack.py --name b25own --bleed-db 25 --with-own                          # ... plus Alex talking
python3 run_twotrack.py --name b25off --bleed-db 25 --no-bleed-gate --no-echo-guard     # both echo defenses off
python3 matrix_table.py $VERSE_EVAL_OUT/twotrack                                        # table of runs named m_<A|C|D|O>_<none|gate|guard|both>
python3 -m pytest tests -q
```

`twotrack.py` renders `twotrack/<id>.json` with two `say` voices (offsets may be negative: overlaps and interruptions), `score_twotrack.py`
counts answered questions, me turns and wrong triggers. Report: `docs/p1-replay-bleed-report.md`.

## Follow my answer (t02, t03, t04)

`docs/specs/2026-10-16-verse-follow-my-answer-design.md`; thresholds and their evidence: `docs/follow-tuning.md`; live card: `docs/follow-live-t03.md`.

```
cd eval; export VERSE_EVAL_OUT=/some/scratch
python3 run_follow.py --fixture t02 --name t02_fake --brain-dir ../brain          # he reads / paraphrases the card: 0 follow cards, points struck
python3 run_follow.py --fixture t03 --name t03_fake --brain-dir ../brain          # off the card, pack topic: a follow card
python3 run_follow.py --fixture t04 --name t04_fake --brain-dir ../brain          # off the card, outside the pack
python3 run_follow.py --fixture t03 --name t03_live --brain-dir ../brain --live --session <session with a STYLE GUIDE>   # real Haiku, spends (~$0.03)
PYTHONPATH=../brain ../brain/.venv/bin/python tune_follow.py                       # the detector tuning (8 min)
```

`run_follow.py` feeds the Python brain directly (fake brain = canned transport answering from the pack's bank, with the embedding
model; `--no-embed` for the lexical-only detector). It exists because `verse-run` has no `--follow` yet and sends no `partial` for the owner's
speech without it; the `say` voices only fix the true start and end of each utterance and the words are delivered like a streaming
recognizer would (see the module docstring). `score_twotrack.py` adds, per labelled owner utterance, `follow_events`, `detection_ms`
(first `follow` event after the first off-card word was spoken), `first_sentence_ms` (first complete SAY line of the follow card),
the card's point count and the `covered` events. Detection and first-sentence times assume the audio clock starts at `session_t0.t`
(exact for `run_follow.py`).
