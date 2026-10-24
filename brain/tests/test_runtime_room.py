"""The room route's live-test fixes (anytime calls, interim until phase D separates the voices):

1. indirect questions: a room statement of 8+ words gets the statement probe, which shows a card only when it says
   KIND: question (no acknowledgements in the room);
2. the owner's own voice by text: while a card is on screen, a room text that lines up with the card in order is relabelled `me`
   (never a card, follow coverage, transcript as the owner); an interviewer who shares a few words with the card stays `room`;
3. PRIORITIES: his notes lead the ABOUT ME block and the system prompts say to follow them.

Fictional fixtures only (Dana Reyes, an interview about the school she chose and her major); the transport is the canned fake."""

from __future__ import annotations

import asyncio
import shutil

from test_runtime_helpers import FIX, partial, run, settle, turn
from test_runtime_me import PROFILE, bp_count, make, me_spec, session_dir, start

from verse_brain.runtime.fake import lines_script
from verse_brain.runtime.me import load_me, priorities_first
from verse_brain.runtime.own import OwnParams, OwnSpeech, aligned, content_stems
from verse_brain.runtime.prompt import (PRIORITIES_HEADING, SYSTEM_DEEP_ME, SYSTEM_FAST_ME, SYSTEMS_ME_PRIORITIES, render_about_block,
                                        statement_tail, system_blocks)

# ---------------------------------------------------------------- the two cards of the fixture interview
CARD1 = ("I am a backend engineer who builds small payment tools, most recently a reconciliation service called Harbor Ledger.",
         ["Harbor Ledger cut the month-end close from six days to two.",
          "Before that I built Trailhead, a hiking app with twelve thousand monthly users."])
CARD2 = ("I chose this school for its co-op program, and I chose accounting because I like turning messy payment data into a clear story.",
         ["The co-op placed me with a finance team for two terms.",
          "Accounting gave me the base to build Harbor Ledger later, a payments reconciliation service."])


def card_text(card) -> str:
    return "\n".join([f"SAY: {card[0]}", *[f"- {p}" for p in card[1]], "BANK: none"])


def responder(info):
    tail = info.tail
    if "STATEMENT CHECK" in tail:
        # what a good model does with the room probe; the fake also writes an acknowledgement for a plain statement, which the room must not show
        if "glad to hear how you" in tail:
            return lines_script("KIND: question\n" + card_text(CARD2))
        return lines_script("KIND: statement\nSAY: Thanks, noted.")
    if info.route == "D":
        return lines_script("OPENER_OK\n- A detail point (f001)\n- Another detail (f002)")
    if "about yourself" in tail:
        return lines_script(card_text(CARD1))
    if "why you chose this school" in tail or "chose accounting" in tail:
        return lines_script(card_text(CARD2))
    return lines_script("SAY: Sure, here is the short answer.\n- First point.\n- Second point.\nBANK: none")


def room_start(tmp_path, **extra):
    b, t, em, _ = make(tmp_path, embedder=False, responder=responder)
    return b, t, em, start(b, session_dir(tmp_path), me=me_spec(), mode="unprepared", route="room", follow=True, **extra)


def f_calls(t):
    return [c for c in t.by_route("F") if "SUMMARIZE" not in c.tail]


def shown(em) -> str:
    """Everything the overlay was sent as card text."""
    return "".join(e["text"] for e in em.of("delta"))


def words_of(s: str) -> list[str]:
    return s.split()


async def read_aloud(b, tid: str, text: str, *, cue: bool = True, kind: str = "statement") -> None:
    """the owner reads `text` while the one microphone hears it: cumulative partials (a question cue on some of them, as a card
    sentence can have one), then the turn."""
    w = words_of(text)
    for n in range(3, len(w) + 1, 3):
        await partial(b, tid, " ".join(w[:n]), cue=cue, speaker="room")
    await turn(b, tid, text, speaker="room", addressee="unknown", kind=kind)


