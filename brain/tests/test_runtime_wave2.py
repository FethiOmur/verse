"""Review wave 2 (REVIEW_2026-11-11.md, review-py.md): regression tests for Q2, Q3, M3, P1, P7 and P6.

Q2  size.py     a real question that merely contains a logistics phrase is not small talk
Q3  repeat.py   two lines that carry different figures are not a repeat
M3  transport   raw httpx2 transport errors in the middle of a stream map to Offline
P1  ask.py      a failure while building the request still ends the answer with ask_error
P7  me.py       an unreadable or malformed profile side file does not raise
P6  indexer.py  an engine that fails to load, or has no model hash, is closed and the indexer goes on without embeddings
"""

from __future__ import annotations

import asyncio
import json
import shutil
import sqlite3
from pathlib import Path

import httpx2
import pytest

from test_memory_index import put_all
from test_runtime_ask import ask_and_wait, make as make_ask, start_msg as ask_start_msg
from test_runtime_memory_ask import ask_and_wait as mem_ask_and_wait, make as make_mem, start_msg as mem_start_msg
from verse_brain.memory.index import MemoryIndex
from verse_brain.memory.indexer import IndexRuntime
from verse_brain.runtime.me import load_me
from verse_brain.runtime.protocol import ListEmitter
from verse_brain.runtime.repeat import find_repeat
from verse_brain.runtime.size import card_size
from verse_brain.runtime.transport import Offline, TransportError, map_sdk_error

FIX = Path(__file__).resolve().parent / "fixtures"


def run(coro):
    return asyncio.run(coro)


# ------------------------------------------------------------------------------------------------------------------ Q2
@pytest.mark.parametrize("text", [
    "Can you see yourself working here in five years?",
    "Do you see any risks in this approach?",
    "Did you see the results from the pilot?",
    "Va bene, quanto costava al mese?",
    "One second, what is your notice period?",
    "Is that okay, and what would you change?",
])
def test_a_real_question_with_a_logistics_phrase_is_not_short(text):
    assert card_size(text) != "short"


@pytest.mark.parametrize("text", [
    "Can you hear me?", "Yes, can you hear me okay?", "One second", "Just a moment", "Sorry, one sec please", "Is that okay?",
    "Can you see my screen?", "Are you ready to start", "Does that make sense?", "Is the audio okay?", "uh, do you hear it",
    "Mi senti?", "Va bene?", "Beni duyuyor musunuz", "Sesim geliyor mu?", "Hi, how are you?", "Hello Alex, how are you?",
])
def test_the_turn_that_is_only_the_phrase_stays_short(text):
    assert card_size(text) == "short"


def test_a_greeting_in_front_of_a_real_question_is_not_small_talk():
    assert card_size("Hello, what is your salary expectation") != "short"


# ------------------------------------------------------------------------------------------------------------------ Q3
@pytest.mark.parametrize("text,ref", [
    ("It cost 1,900 euros per month.", "It saved 9,500 euros per month."),
    ("Line items reached 91 percent accuracy.", "Totals reached 96.4 percent accuracy."),
])
def test_two_lines_with_different_figures_are_not_a_repeat(text, ref):
    assert find_repeat(text, [ref]) is None


def test_different_figures_beat_the_embedding_rule_too():
    text, ref = "It cost 1,900 euros per month.", "It saved 9,500 euros per month."
    assert find_repeat(text, [ref], {text: [1.0, 0.0], ref: [1.0, 0.0]}) is None


def test_the_same_figures_and_lines_without_figures_still_repeat():
    a = "The pilot reached 91 percent accuracy on line items."
    assert find_repeat(a, ["Line items reached 91 percent accuracy in the pilot."]) is not None
    assert find_repeat("Accuracy on line items reached a high mark in the pilot.",
                       ["The pilot reached a high mark of accuracy on line items."]) is not None
    assert find_repeat("The pilot reached 91 percent accuracy.", ["The pilot reached a high accuracy."]) is not None, \
        "only one line has a figure: the lexical rule decides as before"


def test_a_later_reference_is_still_checked_after_one_with_other_figures():
    text = "The pilot reached 91 percent accuracy on line items."
    refs = ["The pilot reached 96 percent accuracy on line items.", "Line items reached 91 percent accuracy in the pilot."]
    hit = find_repeat(text, refs)
    assert hit is not None and hit[0] == refs[1]


