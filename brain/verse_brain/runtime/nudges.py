"""Live nudges, runtime side: pure state for topic-triggered suggestions (docs/specs/2026-11-27-live-nudges-plan.md).

The engine owns the I/O (the tier-K call, the `nudge` / `nudge_clear` events); this module decides:

- `load(path)`: the session's `nudges.jsonl`, tolerant: a missing or malformed file means no nudges, never an error.
- `NudgeTracker.on_turn`: every final turn of `me` and `remote` (never `room`). It runs the money rule (`Until: number`
  retires a nudge once an amount of money is said, and asks to clear it when it is on screen) and stage A, the local gate: a
  still-armed nudge whose `Keys` occur in the words the newest turn added and whose `Who` / `After` / `Until` gates pass is a
  candidate; every `sweep_every` utterances (of SWEEP_MIN_WORDS words or more) without an evaluation all armed nudges are
  nominated. At most `max_candidates` go to one evaluation, with the window.
- The window: final rows are merged into utterances (consecutive rows of one speaker; a growing or repeated row adds only its
  new words; fillers and stutter dropped), then the last two utterances, or those of the last 25 s of audio if that is more,
  capped at WINDOW_WORDS words. A row that adds nothing new is not evaluated. While a nudge is cooling down nothing is.
- `defer` / `take_pending`: an evaluation that meets a K call in flight is not dropped; its candidates get one catch-up over the
  then-current window when that call returns.
- `NudgeTracker.judge`: the K call's line `NUDGE: <id> | "<quote>" | <them|me>`. A nudge fires only when the id was a
  candidate and is still armed, every checked part of the quote (split at an ellipsis) occurs in order in window utterances of
  one speaker (`find_quote`: fillers ignored, at most QUOTE_GAP words skipped, one added word per QUOTE_MISS_EVERY tolerated),
  that speaker is the one the judge stated and the one its `Who` allows, the gates still pass, no nudge fired in the last
  `cooldown_s` of audio, and the result came within `max_age_s` of the launch. Each nudge fires once per call. The sweep is
  off by default (SWEEP_EVERY 0): a nudge then needs a key in the words a turn added.

Times: the audio clock is the turns' `t_audio_end` (seconds since the run started, Swift VerseRunner); without one the tracker's
own clock since it was made stands in. The result age is measured on the tracker's clock (wall, monotonic).
"""

from __future__ import annotations

import json
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

TTL_S = 25          # seconds; an int on the wire (`nudge.ttl_s`)
COOLDOWN_S = 60.0
MAX_AGE_S = 8.0
SWEEP_EVERY = 0          # 0: no sweep, a nudge needs a key in the new words (VERSE_NUDGE_SWEEP=N turns it on)
MAX_CANDIDATES = 3
WINDOW_TURNS = 2
WINDOW_S = 25.0
WINDOW_WORDS = 120       # after fillers and stutter are removed
UTT_MAX_WORDS = 300
QUOTE_GAP = 2
SWEEP_MIN_WORDS = 4      # a backchannel ("yeah", "okay", "sorry") does not count towards the sweep
QUOTE_MAX_WORDS = 30
QUOTE_MISS_EVERY = 8     # one quoted word in eight may be missing from the window (none below eight words)
QUOTE_PART_MIN = 3       # words; a shorter part around an ellipsis is not checked
MAX_NUDGES = 8
SPEAKERS = ("me", "remote")
WHO_SPEAKER = {"me": "me", "them": "remote"}

_TOKEN = re.compile(r"[\w']+", re.UNICODE)

# --------------------------------------------------------------------------------------------- money
_NUMWORD = (r"(?:a|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|"
            r"seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|a\s+hundred)")
