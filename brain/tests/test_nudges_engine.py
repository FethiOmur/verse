"""Live nudges in the engine (tier K): the answer path is untouched, K is cached like F, silent, gated and one at a time."""

from __future__ import annotations

import json

import pytest

from test_runtime_helpers import make, run, session_copy, settle, start
from verse_brain.runtime import nudges as nudges_mod
from verse_brain.runtime.fake import Script, default_responder, lines_script
from verse_brain.runtime.nudges import fake_judge_line
from verse_brain.runtime.settings import HAIKU, SONNET, tuple_of
from verse_brain.runtime.transport import Offline, Overloaded

RECORDS = [
    {"id": "n001", "title": "Pay story", "when": "pay or salary is being discussed now", "keys": ["salary", "pay"],
     "who": "any", "until": "number", "after_s": 0, "say": ["Tell the pilot story first.", "Then name the range."],
     "ref": "prep:L20"},
    {"id": "n002", "title": "Tooling", "when": "the tools they use are being discussed", "keys": ["tooling"],
     "who": "any", "until": None, "after_s": 0, "say": ["Ask which tracker they use."], "ref": "prep:L30"},
]

SCRIPT = [
    ("r1", "remote", "Thanks for joining, can you tell me about yourself?", 5.0),
    ("m1", "me", "Sure, I led Lantern for two years.", 12.0),
    ("r2", "remote", "Great. Let's talk about the salary for this role now.", 20.0),
    ("m2", "me", "Happy to, I have a story about that first.", 26.0),
    ("r3", "remote", "What tooling did you use on Lantern?", 100.0),
    ("m3", "me", "Mostly Python and a small queue.", 106.0),
]


def nudge_session(tmp_path, records=RECORDS, raw: str | None = None):
    s = session_copy(tmp_path)
    text = raw if raw is not None else "".join(json.dumps(r) + "\n" for r in records)
    (s / "nudges.jsonl").write_text(text, encoding="utf-8")
    return s


def is_k(info) -> bool:
    return "NUDGE CHECK." in info.tail


def kcalls(t) -> list:
    """The nudge checks among the transport's calls (the Sonnet judge travels on route label "D", the Haiku judge on "K")."""
    return [c for c in t.calls if is_k(c)]


def responder(k_script=None):
    def r(info):
        if is_k(info):
            return k_script(info) if k_script else lines_script(fake_judge_line(info.tail))
        return default_responder(info)
    return r


async def play(b, script=SCRIPT, wait=True):
    for tid, sp, text, t in script:
        await b.handle({"type": "turn", "turn_id": tid, "speaker": sp, "text": text,
                        "addressee": "me" if sp != "me" else "unknown", "t_audio_end": t})
        if wait:
            await settle(b)


def answer_view(events: list[dict]) -> list[dict]:
    """Non-metric events without the nudge ones, call ids renamed by first appearance (ids come from a process-wide counter)."""
    names: dict[str, str] = {}
    out = []
    for e in events:
        if e["type"] in ("metric", "nudge", "nudge_clear"):
            continue
        e = dict(e)
        for k in ("id", "card_id"):
            if isinstance(e.get(k), str) and e[k][:1] in "sfdvcra" and e[k][1:].isdigit():
                e[k] = names.setdefault(e[k], f"{e[k][0]}#{len(names)}")
        e.pop("path", None)
        out.append(e)
    return out


def routes(t) -> list[str]:
    return [c.route for c in t.calls if not is_k(c)]


def test_no_file_means_no_k_calls(tmp_path):
    async def go():
        b, t, em = make(responder())
        await start(b, session_copy(tmp_path))
        await play(b)
        assert b.nudges is None
        assert kcalls(t) == [] and em.of("nudge") == [] and em.of("nudge_clear") == []
    run(go())


def test_key_turn_fires_nudge_on_lane_1_without_deltas(tmp_path):
    async def go():
        b, t, em = make(responder())
        await start(b, nudge_session(tmp_path))
        await play(b, SCRIPT[:3])
        ks = kcalls(t)
        assert len(ks) == 1 and ks[0].lane == 1 and ks[0].request["max_tokens"] == 100
        assert ks[0].model == SONNET and ks[0].route == "D"              # the default judge rides D's request
        assert "[n001] When: pay or salary" in ks[0].tail
        assert em.of("nudge") == [{"type": "nudge", "id": "n001", "title": "Pay story",
                                   "lines": ["Tell the pilot story first.", "Then name the range."], "turn_id": "r2", "ttl_s": 25}]
        assert not [e for e in em.of("delta") if e.get("tier") == "K"]
        assert not [e for e in em.of("status") if e["state"] not in ("warming", "ready")]
    run(go())


