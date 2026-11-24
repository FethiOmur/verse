"""One model request per finished session, and the code that decides which of its items are true to what was said.

The request (`build_request`): the frozen system text, then one user message with CURRENT PERSONA (the live entries, ids first, so
the model can say an item contradicts one) and CALL ROWS, every row of the session as `[<skey> <m:ss>] <ROLE>: text`. The owner's
rows are the only evidence; the other side's rows are there as question context (their wording becomes the paraphrased
`question` of an answer item, never a claim); room rows may be either voice and are never evidence.

The answer is one JSON object `{"items": [...]}`; each item has kind (answer | claim | style | preference), topic, text, quote,
cite `[skey m:ss]`, and optionally question and contradicts. `verify_items` keeps an item only when, in this order:

  kind      is one of the four kinds
  cite      names this session's key and the stamp of an OWNER row of it (a cite of the other side, of a room row, of a card or
            of a stamp that does not exist is dropped)
  quote     is, after normalisation (prep/sources.py `norm`: case, whitespace, quotes and markdown folded; `...` splits it into
            pieces found in order), inside one owner row with that stamp, and is at least MIN_QUOTE_CHARS long
  number    every significant number of the item's text is in the cited row
  name      every name and month of the item's text is said in the cited row's turn (rows.py `owner_turns`: his consecutive
            rows around it, which live recognition cuts one spoken turn into) or is a word of a confirmed source
            (`names_not_in_row`: the row's words run together, a hyphenated name's parts, or a misheard spelling at least
            NAME_FUZZY similar also count; a sentence's first word, often an ordinary capitalised word, only has to share its
            first four letters with a row word)
  confirmed when the cited row is `read` or `mixed` (rows.py: the card read aloud, which is model output), every number and
            name of the text is also in an already confirmed source (me.md, his notes, his corrections, the imported seed);
            otherwise the item is dropped: he adopted the card's wording, but its facts are not his until confirmed.
            An `own` row is held to the same rule for every number, name or month of the text that a card of the session holds
            (`CardFacts`): a short read-out of a card has too few words to be classified `read`

Logs carry counts only, never row text or item text.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field

from .. import extensions
from ..prep.sources import MIN_QUOTE_CHARS, norm, numbers_in, significant_numbers
from ..runtime.ask import est_tokens
from .rows import PRow, SessionRows, owner_turns

log = logging.getLogger("verse.persona.extract")

KINDS = ("answer", "claim", "style", "preference")
MAX_ITEMS = 30
MAX_QUOTE = 240
MAX_TEXT = 320
MAX_TOPIC = 80
MAX_QUESTION = 200
ROLE_LABEL = {"other": "OTHER", "room": "ROOM (either voice; never cite)"}

# Frozen: `{owner}` / `{OWNER}` are the only variables.
SYSTEM_TEMPLATE = (
    "You read one finished call of {owner} and pick out what it shows about how {owner} answers: the answers he gave, the "
    "claims he made about himself, how he likes to answer, and his preferences. Input: CURRENT PERSONA (what is already "
    "known, one line per entry with its id) and CALL ROWS, each written \"[<key> <m:ss>] <ROLE>: text\". Only {OWNER} rows "
    "are evidence. OTHER rows are the questions he was asked; ROOM rows may be anyone: never cite either. {OWNER} rows marked "
    "(read) are him reading a suggestion card aloud: they show wording he adopted, never proof of a number, name or date. "
    "Write one JSON object and nothing else: {\"items\": [ ... ]}, at most 30 items, each an object with \"kind\" (\"answer\", "
    "\"claim\", \"style\" or \"preference\"), \"topic\" (at most 8 words; no names of the people or companies he spoke with), "
    "\"text\" (one sentence in his voice, first person, at most 40 words, only what the cited row says, in the row's "
    "language), \"quote\" (words copied exactly from the cited row, 10 to 200 characters), \"cite\" (the row's \"[<key> "
    "<m:ss>]\" exactly as given) and, for an answer, \"question\" (the question he answered, as one neutral sentence without "
    "names). Add \"contradicts\": \"<id>\" when the item disagrees with a CURRENT PERSONA entry. Kinds: answer = his reply "
    "to a question, reusable when the question comes again; claim = a fact about himself (experience, numbers, dates, "
    "places, choices); style = how he builds or phrases an answer; preference = what he wants or avoids (roles, pay, place, "
    "ways of working). Rules: 1) Skip small talk, logistics and what CURRENT PERSONA already says, unless the item adds to it "
    "or contradicts it. 2) The rows come from speech recognition: when a key word looks misheard, leave the item out. 3) "
    "Never invent: every number, name and date in \"text\" must be in the cited row (a name the speech recognition split or "
    "misspelled, such as \"north wind\" for Northwind, may be written as the name). 4) No items: {\"items\": []}."
)
SYSTEM_TEMPLATE = extensions.with_addenda("persona", SYSTEM_TEMPLATE)


def system_text(owner: str) -> str:
    return SYSTEM_TEMPLATE.replace("{owner}", owner).replace("{OWNER}", owner.upper())


# ---------------------------------------------------------------- the request
def row_line(key: str, r: PRow, owner_label: str) -> str:
    if r.role == "me":
        mark = " (read)" if r.evidence == "read" else ""
        return f"[{key} {r.stamp}] {owner_label}{mark}: {r.text}"
    return f"[{key} {r.stamp}] {ROLE_LABEL.get(r.role, 'OTHER')}: {r.text}"


def rows_block(key: str, rows: list[PRow], owner_label: str, max_tokens: int) -> tuple[str, int]:
    """CALL ROWS, cut at whole rows to `max_tokens` (estimated); (text, rows left out at the end)."""
    out, used = [], 0
    for i, r in enumerate(rows):
        ln = row_line(key, r, owner_label)
        t = est_tokens(ln) + 1
        if used + t > max_tokens and out:
            return "\n".join(out), len(rows) - i
        out.append(ln)
        used += t
    return "\n".join(out), 0


def persona_block(lines: list[str], max_tokens: int) -> str:
    """CURRENT PERSONA lines in order, cut at whole lines to `max_tokens`; "(empty)" when there are none."""
    out, used = [], 0
    for ln in lines:
        t = est_tokens(ln) + 1
        if used + t > max_tokens:
            break
        out.append(ln)
        used += t
    return "\n".join(out) if out else "(empty)"


@dataclass
class Request:
    system: str
    user: str
    rows_cut: int
    est_input_tokens: int


def build_request(key: str, srows: SessionRows, persona_lines: list[str], owner: str, *, rows_tokens: int,
                  persona_tokens: int, review_system: str = "", review_user: str = "") -> Request:
    """The request. `review_system` / `review_user` (review.py `review_blocks`) add the after-call review to the same request:
    the review rules after the frozen system text, CONFIRMED SOURCES and QUESTION PAIRS after CALL ROWS. Without them (a call
    with no question pairs) the request is what it was before the review existed."""
    block, cut = rows_block(key, srows.rows, owner.upper(), rows_tokens)
    user = f"CURRENT PERSONA\n{persona_block(persona_lines, persona_tokens)}\n\nCALL ROWS\n{block}"
    if review_user:
        user += "\n\n" + review_user
    sys_text = system_text(owner)
    if review_system:
        sys_text += "\n\n" + review_system
    return Request(sys_text, user, cut, est_tokens(sys_text) + est_tokens(user))


# ---------------------------------------------------------------- parsing
@dataclass
class RawItem:
    kind: str
    topic: str
    text: str
    quote: str
    cite: str
    question: str = ""
    contradicts: str = ""


def _s(v: object, cap: int) -> str:
    return " ".join(v.split())[:cap] if isinstance(v, str) else ""


def json_object(text: str) -> dict | None:
    """The one JSON object of the model's answer (code fences and text around it tolerated), or None."""
    s = text.strip()
    s = re.sub(r"^```(?:json)?\s*|\s*```$", "", s)
    a, b = s.find("{"), s.rfind("}")
    if a < 0 or b <= a:
        return None
    try:
        obj = json.loads(s[a:b + 1])
    except ValueError:
        return None
    return obj if isinstance(obj, dict) else None


