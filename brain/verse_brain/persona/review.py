"""The after-call review: every question -> owner-answer pair of a finished session is judged, and the code decides what the
judgement may change. It rides in the persona's one request per session (extract.py `build_request`: `review_blocks` adds the
rules to the system text and CONFIRMED SOURCES plus QUESTION PAIRS to the user message; no pairs, no change to the request).

Pairs (`build_pairs`, rows.py rows only): a question is a row of the other side (or a room row) that asks him something
(`asks`: it ends with "?", opens with a question word or an auxiliary verb and its subject, or asks anywhere: "tell me", "can
you", "I want to understand"; the transcript's own `kind` is not enough, live classification marks monologue fragments as
questions). His rows after it are his answer, read as one text (rows.py `merge_rows`: a rolling transcript's repeated words
count once). The other side's acknowledgements ("yeah", "okay okay") never end an answer; their first real statement after
he has answered (ANSWER_MIN_WORDS of his own words) does, and so does their next question. Questions in a row, and their
statements before he has really started, are one question split across rows; one they talk past (more than QUESTION_TAIL
statements) lapses. Statements alone, and a question he only acknowledged, are no pair. The card of a pair is the card shown on
its question's turn (events.jsonl `card_done.turn`). A question left without an owner row is not reviewed (on the room route his
words may sit in an unlabelled room row), unless its card was marked. A live mark (rows.py `read_marks`; the last mark on a card
wins, `cleared` removes it) joins the pair of its card's turn; a mark on a card whose turn has no pair becomes a pair of its own,
with the question the mark carries and no answer.

The model gives each real question ONE verdict with ONE reason (pairs it leaves out, not real questions, are never weak and
never listed): strong (direct and specific), fine (clear and on topic, however long or conversational: filler and transcription
noise never count) or weak, for one of four reasons only: missed_question, nothing_specific (generic where the sources hold
specifics), contradicts_source (with the line's id), trailed_off. Its "why" states that reason, and the record's labels
(answered / specific / length) are derived from the verdict, so they never disagree with it. Code then checks and decides
(`verify_reviews`):

  verdict       weak needs one of the four reasons, else it is fine (`dropped.weak_reason`); a contradiction needs code's check
  contradiction kept only when the id is a CONFIRMED SOURCES line and the answer states a number or name that line does not
                (store.py `_differs`); without it the verdict is fine
  spoken        weak (its one reason), strong, ok (fine), unreviewed, or none (no answer rows)
  action        GOOD mark -> kept: the card's wording enters the bank, first for that question, when every number and name of it
                is in a confirmed source or in his answer; strong -> adopted: his own wording (the model's tightening when it
                uses only his words and numbers, else the answer rows cut at a sentence) unless he read it off the card or it
                carries a card's number or name that no confirmed source has; weak or BAD mark -> improved, from the model's
                `improved` lines when every line passes `ground_lines`, else no better answer (the item is dropped, never
                softened); a question the owner rejected before -> nothing is generated again. A mark names the card whose SAY
                line was on screen: a call id, or `P-<turn>` for the bank's opener, which keeps that bank entry's opener and
                points (no other call's text)
  learning      items (extract.py) cited in the rows of a weak answer are dropped (`dropped.weak`): a weak answer is never
                learned as his style or as a fact
  BAD mark      the card's bank entry (the turn's agreeing `bank_verdict` or bank `own_card`, looked up in the session's own
                bank.jsonl) leaves the bank (store.py `demote`), whether or not a grounded rewrite exists

Confirmed sources (`SourceBook`): me.md lines (their own `m###` ids, written `[m101] ...` with or without a bullet, their
provenance field left out), his notes (`n###`: me.notes.md lines, plain or bulleted), his MY CORRECTIONS lines (`k###`), his own
lines in Persona.md (`o###`), the seed (`g###`; a seed answer whose card he marked BAD leaves the bank but its facts stay a
source), persona entries he spoke in his own words or edited (`p###`, with their verified quote), better answers in his words
(`i###`), and his strong or fine answers in other calls (`a###`, from the state's review records). His own layer (k, o, m, n)
is offered first; the rest, most relevant to this call's questions and answers first, up to SOURCES_TOKENS. An improved answer
may rest on nothing else.

After the call (`apply_review`): the better answers go into the persona (store.py `add_better`), the session's review is kept in
the state (`reviews`) and the Review note (`render_note`) lists what went well (strong answers, GOOD marks), the fine ones, the
weak answers with their better version, the marks and the open contradictions; topics weak in two or more calls come first (`recurring_weak`).

Logs carry counts only.
"""

from __future__ import annotations

import logging
import math
import re
from dataclasses import dataclass, field

from ..prep.model import PRICES
from ..prep.sources import numbers_in, significant_numbers
from ..runtime.ask import est_tokens
from ..runtime.me import content_words, jaccard
from ..runtime.own import content_stems
from ..runtime.settings import SONNET
from .extract import CardFacts, Confirmed, json_object, months_in, name_tokens, names_not_in_row
from .rows import CardRec, Mark, PRow, SessionRows, _wkey, final_marks, is_backchannel, merge_rows
from .store import BETTER_KINDS, LEARNED_KINDS, NOTE_ANSWER_INDENT, SEED_KINDS, TOPIC_OVERLAP, _differs, one_line

log = logging.getLogger("verse.persona.review")

REVIEW_VERSION = 2            # 2: real-question pairs, one verdict with one reason, the me layer and earlier answers as sources
MAX_PAIRS = 40                 # pairs reviewed per session (marked pairs first, then in order)
SOURCES_TOKENS = 9_000         # CONFIRMED SOURCES in the request, cut at whole lines (his own layer first, the rest by relevance)
ANSWER_MIN_WORDS = 8           # his words (rolling rows merged, acknowledgements left out) before his answer counts as started
REPLY_MIN_WORDS = 3            # ... before their next question is a new question (fewer: an interjection, "actually I")
QUESTION_TAIL = 4              # their statements after a question, before he answers, that still belong to it (then it lapsed)
MAX_EARLIER_ANSWERS = 12       # his strong / fine answers from other calls offered as sources (`a###`), most relevant first
EARLIER_ANSWER_CHARS = 600     # an answer's text kept in the review record (and offered as a source)
CARD_CHARS = 300               # a card's text in QUESTION PAIRS
MAX_IMPROVED_LINES = 4
MAX_LINE_CHARS = 300
MAX_WORDING_CHARS = 600
GROUND_MIN_SHARE = 0.3         # an improved line's content stems found in the sources it cites (English lines; see ground_lines)
GROUND_MIN_SHARED = 2
WORDING_MIN_SHARE = 0.7        # his tightened wording's content stems found in his answer rows
EST_OUT_PER_PAIR = 70          # dry-run projection: output tokens of one pair's review
EST_OUT_PER_IMPROVED = 170     # ... of one improved answer
EST_WEAK_SHARE = 0.35          # ... share of pairs projected weak

VERDICTS = ("strong", "fine", "weak")
# The four reasons an answer may be weak (the model's word -> the reason code kept in the record and shown in the note).
WEAK_REASONS = {"missed_question": "not_answered", "nothing_specific": "vague", "contradicts_source": "contradiction",
                "trailed_off": "trailed_off"}