# ---------------------------------------------------------------- the sequence of the live test
def test_a_room_session_chit_chat_indirect_question_and_reading_the_card(tmp_path):
    async def go():
        b, t, em, coro = room_start(tmp_path)
        await coro
        # 1. the interviewer's chit-chat: statements, probed silently, nothing is shown
        await turn(b, "r1", "thanks for coming in today and for making the time", speaker="room", kind="statement")
        await turn(b, "r2", "we have about forty minutes so let me explain how this will go", speaker="room", kind="statement")
        await settle(b)
        assert em.of("delta") == [] and em.of("metric", stage="statement_probe")        # probed (the model says statement) but shown nothing
        # 2. a direct question: a card
        await partial(b, "r3", "why don't you tell me about yourself", cue=True, speaker="room")
        await turn(b, "r3", "why don't you tell me about yourself", speaker="room", kind="question")
        await settle(b)
        first_cards = [e for e in em.of("delta") if e["tier"] in ("S", "F")]      # S when its partial was speculated
        assert first_cards and "Harbor Ledger" in shown(em)
        n_f = len(f_calls(t))
        n_s = len(t.by_route("S"))
        # 3. he reads the card aloud (the one microphone hears it): his sentences are `me`, no card, no probe
        await read_aloud(b, "r4", CARD1[0])
        await read_aloud(b, "r5", CARD1[1][0], kind="question")        # even when Swift calls it a question with a cue
        await settle(b)
        assert len(f_calls(t)) == n_f and len(t.by_route("S")) == n_s
        assert [x.speaker for x in b.turns][-2:] == ["me", "me"]
        assert em.of("metric", stage="room_own", own=True)
        assert em.of("covered", card_id="orig-r3", point=0)                                  # follow mode got his words: point 1 struck through
        # 4. the next question arrives in three turns; the first two only set it up, the third carries it
        await turn(b, "r6", "one of the big decisions you have made is which university or college to attend", speaker="room",
                   kind="statement")
        await turn(b, "r7", "and an equally big if not bigger one is what your major will be", speaker="room", kind="statement")
        await settle(b)
        assert len(f_calls(t)) == n_f + 2 and "co-op program" not in shown(em)           # the setup turns were probed, not answered
        await turn(b, "r8", "i am interested in why you chose this school and in particular why you chose accounting as a major",
                   speaker="room", kind="question")
        await settle(b)
        assert "co-op program" in shown(em)
        n_f2 = len(f_calls(t))
        # 5. he reads that card; then the interviewer follows up on its subject with a question of his own: that one is a room question
        await read_aloud(b, "r9", CARD2[0])
        await read_aloud(b, "r10", CARD2[1][1])
        await settle(b)
        assert len(f_calls(t)) == n_f2
        await turn(b, "r11", "and what did you do on the co-op placement with the finance team", speaker="room", kind="question")
        await settle(b)
        assert len(f_calls(t)) == n_f2 + 1
        return b, t, em

    b, t, em = run(go())
    assert [x.speaker for x in b.turns if x.turn_id in ("r8", "r9", "r10", "r11")] == ["room", "me", "me", "room"]
    own = [e for e in em.of("metric", stage="room_own") if e["own"]]
    assert {e["turn_id"] for e in own} >= {"r4", "r5", "r9", "r10"} and not {e["turn_id"] for e in own} & {"r6", "r7", "r8", "r11"}


