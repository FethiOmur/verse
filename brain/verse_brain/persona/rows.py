"""The rows of a finished session, read headless from its folder: the persona's only view of what was said.

The Swift app builds the transcript the owner sees in `TranscriptDocument` (app/Sources/VerseUI/TranscriptDocument.swift). The
persona must run without the app (the one-time backfill is a command line run), so this module reads the same two files the
same way:

  transcript.jsonl   one line per finalized turn: {turn_id, speaker me|remote|room, text, t_audio_end, lang, run_start, t_wall}
  events.jsonl       the brain's decisions; read here: `start` (legacy run alignment), `room_text` (own-voice relabels of room
                     rows), the cards (`card_done`, or `card` lines when no `card_done` exists for that id), the owner's live
                     marks on cards (`card_mark`, see `read_marks`) and which bank entry stood on a turn (`bank_verdict`,
                     `own_card`; `bank_hits`)

Ported rules, in the Swift order: runs (forward lines group by `run_start`; legacy lines split on a repeated turn id or a drop of
more than 30 s), legacy runs aligned to the last `start` events, a repeated turn id inside a run replaced in place, rows sorted by
`t_audio_end` inside a run, elapsed time from the earliest run start when every run knows its wall start (else runs placed one
after another), stamps "m:ss" / "h:mm:ss" rounded down, and room rows relabelled `me` (or split) by `room_text` finals. The fixture
test pins the result (tests/test_persona_rows.py), so a change on either side shows up there.

Roles: `me` (the owner's microphone, or a relabelled room text), `other` (the remote side) and `room` (one mic, either voice).

Evidence (owner rows only), computed here because nothing on disk records it: each `me` row is matched against every card the
session showed with the room route's strict in-order measure (runtime/own.py: content-word stems, at most 3 card words skipped):

  read    at least `min_matched` (5) content words on the path and `enter` (75 %) of the row's content words: he read the card
  mixed   at least 5 content words on the path but under 75 %: his own words around a read stretch
  own     anything else: his own words

`read` and `mixed` rows may carry the card's numbers, names and dates, which are model output: persona/extract.py keeps those only
when an already confirmed source has them.

Comparing against every card of the session (not only the one on screen) needs no wall clock, so legacy sessions are classified the
same way. A false `read` costs one item at most; a missed one is the risk the confirmation rule guards against.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from dataclasses import dataclass, field
from pathlib import Path

from ..runtime.own import OwnParams, aligned, content_stems

ROLES = ("me", "other", "room")
EVIDENCE = ("own", "read", "mixed")


@dataclass(frozen=True)
class PRow:
    stamp: str
    role: str                  # me | other | room
    text: str
    turn_id: str
    lang: str = "en"
    evidence: str | None = None    # own | read | mixed for `me` rows; None otherwise
    card_share: float = 0.0        # best strict share against a card of the session (me rows)
    kind: str = ""                 # the transcript's kind: question | statement | fragment ("" when the line has none)

    def as_dict(self) -> dict:
        return {"stamp": self.stamp, "role": self.role, "text": self.text, "turn_id": self.turn_id, "lang": self.lang,
                "evidence": self.evidence}


@dataclass(frozen=True)
class CardRec:
    """One card the session showed: its call id, the turn it answered (the question's turn id) and its text."""
    id: str
    turn: str
    text: str
    say: str = ""
    points: tuple[str, ...] = ()


MARKS = ("good", "bad", "cleared")


@dataclass(frozen=True)
class Mark:
    """The owner's live mark on an answer card (events.jsonl `card_mark`, see `read_marks`)."""
    card: str
    mark: str                  # good | bad | cleared
    t: float
    turn: str = ""
    question: str = ""


@dataclass
class SessionRows:
    name: str
    rows: list[PRow] = field(default_factory=list)
    cards: list[str] = field(default_factory=list)          # every card's text (SAY line and points), in log order
    card_records: list[CardRec] = field(default_factory=list)   # the same cards with their id and turn
    marks: list[Mark] = field(default_factory=list)         # every live mark, in log order (`final_marks` folds them)
    bank_hits: dict[str, str] = field(default_factory=dict)  # turn -> the bank entry id whose card stood on it (`bank_hits`)
    bank: dict[str, dict] = field(default_factory=dict)      # the session's own bank.jsonl (id -> record): what those ids were

    def count(self, role: str, evidence: str | None = None) -> int:
        return sum(1 for r in self.rows if r.role == role and (evidence is None or r.evidence == evidence))

    @property
    def owner_rows(self) -> list[PRow]:
        return [r for r in self.rows if r.role == "me"]

    def fingerprint(self) -> str:
        """sha256 of what the persona sees of this session: the classified rows and the cards. A re-run with the same value is a
        no-op (the session did not change)."""
        h = hashlib.sha256()
        for r in self.rows:
            h.update(json.dumps([r.stamp, r.role, r.evidence, r.text], ensure_ascii=False).encode())
            h.update(b"\n")
        for c in self.cards:
            h.update(c.encode())
            h.update(b"\n")
        for m in self.marks:              # only a session with marks hashes them, so older fingerprints stay as they were
            h.update(json.dumps(["mark", m.card, m.mark, m.t], ensure_ascii=False).encode())
            h.update(b"\n")
        return h.hexdigest()


# ---------------------------------------------------------------- reading
@dataclass
class _Line:
    turn_id: str
    speaker: str
    text: str
    t_audio_end: float
    run_start: float | None
    t_wall: float | None
    lang: str
    kind: str = ""


@dataclass
class _Run:
    lines: list[_Line]
    forward_start: float | None
    wall_start: float | None


def _num(v: object) -> float | None:
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return float(v)


def _objects(path: Path) -> list[dict]:
    """JSON objects of a JSON-lines file; a bad line (a writer caught mid-line) is skipped, a missing file is empty."""
    try:
        text = path.read_bytes().decode("utf-8", errors="replace")
    except OSError:
        return []
    out = []
    for ln in text.splitlines():
        ln = ln.strip()
        if not ln:
            continue
        try:
            o = json.loads(ln)
        except ValueError:
            continue
        if isinstance(o, dict):
            out.append(o)
    return out


def read_lines(path: Path) -> list[_Line]:
    out = []
    for o in _objects(path):
        tid, text = o.get("turn_id"), o.get("text")
        if not isinstance(tid, str) or not isinstance(text, str) or not text.strip():
            continue
        sp = o.get("speaker") if isinstance(o.get("speaker"), str) else "remote"
        lang = o.get("lang") if o.get("lang") in ("en", "it", "tr") else "en"
        kind = o.get("kind") if isinstance(o.get("kind"), str) else ""
        out.append(_Line(tid, sp, text.strip(), _num(o.get("t_audio_end")) or 0.0, _num(o.get("run_start")), _num(o.get("t_wall")),
                         lang, kind))
    return out


def stamp(seconds: float) -> str:
    s = max(0, int(math.floor(seconds)))
    h, m, sec = s // 3600, (s % 3600) // 60, s % 60
    return f"{h}:{m:02d}:{sec:02d}" if h > 0 else f"{m}:{sec:02d}"


def _segment(lines: list[_Line]) -> list[_Run]:
    runs: list[_Run] = []
    seen: set[str] = set()
    max_end = 0.0
    for line in lines:
        if line.run_start is not None:
            key = round(line.run_start * 1000)
            last = runs[-1] if runs else None
            if last is not None and last.forward_start is not None and round(last.forward_start * 1000) == key:
                last.lines.append(line)
            else:
                runs.append(_Run([line], line.run_start, line.run_start))
            seen = set()
            continue
        last = runs[-1] if runs else None
        if last is not None and last.forward_start is None:
            starts_new = line.turn_id in seen or line.t_audio_end < max_end - 30
        else:
            starts_new = True
        if starts_new:
            runs.append(_Run([line], None, None))
            seen = {line.turn_id}
            max_end = line.t_audio_end
        else:
            last.lines.append(line)
            seen.add(line.turn_id)
            max_end = max(max_end, line.t_audio_end)
    return runs


def _align_starts(runs: list[_Run], events: list[dict]) -> None:
    legacy = [i for i, r in enumerate(runs) if r.forward_start is None]
    if not legacy:
        return
    first_fwd = next((i for i, r in enumerate(runs) if r.forward_start is not None), None)
    if first_fwd is not None and any(i > first_fwd for i in legacy):
        return
    starts = sorted(t for t in (_num(e.get("t")) for e in events if e.get("ev") == "start") if t is not None)
    fwd = [r.forward_start for r in runs if r.forward_start is not None]
    if fwd:
        first = min(fwd)
        starts = [s for s in starts if s < first - 30]
    if len(starts) < len(legacy):
        return
    for j, i in enumerate(legacy):
        runs[i].wall_start = starts[len(starts) - len(legacy) + j]


def _dedup(lines: list[_Line]) -> list[_Line]:
    out: list[_Line] = []
    at: dict[str, int] = {}
    for line in lines:
        if line.turn_id in at:
            prev = out[at[line.turn_id]]
            out[at[line.turn_id]] = _Line(prev.turn_id, prev.speaker, line.text, prev.t_audio_end, prev.run_start, prev.t_wall,
                                          prev.lang, line.kind or prev.kind)
        else:
            at[line.turn_id] = len(out)
            out.append(line)
    return out


def _role(speaker: str) -> str:
    return "me" if speaker == "me" else "room" if speaker == "room" else "other"


@dataclass
class _Row:
    turn_id: str
    elapsed: float
    wall: float | None
    role: str
    text: str
    lang: str
    kind: str = ""


def _index_after_words(n: int, text: str) -> int:
    words, in_word = 0, False
    for i, ch in enumerate(text):
        space = ch.isspace()
        if not space and not in_word:
            words += 1
            if words == n + 1:
                return i
        in_word = not space
    return len(text)


def _relabel_room(rows: list[_Row], events: list[dict], wall_known: bool) -> list[_Row]:
    finals = [(i, e) for i, e in enumerate(events)
              if e.get("ev") == "room_text" and e.get("final") is True and isinstance(e.get("turn"), str) and _num(e.get("t")) is not None]
    if not finals or not any(r.role == "room" for r in rows):
        return rows
    by_turn: dict[str, list[tuple[int, dict]]] = {}
    for i, e in finals:
        by_turn.setdefault(e["turn"], []).append((i, e))
    for k in by_turn:
        by_turn[k].sort(key=lambda p: _num(p[1].get("t")) or 0.0)
    room_counts: dict[str, int] = {}
    for r in rows:
        if r.role == "room":
            room_counts[r.turn_id] = room_counts.get(r.turn_id, 0) + 1
    used: set[int] = set()
    ordinal: dict[str, int] = {}
    out: list[_Row] = []
    for row in rows:
        cands = by_turn.get(row.turn_id) if row.role == "room" else None
        if not cands:
            out.append(row)
            continue
        chosen = None
        if wall_known and row.wall is not None:
            free = [c for c in cands if c[0] not in used]
            if free:
                best = min(free, key=lambda c: abs((_num(c[1].get("t")) or 0.0) - row.wall))
                if abs((_num(best[1].get("t")) or 0.0) - row.wall) <= 30:
                    used.add(best[0])
                    chosen = best[1]
        else:
            k = ordinal.get(row.turn_id, 0)
            ordinal[row.turn_id] = k + 1
            if room_counts.get(row.turn_id) == len(cands):
                chosen = cands[k][1]
        if chosen is None:
            out.append(row)
            continue
        label = chosen.get("label")
        if label == "me":
            out.append(_Row(row.turn_id, row.elapsed, row.wall, "me", row.text, row.lang, row.kind))
        elif label == "split":
            n = _num(chosen.get("me_words"))
            if not n or n <= 0:
                out.append(row)
                continue
            cut = _index_after_words(int(n), row.text)
            mine, rest = row.text[:cut].strip(), row.text[cut:].strip()
            out.append(_Row(row.turn_id, row.elapsed, row.wall, "me", mine, row.lang, "statement"))
            if rest:
                out.append(_Row(row.turn_id, row.elapsed, row.wall, "room", rest, row.lang, ""))
        else:
            out.append(row)
    return out


def build_rows(lines: list[_Line], events: list[dict]) -> list[_Row]:
    runs = _segment(lines)
    _align_starts(runs, events)
    all_wall = bool(runs) and all(r.wall_start is not None for r in runs)
    base = min(r.wall_start for r in runs) if all_wall else 0.0
    rows: list[_Row] = []
    cumulative = 0.0
    previous_end = 0.0
    for run in runs:
        ordered = [ln for _, ln in sorted(enumerate(_dedup(run.lines)), key=lambda p: (p[1].t_audio_end, p[0]))]
        start = max((run.wall_start or 0.0) - base if all_wall else cumulative, previous_end)
        for ln in ordered:
            wall = None
            if all_wall:
                wall = ln.t_wall if ln.t_wall is not None else (run.wall_start + ln.t_audio_end if run.wall_start is not None else None)
            rows.append(_Row(ln.turn_id, start + ln.t_audio_end, wall, _role(ln.speaker), ln.text, ln.lang, ln.kind))
        end = max((ln.t_audio_end for ln in ordered), default=0.0)
        cumulative = start + end
        previous_end = max(previous_end, rows[-1].elapsed if rows else previous_end)
    return _relabel_room(rows, events, all_wall)


def session_card_records(events: list[dict]) -> list[CardRec]:
    """Every card the session showed (id, the turn it answered, SAY line and points as one text). `card_done` carries the whole
    card; a call id without one falls back to its `card` lines (the first 60 characters of each line)."""
    done_ids = {e.get("id") for e in events if e.get("ev") == "card_done" and isinstance(e.get("id"), str)}
    cards: list[CardRec] = []
    partial: dict[str, list[str]] = {}
    turns: dict[str, str] = {}
    order: list[str] = []
    for e in events:
        turn = e.get("turn") if isinstance(e.get("turn"), str) else ""
        if e.get("ev") == "card_done":
            parts = [e.get("say")] if isinstance(e.get("say"), str) else []
            parts += [p for p in e.get("points") or [] if isinstance(p, str)]
            text = " ".join(p.strip() for p in parts if p and p.strip())
            if text:
                pts = tuple(p.strip() for p in e.get("points") or [] if isinstance(p, str) and p.strip())
                say = e["say"].strip() if isinstance(e.get("say"), str) else ""
                cards.append(CardRec(e.get("id") if isinstance(e.get("id"), str) else "", turn, text, say, pts))
        elif e.get("ev") == "card" and isinstance(e.get("text"), str) and e["text"].strip():
            cid = e.get("id") if isinstance(e.get("id"), str) else f"_{len(order)}"
            if cid in done_ids:
                continue
            if cid not in partial:
                partial[cid] = []
                turns[cid] = turn
                order.append(cid)
            partial[cid].append(e["text"].strip())
    cards += [CardRec(c if not c.startswith("_") else "", turns[c], " ".join(partial[c]), " ".join(partial[c])) for c in order]
    return cards


def session_cards(events: list[dict]) -> list[str]:
    """Every card's text (see `session_card_records`)."""
    return [c.text for c in session_card_records(events)]


def read_marks(events: list[dict]) -> list[Mark]:
    """The owner's live marks on answer cards, in log order. The line (written into events.jsonl by the live brain, the
    events.py convention: one compact JSON object, `t` the wall clock in seconds):

      {"t": 1795000050.123, "ev": "card_mark", "card": "F-r2", "mark": "good" | "bad" | "cleared", "turn": "r2",
       "question": "<first 80 characters of the question>"}

    `card` (the card's call id, as in its `card` / `card_done` lines) and `mark` are required; `turn` and `question` are optional
    (the turn is looked up from the card's own lines when missing). A line that does not fit is skipped."""
    out = []
    for e in events:
        if e.get("ev") != "card_mark":
            continue
        card, mark, t = e.get("card"), e.get("mark"), _num(e.get("t"))
        if not isinstance(card, str) or not card or mark not in MARKS or t is None:
            continue
        out.append(Mark(card, mark, t, e.get("turn") if isinstance(e.get("turn"), str) else "",
                        " ".join(e["question"].split()) if isinstance(e.get("question"), str) else ""))
    return out


def bank_hits(events: list[dict]) -> dict[str, str]:
    """turn -> the answer-bank entry id whose card stood on that turn at the end: a `bank_verdict` that agreed, or an `own_card`
    taken from the bank; a verdict that disagreed pulls the card again."""
    hits: dict[str, str] = {}
    for e in events:
        turn, bank = e.get("turn"), e.get("bank")
        if not isinstance(turn, str) or not isinstance(bank, str) or not bank:
            continue
        if e.get("ev") == "bank_verdict":
            if e.get("agree") is True:
                hits[turn] = bank
            elif hits.get(turn) == bank:
                del hits[turn]
        elif e.get("ev") == "own_card" and e.get("source") == "bank":
            hits[turn] = bank
    return hits


def session_bank(d: Path) -> dict[str, dict]:
    """The session folder's own bank.jsonl (copied in from the compiled persona or the general prep when the call started)."""
    out = {}
    for o in _objects(d / "bank.jsonl"):
        if isinstance(o.get("id"), str):
            out[o["id"]] = o
    return out


def final_marks(marks: list[Mark]) -> dict[str, Mark]:
    """card id -> its last mark (by time, then log order); a card whose last mark is `cleared` has none."""
    last: dict[str, Mark] = {}
    for _, m in sorted(enumerate(marks), key=lambda p: (p[1].t, p[0])):
        last[m.card] = m
    return {c: m for c, m in last.items() if m.mark != "cleared"}


def classify(text: str, cards: list[str], lang: str = "en", params: OwnParams | None = None) -> tuple[str, float]:
    """(own | read | mixed, best strict share) of an owner row against the session's cards (see the module doc)."""
    p = params or OwnParams()
    mine = content_stems(text, lang)
    if not mine or not cards:
        return "own", 0.0
    best_n = 0
    for c in cards:
        n = aligned(mine, content_stems(c, lang), p.max_gap)
        best_n = max(best_n, n)
    share = best_n / len(mine)
    if best_n >= p.min_matched:
        return ("read" if share >= p.enter else "mixed"), share
    return "own", share


# ---------------------------------------------------------------- the words of spoken rows (English, Italian, Turkish)
def _wkey(w: str) -> str:
    return re.sub(r"[^\w]", "", w.casefold())


ACK = frozenset("""yeah yes yep yup no nope ok okay right sure mhm mmhm mm hmm uh um huh ah oh wow great nice cool perfect
exactly absolutely totally true indeed thanks thank you got it i see good interesting awesome alright of course fine makes sense
sounds sì si certo esatto vero perfetto bene va giusto chiaro capito ottimo evet tamam aynen doğru harika süper anladım peki hı
""".split())


def is_backchannel(text: str) -> bool:
    """An acknowledgement, not a turn: every word is one ("yeah", "okay okay", "of course", "mhm", "esatto", "tamam")."""
    words = [k for k in (_wkey(w) for w in text.split()) if k]
    return bool(words) and all(w in ACK for w in words)


def _contains(hay: list[str], needle: list[str]) -> bool:
    return f" {' '.join(needle)} " in f" {' '.join(hay)} "


def merge_rows(texts: list[str]) -> str:
    """Rows of a rolling transcript as one text, each word once. Live speech recognition writes a row, then a longer take of
    the same words, or a next row that starts with the last words of the previous one: a row that repeats the start of the one
    before (at least half of it) replaces it, a row already said is skipped, and an overlap of 2+ words with the text so far is
    joined once."""
    kept: list[list[str]] = []
    for t in texts:
        w = t.split()
        if not w:
            continue
        if kept:
            last, k = [_wkey(x) for x in kept[-1]], [_wkey(x) for x in w]
            p = 0
            while p < min(len(last), len(k)) and last[p] == k[p]:
                p += 1
            if p >= min(3, len(last)) and p * 2 >= len(last):
                if len(w) > len(kept[-1]):
                    kept[-1] = w
                continue
        kept.append(w)
    flat: list[str] = []
    for w in kept:
        fk, k = [_wkey(x) for x in flat], [_wkey(x) for x in w]
        if len(k) >= 3 and _contains(fk, k):
            continue
        n = next((n for n in range(min(len(fk), len(k)), 1, -1) if fk[-n:] == k[:n]), 0)
        flat += w[n:]
    return " ".join(flat)


def owner_turns(rows: list[PRow]) -> dict[int, str]:
    """row index -> the owner's whole turn around that row, as one text (`merge_rows`): his consecutive rows, across the other
    side's acknowledgements. Live recognition cuts one spoken turn into rolling rows, so a name he said is often in the next or
    previous row of the same turn rather than in the one an item quotes."""
    out: dict[int, str] = {}
    run: list[int] = []

    def close() -> None:
        if run:
            text = merge_rows([rows[i].text for i in run])
            out.update({i: text for i in run})
        run.clear()

    for i, r in enumerate(rows):
        if r.role == "me":
            run.append(i)
        elif not is_backchannel(r.text):
            close()
    close()
    return out


def load_session_rows(session_dir: Path | str) -> SessionRows:
    """The classified rows of one session folder. A missing transcript gives no rows (nothing raises)."""
    d = Path(session_dir).expanduser()
    events = _objects(d / "events.jsonl")
    recs = session_card_records(events)
    cards = [c.text for c in recs]
    rows: list[PRow] = []
    for r in build_rows(read_lines(d / "transcript.jsonl"), events):
        if not r.text:
            continue
        if r.role == "me":
            ev, share = classify(r.text, cards, r.lang)
            rows.append(PRow(stamp(r.elapsed), "me", " ".join(r.text.split()), r.turn_id, r.lang, ev, round(share, 3), r.kind))
        else:
            rows.append(PRow(stamp(r.elapsed), r.role, " ".join(r.text.split()), r.turn_id, r.lang, kind=r.kind))
    return SessionRows(d.name, rows, cards, recs, read_marks(events), bank_hits(events), session_bank(d))