# Frozen: added after the persona system text when the session has question pairs.
REVIEW_SYSTEM = (
    "ALSO REVIEW his answers. QUESTION PAIRS lists each question he was asked: the pair id, the rows of the question (or the "
    "question his live mark names), the rows of his answer (it runs across the other side's short acknowledgements: read every "
    "row of his in that range), the card that was on his screen, and his live mark on it (GOOD, BAD or none). Add a second key "
    "to the same JSON object: \"reviews\": [ ... ], one object per pair in which the other side really asked him something or "
    "asked him for something (leave out pairs where they only made a statement, and small talk), shaped {\"pair\": \"q1\", "
    "\"topic\": ..., \"question\": ..., \"verdict\": ..., \"reason\": ..., \"why\": ..., \"contradicts\": ...} and always "
    "carrying its \"pair\" id from QUESTION PAIRS: \"topic\" (at most 8 words, no names of the people or companies he spoke "
    "with), \"question\" (what they asked, rewritten as one clean neutral sentence without those names, however broken the rows "
    "are), \"verdict\", \"reason\", \"why\" and \"contradicts\". Judge what he said, not how it sounds: the rows are speech "
    "recognition of live talk, so filler words, "
    "repeats, restarts, broken grammar and misheard words are normal and never make an answer weak, and neither does length "
    "alone. \"verdict\" is one of: \"strong\" (answers the question directly and backs it with something specific: a figure, a "
    "named project, a concrete example or outcome); \"fine\" (a clear, on-topic answer, even when long, conversational or "
    "loosely built; a short direct reply to a yes/no or practical question is fine); \"weak\" only for one of these reasons, "
    "given in \"reason\": \"missed_question\" (he did not answer what was asked), \"nothing_specific\" (he stayed generic "
    "although CONFIRMED SOURCES hold specifics that answer it), \"contradicts_source\" (he stated something a CONFIRMED SOURCES "
    "line contradicts; its id goes in \"contradicts\"), \"trailed_off\" (he stopped or drifted off without making his point). "
    "\"reason\" is \"\" for strong and fine, and \"contradicts\" is \"\" unless the reason is contradicts_source. \"why\" (at "
    "most 15 words) gives the reason for this verdict and must agree with it. When the verdict is weak or the mark is BAD, add "
    "\"improved\": {\"lines\": [{\"text\": one sentence in his voice, first person, in the language of his answer, \"src\": [the "
    "ids of the CONFIRMED SOURCES lines it rests on], and when the line is not in English \"en\": the same sentence in English, "
    "word for word}]} with 1 to 4 lines: a better answer to that question built ONLY from CONFIRMED SOURCES (his profile "
    "lines, his notes, his persona entries, his imported prep and his own answers in earlier calls). Write it whenever those "
    "lines hold something that answers the question; leave \"improved\" out only when nothing in them is relevant. Every "
    "number, name and date in a line must be in a line it cites. When the verdict is strong, add \"wording\": his answer "
    "tightened to at most 3 sentences, using only his own words and numbers from his answer rows."
)


# ---------------------------------------------------------------- confirmed sources
_ME_LINE = re.compile(r"^\s*(?:[-*]\s*)?\[(m\d{3,})\]\s*(.+)$")      # me.md writes `[m101] ...`, with or without a bullet
_BULLET = re.compile(r"^\s*[-*]\s+(.+)$")
_PROVENANCE = re.compile(r"^(?:[\w.-]+:\S+|[a-z][\w-]*)$")         # a me.md line's last field: `file:x.md#L3`, or who confirmed it
_NOTE_SKIP = ("#", "<!--", "---", "|")
MIN_NOTE_CHARS = 12
PRIORITY = ("k", "o", "m", "n")      # his own layer, offered first and in file order; every other source by relevance


def me_line_text(body: str) -> str:
    """A me.md line without its provenance field (`... | file:career.md#L21`, `... | owner`): the fact, not where it came from."""
    parts = [p.strip() for p in body.split(" | ")]
    if len(parts) > 1 and _PROVENANCE.match(parts[-1]):
        parts = parts[:-1]
    return " | ".join(p for p in parts if p)


@dataclass
class SourceBook:
    """id -> text of every confirmed source an improved answer may rest on. `block` offers his own layer first (corrections,
    his own Persona.md lines, me.md, his notes), then the rest most relevant to the call first (`focus`)."""
    lines: dict[str, str] = field(default_factory=dict)
    focus: str = ""

    def add(self, sid: str, text: str) -> None:
        t = one_line(text)
        if t and sid not in self.lines:
            self.lines[sid] = t

    def ordered(self) -> list[str]:
        own = [s for s in self.lines if s[:1] in PRIORITY]
        rest = [s for s in self.lines if s[:1] not in PRIORITY]
        if self.focus:
            want = _stems(self.focus, "en")
            score = {s: len(_stems(self.lines[s], "en") & want) for s in rest}
            rest = [s for _, s in sorted(enumerate(rest), key=lambda p: (-score[p[1]], p[0]))]
        return own + rest

    def block(self, max_tokens: int = SOURCES_TOKENS) -> str:
        out, used = [], 0
        for sid in self.ordered():
            ln = f"[{sid}] {self.lines[sid]}"
            n = est_tokens(ln) + 1
            if used + n > max_tokens:
                continue                    # a long line that does not fit leaves room for shorter ones after it
            out.append(ln)
            used += n
        return "\n".join(out) if out else "(none)"

    def offered(self, max_tokens: int = SOURCES_TOKENS) -> set[str]:
        """The ids `block` sends (a cite of an id the model never saw is not a source)."""
        return {ln[1:].split("]", 1)[0] for ln in self.block(max_tokens).splitlines() if ln.startswith("[")}

    def add_earlier_answers(self, reviews: dict, session: str, focus: str = "", limit: int = MAX_EARLIER_ANSWERS) -> int:
        """His own strong or fine answers in OTHER calls (the state's review records, `answer_text`), as `a###` sources: the
        most similar to `focus` first. A read card is not his answer and is left out. Returns how many were added."""
        cands = []
        for sess, rv in sorted((reviews or {}).items(), key=lambda kv: (kv[1].get("date", ""), kv[0])):
            if sess == session:
                continue
            for rec in rv.get("records", []):
                text = one_line(rec.get("answer_text", ""))
                if rec.get("spoken") in ("strong", "ok") and text and rec.get("evidence") != "read":
                    cands.append((rec.get("spoken") == "strong", one_line(rec.get("question", "")), text))
        want = _stems(focus, "en") if focus else set()
        cands.sort(key=lambda c: (-len(_stems(f"{c[1]} {c[2]}", "en") & want), not c[0]))
        n = 0
        for _, q, text in cands[:limit]:
            n += 1
            self.add(f"a{n:03d}", f"{q}: {text}" if q else text)
        return n

    @classmethod
    def build(cls, me_texts: list[str], store=None) -> "SourceBook":
        book = cls()
        if store is not None:
            for i, c in enumerate(store.corrections, start=1):
                book.add(f"k{i:03d}", c)
            for i, ln in enumerate(store.owner_lines, start=1):
                m = _BULLET.match(ln)
                book.add(f"o{i:03d}", m.group(1) if m else ln)
        n = 0
        for text in me_texts:
            text = re.sub(r"\A---\n.*?\n---\n", "", text, flags=re.S)        # frontmatter is not a note
            for ln in text.splitlines():
                m = _ME_LINE.match(ln)
                if m:
                    book.add(m.group(1), me_line_text(m.group(2)))
                    continue
                s = ln.strip()
                if not s or s.startswith(_NOTE_SKIP):
                    continue
                b = _BULLET.match(ln)
                body = b.group(1) if b else s           # his notes are plain lines or bullets
                if len(body) >= MIN_NOTE_CHARS:
                    n += 1
                    book.add(f"n{n:03d}", body)
        if store is None:
            return book
        for e in store.live(*BETTER_KINDS):
            if e.get("edited") or e["kind"] == "adopted":
                f = store.fields(e)
                book.add(e["id"], f"{f.get('question', '')}: {f.get('text', '')}")
        for e in store.entries(*LEARNED_KINDS, statuses=("live",)):
            evs = e.get("evidence") or []
            if e.get("edited"):
                book.add(e["id"], store.fields(e)["text"])
            elif any(ev.get("evidence") == "own" for ev in evs):
                q = next((ev.get("quote", "") for ev in evs if ev.get("evidence") == "own"), "")
                book.add(e["id"], f"{store.fields(e)['text']} (\"{one_line(q)}\")")
        for e in store.entries(*SEED_KINDS, statuses=("live", "superseded")):
            if e.get("superseded") and not e["superseded"].get("mark"):
                continue                    # a BAD mark takes the seed's card out of the bank, not its facts out of the sources
            f = store.fields(e)
            d = e.get("data") or {}
            if e["kind"] == "seed_bank":
                pts = " ".join(str(p) for p in d.get("points", []) if isinstance(p, str))
                book.add(e["id"], f"{f.get('question', '')}: {f.get('opener', '')} {pts}")
            elif e["kind"] == "seed_fact":
                book.add(e["id"], f"{f.get('text', '')} {f.get('value', '')}")
            elif e["kind"] == "seed_glossary":
                book.add(e["id"], f"{f.get('term', '')}: {f.get('line', '')}")
            else:
                book.add(e["id"], f.get("text", ""))
        return book


