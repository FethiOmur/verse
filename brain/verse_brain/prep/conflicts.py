"""Contradiction check (plan F1): find figures that differ between sources, so none is presented as certain.

Deterministic, no model call. Every source document (prep note lines, vault records, commit subjects, vault
snippets) is split into sentences; in each sentence the extractor finds money, percentages, durations, counts,
dates and role-holders ("hiring manager is X"), normalises each to a comparable value, and records the words
around it as a context. Two mentions from different sentences are compared only when they are the same kind of
figure (same currency / unit / role) and their contexts say they are about the same thing. Comparable mentions
whose values do not agree become a conflict; connected disagreements form one cluster.

Agreement rules (they keep the false-positive rate low, a missed conflict costs less than a false alarm because
the review page is read by a human, but a false alarm on every figure would train the owner to ignore the page):
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

Second pass (a live run raised 16 conflicts and nearly all were false). A claim is the same quantity only when its
key matches: the noun phrase next to the figure plus the unit, and the same scope. So:
- a total and its breakdown ("$13 in all: $8 to 16 Oct, $1.15 ..., $3.90 ...") are different quantities: the parts of a
  sentence's total (their sum, or everything smaller than a figure marked "in all/total") never enter a comparison, and a
  figure marked as a total is not compared with one that is not;
- a scope marker is part of the key: a date, `n=`, a fraction's denominator, `run 2`, `final run`, `after the fixes`,
  `baseline`, a statistic (`median`, `p95`) or a CI. Two figures with different scope sets are different measurements;
- figures of one bullet, paragraph or table row are never compared with each other (the author wrote them together); two
  lists that each hold several figures are one list when one holds the other's value; a bullet's `Label:` that differs
  ("Brand spike:" / "Spend at list price:") separates its figures; the word right before a figure must name the same thing;
- `from X to Y`, `X -> Y`, thresholds (`over 150`, `at least 5`), `n=9`, the level of a CI (`95% CI`) and sub-cent amounts
  are not claims about a quantity and are skipped; a `for ...` qualifier on one side only separates two figures;
- the count unit is the noun phrase, not the next word (`9 live turns` is turns), `s` is seconds, and a plural-label count
  (`Tests: 2,399 + 72`) is read; dates that label a log entry (`DECISIONS 2026-10-16 |`) are not claims.

These rules came from a live run on real vault text, where the first version raised six false conflicts out of six.

Third pass (five real prep runs raised 16 conflicts, all false). The cause was the key: a figure's context was every word
of its comma clause, so it took the subject of a neighbouring figure, the month of the other end of a date range, a bracketed
aside or a question label as its own subject. Now a figure's context is only the text that belongs to it:
- a neighbouring figure is a boundary; the words between two figures are split at a connector (`(`, `:`, `and`, `to`, ...),
  so in "7 s (a region mismatch cost 700 ms)" the mismatch belongs to 700 ms only (`_window`);
- an attributive figure ("the 30-second version", "a 2-second session-start bug", "the Jan 2026 release") is named by the
  noun after it, and that noun alone never links it to another figure: two versions are not one version;
- a bracketed aside the figure is not in ("(why it ended: ...)") is not context; month names are values, never context;
- a month range ("Jan-Jul 2026", "May 2024 to May 2025") is one date with two ends; two ranges agree when both ends agree;
- a bullet label that is a question or has a person in it ("Why they ask:") names nothing;
- when each side names a title or proper noun the other lacks ("Senior Software Engineer" / "Lead Software Engineer"),
  the figures are about different things; dates must also be named by the same word ("case study (7 Sep)" is not
  "contract (end of March)"); a date inside a "(source: ...)" bracket names the cited document and is not a claim.

Known limits (unconfirmed recall): an entity is identified by the words next to the figure, so a pair whose
wording shares nothing ("headcount" against "team size") is not paired; day-month dates without a year are not
read; roles are matched against a fixed list of one-holder titles (`ROLE` below). A subject cut off by a comma
("Vantor X Labs, May 2024 to May 2025") is lost, so such a figure is not compared; two attributive figures that
share only their noun ("a 20-minute call" / "the call lasts 30 minutes") are not compared; "N-day/-week/-month/-year"
compounds are not read as durations (those unit words are stop words).
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field, replace
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
def _fold(s: str) -> str:
    """Case- and diacritic-insensitive key: ı/İ/I -> i, combining marks stripped (kasim, KASIM, Kasım all agree)."""
    s = unicodedata.normalize("NFD", s.replace("İ", "i").replace("I", "i").replace("ı", "i").casefold())
    return "".join(c for c in s if not unicodedata.combining(c))


_MONTH_FOLD = {_fold(k): v for k, v in MONTHS.items()}


def _month(name: str) -> int | None:
    """Month number for any spelling the month regex can match; None (never an exception) for an unknown one."""
    return _MONTH_FOLD.get(_fold(name))


_MONTH_RE = "|".join(sorted((re.escape(m) for m in MONTHS), key=len, reverse=True))

CURRENCY = {"€": "EUR", "eur": "EUR", "euro": "EUR", "euros": "EUR", "$": "USD", "usd": "USD", "dollar": "USD",
            "dollars": "USD", "£": "GBP", "gbp": "GBP", "pound": "GBP", "pounds": "GBP", "₺": "TRY", "try": "TRY",
            "tl": "TRY", "lira": "TRY", "lire": "TRY"}
MULT = {"k": 1e3, "thousand": 1e3, "mila": 1e3, "bin": 1e3, "m": 1e6, "mn": 1e6, "mln": 1e6, "million": 1e6,
        "milioni": 1e6, "milyon": 1e6, "bn": 1e9, "billion": 1e9}
# unit word -> (family, factor): durations convert inside a family and are never compared across families
TIME = {"second": ("s", 1), "sec": ("s", 1), "secs": ("s", 1), "s": ("s", 1), "ms": ("s", 0.001), "millisecond": ("s", 0.001),
        "msec": ("s", 0.001), "saniye": ("s", 1), "minute": ("s", 60), "min": ("s", 60), "minuto": ("s", 60),
        "minuti": ("s", 60), "dakika": ("s", 60), "hour": ("s", 3600), "hr": ("s", 3600), "ora": ("s", 3600),
        "ore": ("s", 3600), "saat": ("s", 3600), "day": ("s", 86400), "giorno": ("s", 86400), "giorni": ("s", 86400),
        "gün": ("s", 86400), "week": ("s", 604800), "settimana": ("s", 604800), "settimane": ("s", 604800),
        "hafta": ("s", 604800), "month": ("mo", 1), "mese": ("mo", 1), "mesi": ("mo", 1), "ay": ("mo", 1),
        "year": ("mo", 12), "yr": ("mo", 12), "anno": ("mo", 12), "anni": ("mo", 12), "yıl": ("mo", 12)}
TIME_NAME = {"s": "second", "sec": "second", "secs": "second", "ms": "millisecond", "min": "minute", "hr": "hour", "yr": "year"}
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


# optional second amount of a range; "$8 to 16 Oct" is a date after "to", not the end of a range
_RNG = rf"(?:\s?(?:to|and|a|ile|-|–|—)\s?(?P<a2>{_AMT})(?!\d)(?!\s?(?:{_MONTH_RE})(?![^\W\d_]))(?P<s2>{_SUF})?)?"


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
_MON_RANGE = re.compile(rf"(?<![^\W\d_])(?P<mon1>{_MONTH_RE})(?![^\W\d_])\.?(?:\s+(?P<y1>\d{{4}}))?\s*(?:-|–|—|\bto\b|\buntil\b|\btill\b|\bthrough\b|\bthru\b)"
                        rf"\s*(?P<mon2>{_MONTH_RE})\.?,?\s+(?P<y2>\d{{4}})(?!\d)", _FLAGS)
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
_CLAUSE_SPLIT = re.compile(r",\s+|;\s+")

MAX_QUOTE = 200
LABELISH = frozenset("decision date log entry note section summary status update changelog history timeline".split())


def _num(tok: str) -> float:
    if "." in tok and "," in tok:
        dec = "." if tok.rfind(".") > tok.rfind(",") else ","
        return float(tok.replace("," if dec == "." else ".", "").replace(dec, "."))
    if re.fullmatch(r"\d{1,3}([.,]\d{3})+", tok):
        return float(re.sub(r"[.,]", "", tok))
    if re.fullmatch(r"\d+[.,]\d+", tok):
        return float(tok.replace(",", "."))
    return float(re.sub(r"[.,]", "", tok))


def _num_usd(tok: str) -> float:
    """A `$` amount with exactly one point and no comma is dollars.cents with any number of decimals ($1.152 is one
    dollar and 15.2 cents, not 1,152). Anything else (`$1,152`, `$1,152.50`, `$12.345.678`) reads as before."""
    if re.fullmatch(r"\d+\.\d+", tok):
        return float(tok)
    return _num(tok)


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
    scope: frozenset[str] = frozenset()  # what the figure was measured on: dates, n=, run N, after-fix, median, CI (sentence wide)
    qual: frozenset[str] = frozenset()  # words of a "for ..." / "during ..." qualifier next to the figure
    total: bool = False  # the clause says "in all" / "total": the figure is a sum, not an item
    part: bool = False  # an item of a sentence whose total is stated in the same sentence
    mods: frozenset[str] = frozenset()  # counts: the other words of the noun phrase ("unit" in "unit tests")
    lead: tuple[str, ...] = ()  # the (up to) three content words right before the figure; the last one names it
    topic: frozenset[str] = frozenset()  # words of the "Label:" the bullet starts with, when the figure comes after it
    topic_seq: tuple[str, ...] = ()
    clause: str = ""  # the comma clause the figure sits in
    attr: bool = False  # the figure modifies the noun after it ("the 30-second version", "the Jan 2026 release")
    names: frozenset[str] = frozenset()  # stems of the proper-noun / title words in the figure's own context
    ends: tuple[tuple[float, float], ...] = ()  # dates: the (start, end) spans of the two ends of a range

    @property
    def sort_key(self):
        prio = {"prep": 0, "vault": 1, "commit": 2}[self.src_kind]
        m = re.search(r"L(\d+)$", self.ref)
        return prio, int(m.group(1)) if m else 0, self.ref, self.order, self.display

    def entry(self) -> dict:
        return {"value": self.display, "source_ref": self.ref, "quote": self.quote}


QUAL_PREP = frozenset("for across during on at".split())
_TOTAL = re.compile(r"(?<![^\W\d_])(?:in\s+(?:all|total)|total|totals|overall|altogether|combined|all\s+told|cumulative|grand\s+total)(?![^\W\d_])", _FLAGS)


def _qual(before_words: list[str], after_words: list[str]) -> frozenset[str]:
    """Stems of the words a `for ...` / `during ...` phrase puts next to the figure ("spend for these tests: $3.90")."""
    out: set[str] = set()
    for i, w in enumerate(after_words):
        if w.casefold() in QUAL_PREP:
            out |= {_stem(x) for x in after_words[i + 1:i + 5] if x.casefold() not in STOP and len(x) > 1}
            break
    for i in range(len(before_words) - 1, -1, -1):
        if before_words[i].casefold() in QUAL_PREP:
            out |= {_stem(x) for x in before_words[i + 1:] if x.casefold() not in STOP and len(x) > 1}
            break
    return frozenset(out)


# words and marks that separate two figures of one clause: what comes before them belongs to the first figure, what comes
# after them to the second ("7 s (a region mismatch cost 700 ms)", "a 700-millisecond region mismatch and a 2-second bug")
_CONNECT_WORDS = frozenset("and or but nor plus vs versus to then while whereas".split())
_CONNECT = re.compile(r"[()\[\]:;—–]|\s-\s|(?<![^\W\d_])(?:" + "|".join(sorted(_CONNECT_WORDS)) + r")(?![^\W\d_])", _FLAGS)


def _brackets(s: str) -> list[tuple[int, int]]:
    """Matched () and [] pairs as (open, close) positions."""
    pairs: list[tuple[int, int]] = []
    stack: list[tuple[str, int]] = []
    for i, ch in enumerate(s):
        if ch in "([":
            stack.append((ch, i))
        elif ch in ")]" and stack and stack[-1][0] == ("(" if ch == ")" else "["):
            pairs.append((stack.pop()[1], i))
    return pairs


def _attributive(sent: str, a: int, b: int, kind: str) -> bool:
    """Does the figure modify the noun right after it? `the 30-second version`, `a 2-second session-start bug`,
    `the Jan 2026 release`. Such a figure names which thing is meant; it is not a statement about a thing named elsewhere."""
    if kind not in ("duration", "count", "date"):
        return False
    if kind != "date" and not re.search(r"\d-[^\W\d_]+$", sent[a:b]):
        return False  # only the hyphenated compound ("10-week pilot") is reliably attributive for a duration or a count
    m = re.match(r"[ \t]+([^\W\d_][\w'’-]*)", sent[b:])
    if not m or not m.group(1)[0].islower():
        return False
    w = m.group(1).casefold()
    return len(w) > 1 and w not in STOP and w not in CUT_AFTER and w not in _CONNECT_WORDS and _month(w) is None


def _names(text: str) -> frozenset[str]:
    """Stems of the proper-noun and title words of a context: runs of capitalised words ("Senior Software Engineer",
    "NRT Mobility Agent") and single capitalised words that are not capitalised only by their position (sentence or label start)."""
    toks = list(_WORD.finditer(text))
    out: set[str] = set()

    def cap(i: int) -> bool:
        w = toks[i].group()
        return w[:1].isupper() and w.casefold() not in STOP and len(w) > 1

    for i, m in enumerate(toks):
        if not cap(i):
            continue
        run = (i > 0 and cap(i - 1) and not text[toks[i - 1].end():m.start()].strip()) or \
              (i + 1 < len(toks) and cap(i + 1) and not text[m.end():toks[i + 1].start()].strip())
        head = text[:m.start()].rstrip()
        positional = not head or head[-1] in ".:!?\"“(*-•"
        if run or not positional:
            out.add(_stem(m.group()))
    return frozenset(out)


def _window(sentence: str, start: int, end: int, spans: Iterable[tuple[int, int]], attr: frozenset[tuple[int, int]],
            skip_to: int = 0) -> tuple[str, str, int, int]:
    """The text that belongs to the figure at [start, end): (before_text, after_text, clause_start, clause_end).

    The clause is the comma clause (a table cell never borrows the words of the cell before it). Inside it:
    - a bracketed aside the figure is not in says nothing about the figure ("(why it ended: ...)", "(source: ...)");
      a figure inside brackets keeps the words before the bracket (what it annotates) but not the words after it;
    - a neighbouring figure is a boundary: the words between two figures are split at the first connector for the
      earlier figure and after the last connector for the later one; without a connector they go to the later figure,
      unless the earlier one is attributive (its noun follows it).
    """
    cs = skip_to if skip_to <= start else 0
    for m in _CLAUSE_SPLIT.finditer(sentence, cs, start):
        cs = m.end()
    cs = max(cs, sentence.rfind("|", 0, start) + 1)
    ce = len(sentence)
    m = _CLAUSE_SPLIT.search(sentence, end)
    if m:
        ce = m.start()
    pairs = _brackets(sentence)
    own = min((p for p in pairs if p[0] < start and end <= p[1]), key=lambda p: p[1] - p[0], default=None)
    masked = [p for p in pairs if not (p[0] < start and end <= p[1])]
    vis = list(sentence)
    for p, q in masked:
        vis[p:q + 1] = ";" + " " * (q - p)  # an aside reads as a separator
    text = "".join(vis)
    hi = ce if own is None else min(ce, own[1])
    others = [s for s in spans if (s[1] <= start or s[0] >= end) and s[0] >= cs and s[1] <= ce
              and not any(p <= s[0] and s[1] <= q for p, q in masked)]
    lo = cs
    prev = max((s for s in others if s[1] <= start), key=lambda s: s[1], default=None)
    if prev is not None:
        r1 = own[0] if own is not None and prev[1] <= own[0] else start
        conns = list(_CONNECT.finditer(text, prev[1], r1))
        lo = conns[-1].end() if conns else (r1 if prev in attr else prev[1])
    if own is not None and lo <= own[0]:
        before = text[lo:own[0]] + " " + text[own[0] + 1:start]
    else:
        before = text[max(lo, own[0] + 1) if own is not None else lo:start]
    nxt = min((s for s in others if s[0] >= end and s[1] <= hi), key=lambda s: s[0], default=None)
    if nxt is not None:
        c = _CONNECT.search(text, end, nxt[0])
        hi = c.start() if c else (nxt[0] if (start, end) in attr else end)
    return before, text[end:hi], cs, ce


def _context(sentence: str, start: int, end: int, spans: Iterable[tuple[int, int]] = (),
             attr: frozenset[tuple[int, int]] = frozenset(), skip_to: int = 0):
    """Words that belong to the figure (see `_window`). Returns (before, after, words, after_prep, clause, qual, lead, names).
    Month names are values, not subjects: the other end of a date range never becomes a context word."""
    before_text, after_text, cs, ce = _window(sentence, start, end, spans, attr, skip_to)
    before_words = [w for w in _WORD.findall(before_text)]
    after_words = []
    for w in _WORD.findall(after_text):
        if w.casefold() in CUT_AFTER:
            break
        after_words.append(w)

    def content(w: str) -> bool:
        return w.casefold() not in STOP and len(w) > 1 and _month(w) is None

    bw = [w for w in before_words if content(w)][-5:]
    aw_all = [w for w in after_words if content(w)][:3]
    prep = after_words[0].casefold() if after_words and after_words[0].casefold() in WEAK_AFTER_PREP else ""
    words = tuple(w.casefold() for w in bw + aw_all)
    # an attributive figure is named by the noun after it, any other figure by the words before it
    lead = tuple(_stem(w) for w in aw_all[:2]) if (start, end) in attr else tuple(_stem(w) for w in bw[-3:])
    names = _names(before_text) | _names(" ".join(after_words))
    names = frozenset(n for n in names if n in {_stem(w) for w in bw + aw_all})
    return (frozenset(_stem(w) for w in bw), frozenset(_stem(w) for w in aw_all), words, prep, sentence[cs:ce],
            _qual(before_words, after_words), lead, names)


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
        topic, label_end, template = _unit_topic(unit)
        # a table row is one claim: its `;` and `. ` separate figures from the cells that describe them
        for si, sent in enumerate([unit] if unit.startswith("|") else _SENT_SPLIT.split(unit)):
            if sent.strip():
                out += _sentence_mentions(sent, ref, src_kind, (ref, ui, si), len(out), heading and si == 0 and src_kind != "prep", snap,
                                          topic, label_end if si == 0 else 0, label_end if (template and si == 0) else 0)
    return out


GENERIC_LABEL = frozenset("""note notes result results decision decisions number numbers measured measure update summary status
fyi todo important warning reminder finding findings evidence claim fact facts question answer example quote source fixed
known limit open done""".split())
_LABEL = re.compile(r"^\s*(?:\*\*)?(?P<l>[^:|\d]{2,60}?)(?:\*\*)?:\s")


_WH = frozenset("why what how when where who whom which whose perche cosa come quando dove chi neden ne nasil nasıl".split())
_PRONOUN = frozenset("i me my we us our you your they them their he him his she her".split())


def _unit_topic(unit: str) -> tuple[tuple[str, ...], int, bool]:
    """`Brand spike: 11 sites, 11 credits.` -> ({brand, spike}, end of the label, False). Generic labels ("Result:") say
    nothing. A label that is a question or a clause with a person in it ("Why they ask:", "What I did:") is a template
    label: it says what the text is for, not what the figure is about, so it names nothing (third value True)."""
    m = _LABEL.match(unit)
    if not m or len(_WORD.findall(m["l"])) > 8:
        return (), 0, False
    raw = [w.casefold() for w in _WORD.findall(m["l"])]
    if raw and (raw[0] in _WH or any(w in _PRONOUN for w in raw)):
        return (), m.end(), True
    words = [_stem(w) for w in _WORD.findall(m["l"]) if w.casefold() not in STOP and w.casefold() not in GENERIC_LABEL and len(w) > 1]
    return tuple(words), m.end(), False


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
    if len(_WORD.findall(sent[:a])) <= 2 and re.match(r"\s*[|:\-–—]", sent[b:b + 6]):
        return True  # "DECISIONS 2026-10-16 |": the date heads a log entry
    op = sent.rfind("(", 0, a)
    if op >= 0 and ")" not in sent[op:a] and _SOURCE_BRACKET.match(sent, op):
        return True  # "(source: ServiceNow newsroom, Jan 2026 release, ...)": the date names the cited document
    return bool(_CITATION.search(sent[max(0, a - 60):b + 60]))


_SOURCE_BRACKET = re.compile(r"\(\s*(?:sources?|kaynak(?:lar)?|fonte|fonti|via|cited|citation)\s*:", re.I)


# ---- scope, skip rules, totals (second pass) --------------------------------------------------------

_S_DMON = re.compile(rf"(?<![\d.,/-])(?P<d>\d{{1,2}})(?:st|nd|rd|th)?\s+(?:of\s+)?(?P<mon>{_MONTH_RE})(?![^\W\d_])", _FLAGS)
_S_MOND = re.compile(rf"(?<![^\W\d_])(?P<mon>{_MONTH_RE})\.?\s+(?P<d>\d{{1,2}})(?:st|nd|rd|th)?(?!\d)", _FLAGS)
_S_N = re.compile(r"(?<![^\W\d_])n\s?=\s?(\d[\d,]*)", _FLAGS)
_S_FRAC = re.compile(r"(?<![\d/.,])\d{1,4}/(\d{1,5})(?![\d/])")
_S_RUN = re.compile(r"(?<![^\W\d_])(run|round|trial|attempt|iteration|sprint|batch|phase|stage|version|v)s?\s?(\d+)(?:\s?[-–]\s?(\d+))?(?!\d)", _FLAGS)
_S_ORD = re.compile(r"(?<![^\W\d_])(first|second|third|final|last|latest|initial)\s+(run|round|attempt|trial|recording|measurement|pass|"
                    r"version|release|iteration)s?(?![^\W\d_])", _FLAGS)
_S_WORD = re.compile(r"(?<![^\W\d_])(baseline|previously|formerly|originally|initially|earlier)(?![^\W\d_])", _FLAGS)
_S_AFTER = re.compile(r"(?<![^\W\d_])(after|before|since)\s+(?:the\s+|our\s+|my\s+|this\s+|these\s+|those\s+)?(?:[\w'’.-]+\s+){0,3}?"
                      r"(fix|fixes|change|changes|update|updates|release|refactor|migration|rewrite|patch|launch|deploy|deployment|"
                      r"incident|merge|run|runs|round|rounds|commit|upgrade|tuning|cutover|optimi[sz]ation)(?![^\W\d_])", _FLAGS)
_S_STAT = re.compile(r"(?<![^\W\d_])(median|mean|average|avg|p\s?(?:50|75|90|95|99)|minimum|maximum|peak|worst|best)(?![^\W\d_])", _FLAGS)
_S_CI = re.compile(r"(?<![^\W\d_])(?:ci|confidence\s+interval|interval|wilson|credible)(?![^\W\d_])", _FLAGS)


def _scope(sent: str) -> frozenset[str]:
    """What the figures of a sentence were measured on. Two figures with different scope sets are different measurements."""
    t: set[str] = set()
    for rx in (_ISO, _DMY):
        for m in rx.finditer(sent):
            t.add(f"d:{int(m['m'])}-{int(m['d'])}")
    for rx in (_S_DMON, _S_MOND):
        for m in rx.finditer(sent):
            if _month(m["mon"]) is not None:
                t.add(f"d:{_month(m['mon'])}-{int(m['d'])}")
    for m in _MON_Y.finditer(sent):
        if _month(m["mon"]) is not None:
            t.add(f"m:{_month(m['mon'])}")
    for m in _QUARTER.finditer(sent):
        t.add(f"q:{m['q'] or m['q2']}")
    for m in _HALF.finditer(sent):
        t.add(f"h:{m['h']}")
    t |= {f"n:{m.group(1).replace(',', '')}" for m in _S_N.finditer(sent)}
    t |= {f"n:{m.group(1)}" for m in _S_FRAC.finditer(sent)}
    for m in _S_RUN.finditer(sent):
        t.add(f"{m.group(1).casefold()}:{m.group(2)}" + (f"-{m.group(3)}" if m.group(3) else ""))
    t |= {f"{m.group(1).casefold()}:{_stem(m.group(2))}" for m in _S_ORD.finditer(sent)}
    t |= {m.group(1).casefold() for m in _S_WORD.finditer(sent)}
    t |= {f"{m.group(1).casefold()}:{_stem(m.group(2))}" for m in _S_AFTER.finditer(sent)}
    t |= {"stat:" + re.sub(r"\s", "", m.group(1).casefold()).replace("avg", "average") for m in _S_STAT.finditer(sent)}
    if _S_CI.search(sent):
        t.add("ci")
    return frozenset(t)


_HEDGE_PRE = r"(?:about\s+|around\s+|roughly\s+|approximately\s+|approx\.?\s+|~\s?)?"
_FROM_PRE = re.compile(rf"(?:\bfrom|\binstead of|\brather than|\bup from|\bdown from|\bused to be|\bformerly|\bpreviously)\s+{_HEDGE_PRE}$", _FLAGS)
_FROM_TO = re.compile(rf"\bfrom\s+(?:\S+\s+){{1,4}}?to\s+{_HEDGE_PRE}$", _FLAGS)
_ARROW_PRE = re.compile(rf"(?:→|->|=>|⇒)\s*{_HEDGE_PRE}$")
_ARROW_POST = re.compile(r"^\s*(?:→|->|=>|⇒)")
_THRESH = re.compile(rf"(?:\bover|\babove|\bunder|\bbelow|\bbeyond|\bexceeding|\bexceeds|\bat least|\bat most|\bmore than|\bless than|"
                     rf"\bfewer than|\bup to|\bminimum(?: of)?|\bmaximum(?: of)?|\bmin|\bmax|>=|<=|≥|≤|>|<)\s*{_HEDGE_PRE}$", _FLAGS)
_N_EQ = re.compile(r"(?<![^\W\d_])n\s?=\s?$", _FLAGS)
_CI_POST = re.compile(r"^\s*(?:ci|confidence|interval|wilson|credible)(?![^\W\d_])", _FLAGS)
_CI_PRE = re.compile(r"(?<![^\W\d_])(?:ci|confidence|interval)\s*(?:of\s*)?$", _FLAGS)
_SLASH_POST = re.compile(r"^(?:\s+/\s*|\s*/\s+)[$€£]?\d")
_SLASH_PRE = re.compile(r"(?:\s/\s*|/\s+)$")
_TO_SOON = re.compile(r"^\S*(?:\s+\S+){0,3}?\s+to\b", _FLAGS)


def _not_a_claim(sent: str, a: int, b: int, kind: str) -> bool:
    """A figure that is a baseline (`from X to Y`, arrows, `instead of X`), a threshold (`over 150`), a sample size (`n=9`)
    or the level of a confidence interval (`95% CI`) is not a statement of the quantity itself."""
    pre, post = sent[max(0, a - 60):a], sent[b:b + 40]
    if _FROM_TO.search(pre) or _ARROW_PRE.search(pre) or _ARROW_POST.match(post) or _THRESH.search(pre):
        return True
    m = _FROM_PRE.search(pre)
    if m and (not m.group().casefold().startswith("from") or _TO_SOON.match(post)):
        return True
    if kind == "count" and _N_EQ.search(pre):
        return True
    if _SLASH_POST.match(post) or _SLASH_PRE.search(pre):
        return True  # "25.2 s / 37.3 s": a series of different statistics, not one claim each
    if kind == "percent":
        if _CI_POST.match(post) or _CI_PRE.search(pre):
            return True
        if _S_CI.search(sent) and re.search(r"[(\[][^()\[\]]*$", sent[:a]) and re.match(r"[^()\[\]]*[)\]]", sent[b:]):
            return True  # a bound inside the brackets of a confidence interval
    return False


def _mark_parts(found: list[Mention], sentence_scope: frozenset[str]) -> list[Mention]:
    """Items of a total stated in the same sentence ("$13 in all: $8 to 16 Oct, $1.15 ..., $3.90 ...") are parts: they are
    different quantities from the total and from the same wording elsewhere. The total is a figure the clause calls "in all/total"
    (the largest one) or the figure the others add up to."""
    from itertools import combinations
    part: set[int] = set()
    total: dict[int, set[int]] = {}
    groups: dict[tuple[str, str], list[int]] = {}
    for i, m in enumerate(found):
        if m.kind in ("money", "count", "duration"):
            groups.setdefault((m.kind, m.unit), []).append(i)
    for idxs in groups.values():
        for t in sorted(idxs, key=lambda i: -found[i].hi):
            T = found[t]
            smaller = [i for i in idxs if i != t and i not in part and found[i].hi <= T.lo * (1 + 1e-9)]
            if not smaller:
                continue
            if T.total and T.hi >= max(found[i].hi for i in idxs):
                part |= set(smaller)
                total[t] = set(smaller)
                continue
            for size in range(min(len(smaller), 12), 1, -1):
                hit = next((c for c in combinations(smaller[:12], size) if _sums_to(T, [found[i] for i in c])), None)
                if hit:
                    part |= set(hit)
                    total[t] = set(hit)
                    break
    out = []
    for i, m in enumerate(found):
        if i in total:  # the total is not measured on what only its items carry ("$8 to 16 Oct" scopes the item, not the sum)
            own: set[str] = set()
            for j in total[i]:
                own |= _scope(found[j].clause)
            m = replace(m, scope=(sentence_scope - own) | _scope(m.clause), total=True)
        out.append(replace(m, part=i in part))
    return out


def _sums_to(t: Mention, items: list[Mention]) -> bool:
    lo, hi = sum(x.lo for x in items), sum(x.hi for x in items)
    tol = (0.06 if t.approx or any(x.approx for x in items) else 0.005) * t.hi
    return lo - tol <= t.hi and t.lo <= hi + tol


_PHRASE_NEXT = re.compile(r"[\s-]+([^\W\d_]+)", re.U)


def _noun_phrase(sent: str, first: str, pos: int) -> list[str]:
    """Stems of the noun phrase that follows a number: the unit word plus up to two more, ending at the first plural."""
    words = [first]
    while len(words) < 3 and not _plural(words[-1]):
        m = _PHRASE_NEXT.match(sent, pos)
        if not m:
            break
        w = m.group(1)
        if w.casefold() in STOP or w.casefold() in CUT_AFTER or _month(w) is not None or len(w) < 2:
            break
        words.append(w)
        pos = m.end()
    return [_stem(w) for w in words]


def _plural(w: str) -> bool:
    w = w.casefold()
    return len(w) > 3 and w.endswith("s") and not w.endswith("ss")


_LABEL_COUNT = re.compile(rf"(?:^|[|;(]\s*|[.!?]\s+)(?P<label>[^\W\d_]+(?:[\s-][^\W\d_]+){{0,2}})\s*:\s*(?P<a1>{_AMT})"
                          rf"(?=\s*(?:$|[+,;)|/]|\.(?:\s|$)))", _FLAGS)


def _sentence_mentions(sent: str, ref: str, src_kind: str, sid: tuple[str, int, int], base: int, heading: bool = False,
                       snap: str = "", topic: tuple[str, ...] = (), topic_from: int = 0, skip_to: int = 0) -> list[Mention]:
    found: list[Mention] = []
    used: list[tuple[int, int]] = []
    kinds: dict[tuple[int, int], str] = {}
    pending: list[tuple] = []

    def free(a: int, b: int) -> bool:
        return all(b <= s or a >= e for s, e in used)

    sc = _scope(sent)

    def add(kind, a, b, display, lo, hi, raw, unit, tags=frozenset(), mods=frozenset(), labelled=False, ends=()):
        if kind != "role":
            used.append((a, b))
            kinds[(a, b)] = kind
        if kind in ("money", "count", "percent", "duration") and _not_a_claim(sent, a, b, kind):
            return
        if kind == "money" and hi < 0.01:
            return  # sub-cent amounts say nothing comparable
        pending.append((kind, a, b, display, lo, hi, raw, unit, tags, mods, labelled, ends))

    def build() -> None:
        """Contexts are built once every figure of the sentence is known: each figure is a boundary for its neighbours."""
        spans = sorted(set(used))
        attr = frozenset(s for s in spans if _attributive(sent, s[0], s[1], kinds.get(s, "")))
        for kind, a, b, display, lo, hi, raw, unit, tags, mods, labelled, ends in pending:
            before, after, words, prep, clause, qual, lead, names = _context(sent, a, b, spans, attr, skip_to)
            if labelled:
                after, words = frozenset(), tuple(w for w in words if _stem(w) in before)  # "Tests: 2,399 + 72 in the suite": the label names it, the tail does not
            tp = topic if a >= topic_from else ()
            if not lead and tp:  # "Halden spend: $8 to 16 Oct, ..., about $9 in all": the total restates the label's subject
                before, lead = before | frozenset(tp), tuple(tp[-3:])
                words = tuple(tp[-3:]) + words
            gn, period = _qualifiers(clause) if kind in ("money", "count", "percent") else ("", "")
            fig = kind in ("money", "count", "percent", "duration")
            found.append(Mention(kind, src_kind, ref, _quote(sent, a, b), sent[a:b].strip(), display, lo, hi, tuple(raw), unit,
                                 before, after, words, prep, _approx(sent, a), gn, period, sid, frozenset(tags), base + a, snap,
                                 sc if fig else frozenset(), qual if fig else frozenset(), fig and bool(_TOTAL.search(clause)),
                                 False, frozenset(mods), lead if (fig or kind == "date") else (), frozenset(tp) if fig else frozenset(),
                                 tp, clause, (a, b) in attr, names if kind != "role" else frozenset(), tuple(ends)))

    def span_of(y, m1=1, d1=1, m2=12, d2=None):
        return _span(int(y), m1, d1, m2, d2)

    # dates ------------------------------------------------------------------------------------
    def date_hit(m, sp, display, tags=(), ends=()):
        if sp and free(m.start(), m.end()):
            if _label_date(sent, m.start(), m.end(), heading):
                used.append((m.start(), m.end()))  # consumed, but not a claim
                kinds[(m.start(), m.end())] = "date"
                return
            add("date", m.start(), m.end(), display, sp[0], sp[1], (), "", tags, ends=ends)

    # a month range is one figure with two ends: "Jan-Jul 2026", "May 2024 to May 2025", "Oct 2022-Jan 2024"
    for m in _MON_RANGE.finditer(sent):
        m1, m2, y2 = _month(m["mon1"]), _month(m["mon2"]), int(m["y2"])
        if m1 is None or m2 is None:
            continue
        y1 = int(m["y1"]) if m["y1"] else (y2 if m1 <= m2 else y2 - 1)
        s1, s2 = span_of(y1, m1, 1, m1), span_of(y2, m2, 1, m2)
        if not s1 or not s2 or s1[0] > s2[0]:
            continue
        date_hit(m, (s1[0], s2[1]), f"{y1}-{m1:02d} to {y2}-{m2:02d}", (m["mon1"].casefold(), m["mon2"].casefold()), (s1, s2))
    for m in _ISO.finditer(sent):
        date_hit(m, span_of(m["y"], int(m["m"]), int(m["d"]), int(m["m"]), int(m["d"])), f"{m['y']}-{m['m']}-{m['d']}")
    for m in _DMY.finditer(sent):
        mo, d = int(m["m"]), int(m["d"])
        date_hit(m, span_of(m["y"], mo, d, mo, d), f"{m['y']}-{mo:02d}-{d:02d}")
    for m in _D_MON_Y.finditer(sent):
        mo, d = _month(m["mon"]), int(m["d"])
        if mo is None:
            continue
        date_hit(m, span_of(m["y"], mo, d, mo, d), f"{m['y']}-{mo:02d}-{d:02d}")
    for m in _MON_D_Y.finditer(sent):
        mo, d = _month(m["mon"]), int(m["d"])
        if mo is None:
            continue
        date_hit(m, span_of(m["y"], mo, d, mo, d), f"{m['y']}-{mo:02d}-{d:02d}")
    for m in _MON_Y.finditer(sent):
        mo = _month(m["mon"])
        if mo is None:
            continue
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
        num = _num_usd if m["cur"] == "$" else _num
        a1 = num(m["a1"]) * _mult(s1)
        a2 = num(m["a2"]) * _mult(s2) if m["a2"] else None
        if a2 is not None and s1 is None and s2 is not None and num(m["a1"]) < 1000:  # "€40-45K"
            a1 = num(m["a1"]) * _mult(s2)
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
        if unit_w in STOP or _month(unit_w) is not None or unit_w in CURRENCY or unit_w in ("to", "and", "or"):
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
            ph = _noun_phrase(sent, m["unit"], m.end("unit"))
            u = ph[-1]
            plural = "" if (lo == hi == 1) or u in ("people", "staff") else "s"
            add("count", m.start(), end, f"{_fmt(lo)}{'-' + _fmt(hi) if hi != lo else ''} {' '.join(ph)}{plural}", lo, hi,
                (lo, hi) if hi != lo else (lo,), f"n:{u}", mods=ph[:-1])

    # a plural label with a bare number: "Tests: 2,399 + 72"
    for m in _LABEL_COUNT.finditer(sent):
        a, b = m.start("a1"), m.end("a1")
        lw = _WORD.findall(m["label"])
        tok = m["a1"]
        if not free(a, b) or not _plural(lw[-1]) or lw[-1].casefold() in STOP or re.fullmatch(r"(?:19|20)\d{2}", tok):
            continue
        v = _num(tok)
        if v < 20 or v >= 1e9:
            continue
        head = _stem(lw[-1])
        add("count", a, b, f"{_fmt(v)} {head}s", v, v, (v,), f"n:{head}", mods=[_stem(w) for w in lw[:-1] if w.casefold() not in STOP], labelled=True)

    # role holders -----------------------------------------------------------------------------
    for role, name, a, b in _roles(sent):
        add("role", a, b, re.sub(r"\s+", " ", name), 0.0, 0.0, (), role, set(norm(name).split()))
    build()
    return _mark_parts(found, sc)


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
    if a.kind != b.kind or a.sent[:2] == b.sent[:2] or a.unit != b.unit:
        return False  # figures of one bullet / paragraph were written together: the author's own enumeration
    if a.kind == "role":
        return True
    if a.snap and b.snap and a.snap != b.snap and a.src_kind == b.src_kind:
        return False  # two dated notes (or commits) of the same kind: the figure may have moved between the days
    if a.part or b.part or a.scope != b.scope or a.total != b.total:
        return False  # an item of a total, or another run / date / sample / statistic / total-vs-item: not the same quantity
    if (a.qual or b.qual) and not (a.qual & b.qual):
        return False  # "spend for these tests" against "spend": a qualifier on one side only separates them
    if a.kind == "count" and not (a.mods <= b.mods or b.mods <= a.mods):
        return False
    if a.topic and b.topic and not (a.topic & b.topic):
        return False  # "Brand spike: ..." against "Spend at list price: ...": the bullets are about different things
    if a.lead and b.lead and not (a.lead[-1] == b.lead[-1] or a.lead[-1] in b.lead or b.lead[-1] in a.lead):
        return False  # the word that names the figure differs: "first email" against "first section"
    if a.gross_net and b.gross_net and a.gross_net != b.gross_net:
        return False
    if a.period and b.period and a.period != b.period:
        return False
    if a.after_prep and a.after_prep == b.after_prep and a.after and b.after and not (a.after & b.after):
        return False  # "... for totals" against "... for line items": two different things
    ca, cb = a.before | a.after, b.before | b.after
    if a.kind == "date":  # a bare log word ("decisions", "update") does not make two dates the same event
        ca, cb = ca - LABELISH, cb - LABELISH
    if (a.names - cb) and (b.names - ca):
        return False  # each side names something the other does not: "Senior Software Engineer" against "Lead Software Engineer"
    inter = ca & cb
    if not inter:
        return False
    if len(inter) == 1 and (max(len(ca), len(cb)) > 2 or a.attr or b.attr):
        # one shared word in a long context is too weak a link (e.g. "duration" in two unrelated lines); so is the noun of an
        # attributive figure alone ("the 30-second version" / "the 90-second version" are two versions, not one)
        return False
    return len(inter) / min(len(ca), len(cb)) >= 0.5


def _agree(a: Mention, b: Mention) -> bool:
    if a.kind == "role":
        ta, tb = a.tags, b.tags
        return ta <= tb or tb <= ta
    if a.kind == "date":
        if a.ends and b.ends:  # two ranges agree when their starts agree and their ends agree
            return all(x[0] <= y[1] and y[0] <= x[1] for x, y in zip(a.ends, b.ends))
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

    bysent: dict[tuple, list[Mention]] = {}
    for m in ms:
        bysent.setdefault((m.sent, m.kind, m.unit), []).append(m)
    in_conflict: set[int] = set()
    for i in range(len(ms)):
        for j in range(i + 1, len(ms)):
            a, b = ms[i], ms[j]
            if _comparable(a, b) and not _agree(a, b) and not _listed_in_both(a, b, bysent):
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


def _listed_in_both(a: Mention, b: Mention, bysent: dict[tuple, list[Mention]]) -> bool:
    """Two sentences that each list several figures of this kind: when one sentence also holds the other side's value, the
    figures are items of the same list ("$0.10-0.12 and $0.16 with a repair" against a row with both), not a contradiction."""
    sa, sb = bysent.get((a.sent, a.kind, a.unit), []), bysent.get((b.sent, b.kind, b.unit), [])
    return len(sa) >= 2 and len(sb) >= 2 and (any(_agree(a, c) for c in sb) or any(_agree(b, c) for c in sa))


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
