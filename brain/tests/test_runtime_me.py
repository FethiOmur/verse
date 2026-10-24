"""The me layer at run time: the ABOUT ALEX RIVERA block and its cache layout, conflicts with the pack, library retrieval on the
embedding thread (F never waits, D waits at most 150 ms), the golden request without the layer, and the local fallback prompt.

Fictional person (Dana Reyes) only; the embedder is a fake whose cosines are set exactly."""

from __future__ import annotations

import asyncio
import json
import math
import shutil
import threading
import time
from pathlib import Path

import pytest
from test_runtime_fallback import FakeBackend
from test_runtime_helpers import FIX, exchange, rolling_calls, run, settle, turn  # noqa: F401

from verse_brain.runtime import local_llm as ll
from verse_brain.runtime.embed import PREFIX
from verse_brain.runtime.engine import Brain
from verse_brain.runtime.fake import FakeTransport, default_responder
from verse_brain.runtime.local_llm import LocalGemma
from verse_brain.runtime.me import Chunk, Hit, conflicts, load_me, model_sha, select_hits, write_emb
from verse_brain.runtime.prompt import NO_PACK_LINE, Turn, build_request, fast_tail, render_about_block
from verse_brain.runtime.protocol import ListEmitter
from verse_brain.runtime.settings import Config, route_params

ME_DIR = Path(__file__).resolve().parent / "fixtures" / "me"
PROFILE = ME_DIR / "profile"
GOLDEN = json.loads((ME_DIR / "golden_requests.json").read_text(encoding="utf-8"))


def me_spec(d: Path = PROFILE) -> dict:
    return {"core": str(d / "me.md"), "library": str(d / "me.library.jsonl"), "facts": str(d / "me.facts.jsonl")}


def bytes_of(obj) -> str:
    return json.dumps(obj, sort_keys=True, ensure_ascii=False)


def profile_copy(tmp_path: Path) -> Path:
    dst = tmp_path / "profile"
    shutil.copytree(PROFILE, dst)
    return dst


_SEQ = iter(range(10 ** 6))


def session_dir(tmp_path: Path, pack: str = "", *, name: str = "adhoc", bank: bool = False) -> Path:
    """A session folder: the runtime fixture's pack and bank (`bank`), or an empty pack (an unprepared call)."""
    d = tmp_path / f"{name}-{next(_SEQ)}"
    d.mkdir()
    if bank:
        shutil.copy(FIX / "bank.jsonl", d / "bank.jsonl")
    (d / "pack.md").write_text(pack if pack else ((FIX / "pack.md").read_text(encoding="utf-8") if bank else ""), encoding="utf-8")
    (d / "meta.json").write_text(json.dumps({"session_id": name, "kind": "adhoc"}), encoding="utf-8")
    return d


class LibEmbedder:
    """Cosines set exactly (a background of 0.80 between unrelated texts, like the real model's): a library chunk adds its own
    axis; a query matching a rule (lower-case substring) gets the given cosine with each listed chunk and 0.80 with the rest."""

    BASE = 0.8

    def __init__(self, chunks: list[Chunk], rules: list[tuple[str, dict[str, float]]], delay: float = 0.0) -> None:
        self.ids = [c.id for c in chunks]
        self.docs = {c.text: c.id for c in chunks}
        self.rules, self.delay = rules, delay
        self.queries: list[str] = []
        self.doc_calls = 0
        self.threads: set[str] = set()
        self._c, self._own = math.sqrt(self.BASE), math.sqrt(1 - self.BASE)

    def _doc(self, cid: str) -> list[float]:
        return [self._c] + [self._own if i == cid else 0.0 for i in self.ids] + [0.0]

    def _query(self, scores: dict[str, float]) -> list[float]:
        b = [(scores.get(i, self.BASE) - self.BASE) / self._own for i in self.ids]
        rest = 1 - self.BASE - sum(x * x for x in b)
        assert rest >= 0, scores
        return [self._c] + b + [math.sqrt(rest)]

    def embed(self, text: str) -> list[float]:
        self.threads.add(threading.current_thread().name)
        body = text[len(PREFIX):] if text.startswith(PREFIX) else text
        if body in self.docs:
            self.doc_calls += 1
            return self._doc(self.docs[body])
        if body.startswith("task:") or not any(sub in body.lower() for sub, _ in self.rules):
            return self._query({})
        self.queries.append(body)
        if self.delay:
            time.sleep(self.delay)
        low = body.lower()
        for sub, scores in self.rules:
            if sub in low:
                return self._query(scores)
        return self._query({})

    def close(self) -> None:
        pass


