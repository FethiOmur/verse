"""Ask across meetings (P3): the memory Ask runtime over the fake client and the fixture index.

Fixtures: tests/fixtures/memory/sessions (fictional: Marta Velin and Joe Arkwright of Halden Works, Giulia Ferri of Corvo Studio,
Emre Kaya of Tarla Labs). The owner is the pinned profile of conftest.py ("Alex Rivera").
The live check is opt-in: VERSE_LIVE=1 (Keychain key, spends cents).
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

from test_memory_index import SECRET_SENTENCE, put_all
from verse_brain.memory.index import MemoryIndex
from verse_brain.runtime import memory_ask as mem_mod
from verse_brain.runtime.ask import AskScript, FakeAskClient, make_client, words_script
from verse_brain.runtime.memory_ask import (MEMORY_SYSTEM_TEMPLATE, MemoryAskRuntime, catalog_line, load_memory_history,
                                            memory_system_text, render_catalog)
from verse_brain.runtime.protocol import ListEmitter, parse_line
from verse_brain.runtime.settings import MEMORY_CATALOG_MAX, MEMORY_HISTORY_PAIRS
from verse_brain.runtime.transport import CreditExhausted, Offline, RateLimited

BRAIN = Path(__file__).resolve().parents[1]
GOLDEN = Path(__file__).resolve().parent / "fixtures" / "memory" / "golden"
OWNER = "Alex Rivera"
HALDEN = ["halden-kickoff", "halden-pilot-review"]


def run(coro):
    return asyncio.run(coro)


@pytest.fixture
def idx(tmp_path):
    """(db path, {session name: key}) of the fixture index."""
    path = tmp_path / "memory" / "index.sqlite"
    ix = MemoryIndex.open(path)
    keys = put_all(ix)
    ix.close()
    return path, keys


def entity_scope() -> dict:
    return {"kind": "entity", "id": "e-8hz1p0qq", "name": "Marta Velin", "sessions": HALDEN}


def start_msg(db: Path, chat: Path, scope: dict | None = None, me: bool = False, model: str = "sonnet") -> dict:
    return {"type": "memory_ask_start", "db": str(db), "chat": str(chat), "owner_name": OWNER,
            "me": {"core": str(Path(__file__).parent / "fixtures" / "ask" / "me.md")} if me else None,
            "scope": scope or {"kind": "all", "id": None, "name": None, "sessions": None}, "model": model}


def make(client: FakeAskClient | None = None, **kw):
    em = ListEmitter()
    c = client or FakeAskClient()
    return MemoryAskRuntime(c, em, no_embed=True, **kw), em, c


async def ask_and_wait(rt, q_id: str, text: str, model: str | None = None) -> None:
    msg = {"type": "ask", "id": q_id, "text": text}
    if model:
        msg["model"] = model
    await rt.handle(msg)
    if rt._task is not None:
        await asyncio.gather(rt._task, return_exceptions=True)


def chat_lines(chat: Path) -> list[dict]:
    return [json.loads(ln) for ln in chat.read_text(encoding="utf-8").splitlines() if ln.strip()]


def req_text(req: dict) -> str:
    return json.dumps(req, ensure_ascii=False)


# ---------------------------------------------------------------- prompt and grounding
def test_system_prompt_golden_all_and_entity(idx, tmp_path):
    assert memory_system_text(OWNER) + "\n" == (GOLDEN / "ask_system_all.golden.txt").read_text(encoding="utf-8")
    assert memory_system_text(OWNER, "entity", "Marta Velin") + "\n" == (GOLDEN / "ask_system_entity.golden.txt").read_text(encoding="utf-8")
    assert "{" not in memory_system_text(OWNER, "entity", "Marta Velin")
    db, _ = idx

    async def go(scope):
        rt, _, c = make()
        await rt.handle(start_msg(db, tmp_path / "c.jsonl", scope))
        await ask_and_wait(rt, "q1", "anything?")
        return c.requests[0]["system"][0]["text"]

    assert run(go(None)) == memory_system_text(OWNER)
    assert run(go(entity_scope())) == memory_system_text(OWNER, "entity", "Marta Velin")
    assert "about all of Alex Rivera's past meetings." in memory_system_text(OWNER)


def test_template_has_only_the_documented_variables():
    assert set(re.findall(r"\{\w+\}", MEMORY_SYSTEM_TEMPLATE)) == {"{owner}", "{OWNER}", "{scope}"}


def test_cached_block_is_the_catalog_and_byte_identical(idx, tmp_path):
    db, keys = idx

    async def go():
        rt, em, c = make()
        await rt.handle(start_msg(db, tmp_path / "chat.jsonl"))
        await ask_and_wait(rt, "q1", "What was the budget?")
        await ask_and_wait(rt, "q2", "Who sends the truck list?")
        return rt, em, c

    rt, em, c = run(go())
    g = rt.grounding
    first, second = (r["messages"][0]["content"][0] for r in c.requests)
    assert first == second and first["text"] == g and first["cache_control"] == {"type": "ephemeral"}
    lines = g.splitlines()
    assert lines[0] == "SESSION CATALOG (5 meetings, newest first)"
    # newest first: prepared (27 Oct), pilot review (26 Oct), tarla (21 Oct), corvo (20 Oct), kickoff (19 Oct)
    assert [ln.split(" · ")[0] for ln in lines[1:6]] == [keys[n] for n in (
        "halden-weekly-prep", "halden-pilot-review", "tarla-intro", "corvo-design-call", "halden-kickoff")]
    assert f"{keys['halden-kickoff']} · Mon 19 Oct 2026 · meeting · Halden Kickoff · with Marta Velin (Halden Works)" in lines
    assert "ABOUT" not in g                                   # profile toggle off
    # the tail of each question: EXCERPTS then QUESTION, never in the cached block
    for r, q in zip(c.requests, ("What was the budget?", "Who sends the truck list?")):
        tail = r["messages"][-1]["content"] if r["messages"][-1]["role"] == "user" and isinstance(r["messages"][-1]["content"], str) \
            else r["messages"][0]["content"][1]["text"]
        assert tail.index("EXCERPTS") < tail.index("QUESTION\n" + q) and tail.endswith(q)
        assert "cache_control" not in r["messages"][0]["content"][-1] or len(r["messages"]) > 1
    st = em.of("status")
    assert [s["state"] for s in st] == ["warming", "ready"]
    assert st[1]["context"] == {"tokens": rt.tokens, "mode": "memory", "sessions": 5, "history": 0}
    assert c.counts and c.counts[0][0] == "claude-sonnet-5-5"          # the free count, on Sonnet


def test_profile_block_follows_the_catalog(idx, tmp_path):
    db, _ = idx

    async def go():
        rt, _, _ = make()
        await rt.handle(start_msg(db, tmp_path / "chat.jsonl", me=True))
        return rt.grounding

    g = run(go())
    assert g.index("SESSION CATALOG") < g.index("ABOUT ALEX RIVERA\n")
    assert g.index("PRIORITIES") < g.index("WHO I AM")


def test_catalog_cap_and_labels():
    from verse_brain.memory.index import SessionInfo

    infos = [SessionInfo(f"s{i}", f"sk{i:05d}", f"Title {i}", f"2026-10-{20 - i:02d}T10:00:00+02:00", "meeting", "en", ["Marta Velin"])
             for i in range(5)]
    g = render_catalog(owner=OWNER, infos=infos, about=None, limit=3)
    assert g.splitlines()[0] == "SESSION CATALOG (5 meetings, newest first)"
    assert g.splitlines()[-1] == "(and 2 older meetings, searched but not listed)" and len(g.splitlines()) == 5
    assert MEMORY_CATALOG_MAX == 400 and MEMORY_HISTORY_PAIRS == 6
    leaky = SessionInfo("s", "sk00000", "Call", "2026-10-20T10:00:00+02:00", "call", "en", ["Marta Velin", "marta@halden.example"])
    assert "@" not in catalog_line(leaky) and catalog_line(leaky).endswith("with Marta Velin")


def test_entity_scope_never_includes_another_sessions_text(idx, tmp_path):
    db, keys = idx

    async def go(scope):
        rt, _, c = make()
        await rt.handle(start_msg(db, tmp_path / f"{scope['kind']}.jsonl", scope))
        await ask_and_wait(rt, "q1", "Mavi ahtapot protokolü için ne gerekiyor? Rovigo gateway budget")
        return c.requests[0]

    ent = req_text(run(go(entity_scope())))
    assert "Henüz ölçmedik" not in ent and keys["tarla-intro"] not in ent and keys["corvo-design-call"] not in ent
    assert "Rovigo" in ent                                    # its own sessions do come through
    allr = req_text(run(go({"kind": "all", "id": None, "name": None, "sessions": None})))
    assert "Henüz ölçmedik" in allr and keys["tarla-intro"] in allr


# ---------------------------------------------------------------- citations
def test_citations_are_objects_in_done_and_chat(idx, tmp_path):
    db, keys = idx
    k = keys["halden-pilot-review"]
    answer = f"Joe confirms the truck list on Monday [{k} 2:20]. Not real [{k} 99:99] and [szzzzzz summary]."

    async def go():
        rt, em, c = make(FakeAskClient(lambda r, n: words_script(answer, model=r["model"])))
        chat = tmp_path / "memory" / "chats" / "e-8hz1p0qq.jsonl"
        await rt.handle(start_msg(db, chat, entity_scope()))
        await ask_and_wait(rt, "q1", "Who confirms the truck list?")
        return em, chat

    em, chat = run(go())
    done = em.of("ask_done")[0]
    assert len(done["citations"]) == 1
    cite = done["citations"][0]
    assert cite == {"key": k, "session": "halden-pilot-review", "title": "Halden Pilot Review", "date": "2026-10-26T10:00:00+01:00",
                    "kind": "turn", "stamp": "2:20", "speaker": "Joe", "text": "I will confirm the truck list on Monday morning."}
    assert isinstance(done["excerpt_tokens"], int) and done["excerpt_tokens"] > 0
    q, a = chat_lines(chat)
    assert q["scope"] == "e-8hz1p0qq" and a["citations"] == done["citations"] and a["context"] == "memory"
    assert a["excerpt_tokens"] == done["excerpt_tokens"] and a["text"] == answer


def test_summary_and_out_of_scope_citations(idx, tmp_path):
    db, keys = idx
    kp, kt = keys["halden-pilot-review"], keys["tarla-intro"]

    async def go():
        rt, em, _ = make(FakeAskClient(lambda r, n: words_script(f"A [{kp} summary] B [{kt} 0:04] C [{kp} summary]", model=r["model"])))
        await rt.handle(start_msg(db, tmp_path / "c.jsonl", entity_scope()))
        await ask_and_wait(rt, "q1", "x?")
        return em

    done = run(go()).of("ask_done")[0]
    assert [(c["key"], c["kind"], c["stamp"], c["speaker"]) for c in done["citations"]] == [(kp, "summary", None, None)]
    assert done["citations"][0]["text"].startswith("Summary: Halden Works approved")


# ---------------------------------------------------------------- history
def write_chat(path: Path, pairs: list[tuple[str, str, list[dict]]], reset_after: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    out = []
    for i, (q, a, cites) in enumerate(pairs, 1):
        out.append({"type": "q", "id": f"q{i}", "text": q})
        out.append({"type": "a", "id": f"a{i}", "q": f"q{i}", "text": a, "citations": cites})
        if reset_after == i:
            out.append({"type": "reset"})
    path.write_text("".join(json.dumps(x) + "\n" for x in out), encoding="utf-8")


def cite_of(idx_keys: dict, name: str) -> dict:
    return {"key": idx_keys[name], "session": name, "title": name, "date": "2026-10-19T17:00:00+02:00", "kind": "summary",
            "stamp": None, "speaker": None, "text": "x"}


def history_questions(req: dict) -> list[str]:
    qs = []
    for m in req["messages"][:-1]:
        if m["role"] == "user":
            qs.append(m["content"][1]["text"] if isinstance(m["content"], list) else m["content"])
    return qs


def test_history_skips_pairs_citing_a_session_not_in_the_index(idx, tmp_path):
    db, keys = idx
    chat = tmp_path / "chat.jsonl"
    write_chat(chat, [("first question", "answer one", [cite_of(keys, "halden-kickoff")]),
                      ("second question", "answer two", [cite_of(keys, "tarla-intro")]),
                      ("third question", "answer three", [])])
    # a copy of the index where the cited session is gone (P1's drop)
    copy = tmp_path / "copy" / "index.sqlite"
    copy.parent.mkdir()
    shutil.copy(db, copy)
    ix = MemoryIndex.open(copy)
    ix.drop(["tarla-intro"])
    ix.close()

    async def go(path):
        rt, em, c = make()
        own = tmp_path / f"chat-{path.parent.name}.jsonl"          # each run appends to its own copy of the chat
        shutil.copy(chat, own)
        await rt.handle(start_msg(path, own))
        await ask_and_wait(rt, "q9", "fourth question")
        return history_questions(c.requests[0]), em.of("status")[-1]["context"]["history"]

    assert run(go(db)) == (["first question", "second question", "third question"], 3)
    assert run(go(copy)) == (["first question", "third question"], 2)


def test_history_drop_while_open_is_seen_by_the_next_request(idx, tmp_path):
    db, keys = idx
    chat = tmp_path / "chat.jsonl"
    write_chat(chat, [("first question", "answer one", [cite_of(keys, "tarla-intro")]), ("second question", "answer two", [])])

    async def go():
        rt, em, c = make()
        await rt.handle(start_msg(db, chat))
        await ask_and_wait(rt, "q1", "third question")
        w = MemoryIndex.open(db)
        w.drop(["tarla-intro"])
        w.close()
        await ask_and_wait(rt, "q2", "fourth question")
        return c

    c = run(go())
    assert history_questions(c.requests[0]) == ["first question", "second question"]
    assert history_questions(c.requests[1]) == ["second question", "third question"]


def test_history_after_reset_only_and_capped_at_six(idx, tmp_path):
    db, _ = idx
    chat = tmp_path / "chat.jsonl"
    write_chat(chat, [(f"old {i}", f"old answer {i}", []) for i in range(1, 4)] + [(f"new {i}", f"new answer {i}", []) for i in range(1, 10)],
               reset_after=3)
    assert len(load_memory_history(chat)) == 9

    async def go():
        rt, em, c = make()
        await rt.handle(start_msg(db, chat))
        await ask_and_wait(rt, "q1", "latest?")
        return c.requests[0]

    req = run(go())
    qs = history_questions(req)
    assert qs == [f"new {i}" for i in range(4, 10)] and len(qs) == MEMORY_HISTORY_PAIRS
    assert "old " not in req_text(req).replace("old answer", "")      # nothing from before the reset
    assert [m["role"] for m in req["messages"]] == ["user", "assistant"] * 6 + ["user"]
    assert req["messages"][0]["content"][0]["cache_control"] == {"type": "ephemeral"}


def test_second_question_sends_the_first_and_the_query_has_the_previous_question(idx, tmp_path):
    db, _ = idx
    seen: list[str] = []
    real = mem_mod.search

    def spy(index, query, **kw):
        seen.append(query)
        return real(index, query, **kw)

    async def go():
        mem_mod.search = spy
        try:
            rt, _, c = make()
            await rt.handle(start_msg(db, tmp_path / "c.jsonl"))
            await ask_and_wait(rt, "q1", "Who confirms the truck list?")
            await ask_and_wait(rt, "q2", "And the budget?")
        finally:
            mem_mod.search = real
        return c

    c = run(go())
    assert seen == ["Who confirms the truck list? ", "And the budget? Who confirms the truck list?"]
    assert history_questions(c.requests[1]) == ["Who confirms the truck list?"]


def test_reset_clears_history_and_appends_a_reset_line(idx, tmp_path):
    db, _ = idx

    async def go():
        rt, em, c = make()
        chat = tmp_path / "chat.jsonl"
        await rt.handle(start_msg(db, chat))
        await ask_and_wait(rt, "q1", "one?")
        await rt.handle({"type": "control", "action": "reset"})
        await ask_and_wait(rt, "q2", "two?")
        return c, chat

    c, chat = run(go())
    assert history_questions(c.requests[1]) == []
    assert [x["type"] for x in chat_lines(chat)] == ["q", "a", "reset", "q", "a"]


# ---------------------------------------------------------------- inherited behaviour in the memory mode
def test_delta_then_done_order(idx, tmp_path):
    db, _ = idx

    async def go():
        rt, em, _ = make()
        await rt.handle(start_msg(db, tmp_path / "c.jsonl"))
        await ask_and_wait(rt, "q4", "What did Marta ask about the pilot?")
        return em

    em = run(go())
    kinds = [e["type"] for e in em.events]
    i_done = kinds.index("ask_done")
    assert kinds[:2] == ["status", "status"] and all(k == "ask_delta" for k in kinds[2:i_done]) and kinds[2:i_done]
    done = em.of("ask_done")[0]
    assert done["id"] == "a4" and done["q"] == "q4" and done["stop_reason"] == "end_turn" and done["cost_estimated"] is False
    assert done["cost_usd"] == round((412 * 2.0 + 388 * 10.0 + 31240 * 0.20) / 1e6, 6)
    assert list(done) == ["type", "id", "q", "model", "usage", "cost_usd", "ms_first_token", "ms_total", "citations", "stop_reason",
                          "cost_estimated", "excerpt_tokens"]


def test_cancel_gives_cancelled_with_estimated_cost(idx, tmp_path):
    db, _ = idx

    def slow(request, n):
        return AskScript(chunks=[(0.0, "Partial answer "), (5.0, "never arrives")], model=request["model"])

    async def go():
        rt, em, _ = make(FakeAskClient(slow))
        await rt.handle(start_msg(db, tmp_path / "c.jsonl"))
        await rt.handle({"type": "ask", "id": "q1", "text": "long one"})
        for _ in range(100):
            await asyncio.sleep(0.01)
            if em.of("ask_delta"):
                break
        await rt.handle({"type": "control", "action": "cancel"})
        return em

    done = run(go()).of("ask_done")[0]
    assert done["stop_reason"] == "cancelled" and done["cost_estimated"] is True
    assert done["usage"]["output"] == -(-len("Partial answer ") // 4)


@pytest.mark.parametrize("exc, kind", [(CreditExhausted("402 billing_error"), "credit_exhausted"), (Offline("APIConnectionError"), "offline"),
                                       (RateLimited("429 rate_limit", retry_after=12.0), "rate_limited")])
def test_errors_map_to_ask_error_kinds(idx, tmp_path, exc, kind):
    db, _ = idx

    async def go():
        rt, em, _ = make(FakeAskClient(lambda r, n: AskScript(error=exc)))
        chat = tmp_path / "c.jsonl"
        await rt.handle(start_msg(db, chat))
        await ask_and_wait(rt, "q1", "x?")
        return em, chat

    em, chat = run(go())
    err = em.of("ask_error")[0]
    assert err["kind"] == kind and err["id"] == "a1" and not em.of("ask_done")
    assert [x["type"] for x in chat_lines(chat)] == ["q", "a_error"]


def test_bad_starts_are_status_errors(idx, tmp_path):
    db, _ = idx

    async def go(msg):
        rt, em, _ = make()
        await rt.handle(msg)
        await rt.handle({"type": "ask", "id": "q1", "text": "x?"})
        return em

    for bad in ({"type": "memory_ask_start", "db": str(tmp_path / "none.sqlite"), "chat": str(tmp_path / "c.jsonl"),
                 "scope": {"kind": "all"}},
                {"type": "memory_ask_start", "db": str(db), "chat": str(tmp_path / "c.jsonl"), "scope": {"kind": "weird"}},
                {"type": "memory_ask_start", "db": str(db)}):
        em = run(go(bad))
        assert em.of("status")[-1]["state"] == "error" and em.of("ask_error")[0]["kind"] == "bad_request"


def test_embedder_failure_leaves_fts_only(idx, tmp_path):
    """--fake embeds with the hash stand-in (no vectors in this index, so FTS carries the search) and a missing model is no error."""
    db, _ = idx

    async def go(**kw):
        em = ListEmitter()
        c = FakeAskClient()
        rt = MemoryAskRuntime(c, em, **kw)
        await rt.handle(start_msg(db, tmp_path / "c.jsonl"))
        await ask_and_wait(rt, "q1", "Rovigo gateway budget")
        return rt, c

    rt, c = run(go(fake=True))
    assert rt.embedder is not None and "Rovigo" in req_text(c.requests[0])
    rt, c = run(go(embed_model="/nonexistent/model.litertlm"))
    assert rt.embedder is None and "Rovigo" in req_text(c.requests[0])


# ---------------------------------------------------------------- privacy
def test_no_request_payload_contains_an_at_sign(idx, tmp_path):
    db, _ = idx
    ix = MemoryIndex.open(db)
    ix.con.execute("UPDATE sessions SET labels=? WHERE name='halden-kickoff'", (json.dumps(["Marta Velin", "marta@halden.example"]),))
    ix.close()

    async def go():
        rt, _, c = make()
        await rt.handle(start_msg(db, tmp_path / "c.jsonl"))
        await ask_and_wait(rt, "q1", "Who is at Halden Works? pilot budget")
        return c.requests[0]

    assert "@" not in req_text(run(go()))


def test_only_make_client_is_a_credential_source_in_the_new_modules():
    for rel in ("verse_brain/runtime/memory_ask.py", "verse_brain/memory/brief.py"):
        src = (BRAIN / rel).read_text(encoding="utf-8").lower()
        for forbidden in ("anthropic_auth_token", "auth_token", "oauth", "claude.ai", "environ", "getenv", "anthropic_api_key",
                          "read_api_key", "anthropic("):
            assert forbidden not in src, (rel, forbidden)


# ---------------------------------------------------------------- the process
def spawn(*args: str) -> subprocess.Popen:
    env = dict(os.environ)
    env["PYTHONPATH"] = str(BRAIN) + os.pathsep + env.get("PYTHONPATH", "")
    return subprocess.Popen([sys.executable, "-m", "verse_brain.runtime", *args], cwd=BRAIN, env=env, stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def test_process_mode_stdout_and_quiet_stderr(idx, tmp_path):
    db, keys = idx
    chat = tmp_path / "chats" / "all.jsonl"
    assert parse_line('{"type":"memory_ask_start","db":"x"}')["type"] == "memory_ask_start"
    assert parse_line('{"type":"brief_start","db":"x"}')["type"] == "brief_start"
    p = spawn("--fake", "--no-embed", "--log-level", "INFO")
    evs: list[dict] = []
    try:
        for m in (start_msg(db, chat), {"type": "ask", "id": "q1", "text": f"{SECRET_SENTENCE}?"}):
            p.stdin.write(json.dumps(m, ensure_ascii=False) + "\n")
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
        err = p.stderr.read()
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)
    assert evs[1]["state"] == "ready" and evs[1]["context"]["mode"] == "memory" and evs[1]["context"]["sessions"] == 5
    done = evs[-1]
    assert done["type"] == "ask_done" and done["citations"] == [] or all(c["kind"] for c in done["citations"])
    assert SECRET_SENTENCE not in err and "ahtapot" not in err and "Rovigo" not in err and "Marta" not in err
    assert chat_lines(chat)[0]["scope"] == "all"


def test_meeting_brain_ignores_memory_messages(tmp_path):
    from verse_brain.runtime.engine import Brain
    from verse_brain.runtime.fake import FakeTransport
    from verse_brain.runtime.settings import Config

    async def go():
        em = ListEmitter()
        b = Brain(FakeTransport(), em, Config())
        for t in ("memory_ask_start", "brief_start"):
            await b.handle({"type": t, "db": "x"})
        return em.events

    assert run(go()) == []


# ---------------------------------------------------------------- live (opt-in, see the P3 live check)
@pytest.mark.skipif(os.environ.get("VERSE_LIVE") != "1", reason="live: VERSE_LIVE=1 (Keychain key, spends cents)")
def test_live_memory_ask(idx, tmp_path):
    db, keys = idx

    async def go():
        em = ListEmitter()
        rt = MemoryAskRuntime(make_client(), em, no_embed=True)
        await rt.handle(start_msg(db, tmp_path / "all.jsonl"))
        await ask_and_wait(rt, "q1", "Who promised to send what to Halden Works, and by when?")
        await rt.shutdown()
        return em

    em = run(go())
    done = em.of("ask_done")
    assert done and done[0]["cost_usd"] < 0.2 and done[0]["citations"]