def parse_items(text: str) -> list[RawItem] | None:
    """The items of the model's answer, or None when it holds no readable JSON object with an `items` list. Code fences and text
    around the object are tolerated; at most MAX_ITEMS items are read."""
    obj = json_object(text)
    items = obj.get("items") if isinstance(obj, dict) else None
    if not isinstance(items, list):
        return None
    out = []
    for it in items[:MAX_ITEMS]:
        if not isinstance(it, dict):
            continue
        out.append(RawItem(kind=_s(it.get("kind"), 20).casefold(), topic=_s(it.get("topic"), MAX_TOPIC),
                           text=_s(it.get("text"), MAX_TEXT), quote=_s(it.get("quote"), MAX_QUOTE), cite=_s(it.get("cite"), 40),
                           question=_s(it.get("question"), MAX_QUESTION), contradicts=_s(it.get("contradicts"), 12)))
    return out


# ---------------------------------------------------------------- verification
_CITE = re.compile(r"^\[?\s*(s[0-9a-z]{6,8})\s+(\d{1,2}:\d{2}(?::\d{2})?)\s*\]?$")
_CAP_WORD = re.compile(r"(?<![\w'])([A-ZÀ-ÖØ-ÞÇĞİÖŞÜ][\w'’-]*)", re.UNICODE)
_SENT_START_OK = frozenset("""the a an and so yes no well i i'm i've i'd i'll we my our it it's this that in at for on with but also then
when if as after before because there here what how sure of to from by actually honestly basically""".split())
_MONTHS = frozenset("""january february march april may june july august september october november december""".split())
# Pronouns are never names, wherever they stand ("I" and its contractions, and "You" opening a quoted line).
_PRONOUNS = frozenset("""i i'm i've i'd i'll you you're you've you'd you'll your yours we we're we've our ours us he he's his
him she she's her hers they they're their them me my mine it it's its""".split())