# ---------------------------------------------------------------- pairs
@dataclass
class Pair:
    id: str
    question_rows: list[PRow] = field(default_factory=list)
    answer_rows: list[PRow] = field(default_factory=list)
    cards: list[CardRec] = field(default_factory=list)
    mark: Mark | None = None
    hint: str = ""                 # the question a mark carries, for a pair with no question rows
    uncertain: bool = False        # unlabelled room rows followed the question: his answer may be among them
    tail: int = 0                  # their statements since the last question row, before he answered

    @property
    def turns(self) -> set[str]:
        return {r.turn_id for r in self.question_rows}

    @property
    def question_text(self) -> str:
        """The question as one clean line: its rows merged (`merge_rows`) without filler words; the mark's question without rows."""
        return strip_filler(merge_rows([r.text for r in self.question_rows])) or self.hint

    @property
    def answer_text(self) -> str:
        """His answer as one line: the rows merged (`merge_rows`), so a rolling transcript's repeats are counted once."""
        return merge_rows([r.text for r in self.answer_rows])

    def own_words(self) -> int:
        """His words so far that are not acknowledgements ("yes", "exactly"), rolling rows merged."""
        return len(merge_rows([r.text for r in self.answer_rows if not is_backchannel(r.text)]).split())

    @property
    def answered(self) -> bool:
        """He has started a real answer (ANSWER_MIN_WORDS of his own words): their statements no longer extend the question."""
        return self.own_words() >= ANSWER_MIN_WORDS

    @property
    def q_stamp(self) -> str:
        return self.question_rows[0].stamp if self.question_rows else ""

    @property
    def a_stamps(self) -> list[str]:
        return list(dict.fromkeys(r.stamp for r in self.answer_rows))

    @property
    def card(self) -> CardRec | None:
        """The card the mark names; with no mark, the last card of the question. A mark on the bank's opener (`P-<turn>`) whose
        bank entry is not known names no card: another call's text was not what he marked."""
        if self.mark is not None:
            hit = next((c for c in reversed(self.cards) if c.id == self.mark.card), None)
            if hit is not None:
                return hit
            if self.mark.card.startswith(BANK_CARD_PREFIX):
                return None
        return self.cards[-1] if self.cards else None

    @property
    def evidence(self) -> str:
        evs = {r.evidence for r in self.answer_rows}
        return "read" if "read" in evs else "mixed" if "mixed" in evs else "own" if evs else ""

    @property
    def lang(self) -> str:
        langs = [r.lang for r in self.answer_rows] or [r.lang for r in self.question_rows] or ["en"]
        return max(set(langs), key=langs.count)


BANK_CARD_PREFIX = "P-"      # a mark on a card that showed only the bank's opener (the app's `CardMarks.cardID`)


def bank_card(mark_card: str, turn: str, srows: SessionRows) -> CardRec | None:
    """The card a `P-<turn>` mark names: the opener and points of the bank entry that stood on that turn (`bank_hits`, from the
    session's own bank.jsonl). None when the entry is not known."""
    rec = srows.bank.get(srows.bank_hits.get(turn, ""))
    if rec is None:
        return None
    opener = one_line(str(rec.get("opener") or ""))
    points = tuple(one_line(str(p)) for p in rec.get("points") or [] if isinstance(p, str) and p.strip())
    if not opener and not points:
        return None
    return CardRec(mark_card, turn, " ".join([opener, *points]).strip(), opener, points)


FILLER = frozenset("""um uh uhm erm er ah eh hmm mm so and but okay ok yeah right well then now alright cool great like
e allora quindi ma ecco cioè vabbè dunque beh şey yani ve ama tamam peki işte""".split())
def strip_filler(text: str) -> str:
    """The text without leading filler words ("um so and uh what ...") and without "um" / "uh" anywhere."""
    words = [w for w in text.split() if _wkey(w) not in ("um", "uh", "uhm", "erm", "er", "hmm", "mm")]
    while words and _wkey(words[0]) in FILLER:
        words.pop(0)
    return " ".join(words)


# A question or request to him: a row that ends with "?", opens with a question word (or an auxiliary verb followed by its
# subject: "can you", "is there"; "is not the best fit" is no question), or asks him anywhere ("tell me", "I want to understand").
_WH = frozenset("""what what's whats how how's why when where which who whom whose
come cosa cos che perché perche quando dove quale quali quanto quanta quanti quante chi
ne neden niye niçin nasıl nerede nereden nereye hangi kim kaç""".split())
_AUX = frozenset("""do does did are is was were have has had can could would will should shall may might
hai sei puoi potresti può vuoi avete siete""".split())
_SUBJECT = frozenset("""you your yourself u it there that this these those we they he she i anyone anything someone the a an
tu ti te voi lei ci vi""".split())
_ASK_START = frozenset("""tell walk describe explain share give talk show introduce elaborate expand
raccontami raccontaci parlami parlaci dimmi descrivi spiegami spiegaci anlat anlatır anlatabilir""".split())
_ASK_ANY = re.compile(
    r"\b(?:tell me|tell us|walk me|walk us|can you|could you|would you|do you|did you|have you|are you|were you|will you|"
    r"what's your|what is your|how do you|how did you|how would you|why did you|why do you|i want to understand|"
    r"i want to know|i'd like to know|i would like to know|i'd love to hear|i'm curious|i am curious|"
    r"mi racconti|ci racconti|mi puoi|puoi dirmi|vorrei sapere|vorrei capire|come mai|"
    r"anlatır mısın|anlatabilir misin|söyler misin|bahseder misin)\b", re.I)
_TR_PARTICLE = re.compile(r"\b(?:mı|mi|mu|mü)(?:sın|sin|sun|sün|yız|yiz|sınız|siniz|sunuz|sünüz)?\b", re.I)


def asks(text: str, lang: str = "en") -> bool:
    """The row asks him something (see the patterns above); the transcript's own `kind` is not enough on its own: live
    classification marks half-sentences of a monologue as questions."""
    if text.rstrip().endswith("?"):
        return True
    words = [k for k in (_wkey(w) for w in strip_filler(text).split()) if k]
    if words and (words[0] in _WH or words[0] in _ASK_START
                  or (words[0] in _AUX and len(words) > 1 and words[1] in _SUBJECT)):
        return True
    flat = " ".join(text.split())
    return bool(_ASK_ANY.search(flat) or (lang == "tr" and _TR_PARTICLE.search(flat)))


