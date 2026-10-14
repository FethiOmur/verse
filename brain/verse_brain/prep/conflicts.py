"""Contradiction check (plan F1): find figures that differ between sources, so none is presented as certain.

Deterministic, no model call. Every source document (prep note lines, vault records, commit subjects, vault
snippets) is split into sentences; in each sentence the extractor finds money, percentages, durations, counts,
dates and role-holders ("hiring manager is X"), normalises each to a comparable value, and records the words
around it as a context. Two mentions from different sentences are compared only when they are the same kind of
figure (same currency / unit / role) and their contexts say they are about the same thing. Comparable mentions
whose values do not agree become a conflict; connected disagreements form one cluster.

Agreement rules (they keep the false-positive rate low, a missed conflict costs less than a false alarm because
the review page is read by a human, but a false alarm on every figure would train Alex to ignore the page):
- the same value in another format agrees: `€42K` = `42,000 EUR` = `EUR 42.000`; `22 October 2026` = `2026-10-22`;
  `14%` = `14 percent` = `%14`; `10 weeks` = `70 days`;
- dates agree when their spans overlap (`Q1 2027` and `March 2027` agree, `Q1 2027` and `Q2 2027` do not);
- a range agrees with a point inside it; a hedge ("about", "~") widens a figure by 5 %;
- `gross` against `net`, or two different pay periods, are different quantities and are never compared;
- two figures in the same sentence are different things ("96.4 percent for totals and 91 percent for line items");
  figures qualified by a different trailing "for X" are different things as well;
- a note that carries its own date (daily log, dated folder, commit) is a snapshot: two snapshots of the same kind
  from different days are never compared, because a figure may legitimately have moved between them;
- dates that only label a document are not claims and are skipped: titles ("# Daily log: 2026-09-02"), metadata
  ("**Date:** 2026-09-25", "Updated: ..."), and citations next to a file name or URL;
- a single shared word only links two figures when both contexts are short (at most two words each).

These rules came from a live run on real vault text, where the first version raised six false conflicts out of six.

Known limits (unconfirmed recall): an entity is identified by the words next to the figure, so a pair whose
wording shares nothing ("headcount" against "team size") is not paired; day-month dates without a year are not
read; roles are matched against a fixed list of one-holder titles (`ROLE` below).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date
from typing import TYPE_CHECKING, Iterable

from .sources import SourceBook, norm, numbers_in

if TYPE_CHECKING:  # pragma: no cover
    from .ground import Grounded

# ---------------------------------------------------------------------------------------------- vocabulary

STOP = frozenset("""
a an the of to in on at for from by with and or but is are was were be been being has have had will would shall
should can could may might this that these those it its their his her our your my we they he she you i as than
then so such not no if per about around approximately approx roughly circa nearly almost over under up down out
into onto off also just only still already each every any all some more most less least very much many how what
which who whom when where why now currently today there here after before until since because while during
into via vs
il lo la i gli le un uno una di da con su tra fra e ed o ma che sono era erano ha hanno circa
ve ile bir bu su icin de da ki mi
plan plans planned planning move moves moved moving slip slips slipped slipping target targets targeted expect
expects expected set sets raise raised raises start starts started begin begins began will
reminder note notes update updated fyi todo important warning
gross net lordo netto brutto brut month months monthly year years yearly annual annually week weekly day daily
eur usd gbp try euro euros dollar dollars pound pounds
""".split())
HEDGES = frozenset("about around approximately approx roughly circa nearly almost ca yaklasik yaklaşık".split())
WEAK_AFTER_PREP = frozenset("for of on in per from at across".split())
# words after which the rest of a clause explains the figure instead of qualifying it
CUT_AFTER = frozenset("because since while which that but so although though when if until after before per where whereas as".split())

MONTHS = {
    **{m: i for i, ms in enumerate(
        ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november",
         "december"], 1) for m in (ms, ms[:3])},
    "sept": 9,
    **{m: i for i, m in enumerate(
        ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre",
         "novembre", "dicembre"], 1)},
    **{m: i for i, m in enumerate(
        ["ocak", "şubat", "mart", "nisan", "mayıs", "haziran", "temmuz", "ağustos", "eylül", "ekim", "kasım", "aralık"], 1)},
}
_MONTH_RE = "|".join(sorted((re.escape(m) for m in MONTHS), key=len, reverse=True))

CURRENCY = {"€": "EUR", "eur": "EUR", "euro": "EUR", "euros": "EUR", "$": "USD", "usd": "USD", "dollar": "USD",
            "dollars": "USD", "£": "GBP", "gbp": "GBP", "pound": "GBP", "pounds": "GBP", "₺": "TRY", "try": "TRY",
            "tl": "TRY", "lira": "TRY", "lire": "TRY"}
MULT = {"k": 1e3, "thousand": 1e3, "mila": 1e3, "bin": 1e3, "m": 1e6, "mn": 1e6, "mln": 1e6, "million": 1e6,
        "milioni": 1e6, "milyon": 1e6, "bn": 1e9, "billion": 1e9}
# unit word -> (family, factor): durations convert inside a family and are never compared across families
TIME = {"second": ("s", 1), "sec": ("s", 1), "saniye": ("s", 1), "minute": ("s", 60), "min": ("s", 60), "minuto": ("s", 60),
        "minuti": ("s", 60), "dakika": ("s", 60), "hour": ("s", 3600), "hr": ("s", 3600), "ora": ("s", 3600),
        "ore": ("s", 3600), "saat": ("s", 3600), "day": ("s", 86400), "giorno": ("s", 86400), "giorni": ("s", 86400),
        "gün": ("s", 86400), "week": ("s", 604800), "settimana": ("s", 604800), "settimane": ("s", 604800),
        "hafta": ("s", 604800), "month": ("mo", 1), "mese": ("mo", 1), "mesi": ("mo", 1), "ay": ("mo", 1),
        "year": ("mo", 12), "yr": ("mo", 12), "anno": ("mo", 12), "anni": ("mo", 12), "yıl": ("mo", 12)}
TIME_NAME = {"sec": "second", "min": "minute", "hr": "hour", "yr": "year"}
PERIODS = {"month": "month", "monthly": "month", "mese": "month", "mensile": "month", "aylık": "month",
           "year": "year", "yearly": "year", "annual": "year", "annually": "year", "annum": "year", "anno": "year",
           "annuo": "year", "annua": "year", "yıllık": "year", "week": "week", "weekly": "week", "day": "day",
           "daily": "day", "hour": "hour", "hourly": "hour"}

# one-holder titles; extend as needed. Generic "manager", "engineer", "director" alone are deliberately absent.
_ROLE = (r"(?:(?i:hiring manager|tech(?:nical)? lead|team lead|engineering manager|product owner|recruiter|"
         r"CEO|CTO|CFO|COO|CPO|CMO|CIO|(?:VP|vice president)(?:\s+of)?\s+(?=[A-Z])|head of\s+(?=[A-Z])|"
         r"director of\s+(?=[A-Z]))(?:[A-Z][\w&-]*)?)")
_UP = "A-ZÀ-ÖØ-ÞİŞĞÜÖÇ"
_NAME = rf"[{_UP}][^\W\d_]+(?:['’-][^\W\d_]+)*(?:\s+[{_UP}][^\W\d_]+(?:['’-][^\W\d_]+)*){{1,2}}"

# ---------------------------------------------------------------------------------------------- numbers

_AMT = r"\d{1,3}(?:[.,]\d{3})+(?:[.,]\d+)?|\d+(?:[.,]\d+)?"
_SUF = r"(?:\s?(?:thousand|million|milioni|milyon|billion|mila|mln|bin|mn|bn|k|m)(?![^\W\d_]))"
_CUR = (r"(?P<cur>€|\$|£|₺|(?<![^\W\d_])(?:EUR|USD|GBP|TRY|TL|euros?|dollars?|pounds?|lira|lire)(?![^\W\d_]))")
_FLAGS = re.I | re.U


_RNG = rf"(?:\s?(?:to|and|a|ile|-|–|—)\s?(?P<a2>{_AMT})(?P<s2>{_SUF})?)?"  # optional second amount of a range


_MONEY_PRE = re.compile(rf"{_CUR}\s?(?P<a1>{_AMT})(?P<s1>{_SUF})?{_RNG}", _FLAGS)
_MONEY_POST = re.compile(rf"(?<![\w.,])(?P<a1>{_AMT})(?P<s1>{_SUF})?{_RNG}\s?{_CUR}", _FLAGS)
_PERCENT = re.compile(
    rf"(?<![\w.,])(?P<a1>{_AMT})(?:\s?(?:to|-|–|—)\s?(?P<a2>{_AMT}))?\s?(?:%|percento|percent|per\s?cent|pct)(?![^\W\d_])"
    rf"|%\s?(?P<a3>\d+(?:[.,]\d+)?)", _FLAGS)
_COUNT = re.compile(
    rf"(?<![\w.,/-])(?P<a1>{_AMT})(?P<s1>{_SUF})?(?:\s?(?:to|-|–|—)\s?(?P<a2>{_AMT})(?P<s2>{_SUF})?)?[\s-](?P<unit>[^\W\d_]+)",
    _FLAGS)

_ISO = re.compile(r"(?<![\d./-])(?P<y>\d{4})-(?P<m>\d{2})-(?P<d>\d{2})(?![\d-])")
_DMY = re.compile(r"(?<![\d./-])(?P<d>\d{1,2})[/.](?P<m>\d{1,2})[/.](?P<y>\d{4})(?![\d])")
_D_MON_Y = re.compile(rf"(?<![\d.,])(?P<d>\d{{1,2}})(?:st|nd|rd|th|\.)?\s+(?:of\s+)?(?P<mon>{_MONTH_RE})\.?,?\s+(?P<y>\d{{4}})(?!\d)", _FLAGS)
_MON_D_Y = re.compile(rf"(?<![^\W\d_])(?P<mon>{_MONTH_RE})\.?\s+(?P<d>\d{{1,2}})(?:st|nd|rd|th)?,?\s+(?P<y>\d{{4}})(?!\d)", _FLAGS)
_MON_Y = re.compile(rf"(?<![^\W\d_])(?P<mon>{_MONTH_RE})\.?,?\s+(?P<y>\d{{4}})(?!\d)", _FLAGS)
_QUARTER = re.compile(r"(?<![^\W\d_])Q(?P<q>[1-4])\s?[/,\-]?\s?(?P<y>\d{4})(?!\d)|(?<!\d)(?P<y2>\d{4})\s?[/,\-]?\s?Q(?P<q2>[1-4])(?![\d\w])", re.U)
_HALF = re.compile(r"(?<![^\W\d_])H(?P<h>[12])\s?[/,\-]?\s?(?P<y>\d{4})(?!\d)", re.U)
_YEAR_WORDS = r"(?:in|by|since|until|from|during|before|after|entro|dal|nel|dopo|prima|FY)"
_YEAR = re.compile(rf"(?<![^\W\d_])(?:{_YEAR_WORDS})\s+(?P<y>(?:19|20)\d{{2}})(?![\d.,]\d)(?!\s?(?:{_AMT}))", _FLAGS)

_GROSS = re.compile(r"(?<![^\W\d_])(gross|lordo|brutto|brüt|brut)(?![^\W\d_])", _FLAGS)
_NET = re.compile(r"(?<![^\W\d_])(net|netto|netti)(?![^\W\d_])", _FLAGS)
_PERIOD = re.compile(
    r"(?:\bper\s+|\ba\s+|/\s?|\bal\s+|\bogni\s+)(?P<p1>month|year|annum|week|day|hour|mese|anno)\b|"
    r"\b(?P<p2>monthly|yearly|annual(?:ly)?|weekly|daily|hourly|mensile|annuo|annua)\b|(?P<p3>aylık|yıllık)", _FLAGS)
_WORD = re.compile(r"[^\W\d_]+(?:['’-][^\W\d_]+)*", re.U)
_BULLET = re.compile(r"^\s*(?:[-*•+]|\d+[.)])\s+")
_SENT_SPLIT = re.compile(r"(?<=[.!?])\s+(?=[A-Z\"“(])|;\s+")
_CLAUSE_SPLIT = re.compile(r",\s+")

MAX_QUOTE = 200


def _num(tok: str) -> float:
    if "." in tok and "," in tok:
        dec = "." if tok.rfind(".") > tok.rfind(",") else ","
        return float(tok.replace("," if dec == "." else ".", "").replace(dec, "."))
    if re.fullmatch(r"\d{1,3}([.,]\d{3})+", tok):
        return float(re.sub(r"[.,]", "", tok))
    if re.fullmatch(r"\d+[.,]\d+", tok):
        return float(tok.replace(",", "."))
    return float(re.sub(r"[.,]", "", tok))


def _mult(s: str | None) -> float:
    return MULT.get(s.strip().casefold(), 1.0) if s else 1.0


def _fmt(x: float) -> str:
    return f"{int(round(x)):,}" if abs(x - round(x)) < 1e-9 else f"{x:,.2f}".rstrip("0").rstrip(".")


def _stem(w: str) -> str:
    w = w.casefold()
    if len(w) > 4 and w.endswith("ies"):
        return w[:-3] + "y"
    if len(w) > 3 and w.endswith("s") and not w.endswith("ss"):
        return w[:-1]
    return w


def _span(y: int, m1: int = 1, d1: int = 1, m2: int = 12, d2: int | None = None) -> tuple[int, int] | None:
    try:
        last = d2 if d2 is not None else (date(y + (m2 == 12), m2 % 12 + 1, 1).toordinal() - date(y, m2, 1).toordinal())
        return date(y, m1, d1).toordinal(), date(y, m2, last).toordinal()
    except ValueError:
        return None


# ---------------------------------------------------------------------------------------------- mentions


@dataclass(frozen=True)
class Mention:
    kind: str  # money | percent | count | duration | date | role
    src_kind: str  # prep | vault | commit
    ref: str
    quote: str  # the sentence (or a window of it) the figure sits in; verbatim text of the document
    surface: str  # the figure as written
    display: str  # canonical text of the value, equal for equal values: "EUR 42,000", "2027-Q1", "Ingrid Solberg"
    lo: float  # normalised value range (dates: day ordinals)
    hi: float
    raw: tuple[float, ...]  # the figure as written, scaled by k/m (used to match model facts)
    unit: str  # currency / unit family / noun / role key
    before: frozenset[str]
    after: frozenset[str]
    words: tuple[str, ...]  # context words in reading order, for labels
    after_prep: str
    approx: bool
    gross_net: str
    period: str
    sent: tuple[str, int, int]  # (ref, unit index, sentence index): same-sentence figures are never compared
    tags: frozenset[str] = frozenset()  # dates: "q1", "october"; roles: name tokens
    order: int = 0
    snap: str = ""  # date of a time-stamped source (dated note path, commit date); "" for undated sources

    @property
    def sort_key(self):
        prio = {"prep": 0, "vault": 1, "commit": 2}[self.src_kind]
        m = re.search(r"L(\d+)$", self.ref)
        return prio, int(m.group(1)) if m else 0, self.ref, self.order, self.display

    def entry(self) -> dict:
        return {"value": self.display, "source_ref": self.ref, "quote": self.quote}


def _context(sentence: str, start: int, end: int) -> tuple[frozenset[str], frozenset[str], tuple[str, ...], str, str]:
    """Words before and after the figure inside its comma clause. Returns (before, after, words, after_prep, clause)."""
    cs = 0
    for m in _CLAUSE_SPLIT.finditer(sentence, 0, start):
        cs = m.end()
    ce = len(sentence)
    m = _CLAUSE_SPLIT.search(sentence, end)
    if m:
        ce = m.start()
    before_words = [w for w in _WORD.findall(sentence[cs:start])]
    after_words = []
    for w in _WORD.findall(sentence[end:ce]):
        if w.casefold() in CUT_AFTER:
            break
        after_words.append(w)
    bw = [w for w in before_words if w.casefold() not in STOP and len(w) > 1][-5:]
    aw_all = [w for w in after_words if w.casefold() not in STOP and len(w) > 1][:3]
    prep = after_words[0].casefold() if after_words and after_words[0].casefold() in WEAK_AFTER_PREP else ""
    words = tuple(w.casefold() for w in bw + aw_all)
    return frozenset(_stem(w) for w in bw), frozenset(_stem(w) for w in aw_all), words, prep, sentence[cs:ce]


def _qualifiers(clause: str) -> tuple[str, str]:
    g, n = bool(_GROSS.search(clause)), bool(_NET.search(clause))
    gn = "gross" if g and not n else "net" if n and not g else ""
    pm = _PERIOD.search(clause)
    period = PERIODS.get((pm.group("p1") or pm.group("p2") or pm.group("p3") or "").casefold(), "") if pm else ""
    return gn, period


def _quote(sentence: str, start: int, end: int) -> str:
    s = sentence.strip()
    if len(s) <= MAX_QUOTE:
        return s
    a = max(0, start - 90)
    b = min(len(sentence), end + 90)
    return sentence[a:b].strip()


_INLINE_HEAD = re.compile(r"(?:(?<=\s)|^)#{1,6}\s+")


def _units(text: str, per_line: bool) -> list[tuple[str, bool]]:
    """(unit, is_heading). Bullets, headings and blank-line separated paragraphs are separate units, soft-wrapped lines
    are joined (vault text), and inline `##` markers of flattened markdown start a new heading unit."""
    raw_units: list[tuple[str, bool]] = []
    buf: list[str] = []

    def flush() -> None:
        if buf:
            raw_units.append((" ".join(buf), False))
            buf.clear()

    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            flush()
        elif per_line or _BULLET.match(raw) or line.startswith(("#", "|", ">")):
            flush()
            raw_units.append((_BULLET.sub("", raw).strip().lstrip("#> ").strip(), line.startswith("#")))
        else:
            buf.append(line)
    flush()
    out: list[tuple[str, bool]] = []
    for unit, heading in raw_units:
        pieces = _INLINE_HEAD.split(unit)
        out.append((pieces[0], heading))
        out += [(p, True) for p in pieces[1:]]
    return [(u, h) for u, h in out if u.strip()]


def mentions_in(text: str, ref: str, src_kind: str, *, per_line: bool = False, snap: str = "") -> list[Mention]:
    out: list[Mention] = []
    for ui, (unit, heading) in enumerate(_units(text, per_line)):
        for si, sent in enumerate(_SENT_SPLIT.split(unit)):
            if sent.strip():
                out += _sentence_mentions(sent, ref, src_kind, (ref, ui, si), len(out), heading and si == 0 and src_kind != "prep", snap)
    return out


def _approx(sentence: str, start: int) -> bool:
    head = sentence[:start].rstrip()
    if head.endswith("~"):
        return True
    ws = _WORD.findall(head)[-2:]
    return any(w.casefold() in HEDGES for w in ws)


_META_BOLD = re.compile(r"\*\*\s*(?:tarih|date|created|updated|modified|kaynak|source|dayanak|g[üu]ncelleme|olu[şs]turma)\s*:?\s*\*\*:?\s*$", re.I)
_META_PLAIN = re.compile(r"(?:created|updated|modified|last updated|g[üu]ncellendi|olu[şs]turuldu|kaynak|source|as of)\s*[:\-–—]?\s*$", re.I)
_CITATION = re.compile(r"\.(?:md|json|txt|csv|pdf)\b|https?://", re.I)


def _label_date(sent: str, a: int, b: int, heading: bool) -> bool:
    """A date that names or stamps a document (title, metadata field, citation) is not a claim about the world."""
    if heading and len(_WORD.findall(sent[:a])) <= 8:
        return True
    before = sent[max(0, a - 40):a]
    if _META_BOLD.search(before) or _META_PLAIN.search(before):
        return True
    return bool(_CITATION.search(sent[max(0, a - 60):b + 60]))


def _sentence_mentions(sent: str, ref: str, src_kind: str, sid: tuple[str, int, int], base: int, heading: bool = False,
                       snap: str = "") -> list[Mention]:
    found: list[Mention] = []
    used: list[tuple[int, int]] = []

    def free(a: int, b: int) -> bool:
        return all(b <= s or a >= e for s, e in used)

    def add(kind, a, b, display, lo, hi, raw, unit, tags=frozenset()):
        if kind != "role":
            used.append((a, b))
        before, after, words, prep, clause = _context(sent, a, b)
        gn, period = _qualifiers(clause) if kind in ("money", "count", "percent") else ("", "")
        found.append(Mention(kind, src_kind, ref, _quote(sent, a, b), sent[a:b].strip(), display, lo, hi, tuple(raw), unit,
                             before, after, words, prep, _approx(sent, a), gn, period, sid, frozenset(tags), base + a, snap))

    def span_of(y, m1=1, d1=1, m2=12, d2=None):
        return _span(int(y), m1, d1, m2, d2)

    # dates ------------------------------------------------------------------------------------
    def date_hit(m, sp, display, tags=()):
        if sp and free(m.start(), m.end()):
            if _label_date(sent, m.start(), m.end(), heading):
                used.append((m.start(), m.end()))  # consumed, but not a claim
                return
            add("date", m.start(), m.end(), display, sp[0], sp[1], (), "", tags)

    for m in _ISO.finditer(sent):
        date_hit(m, span_of(m["y"], int(m["m"]), int(m["d"]), int(m["m"]), int(m["d"])), f"{m['y']}-{m['m']}-{m['d']}")
    for m in _DMY.finditer(sent):
        mo, d = int(m["m"]), int(m["d"])
        date_hit(m, span_of(m["y"], mo, d, mo, d), f"{m['y']}-{mo:02d}-{d:02d}")
    for m in _D_MON_Y.finditer(sent):
        mo, d = MONTHS[m["mon"].casefold()], int(m["d"])
        date_hit(m, span_of(m["y"], mo, d, mo, d), f"{m['y']}-{mo:02d}-{d:02d}")
    for m in _MON_D_Y.finditer(sent):
        mo, d = MONTHS[m["mon"].casefold()], int(m["d"])
        date_hit(m, span_of(m["y"], mo, d, mo, d), f"{m['y']}-{mo:02d}-{d:02d}")
    for m in _MON_Y.finditer(sent):
        mo = MONTHS[m["mon"].casefold()]
        date_hit(m, span_of(m["y"], mo, 1, mo), f"{m['y']}-{mo:02d}", (m["mon"].casefold(),))
    for m in _QUARTER.finditer(sent):
        q, y = int(m["q"] or m["q2"]), m["y"] or m["y2"]
        date_hit(m, span_of(y, 3 * q - 2, 1, 3 * q), f"{y}-Q{q}", (f"q{q}",))
    for m in _HALF.finditer(sent):
        h = int(m["h"])
        date_hit(m, span_of(m["y"], 6 * h - 5, 1, 6 * h), f"{m['y']}-H{h}", (f"h{h}",))
    for m in _YEAR.finditer(sent):
        a, b = m.start("y"), m.end("y")
        if free(a, b):
            sp = span_of(m["y"])
            if sp and not _label_date(sent, a, b, heading):
                add("date", a, b, m["y"], sp[0], sp[1], (), "", ())

    # money ------------------------------------------------------------------------------------
    def money(m):
        if not free(m.start(), m.end()):
            return
        cur = CURRENCY.get(m["cur"].casefold().strip(), "")
        s1, s2 = m["s1"], m["s2"]
        a1 = _num(m["a1"]) * _mult(s1)
        a2 = _num(m["a2"]) * _mult(s2) if m["a2"] else None
        if a2 is not None and s1 is None and s2 is not None and _num(m["a1"]) < 1000:  # "€40-45K"
            a1 = _num(m["a1"]) * _mult(s2)
        lo, hi = (a1, a1) if a2 is None else (min(a1, a2), max(a1, a2))
        disp = f"{cur} {_fmt(lo)}" + (f"-{_fmt(hi)}" if hi != lo else "")
        add("money", m.start(), m.end(), disp, lo, hi, (lo, hi) if hi != lo else (lo,), cur)

    for m in _MONEY_PRE.finditer(sent):
        money(m)
    for m in _MONEY_POST.finditer(sent):
        money(m)

    # percent ----------------------------------------------------------------------------------
    for m in _PERCENT.finditer(sent):
        if not free(m.start(), m.end()):
            continue
        a1 = _num(m["a1"] or m["a3"])
        a2 = _num(m["a2"]) if m["a2"] else a1
        lo, hi = min(a1, a2), max(a1, a2)
        add("percent", m.start(), m.end(), f"{_fmt(lo)}%" + (f"-{_fmt(hi)}%" if hi != lo else ""), lo, hi,
            (lo, hi) if hi != lo else (lo,), "%")

    # durations and counts ---------------------------------------------------------------------
    for m in _COUNT.finditer(sent):
        if not free(m.start(), m.end()):
            continue
        unit_w = m["unit"].casefold()
        if unit_w in STOP or unit_w in MONTHS or unit_w in CURRENCY or unit_w in ("to", "and", "or"):
            continue
        tok = m["a1"]
        if re.fullmatch(r"(?:19|20)\d{2}", tok) and not m["s1"]:
            continue  # a bare year, not a count
        a1 = _num(tok) * _mult(m["s1"])
        a2 = _num(m["a2"]) * _mult(m["s2"] or m["s1"]) if m["a2"] else a1
        lo, hi = min(a1, a2), max(a1, a2)
        t = TIME.get(unit_w) or TIME.get(unit_w.rstrip("s"))
        end = m.end()
        if t:
            fam, f = t
            u = _stem(TIME_NAME.get(unit_w, unit_w))
            add("duration", m.start(), end, f"{_fmt(lo)}{'-' + _fmt(hi) if hi != lo else ''} {u}{'' if lo == hi == 1 else 's'}", lo * f, hi * f,
                (lo, hi) if hi != lo else (lo,), fam)
        else:
            u = _stem(unit_w)
            plural = "" if (lo == hi == 1) or u in ("people", "staff") else "s"
            add("count", m.start(), end, f"{_fmt(lo)}{'-' + _fmt(hi) if hi != lo else ''} {u}{plural}", lo, hi,
                (lo, hi) if hi != lo else (lo,), f"n:{u}")

    # role holders -----------------------------------------------------------------------------
    for role, name, a, b in _roles(sent):
        add("role", a, b, re.sub(r"\s+", " ", name), 0.0, 0.0, (), role, set(norm(name).split()))
    return found


def _role_key(r: str) -> str:
    k = re.sub(r"\s+", " ", r.strip().casefold())
    k = re.sub(r"^technical lead$", "tech lead", k)
    k = re.sub(r"^vice president", "vp", k)
    return re.sub(r"\b(of|the)\b\s*", "", k).strip()


def _roles(sent: str) -> list[tuple[str, str, int, int]]:
    out: list[tuple[str, str, int, int]] = []
    role_re = re.compile(_ROLE)
    # Name (role, role)
    for m in re.finditer(rf"(?P<name>{_NAME})\s*\((?P<inner>[^)]*)\)", sent):
        if role_re.match(m["name"]):
            continue
        for r in role_re.finditer(m["inner"]):
            out.append((_role_key(r.group()), m["name"], m.start(), m.end()))
    # Name, the role / Name is the role
    for m in re.finditer(rf"(?P<name>{_NAME})(?:,\s*|\s+(?:is|was|as|will be)\s+)(?:the\s+|our\s+|their\s+)?(?P<role>{_ROLE})", sent):
        if role_re.match(m["name"]):
            continue
        out.append((_role_key(m["role"]), m["name"], m.start(), m.end()))
    # role is Name / role: Name / role Name
    for m in re.finditer(rf"(?P<role>{_ROLE})\s*(?:\s(?:is|was|=)\s|:\s*|[-–—]\s+|\s+)(?P<name>{_NAME})", sent):
        if role_re.match(m["name"]):  # "hiring manager VP Engineering ..." is a title, not a name
            continue
        out.append((_role_key(m["role"]), m["name"], m.start(), m.end()))
    seen: set[tuple[str, str]] = set()
    uniq = []
    for r, n, a, b in out:
        if (r, norm(n)) not in seen:
            seen.add((r, norm(n)))
            uniq.append((r, n, a, b))
    return uniq


# ---------------------------------------------------------------------------------------------- comparing


def _comparable(a: Mention, b: Mention) -> bool:
    if a.kind != b.kind or a.sent == b.sent or a.unit != b.unit:
        return False
    if a.kind == "role":
        return True
    if a.snap and b.snap and a.snap != b.snap and a.src_kind == b.src_kind:
        return False  # two dated notes (or commits) of the same kind: the figure may have moved between the days
    if a.gross_net and b.gross_net and a.gross_net != b.gross_net:
        return False
    if a.period and b.period and a.period != b.period:
        return False
    if a.after_prep and a.after_prep == b.after_prep and a.after and b.after and not (a.after & b.after):
        return False  # "... for totals" against "... for line items": two different things
    ca, cb = a.before | a.after, b.before | b.after
    inter = ca & cb
    if not inter:
        return False
    if len(inter) == 1 and max(len(ca), len(cb)) > 2:
        return False  # one shared word in a long context is too weak a link (e.g. "duration" in two unrelated lines)
    return len(inter) / min(len(ca), len(cb)) >= 0.5


def _agree(a: Mention, b: Mention) -> bool:
    if a.kind == "role":
        ta, tb = a.tags, b.tags
        return ta <= tb or tb <= ta
    if a.kind == "date":
        return a.lo <= b.hi and b.lo <= a.hi
    ta = 0.05 * max(abs(a.lo), abs(a.hi)) if (a.approx or b.approx) else max(abs(a.hi), abs(b.hi), 1.0) * 1e-9
    tb = 0.05 * max(abs(b.lo), abs(b.hi)) if (a.approx or b.approx) else 0.0
    return a.lo - ta <= b.hi + tb and b.lo - tb <= a.hi + ta


@dataclass
class Conflict:
    id: str
    kind: str  # fact kind: number | date | name
    label: str
    sides: list[Mention]
    fact_ids: list[str] = field(default_factory=list)  # facts.jsonl records that carry this conflict (first = primary)
    bank_hits: list[tuple[str, str]] = field(default_factory=list)  # (bank id, "point 2" | "deep")

    @property
    def entries(self) -> list[dict]:
        seen: set[tuple[str, str, str]] = set()
        out = []
        for s in sorted(self.sides, key=lambda m: m.sort_key):
            e = s.entry()
            k = (e["value"], e["source_ref"], norm(e["quote"]))
            if k not in seen:
                seen.add(k)
                out.append(e)
        return out


def conflict_phrase(entries: list[dict]) -> str:
    """'conflicting in sources: A (ref, ref) vs B (ref)': one group per distinct value, refs in source order."""
    groups: dict[str, list[str]] = {}
    for e in entries:
        refs = groups.setdefault(e["value"], [])
        if e["source_ref"] not in refs:
            refs.append(e["source_ref"])
    return "conflicting in sources: " + " vs ".join(f"{v} ({', '.join(r)})" for v, r in groups.items())


_PATH_DATE = re.compile(r"(?<!\d)(\d{4}-\d{2}-\d{2})(?!\d)")


def _docs(book: SourceBook, extra: Iterable[tuple[str, str]]) -> list[tuple[str, str, str, bool, str]]:
    """(src_kind, ref, text, per_line, snapshot date)."""
    docs: list[tuple[str, str, str, bool, str]] = []
    for i, ln in enumerate(book.prep_lines, start=1):
        if ln.strip():
            docs.append(("prep", f"prep:L{i}", ln, True, ""))
    for h in sorted(book.vault, key=lambda x: (len(x), x)):
        rec = book.vault[h]
        m = _PATH_DATE.search(rec.source)
        docs.append(("vault", f"vault:{rec.source}", rec.text, False, m.group(1) if m else ""))
    for _h, c in sorted(book.commits.items()):
        docs.append(("commit", f"commit:{c.repo}@{c.hash}", c.subject, True, c.date))  # the header date is metadata
    for ref, text in extra:
        m = _PATH_DATE.search(ref)
        docs.append(("vault", ref, text, False, m.group(1) if m else ""))
    return docs


def find_conflicts(book: SourceBook, extra: Iterable[tuple[str, str]] = ()) -> list[Conflict]:
    """Conflict clusters in the sources the model saw, plus `extra` (ref, text) vault snippets. Deterministic."""
    ms: list[Mention] = []
    seen: set[tuple[str, str, str, str, str]] = set()
    for src_kind, ref, text, per_line, snap in _docs(book, extra):
        for m in mentions_in(text, ref, src_kind, per_line=per_line, snap=snap):
            k = (m.kind, m.ref, norm(m.quote), m.display, m.unit)
            if k not in seen:
                seen.add(k)
                ms.append(m)
    ms.sort(key=lambda m: m.sort_key)
    parent = list(range(len(ms)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    in_conflict: set[int] = set()
    for i in range(len(ms)):
        for j in range(i + 1, len(ms)):
            a, b = ms[i], ms[j]
            if _comparable(a, b) and not _agree(a, b):
                parent[find(j)] = find(i)
                in_conflict |= {i, j}
    clusters: dict[int, list[int]] = {}
    for i in sorted(in_conflict):
        clusters.setdefault(find(i), []).append(i)
    ordered = sorted(clusters.values(), key=lambda idxs: min(idxs))
    out: list[Conflict] = []
    for n, idxs in enumerate(ordered, start=1):
        sides = [ms[i] for i in idxs]
        kind = {"date": "date", "role": "name"}.get(sides[0].kind, "number")
        out.append(Conflict(f"c{n:03d}", kind, _label(sides), sides))
    return out


def _label(sides: list[Mention]) -> str:
    if sides[0].kind == "role":
        return sides[0].unit
    first = sides[0]
    for pick in (lambda m: m.before, lambda m: m.before | m.after):  # the words before the figure name it best
        shared = None
        for s in sides:
            shared = pick(s) if shared is None else shared & pick(s)
        words = list(dict.fromkeys(w for w in first.words if _stem(w) in (shared or ())))
        if words:
            return " ".join(words[:4])
    return first.display


# ---------------------------------------------------------------------------------------------- applying


def _close(x: float, y: float) -> bool:
    return abs(x - y) <= 1e-9 * max(1.0, abs(x), abs(y))


def _date_spans(text: str) -> list[tuple[int, int]]:
    return [(m.lo, m.hi) for m in _sentence_mentions(text, "x", "prep", ("x", 0, 0), 0) if m.kind == "date"]


def _figure_in_text(side: Mention, text: str) -> bool:
    """Does `text` carry the figure of this side (or, for dates, the same quarter/month/day)?"""
    nt = norm(text)
    if norm(side.surface) in nt:
        return True
    if side.kind == "role":
        return side.tags <= set(nt.split())
    if side.kind == "date":
        if any(a <= side.hi and side.lo <= b for a, b in _date_spans(text)):
            return True
        words = set(re.findall(r"[^\W_]+", nt))
        return any(t in words for t in side.tags)
    nums = numbers_in(text)
    return any(_close(n, v) for n in nums for v in side.raw)


def _stems(text: str) -> frozenset[str]:
    return frozenset(_stem(w) for w in _WORD.findall(text) if w.casefold() not in STOP and len(w) > 1)


def _fact_about(fact: dict, side: Mention) -> bool:
    ns = norm(side.surface)
    if not any(s["ref"] == side.ref and (ns in norm(s["quote"]) or norm(s["quote"]) in norm(side.quote))
               for s in fact["sources"]):
        return False
    return _figure_in_text(side, f"{fact['value']} {fact['text']}")


def _point_uses(side: Mention, text: str, sources: list) -> bool:
    if not _figure_in_text(side, text):
        return False
    if any(s.ref == side.ref and norm(side.surface) in norm(s.quote) for s in sources):
        return True
    return bool(_stems(text) & (side.before | side.after))


def apply_conflicts(book: SourceBook, g: "Grounded", snippets: list[dict]) -> list[Conflict]:
    """Detect conflicts and mark them on facts (status/conflict), bank entries (conflict/conflict_points) and snippets
    (conflict). A conflict no model fact covers gets its own fact record, so the pack always states it."""
    conflicts = find_conflicts(book, extra=[(s["ref"], s["text"]) for s in snippets])
    for c in conflicts:
        entries = c.entries
        for f in g.facts:
            if any(_fact_about(f, s) for s in c.sides):
                c.fact_ids.append(f["id"])
                f["status"] = "conflict"
                have = {(e["value"], e["source_ref"], e["quote"]) for e in f.get("conflict", [])}
                f["conflict"] = f.get("conflict", []) + [e for e in entries if (e["value"], e["source_ref"], e["quote"]) not in have]
                f["topic"] = " / ".join(dict.fromkeys([*f.get("topic", "").split(" / "), c.label]).keys()).strip(" /")
        if not c.fact_ids:
            fid = f"f{len(g.facts) + 1:03d}"
            seen: set[tuple[str, str]] = set()
            srcs = []
            for s in sorted(c.sides, key=lambda m: m.sort_key):
                if (s.ref, norm(s.quote)) not in seen:
                    seen.add((s.ref, norm(s.quote)))
                    srcs.append({"kind": s.src_kind, "ref": s.ref, "quote": s.quote})
            g.facts.append({"id": fid, "kind": c.kind, "text": f"Sources disagree on {c.label}",
                            "value": " vs ".join(dict.fromkeys(e["value"] for e in entries)),
                            "sources": srcs, "status": "conflict", "conflict": entries, "topic": c.label})
            c.fact_ids.append(fid)
    for b in g.bank:
        ps = g.point_sources.get(b["id"], {})
        flagged: list[dict] = []
        items = [(i, p, ps.get("points", [[]] * 3)[i] if i < len(ps.get("points", [])) else []) for i, p in enumerate(b["points"])]
        if b["deep"]:
            items.append(("deep", b["deep"], ps.get("deep", [])))
        for idx, text, srcs in items:
            facts = [c.fact_ids[0] for c in conflicts if any(_point_uses(s, text, srcs) for s in c.sides)]
            if facts:
                flagged.append({"point": idx, "facts": facts})
                for c in conflicts:
                    if c.fact_ids[0] in facts:
                        c.bank_hits.append((b["id"], "deep" if idx == "deep" else f"point {idx + 1}"))
        if flagged:
            b["conflict"] = True
            b["conflict_points"] = flagged
    for s in snippets:
        ns = norm(s["text"])
        if any(c_s.ref == s["ref"] and norm(c_s.surface) in ns for c in conflicts for c_s in c.sides):
            s["conflict"] = True
    g.stats["conflicts"] = len(conflicts)
    g.stats["conflict_bank_entries"] = sum(1 for b in g.bank if b.get("conflict"))
    return conflicts
