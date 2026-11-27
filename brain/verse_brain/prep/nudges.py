"""Live nudges, prep side: parse the `### Nudge:` blocks of a prep note into `nudges.jsonl` (docs/specs/2026-11-27-live-nudges-plan.md).

Authoring format (`### Cue:` is accepted as well)::

    ### Nudge: Pay story
    When: pay, salary or the commercial terms are being discussed now
    Keys: salary, pay, commercials, compensation, package, budget
    Who: any
    Until: number
    After: 0m
    Say: First line to say or do.
      Second line.

A block ends at the next line starting with `#` or at a `---` rule. `When`, `Keys` and `Say` are required; `Say` holds one to
three lines (continuation lines are indented) of at most 45 words in total. A block that breaks a rule, and every block
beyond the eighth compiled one, is dropped with a warning; the others still compile. Ids follow the block order in the note
(`n001` is the first block), so dropping or fixing one block never renumbers the others.

The prep model never sees nudge lines: `model_lines` blanks them (the line numbering is kept, so every `prep:L<n>` handle still
points at the real line). The SourceBook keeps the note as written. Nudges are not part of `pack.md`.

Nudges-only compile, to add nudges to an existing session without rebuilding its answers::

    python -m verse_brain.prep.nudges NOTE.md SESSION_DIR
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

MAX_NUDGES = 8
MAX_SAY_WORDS = 45
MAX_SAY_LINES = 3
WHO = ("any", "me", "them")
FILE_NAME = "nudges.jsonl"

_HEADER = re.compile(r"^\s*#{1,6}\s*(?:nudge|cue)\s*:\s*(.*?)\s*$", re.IGNORECASE)
_FIELD = re.compile(r"^(when|keys|who|until|after|say)\s*:\s*(.*?)\s*$", re.IGNORECASE)
_RULE = re.compile(r"^\s*-{3,}\s*$")
_AFTER = re.compile(r"^(\d+(?:\.\d+)?)\s*(?:m|min|mins|minute|minutes)?$", re.IGNORECASE)


@dataclass
class ParsedNudges:
    records: list[dict] = field(default_factory=list)   # compiled records, sorted by id
    warnings: list[str] = field(default_factory=list)
    lines: set[int] = field(default_factory=set)        # 1-based numbers of every line inside a nudge block (header included)


def _block_end(lines: list[str], start: int) -> int:
    """Index after the last line of the block whose header is at `start` (0-based)."""
    i = start + 1
    while i < len(lines):
        if lines[i].lstrip().startswith("#") or _RULE.match(lines[i]):
            break
        i += 1
    return i


def _compile_block(nid: str, title: str, body: list[tuple[int, str]], header_no: int) -> tuple[dict | None, list[str]]:
    """(record | None, warnings) for one block. `body` holds (1-based line number, text) of the lines after the header."""
    label = f"nudge {nid} ({title or 'untitled'}, prep:L{header_no})"
    fields: dict[str, str] = {}
    say: list[str] = []
    in_say = False
    notes: list[str] = []
    for no, text in body:
        if not text.strip():
            continue
        m = _FIELD.match(text.strip()) if not text[:1].isspace() else None
        if m:
            key, val = m.group(1).lower(), m.group(2)
            if key in fields or (key == "say" and say):
                notes.append(f"{label}: `{key.title()}` given twice (line {no}); the first one is kept")
                in_say = False
                continue
            if key == "say":
                in_say = True
                if val:
                    say.append(val)
                fields["say"] = val
            else:
                in_say = False
                fields[key] = val
            continue
        if in_say and text[:1].isspace():
            say.append(text.strip())
            continue
        notes.append(f"{label}: line {no} is not a nudge field and was ignored (it is hidden from the prep model too)")
    for req in ("when", "keys"):
        if not fields.get(req, "").strip():
            return None, notes + [f"{label} dropped: no `{req.title()}:` line"]
    if not say:
        return None, notes + [f"{label} dropped: no `Say:` lines"]
    if len(say) > MAX_SAY_LINES:
        return None, notes + [f"{label} dropped: `Say` has {len(say)} lines (at most {MAX_SAY_LINES})"]
    words = sum(len(s.split()) for s in say)
    if words > MAX_SAY_WORDS:
        return None, notes + [f"{label} dropped: `Say` has {words} words (at most {MAX_SAY_WORDS})"]
    keys: list[str] = []
    for k in fields["keys"].split(","):
        k = " ".join(k.split()).lower()
        if k and k not in keys:
            keys.append(k)
    if not keys:
        return None, notes + [f"{label} dropped: `Keys:` lists no word"]
    who = (fields.get("who") or "any").strip().lower()
    if who not in WHO:
        return None, notes + [f"{label} dropped: `Who: {fields['who']}` is not one of any, me, them"]
    until = (fields.get("until") or "").strip().lower() or None
    if until not in (None, "number"):
        return None, notes + [f"{label} dropped: `Until: {fields['until']}` (only `number` is known)"]
    after_s = 0.0
    if fields.get("after", "").strip():
        m = _AFTER.match(fields["after"].strip())
        if not m:
            return None, notes + [f"{label} dropped: `After: {fields['after']}` is not a number of minutes like 5m"]
        after_s = float(m.group(1)) * 60.0
    rec = {"id": nid, "title": title or "Nudge", "when": " ".join(fields["when"].split()), "keys": keys, "who": who,
           "until": until, "after_s": after_s, "say": [" ".join(s.split()) for s in say], "ref": f"prep:L{header_no}"}
    return rec, notes


def parse_nudges(lines: list[str]) -> ParsedNudges:
    """Every nudge block of the note (`lines` as `note.splitlines()`). Pure: no I/O."""
    out = ParsedNudges()
    i = 0
    block = 0
    while i < len(lines):
        m = _HEADER.match(lines[i])
        if not m:
            i += 1
            continue
        block += 1
        end = _block_end(lines, i)
        out.lines.update(range(i + 1, end + 1))
        nid = f"n{block:03d}"
        body = [(n + 1, lines[n]) for n in range(i + 1, end)]
        rec, notes = _compile_block(nid, m.group(1), body, i + 1)
        out.warnings += notes
        if rec is not None:
            if len(out.records) >= MAX_NUDGES:
                out.warnings.append(f"nudge {nid} ({rec['title']}, {rec['ref']}) dropped: at most {MAX_NUDGES} nudges per note")
            else:
                out.records.append(rec)
        i = end
    out.records.sort(key=lambda r: r["id"])
    return out


def model_lines(lines: list[str], parsed: ParsedNudges | None = None) -> list[str]:
    """The note's lines as the prep model sees them: every nudge-block line blank, the numbering unchanged."""
    p = parsed if parsed is not None else parse_nudges(lines)
    if not p.lines:
        return list(lines)
    return ["" if n in p.lines else ln for n, ln in enumerate(lines, start=1)]