def is_question(r: PRow) -> bool:
    return r.role != "me" and asks(r.text, r.lang)


def build_pairs(srows: SessionRows, upto: int | None = None, max_pairs: int = MAX_PAIRS) -> list[Pair]:
    """The question -> answer pairs of the rows sent (`upto`: rows past it were cut from the request), their cards and marks.

    A pair is a question or request of the other side (`is_question`) and his rows after it. Questions in a row (with at most
    an interjection of his between them, under REPLY_MIN_WORDS words), and the other side's statements before he has really
    started (`Pair.answered`), are one question split across rows. Their
    acknowledgements ("yeah", "okay okay") never end anything, so his answer runs across them; their first real statement after
    he answered ends it, and so does their next question. A question they talk past (more than QUESTION_TAIL statements and no
    answer) lapses. Statements alone are never a pair, and neither is a question he only acknowledged ("yeah", "exactly")."""
    rows = srows.rows if upto is None else srows.rows[:max(0, upto)]
    pairs: list[Pair] = []
    cur: Pair | None = None
    for r in rows:
        if r.role == "me":
            if cur is not None:
                cur.answer_rows.append(r)
            continue
        if is_question(r):
            if cur is None or cur.own_words() >= REPLY_MIN_WORDS:
                cur = Pair(f"q{len(pairs) + 1}")
                pairs.append(cur)
            cur.question_rows.append(r)
            cur.tail = 0
        elif cur is not None and not is_backchannel(r.text):
            if cur.answered:
                cur = None                           # their statement after his answer: the answer is over
            elif r.role == "room":
                cur.uncertain = True
            elif cur.tail >= QUESTION_TAIL:
                cur = None                           # they talked on and he never answered: the question lapsed
            else:
                cur.question_rows.append(r)          # the question goes on before he answers
                cur.tail += 1
    by_turn: dict[str, list[CardRec]] = {}
    by_id: dict[str, CardRec] = {}
    for c in srows.card_records:
        by_turn.setdefault(c.turn, []).append(c)
        if c.id:
            by_id[c.id] = c
    for p in pairs:
        for t in sorted(p.turns):
            p.cards += by_turn.get(t, [])
    orphans: list[Pair] = []
    marks = sorted(final_marks(srows.marks).values(), key=lambda m: m.t)
    for m in marks:
        if m.card.startswith(BANK_CARD_PREFIX) and m.card not in by_id:
            c = bank_card(m.card, m.turn or m.card[len(BANK_CARD_PREFIX):], srows)
            if c is not None:
                by_id[m.card] = c
    for m in marks:
        turn = m.turn or (by_id[m.card].turn if m.card in by_id else "")
        p = next((x for x in pairs if turn and turn in x.turns), None)
        if p is None:
            p = Pair("", hint=m.question, cards=[by_id[m.card]] if m.card in by_id else [])
            orphans.append(p)
        elif m.card in by_id and by_id[m.card] not in p.cards:
            p.cards.append(by_id[m.card])
        if p.mark is None or m.t >= p.mark.t:
            p.mark = m
    for i, p in enumerate(orphans, start=1):
        p.id = f"m{i}"
    keep = [p for p in pairs + orphans if p.mark is not None
            or (p.question_rows and any(not is_backchannel(r.text) for r in p.answer_rows))]
    marked = [p for p in keep if p.mark is not None]
    rest = [p for p in keep if p.mark is None][:max(0, max_pairs - len(marked))]
    chosen = {id(p) for p in marked + rest}
    out = [p for p in keep if id(p) in chosen]
    for i, p in enumerate((p for p in out if p.id.startswith("q")), start=1):
        p.id = f"q{i}"                               # the pairs sent, numbered in order
    return out


def _card_say(c: CardRec | None) -> str:
    """The SAY line of a card; a card with none (a D card whose first line replaced the opener) opens with its first point."""
    if c is None:
        return ""
    return c.say or (c.points[0] if c.points else c.text)


def _card_points(c: CardRec | None) -> list[str]:
    if c is None:
        return []
    return list(c.points) if c.say or not c.points else list(c.points[1:])


def _q(s: str) -> str:
    return one_line(s).replace('"', "'")


def _clip(s: str, n: int) -> str:
    s = one_line(s)
    return s if len(s) <= n else s[:n].rstrip() + "…"


def review_blocks(key: str, pairs: list[Pair], book: SourceBook, sources_tokens: int = SOURCES_TOKENS) -> tuple[str, str]:
    """(system addendum, user addendum) for the request; ("", "") when there is nothing to review."""
    if not pairs:
        return "", ""

    def span(stamps: list[str]) -> str:
        if len(stamps) <= 3:
            return ", ".join(f"[{key} {s}]" for s in stamps)
        return f"[{key} {stamps[0]}] to [{key} {stamps[-1]}] ({len(stamps)} rows)"

    lines = []
    for p in pairs:
        qs = list(dict.fromkeys(r.stamp for r in p.question_rows))
        q = f"question {span(qs)}" if p.question_rows else f"question (from his mark): \"{_q(p.hint) or '?'}\""
        a = f"answer {span(p.a_stamps)}" if p.answer_rows else "answer: none"
        c = p.card
        card = f"card {c.id or '?'}: \"{_q(_clip(c.text, CARD_CHARS))}\"" if c else "card: none"
        lines.append(f"{p.id} | {q} | {a} | {card} | mark: {p.mark.mark.upper() if p.mark else 'none'}")
    return REVIEW_SYSTEM, f"CONFIRMED SOURCES\n{book.block(sources_tokens)}\n\nQUESTION PAIRS\n" + "\n".join(lines)


def estimate(pairs: list[Pair], system_add: str, user_add: str) -> dict:
    """The review's share of one request, for the dry run: extra input tokens, projected output tokens, and their cost."""
    extra_in = (est_tokens(system_add) if system_add else 0) + (est_tokens(user_add) + 1 if user_add else 0)
    weak = math.ceil(len(pairs) * EST_WEAK_SHARE) + sum(1 for p in pairs if p.mark and p.mark.mark == "bad")
    est_out = len(pairs) * EST_OUT_PER_PAIR + min(len(pairs), weak) * EST_OUT_PER_IMPROVED if pairs else 0
    pin, pout, _ = PRICES[SONNET]
    return {"pairs": len(pairs), "marked": sum(1 for p in pairs if p.mark), "extra_input_tokens": extra_in,
            "est_output_tokens": est_out, "extra_cost_usd": round((extra_in * pin + est_out * pout) / 1e6, 4)}


# ---------------------------------------------------------------- parsing
@dataclass
class RawReview:
    pair: str
    topic: str = ""
    question: str = ""
    verdict: str = ""              # strong | fine | weak ("" when missing or not one of them)
    reason: str = ""               # a weak answer's reason: missed_question | nothing_specific | contradicts_source | trailed_off
    contradicts: str = ""
    note: str = ""                 # the model's "why"
    improved: list[tuple[str, list[str]]] = field(default_factory=list)
    wording: str = ""
    improved_en: list[str] = field(default_factory=list)    # each improved line in English ("" when the model gave none)


def _s(v: object, cap: int) -> str:
    return " ".join(v.split())[:cap] if isinstance(v, str) else ""