def test_the_reading_is_dropped_before_it_can_fire_a_card_even_with_a_question_cue(tmp_path):
    """The card sentence with a cue and 6+ words used to start speculation (S) on its partials and a card at the endpoint."""
    async def go():
        b, t, em, coro = room_start(tmp_path)
        await coro
        await turn(b, "r1", "tell me about yourself in a few words", speaker="room", kind="question")
        await settle(b)
        n = len(t.calls)
        w = words_of("Harbor Ledger cut the month-end close from six days to two and I led the reconciliation work")
        for k in range(4, len(w) + 1):
            await partial(b, "r2", " ".join(w[:k]), cue=True, speaker="room")
        await turn(b, "r2", " ".join(w), speaker="room", kind="question")
        await settle(b)
        return b, t, n

    b, t, n = run(go())
    assert [c.route for c in t.calls[n:]] == [] or all(c.route not in ("F", "D") for c in t.calls[n:])
    # his reading is `me`; "and I led the reconciliation work" is not on the card (4 trailing words), so the text is split there
    assert [(x.turn_id, x.speaker) for x in b.turns[-2:]] == [("r2m", "me"), ("r2", "room")]
    assert b.turns[-2].text.startswith("Harbor Ledger cut the month-end close")


# ---------------------------------------------------------------- the statement probe in the room
def test_room_statements_of_eight_words_get_a_silent_probe_and_a_question_gets_its_card(tmp_path):
    async def go(text, **extra):
        b, t, em, coro = room_start(tmp_path, **extra)
        await coro
        await turn(b, "r1", text, speaker="room", kind="statement")
        await settle(b)
        return t, em

    t, em = run(go("we have about forty minutes so let me explain"))                        # 9 words
    f = f_calls(t)
    assert len(f) == 1 and "STATEMENT CHECK (ROOM MICROPHONE)" in f[0].tail and em.of("delta") == []
    t, em = run(go("thanks for coming in"))                                                    # 4 words (under the probe's 5): nothing at all
    assert t.calls == [] and em.of("metric", stage="room_skipped")[0]["words"] == 4
    t, em = run(go("we have about forty minutes so let me explain", room_auto="off"))     # automatic cards off: not even a probe
    assert t.calls == []
    t, em = run(go("i would be glad to hear how you picked your first big project"))        # the probe says KIND: question
    assert [e["tier"] for e in em.of("delta")][:1] == ["F"] and "co-op program" in shown(em)
    assert len(t.by_route("D")) == 1                                                           # and D follows, as for any question


def test_the_room_probe_tail_is_only_for_the_room(tmp_path):
    plain, room = statement_tail("thanks for joining", "en"), statement_tail("thanks for joining", "en", room=True)
    assert "ROOM MICROPHONE" in room and "ROOM MICROPHONE" not in plain
    assert "STATEMENT CHECK" in plain and "STATEMENT CHECK" in room
    assert "SAY: <a brief acknowledgement" in plain and "acknowledgement" not in room.split("CURRENT TURN")[0].split("Then write")[1]


# ---------------------------------------------------------------- the owner's own voice by text
def card_two() -> OwnSpeech:
    o = OwnSpeech()
    o.add("r8", "orig", "say", CARD2[0], new_say=True)
    for p in CARD2[1]:
        o.add("r8", "orig", "point", p)
    return o


READING = {                                             # the owner, reading the card: must be `me`
    "say, full": "I chose this school for its co-op program and I chose accounting because I like turning messy payment data into a clear story",
    "say, first half": "i chose this school for its co-op program and i chose accounting",
    "say, ASR slips": "i chose this school for its coop program and chose accounting because i like turning messy payment data in a clear story",
    "say, words dropped": "i chose this school its coop program and accounting because i like turning payment data into a clear story",
    "second point": "accounting gave me the base to build harbor ledger later a payments reconciliation service",
    "say into point": "turning messy payment data into a clear story the co-op placed me with a finance team for two terms",
}
INTERVIEWER = {                                         # the other voice, with different words and with a few shared ones: must stay `room`
    "the question itself": "i am interested in why you chose this school and in particular why you chose accounting as a major",
    "a repeat": "so why did you choose accounting as a major in the end",
    "chit-chat on the subject": "thanks for sharing that it sounds like the co-op was a great fit for you",
    "near miss: follow-up, 4 shared words": "and what did you do on the co-op placement with the finance team",
    "near miss: follow-up, 5 shared words": "that is interesting how did the co-op placement with the finance team change your view of accounting",
    "near miss: wording from the card": "what did you learn from turning messy payment data into something clear for the finance team",
    "a paraphrase of the card (stays room on purpose)": "i picked this school for its coop program and i picked accounting because i enjoy turning messy payment data into a clear story",
}