def layer_chunks() -> list[Chunk]:
    return load_me(me_spec()).chunks


RULE = [("reconcil", {"c1a0001": 0.93, "c1a0003": 0.84, "c1a0002": 0.70})]
RULE3 = [("reconcil", {"c1a0001": 0.93, "c1a0003": 0.90, "c1a0002": 0.85})]


def make(tmp_path: Path, *, rules=None, delay: float = 0.0, embedder: bool = True, responder=None, **cfg):
    model = tmp_path / "embed-model.bin"
    if not model.exists():
        model.write_bytes(b"fake embedding model")
    cfg.setdefault("embed_model", str(model))
    t = FakeTransport(responder or default_responder)
    em = ListEmitter()
    emb = LibEmbedder(layer_chunks(), rules if rules is not None else RULE, delay)
    b = Brain(t, em, Config(**cfg), embedder_factory=(lambda: emb) if embedder else None)
    b.start_background = False
    return b, t, em, emb


async def start(b: Brain, sdir: Path, **extra) -> None:
    await b.handle({"type": "start", "session_dir": str(sdir), "lang": "en", **extra})


async def until(pred, timeout: float = 3.0) -> None:
    end = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < end:
        if pred():
            return
        await asyncio.sleep(0.01)
    raise AssertionError("condition not reached")


async def lib_ready(b: Brain) -> None:
    await until(lambda: b.lib is not None and b.lib.ready)


def bp_count(req: dict) -> int:
    return (sum(1 for b in req["system"] if "cache_control" in b)
            + sum(1 for b in req["messages"][0]["content"] if "cache_control" in b))


# ---------------------------------------------------------------- start.me null: today's requests, byte for byte
def test_without_the_layer_requests_are_what_they_were(tmp_path):
    async def go(extra):
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, FIX, **extra)
        await turn(b, "r1", "how did you build the invoice pipeline?")
        await settle(b)
        await turn(b, "m1", "my answer one", speaker="me")
        await turn(b, "r2", "and what about the cost per month?")
        await settle(b)
        return t

    for extra in ({}, {"me": None}, {"me": None, "mode": "prepared", "route": "meeting", "room_auto": "questions"}):
        t = run(go(extra))
        got = {"F1": t.by_route("F")[0].request, "D1": t.by_route("D")[0].request, "F2": t.by_route("F")[1].request,
               "create_S": t.creates[0]["request"], "create_D": t.creates[1]["request"]}
        assert bytes_of(got) == bytes_of(GOLDEN), extra
        assert len(got["F1"]["system"]) == 1 and bp_count(got["F1"]) == 1