@pytest.mark.parametrize("judge,tier,model", [("sonnet", "D", SONNET), ("haiku", "F", HAIKU)])
def test_k_cached_prefix_equals_its_tier_prefix_at_the_same_transcript(tmp_path, monkeypatch, judge, tier, model):
    monkeypatch.setenv("VERSE_NUDGE_MODEL", judge)

    async def go():
        b, t, em = make(responder())
        await start(b, nudge_session(tmp_path))
        await play(b, [("r1", "remote", "Tell me about Lantern?", 5.0),
                       ("m1", "me", "Sure, and I can also cover the salary side.", 12.0),     # K over [r1, m1]
                       ("r2", "remote", "How long did Lantern take to build?", 20.0)])        # F and D over turns_before [r1, m1]
        k = kcalls(t)[0].request
        other = [c for c in t.calls if c.route == tier and not is_k(c) and "How long did Lantern take" in c.tail][0].request
        assert k["model"] == model
        assert k["system"] == other["system"]
        assert k["messages"][0]["content"][:-1] == other["messages"][0]["content"][:-1]
        assert k["messages"][0]["content"][-1] != other["messages"][0]["content"][-1]
        assert tuple_of(k) == tuple_of(other) and k["max_tokens"] == 100
    run(go())


def test_judge_control_lines_never_reach_the_card(tmp_path):
    async def go():
        b, t, em = make(responder(lambda info: lines_script("OPENER_OK\nBANK: b001\nKIND: question\nNUDGE: none")))
        await start(b, nudge_session(tmp_path))
        await play(b, SCRIPT[:2])
        before = (len(em.of("opener_status")), len(em.of("bank_verdict")))
        await play(b, [("m9", "me", "Before the pay question, one short story.", 30.0)])   # a `me` turn with a key: only K
        assert len(kcalls(t)) == 1
        assert (len(em.of("opener_status")), len(em.of("bank_verdict"))) == before
    run(go())


def test_sweep_setting_turns_the_sweep_on(tmp_path, monkeypatch):
    monkeypatch.setenv("VERSE_NUDGE_SWEEP", "2")

    async def go():
        b, t, em = make(responder(lambda info: lines_script("NUDGE: none")))
        await start(b, nudge_session(tmp_path))
        assert b.nudges.sweep_every == 2
        await play(b, [("r1", "remote", "Thanks for joining us today, nice to meet you.", 5.0),
                       ("m1", "me", "Thank you, glad to be here today.", 9.0)])
        assert len(kcalls(t)) == 1                           # no key anywhere: only the sweep could have asked
    run(go())


def test_answer_path_identical_with_nudges_on_off_and_broken(tmp_path, monkeypatch):
    async def once(folder, break_hook=False):
        b, t, em = make(responder())
        await start(b, folder)
        if break_hook:
            def boom(*a, **kw):
                raise RuntimeError("synthetic failure")
            monkeypatch.setattr(b.nudges, "on_turn", boom)
        await play(b)
        await b.stop()
        return b, t, em

    async def go():
        _, t_off, em_off = await once(session_copy(tmp_path / "off"))
        b_on, t_on, em_on = await once(nudge_session(tmp_path / "on"))
        b_bad, t_bad, em_bad = await once(nudge_session(tmp_path / "bad"), break_hook=True)
        assert em_on.of("nudge"), "the on run must actually fire"
        assert kcalls(t_on) and not kcalls(t_bad)
        assert routes(t_on) == routes(t_off) == routes(t_bad)
        assert answer_view(em_on.events) == answer_view(em_off.events) == answer_view(em_bad.events)
        assert b_bad.nudges is None
        assert len(em_bad.of("metric", stage="nudge_error")) == 1
        assert em_bad.of("metric", stage="nudge_error")[0]["where"] == "turn"
    run(go())


def test_k_errors_are_silent(tmp_path):
    for err in (Overloaded("synthetic", status=529), Offline("synthetic")):
        async def go(err=err):
            b, t, em = make(responder(lambda info: Script(error=err)))
            await start(b, nudge_session(tmp_path / type(err).__name__))
            await play(b, SCRIPT[:3])
            assert len(kcalls(t)) == 1
            assert [e["state"] for e in em.of("status")] == ["warming", "ready"]
            assert b.offline is False and b.halted is None and b.nudges is not None
            assert em.of("nudge") == []
        run(go())


def test_no_k_under_a_low_bucket(tmp_path, monkeypatch):
    async def go():
        b, t, em = make(responder())
        await start(b, nudge_session(tmp_path))
        monkeypatch.setattr(b.limiters[SONNET], "fraction_left", lambda: 0.49)   # the judge model's own bucket
        await play(b, SCRIPT[:3])
        assert kcalls(t) == [] and em.of("nudge") == []
    run(go())


def test_env_switch_turns_nudges_off(tmp_path, monkeypatch):
    monkeypatch.setenv("VERSE_NUDGES", "0")

    async def go():
        b, t, em = make(responder())
        await start(b, nudge_session(tmp_path))
        await play(b)
        assert b.nudges is None and kcalls(t) == []
    run(go())


def test_malformed_file_is_no_nudges_not_a_bad_session(tmp_path):
    async def go():
        b, t, em = make(responder())
        await start(b, nudge_session(tmp_path, raw="{this is not json\n"))
        await play(b)
        assert [e["state"] for e in em.of("status")] == ["warming", "ready"]
        assert b.nudges is None and kcalls(t) == []
        assert t.by_route("F")      # the answers ran
    run(go())


