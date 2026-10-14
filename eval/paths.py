"""Where run outputs live: eval/out by default, or $VERSE_EVAL_OUT (dev runs go outside the repo)."""

import os
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = Path(os.environ.get("VERSE_EVAL_OUT", HERE / "out")).expanduser()

# One ledger for all live spend of this package (dev runs included), whatever $VERSE_EVAL_OUT says: the $1.50 cap is total.
LEDGER = HERE / "out" / "spend.json"
