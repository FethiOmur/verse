"""Per-session live-call directives (`call.json`, runtime/call.py): opt-in, byte-identical requests without the file."""

from __future__ import annotations

import json

from test_runtime_helpers import make, run, session_copy, settle, speak, start, turn

from verse_brain.runtime.call import bank_hint, load_call, parse_call
from verse_brain.runtime.prompt import SYSTEM_DEEP, SYSTEM_FAST, build_request, fast_tail
from verse_brain.runtime.protocol import load_session
from verse_brain.runtime.settings import route_params

CALL = {"card_lines": 2, "prefer_bank": True, "numbers": "sources_n", "language": "en",
        "tone": "calm, confident, never eager", "walkthrough_end": "14:07"}


def _with_call(tmp_path, call):
    d = session_copy(tmp_path)
    if call is not None:
        (d / "call.json").write_text(json.dumps(call), encoding="utf-8")
    return d


def _sys_text(req: dict) -> str:
    return req["system"][0]["text"]


def test_parse_ignores_bad_values():
    assert parse_call([1]) is None
    d = parse_call({"card_lines": 9, "numbers": "all", "language": "fr", "prefer_bank": "yes", "tone": 5})
    assert d is not None and not d.active and d.system_text("F") is None
    d = parse_call({"card_lines": True})
    assert d is not None and d.card_lines is None
    assert parse_call({"tone": "  calm,\n confident. "}).tone == "calm, confident"


def test_load_call_missing_unreadable_or_empty(tmp_path):
    assert load_call(tmp_path) is None
    (tmp_path / "call.json").write_text("{not json", encoding="utf-8")
    assert load_call(tmp_path) is None
    (tmp_path / "call.json").write_text(json.dumps({"walkthrough_end": "14:07"}), encoding="utf-8")
    assert load_call(tmp_path) is None            # only the app's time cue: nothing for the prompts


def test_session_without_call_json_is_unchanged(tmp_path):
    d = _with_call(tmp_path, None)
    assert load_session(d).call is None
    req = build_request("F", route_params("F"), "PACK", [], "tail")
    assert req == build_request("F", route_params("F"), "PACK", [], "tail", None, None)
    assert _sys_text(req) == SYSTEM_FAST
    assert fast_tail("q?", "en", True) == fast_tail("q?", "en", True, "", "")

    async def go():
        b, t, em = make()
        await start(b, d)
        await turn(b, "r1", "how did you build the invoice pipeline?")
        await settle(b)
        return t

    t = run(go())
    assert _sys_text(t.by_route("F")[0].request) == SYSTEM_FAST
    assert _sys_text(t.by_route("D")[0].request) == SYSTEM_DEEP


def test_directives_reach_every_route_and_the_prewarm(tmp_path):
    d = _with_call(tmp_path, CALL)

    async def go():
        b, t, em = make()
        await start(b, d)
        await turn(b, "r1", "how did you build the invoice pipeline?")
        await settle(b)
        return t

    t = run(go())
    pre = t.creates
    f, dd = t.by_route("F")[0].request, t.by_route("D")[0].request
    assert _sys_text(f).startswith(SYSTEM_FAST + "\n\nCALL DIRECTIVES")
    assert _sys_text(dd).startswith(SYSTEM_DEEP + "\n\nCALL DIRECTIVES")
    for needle in ("at most 2 short lines", "Prepared answers", "Sample size", "Language: write every line in English",
                   "Tone: calm, confident, never eager"):
        assert needle in _sys_text(f), needle
    assert "OPENER_OK and nothing else" in _sys_text(dd) and "PREPARED DEEP ANSWER" in _sys_text(dd)
    assert "Alex" in _sys_text(f) and len(f["system"]) == 1          # one block: the cache layout is the one it was
    # the pre-warm and the calls share their system bytes per route
    assert pre and {_sys_text(c["request"]) for c in pre if c["route"] == "S"} == {_sys_text(f)}
    assert {_sys_text(c["request"]) for c in pre if c["route"] == "D"} == {_sys_text(dd)}


def test_prefer_bank_names_the_matched_entry_in_the_tail(tmp_path):
    async def go(call):
        b, t, em = make()
        await start(b, _with_call(tmp_path / ("a" if call else "b"), call))
        await b.handle({"type": "bank_hit", "turn_id": "q2", "bank_id": "b001", "score": 0.9})
        await speak(b, "q2", "can you tell me about yourself please".split(), every=0.05)
        await turn(b, "q2", "can you tell me about yourself please")
        await settle(b)
        return t

    (tmp_path / "a").mkdir()
    (tmp_path / "b").mkdir()
    on = run(go({"prefer_bank": True}))
    off = run(go(None))
    tails_on = [c.tail for c in on.calls if c.route in ("S", "F") and "CURRENT QUESTION" in c.tail]
    assert tails_on and all("PREPARED ANSWER [b001]" in x and "SAY: Sure, here is the short version." in x for x in tails_on)
    assert not any("PREPARED ANSWER" in c.tail for c in off.calls)


def test_bank_hint_text():
    assert bank_hint(None) == "" and bank_hint({"id": "b9"}) == ""
    assert bank_hint({"id": "b9", "opener": "Hi.", "points": ["One.", "Two."]}).splitlines()[1:] == ["SAY: Hi.", "- One.", "- Two."]


def test_language_directive_sets_the_cards_language(tmp_path):
    d = _with_call(tmp_path, {"language": "it"})

    async def go():
        b, t, em = make()
        await start(b, d)                       # start says "en"; call.json wins
        await turn(b, "r1", "how did you build the invoice pipeline?")
        await settle(b)
        return t

    t = run(go())
    assert "Language: Italian" in t.by_route("F")[0].tail