def test_evaluation_during_a_k_call_runs_once_as_catch_up(tmp_path):
    async def go():
        none_slow = lambda info: lines_script("NUDGE: none", first_byte_delay=0.3)  # noqa: E731
        b, t, em = make(responder(none_slow))
        await start(b, nudge_session(tmp_path))
        await play(b, [("r1", "remote", "What about salary?", 5.0), ("r2", "remote", "And the tooling you use?", 8.0),
                       ("m1", "me", "Sure, the tooling question first.", 9.0)], wait=False)
        assert len([c for c in b.calls if c.tier == "K"]) == 1     # one in flight; the other evaluations wait
        await settle(b)
        ks = kcalls(t)
        assert len(ks) == 2                       # exactly one catch-up, not one per skipped turn
        assert "[n002] When:" in ks[1].tail and "Sure, the tooling question first." in ks[1].tail
    run(go())


def test_no_catch_up_after_a_fire(tmp_path):
    async def go():
        slow = lambda info: lines_script(fake_judge_line(info.tail), first_byte_delay=0.3)  # noqa: E731
        b, t, em = make(responder(slow))
        await start(b, nudge_session(tmp_path))
        await play(b, [("r1", "remote", "What about salary?", 5.0), ("r2", "remote", "And the tooling you use?", 8.0)],
                   wait=False)
        await settle(b)
        assert len(kcalls(t)) == 1 and [e["id"] for e in em.of("nudge")] == ["n001"]   # cooling: no catch-up call
    run(go())


def test_k_is_never_hedged(tmp_path):
    async def go():
        slow = lambda info: lines_script(fake_judge_line(info.tail), first_byte_delay=0.2)  # noqa: E731
        b, t, em = make(responder(slow), hedge_after_s=0.05)
        await start(b, nudge_session(tmp_path))
        await play(b, SCRIPT[:3])
        ks = kcalls(t)
        assert len(ks) == 1 and ks[0].lane == 1
        assert em.of("nudge")      # a 0.2 s answer is well inside the 8 s age limit
    run(go())


def test_stale_k_result_is_dropped(tmp_path):
    async def go():
        b, t, em = make(responder())
        clock = [1000.0]
        b._clock = lambda: clock[0]
        await start(b, nudge_session(tmp_path))
        real_launched = b.nudges.launched

        def launched(ev):
            real_launched(ev)
            clock[0] += 9.0          # the answer comes back 9 s after the launch
        b.nudges.launched = launched
        await play(b, SCRIPT[:3])
        assert len(kcalls(t)) == 1 and em.of("nudge") == []
    run(go())


def test_until_number_sends_nudge_clear(tmp_path):
    async def go():
        b, t, em = make(responder())
        await start(b, nudge_session(tmp_path))
        await play(b, SCRIPT[:3] + [("m2", "me", "I was hoping for around 90k.", 26.0)])
        assert em.of("nudge", id="n001")
        assert em.of("nudge_clear") == [{"type": "nudge_clear", "id": "n001"}]
        i_nudge = em.events.index(em.of("nudge", id="n001")[0])
        assert em.events.index(em.of("nudge_clear")[0]) > i_nudge
    run(go())


def test_room_turns_are_excluded(tmp_path):
    async def go():
        b, t, em = make(responder())
        await start(b, nudge_session(tmp_path))
        await play(b, [("x1", "room", "So let's talk about the salary for this role now please", 5.0)])
        assert kcalls(t) == []
    run(go())


def test_history_number_retires_before_live_turns(tmp_path):
    async def go():
        b, t, em = make(responder())
        await start(b, nudge_session(tmp_path))
        await b.handle({"type": "history", "turns": [{"turn_id": "h1", "speaker": "me", "text": "my last offer was 70k",
                                                      "t_audio_end": 3.0}]})
        await play(b, SCRIPT[:3])
        assert em.of("nudge") == []        # n001 was retired by the number in history; n002 had no key yet
        assert kcalls(t) == []
    run(go())


def test_loader_failure_inside_start_is_contained(tmp_path, monkeypatch):
    def boom(path):
        raise RuntimeError("synthetic")
    monkeypatch.setattr("verse_brain.runtime.engine.load_nudges", boom)

    async def go():
        b, t, em = make(responder())
        await start(b, nudge_session(tmp_path))
        await play(b, SCRIPT[:3])
        assert [e["state"] for e in em.of("status")] == ["warming", "ready"] and b.nudges is None
    run(go())


def test_judge_failure_turns_nudges_off(tmp_path, monkeypatch):
    async def go():
        b, t, em = make(responder())
        await start(b, nudge_session(tmp_path))

        def boom(*a, **kw):
            raise ValueError("synthetic")
        monkeypatch.setattr(b.nudges, "judge", boom)
        await play(b)
        assert b.nudges is None and em.of("nudge") == []
        assert [e["where"] for e in em.of("metric", stage="nudge_error")] == ["judge"]
        assert len(kcalls(t)) == 1
    run(go())


def test_tracker_module_constants_match_the_wire():
    assert nudges_mod.TTL_S == 25 and isinstance(nudges_mod.TTL_S, int)
