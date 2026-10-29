"""The card follows the question (runtime/size.py): small talk and logistics get one short line, an ordinary question a SAY line and
one or two points, a deep question a longer SAY and the full set. The class is computed in the brain, stated in the uncached tail
as a rule, and the point cap is enforced when the lines are parsed, so a model that ignores the rule still cannot put more on the
screen than the class allows."""

from __future__ import annotations

import json

import pytest
from test_runtime_helpers import lines_script, make, run, session_copy, settle, start, turn

from verse_brain.runtime.prompt import deep_tail, fast_tail
from verse_brain.runtime.size import card_size, points_cap, size_line

# A model that ignores the size rule: always a SAY line and three points, D with five.
THREE_POINTS = "SAY: Sure, here is the short version.\n- I led Lantern.\n- It cut entry to 2 minutes.\n- It runs in six depots.\nBANK: none"
DEEP_FIVE = ("OPENER_OK\n- First detail (f001)\n- Second detail (f001)\n- Third detail (f001)\n- Fourth detail (f001)\n"
             "- Fifth detail (f001)")


def responder(info):
    if "STATEMENT CHECK" in info.tail:
        return lines_script("KIND: statement\nNONE")
    if info.route == "D":
        return lines_script(DEEP_FIVE)
    return lines_script(THREE_POINTS)


def shown(em, tier):
    """The display lines of one tier as the app would assemble them from the deltas."""
    out, cur = [], ""
    for e in em.of("delta", tier=tier):
        cur += e["text"]
        if e["line_done"]:
            out.append(cur.strip())
            cur = ""
    return out


async def ask(text, tmp_path=None, call=None, **cfg):
    b, t, em = make(responder, **cfg)
    sdir = None
    if call is not None:
        sdir = session_copy(tmp_path)
        (sdir / "call.json").write_text(json.dumps(call), encoding="utf-8")
    await start(b, sdir)
    await turn(b, "r1", text, kind="question")
    await settle(b)
    return t, em


# ------------------------------------------------------------------------------------------------------------ the classes
@pytest.mark.parametrize("text,size", [
    ("Yes, can you hear me?", "short"), ("uh do you hear it", "short"), ("you hear me now", "short"),
    ("Can you see my screen?", "short"), ("Hi, how are you?", "short"), ("Are you ready to start", "short"), ("Right?", "short"),
    ("Mi senti?", "short"), ("Beni duyuyor musunuz", "short"),
    ("what did the pilot achieve?", "normal"), ("Which database did you pick", "normal"),
    ("Do you have experience with Kubernetes?", "normal"), ("Hi, what languages do you use?", "normal"),
    ("Do you have any questions for us?", "normal"), ("What video codecs did you use?", "normal"),
    ("Walk me through the architecture of the extraction pipeline", "deep"), ("Tell me about yourself", "deep"),
    ("tell me briefly about yourself", "deep"), ("Tell me a little bit about your background", "deep"),
    ("Could you introduce yourself?", "deep"), ("So, who are you?", "deep"), ("Who are you working with now", "normal"),
    ("How did you design the invoice pipeline at your last company", "deep"),
    ("Tell me about a time you disagreed with a teammate", "deep"),
    ("okay hello can you hear me great so walk me through the design", "deep"),
    ("Mi puoi raccontare come hai progettato il sistema", "deep"), ("Mimariyi anlatır mısınız", "deep"),
    ("", "normal"),
])
def test_the_size_class_of_a_question(text, size):
    assert card_size(text) == size


def test_a_long_multi_part_question_is_deep():
    q = " ".join(["and then there is the part about the rollout plan with the two depots and the budget"] * 3)
    assert len(q.split()) >= 28 and card_size(q) == "deep"


def test_caps_per_class_and_the_call_json_cap():
    assert [points_cap(s, "F") for s in ("short", "normal", "deep")] == [0, 2, 2]
    assert [points_cap(s, "D") for s in ("short", "normal", "deep")] == [0, 2, 4]
    assert points_cap("normal", "F", card_lines=2) == 1 and points_cap("normal", "F", card_lines=1) == 0
    assert points_cap("deep", "F", card_lines=2) == 2, "a real question gets the full card whatever card_lines says"
    assert points_cap("deep", "C") == 3


# ---------------------------------------------------------------------------------------------------------------- the engine
def test_a_yes_no_logistics_question_gets_one_short_line_and_no_points():
    t, em = run(ask("Yes, can you hear me?"))
    f = t.by_route("F")[0]
    assert "CARD SIZE: SHORT" in f.tail and "No \"- \" lines" in f.tail
    assert shown(em, "F") == ["SAY: Sure, here is the short version."], "the model wrote three points; none reaches the screen"
    assert not t.by_route("D"), "no detail tier for a greeting-sized card"
    assert any(e["stage"] == "point_capped" for e in em.of("metric"))


