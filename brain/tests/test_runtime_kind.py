"""Turn kind (Swift `turn.kind`: question | statement | fragment; absent from older senders).

fragment  -> no S/F/D output for that turn, kept as transcript context only.
statement -> no D; at most one short acknowledgement line (or nothing); Haiku answers `KIND: question` to escalate
             to the normal path (F answer + D).
question / missing kind -> unchanged.
"""

from __future__ import annotations

import asyncio
import hashlib
import json

from test_runtime_helpers import DEEP_OK, FAST_OK, lines_script, make, partial, run, settle, speak, start, turn

from verse_brain.runtime import prompt
from verse_brain.runtime.protocol import turn_kind
from verse_brain.runtime.settings import tuple_of

STATEMENT = "i will be taking notes during the call, i hope that is not distracting"
QUESTION = "what did the pilot achieve?"
WORDS = "so tell me how exactly did you design the invoice extraction pipeline at your last company".split()


def is_probe(info) -> bool:
    return "STATEMENT CHECK" in info.tail


def responder_for(probe_text: str):
    def responder(info):
        if info.route == "D":
            return lines_script(DEEP_OK)
        if is_probe(info):
            return lines_script(probe_text)
        return lines_script(FAST_OK)
    return responder


def texts(em, **match):
    return [e["text"] for e in em.of("delta", **match)]


def lines_shown(em, tier="F"):
    """Display lines the app would assemble from the deltas of one tier (a line ends at line_done)."""
    out, cur = [], ""
    for e in em.of("delta", tier=tier):
        cur += e["text"]
        if e["line_done"]:
            out.append(cur.strip())
            cur = ""
    return out


# ---------------------------------------------------------------- protocol helper
def test_turn_kind_helper():
    assert turn_kind({"kind": "fragment"}) == "fragment"
    assert turn_kind({"kind": "statement"}) == "statement"
    assert turn_kind({"kind": "question"}) == "question"
    assert turn_kind({}) is None
    assert turn_kind({"kind": "weird"}) is None
    assert turn_kind({"kind": 3}) is None


# ---------------------------------------------------------------- fragment
def test_fragment_fires_and_shows_nothing_at_turn():
    async def go():
        b, t, em = make(responder_for(FAST_OK))
        await start(b)
        await turn(b, "q1", "We", kind="fragment")
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    assert t.calls == []
    assert not em.of("delta") and not em.of("select") and not em.of("opener_status")
    assert {e["state"] for e in em.of("status")} <= {"warming", "ready"}
    assert [x.text for x in b.turns] == ["We"]          # kept as transcript context
    assert em.of("metric", stage="fragment_skipped", turn_id="q1")


def test_fragment_discards_speculation_and_early_d():
    async def go():
        b, t, em = make(responder_for(FAST_OK))
        await start(b)
        await speak(b, "q1", WORDS[:8], every=0.1)
        await asyncio.sleep(0.9)                         # early D territory too
        await turn(b, "q1", " ".join(WORDS[:8]), kind="fragment")
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    assert t.by_route("S") or t.by_route("D"), "speculation is allowed to have fired on the partials"
    assert not t.by_route("F")
    assert not em.of("delta") and not em.of("select")
    assert all(c.discarded for c in b.calls)
    assert not b.ts["q1"].d_call or b.ts["q1"].d_call.discarded


def test_fragment_is_transcript_context_for_the_next_question():
    async def go():
        b, t, em = make(responder_for(FAST_OK))
        await start(b)
        await turn(b, "f1", "We", kind="fragment")
        await turn(b, "q1", QUESTION, kind="question")
        await settle(b)
        return b, t

    b, t = run(go())
    blocks = [x["text"] for x in t.by_route("F")[0].request["messages"][0]["content"]]
    assert "[Other side] We" in blocks


def test_fragment_does_not_displace_the_pending_question():
    async def go():
        b, t, em = make(responder_for(FAST_OK))
        await start(b)
        await turn(b, "q1", QUESTION, kind="question")
        await turn(b, "f1", "We", kind="fragment")
        await settle(b)
        return b

    b = run(go())
    assert b.latest_remote_turn == "q1"


# ---------------------------------------------------------------- statement
def test_statement_gets_one_short_line_and_no_d():
    async def go(addressee):
        b, t, em = make(responder_for("KIND: statement\nSAY: Not at all, please go ahead."))
        await start(b)
        await turn(b, "s1", STATEMENT, addressee=addressee, kind="statement")
        await settle(b)
        return b, t, em

    for addressee in ("me", "unknown"):
        b, t, em = run(go(addressee))
        assert len(t.by_route("F")) == 1 and not t.by_route("D") and not t.by_route("S")
        assert {e["tier"] for e in em.of("delta")} == {"F"}
        shown = lines_shown(em)
        assert shown == ["SAY: Not at all, please go ahead."]
        assert len(shown[0].split()) - 1 <= 12
        assert not any("KIND" in x for x in texts(em))
        assert not em.of("opener_status") and not em.of("bank_verdict")
        assert em.of("metric", stage="statement_probe", turn_id="s1")