# ------------------------------------------------------------------------------------------------------------------ M3
@pytest.mark.parametrize("exc", [
    httpx2.ReadError("x"), httpx2.RemoteProtocolError("x"), httpx2.ReadTimeout("x"), httpx2.ConnectError("x"),
    httpx2.WriteError("x"), httpx2.PoolTimeout("x"), httpx2.TransportError("x"), httpx2.TimeoutException("x"),
])
def test_raw_httpx_transport_errors_map_to_offline(exc):
    e = map_sdk_error(exc)
    assert isinstance(e, Offline) and e.kind == "offline"


def test_other_exceptions_stay_a_generic_transport_error():
    e = map_sdk_error(ValueError("x"))
    assert type(e) is TransportError and e.kind == "error"
    assert map_sdk_error(httpx2.DecodingError("x")).kind == "error", "a decoding error is not a connection problem"


# ------------------------------------------------------------------------------------------------------------------ P1
def _types(em):
    return [e["type"] for e in em.events]


def test_ask_build_request_failure_ends_with_ask_error(tmp_path):
    async def go():
        rt, em, c, d = make_ask(tmp_path)
        await rt.handle(ask_start_msg(d))

        def boom(*a, **k):
            raise sqlite3.OperationalError("database is locked")

        rt.build_request = boom
        await ask_and_wait(rt, "q1", "What did Lena ask about authoring?")
        return em, c

    em, c = run(go())
    errs = em.of("ask_error")
    assert len(errs) == 1 and errs[0]["id"] == "a1" and errs[0]["q"] == "q1" and errs[0]["kind"] == "error"
    assert errs[0]["message"] == "OperationalError"
    assert "ask_done" not in _types(em) and not c.requests, "no model call was made"


def test_ask_still_answers_after_a_failed_build(tmp_path):
    async def go():
        rt, em, c, d = make_ask(tmp_path)
        await rt.handle(ask_start_msg(d))
        real = rt.build_request
        calls = {"n": 0}

        def flaky(*a, **k):
            calls["n"] += 1
            if calls["n"] == 1:
                raise sqlite3.OperationalError("database is locked")
            return real(*a, **k)

        rt.build_request = flaky
        await ask_and_wait(rt, "q1", "What did Lena ask about authoring?")
        await ask_and_wait(rt, "q2", "What did Lena ask about authoring?")
        return em

    em = run(go())
    assert [e["q"] for e in em.of("ask_error")] == ["q1"] and [e["q"] for e in em.of("ask_done")] == ["q2"]


@pytest.fixture
def mem_idx(tmp_path):
    path = tmp_path / "memory" / "index.sqlite"
    ix = MemoryIndex.open(path)
    put_all(ix)
    ix.close()
    return path


def test_memory_ask_build_request_failure_ends_with_ask_error(tmp_path, mem_idx):
    async def go():
        rt, em, c = make_mem()
        await rt.handle(mem_start_msg(mem_idx, tmp_path / "chat.jsonl"))

        def boom(*a, **k):
            raise sqlite3.OperationalError("database is locked")

        rt.build_request = boom
        await mem_ask_and_wait(rt, "q1", "What did Marta say about the pilot?")
        return em, c

    em, c = run(go())
    errs = em.of("ask_error")
    assert len(errs) == 1 and errs[0]["q"] == "q1" and errs[0]["message"] == "OperationalError"
    assert "ask_done" not in _types(em) and not c.requests


def test_memory_ask_citation_lookup_failure_still_ends_with_ask_done(tmp_path, mem_idx, monkeypatch):
    from verse_brain.runtime import memory_ask as mem_mod

    def boom(*a, **k):
        raise sqlite3.OperationalError("database is locked")

    async def go():
        rt, em, c = make_mem()
        await rt.handle(mem_start_msg(mem_idx, tmp_path / "chat.jsonl"))
        monkeypatch.setattr(mem_mod, "resolve_citations", boom)
        await mem_ask_and_wait(rt, "q1", "What did Marta say about the pilot?")
        return em

    em = run(go())
    assert [e["q"] for e in em.of("ask_done")] == ["q1"] and em.of("ask_done")[0]["citations"] == []
    assert not em.of("ask_error")


