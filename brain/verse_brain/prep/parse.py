"""Parse the model's plain-text record blocks (@BANK / @FACT / @TERM ... @END) into raw items.

Plain text instead of structured outputs keeps one style across the app (spec 5.8). The parser is tolerant:
unknown lines outside a block are ignored, a block that never reaches @END (truncated output) is dropped and
counted, and continuation lines extend the previous text field.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

_KEY = re.compile(r"^(?P<key>lang|question|para\.[A-Za-z]{2,3}|opener|point|deep|kind|text|value|term|line|src)\s*:\s*(?P<val>.*)$")
_SRC = re.compile(r"^(?P<handle>\S+)\s*\|\s*(?P<quote>.+)$")
_OPEN = {"@BANK": "bank", "@FACT": "fact", "@TERM": "term"}
_QUOTES = "\"'“”‘’`"


@dataclass
class RawSrc:
    handle: str
    quote: str


@dataclass
class RawText:
    text: str
    srcs: list[RawSrc] = field(default_factory=list)


@dataclass
class RawBank:
    lang: str = ""
    question: str = ""
    paras: dict[str, list[str]] = field(default_factory=dict)
    opener: str = ""
    points: list[RawText] = field(default_factory=list)
    deep: RawText | None = None


@dataclass
class RawFact:
    kind: str = ""
    text: RawText = field(default_factory=lambda: RawText(""))
    value: str = ""


@dataclass
class RawTerm:
    term: str = ""
    line: RawText = field(default_factory=lambda: RawText(""))


@dataclass
class ParsedOutput:
    bank: list[RawBank] = field(default_factory=list)
    facts: list[RawFact] = field(default_factory=list)
    terms: list[RawTerm] = field(default_factory=list)
    incomplete_blocks: int = 0


def parse_src(val: str) -> RawSrc | None:
    m = _SRC.match(val.strip())
    if not m:
        return None
    quote = m["quote"].strip().strip(_QUOTES).strip()
    return RawSrc(handle=m["handle"].strip(), quote=quote) if quote else None


def parse_output(text: str) -> ParsedOutput:
    out = ParsedOutput()
    kind: str | None = None
    item: RawBank | RawFact | RawTerm | None = None
    last: RawText | None = None  # the text field a following `src:` / continuation line belongs to
    last_para: tuple[str, int] | None = None
    last_scalar: str | None = None  # name of the last scalar field (for continuation lines)

    def close(complete: bool) -> None:
        nonlocal kind, item, last, last_para, last_scalar
        if item is not None:
            if not complete:
                out.incomplete_blocks += 1
            elif isinstance(item, RawBank):
                out.bank.append(item)
            elif isinstance(item, RawFact):
                out.facts.append(item)
            else:
                out.terms.append(item)
        kind = item = last = last_para = last_scalar = None

    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        head = line.split()[0].upper()
        if head in _OPEN:
            close(complete=False)  # a new block while one is open means the previous one was cut off
            kind = _OPEN[head]
            item = {"bank": RawBank, "fact": RawFact, "term": RawTerm}[kind]()
            continue
        if head == "@END":
            close(complete=True)
            continue
        if item is None:
            continue
        m = _KEY.match(line)
        if not m:
            _continue(item, last, last_para, last_scalar, line)
            continue
        key, val = m["key"], m["val"].strip()
        last_para = None
        last_scalar = None
        if key == "src":
            s = parse_src(val)
            if s and last is not None:
                last.srcs.append(s)
            continue
        if isinstance(item, RawBank):
            if key == "lang":
                item.lang, last_scalar = val.lower(), "lang"
            elif key == "question":
                item.question, last_scalar = val, "question"
            elif key.startswith("para."):
                lang = key.split(".", 1)[1].lower()
                item.paras.setdefault(lang, []).append(val)
                last_para = (lang, len(item.paras[lang]) - 1)
            elif key == "opener":
                item.opener, last_scalar = val, "opener"
            elif key == "point":
                last = RawText(val)
                item.points.append(last)
            elif key == "deep":
                last = RawText(val)
                item.deep = last
        elif isinstance(item, RawFact):
            if key == "kind":
                item.kind, last_scalar = val.lower(), "kind"
            elif key == "text":
                item.text = last = RawText(val)
            elif key == "value":
                item.value, last_scalar = val, "value"
        elif isinstance(item, RawTerm):
            if key == "term":
                item.term, last_scalar = val, "term"
            elif key == "line":
                item.line = last = RawText(val)
    close(complete=False)  # EOF inside a block: truncated
    return out


def _continue(item, last: RawText | None, last_para, last_scalar, line: str) -> None:
    """A non-key line extends the previous text-bearing field."""
    if last_para is not None and isinstance(item, RawBank):
        lang, i = last_para
        item.paras[lang][i] = (item.paras[lang][i] + " " + line).strip()
    elif last_scalar and hasattr(item, last_scalar):
        setattr(item, last_scalar, (getattr(item, last_scalar) + " " + line).strip())
    elif last is not None:
        last.text = (last.text + " " + line).strip()
