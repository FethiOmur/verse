"""Follow my answer: the decisions it writes to events.jsonl (`follow_diverged`, `follow_state`, `follow_embed_state`).

The machine reports to a `log(event, **fields)` callback (the engine passes its event writer); here a fake sink collects the
lines. Numbers and enums only: nothing the owner said may appear in a line."""

from __future__ import annotations

import json

from follow_helpers import CARD, PACK_FOR_DETECTOR, ConceptEmbedder
from test_follow_detector import NEW_PROJECT, VERBATIM

from verse_brain.runtime.follow import FollowMachine, FollowParams
from verse_brain.runtime.follow_drive import Clock, make_machine, simulate


class Sink:
    def __init__(self) -> None:
        self.lines: list[tuple[str, dict]] = []

    def __call__(self, ev: str, **fields) -> None:
        self.lines.append((ev, fields))

    def kinds(self) -> list[str]:
        return [ev for ev, _ in self.lines]

    def of(self, ev: str, **where) -> list[dict]:
        return [f for e, f in self.lines if e == ev and all(f.get(k) == v for k, v in where.items())]


def _no_words(sink: Sink, *texts: str) -> None:
    blob = json.dumps(sink.lines).lower()
    for text in texts:
        for w in text.lower().replace(",", " ").replace(".", " ").split():
            if len(w) > 4:
                assert f'"{w}"' not in blob and f" {w} " not in blob, w
    for _, f in sink.lines:
        for v in f.values():
            assert v is None or isinstance(v, (int, float, bool, str)) and (not isinstance(v, str) or len(v) < 40), f


def _answer(text, **kw):
    sink = Sink()
    r = simulate(CARD, text, embedder=ConceptEmbedder(), pack=PACK_FOR_DETECTOR, log=sink, wps=2.5, chunk_s=0.4, **kw)
    return r, sink


def test_a_scripted_off_card_answer_logs_request_arrival_then_divergence_in_order():
    r, sink = _answer(NEW_PROJECT)
    assert r.machine.stats["diverged"] == 1
    k = sink.kinds()
    assert k[-1] == "follow_diverged" or "follow_diverged" in k
    i_div = k.index("follow_diverged")
    pre = [(e, f.get("state")) for e, f in sink.lines[:i_div]]
    assert pre[-2:] == [("follow_embed_state", "requested"), ("follow_embed_state", "arrived")], pre
    arrived = sink.of("follow_embed_state", state="arrived")[-1]
    assert arrived["verdict"] == "diverge" and arrived["embed"] is not None and arrived["margin"] is not None
    d = sink.of("follow_diverged")[0]
    assert d["rule"] in ("lexical", "time") and d["decided_by"] == "embedding" and d["embed_why"] in ("floor", "margin", "both")
    assert d["unmatched"] >= 3 and d["run_words"] >= 3 and d["words"] >= d["unmatched"]
    assert d["diverge_s"] == 4.0 and d["diverge_words"] == 5 and d["sem_floor"] == 0.80 and d["sem_margin"] == 0.04
    assert d["run_s"] >= 0 and d["since_start_s"] >= d["run_s"] and d["turn"] == "q1"
    _no_words(sink, NEW_PROJECT)


def test_reading_the_card_logs_no_divergence_and_no_state_change():
    r, sink = _answer(VERBATIM)
    assert "follow_diverged" not in sink.kinds() and "follow_state" not in sink.kinds()
    assert all(f["verdict"] == "stay" for f in sink.of("follow_embed_state", state="arrived"))
    _no_words(sink, VERBATIM)


def test_follow_state_enters_refreshes_and_ends_with_a_reason():
    sink = Sink()
    clock = Clock()
    m, _ = make_machine(CARD, None, ConceptEmbedder(), clock, pack=PACK_FOR_DETECTOR, log=sink)
    m.c_started("c0001", now=1.0)
    m.c_started("c0002", now=20.0)
    m.end("remote_spoke_again")
    st = sink.of("follow_state")
    assert [(s["state"], s["reason"]) for s in st] == [("entered", "diverged"), ("refreshed", "refresh"),
                                                      ("ended", "remote_spoke_again")]
    assert [s["refreshes"] for s in st[:2]] == [0, 1]


def test_a_refused_launch_and_a_new_question_are_logged():
    sink = Sink()
    m = FollowMachine(clock=Clock(), embed_ok=True, log=sink)
    m.new_turn("q1")
    m.c_failed(reason="halted")
    m.c_started("c0001", now=1.0)
    m.new_turn("q2")
    st = sink.of("follow_state")
    assert [(s["state"], s["reason"]) for s in st] == [("launch_refused", "halted"), ("entered", "diverged"),
                                                      ("ended", "new_question")]
    assert st[-1]["turn"] == "q1", "the line names the answer that ended"


def test_an_embedding_that_does_not_come_is_logged_as_timed_out_then_asked_again():
    sink = Sink()
    clock = Clock()
    m, _ = make_machine(CARD, FollowParams(), ConceptEmbedder(), clock, pack=PACK_FOR_DETECTOR, log=sink)
    words = NEW_PROJECT.split()
    for i in range(1, len(words) + 1):                     # nobody answers the NeedEmbed requests
        clock.t = 0.5 * i
        m.on_me("m1", " ".join(words[:i]), False)
        m.tick()
    m.drain()
    clock.t += 2.0
    m.tick()
    states = [f["state"] for f in sink.of("follow_embed_state")]
    assert states[0] == "requested" and "timed_out" in states and states[states.index("timed_out") + 1] == "requested", states
    t = sink.of("follow_embed_state", state="timed_out")[0]
    assert t["waited_s"] == FollowParams().embed_wait_s


def test_a_machine_without_a_sink_and_a_sink_that_raises_both_work():
    def boom(ev, **f):
        raise RuntimeError("disk full")

    for log in (None, boom):
        r = simulate(CARD, NEW_PROJECT, embedder=ConceptEmbedder(), pack=PACK_FOR_DETECTOR, log=log, wps=2.5, chunk_s=0.4)
        assert r.machine.stats["diverged"] == 1
