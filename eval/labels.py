"""Dialogue label files (eval/dialogues/<id>.json): loading and validation. Stdlib only.

Utterance fields: speaker, text, category, is_question, addressee (me|other|null), bank_id|null, t_start, t_end (nominal
seconds on the dialogue's own clock, measured at generation time; the runner records the real ones for each run),
and `silent_s` for stretches where nobody on the remote channel speaks (Alex answering).
"""

from __future__ import annotations

import json
from pathlib import Path

DIALOGUES_DIR = Path(__file__).resolve().parent / "dialogues"
CATEGORIES = {"exact", "paraphrase", "offbank", "other", "statement", "fragment", "reply", "answer"}
ADDRESSEES = {"me", "other", None}
REQUIRED = ("speaker", "text", "category", "is_question", "addressee", "bank_id", "t_start", "t_end")
TOP_REQUIRED = ("id", "lang", "owner", "participants", "voices", "session", "utterances")


def validate(d: dict) -> list[str]:
    """Returns a list of problems (empty = valid)."""
    errs: list[str] = []
    if not isinstance(d, dict):
        return ["label is not an object"]
    for k in TOP_REQUIRED:
        if k not in d:
            errs.append(f"missing top-level key {k!r}")
    if errs:
        return errs
    if d.get("suite", "main") not in ("main", "short"):
        errs.append(f"suite must be main or short, got {d.get('suite')!r}")
    if d["lang"] != "en":
        errs.append(f"lang must be 'en' (English only for now), got {d['lang']!r}")
    if not isinstance(d["participants"], list) or not d["participants"] or not all(isinstance(x, str) for x in d["participants"]):
        errs.append("participants must be a non-empty list of names")
    speakers = set(d["participants"]) | {d["owner"]}
    for name in d["participants"]:
        if name not in d["voices"]:
            errs.append(f"no voice for participant {name!r}")
    utts = d["utterances"]
    if not isinstance(utts, list) or not utts:
        return errs + ["utterances must be a non-empty list"]
    prev_end = -1.0
    for i, u in enumerate(utts):
        where = f"utterance {i}"
        for k in REQUIRED:
            if k not in u:
                errs.append(f"{where}: missing {k!r}")
        if any(k not in u for k in REQUIRED):
            continue
        if u["speaker"] not in speakers:
            errs.append(f"{where}: unknown speaker {u['speaker']!r}")
        if u["category"] not in CATEGORIES:
            errs.append(f"{where}: bad category {u['category']!r}")
        if not isinstance(u["is_question"], bool):
            errs.append(f"{where}: is_question must be a boolean")
        if u["addressee"] not in ADDRESSEES:
            errs.append(f"{where}: addressee must be me, other or null")
        if u["bank_id"] is not None and not (isinstance(u["bank_id"], str) and u["bank_id"].startswith("b")):
            errs.append(f"{where}: bank_id must be null or a bank id")
        if u["is_question"] and u["addressee"] is None:
            errs.append(f"{where}: a question needs an addressee")
        if u["category"] in ("exact", "paraphrase") and not u["bank_id"]:
            errs.append(f"{where}: {u['category']} needs a bank_id")
        if u["category"] in ("offbank", "other", "statement", "fragment", "reply") and u["bank_id"]:
            errs.append(f"{where}: {u['category']} must not have a bank_id")
        if u["category"] == "other" and u["addressee"] != "other":
            errs.append(f"{where}: category other needs addressee other")
        silent = bool(u.get("silent_s"))
        if silent and u["speaker"] != d["owner"]:
            errs.append(f"{where}: only the owner is silent")
        if (u["speaker"] == d["owner"]) != silent:
            errs.append(f"{where}: the owner's utterances are silent (silent_s) and nobody else's are")
        if not (isinstance(u["t_start"], (int, float)) and isinstance(u["t_end"], (int, float)) and u["t_end"] > u["t_start"]):
            errs.append(f"{where}: t_end must be greater than t_start")
        elif u["t_start"] < prev_end - 1e-6:
            errs.append(f"{where}: starts before the previous utterance ended")
        else:
            prev_end = u["t_end"]
    if not any(u["is_question"] and u["addressee"] == "me" for u in utts):
        errs.append("no question addressed to the owner")
    return errs


def load(path: Path) -> dict:
    d = json.loads(Path(path).read_text(encoding="utf-8"))
    errs = validate(d)
    if errs:
        raise ValueError(f"{path.name}: " + "; ".join(errs))
    return d


def load_all(directory: Path = DIALOGUES_DIR) -> list[dict]:
    return [load(p) for p in sorted(directory.glob("*.json"))]