def parse_cite(cite: str) -> tuple[str, str] | None:
    m = _CITE.match(cite.strip())
    return (m.group(1), m.group(2)) if m else None


def quote_in(row_text: str, quote: str) -> bool:
    """Every `...`-separated piece of the quote, normalised, occurs in the normalised row text, in order."""
    pieces = [norm(p) for p in re.split(r"…|\.\.\.", quote)]
    pieces = [p for p in pieces if p]
    if not pieces or len(norm(quote)) < MIN_QUOTE_CHARS:
        return False
    doc, pos = norm(row_text), 0
    for p in pieces:
        k = doc.find(p, pos)
        if k < 0:
            return False
        pos = k + len(p)
    return True


def _key(word: str) -> str:
    """A word as names are compared: casefolded, and cut at its first apostrophe, so "Stripe's" and "Northwind'de" (a Turkish
    suffix) meet "Stripe" and "Northwind"."""
    w = word.casefold().replace("’", "'").strip("'-")
    return w.split("'", 1)[0] or w


def name_tokens(text: str) -> list[tuple[str, bool]]:
    """(key, first word of a sentence) of every capitalised word of `text` that may be a proper name or a month. A sentence's
    first word counts unless it is a common sentence opener ("The", "So"); a pronoun ("I", "You", "We") never counts."""
    out: list[tuple[str, bool]] = []
    for m in _CAP_WORD.finditer(text):
        w = m.group(1).strip("'’-")
        low = w.casefold().replace("’", "'")
        if not w or low in _PRONOUNS:
            continue
        before = text[:m.start()].rstrip()
        initial = not before or before[-1] in ".!?:;\"“("
        if initial and low in _SENT_START_OK:
            continue
        out.append((_key(w), initial))
    return out