def test_thresholds_on_the_fixtures_reading_is_me_and_the_interviewer_stays_room():
    o = card_two()
    p = o.p
    assert (p.enter, p.stay, p.min_matched, p.max_gap) == (0.75, 0.60, 5, 3)
    for name, text in READING.items():
        own, sc = o.is_own(text)
        assert own, (name, sc)
        assert sc.share >= 0.90 and sc.matched >= p.min_matched, (name, sc)
    for name, text in INTERVIEWER.items():
        own, sc = o.is_own(text)
        assert not own, (name, sc)
    # the margins the values sit in: the nearest interviewer text is the follow-up with 4 of 5 words shared (0.80, 4 matched)
    near = o.score(INTERVIEWER["near miss: follow-up, 4 shared words"])
    assert near.matched == 4 and 0.75 <= near.share < 0.9


def test_an_open_turn_that_is_me_stays_me_a_little_longer(tmp_path):
    o = card_two()
    mixed = READING["say, full"] + " now tell me about the hardest production incident you handled last year"        # his reading, then the other voice
    assert not o.is_own(mixed)[0]
    assert o.is_own(mixed, already=True)[0] and o.score(mixed).share < o.p.enter
    assert not o.is_own("so what is your biggest weakness", already=True)[0]


def test_alignment_is_in_order_and_gaps_are_bounded():
    card = "alpha bravo charlie delta echo foxtrot golf".split()
    assert aligned(["alpha", "bravo", "charlie"], card, 3) == 3
    assert aligned(["charlie", "bravo", "alpha"], card, 3) == 1                                    # reversed: no path
    assert aligned(["alpha", "echo"], card, 3) == 2                                                  # 3 card words skipped: fine
    assert aligned(["alpha", "foxtrot"], card, 3) == 1                                               # 4 skipped: only a new path
    assert aligned(["alpha", "zulu", "bravo"], card, 3) == 2                                         # a word of the text that matches nothing is free
    assert aligned([], card, 3) == 0 and aligned(["alpha"], [], 3) == 0
    assert content_stems("Harbor Ledger cut the closes") == content_stems("harbor ledgers cutting the close")   # follow's tokenizer and stemmer


def test_no_card_on_screen_nothing_is_relabelled(tmp_path):
    async def go():
        b, t, em, coro = room_start(tmp_path)
        await coro
        await turn(b, "r1", READING["say, full"], speaker="room", kind="statement")
        await settle(b)
        return b

    assert run(go()).turns[-1].speaker == "room"


def test_own_params_can_be_tuned_per_session_config(tmp_path):
    strict = OwnSpeech(OwnParams(enter=0.99, min_matched=12))
    strict.add("r8", "orig", "say", CARD2[0], new_say=True)
    assert not strict.is_own(READING["say, ASR slips"])[0] and strict.is_own(READING["say, full"])[0]


def test_a_follow_card_is_its_own_card_and_a_new_question_replaces_the_old_card():
    o = OwnSpeech()
    o.add("r1", "orig", "say", "First answer about the school.", new_say=True)
    o.add("r1", "c0001", "say", "Then the co-op placement with the finance team ran for two terms.")
    assert o.is_own("then the co-op placement with the finance team ran for two terms")[0]
    o.add("r2", "orig", "say", "A different answer about the hiking app and its twelve thousand users.", new_say=True)
    assert not o.is_own("then the co-op placement with the finance team ran for two terms")[0]    # the old card is gone
    assert o.cards.keys() == {"orig"}


# ---------------------------------------------------------------- PRIORITIES
NOTE = "[m701] Lead with Harbor Ledger and my recent projects before older jobs. | user"