# ---------------------------------------------------------------- the ABOUT ALEX RIVERA block and the cache layout
def test_about_block_is_the_second_system_block_and_every_request_shares_it(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, FIX, me=me_spec())
        for i in range(5):
            await exchange(b, i)
        await settle(b)
        await b._warm("claude-haiku-5-5", "keepalive")
        return b, t, em

    b, t, em = run(go())
    about = load_me(me_spec()).about_block((FIX / "pack.md").read_text(encoding="utf-8"))   # this pack has no style guide: the voice is in
    assert "## STYLE GUIDE" in about
    reqs = [c.request for c in t.calls] + [c["request"] for c in t.creates]
    assert len(reqs) > 10
    for r in reqs:
        assert len(r["system"]) == 2 and r["system"][1]["text"] == about
        assert r["system"][1]["cache_control"] == {"type": "ephemeral"}
        assert "cache_control" not in r["system"][0]
        assert bp_count(r) <= 4
    # the system text of a route is one string for the whole session, and S/F (and the pre-warm of Haiku) share it
    for route in ("F", "D"):
        assert len({bytes_of(c.request["system"]) for c in t.by_route(route)}) == 1
    assert "ABOUT ALEX RIVERA" in reqs[0]["system"][0]["text"] and "MEETING PACK wins" in reqs[0]["system"][0]["text"]
    assert "[m401]" in about and "Harbor Ledger processed about 41,000" in about
    # 3 breakpoints with a pack: ABOUT ALEX RIVERA, the pack block and a finalized turn (after 4 turns)
    late = t.by_route("F")[-1].request
    assert bp_count(late) == 3
    # the ready status says what the layer is
    ready = [e for e in em.of("status") if e["state"] == "ready"][0]
    assert ready["me"] == {"tokens": 640, "built_at": "2026-10-16T09:00:00+00:00"}


def test_about_block_is_byte_identical_across_sessions_and_has_no_per_run_values(tmp_path):
    async def one(name):
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path, name=name, bank=True), me=me_spec())
        await turn(b, "r1", "how did you build the invoice pipeline?")
        await settle(b)
        return t.by_route("F")[0].request["system"]

    a, b2 = run(one("s1")), run(one("s2"))
    assert bytes_of(a) == bytes_of(b2)
    text = a[1]["text"]
    for per_run in ("s1", "s2", str(tmp_path), "2026-10-16"):
        assert per_run not in text


def test_style_guide_goes_into_the_block_only_when_the_pack_has_none(tmp_path):
    core = (PROFILE / "me.md").read_text(encoding="utf-8")
    layer = load_me(me_spec())
    assert layer.voice and "### Tone" in layer.voice
    with_voice = layer.about_block("## FACTS\n[f001] ...\n")
    assert with_voice == render_about_block(core, layer.voice) and "## STYLE GUIDE" in with_voice
    assert "## STYLE GUIDE" not in layer.about_block("## FACTS\n\n## STYLE GUIDE (how to speak)\n### Tone\n- x\n")
    # unprepared: the pack is empty, so the block carries the voice
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), mode="unprepared", me=me_spec())
        await turn(b, "r1", "tell me about the project you are proudest of")
        await settle(b)
        return t.by_route("F")[0].request

    req = run(go())
    assert "## STYLE GUIDE" in req["system"][1]["text"]


def test_empty_pack_is_the_fixed_line_and_still_three_breakpoints(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), mode="unprepared", me=me_spec())
        for i in range(3):
            await exchange(b, i)
        await settle(b)
        return t

    t = run(go())
    for route in ("S", "F", "D"):
        for c in t.by_route(route):
            assert NO_PACK_LINE in c.request["messages"][0]["content"][0]["text"]
            assert bp_count(c.request) <= 4
    late = t.by_route("F")[-1].request
    assert bp_count(late) == 3
    assert late["messages"][0]["content"][0]["text"] == f"MEETING PACK\n\n{NO_PACK_LINE}\n## TRANSCRIPT SO FAR (finalized turns follow, one block each)\n"
    # an empty pack without the layer is the same fixed line, with the unprepared rule in the system text and one block
    async def bare():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path, name="adhoc2"), mode="unprepared")
        await turn(b, "r1", "tell me about yourself please")
        await settle(b)
        return t.by_route("F")[0].request

    r = run(bare())
    assert len(r["system"]) == 1 and "(none: unprepared call)" in r["system"][0]["text"] and bp_count(r) == 1


