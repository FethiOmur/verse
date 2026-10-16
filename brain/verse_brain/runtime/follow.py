"""Follow my answer (spec 2026-10-16): divergence detection on the owner's own speech, coverage of card points, and the
refresh schedule of the follow card (tier C). A pure state machine: it reads time from an injected clock, never touches
the network, and asks for embeddings through effects, so every rule is unit-testable with fakes.

How it is driven (runtime/engine.py is the only production caller):

    m = FollowMachine(params, clock, embed_ok=True)
    m.new_turn("q7")                                # a remote question has been endpointed
    m.add_line("f0004", "F", "say", "Sure, ...")    # card lines as they complete (bank lines: source="bank")
    m.on_me("m3", "I built it mostly alone", final=False)     # the owner's cumulative text for his turn
    for fx in m.drain(): ...                        # Diverged | Refresh | Covered | Ended | NeedEmbed
    m.on_embed(seq, scores)                         # the answer to a NeedEmbed (cosines per text and card line)
    m.tick()                                        # timers: pause = sentence end, embed timeout, 4 s silence end

What is measured (every number lives in `FollowParams`; the evidence for the values is in docs/follow-tuning.md):

* Tokens: lower-cased words, number words folded to digits ("eleven" -> "11", "ninety six point four" -> "96.4"), British
  -ise spellings folded, a light suffix stemmer. Content words are tokens that are not in the stopword/filler list
  ("so", "um", "yeah", "actually", light verbs). Fillers and backchannels therefore never count for or against.
* Lexical match: a content word matches the card when it sits in a cluster, i.e. at least two distinct stems of the same
  card line within +-3 content words. One stray word that also occurs somewhere on the card ("data", "project") is not a
  match. Reading the card verbatim, with ASR slips, matches almost everything; a paraphrase matches in part.
* Semantic match (EmbeddingGemma, same model and prefix as the bank matcher): the cosine between a window of his last words
  and each card line. A window that is similar enough to a line counts as matched ("rescued"), whatever the words.
* Diverged: among his last `window` content words at least `diverge_words` are unmatched (lexically AND, when the embedder
  is available, semantically), or the trailing run of unmatched content words lasts `diverge_s` seconds of his speech
  (with at least `time_min_words` words). The lexical test only raises suspicion; the embedding gets the last word.
* Coverage: a point is covered when most of its content stems occur close together in his speech, or a window of his
  words is semantically close enough to the point (numbers must not contradict). Covered points are struck through.
* Refresh: after a follow card, at his sentence ends only (a final result, or `pause_s` without new words), at most every
  `refresh_gap_s`, only with `refresh_new_words` new content words since the last C call, never while all points are covered
  and he has stopped (`quiet_s`).
* End: a new remote question (`new_turn`), or `end_silence_s` of silence from Alex after the remote spoke again.
"""

from __future__ import annotations

import math
import re
import time
from dataclasses import dataclass, field
from operator import mul
from typing import Callable, Protocol, Sequence


# --------------------------------------------------------------------------------------------------------- parameters
@dataclass
class FollowParams:
    # divergence
    window: int = 8                  # content words the unmatched count looks at
    diverge_words: int = 5           # spec: >= 5 content words that do not match the card
    diverge_s: float = 1.2           # spec: ... or >= 1.2 s of his speech
    time_min_words: int = 3          # the time rule needs this many unmatched content words in the run (one slow word is not a topic)
    lex_only_words: int = 11         # without the embedder the count rule is stricter (docs/follow-tuning.md part 1: still 12 of 46 false)
    lex_only_s: float = 4.0
    cluster_span: int = 3            # +-content words around a word that must hold a second stem of the same line
    cluster_min: int = 2             # distinct stems of one line (the word itself included)
    # semantic
    sem_floor: float = 0.80          # best cosine of his words (the unmatched run) to a card line must reach this to count as still on the card
    sem_margin: float = 0.04         # ... and no other line of the pack may beat the card by this much (he is on another pack topic then)
    sem_mark: float = 0.88           # a window this close to the card is also remembered as matched; a borderline one only vetoes this check
    cover_score: float = 0.88        # ... at or above this a card point counts as said
    cover_best_gap: float = 0.01     # ... and no other line scores more than this above it for that window
    cover_min_content: int = 4       # content words a window needs before it can strike a point semantically
    cover_names: tuple[str, ...] = ("last12", "last24", "sentence")   # which windows of his speech may cover a point
    embed_tokens: int = 12           # the "last ~12 words" window
    embed_tokens_long: int = 24
    stretch_ctx: int = 2             # raw words before the unmatched run that go into the stretch text
    stretch_min_tokens: int = 6
    use_stretch: bool = True         # embed the unmatched run (plus context) instead of the plain last-12 window
    embed_wait_s: float = 0.6        # a pending divergence waits this long for the embedding, then decides lexically
    embed_gap_s: float = 0.25        # background requests (coverage) are at least this far apart
    embed_new_words: int = 2         # ... and wait for this many new content words
    # coverage
    cover_lex: float = 0.6           # share of a point's content stems found in one span of his speech
    cover_min_stems: int = 2
    cover_span_factor: float = 2.0   # span = max(8, factor * stems of the point) content words
    # refresh
    pause_s: float = 0.7             # no new words this long = sentence end
    refresh_gap_s: float = 4.0
    refresh_new_words: int = 4
    quiet_s: float = 1.5
    end_silence_s: float = 4.0       # Alex silent this long after the remote spoke again ends follow mode
    min_gap_after_fail_s: float = 4.0


