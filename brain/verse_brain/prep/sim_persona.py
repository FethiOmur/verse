"""Interviewer persona of a sim (opt-in): who asks, what they probe, and the answer length the feedback measures against.

`sim.json` gets a `persona` key only when one is given; a sim without it is built and run exactly as before. Sources, in order
of precedence: CLI flags, then a small JSON file (`--persona-file`):

    {"name": "Sam Carter", "role": "Head of Engineering",
     "focus": ["ownership and AI use", "trade-offs", "evals", "cost and latency"],
     "answer_target_s": [30, 60]}

`focus` is a list or a comma-separated string. `answer_target_s` is `[lo, hi]` or `"lo-hi"` seconds (default 30-60); it replaces the
`target_s` of every planned question, so the report's length verdict and the live feedback measure against it.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from .model import PrepError

DEFAULT_ANSWER_TARGET = [30, 60]
MAX_FOCUS = 10
MAX_FIELD_CHARS = 80
_RANGE = re.compile(r"^\s*(\d{1,3})\s*[-–]\s*(\d{1,3})\s*$")


def _one(v: object) -> str:
    return " ".join(v.split())[:MAX_FIELD_CHARS].strip() if isinstance(v, str) else ""


def _focus(v: object) -> list[str]:
    items = re.split(r"[;,]", v) if isinstance(v, str) else v if isinstance(v, (list, tuple)) else []
    out: list[str] = []
    for x in items:
        s = _one(x)
        if s and s.lower() not in {o.lower() for o in out}:
            out.append(s)
    return out[:MAX_FOCUS]


def _target(v: object) -> list[int] | None:
    if isinstance(v, str):
        m = _RANGE.match(v)
        v = [int(m.group(1)), int(m.group(2))] if m else None
    if isinstance(v, (list, tuple)) and len(v) == 2 and all(isinstance(x, int) and not isinstance(x, bool) for x in v):
        if 0 < v[0] < v[1] <= 600:
            return [int(v[0]), int(v[1])]
    return None


def build_persona(*, file: Path | None = None, name: str | None = None, role: str | None = None, focus: object = None,
                  answer_target: object = None) -> dict | None:
    """The persona dict for sim.json, or None when nothing was given. A bad `answer_target` is an error (a typo must not
    silently measure against the default)."""
    raw: dict = {}
    if file is not None:
        try:
            raw = json.loads(Path(file).expanduser().read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError) as e:
            raise PrepError(f"cannot read the persona file {file}: {e}") from e
        if not isinstance(raw, dict):
            raise PrepError("the persona file must hold a JSON object")
    nm, rl = _one(name) or _one(raw.get("name")), _one(role) or _one(raw.get("role"))
    fc = _focus(focus) or _focus(raw.get("focus"))
    given = answer_target if answer_target not in (None, "") else raw.get("answer_target_s")
    tg = _target(given) if given not in (None, "") else None
    if given not in (None, "") and tg is None:
        raise PrepError("the answer target must be LO-HI seconds, for example 30-60")
    if not (nm or rl or fc or tg):
        return None
    out: dict = {}
    if nm:
        out["name"] = nm
    if rl:
        out["role"] = rl
    if fc:
        out["focus"] = fc
    out["answer_target_s"] = tg or list(DEFAULT_ANSWER_TARGET)
    return out


def apply_persona(persona: dict | None, questions: list[dict]) -> None:
    """Every planned question gets the persona's answer target."""
    if persona:
        for q in questions:
            q["target_s"] = list(persona["answer_target_s"])
