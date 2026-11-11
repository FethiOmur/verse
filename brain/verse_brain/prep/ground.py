"""Turn parsed model output into validated records. Every point and fact must carry >= 1 verified source.

Dropped items are kept (with a reason) so review.md can show the owner what was thrown away.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from .parse import ParsedOutput, RawBank, RawFact, RawSrc, RawTerm, RawText
from .sources import Source, SourceBook, norm, numbers_in, numbers_supported, significant_numbers

FACT_KINDS = ("number", "date", "name")


@dataclass
class Dropped:
    what: str  # "point" | "deep" | "fact" | "term" | "entry"
    reason: str  # "unsourced" | "unsupported_quote" | "unsupported_number" | ...
    text: str
    where: str = ""
    claimed: str = ""  # the sources the model offered (handle | quote), so a failed check can be diagnosed


@dataclass
class Grounded:
    bank: list[dict] = field(default_factory=list)
    facts: list[dict] = field(default_factory=list)
    glossary: list[dict] = field(default_factory=list)
    dropped: list[Dropped] = field(default_factory=list)
    stats: dict = field(default_factory=dict)
    # bank id -> {"points": [[Source, ...] per kept point], "deep": [Source, ...]}; used by the conflict check, not stored
    point_sources: dict = field(default_factory=dict)


def _verify(srcs: list[RawSrc], book: SourceBook) -> tuple[list[Source], int]:
    """Verified sources (deduped, in order) and how many claimed sources failed."""
    good: list[Source] = []
    bad = 0
    seen: set[tuple[str, str]] = set()
    for s in srcs:
        v = book.resolve(s.handle, s.quote)
        if v is None:
            bad += 1
            continue
        k = (v.ref, norm(v.quote))
        if k not in seen:
            seen.add(k)
            good.append(v)
    return good, bad


def _stat(what: str, reason: str) -> str:
    return f"points_dropped_{reason}" if what == "point" else f"{what}_dropped_{reason}"


def _check_text(t: RawText, book: SourceBook, what: str, where: str, g: Grounded) -> list[Source] | None:
    """Returns verified sources, or None after recording why the text was dropped."""
    text = t.text.strip()
    if not text:
        return None
    reason = None
    good: list[Source] = []
    if not t.srcs:
        reason = "unsourced"
    else:
        good, _bad = _verify(t.srcs, book)
        if not good:
            reason = "unsupported_quote"
        elif not numbers_supported(text, [s.span or s.quote for s in good]):
            reason = "unsupported_number"
    if reason:
        claimed = "; ".join(f"{s.handle} | {s.quote}" for s in t.srcs)
        g.dropped.append(Dropped(what, reason, text, where, claimed))
        _bump(g, _stat(what, reason))
        return None
    return good


def _bump(g: Grounded, key: str) -> None:
    g.stats[key] = g.stats.get(key, 0) + 1


def ground(parsed: ParsedOutput, book: SourceBook, langs: list[str], max_questions: int) -> Grounded:
    g = Grounded()
    g.stats["blocks_incomplete"] = parsed.incomplete_blocks
    _ground_facts(parsed.facts, book, g)
    _ground_terms(parsed.terms, book, g)
    _ground_bank(parsed.bank, book, langs, max_questions, g)
    return g


# ---------------------------------------------------------------------------------------------- facts


def _value_supported(kind: str, value: str, quotes: list[str]) -> bool:
    if kind == "number":
        want = numbers_in(value)
        have: set[float] = set()
        for q in quotes:
            have |= numbers_in(q)
        return bool(want) and all(any(abs(w - h) < 1e-9 for h in have) for w in want)
    if kind == "date":
        parts = re.findall(r"\d+", value)
        have = set()
        for q in quotes:
            have |= numbers_in(q)
        if not parts:
            return False
        # A quote may spell the month as a word, so a numeric month is not required; the year and the day are.
        if len(parts) == 3 and len(parts[0]) == 4:  # 2025-03-14
            need = [parts[0], parts[2]]
        elif len(parts) == 3 and len(parts[2]) == 4:  # 14/03/2025
            need = [parts[0], parts[2]]
        elif len(parts) == 2 and len(parts[0]) == 4:  # 2025-03
            need = [parts[0]]
        else:  # "14 March 2025", "2025", "14"
            need = parts
        return all(float(p) in have for p in need)
    nv = norm(value)
    return bool(nv) and any(nv in norm(q) for q in quotes)


def _ground_facts(raw: list[RawFact], book: SourceBook, g: Grounded) -> None:
    seen: set[str] = set()
    for f in raw:
        text = f.text.text.strip()
        if f.kind not in FACT_KINDS or not text or not f.value.strip():
            g.dropped.append(Dropped("fact", "malformed", text or f.value, f.kind))
            _bump(g, "facts_dropped_malformed")
            continue
        srcs = _check_text(f.text, book, "fact", f.kind, g)
        if srcs is None:
            continue
        if not _value_supported(f.kind, f.value, [s.span or s.quote for s in srcs]):
            g.dropped.append(Dropped("fact", "value_not_in_quote", f"{text} [{f.value}]", f.kind))
            _bump(g, "facts_dropped_value_not_in_quote")
            continue
        key = norm(text)
        if key in seen:
            continue
        seen.add(key)
        g.facts.append({"id": f"f{len(g.facts) + 1:03d}", "kind": f.kind, "text": text, "value": f.value.strip(),
                        "sources": [s.as_dict() for s in srcs]})


def _ground_terms(raw: list[RawTerm], book: SourceBook, g: Grounded) -> None:
    seen: set[str] = set()
    for t in raw:
        term = t.term.strip()
        if not term or not t.line.text.strip():
            g.dropped.append(Dropped("term", "malformed", term or t.line.text, ""))
            _bump(g, "terms_dropped_malformed")
            continue
        srcs = _check_text(t.line, book, "term", term, g)
        if srcs is None or norm(term) in seen:
            continue
        seen.add(norm(term))
        g.glossary.append({"id": f"g{len(g.glossary) + 1:03d}", "term": term, "line": t.line.text.strip(),
                           "sources": [s.as_dict() for s in srcs]})


# ---------------------------------------------------------------------------------------------- bank


def _ground_bank(raw: list[RawBank], book: SourceBook, langs: list[str], cap: int, g: Grounded) -> None:
    seen: set[str] = set()
    few_para = 0
    for e in raw:
        q = e.question.strip()
        lang = e.lang.strip().lower() or langs[0]
        if lang not in langs:
            lang = langs[0]
        if not q or not e.opener.strip():
            g.dropped.append(Dropped("entry", "malformed", q or e.opener, ""))
            _bump(g, "entries_dropped_malformed")
            continue
        if norm(q) in seen:
            g.dropped.append(Dropped("entry", "duplicate", q, ""))
            _bump(g, "entries_dropped_duplicate")
            continue
        opener = _ground_opener(e.opener, q, g)
        if not opener:
            g.dropped.append(Dropped("entry", "opener_unsupported_number", q, "", e.opener.strip()))
            _bump(g, "entries_dropped_opener")
            continue
        points: list[str] = []
        point_srcs: list[list[Source]] = []
        srcs: list[Source] = []
        for p in e.points:
            ps = _check_text(p, book, "point", q, g)
            if ps is None:
                continue
            points.append(p.text.strip())
            point_srcs.append(ps)
            srcs.extend(ps)
        points, point_srcs = points[:3], point_srcs[:3]
        if not points:
            g.dropped.append(Dropped("entry", "no_sourced_points", q, ""))
            _bump(g, "entries_dropped_no_points")
            continue
        deep = ""
        deep_srcs: list[Source] = []
        if e.deep is not None and e.deep.text.strip():
            ds = _check_text(e.deep, book, "deep", q, g)
            if ds is not None:
                deep = e.deep.text.strip()
                deep_srcs = ds
                srcs.extend(ds)
        paras: dict[str, list[str]] = {}
        for pl in langs:
            vals = _dedupe([x.strip() for x in e.paras.get(pl, []) if x.strip()])
            if vals:
                paras[pl] = vals
            if len(vals) < 3:
                few_para += 1
        seen.add(norm(q))
        bank_id = f"b{len(g.bank) + 1:03d}"
        g.point_sources[bank_id] = {"points": point_srcs, "deep": deep_srcs}
        g.bank.append({
            "id": bank_id, "lang": lang, "question": q, "paraphrases": paras, "opener": opener,
            "points": points, "deep": deep, "sources": [s.as_dict() for s in _dedupe_sources(srcs)],
        })
        if len(g.bank) >= cap:
            break
    g.stats["paraphrase_lists_under_3"] = few_para


_MONTH_WORDS: dict[str, int] = {}
for _i, _names in enumerate([
    ("january", "jan", "gennaio"), ("february", "feb", "febbraio"), ("march", "mar", "marzo"),
    ("april", "apr", "aprile"), ("may", "maggio"), ("june", "jun", "giugno"), ("july", "jul", "luglio"),
    ("august", "aug", "agosto"), ("september", "sep", "sept", "settembre"), ("october", "oct", "ottobre"),
    ("november", "nov", "novembre"), ("december", "dec", "dicembre"),
], start=1):
    for _n in _names:
        _MONTH_WORDS[_n] = _i
_AMBIGUOUS_MONTHS = {"may", "march"}  # also ordinary English words
_ABBREVIATIONS = {"jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"}  # "mar"/"dec" are Italian words too
_WORD = re.compile(r"[A-Za-z]+")
_SENTENCE_END = re.compile(r"[.!?]['\")\]]*\s+$")
# Sentence-initial "May"/"March" is a month before these (or a comma, or a year); "May I", "May we", "March on" are not.
_MONTH_CONTINUATION = re.compile(r"\s+(?:was|is|has|had|will|brought|saw)\b|\s*,|\s+\d{4}\b", re.IGNORECASE)


def _months_in(text: str) -> set[int]:
    """Month numbers named in `text`.
    "may"/"march": next to a number, capitalised mid-sentence, or sentence-initial followed by was/is/has/had/will/
    brought/saw, a comma or a year. 3-letter abbreviations ("mar", "dec", ...): only when capitalised, followed by a
    period, or next to a number, so the Italian words "mar"/"dec" in lowercase prose are not months."""
    out: set[int] = set()
    for m in _WORD.finditer(text):
        word = m.group()
        low = word.lower()
        num = _MONTH_WORDS.get(low)
        if num is None:
            continue
        ambiguous = low in _AMBIGUOUS_MONTHS
        abbreviation = low in _ABBREVIATIONS
        if ambiguous or abbreviation:
            before, after = text[:m.start()], text[m.end():]
            near_number = bool(re.match(r"\.?\s*\d", after)) or bool(re.search(r"\d(?:st|nd|rd|th)?\s+(?:of\s+)?$", before))
            capitalised = word[0].isupper()
            if ambiguous:
                if before.strip() == "" or _SENTENCE_END.search(before):
                    ok = near_number or bool(_MONTH_CONTINUATION.match(after))
                else:
                    ok = near_number or capitalised
            else:
                ok = near_number or capitalised or after.startswith(".")
            if not ok:
                continue
        out.add(num)
    return out


def _ground_opener(opener: str, question: str, g: Grounded) -> str:
    """The opener is read aloud with no source line, so it may not state a number or date its question does not carry.
    Sentences with an unsupported number are cut (recorded in `dropped`); returns "" when nothing is left."""
    allowed = numbers_in(question)
    allowed_months = _months_in(question)
    keep: list[str] = []
    for sent in re.split(r"(?<=[.!?])\s+", opener.strip()):
        if not sent:
            continue
        if not all(any(abs(n - h) < 1e-9 for h in allowed) for n in significant_numbers(sent)):
            g.dropped.append(Dropped("opener", "unsupported_number", sent, question))
            _bump(g, "opener_sentences_dropped_unsupported_number")
        elif not _months_in(sent) <= allowed_months:
            g.dropped.append(Dropped("opener", "unsupported_month", sent, question))
            _bump(g, "opener_sentences_dropped_unsupported_month")
        else:
            keep.append(sent)
    return " ".join(keep)


def _dedupe(xs: list[str]) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for x in xs:
        k = norm(x)
        if k not in seen:
            seen.add(k)
            out.append(x)
    return out


def _dedupe_sources(srcs: list[Source]) -> list[Source]:
    out: list[Source] = []
    seen: set[tuple[str, str]] = set()
    for s in srcs:
        k = (s.ref, norm(s.quote))
        if k not in seen:
            seen.add(k)
            out.append(s)
    return out