def names_in(text: str) -> set[str]:
    """Capitalised words of `text` (proper names, months), as `_key`s (see `name_tokens`)."""
    return {k for k, _ in name_tokens(text)}


def _words(text: str) -> set[str]:
    return {_key(w) for w in re.findall(r"[\w'’-]+", text, re.UNICODE)} - {""}


def months_in(text: str) -> set[str]:
    return _words(text) & _MONTHS


NAME_FUZZY = 0.8          # a name and a row word (or two or three row words run together) this similar are one name
NAME_FUZZY_MIN = 5        # ... when both are at least this long


def _alnum(w: str) -> str:
    return re.sub(r"[^\w]|_", "", w)


def _row_forms(row_text: str) -> tuple[set[str], set[str]]:
    """(the row's words as `_key`s, the row's words with punctuation taken out and runs of two or three of them joined): what a
    name may be in a transcript ("north wind" for Northwind, "open-ai" for OpenAI)."""
    keys = [_key(w) for w in re.findall(r"[\w'’-]+", row_text, re.UNICODE)]
    keys = [k for k in keys if k]
    flat = [_alnum(p) for k in keys for p in k.split("-") if _alnum(p)]
    forms = set(flat)
    for n in (2, 3):
        forms |= {"".join(flat[i:i + n]) for i in range(len(flat) - n + 1)}
    return set(keys), forms


def name_said(k: str, row_keys: set[str], row_forms: set[str], extra: set[str] | frozenset[str] = frozenset()) -> bool:
    """The name `k` (a `_key`) is said by the row, or is in `extra` (the words of the confirmed sources). Transcripts split,
    hyphenate and misspell names: a name matches the row's words run together, a hyphenated name matches when its parts do,
    and a name of NAME_FUZZY_MIN letters or more matches a row form at least NAME_FUZZY similar. A month must match exactly."""
    if k in row_keys or k in extra:
        return True
    if k in _MONTHS:
        return False
    parts = [_alnum(p) for p in k.split("-") if _alnum(p)]
    joined = "".join(parts)
    if not joined:
        return True
    if joined in row_forms or joined in extra or (len(parts) > 1 and all(p in row_forms or p in extra for p in parts)):
        return True
    if len(joined) >= NAME_FUZZY_MIN:
        from difflib import SequenceMatcher

        return any(len(f) >= NAME_FUZZY_MIN and abs(len(f) - len(joined)) <= 3
                   and SequenceMatcher(None, joined, f).ratio() >= NAME_FUZZY for f in row_forms)
    return False


def names_not_in_row(text: str, row_text: str, extra: set[str] | frozenset[str] = frozenset()) -> set[str]:
    """The names (capitalised words, months included) of an item's text that its cited row does not say (`name_said`: the
    row's words, run together or misheard, or `extra`, the confirmed sources' words). A lower-case "may" or "march" is a verb,
    not a month, and is not checked. A sentence's first word is often an ordinary word written with a capital ("Mentoring
    juniors matters to me", or a verb in Italian or Turkish), so it only has to share its first four letters with a word of the
    row ("mentor"); a name the row never says does not."""
    row, forms = _row_forms(row_text)
    missing: set[str] = set()
    for k, initial in name_tokens(text):
        if name_said(k, row, forms, extra):
            continue
        if initial and any(w[:4] == k[:4] for w in row if len(w) >= 4 and len(k) >= 4):
            continue
        missing.add(k)
    return missing


