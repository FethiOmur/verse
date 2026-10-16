"""the owner's own voice in the room route, told by text (docs/specs/2026-10-16-verse-anytime-calls-design.md 2.1).

The room route has one microphone and no speaker separation before phase D, so the owner's own sentences arrive labelled
`room`, next to the interviewer's. The commonest own speech in a live call is the card itself: he reads the SAY line and
the points aloud. While a card is on screen, a room partial or turn whose words line up with that card, in order, is his
voice: it is relabelled `me` before anything else looks at it. It then never fires a card, it moves follow mode's
coverage (struck-through points) and it sits in the transcript as `[Alex]`. Text that does not line up stays `room`.

Three rules decide it, all on one in-order path through the lines of the card (at most `max_gap` card words skipped between
two matched ones):

* strict (the first rule, unchanged): at least `min_matched` content words matched and `enter` of the text's content words
  on the path (`stay` for a turn that already is `me`). A whole sentence of the card, read with ASR slips, passes.
* start: a text that begins the card, at its first words or at the first point's: at least `start_min` words matched from
  the first `start_slack` words of the line, and `start_share` of the text's words on the path. This is how reading is entered
  when the recognizer delivers the card in fragments of two to six words (live Italian call, 16 Oct): no fragment holds five
  content words, so the strict rule never fired.
* continue: inside a reading session (the last `me` label was within `session_s`), a fragment that continues from the reading
  cursor, the card position after the last matched stretch: its first matched word within `cont_back` before and
  `cont_ahead` after the cursor, at least `cont_min` content words matched and `cont_share` of its words on the path. The
  cursor belongs to the card on screen and is reset with it.

A text that mixes his reading and the other person's next question ("... tends to stay high. Great, how would you describe
yourself as a team member") is split when its path covers a prefix and at least `split_trail` words after it do not: the
prefix is `me`, the remainder is a `room` text and is judged on its own for kind and probe (`Verdict.label == "split"`).

Tokens are compared stem by stem. English uses the follow detector's stopword list and stemmer (`follow.py`). `follow.py`'s
tokenizer only knows a-z, which cuts Italian accents and Turkish letters out of words, so here the words are split on
Unicode letters, accent-folded, and Italian and Turkish have their own short stopword lists and stemmers (Italian: trailing
vowel and the first six letters; Turkish: the first five letters, spec 2.5). The follow detector's own lexical rule
(a word matches when a second stem of the same line is within +-3 words) is order-blind; it would let an interviewer who
restates a card's words ("why you chose accounting as a major") look like Alex, and here that is the failure to avoid.

This is an interim rule until phase D separates the voices by embedding. It cannot know that Alex paraphrases the card
(that text stays `room`), and it cannot tell another person reading the same words.
"""

from __future__ import annotations

import re
import time
import unicodedata
from dataclasses import dataclass
from typing import Callable

from .follow import _TENS, _UNITS, clean_line
from .follow import is_content as en_is_content
from .follow import stem as en_stem


@dataclass
class OwnParams:
    # Tuned on the Dana fixtures in tests/test_runtime_room.py (the card of "why this school, why accounting"): reading the card
    # aloud, with ASR slips, scores 0.90-1.00 from 5 matched words on; an interviewer who follows up on the card's own subject
    # scores 0.56-0.80 but with at most 4 matched words when the question is short. 0.75 / 5 keeps both sides apart; a
    # paraphrase of the card (0.69 in the fixtures) stays `room` on purpose.
    enter: float = 0.75       # share of the text's content words on the card, in order, for a `room` text to become `me`
    stay: float = 0.60        # an open turn that already is `me` stays `me` down to this share (the end of a turn may carry other voices)
    min_matched: int = 5      # ... and at least this many content words must line up (a short stretch proves nothing)
    max_gap: int = 3          # card content words that may be skipped between two matched ones (a skipped or misheard word)
    # reading across fragments (tests/test_runtime_room_reading.py; the live Italian call delivered the card in finals of 2-6 words)
    session_s: float = 4.0    # a reading session lasts this long after the last text taken for his
    start_min: int = 3        # words matched from the start of the SAY line or of the first point (entering a reading session)
    start_slack: int = 2      # ... the first matched card word within this many words of that line start
    start_share: float = 0.75  # ... and this share of the text's words on the path
    all_gap: int = 4          # card words that may be skipped between two matched ones when every word counts (function words too)
    cont_min: int = 2         # inside a session: content words matched from the cursor on
    cont_share: float = 0.60  # ... and this share of the text's words on the path
    cont_back: int = 2        # ... the first matched card word at most this far before the cursor (a word said twice)
    cont_ahead: int = 4       # ... and at most this far after it (words dropped or misheard between two fragments)
    split_trail: int = 4      # words after the path that do not match, to split a text there
    split_trail_content: int = 2   # ... of which at least this many are content words (four filler words are not another speaker)


