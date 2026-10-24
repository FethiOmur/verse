"""The owner's own voice in the room route, told by text (docs/specs/2026-10-16-verse-anytime-calls-design.md 2.1).

The room route has one microphone and no speaker separation before phase D, so the owner's own sentences arrive labelled
`room`, next to the interviewer's. The commonest own speech in a live call is the card itself: he reads the SAY line and
the points aloud. While a card is on screen, a room partial or turn whose words line up with that card, in order, is his
voice: it is relabelled `me` before anything else looks at it. It then never fires a card, it moves follow mode's
coverage (struck-through points) and it sits in the transcript as `[<name>]`. Text that does not line up stays `room`.

Three rules decide it, all on one in-order path through the lines of the card (at most `max_gap` card words skipped between
two matched ones):

* strict (the first rule, unchanged): at least `min_matched` content words matched and `enter` of the text's content words
  on the path (`stay` for a turn that already is `me`). A whole sentence of the card, read with ASR slips, passes.
* start: a text that begins a line of the card (the SAY line or any point, D's too): at least `start_min` words matched from
  the first `start_slack` words of the line, and `start_share` of the text's words on the path. This is how reading is entered
  when the recognizer delivers the card in fragments of two to six words (live Italian call, 16 Oct): no fragment holds five
  content words, so the strict rule never fired.
* continue: inside a reading session (the last `me` label was within `session_s`), a fragment that continues from the reading
  cursor, the card position after the last matched stretch: its first matched word within `cont_back` before and
  `cont_ahead` after the cursor, at least `cont_min` content words matched and `cont_share` of its words on the path. The
  cursor belongs to the card on screen and is reset with it.

* re-anchor: the three rules above follow one path. When he jumps on the card (skips a sentence, re-reads a line, starts from a
  point) that path is lost, so a text that holds `anchor_min` or more content words on a near-consecutive path (at most `anchor_gap`
  card content words skipped between two matched ones) with `anchor_share` of the text's content words on it is also his reading,
  wherever on the card it sits, and the reading cursor moves there, forward or back. Function words never count toward the threshold
  (only content words are aligned). It is stronger than the continue rule (2 words, near the cursor) on purpose: a question from
  the other side that shares two or three card words must neither be taken for his reading nor move the cursor, and a single
  matching word never does. Only the cursor moves: nothing is un-read or marked read here (the lines he skipped stay as they were).
  The Swift twin is `RoomReadingGate` (`.anchor`) in `app/Sources/VerseUI/CardReading.swift`, with the same constants.

A text that mixes his reading and the other person's next question ("... tends to stay high. Great, how would you describe
yourself as a team member") is split when its path covers a prefix and at least `split_trail` words after it do not: the
prefix is `me`, the remainder is a `room` text and is judged on its own for kind and probe (`Verdict.label == "split"`).

Tokens are compared stem by stem. English uses the follow detector's stopword list and stemmer (`follow.py`). `follow.py`'s
tokenizer only knows a-z, which cuts Italian accents and Turkish letters out of words, so here the words are split on
Unicode letters, accent-folded, and Italian and Turkish have their own short stopword lists and stemmers (Italian: trailing
vowel and the first six letters; Turkish: the first five letters, spec 2.5). The follow detector's own lexical rule
(a word matches when a second stem of the same line is within +-3 words) is order-blind; it would let an interviewer who
restates a card's words ("why you chose accounting as a major") look like the owner, and here that is the failure to avoid.

This is an interim rule until phase D separates the voices by embedding. It cannot know that the owner paraphrases the card
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
    # re-anchor anywhere on the card (twin: RoomReadingGate.anchorMin / anchorGap / anchorShare in app/Sources/VerseUI/CardReading.swift).
    # Fixtures: the nearest interviewer text quotes 4 consecutive card words with one more word of its own (4 of 5, 0.80), so the share
    # sits above that; a short line read whole (4 of 4) passes.
    anchor_min: int = 4       # content words on one near-consecutive path, wherever on the card (function words do not count)
    anchor_gap: int = 1       # card content words that may be skipped between two matched ones (stricter than max_gap: near-consecutive)
    anchor_share: float = 0.85  # share of the text's content words on that path
    split_trail: int = 4      # words after the path that do not match, to split a text there
    split_trail_content: int = 2   # ... of which at least this many are content words (four filler words are not another speaker)
    # one turn, many cumulative partials (live English call, 17 Oct): a turn once taken for his keeps its label while its share stays above `exit_share`
    exit_share: float = 0.60  # a turn already `me` stays `me` while this share of its words lies on the card path that began where it began
    stay_min: int = 3         # ... with at least this many words matched
    speech_floor: float = 0.35  # a room text that scores at least this against the card is reading-like speech (it keeps a held card waiting)
    own_drop: float = 0.50    # ... and at this score it is his: a held card for it is dropped, a statement probe is never asked about it


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


def anchor_path(text: list[str], card: list[str], max_gap: int, near: int = 0) -> list[tuple[int, int]]:
    """Like `align_path`, but for re-anchoring: the path may begin anywhere on the card, and among equally long paths the one that
    begins nearest to card position `near` wins (a line said twice anchors at the occurrence closest to the reading cursor).
    Rank of a path = (matched pairs, -|start - near|); the first one found wins a tie, in the order i, j ascending.
    Twin: `RoomReading.anchorPath` in app/Sources/VerseUI/CardReading.swift."""
    n, m = len(text), len(card)
    if n == 0 or m == 0:
        return []
    best: dict[tuple[int, int], tuple[int, tuple[int, int] | None, int]] = {}      # (i, j) -> (count, previous pair, start j)
    top: tuple[int, int] | None = None

    def rank(c: tuple[int, tuple[int, int] | None, int]) -> tuple[int, int]:
        return c[0], -abs(c[2] - near)

    for i in range(n):
        for j in range(m):
            if card[j] != text[i]:
                continue
            cur = (1, None, j)
            for i2 in range(i):
                for j2 in range(max(0, j - 1 - max_gap), j):
                    c = best.get((i2, j2))
                    if c is not None and rank((c[0] + 1, c[1], c[2])) > rank(cur):
                        cur = (c[0] + 1, (i2, j2), c[2])
            best[(i, j)] = cur
            if top is None or rank(cur) > rank(best[top]):
                top = (i, j)
    path: list[tuple[int, int]] = []
    node = top
    while node is not None:
        path.append(node)
        node = best[node][1]
    return path[::-1]


@dataclass(frozen=True)
class OwnScore:
    share: float              # matched / content words of the text
    matched: int
    content: int
    card: str | None = None   # key of the card the best path is on


@dataclass(frozen=True)
class Cand:
    """The best path of one rule over the card(s) on screen."""
    rule: str                 # "strict" | "start" | "continue" | "stay" | "anchor"
    ok: bool
    key: str | None
    matched: int
    content_matched: int
    share: float
    end: int                  # index (in the text's tokens) of the last matched token; -1 when nothing matched
    cursor: int               # card position after the last matched card token
    first: int = -1           # card position (token index) of the first matched card token; -1 when nothing matched


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


@dataclass
class TurnTrack:
    """What one turn (its cumulative partials and its final) needs between two judgements."""
    base: dict[str, int]                  # the reading cursor when the turn was first judged: every partial and the final continue from here
    me: bool = False                      # an earlier text of this turn was taken for his reading
    entry: tuple[str, int] | None = None  # (card key, card position) where his reading of this turn began


class OwnSpeech:
    """The lines of the card on screen, the reading cursor on it, and the match of a room text against them."""

    def __init__(self, params: OwnParams | None = None, clock: Callable[[], float] = time.monotonic) -> None:
        self.p = params or OwnParams()
        self.clock = clock
        self.turn_id: str | None = None
        self.cards: dict[str, list[tuple[str, str]]] = {}      # card key -> [(kind, text)] in reading order
        self._toks: dict[tuple[str, str], tuple[list[Tok], list[int]]] = {}   # (card key, lang) -> tokens, line start indices
        self.cursor: dict[str, int] = {}                        # card key -> position after the last matched stretch
        self._turns: dict[str, TurnTrack] = {}                  # turn id -> its anchor (a turn's growing partials all continue from the
                                                                # cursor the turn started at, not from where the partials moved it)
        self.last_me: float | None = None                       # clock time of the last text taken for his
        self.last_speech: float | None = None                   # clock time of the last room text that scored >= speech_floor on the card

    def clear(self) -> None:
        self.turn_id = None
        self.cards.clear()
        self._toks.clear()
        self.cursor.clear()
        self._turns.clear()
        self.last_me = None
        self.last_speech = None

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
        """Seconds since the last text taken for his, or since the last room text that scored `speech_floor` on the card, whichever
        is later (infinity when none). The second clock matters: a final that failed the rules (an ASR slip too many) is still
        reading-like speech, and a held card must not fire in its first second."""
        last = max((t for t in (self.last_me, self.last_speech) if t is not None), default=None)
        if last is None:
            return float("inf")
        return (self.clock() if now is None else now) - last

    def note_speech(self, text: str, lang: str = "en", now: float | None = None) -> float:
        """A room text was heard while a card is on screen: its score on the card; at `speech_floor` or more it counts as speech
        that keeps a held card waiting."""
        sc = self.own_score(text, lang)
        if sc >= self.p.speech_floor:
            self.last_speech = self.clock() if now is None else now
        return sc

    def visible_lines(self) -> list[tuple[str, str]]:
        """The lines of the card(s) on screen as (kind, text) in reading order."""
        return [kv for lines in self.cards.values() for kv in lines]

    def _card(self, key: str, lang: str) -> tuple[list[Tok], list[int]]:
        got = self._toks.get((key, lang))
        if got is None:
            toks: list[Tok] = []
            starts: list[int] = []
            for _kind, text in self.cards.get(key, []):
                part = tokenize(text, lang)
                if part:
                    starts.append(len(toks))      # every line of the card can be where a reading begins: the SAY line, each point (D's too)
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

    def own_score(self, text: str, lang: str = "en") -> float:
        """How much of this text lies on the visible card, in order (the strict share of its content words). A stretch of fewer
        than `min_matched` words proves little (an interviewer quoting four words of the card in his follow-up question scores 0.8),
        so its score never reaches `own_drop`."""
        sc = self.score(text, lang)
        if sc.matched >= self.p.min_matched:
            return sc.share
        return min(sc.share, self.p.own_drop - 0.01)

    # ---- the three rules over a token list
    def _cands(self, toks: list[Tok], lang: str, already: bool, reading: bool, base: dict[str, int],
               entry: tuple[str, int] | None = None) -> list[Cand]:
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
            offer(Cand("strict", ok, key, n, n, share, mine_idx[path[-1][0]] if path else -1, cidx[path[-1][1]] + 1 if path else 0,
                       cidx[path[0][1]] if path else -1))

            # start and continue: every word counts (a fragment of 3 words has one or two content words at most)
            def all_cand(rule: str, first: Callable[[int], bool], need_matched: int, need_content: int, need_share: float) -> Cand:
                pth = align_path(allw, [t.stem for t in ctoks], p.all_gap, first)
                m = len(pth)
                cm = sum(1 for _, j in pth if ctoks[j].content)
                sh = m / len(toks) if toks else 0.0
                good = m >= need_matched and cm >= need_content and sh >= need_share
                return Cand(rule, good, key, m, cm, sh, pth[-1][0] if pth else -1, pth[-1][1] + 1 if pth else 0, pth[0][1] if pth else -1)

            # anchor: content words only, near-consecutive, anywhere on the card (the reading may have jumped)
            near = sum(1 for j in cidx if j < base.get(key, 0))
            apath = anchor_path(mine, [ctoks[j].stem for j in cidx], p.anchor_gap, near) if mine else []
            an = len(apath)
            ash = an / len(mine) if mine else 0.0
            offer(Cand("anchor", an >= p.anchor_min and ash >= p.anchor_share, key, an, an, ash, mine_idx[apath[-1][0]] if apath else -1,
                       cidx[apath[-1][1]] + 1 if apath else 0, cidx[apath[0][1]] if apath else -1))

            heads = {0, *starts}
            offer(all_cand("start", lambda j: any(h <= j <= h + p.start_slack for h in heads), p.start_min, 1, p.start_share))
            if reading:
                cur = base.get(key, 0)      # a card nobody has read yet continues from its start
                offer(all_cand("continue", lambda j: cur - p.cont_back <= j <= cur + p.cont_ahead, 1, p.cont_min, p.cont_share))
            if already and entry is not None and entry[0] == key:
                # the turn is already his: its growing text stays his while `exit_share` of it lies on the path that began where
                # his reading of this turn began (no session needed, no flicker from one partial to the next)
                e = entry[1]
                offer(all_cand("stay", lambda j: e - p.cont_back <= j <= e + p.cont_ahead, p.stay_min, 1, p.exit_share))
        return list(best.values())

    def _anchor_move(self, c: Cand, cands: list[Cand], base: dict[str, int]) -> tuple[str, int, int] | None:
        """Where the reading cursor must jump to (card key, card position of the first matched token, cursor after the last), or None
        when the text continues the reading where it was. The anchor path decides; a broader path of the verdict that contains it (a
        long reading with a gap in the middle) gives the far end, so a jump never lands before where the text really ends."""
        a = next((x for x in cands if x.rule == "anchor" and x.ok and x.key is not None), None)
        if a is None:
            return None
        first, cursor = a.first, a.cursor
        if c.key == a.key and 0 <= c.first <= a.first and c.cursor >= a.cursor:
            first, cursor = c.first, c.cursor
        at = base.get(a.key or "", 0)
        if at - self.p.cont_back <= first <= at + self.p.cont_ahead:
            return None
        return a.key or "", first, cursor

    def _note_me(self, c: Cand, now: float, track: TurnTrack | None = None, move: tuple[str, int, int] | None = None) -> None:
        self.last_me = now
        if c.key is not None:
            self.cursor[c.key] = max(self.cursor.get(c.key, 0), c.cursor)
            if track is not None:
                track.me = True
                if track.entry is None and c.first >= 0:
                    track.entry = (c.key, c.first)
        if move is not None:
            key, first, cursor = move
            self.cursor[key] = cursor                  # a jump: forward or back, not the max of the two
            if track is not None and (track.entry is None or track.entry[0] != key):
                track.entry = (key, first)

    def judge(self, text: str, lang: str = "en", already: bool = False, now: float | None = None,
              turn_id: str | None = None, final: bool = False) -> Verdict:
        """Is this room text the owner reading his card? `me`, `room`, or `split` (a prefix of his reading, then another voice).
        `turn_id`: the partials and the final of one turn are judged from the cursor the turn started at."""
        now = self.clock() if now is None else now
        if not self.has_card():
            return Verdict("room", "no_card")
        toks = tokenize(text, lang)
        if not toks:
            return Verdict("room", "empty")
        words = text.split()
        reading = self.reading_active(now)
        track = None
        if turn_id is not None:
            track = self._turns.get(turn_id)
            if track is None:
                track = self._turns[turn_id] = TurnTrack(dict(self.cursor))
                for k in [k for k in self._turns if k != turn_id][:-31]:      # a call has a few hundred turns: keep the last 32
                    del self._turns[k]
        base = dict(self.cursor) if track is None else track.base
        already = already or (track is not None and track.me)
        entry = track.entry if track is not None else None
        whole = self._cands(toks, lang, already, reading, base, entry)
        strict = next((c for c in whole if c.rule == "strict"), None)
        info = dict(share=strict.share if strict else 0.0, matched=strict.matched if strict else 0,
                    content=sum(1 for t in toks if t.content), card=strict.key if strict else None, reading=reading)
        stay = next((c for c in whole if c.rule == "stay" and c.ok), None)
        if stay is not None and not final:
            # a partial of a turn that is already his: a dip in the middle of a turn is no split and no probe. Only the final
            # may still cut the turn where the next speaker's question starts.
            self._note_me(stay, now, track, self._anchor_move(stay, whole, base))
            return Verdict("me", "stay", stay.share, stay.matched, info["content"], stay.key, reading, self.cursor.get(stay.key or ""))
        # a prefix on the card, then words that are not: the next speaker's question glued to the end of his reading
        def trails(k: int) -> list[Tok]:
            """The tokens after the word that token `k` belongs to, when they are enough to be another speaker; else []."""
            rest = [t for t in toks if t.word > toks[k].word]
            if len(rest) < self.p.split_trail or sum(1 for t in rest if t.content) < self.p.split_trail_content:
                return []
            return rest

        # a rule that already takes the whole text (nothing left over after its path) leaves nothing to split: a weaker rule's path
        # that happens to end earlier (the start rule's, say) must not cut a sentence he read through to its end
        whole_ok = any(c.ok and c.end >= 0 and not trails(c.end) for c in whole)
        for k in [] if whole_ok else sorted({c.end for c in whole if c.end >= 0}, reverse=True):
            w = toks[k].word
            trail = trails(k)
            if not trail:
                continue
            cands = self._cands([t for t in toks if t.word <= w], lang, already, reading, base, entry)
            ok = [c for c in cands if c.ok and c.rule != "stay"]
            if ok:
                c = max(ok, key=lambda x: x.matched)
                self._note_me(c, now, track, self._anchor_move(c, cands, base))
                return Verdict("split", c.rule, c.share, c.matched, sum(1 for t in toks if t.word <= w if t.content), c.key, reading,
                               self.cursor.get(c.key or ""), " ".join(words[:w + 1]), " ".join(words[w + 1:]))
        ok = [c for c in whole if c.ok]
        if ok:
            c = max(ok, key=lambda x: x.matched)
            self._note_me(c, now, track, self._anchor_move(c, whole, base))
            return Verdict("me", c.rule, c.share, c.matched, info["content"], c.key, reading, self.cursor.get(c.key or ""))
        top = max(whole, key=lambda c: c.matched, default=None)
        if top is not None and top.rule != "strict":
            info.update(share=top.share, matched=top.matched)     # the nearest miss, for the log
        return Verdict("room", "weak", **info)
