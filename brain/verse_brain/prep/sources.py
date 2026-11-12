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
_HEX_KEY = re.compile(r"[0-9a-f]{7,40}")


def norm(s: str) -> str:
    return _WS.sub(" ", s.translate(_MAP)).strip().casefold()


# ---- numbers -----------------------------------------------------------------------------------------

_NUM = re.compile(r"\d[\d.,]*\d|\d")
_SUFFIX = re.compile(r"\s?([kKmM])\b")


_EN_THOUSANDS = re.compile(r"[1-9]\d{0,2}(,\d{3})+(\.\d+)?")  # 1,500 / 12,345,678.9
_EN_DECIMAL = re.compile(r"\d+\.\d+")
_DOTS_THOUSANDS = re.compile(r"[1-9]\d{0,2}(\.\d{3})+(,\d+)?")  # 1.500 / 12.345.678,9
_DOTS_DECIMAL = re.compile(r"\d+,\d+")
# Languages whose number format is known; any other code (or None) falls back to the guess in `_to_float`.
_POINT_DECIMAL = frozenset({"en"})
_COMMA_DECIMAL = frozenset({"it", "tr"})


def _to_float(tok: str, lang: str | None = None) -> float:
    """`lang` says how the number was written: in English `3.141` is a decimal and `3,141` thousands; in Italian and Turkish
    `3.141` is thousands and `3,141` a decimal. Without a known language a three-digit group is read as thousands
    unless it follows a leading zero ("0.125"); a token the language's own format does not describe is guessed the same way."""
    code = (lang or "").strip().lower()[:2]
    if code in _POINT_DECIMAL:
        if _EN_THOUSANDS.fullmatch(tok):
            return float(tok.replace(",", ""))
        if _EN_DECIMAL.fullmatch(tok):
            return float(tok)
    elif code in _COMMA_DECIMAL:
        if _DOTS_THOUSANDS.fullmatch(tok):
            return float(tok.replace(".", "").replace(",", "."))
        if _DOTS_DECIMAL.fullmatch(tok):
            return float(tok.replace(",", "."))
    if re.fullmatch(r"0[.,]\d{3}", tok):  # 0.125 is a decimal, never "0125" thousands
        return float(tok.replace(",", "."))
    if re.fullmatch(r"\d{1,3}([.,]\d{3})+", tok):  # thousands separators (1,500 / 1.500 / 12,345,678)
        return float(re.sub(r"[.,]", "", tok))
    if re.fullmatch(r"\d+[.,]\d+", tok):  # decimal comma or point
        return float(tok.replace(",", "."))
    return float(re.sub(r"[.,]", "", tok))


def numbers_in(text: str, lang: str | None = None) -> set[float]:
    out: set[float] = set()
    for m in _NUM.finditer(text):
        try:
            v = _to_float(m.group(), lang)
        except ValueError:
            continue
        out.add(v)
        sm = _SUFFIX.match(text, m.end())
        if sm:
            out.add(v * (1000 if sm.group(1).lower() == "k" else 1_000_000))
    return out


def significant_numbers(text: str, lang: str | None = None) -> set[float]:
    """Numbers that need support: two or more digits, or a decimal. Lone digits ("3 steps") are ignored."""
    out: set[float] = set()
    for m in _NUM.finditer(text):
        tok = m.group()
        digits = re.sub(r"\D", "", tok)
        if len(digits) < 2 and not re.search(r"[.,]\d", tok):
            continue
        try:
            v = _to_float(tok, lang)
        except ValueError:
            continue
        sm = _SUFFIX.match(text, m.end())
        out.add(v * (1000 if sm and sm.group(1).lower() == "k" else 1_000_000 if sm else 1))
    return out


def numbers_supported(text: str, quotes: list[str], lang: str | None = None) -> bool:
    """`lang` is the language the claim and its quotes are written in (see `_to_float`); None keeps the format-blind guess."""
    need = significant_numbers(text, lang)
    if not need:
        return True
    have: set[float] = set()
    for q in quotes:
        have |= numbers_in(q, lang)
    return all(any(abs(n - h) < 1e-9 for h in have) for n in need)


# ---- source book -------------------------------------------------------------------------------------


@dataclass
class Source:
    kind: str  # "prep" | "vault" | "commit"
    ref: str
    quote: str
    span: str = ""  # the document text the quote pieces matched (normalized); numbers are read from here, not from `quote`

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
            span = self.match(rec.text, quote) if rec else None
            if rec and span is not None:
                return Source("vault", f"vault:{rec.source}", q, span)
            return None
        c = self._commit(h)
        span = self.match(c.line() + " " + c.line_text(), quote) if c else None  # the line as shown to the model, or its parts
        if c and span is not None:
            return Source("commit", f"commit:{c.repo}@{c.hash}", q, span)
        return None

    def _commit(self, h: str):
        key = h.split(":", 1)[-1].strip().lower()
        if not _HEX_KEY.fullmatch(key):  # an empty or short key would prefix-match the first commit
            return None
        for ch, c in self.commits.items():
            if ch == key or ch.startswith(key) or key.startswith(ch):
                return c
        return None

    def _prep(self, low: str, quote: str) -> Source | None:
        pieces = self._pieces(quote)
        if not pieces:
            return None
        lines = [norm(x) for x in self.prep_lines]
        # every piece, in order, inside one line
        for i, ln in enumerate(lines, start=1):
            span = _in_order(ln, pieces)
            if span is not None:
                return Source("prep", f"prep:L{i}", quote, span[1])
        # quote spans a line break: a window of three lines, the first piece starting in its first line
        for i in range(len(lines)):
            span = _in_order(" ".join(lines[i : i + 3]), pieces)
            if span is not None and span[0] <= len(lines[i]):
                return Source("prep", f"prep:L{i + 1}", quote, span[1])
        return None

    @staticmethod
    def _strip_ellipsis(quote: str) -> list[str]:
        return [p.strip() for p in re.split(r"…|\.\.\.", quote) if p.strip()]

    def _pieces(self, quote: str) -> list[str]:
        """Normalized pieces of a quote split on ellipses. None is dropped: a short piece must be found too."""
        return [n for n in (norm(p) for p in self._strip_ellipsis(quote)) if n]

    def match(self, doc: str, quote: str) -> str | None:
        """The matched document text when every piece of the quote occurs in `doc`, in order; else None."""
        pieces = self._pieces(quote)
        found = _in_order(norm(doc), pieces) if pieces else None
        return found[1] if found else None

    def supports(self, doc: str, quote: str) -> bool:
        return self.match(doc, quote) is not None


def _in_order(doc: str, pieces: list[str]) -> tuple[int, str] | None:
    """(start of the first piece, the pieces as found, joined by a space) when all occur in order, never overlapping."""
    pos = 0
    first = -1
    for p in pieces:
        k = doc.find(p, pos)
        if k < 0:
            return None
        if first < 0:
            first = k
        pos = k + len(p)
    return first, " ".join(pieces)