_CURWORD = r"(?:francs?|euros?|dollars?|pounds?|bucks|chf|usd|eur|gbp|lira|liras|lire)"
_MONEY = re.compile(
    r"[$€£¥₺]\s?\d"                                                          # $80, € 5
    r"|\d[\d.,']*\s?(?:k|m|mn|bn)\b"                                          # 80k, 1.5m
    r"|\d[\d.,']*\s*(?:thousand|grand|million|billion)\b"                    # 80 thousand
    r"|\d[\d.,']*\s*" + _CURWORD + r"\b"                                     # 5000 francs
    r"|\b" + _CURWORD + r"\s?\d"                                             # CHF 90
    r"|\b" + _NUMWORD + r"(?:[\s-]+(?:" + _NUMWORD + r"|and))*\s+(?:thousand|grand|million|billion)\b"   # eighty five thousand
    r"|\b" + _NUMWORD + r"(?:[\s-]+(?:" + _NUMWORD + r"|and))*\s+" + _CURWORD + r"\b",                     # fifty euros
    re.IGNORECASE)


def says_money(text: str) -> bool:
    """True when the text names an amount of money (digits with a currency word or symbol, k, thousand, or number words
    followed by thousand / a currency word). Deterministic, English."""
    return bool(_MONEY.search(text or ""))


# --------------------------------------------------------------------------------------------- records
@dataclass(frozen=True)
class Nudge:
    id: str
    title: str
    when: str
    keys: tuple[str, ...]
    say: tuple[str, ...]
    who: str = "any"
    until: str | None = None
    after_s: float = 0.0
    ref: str = ""


def _record(o: object) -> Nudge | None:
    if not isinstance(o, dict):
        return None
    nid, when, keys, say = o.get("id"), o.get("when"), o.get("keys"), o.get("say")
    if not (isinstance(nid, str) and re.fullmatch(r"n\d{3}", nid) and isinstance(when, str) and when.strip()):
        return None
    if not (isinstance(keys, list) and keys and all(isinstance(k, str) and k.strip() for k in keys)):
        return None
    if not (isinstance(say, list) and 1 <= len(say) <= 3 and all(isinstance(s, str) and s.strip() for s in say)):
        return None
    who = o.get("who", "any")
    until = o.get("until")
    after = o.get("after_s", 0)
    if who not in ("any", "me", "them") or until not in (None, "number"):
        return None
    if not isinstance(after, (int, float)) or isinstance(after, bool) or after < 0:
        return None
    title = o.get("title") if isinstance(o.get("title"), str) and o.get("title").strip() else "Nudge"
    return Nudge(nid, title.strip(), " ".join(when.split()), tuple(" ".join(k.lower().split()) for k in keys),
                 tuple(" ".join(s.split()) for s in say), who, until, float(after), str(o.get("ref") or ""))


def load(path: str | Path) -> list[Nudge]:
    """The nudges of `path` (`<session>/nudges.jsonl`), sorted by id. A missing, unreadable or malformed file gives []: a bad
    file turns nudges off, it never stops the session. A record that breaks the schema drops the whole file too (it was not
    written by the prep step)."""
    try:
        p = Path(path)
        if not p.is_file():
            return []
        out: list[Nudge] = []
        for ln in p.read_text(encoding="utf-8").splitlines():
            if not ln.strip():
                continue
            rec = _record(json.loads(ln))
            if rec is None:
                return []
            out.append(rec)
        if len({n.id for n in out}) != len(out):
            return []
        return sorted(out, key=lambda n: n.id)[:MAX_NUDGES]
    except Exception:  # noqa: BLE001 - any problem with the file means no nudges
        return []