def test_missing_files_give_a_notice_and_the_session_runs_without_the_layer(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, FIX, me={"core": str(tmp_path / "nope" / "me.md"), "library": "x", "facts": "y"})
        await turn(b, "r1", "how did you build the invoice pipeline?")
        await settle(b)
        return t, em

    t, em = run(go())
    assert [e["kind"] for e in em.of("notice")] == ["me_missing"]
    assert len(t.by_route("F")[0].request["system"]) == 1
    ready = [e for e in em.of("status") if e["state"] == "ready"][0]
    assert ready["me"] is None


# ---------------------------------------------------------------- conflicts with the pack
PACK_38K = "## FACTS\n[f001] number | Harbor Ledger handled 38,000 payments per month. | 38000 | prep:L4\n"


def test_conflicts_a_differing_number_on_a_shared_label_gives_one_item():
    facts = load_me(me_spec()).facts
    items = conflicts(facts, PACK_38K)
    assert items == [{"me": "m401", "pack": "f001", "topic": "Harbor Ledger handled 38,000 payments per month."}]
    # equal numbers: none; labels that share too little: none; a conflicted pack fact (no value) is skipped
    assert conflicts(facts, PACK_38K.replace("38,000", "41,000").replace("38000", "41000")) == []
    assert conflicts(facts, "## FACTS\n[f001] number | Lantern cut data entry from 11 minutes to 2 minutes. | 2 | prep:L1\n") == []
    assert conflicts(facts, "## FACTS\n[f001] number | Harbor Ledger payments | conflicting in sources: 38,000 (a) vs 41,000 (b)\n") == []
    assert conflicts(facts, "") == []


def test_conflicts_notice_after_start(tmp_path):
    async def go(pack):
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path, pack, name="s" + str(abs(hash(pack)))), me=me_spec())
        return em

    em = run(go(PACK_38K))
    n = em.of("notice", kind="me_conflicts")
    assert len(n) == 1 and n[0]["items"] == [{"me": "m401", "pack": "f001", "topic": "Harbor Ledger handled 38,000 payments per month."}]
    assert run(go(PACK_38K.replace("38,000", "41,000").replace("38000", "41000"))).of("notice") == []


# ---------------------------------------------------------------- retrieval
def hits_in(tail: str) -> list[str]:
    return [l.split("]")[0][len("[lib:"):] for l in tail.splitlines() if l.startswith("[lib:")]


QUESTION = "how did you handle the bank reconciliation matching work"
FINAL = QUESTION + " in that project and how did it go"      # more than 3 words away from the partial: S is not the answer, F is


async def ask(b: Brain, em: ListEmitter, text: str = FINAL) -> None:
    """A cue partial (so a retrieval runs), then the turn: F answers with the hits of the partial."""
    await b.handle({"type": "partial", "turn_id": "r1", "speaker": "remote", "text": QUESTION, "cue": True, "t_audio_end": 0.0})
    await until(lambda: em.of("metric", stage="me_retrieval"))
    await turn(b, "r1", text)
    await settle(b)


def test_top_chunks_above_the_floor_reach_the_tail_in_score_order(tmp_path):
    async def go():
        b, t, em, emb = make(tmp_path)
        await start(b, session_dir(tmp_path), mode="unprepared", me=me_spec())
        await lib_ready(b)
        await ask(b, em)
        return t, em, emb

    t, em, emb = run(go())
    m = em.of("metric", stage="me_retrieval")[0]
    assert m["hits"] == 2 and m["ids"] == ["c1a0001", "c1a0003"] and m["top"] == pytest.approx(0.93, abs=1e-3) and m["ms"] >= 0
    f = t.by_route("F")[0]
    assert hits_in(f.tail) == ["c1a0001", "c1a0003"]                       # below the floor (0.70): not there
    assert "FROM ALEX RIVERA'S FILES" in f.tail and f.tail.splitlines()[-1].startswith("CURRENT QUESTION")
    assert "[lib:c1a0001] (Harbor Ledger.md)" in f.tail
    assert emb.threads and all(n.startswith("verse-embed") for n in emb.threads)                                  # on the embedding thread, never on the loop


