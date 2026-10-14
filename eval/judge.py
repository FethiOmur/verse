"""Independent grounding judge: Haiku checks, line by line, whether a suggestion is supported by the meeting pack.

The API key comes from the Keychain (checks.keychain_key) and goes straight into the SDK client; it is never printed.
Only lines that the string check could not resolve are sent.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import checks  # noqa: E402

MODEL = "claude-haiku-5-5"
SECOND_MODEL = "claude-sonnet-5-5"   # second opinion on the lines Haiku flags
PRICES = {MODEL: (0.10, 0.50), SECOND_MODEL: (2.00, 10.00)}   # USD per million tokens (brain/verse_brain/prep/model.py PRICES)

SYSTEM = (
    "You audit what a live interview assistant showed to a candidate. You are given the candidate's meeting notes (the only "
    "allowed source) and numbered lines the assistant suggested, each with the question it answered. For every line decide "
    "whether each number, date, proper name and factual claim in it is stated in the notes or follows directly from them "
    "(a number written in words, rounded the way the notes round it, or a generic phrase that asserts nothing, counts as supported; "
    "a line that says something is not in the notes is supported; the notes include prepared answers, so a line that repeats or "
    "paraphrases a prepared answer is supported). Search the whole notes before you decide. Mark a line unsupported only when it states a "
    "number, date, name or fact that the notes do not contain. Answer with JSON only: a list of objects {\"i\": <number>, "
    "\"supported\": true|false, \"evidence\": <a short exact quote from the notes that supports the line, or null>, "
    "\"unsupported_claim\": <short text or null>}."
)


class JudgeError(RuntimeError):
    pass


def judge_lines(pack: str, items: list[dict], model: str = MODEL) -> tuple[list[dict], float]:
    """items: [{"i": int, "question": str, "line": str}]. Returns (verdicts, cost_usd)."""
    import anthropic

    key = checks.keychain_key()
    if not key:
        raise JudgeError("no API key in the Keychain (service verse-anthropic)")
    client = anthropic.Anthropic(api_key=key, max_retries=1, timeout=60.0)
    del key
    body = "\n".join(f"{it['i']}. QUESTION: {it['question']}\n   LINE: {it['line']}" for it in items)
    user = f"MEETING NOTES:\n{pack}\n\nSUGGESTED LINES:\n{body}\n\nJSON:"
    try:
        extra = {"thinking": {"type": "disabled"}} if model == MODEL else {}
        msg = client.messages.create(model=model, max_tokens=4000, system=SYSTEM, output_config={"effort": "low" if model == MODEL else "medium"},
                                     messages=[{"role": "user", "content": user}], **extra)
    except Exception as e:  # noqa: BLE001  (no request data in the message)
        raise JudgeError(f"judge call failed: {type(e).__name__}") from None
    text = "".join(b.text for b in msg.content if getattr(b, "type", "") == "text")
    m = re.search(r"\[.*\]", text, re.S)
    if not m:
        raise JudgeError("judge did not return JSON")
    try:
        verdicts = json.loads(m.group(0))
    except json.JSONDecodeError:
        raise JudgeError("judge JSON did not parse") from None
    u = msg.usage
    pin, pout = PRICES[model]
    cost = (u.input_tokens * pin + u.output_tokens * pout) / 1_000_000
    return verdicts, cost