# --------------------------------------------------------------------------------------------- text helpers
# Speech recognition fills turns with these; they are dropped from the window and ignored when a quote is checked.
FILLERS = frozenset({"um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "eh", "hmm", "hm", "mm", "mhm"})


def _norm_word(w: str) -> str:
    return re.sub(r"[^\w']", "", w.replace("’", "'").replace("‘", "'").lower())


def words(text: str) -> list[str]:
    return _TOKEN.findall((text or "").replace("’", "'").replace("‘", "'").lower())


def _collapse(items: list, keys: list[str]) -> list:
    """Drops an immediate repeat of the last 1-3 words ("if if if" -> "if", "yeah yeah" -> "yeah", "the the" -> "the"):
    recogniser stutter. `keys` are the normalised forms of `items`."""
    out, ok = [], []
    i = 0
    while i < len(items):
        for n in (3, 2, 1):
            if len(ok) >= n and i + n <= len(items) and keys[i:i + n] == ok[-n:]:
                i += n
                break
        else:
            out.append(items[i])
            ok.append(keys[i])
            i += 1
    return out


def clean_words(text: str) -> list[str]:
    """The words of a recognised turn as shown to the judge: fillers dropped, stutter collapsed, punctuation kept."""
    ws = [w for w in (text or "").split() if _norm_word(w) and _norm_word(w) not in FILLERS]
    return _collapse(ws, [_norm_word(w) for w in ws])


def norm_tokens(text: str) -> list[str]:
    """Tokens for comparing a quote with the window: lower case, no punctuation, no fillers, stutter collapsed."""
    toks = [t for t in words(text) if t not in FILLERS]
    return _collapse(toks, toks)


def key_hits(keys: tuple[str, ...], text: str) -> int:
    """How many of `keys` occur in `text`: every word of a key must start a word of the text, in order (word prefixes:
    "compensat" matches "compensation")."""
    toks = norm_tokens(text)
    n = 0
    for k in keys:
        kw = words(k)
        if not kw:
            continue
        for i in range(len(toks) - len(kw) + 1):
            if all(toks[i + j].startswith(kw[j]) for j in range(len(kw))):
                n += 1
                break
    return n


def contains_words(hay: list[str], needle: list[str]) -> bool:
    if not needle or len(needle) > len(hay):
        return False
    return any(hay[i:i + len(needle)] == needle for i in range(len(hay) - len(needle) + 1))


def find_quote(hay: list[str], quote: list[str], start: int = 0, gap: int = QUOTE_GAP) -> int:
    """The index after the match of `quote` in `hay[start:]`, or -1. The words of `quote` must occur in order, with at most
    `gap` words of `hay` skipped between two matched words (the judge may drop a filler or a repeated word the cleaning missed),
    and at most one quoted word in QUOTE_MISS_EVERY may be missing from `hay` (a word the judge added: "the start date" for
    "start date"). Both are `norm_tokens`."""
    if not quote or not hay:
        return -1
    budget = len(quote) // QUOTE_MISS_EVERY
    for s in range(start, len(hay)):
        for k in range(min(budget, len(quote) - 1) + 1):      # the first k quoted words may be the added ones
            if hay[s] != quote[k]:
                continue
            pos, misses, ok = s, k, True
            for q in quote[k + 1:]:
                nxt = next((p for p in range(pos + 1, min(len(hay), pos + 2 + gap)) if hay[p] == q), None)
                if nxt is not None:
                    pos = nxt
                elif misses < budget:
                    misses += 1
                else:
                    ok = False
                    break
            if ok:
                return pos + 1
    return -1


def quote_in(hay: list[str], quote: list[str], gap: int = QUOTE_GAP) -> bool:
    return find_quote(hay, quote, 0, gap) >= 0


_ELLIPSIS = re.compile(r"\.{2,}|…")


def quote_parts(quote: str) -> list[list[str]]:
    """The parts of a quote that are checked: split at an ellipsis ("..." or "…"); a part of fewer than QUOTE_PART_MIN words
    is ignored unless it is the only part."""
    parts = [norm_tokens(p) for p in _ELLIPSIS.split(quote or "")]
    parts = [p for p in parts if p]
    if len(parts) == 1:
        return parts
    return [p for p in parts if len(p) >= QUOTE_PART_MIN]


def _overlap(a: list[str], b: list[str]) -> int:
    """The longest k with a[-k:] == b[:k]."""
    for k in range(min(len(a), len(b)), 0, -1):
        if a[-k:] == b[:k]:
            return k
    return 0


_NUDGE_LINE = re.compile(r"^\s*\**\s*NUDGE\s*:\s*(.*?)\s*$", re.IGNORECASE)
_PICK = re.compile(r"^\[?(n\d{3})\]?\s*\|\s*(.*)$", re.IGNORECASE)
_CLOSERS = {'"': '"', "“": "”\"", "'": "'’", "‘": "’'", "`": "`"}
_WHO_FIELD = re.compile(r"^\s*\|\s*[\[(<]?\s*(them|me)\s*[\])>]?\s*[.!]?\s*$", re.IGNORECASE)
_NEGATED = re.compile(r"\b(not|no|isn't|aren't|doesn't|none)\b", re.IGNORECASE)


@dataclass
class Verdict:
    """The K call's line, parsed. `id` None: no pick (`why` says: none, garbage, not_quotation, unclosed, negated)."""
    id: str | None
    quote: str | None = None
    who: str | None = None              # "them" | "me" as the judge stated it; None when the field is missing or other
    why: str = "none"


def parse_output(text: str) -> Verdict:
    """`NUDGE: <id> | "<quote>" | <them|me>` -> a pick; `NUDGE: none`, no NUDGE line or a malformed one -> no pick. Only the first
    NUDGE line counts. The text after the id must start as a quotation; the quote ends at the last matching closing mark before
    the who field. A line that says the moment is not happening (a negation after the quote) is none."""
    for ln in (text or "").splitlines():
        m = _NUDGE_LINE.match(ln)
        if not m:
            continue
        body = m.group(1)
        if re.match(r"^\[?none\b", body, re.IGNORECASE):
            return Verdict(None, why="none")
        p = _PICK.match(body)
        if not p:
            return Verdict(None, why="garbage")
        nid, rest = p.group(1).lower(), p.group(2).strip()
        if not rest or rest[0] not in _CLOSERS:
            return Verdict(None, why="not_quotation")
        after = rest[1:]
        bar = after.rfind("|")
        seg = after[:bar] if bar >= 0 else after
        ci = max(seg.rfind(c) for c in _CLOSERS[rest[0]])
        if ci < 0:
            return Verdict(None, why="unclosed")
        quote = seg[:ci].strip()
        trailing = seg[ci + 1:]
        if _NEGATED.search(trailing):
            return Verdict(None, quote=quote, why="negated")
        if not quote:
            return Verdict(None, why="not_quotation")
        w = _WHO_FIELD.match(after[bar:]) if bar >= 0 and not trailing.strip() else None
        return Verdict(nid, quote, w.group(1).lower() if w else None, "pick")
    return Verdict(None, why="garbage")


# --------------------------------------------------------------------------------------------- tracker
@dataclass
class Evaluation:
    """One stage-B request: what the K call is asked about, as it was when it was launched."""
    turn_id: str
    candidates: list[str]
    window: list[tuple[str, str]]        # (speaker, text) of merged utterances, oldest first
    reason: str                          # "keys" | "sweep" | "keys+sweep" | "catch_up"
    t0: float = 0.0                      # tracker clock at launch (set by `launched`)


@dataclass
class TurnResult:
    retired: list[str] = field(default_factory=list)    # nudges the money rule retired with this turn
    clear: list[str] = field(default_factory=list)      # of those, the ones on screen now: send `nudge_clear`
    evaluation: Evaluation | None = None                 # stage B is wanted for these candidates
    key_hits: list[str] = field(default_factory=list)   # candidates nominated by a key word
    new_words: int = 0                                   # words this turn added to the conversation (0: a repeat)


@dataclass
class Fire:
    nudge: Nudge
    turn_id: str
    quote: str
    speaker: str


@dataclass
class _Utt:
    """Consecutive final turns of one speaker, merged: the recogniser sends growing and repeated rows ("I think you can" then
    "I think you can understand it"), so a row's words are appended only where they extend what is already there."""
    speaker: str
    words: list[str]
    norms: list[str]
    t_end: float | None
    counted: bool = False        # counted towards the sweep (once it holds SWEEP_MIN_WORDS words)


class NudgeTracker:
    def __init__(self, nudges: list[Nudge], clock: Callable[[], float] = time.monotonic, *, ttl_s: float = TTL_S,
                 cooldown_s: float = COOLDOWN_S, max_age_s: float = MAX_AGE_S, sweep_every: int = SWEEP_EVERY,
                 max_candidates: int = MAX_CANDIDATES) -> None:
        self.nudges = {n.id: n for n in nudges}
        self.armed: set[str] = set(self.nudges)
        self.fired: list[str] = []
        self.retired: set[str] = set()
        self.clock = clock
        self.t_start = clock()
        self.ttl_s, self.cooldown_s, self.max_age_s = ttl_s, cooldown_s, max_age_s
        self.sweep_every, self.max_candidates = sweep_every, max_candidates
        self.utts: list[_Utt] = []
        self._seen: set[str] = set()
        self.last_turn_id = ""
        self.finals_since_eval = 0               # utterances (speaker changes) since the last evaluation: the sweep counter
        self.audio_now: float | None = None
        self.last_fire_audio: float | None = None
        self.shown: dict[str, float] = {}        # id -> tracker clock when it was sent
        self.pending: list[str] | None = None    # candidates of evaluations skipped while a K call was in flight
        self._nominated: dict[str, int] = {}     # id -> evaluation count when last nominated (the sweep's rotation)
        self._evals = 0

    # ---- clocks
    def _audio(self) -> float:
        return self.audio_now if self.audio_now is not None else self.clock() - self.t_start

    def _note_audio(self, t: object) -> float | None:
        if isinstance(t, (int, float)) and not isinstance(t, bool):
            self.audio_now = float(t) if self.audio_now is None else max(self.audio_now, float(t))
            return float(t)
        return None

    def cooling(self) -> bool:
        """A nudge fired less than `cooldown_s` of audio ago: nothing can fire, so nothing is evaluated."""
        return self.last_fire_audio is not None and self._audio() - self.last_fire_audio < self.cooldown_s

    # ---- gates
    def _gates(self, n: Nudge, speaker: str | None = None) -> bool:
        if n.id not in self.armed:
            return False
        if self._audio() < n.after_s:
            return False
        if speaker is not None and n.who != "any" and WHO_SPEAKER[n.who] != speaker:
            return False
        return True

    def _money(self, text: str) -> tuple[list[str], list[str]]:
        retired, clear = [], []
        if not says_money(text):
            return retired, clear
        now = self.clock()
        for n in self.nudges.values():
            if n.until != "number" or n.id in self.retired:
                continue
            self.retired.add(n.id)
            if n.id in self.armed:
                self.armed.discard(n.id)
                retired.append(n.id)
            elif n.id in self.shown and now - self.shown[n.id] < self.ttl_s:
                retired.append(n.id)
                clear.append(n.id)
                self.shown.pop(n.id, None)
        return retired, clear

    # ---- the conversation as merged utterances
    def _add(self, speaker: str, text: str, t: float | None) -> tuple[str, str, bool]:
        """Adds a row; returns (the text it added, that text plus up to 3 words before it for multi-word keys, whether a new
        utterance started). A row that only repeats what the utterance already holds adds nothing."""
        ws = clean_words(text)
        ns = [_norm_word(w) for w in ws]
        if not ws:
            return "", "", False
        u = self.utts[-1] if self.utts else None
        if u is not None and u.speaker == speaker:
            if t is not None:
                u.t_end = t if u.t_end is None else max(u.t_end, t)
            if contains_words(u.norms, ns):
                return "", "", False
            k = _overlap(u.norms, ns)
            u.words += ws[k:]
            u.norms += ns[k:]
            del u.words[:-UTT_MAX_WORDS], u.norms[:-UTT_MAX_WORDS]
            return " ".join(ws[k:]), " ".join(ws[max(0, k - 3):]), False
        self.utts.append(_Utt(speaker, list(ws), list(ns), t))
        del self.utts[:-30]
        return " ".join(ws), " ".join(ws), True

    def window(self) -> list[tuple[str, str]]:
        """The last WINDOW_TURNS utterances, or those that ended in the last WINDOW_S seconds of audio when that is more,
        capped at WINDOW_WORDS words (the oldest words go first)."""
        if not self.utts:
            return []
        k = max(0, len(self.utts) - WINDOW_TURNS)
        t_new = self.utts[-1].t_end
        if t_new is not None:
            while k > 0 and self.utts[k - 1].t_end is not None and t_new - self.utts[k - 1].t_end <= WINDOW_S:
                k -= 1
        out: list[tuple[str, str]] = []
        budget = WINDOW_WORDS
        for u in reversed(self.utts[k:]):
            if budget <= 0:
                break
            w = u.words[-budget:]
            budget -= len(w)
            out.append((u.speaker, " ".join(w)))
        out.reverse()
        return [(sp, t) for sp, t in out if t]

    # ---- input
    def observe(self, speaker: str, text: str, t_audio_end: object = None) -> list[str]:
        """A turn from before this process (history replay): it joins the window and the money rule, nothing is evaluated."""
        if speaker not in SPEAKERS:
            return []
        self._add(speaker, text, self._note_audio(t_audio_end))
        return self._money(text)[0]

    def on_turn(self, turn_id: str, speaker: str, text: str, t_audio_end: object = None) -> TurnResult:
        res = TurnResult()
        if speaker not in SPEAKERS or (turn_id and turn_id in self._seen):
            return res        # a repeated final of the same turn counts once
        if turn_id:
            self._seen.add(turn_id)
            self.last_turn_id = turn_id
        t = self._note_audio(t_audio_end)
        res.retired, res.clear = self._money(text)
        added, joined, _ = self._add(speaker, text, t)
        u = self.utts[-1] if self.utts else None
        if u is not None and not u.counted and len(u.words) >= SWEEP_MIN_WORDS:
            u.counted = True
            self.finals_since_eval += 1
        res.new_words = len(added.split())
        if not added or self.cooling():
            return res
        hits = []
        for n in self.nudges.values():
            if self._gates(n, speaker):
                h = sum(1 for k in n.keys if key_hits((k,), joined if " " in k else added))
                if h:
                    hits.append((-h, n.id))
        cands = [nid for _, nid in sorted(hits)][: self.max_candidates]
        res.key_hits = list(cands)
        reason = "keys" if cands else ""
        if 0 < self.sweep_every <= self.finals_since_eval and len(cands) < self.max_candidates:
            rest = sorted((nid for nid in self.armed if nid not in cands and self._gates(self.nudges[nid])),
                          key=lambda nid: (self._nominated.get(nid, -1), nid))
            if rest:
                cands += rest[: self.max_candidates - len(cands)]
                reason = "keys+sweep" if reason else "sweep"
        if cands:
            res.evaluation = Evaluation(turn_id, cands, self.window(), reason)
        return res

    def defer(self, ev: Evaluation) -> None:
        """`ev` could not be launched (a K call is in flight): its candidates wait for one catch-up when that call returns."""
        old = [c for c in (self.pending or []) if c not in ev.candidates]
        self.pending = (list(ev.candidates) + old)[: self.max_candidates]

    def take_pending(self) -> Evaluation | None:
        """The catch-up evaluation over the window as it is now, or None (nothing pending, cooling down, or none still armed)."""
        cands, self.pending = self.pending, None
        if not cands or self.cooling():
            return None
        cands = [c for c in cands if self._gates(self.nudges[c])]
        return Evaluation(self.last_turn_id, cands, self.window(), "catch_up") if cands else None

    def launched(self, ev: Evaluation) -> None:
        """The K call for `ev` went out: the sweep counter starts again and the nominated nudges go to the back of the rotation."""
        self._evals += 1
        ev.t0 = self.clock()
        self.finals_since_eval = 0
        for nid in ev.candidates:
            self._nominated[nid] = self._evals

    def locate(self, window: list[tuple[str, str]], quote: str) -> tuple[str | None, str]:
        """(speaker of the utterance holding the quote, "") or (None, reason). Every checked part of the quote (`quote_parts`)
        must occur in the window in order; all of them in utterances of one speaker."""
        parts = quote_parts(quote)
        if not parts:
            return None, "quote_not_in_window"
        hays = [norm_tokens(t) for _, t in window]
        ui, ti = 0, 0
        speakers: set[str] = set()
        for part in parts:
            while ui < len(hays):
                end = find_quote(hays[ui], part, ti)
                if end >= 0:
                    speakers.add(window[ui][0])
                    ti = end
                    break
                ui, ti = ui + 1, 0
            else:
                return None, "quote_not_in_window"
        if len(speakers) != 1:
            return None, "who_mismatch"
        return speakers.pop(), ""

    def judge(self, ev: Evaluation, output: str) -> tuple[Fire | None, str, dict]:
        """(fire | None, reason, details) for the K call's output. A fire is already recorded (the nudge is spent).
        Reasons without a pick: none, garbage, not_quotation, unclosed, negated. Rejected picks: not_candidate, retired,
        not_armed, no_who (the who field is missing), quote_too_long, quote_not_in_window, who_mismatch (the stated speaker is
        not the one whose words hold the quote), who (the nudge's `Who` excludes that speaker), gates, stale, cooldown."""
        v = parse_output(output)
        info: dict = {"id": v.id, "quote": v.quote, "who": v.who}
        if v.id is None:
            return None, v.why, info
        nid, quote = v.id, v.quote or ""
        if nid not in ev.candidates:
            return None, "not_candidate", info
        n = self.nudges.get(nid)
        if n is None or nid not in self.armed:
            return None, "retired" if nid in self.retired else "not_armed", info
        if v.who is None:
            return None, "no_who", info
        if len(words(_ELLIPSIS.sub(" ", quote))) > QUOTE_MAX_WORDS:
            return None, "quote_too_long", info
        where, why = self.locate(ev.window, quote)
        if where is None:
            return None, why, info
        if WHO_SPEAKER[v.who] != where:
            return None, "who_mismatch", info
        if n.who != "any" and WHO_SPEAKER[n.who] != where:
            return None, "who", info
        if not self._gates(n):
            return None, "gates", info
        age = self.clock() - ev.t0
        info["age_s"] = round(age, 3)
        if age > self.max_age_s:
            return None, "stale", info
        if self.cooling():
            return None, "cooldown", info
        self.armed.discard(nid)
        self.fired.append(nid)
        self.shown[nid] = self.clock()
        self.last_fire_audio = self._audio()
        return Fire(n, ev.turn_id, quote, where), "fired", info


# --------------------------------------------------------------------------------------------- fakes
_CAND = re.compile(r"^\[(n\d{3})\] When: ", re.MULTILINE)
WINDOW_HEADER = "LATEST TURNS (only these count):"
WINDOW_END = "END OF LATEST TURNS"


def fake_judge_line(tail: str) -> str:
    """A K answer for fake transports (tests, eval arm A): the first candidate, quoting the last words of the newest window
    turn and naming its speaker. Not a model of the judge's judgement: it only exercises the plumbing."""
    cands = _CAND.findall(tail or "")
    lines = (tail or "").splitlines()
    try:
        win = lines[lines.index(WINDOW_HEADER) + 1: lines.index(WINDOW_END)]
    except ValueError:
        return "NUDGE: none"
    win = [ln for ln in win if ln.strip()]
    if not cands or not win:
        return "NUDGE: none"
    m = re.match(r"^\[([^\]]*)\]\s*(.*)$", win[-1])
    if not m:
        return "NUDGE: none"
    who = "them" if m.group(1) == "Other side" else "me"
    w = m.group(2).split()[-6:]
    return f'NUDGE: {cands[0]} | "{" ".join(w)}" | {who}' if w else "NUDGE: none"