def parse_reviews(text: str) -> list[RawReview]:
    """The `reviews` of the model's answer ([] when there are none or they cannot be read). A verdict or reason outside its
    values is read as "" (missing); `verify_reviews` drops a review with neither a verdict nor an improved answer."""
    obj = json_object(text)
    revs = obj.get("reviews") if isinstance(obj, dict) else None
    if not isinstance(revs, list):
        return []
    out = []
    for r in revs[:MAX_PAIRS + 10]:
        if not isinstance(r, dict) or not _s(r.get("pair"), 12):
            continue
        enum = lambda k, vals: (lambda v: v if v in vals else "")(_s(r.get(k), 20).casefold())  # noqa: E731
        imp: list[tuple[str, list[str]]] = []
        imp_en: list[str] = []
        lines = (r.get("improved") or {}).get("lines") if isinstance(r.get("improved"), dict) else None
        if isinstance(lines, list):
            for ln in lines[:MAX_IMPROVED_LINES + 2]:
                if isinstance(ln, dict):
                    src = [x.strip() for x in ln.get("src") or [] if isinstance(x, str) and x.strip()][:6]
                    imp.append((_s(ln.get("text"), MAX_LINE_CHARS + 50), src))
                    imp_en.append(_s(ln.get("en"), MAX_LINE_CHARS + 50))
        out.append(RawReview(pair=_s(r.get("pair"), 12), topic=_s(r.get("topic"), 80), question=_s(r.get("question"), 200),
                             verdict=enum("verdict", VERDICTS), reason=enum("reason", tuple(WEAK_REASONS)),
                             contradicts=_s(r.get("contradicts"), 12), note=_s(r.get("why") or r.get("note"), 160),
                             improved=imp, wording=_s(r.get("wording"), MAX_WORDING_CHARS + 200), improved_en=imp_en))
    return out


# ---------------------------------------------------------------- decisions (pure)
def spoken_verdict(has_answer: bool, reviewed: bool, verdict: str, reason: str, contradiction_ok: bool) -> tuple[str, list[str]]:
    """(none | weak | strong | ok | unreviewed, reasons) of his spoken answer: the model's one verdict, its one reason the only
    label. A weak verdict needs one of the four reasons (WEAK_REASONS), and a contradiction needs code's check
    (`contradiction_ok`); without them it is not weak but fine (the verdict never disagrees with its reason). A pair the model
    did not review (not a real question) is never weak."""
    if not has_answer:
        return "none", []
    if not reviewed or not verdict:
        return "unreviewed", []
    if verdict == "weak":
        code = WEAK_REASONS.get(reason)
        if code is None or (code == "contradiction" and not contradiction_ok):
            return "ok", []
        return "weak", [code]
    return ("strong" if verdict == "strong" else "ok"), []


def choose_action(spoken: str, mark: str, rejected: bool, has_card: bool) -> str:
    """kept | adopted | improve | rejected | none. The owner's GOOD mark keeps the card; his own strong wording beats the card;
    a weak answer or a BAD mark asks for a rewrite, unless he rejected a rewrite of that question before."""
    if mark == "good" and has_card:
        return "kept"
    if spoken == "strong":
        return "adopted"
    if spoken == "weak" or mark == "bad":
        return "rejected" if rejected else "improve"
    return "none"


def _stems(text: str, lang: str) -> set[str]:
    return set(content_stems(text, lang))


def _missing_names(text: str, source: str, lang: str) -> set[str]:
    """Names of `text` its source does not say (extract.py `names_not_in_row`). In Italian and Turkish a sentence's first word is
    not checked: the English sentence-opener list does not cover them, and a verb there ("Ho", "Sono") is no name."""
    if lang == "en":
        return names_not_in_row(text, source)
    have = {w for w in re.findall(r"[\w'’-]+", source.casefold())} | {w.split("'", 1)[0] for w in re.findall(r"[\w'’-]+", source.casefold())}
    return {k for k, initial in name_tokens(text) if not initial and k not in have} | (months_in(text) - months_in(source))


# Number words an improved line may state. A line's number word needs its value among its sources' numbers, or the word itself
# in them ("one", "uno", "bir" are left out: they are articles and pronouns far more often than counts).
NUMBER_WORDS: dict[str, dict[str, tuple[float, ...]]] = {
    "en": {"two": (2,), "three": (3,), "four": (4,), "five": (5,), "six": (6,), "seven": (7,), "eight": (8,), "nine": (9,),
           "ten": (10,), "eleven": (11,), "twelve": (12,), "twenty": (20,), "thirty": (30,), "forty": (40,), "fifty": (50,),
           "hundred": (100,), "thousand": (1000,), "million": (1e6,), "dozen": (12,), "half": (0.5, 50), "twice": (2,),
           "double": (2,), "doubled": (2,), "triple": (3,), "tripled": (3,), "quarter": (0.25, 25)},
    "it": {"due": (2,), "tre": (3,), "quattro": (4,), "cinque": (5,), "sei": (6,), "sette": (7,), "otto": (8,), "nove": (9,),
           "dieci": (10,), "undici": (11,), "dodici": (12,), "venti": (20,), "trenta": (30,), "quaranta": (40,),
           "cinquanta": (50,), "cento": (100,), "mille": (1000,), "mila": (1000,), "milione": (1e6,), "milioni": (1e6,),
           "metà": (0.5, 50), "doppio": (2,), "raddoppiato": (2,), "raddoppiata": (2,), "triplicato": (3,), "quarto": (0.25, 25)},
    "tr": {"iki": (2,), "üç": (3,), "dört": (4,), "beş": (5,), "altı": (6,), "yedi": (7,), "sekiz": (8,), "dokuz": (9,),
           "on": (10,), "yirmi": (20,), "otuz": (30,), "kırk": (40,), "elli": (50,), "yüz": (100,), "bin": (1000,), "milyon": (1e6,), "yarı": (0.5, 50),
           "yarısı": (0.5, 50), "yarıya": (0.5, 50), "katı": (2,)},
}


def number_words(text: str, lang: str) -> dict[str, tuple[float, ...]]:
    """The number words of `text` in `lang` (NUMBER_WORDS), word -> the values it may stand for."""
    table = NUMBER_WORDS.get(lang, {})
    return {w: table[w] for w in re.findall(r"[\w']+", text.casefold()) if w in table}


def numbers_grounded(text: str, source: str, lang: str) -> bool:
    """Every number of `text` (single digits too) and every number word is in `source`: its value among the source's numbers,
    or, for a word, the word itself."""
    have = numbers_in(source, lang) | numbers_in(source)
    if not all(any(abs(n - h) < 1e-9 for h in have) for n in numbers_in(text, lang)):
        return False
    words = set(re.findall(r"[\w']+", source.casefold()))
    return all(w in words or any(abs(v - h) < 1e-9 for v in vals for h in have) for w, vals in number_words(text, lang).items())