def test_statement_probe_uses_the_fast_route_prefix():
    async def go():
        b, t, em = make(responder_for("KIND: statement\nNONE"))
        await start(b)
        await turn(b, "s1", STATEMENT, kind="statement")
        await settle(b)
        return t

    t = run(go())
    (c,) = t.by_route("F")
    assert "finished" in c.tail and STATEMENT in c.tail
    assert "Language: English" in c.tail
    assert c.request["max_tokens"] == 120


def test_statement_that_needs_no_reply_shows_nothing():
    for body in ("KIND: statement\nNONE", "NONE"):
        async def go():
            b, t, em = make(responder_for(body))
            await start(b)
            await turn(b, "s1", STATEMENT, kind="statement")
            await settle(b)
            return t, em

        t, em = run(go())
        assert len(t.by_route("F")) == 1 and not t.by_route("D")
        assert not em.of("delta")
        assert em.of("metric", stage="statement_no_reply", turn_id="s1")


def test_statement_output_is_clamped_to_one_short_line():
    # a model that ignores the format: points, a BANK line and a second SAY must not reach the screen
    chatty = "KIND: statement\nSAY: Sure, go ahead.\n- A point nobody asked for.\n- Another.\nBANK: none"
    # no KIND line at all: still a statement (the safe default), still one line
    no_kind = "SAY: Sure, go ahead.\n- A point nobody asked for.\nBANK: none"
    # too long for an acknowledgement: dropped rather than shown cut off
    too_long = "KIND: statement\nSAY: " + " ".join(["word"] * 20)
    for body, expect in ((chatty, ["SAY: Sure, go ahead."]), (no_kind, ["SAY: Sure, go ahead."]), (too_long, [])):
        async def go():
            b, t, em = make(responder_for(body))
            await start(b)
            await turn(b, "s1", STATEMENT, kind="statement")
            await settle(b)
            return t, em

        t, em = run(go())
        assert lines_shown(em) == expect, body
        assert not t.by_route("D")
        assert not any(x.startswith("- ") or "BANK" in x for x in texts(em))


def test_statement_discards_speculation_started_on_partials():
    async def go():
        b, t, em = make(responder_for("KIND: statement\nSAY: Of course."))
        await start(b)
        await speak(b, "s1", STATEMENT.split()[:8], every=0.1)      # cued partials: S fires as before
        await asyncio.sleep(0.9)                                     # ...and so does an early D
        await turn(b, "s1", STATEMENT, kind="statement")
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    assert t.by_route("S"), "S still fires on partials (the kind is unknown until the turn)"
    assert not em.of("select")
    assert {e["tier"] for e in em.of("delta")} == {"F"}
    assert lines_shown(em) == ["SAY: Of course."]
    assert all(c.discarded for c in b.calls if c.tier in ("S", "D"))


def test_statement_escalates_to_the_full_path_when_haiku_says_question():
    body = "KIND: question\nSAY: Sure, here is the short version.\n- I led Lantern.\n- It cut entry to 2 minutes.\nBANK: none"

    async def go():
        b, t, em = make(responder_for(body))
        await start(b)
        await turn(b, "s1", "walk me through the pilot", kind="statement")
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    assert len(t.by_route("F")) == 1 and len(t.by_route("D")) == 1
    assert lines_shown(em, "F") == ["SAY: Sure, here is the short version.", "- I led Lantern.", "- It cut entry to 2 minutes."]
    assert em.of("delta", tier="D")
    assert not any("KIND" in x for x in texts(em))
    assert em.of("metric", stage="statement_escalated", turn_id="s1")
    assert em.of("opener_status", turn_id="s1")           # D's first line, as on the normal path
    assert len(em.of("opener_status")) == 1


def test_statement_probe_that_fails_does_not_fire_d():
    from verse_brain.runtime.fake import Script
    from verse_brain.runtime.transport import RateLimited

    def responder(info):
        if is_probe(info):
            return Script(error=RateLimited("429", retry_after=0.1, status=429))
        return lines_script(DEEP_OK)

    async def go():
        b, t, em = make(responder)
        await start(b)
        await turn(b, "s1", STATEMENT, kind="statement")
        await settle(b)
        return t, em

    t, em = run(go())
    assert not t.by_route("D") and not em.of("delta")


# ---------------------------------------------------------------- question / missing kind: unchanged
def _shape(t, em):
    return ([(c.route, c.tail) for c in t.calls],
            [(e["type"], e.get("tier"), e.get("text"), e.get("line_done")) for e in em.events if e["type"] in ("delta", "select", "opener_status")])


def test_question_and_missing_kind_are_unchanged():
    async def go(kind):
        b, t, em = make(responder_for(FAST_OK))
        await start(b)
        await turn(b, "q1", QUESTION, kind=kind)
        await settle(b)
        return t, em

    base = run(go(None))
    assert len(base[0].by_route("F")) == 1 and len(base[0].by_route("D")) == 1
    assert base[0].by_route("F")[0].tail == prompt.fast_tail(QUESTION, "en", final=True)
    assert not any("STATEMENT CHECK" in c.tail for c in base[0].calls)
    for kind in ("question", "weird"):
        other = run(go(kind))
        assert _shape(*other) == _shape(*base), kind


