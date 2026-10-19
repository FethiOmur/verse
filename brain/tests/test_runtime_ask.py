"""Ask this meeting (F2a): the ask runtime over the fake client. Fixtures: tests/fixtures/ask (a fictional Dana Reyes interview).

The live check (`test_live_ask_per_model`) is opt-in: VERSE_LIVE=1. It reads the Keychain key through read_api_key and spends cents.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from verse_brain.prep.keychain import KeychainError
from verse_brain.runtime import ask as ask_mod
from verse_brain.runtime.ask import (AskRuntime, AskScript, FakeAskClient, Row, extract_citations, fold, load_history,
                                      make_chunks, parse_rows, render_grounding, select_chunks, system_text, words_script)
from verse_brain.runtime.protocol import ListEmitter, parse_line
from verse_brain.runtime.transport import CreditExhausted, Offline, RateLimited

BRAIN = Path(__file__).resolve().parents[1]
FIX = Path(__file__).resolve().parent / "fixtures" / "ask"
ROWS = json.loads((FIX / "transcript.json").read_text(encoding="utf-8"))


def session_dir(tmp_path: Path, chat: bool = False) -> Path:
    d = tmp_path / "dana"
    d.mkdir()
    for n in ("pack.md", "summary.md"):
        shutil.copy(FIX / n, d / n)
    if chat:
        shutil.copy(FIX / "chat.jsonl", d / "chat.jsonl")
    return d


def start_msg(d: Path, me: bool = True, model: str = "sonnet", rows: list | None = None) -> dict:
    return {"type": "ask_start", "session_dir": str(d), "owner_name": "Alex", "title": "Larkspur Health interview",
            "date": "2026-10-19T17:00:00+02:00", "me": {"core": str(FIX / "me.md")} if me else None,
            "transcript": ROWS if rows is None else rows, "model": model}


def make(tmp_path: Path, client: FakeAskClient | None = None, chat: bool = False, **kw):
    d = session_dir(tmp_path, chat)
    em = ListEmitter()
    c = client or FakeAskClient()
    return AskRuntime(c, em, **kw), em, c, d


def run(coro):
    return asyncio.run(coro)


async def ask_and_wait(rt: AskRuntime, q_id: str, text: str, model: str | None = None) -> None:
    msg = {"type": "ask", "id": q_id, "text": text}
    if model:
        msg["model"] = model
    await rt.handle(msg)
    if rt._task is not None:
        await asyncio.gather(rt._task, return_exceptions=True)


def chat_lines(d: Path) -> list[dict]:
    return [json.loads(ln) for ln in (d / "chat.jsonl").read_text(encoding="utf-8").splitlines() if ln.strip()]


# ---------------------------------------------------------------- grounding and prompt
def test_grounding_is_byte_identical_and_ordered(tmp_path):
    async def go():
        rt1, _, c1, d = make(tmp_path)
        await rt1.handle(start_msg(d))
        rt2 = AskRuntime(FakeAskClient(), ListEmitter())
        await rt2.handle(start_msg(d))
        return rt1.grounding, rt2.grounding

    g1, g2 = run(go())
    assert g1 == g2
    order = [g1.index(h) for h in ("MEETING: ", "ABOUT OWNER\n", "MEETING PREP\n", "SUMMARY\n", "TRANSCRIPT\n")]
    assert order == sorted(order)
    assert "STYLE GUIDE" not in g1 and "Short sentences. Plain words." not in g1     # the pack comes without its STYLE GUIDE
    assert g1.index("PRIORITIES") < g1.index("WHO I AM")                              # MY NOTES lead
    assert "[0:19] Alex: Happy to be here." in g1 and "[0:04] Other: Thanks for joining." in g1
    assert g1.rstrip().endswith("[19:58] Alex: Thank you Mara. Talk soon.")


def test_profile_off_and_empty_prep(tmp_path):
    async def go():
        d = tmp_path / "bare"
        d.mkdir()
        rt = AskRuntime(FakeAskClient(), ListEmitter())
        await rt.handle(start_msg(d, me=False))
        return rt.grounding

    g = run(go())
    assert "ABOUT OWNER" not in g
    assert "MEETING PREP\n(none: unprepared call)" in g and "SUMMARY\n(none yet)" in g


def test_system_prompt_frozen_golden():
    golden = (FIX / "system_prompt.golden.txt").read_text(encoding="utf-8").rstrip("\n")
    assert system_text("Alex") == golden
    assert "ABOUT OWNER" in golden and "the owner's questions" in golden


def test_request_layout_and_breakpoints(tmp_path):
    async def go():
        rt, em, c, d = make(tmp_path, chat=True)
        await rt.handle(start_msg(d))
        return rt.build_request("sonnet", "When can Dana start?"), rt.history

    req, hist = run(go())
    assert len(hist) == 2                                      # q2/a2 and q4/a4: the reset hides q1, the a_error pair is skipped
    msgs = req["messages"]
    assert [m["role"] for m in msgs] == ["user", "assistant", "user", "assistant", "user"]
    first = msgs[0]["content"]
    assert first[0]["cache_control"] == {"type": "ephemeral"} and first[1]["text"] == hist[0][0]
    assert msgs[1]["content"] == hist[0][1] and msgs[-1]["content"] == "When can Dana start?"
    blob = json.dumps(req)
    assert blob.count('"cache_control"') == 2 and req["cache_control"] == {"type": "ephemeral"}      # <= 4, here 2
    assert req["system"] == [{"type": "text", "text": system_text("Alex")}]
    assert "betas" in req and req["fallbacks"] == "default"


def test_first_question_rides_in_the_grounding_message(tmp_path):
    async def go():
        rt, _, _, d = make(tmp_path)
        await rt.handle(start_msg(d))
        return rt.build_request("sonnet", "q one")

    msgs = run(go())["messages"]
    assert len(msgs) == 1 and [b["text"] for b in msgs[0]["content"]][1] == "q one"


# ---------------------------------------------------------------- history
def test_history_after_last_reset_skips_errors_and_caps(tmp_path):
    p = tmp_path / "chat.jsonl"
    p.write_text((FIX / "chat.jsonl").read_text(encoding="utf-8"), encoding="utf-8")
    assert load_history(p) == [("What did Mara ask about Harbor Ledger?", "She asked about your role and the hardest part [1:33] [2:30]."),
                               ("When can Dana start?", "From January 2027 [12:22].")]
    lines = []
    for i in range(20):
        lines.append(json.dumps({"type": "q", "id": f"q{i}", "t": "x", "text": f"question {i}", "model": "m"}))
        lines.append(json.dumps({"type": "a", "id": f"a{i}", "q": f"q{i}", "t": "x", "text": f"answer {i}"}))
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    h = load_history(p)
    assert len(h) == 12 and h[0][0] == "question 8" and h[-1][0] == "question 19"
    assert load_history(tmp_path / "missing.jsonl") == []


# ---------------------------------------------------------------- modes
def test_full_to_chunked_switch_at_the_threshold(tmp_path):
    def run_with(tokens):
        async def go():
            c = FakeAskClient(token_counter=lambda m, s, msgs: tokens)
            rt, em, _, d = make(tmp_path / f"t{tokens}", c)
            await rt.handle(start_msg(d))
            return rt, em

        (tmp_path / f"t{tokens}").mkdir()
        return run(go())

    rt, em = run_with(180_000)
    assert rt.mode == "full" and "TRANSCRIPT\n" in rt.grounding and "TRANSCRIPT INDEX" not in rt.grounding
    ready = em.of("status", state="ready")[0]
    assert ready["context"] == {"tokens": 180_000, "mode": "full", "rows": 40, "history": 0}
    rt, em = run_with(180_001)
    assert rt.mode == "chunked" and "TRANSCRIPT INDEX" in rt.grounding and "[19:58] Alex" not in rt.grounding
    assert em.of("status", state="ready")[0]["context"]["mode"] == "chunked"


def test_count_is_free_and_on_sonnet(tmp_path):
    async def go():
        rt, _, c, d = make(tmp_path)
        await rt.handle(start_msg(d))
        return c.counts

    counts = run(go())
    assert len(counts) == 1 and counts[0][0] == "claude-sonnet-5-5"


def test_bm25_picks_the_chunk_with_the_rare_word_in_time_order():
    rows = [Row(f"{i}:00", "Other" if i % 2 else "Alex", f"Filler talk about weather and travel number {i} and more filler words here")
            for i in range(30)]
    rows[22] = Row("22:00", "Alex", "We fixed the idempotency key bug in the replay path")
    chunks = make_chunks(rows, chunk_tokens=60)
    assert len(chunks) > 5
    sel = select_chunks(chunks, "What about the idempotency key?", budget_tokens=chunks[0].tokens * 2)
    assert any("idempotency" in c.text for c in sel)
    assert [c.index for c in sel] == sorted(c.index for c in sel)
    assert sum(c.tokens for c in sel) <= chunks[0].tokens * 2
    # accent-folded: Turkish dotted I and Italian accents
    assert fold("İstanbul perché") == fold("istanbul perche")
    rows[5] = Row("5:00", "Other", "Parliamo di perché İstanbul è speciale")
    sel2 = select_chunks(make_chunks(rows, chunk_tokens=60), "perche istanbul", budget_tokens=500)
    assert any("İstanbul" in c.text for c in sel2)


def test_chunked_question_carries_excerpts(tmp_path):
    async def go():
        c = FakeAskClient(token_counter=lambda *a: 999_999)
        rt, em, _, d = make(tmp_path, c, chunk_tokens=120, excerpt_tokens=200)
        await rt.handle(start_msg(d))
        await ask_and_wait(rt, "q1", "How did she find the Kafka consumer lag?")
        return rt, c

    rt, c = run(go())
    tail = c.requests[0]["messages"][-1]["content"][-1]["text"]
    assert tail.startswith("TRANSCRIPT EXCERPTS") and "QUESTION\nHow did she find" in tail
    assert "Kafka" in tail
    assert sum(ch.tokens for ch in rt.chunks if ch.text in tail) <= 200
    assert rt.mode == "chunked" and "TRANSCRIPT INDEX" in c.requests[0]["messages"][0]["content"][0]["text"]


# ---------------------------------------------------------------- citations
def test_citations_valid_in_order_invalid_dropped():
    stamps = frozenset(r["stamp"] for r in ROWS)
    text = "He asked [12:22] and before that [1:33], again [12:22]. A made-up [99:99] and [3:7] and a late [19:58]."
    assert extract_citations(text, stamps) == ["12:22", "1:33", "19:58"]
    assert extract_citations("[1:02:05] x", frozenset({"1:02:05"})) == ["1:02:05"]


# ---------------------------------------------------------------- streaming, cancel, errors
def test_delta_then_done_order_and_chat_lines(tmp_path):
    async def go():
        rt, em, c, d = make(tmp_path)
        await rt.handle(start_msg(d))
        await ask_and_wait(rt, "q4", "What did Lena ask about authoring?")
        return rt, em, d

    rt, em, d = run(go())
    kinds = [e["type"] for e in em.events]
    assert kinds[:2] == ["status", "status"] and kinds.count("ask_done") == 1
    i_done = kinds.index("ask_done")
    assert all(k == "ask_delta" for k in kinds[2:i_done]) and kinds[2:i_done]
    deltas = "".join(e["text"] for e in em.of("ask_delta"))
    done = em.of("ask_done")[0]
    assert done["id"] == "a4" and done["q"] == "q4" and done["model"] == "claude-sonnet-5-5"
    assert done["usage"] == {"input": 412, "output": 388, "cache_read": 31240, "cache_write": 0}
    assert done["cost_usd"] == round((412 * 2.0 + 388 * 10.0 + 31240 * 0.20) / 1e6, 6)
    assert done["stop_reason"] == "end_turn" and done["cost_estimated"] is False
    assert done["citations"] == ["0:04"] and "[0:04]" in deltas
    assert isinstance(done["ms_total"], int) and isinstance(done["ms_first_token"], int)
    assert list(done) == ["type", "id", "q", "model", "usage", "cost_usd", "ms_first_token", "ms_total", "citations",
                          "stop_reason", "cost_estimated"]
    q, a = chat_lines(d)
    assert list(q) == ["type", "id", "t", "text", "model"] and q["type"] == "q" and q["model"] == "claude-sonnet-5-5"
    assert list(a) == ["type", "id", "q", "t", "text", "model", "usage", "cost_usd", "cost_estimated", "ms_first_token",
                       "ms_total", "citations", "stop_reason", "context"]
    assert a["text"] == deltas and a["context"] == "full" and a["q"] == "q4"
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", q["t"])
    assert rt.history[-1][0] == "What did Lena ask about authoring?"


def test_second_question_sends_history(tmp_path):
    async def go():
        rt, _, c, d = make(tmp_path)
        await rt.handle(start_msg(d))
        await ask_and_wait(rt, "q1", "first?")
        await ask_and_wait(rt, "q2", "second?")
        return c

    c = run(go())
    msgs = c.requests[1]["messages"]
    assert [m["role"] for m in msgs] == ["user", "assistant", "user"]
    assert msgs[0]["content"][1]["text"] == "first?" and msgs[2]["content"] == "second?"
    assert msgs[0]["content"][0]["text"] == c.requests[0]["messages"][0]["content"][0]["text"]      # same grounding bytes


def test_cancel_gives_cancelled_with_estimated_cost(tmp_path):
    def slow(request, n):
        return AskScript(chunks=[(0.0, "Partial answer "), (5.0, "never arrives")], model=request["model"])

    async def go():
        rt, em, c, d = make(tmp_path, FakeAskClient(slow))
        await rt.handle(start_msg(d))
        await rt.handle({"type": "ask", "id": "q1", "text": "long one"})
        for _ in range(100):
            await asyncio.sleep(0.01)
            if em.of("ask_delta"):
                break
        await rt.handle({"type": "control", "action": "cancel"})
        rt.client.responder = lambda r, n: words_script("ok", model=r["model"])      # a new question works afterwards
        await ask_and_wait(rt, "q2", "again")
        return rt, em, d

    rt, em, d = run(go())
    assert [e["stop_reason"] for e in em.of("ask_done")] == ["cancelled", "end_turn"]
    done = em.of("ask_done")[0]
    assert done["stop_reason"] == "cancelled" and done["cost_estimated"] is True
    assert done["usage"]["output"] == -(-len("Partial answer ") // 4)           # characters / 4, rounded up
    assert done["usage"]["input"] == 412 and done["usage"]["cache_read"] == 31240
    assert done["cost_usd"] == round((412 * 2.0 + done["usage"]["output"] * 10.0 + 31240 * 0.20) / 1e6, 6)
    a = [x for x in chat_lines(d) if x["type"] == "a"][0]
    assert a["stop_reason"] == "cancelled" and a["text"] == "Partial answer "
    assert not em.of("ask_error")


@pytest.mark.parametrize("exc, kind", [(CreditExhausted("402 billing_error"), "credit_exhausted"), (Offline("APIConnectionError"), "offline"),
                                       (RateLimited("429 rate_limit", retry_after=12.0), "rate_limited")])
def test_errors_map_to_ask_error_kinds(tmp_path, exc, kind):
    async def go():
        rt, em, c, d = make(tmp_path, FakeAskClient(lambda r, n: AskScript(error=exc)))
        await rt.handle(start_msg(d))
        await ask_and_wait(rt, "q1", "x?")
        return em, d, rt

    em, d, rt = run(go())
    err = em.of("ask_error")[0]
    assert err["kind"] == kind and err["id"] == "a1" and err["q"] == "q1" and not em.of("ask_done")
    assert (err.get("retry_after") == 12.0) == (kind == "rate_limited")
    lines = chat_lines(d)
    assert [x["type"] for x in lines] == ["q", "a_error"] and lines[1]["kind"] == kind
    assert rt.history == []                      # a failed question is not history


def test_refusal_is_an_ask_error(tmp_path):
    async def go():
        rt, em, c, d = make(tmp_path, FakeAskClient(lambda r, n: AskScript(stop_reason="refusal", chunks=[(0.0, "no")])))
        await rt.handle(start_msg(d))
        await ask_and_wait(rt, "q1", "x?")
        return em

    em = run(go())
    assert em.of("ask_error")[0]["kind"] == "refusal"


def test_busy_unstarted_and_reset(tmp_path):
    async def go():
        rt, em, c, d = make(tmp_path, FakeAskClient(lambda r, n: AskScript(chunks=[(0.0, "a"), (0.2, "b")])))
        await rt.handle({"type": "ask", "id": "q0", "text": "too early"})
        await rt.handle(start_msg(d))
        await rt.handle({"type": "ask", "id": "q1", "text": "one"})
        await rt.handle({"type": "ask", "id": "q2", "text": "two"})
        await asyncio.gather(rt._task)
        await rt.handle({"type": "control", "action": "reset"})
        return rt, em, d

    rt, em, d = run(go())
    errs = em.of("ask_error")
    assert [e["kind"] for e in errs] == ["bad_request", "bad_request"]
    assert rt.history == [] and chat_lines(d)[-1]["type"] == "reset"
    assert load_history(d / "chat.jsonl") == []


def test_params_per_model(tmp_path):
    async def go():
        rt, _, c, d = make(tmp_path)
        await rt.handle(start_msg(d))
        return {m: rt.build_request(m, "q") for m in ("haiku", "sonnet", "opus")}

    r = run(go())
    h, s, o = r["haiku"], r["sonnet"], r["opus"]
    assert h["thinking"] == {"type": "disabled"} and "betas" not in h and "fallbacks" not in h and h["max_tokens"] == 1500
    assert h["model"] == "claude-haiku-5-5" and h["output_config"] == {"effort": "medium"}
    assert "thinking" not in s and s["max_tokens"] == 4000 and s["betas"] == ["server-side-fallback-2026-07-01"]
    assert s["fallbacks"] == "default" and s["model"] == "claude-sonnet-5-5"
    assert "thinking" not in o and o["model"] == "claude-opus-5-5" and o["output_config"] == {"effort": "medium"}
    assert o["betas"] == ["server-side-fallback-2026-07-01"] and o["fallbacks"] == "default"


def test_model_picker_switches_per_question(tmp_path):
    async def go():
        rt, em, c, d = make(tmp_path)
        await rt.handle(start_msg(d, model="haiku"))
        await ask_and_wait(rt, "q1", "a?")
        await ask_and_wait(rt, "q2", "b?", model="opus")
        return c, d

    c, d = run(go())
    assert [r["model"] for r in c.requests] == ["claude-haiku-5-5", "claude-opus-5-5"]
    assert [x["model"] for x in chat_lines(d) if x["type"] == "q"] == ["claude-haiku-5-5", "claude-opus-5-5"]


# ---------------------------------------------------------------- billing
def test_client_is_built_from_the_keychain_key_only(monkeypatch):
    seen = {}

    class Rec:
        def __init__(self, **kw):
            seen.update(kw)

    monkeypatch.setattr(ask_mod, "read_api_key", lambda: "sk-ant-test-0123456789")
    import anthropic

    monkeypatch.setattr(anthropic, "AsyncAnthropic", Rec)
    ask_mod.make_client()
    assert seen["api_key"] == "sk-ant-test-0123456789"
    assert seen.get("auth_token") is None

    def boom():
        raise KeychainError("Keychain item service=verse-anthropic missing")

    monkeypatch.setattr(ask_mod, "read_api_key", boom)
    with pytest.raises(KeychainError):
        ask_mod.make_client()
    assert isinstance(ask_mod.make_client(fake=True), FakeAskClient)


def test_no_oauth_or_token_env_path_in_ask_py():
    src = (BRAIN / "verse_brain" / "runtime" / "ask.py").read_text(encoding="utf-8").lower()
    for forbidden in ("anthropic_auth_token", "auth_token", "oauth", "claude.ai", "environ", "getenv", "anthropic_api_key"):
        assert forbidden not in src, forbidden
    assert "read_api_key" in src


# ---------------------------------------------------------------- the process
def test_protocol_parse_and_process_modes(tmp_path):
    assert parse_line('{"type":"ask_start","session_dir":"x"}')["type"] == "ask_start"
    assert parse_line('{"type":"ask","id":"q1","text":"x"}')["type"] == "ask"
    d = session_dir(tmp_path)
    p = subprocess.Popen([sys.executable, "-m", "verse_brain.runtime", "--fake"], cwd=BRAIN, stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    evs: list[dict] = []
    try:
        for m in (start_msg(d), {"type": "ask", "id": "q1", "text": "hello?"}):
            p.stdin.write(json.dumps(m) + "\n")
        p.stdin.flush()
        while True:
            ln = p.stdout.readline()
            assert ln, "the process ended before ask_done"
            evs.append(json.loads(ln))
            if evs[-1]["type"] == "ask_done":
                break
        p.stdin.write(json.dumps({"type": "control", "action": "stop"}) + "\n")
        p.stdin.flush()
        assert p.wait(timeout=10) == 0
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)
    assert [e["type"] for e in evs][:2] == ["status", "status"] and evs[1]["state"] == "ready"
    assert any(e["type"] == "ask_delta" for e in evs) and evs[-1]["citations"] == ["0:04"]


def test_meeting_brain_ignores_ask_messages(tmp_path):
    from verse_brain.runtime.engine import Brain
    from verse_brain.runtime.fake import FakeTransport
    from verse_brain.runtime.settings import Config

    async def go():
        em = ListEmitter()
        b = Brain(FakeTransport(), em, Config())
        await b.handle({"type": "ask", "id": "q1", "text": "x"})
        await b.handle({"type": "ask_start", "session_dir": "x"})
        return em.events

    assert run(go()) == []


# ---------------------------------------------------------------- live (opt-in)
@pytest.mark.skipif(os.environ.get("VERSE_LIVE") != "1", reason="live: VERSE_LIVE=1 (Keychain key, spends cents)")
def test_live_ask_per_model(tmp_path):
    async def go():
        d = session_dir(tmp_path)
        em = ListEmitter()
        rt = AskRuntime(ask_mod.make_client(), em)
        await rt.handle(start_msg(d, me=False))
        out = {}
        for i, m in enumerate(("sonnet", "sonnet", "haiku", "opus"), 1):
            await ask_and_wait(rt, f"q{i}", ("What did Mara ask about Harbor Ledger?", "When can Dana start, and which salary range was named?",
                                             "Who is Mara?", "What did Dana say about monitoring?")[i - 1], model=m)
        await rt.shutdown()
        return em

    em = run(go())
    for e in em.of("ask_done") + em.of("ask_error"):
        print(json.dumps(e))
    assert len(em.of("ask_done")) == 4