# ---------------------------------------------------------------------------------------------------------------- words
_WORD = re.compile(r"\w+(?:'\w+)?", re.UNICODE)
_WORD_ELIDED = re.compile(r"\w+", re.UNICODE)       # Italian and Turkish: an apostrophe ends a word ("l'esperienza", "Ankara'da")
_THOUSANDS = re.compile(r"(?<=\d),(?=\d{3}\b)")

_IT_STOP = frozenset("""
a ad al allo alla alle ai agli all anche che chi ci col con cui da dal dallo dalla dalle dai dagli dei del dello della delle degli
di e ed è ha ho hai hanno abbiamo avete era ero erano fu gli i il in io la le lei li lo loro lui ma me mi mia mie miei mio ne nei
nel nella nelle negli no noi non o per più poi quel quella quelle quelli quello questa queste questi questo se sei si sia sono su
sul sulla sulle sui sugli suo sua sue suoi ti tra fra tu tua tue tuo tuoi un una uno vi voi come cosa quando dove perché perche
molto poco già ancora solo sempre mai essere avere stato stata fatto fare però quindi allora ecco
""".split())
_TR_STOP = frozenset("""
bir ve ile de da ki bu şu su o ben sen biz siz onlar için icin gibi ama fakat ya veya çok cok daha en mı mi mu mü var yok her bazı
bazi olarak kadar sonra önce once ne hem ise ise değil degil tabii evet hayır hayir peki yani işte iste
""".split())
_FILLERS = frozenset("ehm eh ehh uh uhm um umm er erm hmm hm mm mmm ah ee eee ıı şey sey".split())


def _fold(word: str, lang: str) -> str:
    if lang == "tr":
        word = word.replace("I", "ı").replace("İ", "i")
    word = unicodedata.normalize("NFKD", word.lower().replace("’", "'"))
    word = "".join(c for c in word if not unicodedata.combining(c))
    return word.replace("ı", "i").replace("ß", "ss")


_STOP_FOLDED = {"it": frozenset(_fold(s, "it") for s in _IT_STOP), "tr": frozenset(_fold(s, "tr") for s in _TR_STOP), "en": frozenset()}


def _is_content(tok: str, lang: str) -> bool:
    if any(c.isdigit() for c in tok):
        return True
    if lang == "en":
        return en_is_content(tok)
    return len(tok) > 1 and tok not in _STOP_FOLDED.get(lang, frozenset())


def _stem(tok: str, lang: str) -> str:
    if any(c.isdigit() for c in tok):
        return tok[:-2] if tok.endswith(".0") else tok
    if lang == "tr":
        return tok[:5]
    if lang == "it":
        if len(tok) > 4 and tok[-1] in "aeiou":
            tok = tok[:-1]
        return tok[:6]
    return en_stem(tok)


@dataclass(frozen=True)
class Tok:
    stem: str
    content: bool
    word: int       # index of the whitespace-separated word of the text it came from