def test_a_speculative_call_fired_after_the_first_retrieval_carries_the_chunks(tmp_path):
    async def go():
        b, t, em, emb = make(tmp_path, s_min_gap_s=0.0)
        await start(b, session_dir(tmp_path), mode="unprepared", me=me_spec())
        await lib_ready(b)
        await b.handle({"type": "partial", "turn_id": "r1", "speaker": "remote", "text": QUESTION, "cue": True, "t_audio_end": 0.0})
        await until(lambda: em.of("metric", stage="me_retrieval"))
        await b.handle({"type": "partial", "turn_id": "r1", "speaker": "remote", "text": FINAL, "cue": True, "t_audio_end": 0.0})
        await settle(b)
        return t

    s = run(go()).by_route("S")
    assert len(s) == 2 and "FROM ALEX RIVERA'S FILES" not in s[0].tail and hits_in(s[1].tail) == ["c1a0001", "c1a0003"]


def test_prepared_sessions_get_two_chunks_and_unprepared_three(tmp_path):
    async def go(prepared):
        b, t, em, emb = make(tmp_path, rules=RULE3)
        sd = session_dir(tmp_path, name="p" if prepared else "u", bank=prepared)
        await start(b, sd, me=me_spec(), **({} if prepared else {"mode": "unprepared"}))
        await lib_ready(b)
        await ask(b, em)
        return t

    assert hits_in(run(go(True)).by_route("F")[0].tail) == ["c1a0001", "c1a0003"]
    assert hits_in(run(go(False)).by_route("F")[0].tail) == ["c1a0001", "c1a0003", "c1a0002"]


def test_chunks_whose_source_is_a_pack_snippet_are_skipped(tmp_path):
    pack = (FIX / "pack.md").read_text(encoding="utf-8").replace(
        "## SNIPPETS\n", "## SNIPPETS\n[s001] vault:300-Projects/Harbor Ledger/Harbor Ledger.md | Reconciliation notes of the project.\n")

    async def go():
        b, t, em, emb = make(tmp_path, rules=RULE3)
        await start(b, session_dir(tmp_path, pack, name="snip", bank=True), me=me_spec())
        await lib_ready(b)
        await ask(b, em)
        return t

    t = run(go())
    assert hits_in(t.by_route("F")[0].tail) == ["c1a0003", "c1a0002"]
    # the unit: the same rule on its own
    ch = layer_chunks()
    sel = select_hits([Hit(ch[0], 0.9), Hit(ch[1], 0.85)], {"vault:300-projects/harbor ledger/harbor ledger.md"}, 3, 4800)
    assert [h.chunk.id for h in sel] == ["c1a0002"]


def test_f_never_waits_for_retrieval_and_d_waits_at_most_150_ms(tmp_path):
    async def go(delay):
        b, t, em, emb = make(tmp_path, delay=delay)
        await start(b, session_dir(tmp_path, name=f"w{int(delay * 100)}"), mode="unprepared", me=me_spec())
        await lib_ready(b)
        t0 = time.monotonic()
        await turn(b, "r1", QUESTION)                      # no partials: only the final-text retrieval exists
        await settle(b, 5.0)
        f, d = t.by_route("F")[0], t.by_route("D")[0]
        return f, d, d.t_open - t0, em, t0, f.t_open - t0

    # slow retrieval (0.6 s): F had nothing and did not wait; D gave up after ~150 ms and also has nothing
    f, d, d_at, em, _, f_at = run(go(0.6))
    assert f_at < 0.05 and "FROM ALEX RIVERA'S FILES" not in f.tail and "FROM ALEX RIVERA'S FILES" not in d.tail
    assert 0.14 <= d_at < 0.5
    w = em.of("metric", stage="me_final_wait")[0]
    assert w["got"] is False and 140 <= w["ms"] < 400
    # fast retrieval (50 ms): F still had nothing (it fires at the endpoint), D waited for it and has the chunks
    f, d, d_at, em, _, f_at = run(go(0.05))
    assert f_at < 0.04 and "FROM ALEX RIVERA'S FILES" not in f.tail
    assert hits_in(d.tail) == ["c1a0001", "c1a0003"] and 0.04 <= d_at < 0.15
    assert em.of("metric", stage="me_final_wait")[0]["got"] is True


