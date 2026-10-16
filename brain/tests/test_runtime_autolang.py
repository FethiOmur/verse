"""Interim AUTO language (spec 2.5): the brain answers each turn in that turn's `lang`, whatever the session language is.

Swift tags every partial and turn with the language of its text (and switches the recognizers a few seconds later). Until that
switch lands the session language is stale, so the turn's tag has to win everywhere a tail is built. Fictional text; the transport
is the canned fake (no network)."""

from __future__ import annotations

from test_runtime_helpers import partial, run, settle, turn
from test_runtime_me import make, me_spec, session_dir, start
from test_runtime_unprepared import UNPREPARED, room

EN_Q = "tell me about the project you are proudest of"
IT_Q = "parlami del progetto di cui sei piu orgoglioso"


def f_calls(t):
    """The fast-tier cards of the turns: the stable-partial call (route S) or the final one (route F)."""
    return [c for c in t.calls if c.route in ("S", "F") and "SUMMARIZE" not in c.tail]


def d_calls(t):
    return [c for c in t.by_route("D") if "SUMMARIZE" not in c.tail]


async def lang_msg(b, tid: str, text: str, lang: str | None, *, kind: str = "question", speaker: str = "remote", with_partial: bool = True):
    """A partial and a turn tagged with `lang` (None leaves the field out, like an older sender)."""
    extra = {} if lang is None else {"lang": lang}
    if with_partial:
        await b.handle({"type": "partial", "turn_id": tid, "speaker": speaker, "text": text, "cue": True, "t_audio_end": 0.0, **extra})
    await b.handle({"type": "turn", "turn_id": tid, "speaker": speaker, "text": text, "addressee": "me", "kind": kind,
                    "t_audio_end": 0.0, **extra})


def test_an_english_question_in_an_italian_session_gets_an_english_card(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **UNPREPARED)
        await b.handle({"type": "control", "action": "lang", "lang": "it"})           # the call is on IT: the chip, or AUTO
        await lang_msg(b, "r1", EN_Q, "en")                                              # ... and the other side asks in English
        await settle(b)
        return b, t

    b, t = run(go())
    assert b.lang == "it", "the session language is still Italian: the STT switch has not landed"
    f, d = f_calls(t), d_calls(t)
    assert f and all(c.tail.startswith("Language: English") for c in f)
    assert all("Language: Italian" not in c.tail for c in f)
    assert len(d) == 1 and d[0].tail.startswith("Language: English"), "the deep card follows the turn too"


def test_the_partial_tag_reaches_the_fast_card_before_the_turn_closes(tmp_path):
    """The fast card can start on a partial; the language of the partial is the one it is written in."""
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **UNPREPARED)
        await b.handle({"type": "control", "action": "lang", "lang": "it"})
        await b.handle({"type": "partial", "turn_id": "r1", "speaker": "remote", "text": EN_Q, "cue": True, "lang": "en", "t_audio_end": 0.0})
        await settle(b)
        return t

    calls = f_calls(run(go()))
    assert calls and all(c.tail.startswith("Language: English") for c in calls)


def test_each_turn_uses_its_own_tag_and_a_missing_tag_uses_the_session(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **UNPREPARED)          # session: English
        await lang_msg(b, "r1", IT_Q, "it")                                          # Italian turn in an English session
        await settle(b)
        await lang_msg(b, "r2", EN_Q, "en")
        await settle(b)
        await b.handle({"type": "control", "action": "lang", "lang": "tr"})
        await lang_msg(b, "r3", EN_Q, None)                                          # no tag: the session's (Turkish)
        await settle(b)
        await lang_msg(b, "r4", EN_Q, "xx")                                          # not a language: the session's
        await settle(b)
        return t

    heads = [c.tail.split("\n")[0] for c in f_calls(run(go()))]
    # One card per turn (the partial's stable-partial call and the final's are one card here): the order is the turns' order.
    order = [h for i, h in enumerate(heads) if i == 0 or h != heads[i - 1]]
    assert order == ["Language: Italian", "Language: English", "Language: Turkish"], heads


def test_a_stale_session_language_does_not_override_a_confident_tag_in_the_room(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **room(room_auto="questions"))
        await b.handle({"type": "control", "action": "lang", "lang": "it"})
        await lang_msg(b, "q1", "so tell me how the reconciliation service worked in the end", "en", speaker="room")
        await settle(b)
        return t

    f = f_calls(run(go()))
    assert f and all(c.tail.startswith("Language: English") for c in f)


def test_card_now_answers_in_the_language_of_the_turn_it_answers(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **room(room_auto="off"))
        await b.handle({"type": "control", "action": "lang", "lang": "it"})
        await lang_msg(b, "q1", "so tell me how the reconciliation service worked in the end", "en", speaker="room")
        await settle(b)
        assert t.calls == []
        await b.handle({"type": "control", "action": "card_now"})
        await settle(b)
        return t

    f = f_calls(run(go()))
    assert len(f) == 1 and f[0].tail.startswith("Language: English\nCARD NOW.")