def ground_lines(lines: list[tuple[str, list[str]]], book: SourceBook, lang: str, offered: set[str] | None = None,
                 glosses: list[str] | None = None) -> str:
    """"" when every line of an improved answer traces to the confirmed sources it cites, else why not: improved_empty (no
    lines, an empty line, a line too long, too many lines), improved_source (a line cites nothing, or an id that is not a
    confirmed source the model was shown), improved_number (a number its sources do not have: any number, single digits
    included, and number words such as "three" or "half"), improved_name (a name or month they do not have), improved_ungrounded
    (a line whose content words are mostly not in its sources: under GROUND_MIN_SHARE of them, or fewer than GROUND_MIN_SHARED).
    Lines in Italian or Turkish resting on English sources cannot be compared word by word: such a line needs its English gloss
    (`glosses`, the model's `en`), and the gloss takes the English content test while the line and the gloss both take the number
    and name checks. A non-English line without a gloss is improved_ungrounded."""
    if not lines or len(lines) > MAX_IMPROVED_LINES:
        return "improved_empty"
    known = offered if offered is not None else set(book.lines)
    for i, (text, src) in enumerate(lines):
        if not text or len(text) > MAX_LINE_CHARS:
            return "improved_empty"
        if not src or any(s not in book.lines or s not in known for s in src):
            return "improved_source"
        srct = " ".join(book.lines[s] for s in src)
        gloss = text if lang == "en" else (glosses[i] if glosses and i < len(glosses) else "")
        if not numbers_grounded(text, srct, lang) or (gloss and not numbers_grounded(gloss, srct, "en")):
            return "improved_number"
        if _missing_names(text, srct, lang) or (gloss and _missing_names(gloss, srct, "en")):
            return "improved_name"
        if not gloss or len(gloss) > MAX_LINE_CHARS:
            return "improved_ungrounded"
        mine = _stems(gloss, "en")
        shared = mine & _stems(srct, "en")
        if mine and (len(shared) < min(GROUND_MIN_SHARED, len(mine)) or len(shared) / len(mine) < GROUND_MIN_SHARE):
            return "improved_ungrounded"
    return ""


_SENT = re.compile(r"(?<=[.!?])\s+")


def sentences(text: str) -> list[str]:
    return [s.strip() for s in _SENT.split(one_line(text)) if s.strip()]


def verbatim(answer: str, max_chars: int = MAX_WORDING_CHARS) -> str:
    """His answer rows, cut at a whole sentence to `max_chars` (at least the first sentence, itself cut at a word)."""
    out = ""
    for s in sentences(answer):
        if out and len(out) + 1 + len(s) > max_chars:
            break
        out = f"{out} {s}".strip()
    if len(out) > max_chars:
        out = out[:max_chars].rsplit(" ", 1)[0]
    return out


def wording_ok(wording: str, answer: str, lang: str) -> bool:
    """The model's tightening of his answer is his: at most 3 sentences, numbers and names all his, and at least
    WORDING_MIN_SHARE of its content words from his answer rows."""
    if not wording or len(wording) > MAX_WORDING_CHARS or len(sentences(wording)) > 3:
        return False
    have = numbers_in(answer, lang)
    if not all(any(abs(n - h) < 1e-9 for h in have) for n in significant_numbers(wording, lang)):
        return False
    if names_not_in_row(wording, answer):
        return False
    mine = _stems(wording, lang)
    return bool(mine) and len(mine & _stems(answer, lang)) / len(mine) >= WORDING_MIN_SHARE


# ---------------------------------------------------------------- the review of one session
@dataclass
class PairReview:
    pair: str
    topic: str
    question: str
    paraphrases: list[str]
    q_stamp: str
    a_stamps: list[str]
    lang: str
    reviewed: bool = False
    answered: str = ""
    specific: str = ""
    length: str = ""
    contradicts: str = ""
    note: str = ""
    mark: str = ""
    mark_t: float = 0.0
    card: str = ""
    card_say: str = ""
    card_points: list[str] = field(default_factory=list)
    spoken: str = "unreviewed"
    reasons: list[str] = field(default_factory=list)
    action: str = "none"           # kept | adopted | improved | no_better | rejected | not_banked | none
    why: str = ""                  # why a better answer was not banked
    lines: list[tuple[str, list[str]]] = field(default_factory=list)   # the grounded improved answer
    wording: str = ""              # his words (adopted)
    answer_quote: str = ""
    answer_text: str = ""          # his answer, rows merged, up to EARLIER_ANSWER_CHARS (a source for later calls when not weak)
    evidence: str = ""             # own | mixed | read: his answer rows (rows.py)
    bank_origin: str = ""          # the bank entry the marked card came from (a BAD mark demotes it)
    bank_question: str = ""

    @property
    def needs_rewrite(self) -> bool:
        return self.spoken == "weak" or self.mark == "bad"


@dataclass
class Review:
    pairs: list[PairReview]
    dropped: dict[str, int]

    @property
    def weak_stamps(self) -> set[str]:
        return {s for p in self.pairs if p.spoken == "weak" for s in p.a_stamps}

    def counts(self) -> dict:
        c = {"pairs": len(self.pairs), "reviewed": sum(1 for p in self.pairs if p.reviewed),
             "weak": sum(1 for p in self.pairs if p.spoken == "weak"), "strong": sum(1 for p in self.pairs if p.spoken == "strong"),
             "fine": sum(1 for p in self.pairs if p.spoken == "ok"), "marks": sum(1 for p in self.pairs if p.mark)}
        for a in ("improved", "adopted", "kept", "no_better", "rejected", "not_banked"):
            c[a] = sum(1 for p in self.pairs if p.action == a)
        return c


def _topic_of(question: str) -> str:
    words = [w for w in re.findall(r"[\w'’-]+", question) if content_words(w)]
    return " ".join(words[:6]) or _clip(question, 60)


def card_confirmed(text: str, lang: str, confirmed: Confirmed) -> bool:
    """A card the owner marked GOOD may enter the bank: every number of it is confirmed, and every name inside a sentence (a
    sentence's first word is mostly an ordinary verb on a card: "Mention ...", "Ship ...") and every month."""
    if not confirmed.has_numbers(text, lang):
        return False
    names = {k for k, initial in name_tokens(text) if not initial} | months_in(text)
    return all(n in confirmed._words for n in names)