def test_vectors_file_is_used_when_it_matches_the_model_and_the_chunks_are_embedded_otherwise(tmp_path):
    prof = profile_copy(tmp_path)

    async def go(wrote: bool):
        b, t, em, emb = make(tmp_path)
        model = Path(b.config.embed_model)
        if wrote:                                         # vectors made by "build" for this very model
            ch = load_me(me_spec(prof)).chunks
            e0 = LibEmbedder(ch, [])
            from verse_brain.runtime.embed import unit
            write_emb(prof / "me.library.emb", [c.id for c in ch], [unit(e0.embed(PREFIX + c.text)) for c in ch], model_sha(model))
        sd = session_dir(tmp_path, name="v" + str(wrote))
        await start(b, sd, mode="unprepared", me=me_spec(prof))
        await lib_ready(b)
        return em, emb

    em, emb = run(go(False))
    assert emb.doc_calls == 3 and em.of("metric", stage="me_library_ready")[0]["embedded_now"] == 3
    (prof / "me.library.emb").unlink(missing_ok=True)
    em, emb = run(go(True))
    assert emb.doc_calls == 0                          # the stored vectors were enough
    assert em.of("metric", stage="me_library_ready")[0]["embedded_now"] == 0
    # vectors made with another model are ignored
    (prof / "me.library.emb").write_bytes(b'{"model_sha":"other","dim":2,"ids":["c1a0001"]}\n' + b"\0\0\0\0")
    em, emb = run(go(False))
    assert em.of("metric", stage="me_library_ready")[0]["embedded_now"] == 3


def test_without_an_embedder_the_core_still_works(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), mode="unprepared", me=me_spec())
        await turn(b, "r1", QUESTION)
        await settle(b)
        return b, t

    b, t = run(go())
    assert b.lib is None and "FROM ALEX RIVERA'S FILES" not in t.by_route("F")[0].tail and len(t.by_route("F")[0].request["system"]) == 2


def test_follow_card_tail_names_the_me_layer_as_grounding_only_when_it_is_on():
    from verse_brain.runtime.prompt import follow_tail

    args = ("what did you build?", "en", "I built a service", ["SAY: x", "- y"], [], None, "diverged")
    off, on = follow_tail(*args), follow_tail(*args, me_on=True)
    assert follow_tail(*args, me_on=False) == off and "ABOUT ALEX RIVERA" not in off
    for sentence in ("must come from the meeting pack (bank, facts, evidence), ABOUT ALEX RIVERA or FROM ALEX RIVERA'S FILES",
                     "the meeting pack and ABOUT ALEX RIVERA have nothing grounded", "When none of them has anything for his topic"):
        assert sentence in on, sentence
    assert "the pack cannot support" not in on and "a point they cannot support" in on


# ---------------------------------------------------------------- the G1 fallback prompt
def big_about(sections: dict[str, int]) -> str:
    """A me.md-shaped ABOUT ALEX RIVERA block with `n` long lines per section (ids m0xx, m1xx, ... as in me.md)."""
    out = []
    for i, (name, n) in enumerate(sections.items()):
        out.append(f"## {name}")
        out += [f"[m{i * 100 + j + 1:03d}] {name.lower()} item {j} " + "detail " * 30 + "| file:x.md" for j in range(n)]
    return render_about_block("\n".join(out), None)


SECTION_COUNTS = {"WHO I AM": 3, "EXPERIENCE": 4, "PROJECTS": 6, "SKILLS": 8, "NUMBERS": 10, "STORIES": 6, "LOOKING FOR": 1}


def ids_in(text: str, prefix: str) -> list[str]:
    return [l[1:5] for l in text.splitlines() if l.startswith(f"[{prefix}")]


