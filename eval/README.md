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