def tokenize(text: str, lang: str = "en") -> list[Tok]:
    """Tokens of `text` in order. One whitespace-separated word gives zero or more tokens ("month-end" gives two, a lone "ehm"
    none); `Tok.word` says which, so a text can be cut between words."""
    out: list[Tok] = []
    for w, word in enumerate(_THOUSANDS.sub("", text).split()):
        for raw in (_WORD if lang == "en" else _WORD_ELIDED).findall(_fold(word, lang)):
            if raw in _FILLERS:
                continue
            if lang == "en" and raw in _UNITS:
                raw = str(_UNITS[raw])
            elif lang == "en" and raw in _TENS:
                raw = str(_TENS[raw])
            out.append(Tok(_stem(raw, lang), _is_content(raw, lang), w))
    return out


def content_stems(text: str, lang: str = "en") -> list[str]:
    return [t.stem for t in tokenize(text, lang) if t.content]


# ------------------------------------------------------------------------------------------------------------ alignment
def align_path(text: list[str], card: list[str], max_gap: int, first: Callable[[int], bool] | None = None) -> list[tuple[int, int]]:
    """The longest in-order path of matched pairs (i, j) (i and j both increasing, at most `max_gap` card words skipped between
    two consecutive pairs; words of `text` that match nothing are free to be skipped). `first(j)` limits where a path may begin on
    the card."""
    n, m = len(text), len(card)
    if n == 0 or m == 0:
        return []
    best: dict[tuple[int, int], tuple[int, tuple[int, int] | None]] = {}
    top: tuple[int, int] | None = None
    for i in range(n):
        for j in range(m):
            if card[j] != text[i]:
                continue
            cnt, prev = 0, None
            for i2 in range(i):
                for j2 in range(max(0, j - 1 - max_gap), j):
                    c = best.get((i2, j2))
                    if c is not None and c[0] > cnt:
                        cnt, prev = c[0], (i2, j2)
            if cnt == 0 and first is not None and not first(j):
                continue
            best[(i, j)] = (cnt + 1, prev)
            if top is None or cnt + 1 > best[top][0]:
                top = (i, j)
    path: list[tuple[int, int]] = []
    cur = top
    while cur is not None:
        path.append(cur)
        cur = best[cur][1]
    return path[::-1]


def aligned(text: list[str], card: list[str], max_gap: int) -> int:
    """Most content words of `text` that sit on one in-order path through `card` (see `align_path`)."""
    return len(align_path(text, card, max_gap))


@dataclass(frozen=True)
class OwnScore:
    share: float              # matched / content words of the text
    matched: int
    content: int
    card: str | None = None   # key of the card the best path is on


@dataclass(frozen=True)
class Cand:
    """The best path of one rule over the card(s) on screen."""
    rule: str                 # "strict" | "start" | "continue"
    ok: bool
    key: str | None
    matched: int
    content_matched: int
    share: float
    end: int                  # index (in the text's tokens) of the last matched token; -1 when nothing matched
    cursor: int               # card position after the last matched card token


@dataclass(frozen=True)
class Verdict:
    label: str                # "me" | "room" | "split"
    rule: str                 # the rule that said me (or split); for room: why not ("no_card" | "empty" | "weak")
    share: float = 0.0
    matched: int = 0
    content: int = 0
    card: str | None = None
    reading: bool = False     # a reading session was active when the text was judged
    cursor: int | None = None
    me_text: str = ""         # label "split": the prefix that is his reading ...
    room_text: str = ""       # ... and the remainder that is not