def test_local_prompt_with_a_pack_keeps_who_numbers_and_projects_in_3000_chars():
    out = ll.trim_me(big_about(SECTION_COUNTS), 3000, with_pack=True)
    assert len(out) <= 3000
    assert [l for l in out.splitlines() if l.startswith("## ")] == ["## WHO I AM", "## PROJECTS", "## NUMBERS"]
    assert len(ids_in(out, "m0")) == 3 and len(ids_in(out, "m4")) >= 3          # WHO I AM whole, NUMBERS first in the budget
    assert len(ids_in(out, "m2")) < 6                                            # PROJECTS gives way first
    assert "EXPERIENCE" not in out and "STORIES" not in out and "SKILLS" not in out


def test_local_prompt_unprepared_trims_in_the_build_order():
    block = big_about(SECTION_COUNTS)
    small = ll.trim_me(block, len(block) - 200, with_pack=False)               # a little over: only the last story goes
    assert ids_in(small, "m5") == [f"m50{j}" for j in range(1, 6)] and len(ids_in(small, "m3")) == 8
    more = ll.trim_me(block, len(block) - 2200, with_pack=False)               # all of STORIES' tail, then the tail of SKILLS
    assert ids_in(more, "m5") == ["m501"] and 0 < len(ids_in(more, "m3")) < 8
    assert len(ids_in(more, "m2")) == 6 and len(ids_in(more, "m1")) == 4          # PROJECTS and EXPERIENCE come after SKILLS
    for out in (small, more, ll.trim_me(block, 9500, with_pack=False)):
        assert len(ids_in(out, "m4")) == 10 and len(ids_in(out, "m0")) == 3       # NUMBERS and WHO I AM are never trimmed
    assert len(ll.trim_me(block, 9500, with_pack=False)) <= 9500
    # the STYLE GUIDE section stays whole and does not count against the budget
    styled = render_about_block("\n".join(["## WHO I AM", "[m001] x " * 20, "## STORIES"] + [f"[m5{j:02d}] " + "story " * 60 for j in range(6)]),
                                "### Tone\n- relaxed\n")
    out = ll.trim_me(styled, 600, with_pack=False)
    assert "## STYLE GUIDE" in out and "### Tone" in out


def test_gemma_gets_the_me_layer_inside_the_9500_char_prefix():
    block = big_about(SECTION_COUNTS)
    pack = (FIX / "pack.md").read_text(encoding="utf-8")
    be = FakeBackend()
    local = LocalGemma(Config(), backend=be)

    async def go():
        prepared = build_request("F", route_params("F"), pack, [], fast_tail("tell me about yourself", "en", True), block)
        async for _ in local.stream(prepared):
            pass
        unprepared = build_request("F", route_params("F"), "", [Turn("t0", "remote", "hi there")],
                                   fast_tail("tell me about yourself", "en", True), block)
        async for _ in local.stream(unprepared):
            pass
        await local.aclose()

    run(go())
    assert len(be.convs) == 2                                               # another frozen prefix: another conversation
    first = be.sent[0]
    assert first.startswith("ABOUT ALEX RIVERA") and len(first.split(ll.PACK_HEADER)[0]) <= 3002
    assert len(first.split(ll.TRANSCRIPT_HEADER)[0]) <= 9500
    second = be.sent[1]
    assert second.startswith("ABOUT ALEX RIVERA") and "(none: unprepared call)" in second
    assert len(second.split(ll.PACK_HEADER)[0]) <= 9500 + 2
    parts = ll.split_request(build_request("F", route_params("F"), pack, [], "tail", block))
    assert parts.me == block and parts.system.startswith("You are Verse") and "ABOUT ALEX RIVERA" in parts.system
    assert ll.split_request(build_request("F", route_params("F"), pack, [], "tail")).me == ""


# ---------------------------------------------------------------- the real model: where the floor sits
import os  # noqa: E402