def test_question_still_selects_speculation_and_skips_d_on_bank_agreement():
    async def go():
        b, t, em = make(responder_for(FAST_OK))
        await start(b)
        await speak(b, "q1", WORDS[:13], every=0.1)
        await turn(b, "q1", " ".join(WORDS[:13]), kind="question")
        await settle(b)
        return t, em

    t, em = run(go())
    assert em.of("select", turn_id="q1") and not t.by_route("F")


# ---------------------------------------------------------------- cache layout
# sha256 of the prompt constants as they were before this change: any edit to them breaks the cache prefix.
PINNED = {
    "SYSTEM_FAST": "225eaeff8099a097587edbf895b9cc1976d9c8d74407f8a357ba2e71ca987715",
    "SYSTEM_DEEP": "4ee79eee47a201ef1fdf5d833f05607d6291d8579f60759baf30c4e4802b0502",
    "PACK_HEADER": "f37a145e475c721f232e440f1ad78c8a7705c196eee5b200db0b973bdc18b525",
    "TRANSCRIPT_HEADER": "d33c9a039282727fa1162a84e507311b69d26fe7e13151611cd4d3836c3421a8",
}


def test_cache_prefix_bytes_unchanged():
    for name, digest in PINNED.items():
        assert hashlib.sha256(getattr(prompt, name).encode()).hexdigest() == digest, name


def test_statement_probe_shares_the_question_cache_prefix():
    """Up to and including breakpoint 2 (everything before the tail) a statement probe, a question F call and the
    pre-warm are byte-identical; only the tail differs."""
    def j(o):
        return json.dumps(o, sort_keys=True, ensure_ascii=False)

    async def go():
        b, t, em = make(responder_for("KIND: statement\nNONE"))
        await start(b)
        for i in range(5):                                # 10 finalized turns: breakpoint 2 is in play
            await turn(b, f"r{i}", f"question number {i} about the Lantern project?", kind="question")
            await settle(b)
            await turn(b, f"m{i}", f"my answer {i}", speaker="me")
        await turn(b, "q-last", QUESTION, kind="question")
        await settle(b)
        await turn(b, "s-last", STATEMENT, kind="statement")
        await settle(b)
        return t

    t = run(go())
    question = [c for c in t.by_route("F") if not is_probe(c)][-1].request
    probe = next(c for c in t.by_route("F") if is_probe(c)).request
    warm = t.creates[0]["request"]                         # Haiku pre-warm
    for a, b_ in ((question, probe), (probe, warm)):
        assert j(a["system"]) == j(b_["system"])
        assert tuple_of(a) == tuple_of(b_)
        assert j(a["messages"][0]["content"][0]) == j(b_["messages"][0]["content"][0])   # breakpoint 1 block
    qc, pc = question["messages"][0]["content"], probe["messages"][0]["content"]
    # the probe saw the question's turn and the answer in between: its blocks start with the question's blocks
    assert j(qc[:-1]) == j(pc[:len(qc) - 1])
    assert qc[-1]["text"] != pc[-1]["text"] and "cache_control" not in pc[-1]
    assert [i for i, x in enumerate(pc) if "cache_control" in x][0] == 0
    assert j(question["system"]) == j([{"type": "text", "text": prompt.SYSTEM_FAST}])


# ---------------------------------------------------------------- over the pipe (--fake)
def test_kind_over_pipes(tmp_path):
    """`kind` travels as JSON: a fragment is silent, a statement gets one line and no D."""
    import queue
    import threading
    import time

    from test_runtime_helpers import session_copy
    from test_runtime_ipc import _reader, _send, _spawn, _until

    sess = session_copy(tmp_path)
    p = _spawn()
    try:
        q: queue.Queue = queue.Queue()
        threading.Thread(target=_reader, args=(p, q), daemon=True).start()
        _send(p, {"type": "start", "session_dir": str(sess), "lang": "en"})
        assert _until(q, lambda e: e.get("state") == "ready", 10), "no ready status"
        _send(p, {"type": "turn", "turn_id": "f1", "speaker": "remote", "text": "We", "addressee": "me",
                  "t_audio_end": time.time(), "kind": "fragment"})
        _send(p, {"type": "turn", "turn_id": "s1", "speaker": "remote", "text": STATEMENT, "addressee": "me",
                  "t_audio_end": time.time(), "kind": "statement"})
        seen = _until(q, lambda e: e["type"] == "delta" and e["line_done"], 5)
        assert seen, "no acknowledgement line"
        time.sleep(0.5)
        while True:
            try:
                _, line = q.get_nowait()
            except queue.Empty:
                break
            if line:
                seen.append(json.loads(line))
        deltas = [e for e in seen if e["type"] == "delta"]
        assert {e["turn_id"] for e in deltas} == {"s1"} and {e["tier"] for e in deltas} == {"F"}
        assert "".join(e["text"] for e in deltas).strip() == "SAY: Thanks, noted."
        _send(p, {"type": "control", "action": "stop"})
        assert p.wait(timeout=5) == 0
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)