def profile_with_note(tmp_path, note: str | None = NOTE):
    d = tmp_path / "profile"
    shutil.copytree(PROFILE, d)
    if note:
        p = d / "me.md"
        p.write_text(p.read_text(encoding="utf-8").rstrip("\n") + "\n" + note + "\n", encoding="utf-8")
    return d


def test_notes_lead_the_about_block_under_priorities_and_appear_once(tmp_path):
    d = profile_with_note(tmp_path)
    about = load_me(me_spec(d)).about_block((FIX / "pack.md").read_text(encoding="utf-8"))
    head, _, rest = about.partition("\n\n")
    assert head.startswith("ABOUT ME") and rest.startswith(PRIORITIES_HEADING + "\n" + NOTE + "\n")
    assert about.count(NOTE) == 1 and "## MY NOTES" not in about
    assert about.index(PRIORITIES_HEADING) < about.index("## WHO I AM") < about.index("## PROJECTS")
    assert "[m201] Harbor Ledger" in about and "## STYLE GUIDE" in about           # the rest of the block is as it was
    assert about == load_me(me_spec(d)).about_block((FIX / "pack.md").read_text(encoding="utf-8"))   # byte-stable
    assert about == render_about_block(priorities_first(load_me(me_spec(d)).core), load_me(me_spec(d)).voice)


def test_without_notes_the_block_and_the_system_text_are_what_they_were(tmp_path):
    core = (PROFILE / "me.md").read_text(encoding="utf-8")
    assert "## MY NOTES" in core and priorities_first(core) == core                  # an empty notes section: untouched
    layer = load_me(me_spec())
    assert layer.about_block("## FACTS\n[f001] x\n") == render_about_block(core, layer.voice)
    about = layer.about_block("")
    assert PRIORITIES_HEADING not in about
    assert system_blocks("F", about)[0]["text"] == SYSTEM_FAST_ME and system_blocks("D", about)[0]["text"] == SYSTEM_DEEP_ME


def test_the_system_prompts_of_s_f_d_and_c_follow_priorities_only_when_the_block_has_them(tmp_path):
    about = load_me(me_spec(profile_with_note(tmp_path))).about_block("")
    for route in ("S", "F", "C", "D"):
        text = system_blocks(route, about)[0]["text"]
        assert text == SYSTEMS_ME_PRIORITIES[route]
        assert "headed PRIORITIES" in text and "PROJECTS lines" in text and "oldest EXPERIENCE line" in text
        assert text.startswith(system_blocks(route, load_me(me_spec()).about_block(""))[0]["text"])   # the old text, then the rule
    assert system_blocks("F", None)[0]["text"] != SYSTEMS_ME_PRIORITIES["F"] and "PRIORITIES" not in system_blocks("F", None)[0]["text"]


def test_a_session_with_notes_keeps_the_breakpoint_count_and_the_block_across_requests(tmp_path):
    async def one(spec):
        b, t, em, _ = make(tmp_path, embedder=False, responder=responder)
        await start(b, session_dir(tmp_path, bank=True), me=spec)
        for i in range(5):
            await turn(b, f"q{i}", f"why don't you tell me about yourself number {i}", kind="question")
            await settle(b)
        return [c.request for c in t.calls]

    with_note = run(one(me_spec(profile_with_note(tmp_path / "with", NOTE))))
    without = run(one(me_spec()))
    assert len({r["system"][1]["text"] for r in with_note}) == 1 and PRIORITIES_HEADING in with_note[0]["system"][1]["text"]
    assert PRIORITIES_HEADING not in without[0]["system"][1]["text"]
    assert [bp_count(r) for r in with_note] == [bp_count(r) for r in without] and max(bp_count(r) for r in with_note) <= 4
    assert all(r["system"][1]["cache_control"] == {"type": "ephemeral"} and len(r["system"]) == 2 for r in with_note)
