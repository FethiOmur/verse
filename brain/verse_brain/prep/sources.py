"""Source documents and quote verification.

A source is only accepted when its handle resolves to a document we gave the model AND its quote is really
in that document (whitespace/case/markdown-insensitive). The stored `ref` is rewritten from what we verified
(for the prep note: the real line number), not from what the model claimed.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from .git_digest import Commit
from .vault import VaultRecord

MIN_QUOTE_CHARS = 10
MAX_QUOTE_CHARS = 200

_MAP = str.maketrans({
    "‘": "'", "’": "'", "“": '"', "”": '"', "–": "-", "—": "-", "−": "-",
    " ": " ", "*": "", "_": "", "`": "",
})
_WS = re.compile(r"\s+")


def norm(s: str) -> str:
    return _WS.sub(" ", s.translate(_MAP)).strip().casefold()


# ---- numbers -----------------------------------------------------------------------------------------

_NUM = re.compile(r"\d[\d.,]*\d|\d")
_SUFFIX = re.compile(r"\s?([kKmM])\b")


def _to_float(tok: str) -> float:
    if re.fullmatch(r"\d{1,3}([.,]\d{3})+", tok):  # thousands separators (1,500 / 1.500 / 12,345,678)
        return float(re.sub(r"[.,]", "", tok))
    if re.fullmatch(r"\d+[.,]\d+", tok):  # decimal comma or point
        return float(tok.replace(",", "."))
    return float(re.sub(r"[.,]", "", tok))


def numbers_in(text: str) -> set[float]:
    out: set[float] = set()
    for m in _NUM.finditer(text):
        try:
            v = _to_float(m.group())
        except ValueError:
            continue
        out.add(v)
        sm = _SUFFIX.match(text, m.end())
        if sm:
            out.add(v * (1000 if sm.group(1).lower() == "k" else 1_000_000))
    return out


def significant_numbers(text: str) -> set[float]:
    """Numbers that need support: two or more digits, or a decimal. Lone digits ("3 steps") are ignored."""
    out: set[float] = set()
    for m in _NUM.finditer(text):
        tok = m.group()
        digits = re.sub(r"\D", "", tok)
        if len(digits) < 2 and not re.search(r"[.,]\d", tok):
            continue
        try:
            v = _to_float(tok)
        except ValueError:
            continue
        sm = _SUFFIX.match(text, m.end())
        out.add(v * (1000 if sm and sm.group(1).lower() == "k" else 1_000_000 if sm else 1))
    return out


def numbers_supported(text: str, quotes: list[str]) -> bool:
    need = significant_numbers(text)
    if not need:
        return True
    have: set[float] = set()
    for q in quotes:
        have |= numbers_in(q)
    return all(any(abs(n - h) < 1e-9 for h in have) for n in need)


# ---- source book -------------------------------------------------------------------------------------


@dataclass
class Source:
    kind: str  # "prep" | "vault" | "commit"
    ref: str
    quote: str

    def as_dict(self) -> dict:
        return {"kind": self.kind, "ref": self.ref, "quote": self.quote}


@dataclass
class SourceBook:
    prep_lines: list[str]
    vault: dict[str, VaultRecord] = field(default_factory=dict)  # handle "V1" -> record
    commits: dict[str, Commit] = field(default_factory=dict)  # hash -> commit

    @property
    def prep_text(self) -> str:
        return "\n".join(self.prep_lines)

    # -- resolving ---------------------------------------------------------------------------------
    def resolve(self, handle: str, quote: str) -> Source | None:
        h = handle.strip().strip("[]()")
        quote = quote.strip()
        if len(norm(quote)) < MIN_QUOTE_CHARS:
            return None
        q = quote[:MAX_QUOTE_CHARS]
        low = h.lower()
        if low.startswith("prep"):
            return self._prep(low, q)
        if low.startswith("vault:") or re.fullmatch(r"v\d+", low):
            key = h.split(":", 1)[-1].upper()
            rec = self.vault.get(key)
            if rec and self.supports(rec.text, quote):
                return Source("vault", f"vault:{rec.source}", q)
            return None
        c = self._commit(h)
        if c and self.supports(c.line() + " " + c.line_text(), quote):  # the line as shown to the model, or its parts
            return Source("commit", f"commit:{c.repo}@{c.hash}", q)
        return None

    def _commit(self, h: str):
        key = h.split(":", 1)[-1].strip().lower()
        for ch, c in self.commits.items():
            if ch == key or ch.startswith(key) or key.startswith(ch):
                return c
        return None

    def _prep(self, low: str, quote: str) -> Source | None:
        m = re.search(r"(\d+)", low)
        claimed = int(m.group(1)) if m else 1
        nq = self._strip_ellipsis(quote)
        pieces = [norm(p) for p in nq if len(norm(p)) >= 4]
        if not pieces:
            return None
        lines = [norm(x) for x in self.prep_lines]
        # single-line match -> exact line number
        for i, ln in enumerate(lines, start=1):
            if all(p in ln for p in pieces):
                return Source("prep", f"prep:L{i}", quote)
        # quote spans a line break
        joined = " ".join(lines)
        if all(p in joined for p in pieces):
            first = pieces[0]
            for i in range(len(lines)):
                if first in " ".join(lines[i : i + 3]):
                    return Source("prep", f"prep:L{i + 1}", quote)
            return Source("prep", f"prep:L{min(max(claimed, 1), len(lines) or 1)}", quote)
        return None

    @staticmethod
    def _strip_ellipsis(quote: str) -> list[str]:
        return [p.strip() for p in re.split(r"…|\.\.\.", quote) if p.strip()]

    def supports(self, doc: str, quote: str) -> bool:
        pieces = [norm(p) for p in self._strip_ellipsis(quote) if len(norm(p)) >= 4]
        nd = norm(doc)
        return bool(pieces) and all(p in nd for p in pieces)