# ------------------------------------------------------------------------------------------------------------------ P7
def _profile(tmp_path: Path) -> Path:
    d = tmp_path / "profile"
    shutil.copytree(FIX / "me" / "profile", d)
    return d


def _spec(d: Path) -> dict:
    return {"core": str(d / "me.md"), "library": str(d / "me.library.jsonl"), "facts": str(d / "me.facts.jsonl")}


def test_the_fixture_profile_loads_with_library_and_facts(tmp_path):
    layer = load_me(_spec(_profile(tmp_path)))
    assert layer is not None and layer.chunks and layer.facts


@pytest.mark.parametrize("name", ["me.library.jsonl", "me.facts.jsonl"])
def test_a_non_utf8_library_or_facts_file_does_not_raise(tmp_path, name):
    d = _profile(tmp_path)
    (d / name).write_bytes(b'{"id": "x", "text": "caf\xe9"}\n\xff\xfe\x00')
    layer = load_me(_spec(d))
    assert layer is not None, "the core file is fine: the layer loads"
    assert (layer.chunks if name == "me.library.jsonl" else layer.facts) == []


def test_an_unreadable_side_file_does_not_raise(tmp_path):
    d = _profile(tmp_path)
    (d / "me.library.jsonl").unlink()
    (d / "me.library.jsonl").mkdir()          # a directory where the file should be: is_file() is False, read would be EISDIR
    (d / "me.facts.jsonl").chmod(0)
    try:
        layer = load_me(_spec(d))
    finally:
        (d / "me.facts.jsonl").chmod(0o644)
    assert layer is not None and layer.chunks == [] and layer.facts == []


@pytest.mark.parametrize("raw", ["[1, 2]", '"text"', "42", "null"])
def test_a_non_dict_meta_file_does_not_raise(tmp_path, raw):
    d = _profile(tmp_path)
    (d / "me.meta.json").write_text(raw, encoding="utf-8")
    layer = load_me(_spec(d))
    assert layer is not None and layer.built_at == "" and layer.tokens >= 1


def test_a_non_utf8_core_file_is_none(tmp_path):
    d = _profile(tmp_path)
    (d / "me.md").write_bytes(b"\xff\xfe\x00bad")
    assert load_me(_spec(d)) is None


# ------------------------------------------------------------------------------------------------------------------ P6
class FakeEngine:
    instances: list = []

    def __init__(self, *a, **k):
        self.closed = 0
        FakeEngine.instances.append(self)

    def embed(self, text):
        return [1.0, 0.0]

    def close(self):
        self.closed += 1


def _indexer(monkeypatch, *, sha, engine=FakeEngine):
    from verse_brain.runtime import embed as embed_mod, me as me_mod

    FakeEngine.instances = []
    monkeypatch.setattr(embed_mod, "LiteRtEmbedder", engine)
    monkeypatch.setattr(me_mod, "model_sha", sha)
    return IndexRuntime(ListEmitter(), embed_model="/models/none.litertlm")


def test_an_engine_without_a_model_hash_is_closed_and_dropped(monkeypatch):
    rt = _indexer(monkeypatch, sha=lambda p: None)
    rt._load_embedder()
    assert rt.embedder is None and rt._raw is None and rt.sha is None
    assert [e.closed for e in FakeEngine.instances] == [1]


def test_a_failing_hash_closes_the_engine_and_leaves_embeddings_off(monkeypatch):
    def bad_sha(p):
        raise PermissionError("denied")

    rt = _indexer(monkeypatch, sha=bad_sha)
    rt._load_embedder()
    assert rt.embedder is None and rt._raw is None and [e.closed for e in FakeEngine.instances] == [1]


def test_an_engine_that_fails_with_another_error_leaves_embeddings_off(monkeypatch):
    class Boom:
        def __init__(self, *a, **k):
            raise RuntimeError("native crash")

    rt = _indexer(monkeypatch, sha=lambda p: "abc", engine=Boom)
    rt._load_embedder()
    assert rt.embedder is None and rt._raw is None and rt.sha is None


def test_a_working_engine_with_a_hash_is_kept(monkeypatch):
    rt = _indexer(monkeypatch, sha=lambda p: "abc")
    rt._load_embedder()
    assert rt.embedder is not None and rt.sha == "abc" and [e.closed for e in FakeEngine.instances] == [0]
