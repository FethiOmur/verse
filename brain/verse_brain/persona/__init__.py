"""The master persona: what the owner's own answers in finished calls show about him, kept as notes in a folder of his vault.

  rows.py      the rows of a finished session, read headless (the Swift TranscriptDocument rules), owner rows classified
  extract.py   the one model request per session and the verification of its items (cite, quote, numbers, card-read rule)
  store.py     Persona.md, the Log notes and the state: merge, owner edits, deletions, contradictions, write guard
  review.py    the after-call review of every question -> answer pair (same request): weak answers get a better answer from
               confirmed sources, strong ones and GOOD-marked cards become the bank's wording, the Review note
  compile.py   the one-time import of the general prep and the compile into the files an unprepared call loads
  runtime.py   one session's update, the backfill plan and the `persona_start` process mode
  __main__.py  the command line: update, backfill (with --dry-run and the review's cost), import-general, compile, show,
               resolve

Off unless the owner profile names `persona_dir` (owner.py).
"""