@dataclass
class Confirmed:
    """What already counts as true about the owner: me.md lines, his notes, his corrections and the imported seed. A `read` or
    `mixed` row's number, name or date is kept only when it is in here."""
    texts: list[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        self._nums: set[float] = set()
        self._words: set[str] = set()
        for t in self.texts:
            self.add(t)

    def add(self, text: str) -> None:
        self._nums |= numbers_in(text)
        self._words |= _words(text)

    def has_number(self, n: float) -> bool:
        return any(abs(n - h) < 1e-9 for h in self._nums)

    def has_numbers(self, text: str, lang: str | None = None) -> bool:
        return all(self.has_number(n) for n in significant_numbers(text, lang))

    def has_names(self, text: str) -> bool:
        return all(n in self._words for n in names_in(text) | months_in(text))


@dataclass
class CardFacts:
    """The numbers and words of every card the session showed. Cards are model output: an item number, name or month that a card
    holds is the card's until a confirmed source has it, however few words of the row line up with the card (a short read-out
    such as "a team of 12 engineers at Northwind" stays under rows.py's `min_matched` and is classified `own`)."""
    nums: set[float] = field(default_factory=set)
    words: set[str] = field(default_factory=set)

    @classmethod
    def of(cls, cards: list[str]) -> "CardFacts":
        cf = cls()
        for c in cards:
            cf.nums |= numbers_in(c)
            cf.words |= _words(c)
        return cf

    def unconfirmed(self, text: str, lang: str | None, confirmed: Confirmed) -> bool:
        """The item's text carries a number, name or month that a card holds and no confirmed source has."""
        for n in significant_numbers(text, lang):
            if any(abs(n - h) < 1e-9 for h in self.nums) and not confirmed.has_number(n):
                return True
        return any(w in self.words and w not in confirmed._words for w in names_in(text))


@dataclass
class Item:
    kind: str
    topic: str
    text: str
    quote: str
    skey: str
    stamp: str
    evidence: str            # own | read | mixed (the cited row's)
    question: str = ""
    contradicts: str = ""

    @property
    def cite(self) -> str:
        return f"[{self.skey} {self.stamp}]"


@dataclass
class Verified:
    items: list[Item]
    dropped: dict[str, int]


def verify_items(raw: list[RawItem], key: str, srows: SessionRows, confirmed: Confirmed) -> Verified:
    dropped = {"kind": 0, "cite": 0, "quote": 0, "number": 0, "name": 0, "unconfirmed": 0, "empty": 0}
    cards = CardFacts.of(srows.cards)
    by_stamp: dict[str, list[PRow]] = {}
    turn_of: dict[int, str] = {}                  # id(row) -> his whole turn around it (names said in the same breath)
    turns = owner_turns(srows.rows)
    for i, r in enumerate(srows.rows):
        if r.role == "me":
            by_stamp.setdefault(r.stamp, []).append(r)
            turn_of[id(r)] = turns.get(i, r.text)
    kept: list[Item] = []
    seen: set[tuple[str, str]] = set()
    for it in raw:
        if it.kind not in KINDS:
            dropped["kind"] += 1
            continue
        if not it.text or not it.topic:
            dropped["empty"] += 1
            continue
        c = parse_cite(it.cite)
        if c is None or c[0] != key or c[1] not in by_stamp:
            dropped["cite"] += 1
            continue
        row = next((r for r in by_stamp[c[1]] if quote_in(r.text, it.quote)), None)
        if row is None:
            dropped["quote"] += 1
            continue
        if not all(any(abs(n - h) < 1e-9 for h in numbers_in(row.text, row.lang)) for n in significant_numbers(it.text, row.lang)):
            dropped["number"] += 1
            continue
        if names_not_in_row(it.text, turn_of.get(id(row), row.text), confirmed._words):
            dropped["name"] += 1
            continue
        if row.evidence in ("read", "mixed"):
            if not (confirmed.has_numbers(it.text, row.lang) and confirmed.has_names(it.text)):
                dropped["unconfirmed"] += 1
                continue
        elif cards.unconfirmed(it.text, row.lang, confirmed):
            dropped["unconfirmed"] += 1
            continue
        sig = (it.kind, norm(it.text))
        if sig in seen:
            continue
        seen.add(sig)
        kept.append(Item(it.kind, it.topic, it.text, it.quote, key, c[1], row.evidence or "own",
                         it.question if it.kind == "answer" else "", it.contradicts))
    log.info("persona items: kept=%d dropped=%s", len(kept), {k: v for k, v in dropped.items() if v})
    return Verified(kept, dropped)