def verify_reviews(raw: list[RawReview], pairs: list[Pair], book: SourceBook, srows: SessionRows, confirmed: Confirmed,
                   is_rejected=lambda q, t, paras: False, offered: set[str] | None = None) -> Review:
    dropped = {"review_pair": 0, "review_empty": 0, "contradiction": 0, "weak_reason": 0, "improved_empty": 0,
               "improved_source": 0, "improved_number": 0, "improved_name": 0, "improved_ungrounded": 0, "wording": 0,
               "kept_unconfirmed": 0, "adopted_unconfirmed": 0, "adopted_read": 0}
    by_id = {p.id: p for p in pairs}
    raws: dict[str, RawReview] = {}
    for r in raw:
        if r.pair not in by_id:
            dropped["review_pair"] += 1
            continue
        if not (r.verdict or r.improved):
            dropped["review_empty"] += 1
            continue
        raws.setdefault(r.pair, r)
    cards = CardFacts.of(srows.cards)
    out: list[PairReview] = []
    for p in pairs:
        r = raws.get(p.id)
        lang = p.lang
        has_answer = bool(p.answer_rows)
        question = (r.question if r and r.question else "") or _clip(p.question_text, 200)
        paras = [x for x in [_clip(p.question_text, 200)] if x and x.casefold() != question.casefold()]
        topic = (r.topic if r and r.topic else "") or _topic_of(question)
        c = p.card
        pr = PairReview(p.id, topic, question, paras, p.q_stamp, p.a_stamps, lang, reviewed=r is not None,
                        mark=p.mark.mark if p.mark else "", mark_t=p.mark.t if p.mark else 0.0, card=c.id if c else "",
                        card_say=_card_say(c), card_points=_card_points(c),
                        answer_quote=_clip(p.answer_text, 200), note=r.note if r else "",
                        answer_text=_clip(p.answer_text, EARLIER_ANSWER_CHARS), evidence=p.evidence)
        verdict, reason = (r.verdict, r.reason) if r else ("", "")
        if r and r.contradicts:
            src = book.lines.get(r.contradicts)
            if src and has_answer and reason == "contradicts_source" and _differs(p.answer_text, src):
                pr.contradicts = r.contradicts
            else:
                dropped["contradiction"] += 1
        pr.spoken, pr.reasons = spoken_verdict(has_answer, r is not None, verdict, reason, bool(pr.contradicts))
        if verdict == "weak" and pr.spoken != "weak" and reason != "contradicts_source":
            dropped["weak_reason"] += 1               # a weak verdict without one of the four reasons: fine
        # the labels follow the one verdict (kept in the record for the note and for older readers)
        judged = pr.spoken in ("weak", "ok", "strong")
        pr.answered = "no" if not has_answer or "not_answered" in pr.reasons else "yes" if judged else ""
        pr.specific = "vague" if "vague" in pr.reasons else "specific" if pr.spoken == "strong" else ""
        pr.length = "trailed_off" if "trailed_off" in pr.reasons else "ok" if judged else ""
        if pr.mark == "bad" and c is not None:
            hit = next((srows.bank_hits[t] for t in sorted(p.turns) if t in srows.bank_hits), "")
            rec = srows.bank.get(hit) if hit else None
            if rec is not None:
                pr.bank_origin, pr.bank_question = str(rec.get("origin") or ""), one_line(rec.get("question", ""))
        action = choose_action(pr.spoken, pr.mark, is_rejected(question, topic, paras), c is not None)
        if action == "kept":
            text = " ".join([pr.card_say, *pr.card_points])
            if card_confirmed(text, lang, Confirmed(confirmed.texts + [p.answer_text])):
                pr.action = "kept"
            else:
                pr.action, pr.why = "not_banked", "the card states a figure or a name no confirmed source has"
                dropped["kept_unconfirmed"] += 1
        elif action == "adopted" and p.evidence == "read":
            pr.why = "he read the card aloud: the card's wording, not his"
            dropped["adopted_read"] += 1
        elif action == "adopted":
            w = r.wording if r else ""
            if w and not wording_ok(w, p.answer_text, lang):
                dropped["wording"] += 1
                w = ""
            w = w or verbatim(p.answer_text)
            if cards.unconfirmed(w, lang, confirmed):
                pr.action, pr.why = "not_banked", "his answer carries a card's figure or name that no confirmed source has"
                dropped["adopted_unconfirmed"] += 1
            else:
                pr.action, pr.wording = "adopted", w
        elif action == "improve":
            lines = r.improved if r else []
            if not lines:
                pr.action, pr.why = "no_better", "the confirmed sources do not answer it"
            else:
                why = ground_lines(lines, book, lang, offered, r.improved_en if r else None)
                if why:
                    dropped[why] += 1
                    pr.action, pr.why = "no_better", "the rewrite did not trace to confirmed sources"
                else:
                    pr.action, pr.lines = "improved", lines
        elif action == "rejected":
            pr.action, pr.why = "rejected", "a better answer to this question was rejected before"
        out.append(pr)
    rv = Review(out, dropped)
    log.info("persona review: %s dropped=%s", rv.counts(), {k: v for k, v in dropped.items() if v})
    return rv


# ---------------------------------------------------------------- after the call
def apply_review(store, rv: Review, *, session: str, skey: str, day: str, book: SourceBook) -> dict:
    """The better answers into the persona and the session's review into the state. Call inside `store.locked()`."""
    made = {"improved": [], "adopted": [], "kept": [], "demoted": []}
    records = []
    for p in rv.pairs:
        iid = None
        stamp = p.q_stamp or (p.a_stamps[0] if p.a_stamps else "")
        common = dict(question=p.question, paraphrases=p.paraphrases, topic=p.topic, lang=p.lang, session=session, skey=skey,
                      stamp=stamp, day=day, card=p.card if p.action == "kept" else "", reasons=p.reasons)
        if p.action == "improved":
            texts = [t for t, _ in p.lines]
            src_ids = list(dict.fromkeys(s for _, ss in p.lines for s in ss))
            iid = store.add_better("improved", opener=texts[0], points=texts[1:],
                                   sources=[{"id": s, "text": book.lines.get(s, "")} for s in src_ids], **common)
        elif p.action == "adopted":
            ss = sentences(p.wording) or [p.wording]
            iid = store.add_better("adopted", opener=ss[0], points=ss[1:3],
                                   sources=[{"id": f"{skey} {s}", "text": p.wording} for s in p.a_stamps[:1]], **common)
        elif p.action == "kept":
            iid = store.add_better("kept", opener=p.card_say, points=p.card_points,
                                   sources=[{"id": f"card {p.card}", "text": " ".join([p.card_say, *p.card_points])}], **common)
        if iid and p.action in made:
            made[p.action].append(iid)
        if p.mark == "bad" and (p.bank_origin or p.bank_question):
            gone = store.demote(p.bank_origin, p.bank_question, day, by=iid or "", card=p.card)
            if gone:
                made["demoted"].append(gone)
        records.append({"pair": p.pair, "topic": p.topic, "question": p.question, "q_stamp": p.q_stamp, "a_stamps": p.a_stamps,
                        "spoken": p.spoken, "reasons": p.reasons, "needs_rewrite": p.needs_rewrite, "mark": p.mark,
                        "mark_t": p.mark_t, "card": p.card, "action": p.action, "why": p.why, "better": iid or "",
                        "contradicts": p.contradicts, "note": p.note, "answered": p.answered, "specific": p.specific,
                        "length": p.length, "answer_quote": p.answer_quote, "answer_text": p.answer_text,
                        "evidence": p.evidence, "date": day})
    store.state.setdefault("reviews", {})[session] = {"date": day, "skey": skey, "version": REVIEW_VERSION, "records": records,
                                                      "counts": rv.counts()}
    return made


def recurring_weak(reviews: dict, min_sessions: int = 2) -> list[dict]:
    """Topics whose answer needed a rewrite in at least `min_sessions` calls, most calls first, then the latest first. Two
    reviews share a topic when their topics or their questions overlap (content words, >= TOPIC_OVERLAP)."""
    clusters: list[dict] = []
    for sess, rv in sorted(reviews.items(), key=lambda kv: (kv[1].get("date", ""), kv[0])):
        for rec in rv.get("records", []):
            if not rec.get("needs_rewrite"):
                continue
            tw, qw = content_words(rec.get("topic", "")), content_words(rec.get("question", ""))
            home = next((c for c in clusters if (tw and jaccard(tw, c["tw"]) >= TOPIC_OVERLAP)
                         or (qw and jaccard(qw, c["qw"]) >= TOPIC_OVERLAP)), None)
            if home is None:
                home = {"topic": rec.get("topic", ""), "tw": tw, "qw": qw, "sessions": [], "dates": [], "latest": ""}
                clusters.append(home)
            if sess not in home["sessions"]:
                home["sessions"].append(sess)
                home["dates"].append(rec.get("date", rv.get("date", "")))
            home["latest"] = max(home["latest"], rec.get("date", ""))
            home["topic"] = rec.get("topic") or home["topic"]
    out = [{"topic": c["topic"], "sessions": c["sessions"], "dates": c["dates"], "latest": c["latest"]}
           for c in clusters if len(c["sessions"]) >= min_sessions]
    out.sort(key=lambda c: (len(c["sessions"]), c["latest"]), reverse=True)
    return out


# ---------------------------------------------------------------- the Review note
REASON_TEXT = {"not_answered": "missed the question", "vague": "nothing specific", "trailed_off": "trailed off",
               "contradiction": "contradicts a confirmed source", "bad_mark": "marked BAD",
               # review version 1 reasons, still in older records
               "partly_answered": "partly answered", "rambling": "rambling", "cut_short": "cut short"}