from verse_brain.runtime.embed import DEFAULT_MODEL, LiteRtEmbedder, unit  # noqa: E402

_HAVE_MODEL = os.path.isfile(os.path.expanduser(DEFAULT_MODEL))
try:
    import litert_lm  # noqa: F401, E402
    _HAVE_LITERT = True
except ImportError:
    _HAVE_LITERT = False

# (question, the library chunks that answer it as (source, heading)); None = the files say nothing about it
REAL_QUERIES = [
    ("How did you handle matching bank lines to invoices when the reference was missing?", [("Harbor Ledger.md", "Notes")]),
    ("Tell me about the payments reconciliation service you led.", [("dana_profile.md", "Harbor Ledger"), ("Harbor Ledger.md", "Harbor Ledger"), ("Harbor Ledger.md", "Numbers")]),
    ("How many users does your hiking app have?", [("Trailhead.md", "Status")]),
    ("What does it cost to run Trailhead each month?", [("Trailhead.md", "Stack")]),
    ("What stack is Trailhead built on?", [("Trailhead.md", "Stack"), ("dana_profile.md", "Trailhead")]),
    ("Tell me about a production incident you dealt with.", [("dana_profile.md", "Incident story")]),
    ("Where have you worked before your current job?", [("dana_profile.md", "Work history")]),
    ("What kind of role are you looking for next?", [("dana_profile.md", "What Dana is looking for")]),
    ("How do you like to work with other people?", [("dana_profile.md", "How Dana works")]),
    ("What is your notice period at the moment?", None),
    ("Do you have experience with Kubernetes in production?", None),
    ("What are your salary expectations for this position?", None),
    ("How would you roll out a pilot of an LLM dispatcher across four countries?", None),
    ("Can you tell me a bit about yourself and your background?", None),
    ("What is the weather like where you live?", None),
    ("Why do you want to leave your current company?", None),
]


@pytest.mark.skipif(not (_HAVE_MODEL and _HAVE_LITERT), reason="EmbeddingGemma model or litert_lm missing")
def test_real_model_floor():
    """EmbeddingGemma's background similarity is high (unrelated texts sit near 0.75-0.80), so the floor matters: unrelated
    questions must stay under it and most answerable ones above (measured 16 Oct 2026: unrelated <= 0.797, answerable
    0.756-0.884, 6 of 9 above 0.81)."""
    from operator import mul

    from verse_brain.prep import me as M

    docs = [M.Doc(f"S{i + 1}", f"s{i + 1}", kind, f"{kind}:{f.name}", f.name, f.read_text(encoding="utf-8"))
            for i, (kind, f) in enumerate([("file", ME_DIR / "dana_profile.md"), ("vault", ME_DIR / "vault" / "Harbor Ledger.md"),
                                           ("vault", ME_DIR / "vault" / "Trailhead.md")])]
    chunks, _ = M.build_library(docs)
    where = {(c["source"], c["heading"]): c["id"] for c in chunks}
    try:
        e = LiteRtEmbedder(DEFAULT_MODEL, Config().embed_backend)
    except Exception as exc:  # noqa: BLE001 - no GPU in this environment
        pytest.skip(f"embedding engine not available: {type(exc).__name__}")
    try:
        vecs = {c["id"]: unit(e.embed(PREFIX + c["text"])) for c in chunks}
        floor = Config().me_retrieval_floor
        found = missed = 0
        for q, exp in REAL_QUERIES:
            qv = unit(e.embed(PREFIX + q))
            scores = {cid: sum(map(mul, qv, v)) for cid, v in vecs.items()}
            if exp is None:
                assert max(scores.values()) < floor, (q, max(scores.values()))      # nothing unrelated gets in
            else:
                want = {where[k] for k in exp}
                if max(scores[i] for i in want) >= floor:
                    found += 1
                else:
                    missed += 1
        assert found >= 5 and found + missed == 9, (found, missed)       # 6 of 9 on the GPU, 5 on the CPU backend
    finally:
        e.close()
