"""F5: a calendar event (JSON written by the Swift app) -> a prep note the existing pipeline can ingest.

The note is plain markdown: title, time, platform and link, attendees, agenda/notes. Rendering is deterministic.
Attendees are listed by name; an email address appears only when the event has no name for that person.
`FakeEventModel` is an offline stand-in for the prep model (`--fake`): it builds grounded @BANK/@FACT blocks
straight from the note's own lines, so tests and the `verse-meet prep` default never touch the network.
"""

from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path

from .model import ModelOutput, Usage

PROVIDERS = {"meet": "Google Meet", "zoom": "Zoom", "teams": "Microsoft Teams", "other": "Other"}
MAX_NOTE_LINES = 60
MAX_LINE_CHARS = 300


class EventError(ValueError):
    pass


def load_event(path: Path) -> dict:
    try:
        raw = json.loads(Path(path).expanduser().read_text(encoding="utf-8"))
    except OSError as e:
        raise EventError(f"cannot read event file: {e.strerror or e}") from e
    except json.JSONDecodeError as e:
        raise EventError(f"event file is not valid JSON: {e.msg}") from e
    if not isinstance(raw, dict):
        raise EventError("event file must hold one JSON object")
    if not str(raw.get("title") or "").strip():
        raise EventError("event has no title")
    return raw


def _one_line(s: object, limit: int = MAX_LINE_CHARS) -> str:
    return re.sub(r"\s+", " ", str(s or "")).strip()[:limit]


def _parse_dt(s: object) -> datetime | None:
    if not s:
        return None
    try:
        return datetime.fromisoformat(str(s).strip().replace("Z", "+00:00"))
    except ValueError:
        return None


def _when(event: dict) -> str:
    start, end = _parse_dt(event.get("start")), _parse_dt(event.get("end"))
    if start is None:
        return ""
    day = f"{start:%A} {start.day} {start:%B %Y}"
    tz = start.strftime("%z")
    zone = f" (UTC{tz[:3]}:{tz[3:]})" if tz else ""
    if end is None or end <= start:
        return f"{day}, {start:%H:%M}{zone}"
    minutes = int((end - start).total_seconds() // 60)
    return f"{day}, {start:%H:%M} to {end:%H:%M}{zone}, {minutes} minutes"


def _attendee(a: object) -> str:
    if isinstance(a, dict):
        return _one_line(a.get("name")) or _one_line(a.get("email"))
    return _one_line(a)


def event_to_prep_note(event: dict) -> str:
    title = _one_line(event.get("title")) or "Untitled meeting"
    lines = [f"# Meeting prep: {title}", ""]
    when = _when(event)
    if when:
        lines.append(f"When: {when}")
    provider = str(event.get("provider") or "").lower()
    if provider in PROVIDERS and provider != "other":
        lines.append(f"Platform: {PROVIDERS[provider]}")
    url = _one_line(event.get("url"), 500)
    if url:
        lines.append(f"Link: {url}")
    attendees = [x for x in (_attendee(a) for a in event.get("attendees") or []) if x]
    if attendees:
        lines += ["", "## Attendees", *[f"- {a}" for a in attendees]]
    notes = [_one_line(x) for x in str(event.get("notes") or "").splitlines()]
    notes = [re.sub(r"^[-*•]\s*", "", n) for n in notes if n][:MAX_NOTE_LINES]
    if notes:
        lines += ["", "## Agenda and notes", *[f"- {n}" for n in notes]]
    return "\n".join(lines).rstrip() + "\n"


# ---------------------------------------------------------------------------------------------- offline model

_LINE = re.compile(r"^L(\d+): (.*)$")


class FakeEventModel:
    """Deterministic offline prep model. It only quotes lines it was given, so every block grounds."""

    model = "claude-sonnet-5-5"

    async def generate(self, system: str, user: str, max_tokens: int) -> ModelOutput:
        lang = (re.search(r"\((\w{2,3})\)", user) or [None, "en"])[1]
        by_line = {int(m[1]): m[2] for ln in user.splitlines() if (m := _LINE.match(ln))}
        title_no, title = next(((n, t) for n, t in by_line.items() if t.startswith("# Meeting prep:")), (0, ""))
        title_text = title.removeprefix("# Meeting prep:").strip() or "this meeting"
        section, agenda, people, when = "", [], [], None
        for n, t in sorted(by_line.items()):
            if t.startswith("## "):
                section = t[3:].strip()
            elif t.startswith("When: "):
                when = (n, t)
            elif t.startswith("- "):
                (agenda if section == "Agenda and notes" else people if section == "Attendees" else []).append((n, t[2:].strip()))
        out: list[str] = []

        def block(question: str, opener: str, points: list[tuple[int, str]], paras: list[str]) -> None:
            if not points:
                return
            out.append("@BANK")
            out.append(f"lang: {lang}")
            out.append(f"question: {question}")
            out.extend(f"para.{lang}: {p}" for p in paras)
            out.append(f"opener: {opener}")
            for line_no, text in points[:3]:
                out.append(f"point: {text}")
                out.append(f"src: prep:L{line_no} | {text}")
            out.append("@END")

        block(f"What is the {title_text} meeting about?", "Here is what the calendar invite says.",
              agenda or ([(title_no, f"Meeting prep: {title_text}")] if title_no else []),
              [f"What is {title_text} for?", f"What are we covering in {title_text}?", f"Why are we meeting about {title_text}?"])
        block("Who is in this meeting?", "These are the people on the invite.", people,
              ["Who else is on the call?", "Who are the attendees?", "Which people are joining?"])
        if when:
            n, t = when
            text = t.removeprefix("When: ")
            day = re.search(r"\d{1,2} \w+ \d{4}", text)
            if day:
                out += ["@FACT", "kind: date", f"text: {text}", f"value: {day[0]}", f"src: prep:L{n} | {text}", "@END"]
        text = "\n".join(out) + "\n"
        return ModelOutput(text, Usage(), "end_turn")

    async def count_tokens(self, text: str) -> int:
        return len(text) // 4

    async def count_request_tokens(self, system: str, user: str) -> int:
        return (len(system) + len(user)) // 4