_NOTE_ID = re.compile(r"\[\s*([pgcimakon]\d{3,})\s*\]", re.I)    # an entry or source id in brackets: `[i006]`, `[p001]`
_NOTE_MARKER = re.compile(r"\b(Q|SAY|MORE|FACT|TERM|SNIPPET)\s*:", re.I)   # the answer-line field markers
_NOTE_LIST = re.compile(r"^(?:[-*+>#]+|\d+[.)])(?:\s+|$)")         # a Markdown list marker, quote or heading at the start
_NOTE_REJECT = re.compile(r"^(reject(?:ed)?|rifiut\w*|reddet\w*)\b|\b(reject(?:ed)?|rifiut\w*|reddet\w*)(\W*)$", re.I)


def note_text(s: object) -> str:
    """Text that came from the call or from the model, made safe to stand in the Review note: nothing of it can be read back as
    structure by `PersonaStore._sync_notes` (or by an eye skimming the note). One line (every line break folded), no leading list
    marker, quote or heading, no bracketed entry id (`[i006]` -> `(i006)`), no ` | ` field separator, no `Q:` / `SAY:` / `MORE:`
    marker (`Q -`), and a `reject` at either end quoted. Plain text passes unchanged."""
    t = one_line(s)
    while True:
        m = _NOTE_LIST.match(t)
        if not m or not m.group(0):
            break
        t = t[m.end():].lstrip()
    t = _NOTE_ID.sub(lambda m: f"({m.group(1)})", t)
    t = t.replace("|", "/")
    t = _NOTE_MARKER.sub(lambda m: f"{m.group(1)} -", t)
    t = _NOTE_REJECT.sub(lambda m: f"'{m.group(1)}'" if m.group(1) else f"'{m.group(2)}'{m.group(3)}", t)
    return t


def _clock(t: float) -> str:
    from datetime import datetime

    return datetime.fromtimestamp(t).strftime("%H:%M:%S") if t else ""


def render_note(store, session: str, skey: str, day: str, open_list: list[dict]) -> tuple[str, dict[str, str]]:
    """(the Review note of one session, {better id: its line in the note}). Built from the state's review of the session."""
    rv = store.state.get("reviews", {}).get(session) or {"records": []}
    recs = rv.get("records", [])
    ents = store.state["entries"]
    recurring = recurring_weak(store.state.get("reviews", {}))
    rec_topics = [r for r in recurring if session in r["sessions"]]

    def recurring_here(rec: dict) -> bool:
        tw, qw = content_words(rec.get("topic", "")), content_words(rec.get("question", ""))
        return any(jaccard(tw, content_words(r["topic"])) >= TOPIC_OVERLAP or jaccard(qw, content_words(r["topic"])) >= TOPIC_OVERLAP
                   for r in rec_topics)

    answer_lines: dict[str, str] = {}

    def better_line(iid: str) -> str:
        e = ents.get(iid)
        if not e:
            return ""
        # The owner's own edit stands as he wrote it; Verse's line has its model-made fields cleaned (`note_text`).
        ln = e["edited"].strip() if e.get("edited") else store.render_line(e, clean=note_text)
        answer_lines[iid] = NOTE_ANSWER_INDENT + ln
        return NOTE_ANSWER_INDENT + ln

    out = [f"---\ntitle: Verse review {day} {skey}\ncreated: {day}\ntype: persona-review\ntags:\n  - verse\n  - persona\n---",
           f"# Review {day} `{skey}`", "",
           "Edit an answer line below (or in Persona.md) and Verse keeps your wording. Write `reject` as its last field, or "
           "delete it from Persona.md, and no better answer to that question is written again.", ""]
    out.append("## Weak in more than one call")
    if recurring:
        for r in recurring:
            here = " (this call too)" if session in r["sessions"] else ""
            out.append(f"- {note_text(r['topic'])}: weak in {len(r['sessions'])} calls ({', '.join(r['dates'])}){here}")
    else:
        out.append("- none")
    out += ["", "## Went well"]
    good = [r for r in recs if not r.get("needs_rewrite") and (r.get("spoken") == "strong" or r.get("mark") == "good")]
    for r in good:
        bits = [note_text(r.get("question", ""))]
        if r.get("q_stamp"):
            bits.append(f"[{skey} {r['q_stamp']}]")
        tags = []
        if r.get("mark") == "good":
            tags.append("card marked GOOD")
        if r.get("action") in ("not_banked", "none") and r.get("why"):
            tags.append(f"not banked: {note_text(r.get('why', ''))}")
        out.append("- " + " ".join(bits) + (f" ({'; '.join(tags)})" if tags else ""))
        if r.get("note"):
            out.append(f"  - why: {note_text(r['note'])}")
        if r.get("better"):
            out.append(better_line(r["better"]))
    if not good:
        out.append("- none")
    out += ["", "## Fine"]
    fine = [r for r in recs if not r.get("needs_rewrite") and r.get("spoken") == "ok" and r.get("mark") != "good"]
    for r in fine:
        at = f" [{skey} {r['q_stamp']}]" if r.get("q_stamp") else ""
        out.append(f"- {note_text(r.get('question', ''))}{at}")
    if not fine:
        out.append("- none")
    out += ["", "## Weak answers"]
    weak = sorted((r for r in recs if r.get("needs_rewrite")), key=lambda r: (not recurring_here(r), r.get("q_stamp", "")))
    for r in weak:
        reasons = [REASON_TEXT.get(x) or note_text(x) for x in r.get("reasons", [])]
        if r.get("mark") == "bad":
            reasons.append(REASON_TEXT["bad_mark"])
        at = f" [{skey} {r['q_stamp']}]" if r.get("q_stamp") else ""
        again = " (weak before too)" if recurring_here(r) else ""
        out.append(f"- {note_text(r.get('question', ''))}{at}: {', '.join(reasons) or 'needs a rewrite'}{again}")
        if r.get("note"):
            out.append(f"  - why: {note_text(r['note'])}")
        if r.get("better"):
            out.append(better_line(r["better"]))
        elif r.get("why"):
            out.append(f"  - no better answer: {note_text(r['why'])}")
    if not weak:
        out.append("- none")
    out += ["", "## Marks"]
    marks = sorted((r for r in recs if r.get("mark")), key=lambda r: r.get("mark_t", 0.0))
    for r in marks:
        out.append(f"- {_clock(r.get('mark_t', 0.0))} card {note_text(r.get('card')) or '?'}: {note_text(r['mark']).upper()} | "
                   f"{note_text(r.get('question', ''))}")
    if not marks:
        out.append("- none")
    out += ["", "## Open contradictions"]
    n = 0
    for c in open_list:
        n += 1
        out.append(f"- [{c['id']}] {note_text(c['topic'])}: \"{_q(note_text(c['a'].get('quote', '')))}\" ({c['a'].get('date', '')}) vs "
                   f"\"{_q(note_text(c['b'].get('quote', '')))}\" ({c['b'].get('date', '')})")
    for r in recs:
        if r.get("contradicts"):
            n += 1
            out.append(f"- {note_text(r.get('question', ''))} [{skey} {r.get('a_stamps', [''])[0] if r.get('a_stamps') else ''}]: "
                       f"your answer disagrees with [{note_text(r['contradicts']).strip('()')}]")
    if not n:
        out.append("- none")
    return "\n".join(out).rstrip("\n") + "\n", answer_lines


def note_rel(day: str, skey: str) -> str:
    return f"Review/{day} {skey}.md"