class OwnSpeech:
    """The lines of the card on screen, the reading cursor on it, and the match of a room text against them."""

    def __init__(self, params: OwnParams | None = None, clock: Callable[[], float] = time.monotonic) -> None:
        self.p = params or OwnParams()
        self.clock = clock
        self.turn_id: str | None = None
        self.cards: dict[str, list[tuple[str, str]]] = {}      # card key -> [(kind, text)] in reading order
        self._toks: dict[tuple[str, str], tuple[list[Tok], list[int]]] = {}   # (card key, lang) -> tokens, line start indices
        self.cursor: dict[str, int] = {}                        # card key -> position after the last matched stretch
        self._base: dict[str, dict[str, int]] = {}              # turn id -> the cursor when the turn was first judged (a turn's growing
                                                                # partials all continue from there, not from where the partials moved it)
        self.last_me: float | None = None                       # clock time of the last text taken for his

    def clear(self) -> None:
        self.turn_id = None
        self.cards.clear()
        self._toks.clear()
        self.cursor.clear()
        self._base.clear()
        self.last_me = None

    def add(self, turn_id: str, card_key: str, kind: str, text: str, *, new_say: bool = False) -> None:
        """A complete card line that the overlay shows. A new turn's first line starts a new card (and resets the reading cursor);
        `new_say` (an S/F SAY line) replaces the lines of that card key (the fast tier's answer replaces what was there)."""
        text = clean_line(text)
        if not text:
            return
        if turn_id != self.turn_id:
            self.clear()
            self.turn_id = turn_id
        lines = self.cards.setdefault(card_key, [])
        if new_say:
            lines.clear()
            self.cursor.pop(card_key, None)
        lines.append((kind, text))
        for k in [k for k in self._toks if k[0] == card_key]:
            del self._toks[k]

    def has_card(self) -> bool:
        return any(self.cards.values())

    def reading_active(self, now: float | None = None) -> bool:
        """Was a text taken for his reading within the last `session_s`?"""
        if self.last_me is None:
            return False
        return (self.clock() if now is None else now) - self.last_me <= self.p.session_s

    def quiet_for(self, now: float | None = None) -> float:
        """Seconds since the last text taken for his (infinity when none)."""
        if self.last_me is None:
            return float("inf")
        return (self.clock() if now is None else now) - self.last_me

    def _card(self, key: str, lang: str) -> tuple[list[Tok], list[int]]:
        got = self._toks.get((key, lang))
        if got is None:
            toks: list[Tok] = []
            starts: list[int] = []
            seen_point = False
            for kind, text in self.cards.get(key, []):
                part = tokenize(text, lang)
                if part and (not toks or (kind == "point" and not seen_point)):
                    starts.append(len(toks))
                    seen_point = seen_point or kind == "point"
                toks += part
            got = self._toks[(key, lang)] = (toks, starts)
        return got

    # ---- the strict score (the first rule; also the number the thresholds were tuned on)
    def score(self, text: str, lang: str = "en") -> OwnScore:
        mine = content_stems(text, lang)
        if not mine or not self.has_card():
            return OwnScore(0.0, 0, len(mine))
        best_n, best_key = 0, None
        for key in self.cards:
            card = [t.stem for t in self._card(key, lang)[0] if t.content]
            n = aligned(mine, card, self.p.max_gap)
            if n > best_n:
                best_n, best_key = n, key
        return OwnScore(best_n / len(mine), best_n, len(mine), best_key)

    def is_own(self, text: str, already: bool = False, lang: str = "en") -> tuple[bool, OwnScore]:
        """Is this room text the owner's by the strict rule alone? `already`: the turn was taken for his before (hysteresis: it
        stays his above `stay`)."""
        sc = self.score(text, lang)
        if sc.matched < self.p.min_matched:
            return False, sc
        return sc.share >= (self.p.stay if already else self.p.enter), sc

    # ---- the three rules over a token list
    def _cands(self, toks: list[Tok], lang: str, already: bool, reading: bool, base: dict[str, int]) -> list[Cand]:
        p = self.p
        mine_idx = [i for i, t in enumerate(toks) if t.content]
        mine = [toks[i].stem for i in mine_idx]
        allw = [t.stem for t in toks]
        best: dict[str, Cand] = {}

        def offer(c: Cand) -> None:
            cur = best.get(c.rule)
            if cur is None or (c.ok, c.matched) > (cur.ok, cur.matched):
                best[c.rule] = c

        for key in self.cards:
            ctoks, starts = self._card(key, lang)
            if not ctoks:
                continue
            # strict: content words only
            cidx = [j for j, t in enumerate(ctoks) if t.content]
            path = align_path(mine, [ctoks[j].stem for j in cidx], p.max_gap) if mine else []
            n = len(path)
            share = n / len(mine) if mine else 0.0
            ok = n >= p.min_matched and share >= (p.stay if already else p.enter)
            offer(Cand("strict", ok, key, n, n, share, mine_idx[path[-1][0]] if path else -1, cidx[path[-1][1]] + 1 if path else 0))

            # start and continue: every word counts (a fragment of 3 words has one or two content words at most)
            def all_cand(rule: str, first: Callable[[int], bool], need_matched: int, need_content: int, need_share: float) -> Cand:
                pth = align_path(allw, [t.stem for t in ctoks], p.all_gap, first)
                m = len(pth)
                cm = sum(1 for _, j in pth if ctoks[j].content)
                sh = m / len(toks) if toks else 0.0
                good = m >= need_matched and cm >= need_content and sh >= need_share
                return Cand(rule, good, key, m, cm, sh, pth[-1][0] if pth else -1, pth[-1][1] + 1 if pth else 0)

            heads = {0, starts[1] if len(starts) > 1 else 0} if starts else {0}
            offer(all_cand("start", lambda j: any(h <= j <= h + p.start_slack for h in heads), p.start_min, 1, p.start_share))
            if reading and key in base:
                cur = base[key]
                offer(all_cand("continue", lambda j: cur - p.cont_back <= j <= cur + p.cont_ahead, 1, p.cont_min, p.cont_share))
        return list(best.values())

    def _note_me(self, c: Cand, now: float) -> None:
        self.last_me = now
        if c.key is not None:
            self.cursor[c.key] = max(self.cursor.get(c.key, 0), c.cursor)

    def judge(self, text: str, lang: str = "en", already: bool = False, now: float | None = None,
              turn_id: str | None = None) -> Verdict:
        """Is this room text Alex reading his card? `me`, `room`, or `split` (a prefix of his reading, then another voice).
        `turn_id`: the partials and the final of one turn are judged from the cursor the turn started at."""
        now = self.clock() if now is None else now
        if not self.has_card():
            return Verdict("room", "no_card")
        toks = tokenize(text, lang)
        if not toks:
            return Verdict("room", "empty")
        words = text.split()
        reading = self.reading_active(now)
        base = dict(self.cursor) if turn_id is None else self._base.setdefault(turn_id, dict(self.cursor))
        whole = self._cands(toks, lang, already, reading, base)
        strict = next((c for c in whole if c.rule == "strict"), None)
        info = dict(share=strict.share if strict else 0.0, matched=strict.matched if strict else 0,
                    content=sum(1 for t in toks if t.content), card=strict.key if strict else None, reading=reading)
        # a prefix on the card, then words that are not: the next speaker's question glued to the end of his reading
        for k in sorted({c.end for c in whole if c.end >= 0}, reverse=True):
            w = toks[k].word
            trail = [t for t in toks if t.word > w]
            if len(trail) < self.p.split_trail or sum(1 for t in trail if t.content) < self.p.split_trail_content:
                continue
            ok = [c for c in self._cands([t for t in toks if t.word <= w], lang, already, reading, base) if c.ok]
            if ok:
                c = max(ok, key=lambda x: x.matched)
                self._note_me(c, now)
                return Verdict("split", c.rule, c.share, c.matched, sum(1 for t in toks if t.word <= w if t.content), c.key, reading,
                               self.cursor.get(c.key or ""), " ".join(words[:w + 1]), " ".join(words[w + 1:]))
        ok = [c for c in whole if c.ok]
        if ok:
            c = max(ok, key=lambda x: x.matched)
            self._note_me(c, now)
            return Verdict("me", c.rule, c.share, c.matched, info["content"], c.key, reading, self.cursor.get(c.key or ""))
        top = max(whole, key=lambda c: c.matched, default=None)
        if top is not None and top.rule != "strict":
            info.update(share=top.share, matched=top.matched)     # the nearest miss, for the log
        return Verdict("room", "weak", **info)