def model_note(note: str) -> str:
    """The note text with its nudge blocks blanked (same line count). A note without nudges is returned unchanged."""
    lines = note.splitlines()
    p = parse_nudges(lines)
    if not p.lines:
        return note
    text = "\n".join(model_lines(lines, p))
    return text + "\n" if note.endswith("\n") else text


def render_jsonl(records: list[dict]) -> str:
    return "".join(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n" for r in sorted(records, key=lambda r: r["id"]))


def write_nudges(folder: Path, records: list[dict]) -> Path | None:
    """Writes `<folder>/nudges.jsonl` (atomically). No records: nothing is written and None is returned, so a session
    without nudges looks exactly as before."""
    if not records:
        return None
    folder = Path(folder)
    path = folder / FILE_NAME
    tmp = folder / f".{FILE_NAME}.tmp"
    tmp.write_text(render_jsonl(records), encoding="utf-8")
    tmp.replace(path)
    return path


def review_lines(records: list[dict]) -> list[str]:
    """The `## Nudges` section of review.md (empty for no nudges)."""
    if not records:
        return []
    L = ["", "## Nudges", "",
         "Shown live, word for word, when the moment named in `When` comes up (a key word nominates it, a quick model check "
         "confirms it). Each one fires at most once per call."]
    for r in records:
        gates = [f"who {r['who']}"] + (["until a number is said"] if r.get("until") == "number" else []) + \
                ([f"not before {r['after_s'] / 60:g} min"] if r.get("after_s") else [])
        L.append("")
        L.append(f"### {r['id']} {r['title']} (`{r['ref']}`)")
        L.append(f"- When: {r['when']}")
        L.append(f"- Keys: {', '.join(r['keys'])} | {'; '.join(gates)}")
        L += [f"- SAY: {s}" for s in r["say"]]
    return L


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m verse_brain.prep.nudges",
                                 description="Compile the nudge blocks of a prep note into SESSION_DIR/nudges.jsonl (no model call).")
    ap.add_argument("note", type=Path)
    ap.add_argument("session_dir", type=Path)
    a = ap.parse_args(argv)
    note = a.note.expanduser()
    folder = a.session_dir.expanduser()
    if not (folder / "pack.md").is_file():
        print(f"not a session folder (no pack.md): {folder}", file=sys.stderr)
        return 2
    p = parse_nudges(note.read_text(encoding="utf-8").splitlines())
    for w in p.warnings:
        print(f"warning: {w}", file=sys.stderr)
    path = write_nudges(folder, p.records)
    if path is None:
        print("no nudge compiled; nothing written", file=sys.stderr)
        return 1
    print(f"wrote {len(p.records)} nudge(s) to {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
