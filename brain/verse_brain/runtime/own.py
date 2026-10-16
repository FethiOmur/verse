"""the owner's own voice in the room route, told by text (docs/specs/2026-10-16-verse-anytime-calls-design.md 2.1).

The room route has one microphone and no speaker separation before phase D, so the owner's own sentences arrive labelled
`room`, next to the interviewer's. The commonest own speech in a live call is the card itself: he reads the SAY line and
the points aloud. While a card is on screen, a room partial or turn whose content words line up with that card, in order,
is his voice: it is relabelled `me` before anything else looks at it. It then never fires a card, it moves follow mode's
coverage (struck-through points) and it sits in the transcript as `[Alex]`. Text that does not line up stays `room`.

The measure reuses the follow detector's tokenizer, stopword list and stemmer (`follow.py`): content words are compared
stem by stem, in order, against the lines of the card, the way he would read them (top to bottom; a word or two skipped
or misheard is fine). The measure is the share of the text's content words that sit on one in-order path through the
card, with at most `max_gap` card words skipped between two matched ones. The follow detector's own lexical rule (a word
matches when a second stem of the same line is within +-3 words) is order-blind; it would let an interviewer who restates
a card's words ("why you chose accounting as a major") look like Alex, and here that is the failure to avoid.

This is an interim rule until phase D separates the voices by embedding. It cannot know that Alex paraphrases the card
(that text stays `room`), and it cannot tell another person reading the same words.
"""

from __future__ import annotations

from dataclasses import dataclass

from .follow import clean_line, is_content, stem, tokenize


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


@dataclass(frozen=True)
class OwnScore:
    share: float              # matched / content words of the text
    matched: int
    content: int
    card: str | None = None   # key of the card the best path is on


def content_stems(text: str) -> list[str]:
    return [stem(t) for t in tokenize(text) if is_content(t)]


def aligned(text: list[str], card: list[str], max_gap: int) -> int:
    """Most content words of `text` that sit on one in-order path through `card`: matched pairs (i, j) with i and j both
    increasing, and at most `max_gap` card words skipped between two consecutive pairs. Words of `text` that match nothing
    are free to be skipped (they only lower the share)."""
    n, m = len(text), len(card)
    if n == 0 or m == 0:
        return 0
    # best[j]: longest path ending with card position j, over the text words seen so far
    best = [0] * m
    top = 0
    for i in range(n):
        # a pair (i, j) extends a path that ended at j' in [j - 1 - max_gap, j - 1] on an earlier text word; `best` still holds
        # only earlier words while this row is computed (it is updated after), so one row never extends itself
        row = {}
        for j in range(m):
            if card[j] != text[i]:
                continue
            lo = max(0, j - 1 - max_gap)
            prev = max(best[lo:j], default=0)
            row[j] = prev + 1
        for j, v in row.items():
            if v > best[j]:
                best[j] = v
                if v > top:
                    top = v
    return top


class OwnSpeech:
    """The lines of the card on screen and the match of a room text against them."""

    def __init__(self, params: OwnParams | None = None) -> None:
        self.p = params or OwnParams()
        self.turn_id: str | None = None
        self.cards: dict[str, list[tuple[str, str]]] = {}      # card key -> [(kind, text)] in reading order
        self._stems: dict[str, list[str]] = {}

    def clear(self) -> None:
        self.turn_id = None
        self.cards.clear()
        self._stems.clear()

    def add(self, turn_id: str, card_key: str, kind: str, text: str, *, new_say: bool = False) -> None:
        """A complete card line that the overlay shows. A new turn's first line starts a new card; `new_say` (an S/F SAY line)
        replaces the lines of that card key (the fast tier's answer replaces what was there)."""
        text = clean_line(text)
        if not text:
            return
        if turn_id != self.turn_id:
            self.clear()
            self.turn_id = turn_id
        lines = self.cards.setdefault(card_key, [])
        if new_say:
            lines.clear()
        lines.append((kind, text))
        self._stems[card_key] = [s for _, t in lines for s in content_stems(t)]

    def has_card(self) -> bool:
        return any(self._stems.values())

    def score(self, text: str) -> OwnScore:
        mine = content_stems(text)
        if not mine or not self.has_card():
            return OwnScore(0.0, 0, len(mine))
        best_n, best_key = 0, None
        for key, card in self._stems.items():
            n = aligned(mine, card, self.p.max_gap)
            if n > best_n:
                best_n, best_key = n, key
        return OwnScore(best_n / len(mine), best_n, len(mine), best_key)

    def is_own(self, text: str, already: bool = False) -> tuple[bool, OwnScore]:
        """Is this room text the owner's? `already`: the turn was taken for his before (hysteresis: it stays his above `stay`)."""
        sc = self.score(text)
        if sc.matched < self.p.min_matched:
            return False, sc
        return sc.share >= (self.p.stay if already else self.p.enter), sc