# ---------------------------------------------------------------------------------------------------------- tokenizer
_UNITS = {w: i for i, w in enumerate(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen "
    "eighteen nineteen".split())}
_TENS = {"twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90}
_MULT = {"hundred": 100, "thousand": 1000, "million": 1_000_000}
_NUMWORDS = set(_UNITS) | set(_TENS) | set(_MULT)
_RAW = re.compile(r"\d+(?:\.\d+)?|[a-z]+(?:'[a-z]+)?|\|s?")
_SENT_END = re.compile(r"[.!?]+(?=\s|$)")
_BREAK = re.compile(r"(?<!\d)[,;:!?.]|[,;:!?.](?!\d)|[()\u2014-]")

STOP = frozenset("""
a an the and or but nor so if then than that this these those it its it's i i'm i've i'll i'd me my mine myself we we're
we've we'd we'll us our ours you you're you've you'd you'll your yours he he's she she's they they're they've them their
theirs is am are was were be been being do does did done doing don't doesn't didn't have has had having haven't hasn't will
would can could should shall may might must won't wouldn't can't couldn't to of in on at by for with about as from into over
under up down out off too very just also only even still yet now here there when where while how what which who whom whose why
not no nor yes yeah yep yup nope ok okay right well uh um er erm ah oh hmm mm mhm huh hm eh aha ahh like kind sort really
actually basically literally honestly probably maybe perhaps some any all each every both either neither more most much many
other another such same one own thing things stuff way lot lots bit get gets got getting go goes going went gone make makes made
making say says said saying know knew think thought mean means meant see saw let lets want wanted need needed take took come
came put give gave tell told something anything everything someone anyone everyone because though although however
anyway sure thanks thank please sorry first then next after before again always never often sometimes usually already
quite rather pretty bit around approximately roughly almost nearly exactly mostly mainly """.split())
FILLER_FRAGMENTS = {"uh", "um", "er", "erm", "hmm", "mm", "mhm", "huh", "ah", "oh"}


def _num_value(words: list[str]) -> float | None:
    """The value of a spoken number phrase ("thirty eight thousand", "four hundred", "nineteen hundred"), else None."""
    total, cur, seen = 0, 0, False
    for w in words:
        if w == "and":
            continue
        if w in _UNITS:
            cur += _UNITS[w]
        elif w in _TENS:
            cur += _TENS[w]
        elif w in _MULT:
            m = _MULT[w]
            if m == 100:
                cur = (cur or 1) * 100
            else:
                total += (cur or 1) * m
                cur = 0
        else:
            return None
        seen = True
    return total + cur if seen else None


def tokenize(text: str) -> list[str]:
    return tokenize_sents(text)[0]


def tokenize_sents(text: str) -> tuple[list[str], list[int]]:
    """Lower-cased tokens with number words folded to digits ("twenty three" -> "23", "ninety six point four" -> "96.4",
    "twenty twenty seven" -> "2027"), thousands commas and "%" handled; plus, per token, the index of its sentence."""
    s = text.lower().replace("’", "'").replace("%", " percent ")
    s = re.sub(r"(?<=\d),(?=\d{3}\b)", "", s)
    s = _SENT_END.sub(" |s ", s)
    s = _BREAK.sub(" | ", s)               # a number phrase never runs over a comma or a full stop
    raw = _RAW.findall(s)
    out: list[str] = []
    sent: list[int] = []
    sidx = 0
    i = 0
    while i < len(raw):
        w = raw[i]
        if w in ("|", "|s"):
            if w == "|s":
                sidx += 1
            i += 1
            continue
        if w not in _NUMWORDS:
            out.append(w)
            sent.append(sidx)
            i += 1
            continue
        if w == "one" and not (i + 1 < len(raw) and raw[i + 1] in ("hundred", "thousand", "million", "point")):
            out.append(w)                  # "one" alone is a pronoun or an article as often as a number
            sent.append(sidx)
            i += 1
            continue
        j = i
        while j < len(raw) and raw[j] != "|" and (raw[j] in _NUMWORDS or (raw[j] == "and" and j + 1 < len(raw) and raw[j + 1] in _NUMWORDS
                                                           and j > i and raw[j - 1] in _MULT)):
            # a number phrase cannot hold two tens or two units in a row: "twenty twenty" is a year, not 40
            if j > i and raw[j] in _TENS and (raw[j - 1] in _TENS or raw[j - 1] in _UNITS):
                break
            if j > i and raw[j] in _UNITS and raw[j - 1] in _UNITS:
                break
            j += 1
        val = _num_value(raw[i:j])
        if val is None:
            out.append(w)
            sent.append(sidx)
            i += 1
            continue
        if j < len(raw) and raw[j] == "point" and j + 1 < len(raw) and raw[j + 1] in _UNITS and _UNITS[raw[j + 1]] < 10:
            k = j + 1
            digits = ""
            while k < len(raw) and raw[k] in _UNITS and _UNITS[raw[k]] < 10:
                digits += str(_UNITS[raw[k]])
                k += 1
            out.append(f"{val}.{digits}")
            sent.append(sidx)
            i = k
            continue
        out.append(str(val))
        sent.append(sidx)
        i = j
    # a year spoken as two numbers: "twenty twenty seven" -> 20, 27 -> 2027
    merged: list[str] = []
    msent: list[int] = []
    for tok, si in zip(out, sent):
        if (merged and merged[-1] in ("19", "20") and tok.isdigit() and 10 <= int(tok) <= 99 and msent[-1] == si
                and not (len(merged) > 1 and merged[-2].isdigit())):
            merged[-1] = merged[-1] + tok
        else:
            merged.append(tok)
            msent.append(si)
    return merged, msent


_IZE = re.compile(r"^(.{3,}?)is(e|ed|es|ing|er|ers|ation|ations)$")


def stem(w: str) -> str:
    """A light suffix stemmer; it only has to map the surface forms of a word to one key (both sides use it)."""
    if any(c.isdigit() for c in w):
        return w[:-2] if w.endswith(".0") else w
    if "'" in w:
        w = w.split("'")[0] or w
    if len(w) <= 3:
        return w
    m = _IZE.match(w)
    if m and len(w) > 6:
        w = m.group(1) + "iz" + m.group(2)
    for suf, rep, minlen in (("ies", "y", 5), ("ied", "y", 5), ("sses", "ss", 6)):
        if w.endswith(suf) and len(w) >= minlen:
            w = w[: -len(suf)] + rep
            break
    else:
        if w.endswith("ing") and len(w) > 5:
            w = w[:-3]
            if len(w) > 3 and w[-1] == w[-2] and w[-1] not in "lsz":
                w = w[:-1]
        elif w.endswith("ed") and len(w) > 4:
            w = w[:-2]
            if len(w) > 3 and w[-1] == w[-2] and w[-1] not in "lsz":
                w = w[:-1]
        elif w.endswith("ly") and len(w) > 4:
            w = w[:-2]
        elif w.endswith("es") and len(w) > 4 and (w[-3] in "sxz" or w[-4:-2] in ("ch", "sh")):
            w = w[:-2]
        elif w.endswith("s") and len(w) > 3 and not w.endswith(("ss", "us", "is")):
            w = w[:-1]
    if w.endswith("e") and len(w) > 4:
        w = w[:-1]
    if w.endswith("er") and len(w) > 6:
        w = w[:-2]
    return w


def is_content(tok: str) -> bool:
    if any(c.isdigit() for c in tok):
        return True
    if tok in STOP or tok.split("'")[0] in STOP:
        return False
    return len(tok) > 1


_REF_TAIL = re.compile(r"\s*\((?:[a-z]+:L?\d+|[bfgs]\d{3})(?:[,;]\s*[^)]*)?\)\s*$", re.IGNORECASE)


def clean_line(text: str) -> str:
    """A card line without its trailing source tag ("(prep:L14)", "(f010)"): the tag is no part of what he would say."""
    return _REF_TAIL.sub("", " ".join(text.split())).strip()


def content_stems(text: str) -> frozenset[str]:
    return frozenset(stem(t) for t in tokenize(text) if is_content(t))


def numbers_of(text: str) -> frozenset[str]:
    return frozenset(t for t in tokenize(text) if any(c.isdigit() for c in t))


# -------------------------------------------------------------------------------------------------------------- types
@dataclass
class Line:
    card_id: str
    tier: str                 # S | F | D | C | bank
    kind: str                 # "say" | "point"
    index: int                # point index on its card (0-based); -1 for a say line
    text: str
    stems: frozenset[str]
    nums: frozenset[str]
    covered: bool = False
    visible: bool = True      # a model card line the overlay shows (bank lines are reference-only: no covered events)

    @property
    def key(self) -> tuple[str, str, int]:
        return (self.card_id, self.kind, self.index)


@dataclass
class Tok:
    raw: str
    stem: str
    content: bool
    t: float                  # arrival time of the first partial that contained it
    turn: str
    sent: int = 0             # sentence index within his turn
    lex: bool = False
    sem: bool = False
    card: str | None = None   # card id of the line it matched lexically (for "back on the original card")

    @property
    def matched(self) -> bool:
        return self.lex or self.sem


@dataclass
class Diverged:
    reason: str               # "lexical+embed" | "lexical" (no embedder) | "embed_timeout"
    words: int                # unmatched content words in the window at detection
    embed: float | None       # best cosine of the stretch to any card line (None: not measured)
    margin: float | None      # best cosine to a pack line that is not on the card, minus the card score
    lex_score: float          # unmatched share of the window (0..1)
    ms: float                 # since the first word of the unmatched run arrived
    run_words: int
    start_ms: float           # since the first word of his answer arrived
    text: str                 # his words so far (the run included)


@dataclass
class Refresh:
    new_words: int
    text: str


@dataclass
class Covered:
    card_id: str
    point: int
    via: str                  # "lex" | "embed"
    score: float


@dataclass
class Ended:
    reason: str


@dataclass
class NeedEmbed:
    seq: int
    texts: dict[str, str]                       # name -> text to embed
    lines: list[tuple[str, str, int, str]]      # (card_id, kind, index, text) of every reference line


Effect = Diverged | Refresh | Covered | Ended | NeedEmbed


@dataclass
class _Card:
    card_id: str
    tier: str
    lines: list[Line] = field(default_factory=list)
    points: int = 0


class Embedder(Protocol):
    def embed(self, text: str) -> list[float]: ...


def unit(v: list[float]) -> list[float]:
    n = math.sqrt(sum(x * x for x in v))
    return [x / n for x in v] if n > 0 else list(v)


def score_matrix(embed: Callable[[str], list[float]], req: NeedEmbed, cache: dict[str, list[float]] | None = None,
                 prefix: str = "", pack: Sequence[str] = ()) -> tuple[dict[str, list[float]], dict[str, float]]:
    """(cosines of every requested text to every requested card line, best cosine of every text to the pack lines that are
    not card lines). `embed` returns an unnormalised vector; vectors are cached by text, so a card line or a pack line is
    embedded once per session. Used by both drivers (sync and the engine's embedding thread)."""
    cache = cache if cache is not None else {}

    def vec(t: str) -> list[float]:
        v = cache.get(t)
        if v is None:
            v = cache[t] = unit(embed(prefix + t))
        return v

    lines = [vec(ln[3]) for ln in req.lines]
    own = {ln[3] for ln in req.lines}
    others = [vec(t) for t in pack if t not in own]
    scores = {name: [sum(map(mul, vec(text), lv)) for lv in lines] for name, text in req.texts.items()}
    best = {name: (max(sum(map(mul, vec(text), ov)) for ov in others) if others else -1.0)
            for name, text in req.texts.items()}
    return scores, best


# --------------------------------------------------------------------------------------------------------- machine
class FollowMachine:
    def __init__(self, params: FollowParams | None = None, clock: Callable[[], float] = time.monotonic, *,
                 embed_ok: bool = False) -> None:
        self.p = params or FollowParams()
        self.clock = clock
        self.embed_ok = embed_ok
        self._fx: list[Effect] = []
        self.turn_id: str | None = None
        self._seq = 0                                  # request numbers never restart: a late answer of an old turn finds no meta
        self._applied_seq = 0
        self._stale_turns: set[str] = set()
        self._reset()

    # ---------------------------------------------------------------------------------------------- state
    def _reset(self) -> None:
        self.cards: dict[str, _Card] = {}
        self.order: list[str] = []                     # card ids in arrival order
        self.original_id: str | None = None            # the F/S card the overlay showed first
        self.visible_id: str | None = None             # the card on screen (the latest C once following)
        self.turn_order: list[str] = []                # the owner's turn ids since the question
        self.turn_toks: dict[str, list[Tok]] = {}
        self.turn_text: dict[str, str] = {}
        self._toks_cache: list[Tok] | None = None
        self.mode = "watch"                            # watch -> following -> (ended)
        self.ended = False
        self.last_word_t: float | None = None
        self.diverged_at: float | None = None
        self.c_launch_t: float | None = None
        self.c_in_flight = False
        self.c_count = 0
        self.last_c_t: float = -1e9
        self.fail_t: float = -1e9
        self.refreshed_at_word_t: float | None = None  # last_word_t at the last refresh decision (one refresh per pause)
        self.remote_at: float | None = None
        self.final_seen = False
        self._req_meta: dict[int, dict] = {}
        self._pend_div: dict | None = None             # {"seq", "deadline"}
        self._last_req_t = -1e9
        self._last_req_content = 0
        self.stats = {"diverged": 0, "refresh": 0, "covered": 0}
        self.last_embed: float | None = None
        self.last_margin: float | None = None

    def new_turn(self, turn_id: str) -> None:
        """A remote question was endpointed: follow mode of the previous turn is over, the card state starts again."""
        if turn_id == self.turn_id:
            return
        self.turn_id = turn_id
        keep = self.stats
        self._stale_turns |= set(self.turn_order)      # his turn that is still open keeps sending cumulative text: ignore it
        self._reset()
        self.stats = keep

    def reset_cards(self) -> None:
        """The same question is answered again (offline retry, late bank hit): the old card lines are void, his words stay."""
        self.cards.clear()
        self.order.clear()
        self.original_id = self.visible_id = None
        self.mode = "watch"
        self.diverged_at = None
        self._pend_div = None
        self.c_in_flight = False

    # ------------------------------------------------------------------------------------------------ cards
    def add_line(self, card_id: str, tier: str, kind: str, text: str, *, source: str = "model") -> None:
        """A complete card line. `kind` is "say" or "point"; points are indexed in arrival order on their card. Lines with
        `source="bank"` (the prepared answer) or `"ref"` (D's detail points) are references only: they keep a paraphrase of
        them from counting as a divergence, but they carry no `covered` events."""
        text = clean_line(text)
        if not text or self.ended:
            return
        card = self.cards.get(card_id)
        if card is None:
            card = self.cards[card_id] = _Card(card_id, tier)
            self.order.append(card_id)
            if tier in ("S", "F") and self.original_id is None:
                self.original_id = card_id
            if tier == "C":
                self.visible_id = card_id
            elif self.visible_id is None and tier in ("S", "F"):
                self.visible_id = card_id
        idx = -1
        if kind == "point":
            idx = card.points
            card.points += 1
        ln = Line(card_id, tier, kind, idx, text, content_stems(text), numbers_of(text), visible=(source == "model"))
        card.lines.append(ln)
        self._recompute()
        self._check_all()

    def ref_lines(self) -> list[Line]:
        return [ln for cid in self.order for ln in self.cards[cid].lines if ln.stems]

    def card_lines(self, card_id: str | None) -> list[Line]:
        c = self.cards.get(card_id) if card_id else None
        return list(c.lines) if c else []

    # ------------------------------------------------------------------------------------------------- speech
    def toks(self) -> list[Tok]:
        if self._toks_cache is None:
            self._toks_cache = [t for tid in self.turn_order for t in self.turn_toks[tid]]
        return self._toks_cache

    def on_me(self, turn_id: str, text: str, final: bool = False, now: float | None = None) -> None:
        """the owner's text for his turn `turn_id` (cumulative within the turn; a revision replaces the changed tail)."""
        if self.turn_id is None or self.ended or turn_id in self._stale_turns:
            return
        now = self.clock() if now is None else now
        new, new_sent = tokenize_sents(text)
        old = self.turn_toks.get(turn_id)
        if old is None:
            self.turn_order.append(turn_id)
            old = []
        k = 0
        while k < len(old) and k < len(new) and old[k].raw == new[k]:
            k += 1
        toks = old[:k] + [Tok(w, stem(w), is_content(w), now, turn_id, new_sent[i]) for i, w in enumerate(new) if i >= k]
        for i in range(k):
            toks[i].sent = new_sent[i]
        changed = len(new) != len(old) or k < len(new)
        self.turn_toks[turn_id] = toks
        self.turn_text[turn_id] = " ".join(text.split())
        self._toks_cache = None
        if changed:
            self.last_word_t = now
        if final:
            self.final_seen = True
        self._recompute()
        self._check_all(now, final=final)

    def on_remote_activity(self, now: float | None = None) -> None:
        """The remote spoke again (any partial or turn after the question)."""
        if self.turn_id is None or self.ended:
            return
        self.remote_at = self.clock() if now is None else now

    def his_text(self) -> str:
        return " ".join(self.turn_text[t] for t in self.turn_order if self.turn_text.get(t))

    # ---------------------------------------------------------------------------------------- lexical matching
    def _recompute(self) -> None:
        toks = self.toks()
        lines = self.ref_lines()
        content = [i for i, t in enumerate(toks) if t.content]
        for t in toks:
            t.lex = False
            t.card = None
        span, need = self.p.cluster_span, self.p.cluster_min
        for pos, i in enumerate(content):
            s = toks[i].stem
            cand = [ln for ln in lines if s in ln.stems]
            if not cand:
                continue
            near = {toks[j].stem for j in content[max(0, pos - span): pos + span + 1] if j != i}
            best: Line | None = None
            best_n = 0
            for ln in cand:
                n = 1 + len((near - {s}) & ln.stems)
                if n > best_n:
                    best, best_n = ln, n
            if best is not None and best_n >= need:
                toks[i].lex = True
                toks[i].card = best.card_id

    def _content(self) -> list[Tok]:
        return [t for t in self.toks() if t.content]

    def _unmatched_window(self) -> tuple[int, list[Tok]]:
        win = self._content()[-self.p.window:]
        return sum(1 for t in win if not t.matched), win

    def _run(self) -> list[Tok]:
        """The trailing run of unmatched content words."""
        run: list[Tok] = []
        for t in reversed(self._content()):
            if t.matched:
                break
            run.append(t)
        run.reverse()
        return run

    # ---------------------------------------------------------------------------------------------- decisions
    def _lex_trigger(self) -> tuple[bool, int, list[Tok]]:
        p = self.p
        n, _ = self._unmatched_window()
        run = self._run()
        words = p.diverge_words if self.embed_ok else p.lex_only_words
        secs = p.diverge_s if self.embed_ok else p.lex_only_s
        by_count = n >= words
        by_time = len(run) >= p.time_min_words and run[-1].t - run[0].t >= secs
        return (by_count or by_time), n, run

    def _check_all(self, now: float | None = None, final: bool = False) -> None:
        if self.ended or self.turn_id is None:
            return
        now = self.clock() if now is None else now
        self._coverage_lex()
        if self.mode == "watch":
            self._check_diverge(now)
        self._maybe_request(now, force=final)
        if self.mode == "following":
            self._check_refresh(now, final=final)

    def _check_diverge(self, now: float) -> None:
        if not self.ref_lines():
            return                        # no card yet: nothing to diverge from
        if self.diverged_at is not None or now - self.fail_t < self.p.min_gap_after_fail_s:
            return
        trig, n, run = self._lex_trigger()
        if not trig:
            self._pend_div = None
            return
        if not self.embed_ok:
            self._diverge(now, "lexical", n, run, None)
            return
        if self._pend_div is None:
            req = self._request(now, for_div=True)
            self._pend_div = {"seq": req.seq if req else None, "deadline": now + self.p.embed_wait_s}
            if req is None:
                self._diverge(now, "embed_timeout", n, run, None)

    def _diverge(self, now: float, reason: str, n: int, run: list[Tok], embed: float | None,
                 margin: float | None = None) -> None:
        self._pend_div = None
        first = run[0].t if run else now
        self.diverged_at = now
        self.stats["diverged"] += 1
        toks = self.toks()
        start = toks[0].t if toks else now
        self._fx.append(Diverged(reason, n, embed, margin, round(n / max(1, min(self.p.window, len(self._content()))), 3),
                                 round((now - first) * 1000, 1), len(run), round((now - start) * 1000, 1),
                                 self.his_text()))

    # --------------------------------------------------------------------------------------------- embeddings
    def _stretch_text(self, run: list[Tok]) -> tuple[str, int]:
        toks = self.toks()
        p = self.p
        if run:
            first = toks.index(run[0])
        else:
            first = max(0, len(toks) - p.embed_tokens)
        start = max(0, first - p.stretch_ctx)
        start = min(start, max(0, len(toks) - p.stretch_min_tokens))
        start = max(start, len(toks) - p.embed_tokens)
        return " ".join(t.raw for t in toks[start:]), start

    def _sentence_text(self) -> tuple[str, int]:
        """His current sentence so far (at most `embed_tokens_long` words, at least `stretch_min_tokens`: a short one is
        extended back into the sentence before)."""
        toks = self.toks()
        if not toks:
            return "", 0
        last = (toks[-1].turn, toks[-1].sent)
        i = len(toks)
        while i > 0 and (toks[i - 1].turn, toks[i - 1].sent) == last:
            i -= 1
        start = min(i, max(0, len(toks) - self.p.stretch_min_tokens))
        start = max(start, len(toks) - self.p.embed_tokens_long)
        return " ".join(t.raw for t in toks[start:]), start

    def _request(self, now: float, for_div: bool = False) -> NeedEmbed | None:
        if not self.embed_ok:
            return None
        lines = self.ref_lines()
        toks = self.toks()
        if not lines or not toks:
            return None
        self._seq += 1
        p = self.p
        texts = {"last12": " ".join(t.raw for t in toks[-p.embed_tokens:]),
                 "last24": " ".join(t.raw for t in toks[-p.embed_tokens_long:])}
        starts = {"last12": max(0, len(toks) - p.embed_tokens), "last24": max(0, len(toks) - p.embed_tokens_long)}
        if p.use_stretch:
            st, start = self._stretch_text(self._run())
            texts["stretch"] = st
            starts["stretch"] = start
            st, start = self._sentence_text()
            texts["sentence"] = st
            starts["sentence"] = start
        req = NeedEmbed(self._seq, texts, [(ln.card_id, ln.kind, ln.index, ln.text) for ln in lines])
        self._req_meta[self._seq] = {"starts": starts, "end": len(toks), "raws": [t.raw for t in toks], "lines": lines}
        for k in [k for k in self._req_meta if k < self._seq - 6]:
            del self._req_meta[k]
        self._fx.append(req)
        self._last_req_t = now
        self._last_req_content = len(self._content())
        return req

    def _maybe_request(self, now: float, force: bool = False) -> None:
        """Background requests for coverage (the divergence check asks for its own)."""
        if not self.embed_ok or self._pend_div is not None:
            return
        if not any(not ln.covered and ln.visible for ln in self.ref_lines()):
            return
        new = len(self._content()) - self._last_req_content
        if new <= 0:
            return
        if force or (new >= self.p.embed_new_words and now - self._last_req_t >= self.p.embed_gap_s):
            self._request(now)

    def on_embed(self, seq: int, scores: dict[str, list[float]], others: dict[str, float] | None = None,
                 now: float | None = None) -> None:
        """The cosines for `NeedEmbed(seq)`: per text name, one score per requested line (same order); `others`: per text
        name, the best cosine to the pack's lines that are not on the card (None: no pack lines known)."""
        if self.turn_id is None or self.ended or seq <= self._applied_seq:
            return
        meta = self._req_meta.get(seq)
        if meta is None:
            return
        self._applied_seq = seq
        now = self.clock() if now is None else now
        req_lines = meta["lines"]
        toks = self.toks()
        same = [t.raw for t in toks[:meta["end"]]] == meta["raws"][:len(toks)] and len(toks) >= meta["end"]
        p = self.p
        names = ["stretch"] if p.use_stretch and "stretch" in scores else ["last12"]
        best_stay, best_ln = -1.0, None
        for ln, sc in zip(req_lines, scores.get(names[0], [])):
            if sc > best_stay:
                best_stay, best_ln = sc, ln
        self.last_embed = round(best_stay, 4)
        other = (others or {}).get(names[0], -1.0)
        margin = round(other - best_stay, 4) if others else 0.0
        self.last_margin = margin
        on_card = best_stay >= p.sem_floor and margin < p.sem_margin
        # rescue: his words are still the card, said another way
        if same and on_card and best_ln is not None and best_stay >= p.sem_mark:
            start = meta["starts"][names[0]]
            for t in toks[start:meta["end"]]:
                if not t.lex:
                    t.sem = True
                    t.card = t.card or best_ln.card_id
        # semantic coverage
        if same:
            for name in p.cover_names:
                top = max(scores.get(name, [-1.0]))
                for ln, sc in zip(req_lines, scores.get(name, [])):
                    if (ln.visible and ln.kind == "point" and not ln.covered and sc >= p.cover_score
                            and sc >= top - p.cover_best_gap):
                        start = meta["starts"][name]
                        win = toks[start:meta["end"]]
                        span = " ".join(t.raw for t in win)
                        if sum(1 for t in win if t.content) >= p.cover_min_content and self._numbers_ok(ln, span):
                            self._cover(ln, "embed", sc)
        pend = self._pend_div
        if pend is not None and (pend["seq"] is None or seq >= pend["seq"]):
            self._pend_div = None
            if self.mode == "watch" and self.diverged_at is None:
                trig, n, run = self._lex_trigger()
                if trig and not on_card:
                    self._diverge(now, "lexical+embed", n, run, round(best_stay, 4), margin)
                elif not trig or on_card:
                    pass
        self._maybe_request(now)
        if self.mode == "following":
            self._check_refresh(now)

    # ----------------------------------------------------------------------------------------------- coverage
    @staticmethod
    def _numbers_ok(ln: Line, span: str) -> bool:
        """A point that carries numbers is struck only when he said one of them: "twenty minutes to five" is not "11 minutes
        to 2", and a sentence that has not reached its numbers yet has not said the point."""
        return not ln.nums or bool(ln.nums & numbers_of(span))

    def _cover(self, ln: Line, via: str, score: float) -> None:
        if ln.covered or not ln.visible or ln.kind != "point":
            return
        ln.covered = True
        self.stats["covered"] += 1
        self._fx.append(Covered(ln.card_id, ln.index, via, round(score, 4)))

    def _coverage_lex(self) -> None:
        p = self.p
        content = [t.stem for t in self._content()][-60:]
        if not content:
            return
        for cid in self.order:
            for ln in self.cards[cid].lines:
                if ln.kind != "point" or ln.covered or not ln.visible or len(ln.stems) < p.cover_min_stems:
                    continue
                span = max(8, int(p.cover_span_factor * len(ln.stems)))
                need = max(p.cover_min_stems, math.ceil(p.cover_lex * len(ln.stems)))
                best = 0
                for s0 in range(0, max(1, len(content) - span + 1)):
                    got = len(ln.stems & set(content[s0:s0 + span]))
                    if got > best:
                        best = got
                    if best >= need:
                        break
                if best >= need:
                    span_txt = " ".join(t.raw for t in self.toks()[-120:])
                    if self._numbers_ok(ln, span_txt):
                        self._cover(ln, "lex", best / len(ln.stems))

    # ----------------------------------------------------------------------------------------------- refresh
    def c_started(self, card_id: str, now: float | None = None) -> None:
        """The engine launched a C call (after a Diverged or Refresh effect)."""
        now = self.clock() if now is None else now
        self.mode = "following"
        self.c_launch_t = now
        self.last_c_t = now
        self.c_in_flight = True
        self.c_count += 1
        self._pend_div = None

    def c_failed(self, now: float | None = None) -> None:
        """The launch was refused (rate bucket, halted): stay as before and retry no earlier than `min_gap_after_fail_s`."""
        now = self.clock() if now is None else now
        self.fail_t = now
        if self.mode == "watch":
            self.diverged_at = None

    def c_done(self) -> None:
        self.c_in_flight = False

    def _new_words_since_c(self) -> int:
        if self.c_launch_t is None:
            return 0
        orig = self.original_id
        vis = self.visible_id
        n = 0
        for t in self.toks():
            if not t.content or t.t <= self.c_launch_t:
                continue
            if t.matched and t.card == orig and orig != vis:
                continue                      # he is back on the original card: not news for the follow card
            n += 1
        return n

    def _all_covered(self) -> bool:
        pts = [ln for ln in self.card_lines(self.visible_id) if ln.kind == "point"]
        return bool(pts) and all(ln.covered for ln in pts)

    def _check_refresh(self, now: float, final: bool = False) -> None:
        p = self.p
        if self.ended or self.c_in_flight or self.mode != "following" or self.last_word_t is None:
            return
        if now - self.last_c_t < p.refresh_gap_s:
            return
        if self.refreshed_at_word_t == self.last_word_t:
            return
        pause = now - self.last_word_t
        sentence_end = final or pause >= p.pause_s
        if not sentence_end:
            return
        n = self._new_words_since_c()
        if n < p.refresh_new_words:
            return
        if self._all_covered() and pause >= p.quiet_s and not final:
            return                            # he said everything on the card and stopped: no push
        self.refreshed_at_word_t = self.last_word_t
        self.stats["refresh"] += 1
        self._fx.append(Refresh(n, self.his_text()))

    # ------------------------------------------------------------------------------------------------- timers
    def tick(self, now: float | None = None) -> None:
        if self.turn_id is None or self.ended:
            return
        now = self.clock() if now is None else now
        p = self.p
        pend = self._pend_div
        if pend is not None and now >= pend["deadline"] and self.mode == "watch" and self.diverged_at is None:
            self._pend_div = None
            trig, n, run = self._lex_trigger()
            if trig:
                self._diverge(now, "embed_timeout", n, run, None)
        if self.mode == "following":
            self._check_refresh(now)
        if self.remote_at is not None:
            quiet_since = max(self.remote_at, self.last_word_t or -1e9)
            if now - quiet_since >= p.end_silence_s:
                self.end("remote_spoke_again")

    def end(self, reason: str) -> None:
        if self.ended:
            return
        self.ended = True
        self._pend_div = None
        self._fx.append(Ended(reason))

    # -------------------------------------------------------------------------------------------------- output
    def drain(self) -> list[Effect]:
        fx, self._fx = self._fx, []
        return fx

    def pop_embed(self) -> NeedEmbed | None:
        """The newest NeedEmbed in the queue (older ones are dropped, like the engine's coalescing queue)."""
        for i in range(len(self._fx) - 1, -1, -1):
            if isinstance(self._fx[i], NeedEmbed):
                req = self._fx[i]
                self._fx = [e for e in self._fx if not isinstance(e, NeedEmbed)]
                return req  # type: ignore[return-value]
        return None