def test_an_ordinary_question_gets_the_say_line_and_at_most_two_points():
    t, em = run(ask("what did the pilot achieve?"))
    assert "CARD SIZE: NORMAL" in t.by_route("F")[0].tail
    assert shown(em, "F") == ["SAY: Sure, here is the short version.", "- I led Lantern.", "- It cut entry to 2 minutes."]
    d = t.by_route("D")
    assert d and "CARD SIZE: NORMAL" in d[0].tail and "at most 2 detail points" in d[0].tail
    assert len(shown(em, "D")) == 2, "D wrote five points; a normal card shows two"


def test_a_deep_question_gets_the_longer_say_and_the_full_set():
    t, em = run(ask("Walk me through the architecture of the extraction pipeline"))
    assert "CARD SIZE: DEEP" in t.by_route("F")[0].tail and "up to 32 words" in t.by_route("F")[0].tail
    assert len(shown(em, "F")) == 3, "SAY and the two points of the F tier"
    d = t.by_route("D")
    assert d and "CARD SIZE: DEEP" in d[0].tail and "2 to 4 detail points" in d[0].tail, "D keeps its 2 to 4 points"
    assert len(shown(em, "D")) == 4, "D wrote five points; four is its maximum"


def test_the_call_json_cap_is_enforced_in_code(tmp_path):
    (tmp_path / "a").mkdir()
    (tmp_path / "b").mkdir()
    (tmp_path / "c").mkdir()
    t, em = run(ask("what did the pilot achieve?", tmp_path / "a", call={"card_lines": 2}))
    assert shown(em, "F") == ["SAY: Sure, here is the short version.", "- I led Lantern."], "the whole card is two lines"
    assert "CARD SIZE" not in t.by_route("F")[0].tail, "the directive in the system prompt wins over a normal class"
    t, em = run(ask("Yes, can you hear me?", tmp_path / "b", call={"card_lines": 3}))
    assert "CARD SIZE: SHORT" in t.by_route("F")[0].tail and shown(em, "F") == ["SAY: Sure, here is the short version."]


def test_a_deep_question_beats_the_call_json_cap(tmp_path):
    """Owner, 29 Oct: "tell me about yourself" got two lines because the session's call.json said card_lines 2."""
    t, em = run(ask("tell me briefly about yourself", tmp_path, call={"card_lines": 2}))
    f = t.by_route("F")[0]
    assert "CARD SIZE: DEEP" in f.tail and "overrides the card-size directive" in f.tail
    assert len(shown(em, "F")) == 3, "SAY and both points, not the two-line card"
    d = t.by_route("D")
    assert d and "CARD SIZE: DEEP" in d[0].tail and len(shown(em, "D")) == 4


def test_with_the_setting_off_every_card_is_as_before():
    t, em = run(ask("Yes, can you hear me?", card_size=False))
    assert "CARD SIZE" not in t.by_route("F")[0].tail
    assert len(shown(em, "F")) == 4 and t.by_route("D")
    assert t.by_route("F")[0].tail == fast_tail("Yes, can you hear me?", "en", final=True)


def test_the_tails_without_a_size_are_unchanged():
    assert fast_tail("q?", "en", True) == "Language: English\nCURRENT QUESTION (finished): q?"
    assert deep_tail("q?", "en", True, None, None) == "Language: English\nOPENER ALREADY SHOWN: (none)\nCURRENT QUESTION (finished): q?"
    assert size_line(None) == "" and size_line("bogus") == ""


def test_the_size_line_comes_before_the_question():
    tail = fast_tail("Can you hear me?", "en", True, size="short")
    assert tail.index("CARD SIZE: SHORT") < tail.index("CURRENT QUESTION")


def test_a_speculative_card_of_another_class_is_not_the_answer():
    """The S call fired on a partial that read as an ordinary question; the finished question is small talk: F answers it."""
    async def go():
        b, t, em = make(responder)
        await start(b)
        from test_runtime_helpers import partial
        await partial(b, "r1", "so how was your trip over here this morning", cue=True)
        import asyncio
        await asyncio.sleep(0.4)
        await turn(b, "r1", "so how are you", kind="question")
        await settle(b)
        return t, em

    t, em = run(go())
    assert card_size("so how was your trip over here this morning") == "normal" and card_size("so how are you") == "short"
    assert shown(em, "F") == ["SAY: Sure, here is the short version."] or shown(em, "S") == ["SAY: Sure, here is the short version."]
    assert not [e for e in em.of("delta") if e["text"].startswith("- ")]
