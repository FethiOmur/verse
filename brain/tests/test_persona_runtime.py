"""persona/runtime.py, compile.py and the CLI: one session's update end to end with a fake client, idempotence, spend, the
general prep import and the compiled output shape, the `persona_start` process mode and the backfill dry run. No network: the
client is FakeAskClient everywhere and the real client factory is made to fail."""

import asyncio
import hashlib
import json
import logging
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from verse_brain.memory.index import session_key
from verse_brain.persona import __main__ as cli
from verse_brain.persona.compile import COMPILED_MARKER, compile_async, import_general_core
from verse_brain.persona.runtime import PersonaRunError, PersonaRuntime, update_session
from verse_brain.persona.store import PERSONA_MD, PersonaGuardError, PersonaStore
from verse_brain.runtime.ask import FakeAskClient, words_script
from verse_brain.runtime.protocol import ListEmitter

FIX = Path(__file__).parent / "fixtures" / "persona"
BRAIN = Path(__file__).resolve().parents[1]
KA, KB = session_key("acme-intro", set()), session_key("globex-call", set())

ITEMS = {
    KA: [
        {"kind": "claim", "topic": "team size", "text": "I grew the platform team to 12 engineers.", "quote": "grew it to 12 engineers",
         "cite": f"[{KA} 0:14]"},
        {"kind": "answer", "topic": "why leaving", "text": "I want a smaller company where I own the product.",
         "quote": "I want a smaller company where I can own the product", "cite": f"[{KA} 0:31]",
         "question": "Why are you thinking about leaving?"},
        {"kind": "preference", "topic": "team size wish", "text": "I want a team of about 40 people.",
         "quote": "team of about 40 people", "cite": f"[{KA} 0:31]"},                       # read row, unconfirmed number
        {"kind": "claim", "topic": "salary expectation", "text": "I am looking for around 95,000 euros base.",
         "quote": "looking for around 95,000 euros base", "cite": f"[{KA} 0:47]"},
        {"kind": "style", "topic": "answer shape", "text": "I start with the result, then how we got there.",
         "quote": "start with the result and then explain", "cite": f"[{KA} 1:03]"},
        {"kind": "claim", "topic": "made up", "text": "I won an award.", "quote": "I won an award at the gala", "cite": f"[{KA} 0:14]"},
    ],
    KB: [
        {"kind": "claim", "topic": "salary expectation", "text": "I expect around 110,000 euros base.",
         "quote": "I expect around 110,000 euros base", "cite": f"[{KB} 0:15]"},
        {"kind": "claim", "topic": "start date", "text": "I could start in March.", "quote": "I could start in March",
         "cite": f"[{KB} 0:24]"},
        {"kind": "claim", "topic": "what I bring", "text": "I bring calm to a team.", "quote": "bring a lot of calm to the team",
         "cite": f"[{KB} 0:33]"},                                                            # a room row: never evidence
    ],
}


def responder(request, n):
    user = request["messages"][0]["content"]
    key = KA if f"[{KA} " in user else KB
    return words_script(json.dumps({"items": ITEMS[key]}), model=request["model"])


@pytest.fixture
def env(tmp_path):
    sessions = tmp_path / "sessions"
    shutil.copytree(FIX / "sessions", sessions)
    vault = tmp_path / "vault"
    vault.mkdir()
    (vault / "Note.md").write_text("an existing vault note\n")
    store = PersonaStore(vault / "Verse Persona", tmp_path / "profile" / "persona.meta.json")
    return {"tmp": tmp_path, "sessions": sessions, "vault": vault, "store": store, "me": [(FIX / "me.md").read_text()]}


def run(coro):
    return asyncio.run(coro)


def tree_hashes(root: Path) -> dict:
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob("*")) if p.is_file()}


async def update(env, name, client, **kw):
    s = env["store"]
    with s.locked():
        s.load()
        return await update_session(s, env["sessions"] / name, client, owner="Alex Rivera", me_texts=env["me"], **kw)


def test_two_sessions_end_to_end_with_verification_contradiction_and_spend(env, caplog):
    caplog.set_level(logging.DEBUG)
    client = FakeAskClient(responder)
    ra = run(update(env, "acme-intro", client))
    assert ra.kept == 4 and ra.dropped["unconfirmed"] == 1 and ra.dropped["quote"] == 1
    rb = run(update(env, "globex-call", client))
    assert rb.kept == 2 and rb.dropped["cite"] == 1 and len(rb.contradictions) == 1
    s = env["store"]
    st = json.loads(s.state_path.read_text())
    assert set(st["sessions"]) == {"acme-intro", "globex-call"}
    assert st["spend_usd"] == pytest.approx(ra.cost_usd + rb.cost_usd) and ra.cost_usd > 0
    md = (s.dir / PERSONA_MD).read_text()
    assert "| open" in md and "95,000" in md and "110,000" in md
    assert (s.dir / "Log").is_dir() and len(list((s.dir / "Log").iterdir())) == 2
    # the request carried the owner's rows and the persona so far; the second one saw the first session's entries
    assert "CURRENT PERSONA\n(empty)" in client.requests[0]["messages"][0]["content"]
    assert "[p001]" in client.requests[1]["messages"][0]["content"]
    # logs: counts only, never row or item text
    logged = "\n".join(r.getMessage() for r in caplog.records)
    for secret in ("Northwind", "95,000", "110,000", "smaller company", "March", "calm"):
        assert secret not in logged


def test_rerunning_a_session_is_idempotent_and_spends_nothing(env):
    client = FakeAskClient(responder)
    run(update(env, "acme-intro", client))
    md = (env["store"].dir / PERSONA_MD).read_text()
    state = env["store"].state_path.read_text()
    again = run(update(env, "acme-intro", client))
    assert again.skipped == "unchanged" and len(client.requests) == 1
    assert (env["store"].dir / PERSONA_MD).read_text() == md and env["store"].state_path.read_text() == state
    forced = run(update(env, "acme-intro", client, force=True))
    assert forced.new == [] and forced.repeats == forced.kept and len(client.requests) == 2


def test_owner_edits_made_while_the_request_runs_are_kept(env):
    """The update reads Persona.md before the request and writes it after: what the owner typed in his editor meanwhile must
    survive the write (a correction, an edited line, a deleted line)."""
    run(update(env, "acme-intro", FakeAskClient(responder)))
    md = env["store"].dir / PERSONA_MD
    edited = "- [p002] why leaving | I want a small company with real ownership. | my wording"

    def editing(request, n):
        out = []
        for ln in md.read_text().splitlines():
            if ln.startswith("- [p001]"):
                continue                                         # he deletes p001
            if ln.startswith("- [p002]"):
                ln = edited                                      # and rewrites p002
            out.append(ln)
            if ln == "## MY CORRECTIONS":
                out.append("- my own correction")                # and adds a correction
        md.write_text("\n".join(out) + "\n")
        return responder(request, n)

    res = run(update(env, "globex-call", FakeAskClient(editing)))
    text = md.read_text()
    assert res.contradictions and "| open" in text                # the run's own merge landed
    assert "- my own correction" in text and edited in text.splitlines() and "[p001]" not in text
    st = json.loads(env["store"].state_path.read_text())
    assert "p001" in st["deleted"] and "p001" not in st["entries"]
    assert st["entries"]["p002"]["edited"] == edited


def test_budget_unreadable_output_and_no_owner_rows(env):
    client = FakeAskClient(responder)
    with pytest.raises(PersonaRunError) as e:
        run(update(env, "acme-intro", client, budget_usd=0.001))
    assert e.value.kind == "budget" and client.requests == []
    bad = FakeAskClient(lambda req, n: words_script("I cannot do JSON today", model=req["model"]))
    with pytest.raises(PersonaRunError) as e:
        run(update(env, "acme-intro", bad))
    st = json.loads(env["store"].state_path.read_text())
    assert e.value.kind == "bad_output" and st["spend_usd"] > 0 and "acme-intro" not in st["sessions"]
    empty = env["sessions"] / "silent"
    empty.mkdir()
    (empty / "transcript.jsonl").write_text(json.dumps({"turn_id": "1", "speaker": "remote", "text": "Hello?", "t_audio_end": 1}) + "\n")
    assert run(update(env, "silent", client)).skipped == "no_owner_rows" and client.requests == []
    with pytest.raises(PersonaRunError) as e:
        run(update(env, "sim-practice", client))
    assert e.value.kind == "excluded"


def test_import_and_compile_one_mechanism(env):
    general = env["sessions"] / "general-core"
    before = tree_hashes(general)
    s = env["store"]
    with s.locked():
        s.load()
        counts = import_general_core(s, general)
    assert counts == {"bank": 2, "facts": 2, "glossary": 1, "snippets": 1, "style": 1}
    with s.locked():
        s.load()
        with pytest.raises(Exception):
            import_general_core(s, general)                    # once only
    client = FakeAskClient(responder)
    run(update(env, "acme-intro", client))
    run(update(env, "globex-call", client))
    out = env["sessions"] / "persona-core"
    s.load()
    res = run(compile_async(s, out))
    assert tree_hashes(general) == before                     # general-core is never modified
    assert sorted(p.name for p in out.iterdir()) == sorted([COMPILED_MARKER, "pack.md", "bank.jsonl", "facts.jsonl",
                                                             "glossary.jsonl", "snippets.jsonl", "meta.json"])
    bank = [json.loads(l) for l in (out / "bank.jsonl").read_text().splitlines()]
    facts = [json.loads(l) for l in (out / "facts.jsonl").read_text().splitlines()]
    snippets = [json.loads(l) for l in (out / "snippets.jsonl").read_text().splitlines()]
    assert [b["id"] for b in bank] == ["b001", "b002", "b003"]
    assert [b["origin"].split()[0] for b in bank[:2]] == ["general-core", "general-core"] and bank[2]["origin"].startswith("persona:")
    assert all({"id", "lang", "question", "opener", "points"} <= set(b) for b in bank)
    assert bank[2]["question"] == "Why are you thinking about leaving?"
    assert snippets[0]["bank_ids"] == ["b002"]                # the seed snippet's bank id remapped
    pack = (out / "pack.md").read_text()
    for sec in ("## FACTS", "## GLOSSARY", "## ANSWER BANK", "## SNIPPETS", "## STYLE GUIDE"):
        assert sec in pack
    # the open contradiction: neither value reaches the call, one unsettled line instead
    assert "95,000" not in pack and "110,000" not in pack and "unsettled | salary expectation" in pack
    assert "95,000" not in json.dumps(facts) and "110,000" not in json.dumps(snippets)
    # live claims do: the team size (a number fact) and the start date (SAID BEFORE)
    assert any("12" in f["value"] for f in facts) and any("start in March" in x["text"] for x in snippets)
    assert "Learned from my calls:\n- I start with the result" in pack
    assert pack.index("## STYLE GUIDE") > pack.index("## SNIPPETS")
    meta = json.loads((out / "meta.json").read_text())
    assert meta["kind"] == "persona-core" and meta["counts"]["unsettled"] == 1 and res["bank"] == 3
    # settle it: the kept value reaches the next compile, the other stays out
    with s.locked():
        s.load()
        cid = next(e["id"] for e in s.entries("contradiction"))
        s.resolve(cid, "2")
        s.save()
    s.load()
    run(compile_async(s, out))
    pack2 = (out / "pack.md").read_text()
    assert "110,000" in (out / "snippets.jsonl").read_text() + (out / "facts.jsonl").read_text()
    assert "95,000" not in pack2 and "unsettled" not in pack2


def test_compile_refuses_foreign_folders_and_an_empty_persona(env):
    s = env["store"]
    s.load()
    with pytest.raises(PersonaGuardError):
        run(compile_async(s, env["sessions"] / "general-core"))
    with pytest.raises(PersonaGuardError):
        run(compile_async(s, env["sessions"] / "acme-intro"))
    with pytest.raises(Exception, match="empty"):
        run(compile_async(s, env["tmp"] / "out"))


def start_msg(env, **kw):
    return {"type": "persona_start", "session_dir": str(env["sessions"] / "acme-intro"), "persona_dir": str(env["store"].dir),
            "state": str(env["store"].state_path), "me": {"core": str(FIX / "me.md")}, **kw}


def test_persona_start_update_compiles_and_reports(env):
    em = ListEmitter()
    rt = PersonaRuntime(FakeAskClient(responder), em)
    run(rt.handle(start_msg(env)))
    assert rt.stopped.is_set()
    assert [e["state"] for e in em.of("status")] == ["warming", "ready"]
    ready = em.of("status", state="ready")[0]["context"]
    assert ready["owner_rows"] == 4 and ready["read"] == 1 and ready["max_tokens"] > 0
    done = em.of("persona_done")[0]
    assert done["kept"] == 4 and done["skipped"] is None and done["compiled"]["out"].endswith("persona-core")
    assert done["open_contradictions"] == 0 and done["cost_usd"] > 0
    em2 = ListEmitter()
    run(PersonaRuntime(FakeAskClient(responder), em2).handle(start_msg(env)))
    assert em2.of("persona_done")[0]["skipped"] == "unchanged" and em2.of("persona_done")[0]["compiled"] is None


def test_persona_start_errors(env):
    em = ListEmitter()
    run(PersonaRuntime(FakeAskClient(responder), em).handle({**start_msg(env), "persona_dir": None}))
    assert em.of("persona_error")[0]["kind"] == "off"             # the pinned owner profile has no persona_dir
    em = ListEmitter()
    run(PersonaRuntime(FakeAskClient(responder), em).handle(start_msg(env, session_dir=str(env["sessions"] / "sim-practice"))))
    assert em.of("persona_error")[0]["kind"] == "excluded"
    em = ListEmitter()
    run(PersonaRuntime(FakeAskClient(responder), em).handle(start_msg(env, action="compile")))
    assert em.of("persona_error")[0]["kind"] == "empty"
    em = ListEmitter()
    run(PersonaRuntime(FakeAskClient(responder), em).handle(start_msg(env, action="import_general")))
    assert em.of("persona_done")[0]["imported"]["bank"] == 2 and em.of("persona_done")[0]["compiled"]["bank"] == 2
    em = ListEmitter()
    run(PersonaRuntime(FakeAskClient(responder), em).handle(start_msg(env, action="import_general")))
    assert em.of("persona_error")[0]["kind"] == "already_imported"


def test_persona_start_through_the_runtime_process(env):
    msg = json.dumps(start_msg(env)) + "\n"
    r = subprocess.run([sys.executable, "-m", "verse_brain.runtime", "--fake"], input=msg, capture_output=True, text=True,
                       cwd=str(BRAIN), timeout=60)
    events = [json.loads(l) for l in r.stdout.splitlines() if l.strip()]
    done = [e for e in events if e["type"] == "persona_done"]
    assert done and done[0]["kept"] == 0 and done[0]["cost_usd"] >= 0, r.stderr[-800:]


def test_backfill_dry_run_spends_nothing_and_writes_nothing(env, capsys, monkeypatch):
    import verse_brain.runtime.ask as ask_mod

    monkeypatch.setattr(ask_mod, "make_client", lambda fake=False: (_ for _ in ()).throw(AssertionError("no client in a dry run")))
    rc = cli.main(["--persona-dir", str(env["store"].dir), "--state", str(env["store"].state_path), "--profile-dir", str(FIX),
                   "backfill", "--sessions-root", str(env["sessions"]), "--include", "acme-intro", "globex-call", "old-call",
                   "sim-practice", "missing", "--exclude-prefix", "old-", "--dry-run"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "old-call: excluded" in out and "sim-practice: excluded" in out and "missing: no transcript.jsonl" in out
    assert "acme-intro: date=" in out and "owner_rows=4 (own 3, read 1, mixed 0)" in out and "est_input_tokens=" in out
    assert "globex-call: date=" in out and "owner_rows=2" in out and "room_rows=3" in out
    assert out.index("acme-intro: date") < out.index("globex-call: date")       # oldest call first
    assert "TOTAL sessions=2 owner_rows=6" in out
    assert not env["store"].dir.exists() and not env["store"].state_path.exists()


def test_backfill_with_the_fake_client_then_show(env, capsys):
    base = ["--persona-dir", str(env["store"].dir), "--state", str(env["store"].state_path), "--profile-dir", str(FIX)]
    rc = cli.main(base + ["backfill", "--sessions-root", str(env["sessions"]), "--include", "acme-intro", "globex-call", "--fake"])
    assert rc == 0 and (env["store"].dir / PERSONA_MD).is_file()
    assert set(json.loads(env["store"].state_path.read_text())["sessions"]) == {"acme-intro", "globex-call"}
    assert cli.main(base + ["show"]) == 0
    assert "sessions learned: 2" in capsys.readouterr().out
    assert cli.main(["--state", str(env["store"].state_path), "show"]) == 2          # no persona_dir: refused


# ---------------------------------------------------------------- the app's actions: seed first, status, resolve, kill safety
def test_seed_from_general_runs_once_before_the_first_update(env):
    em = ListEmitter()
    run(PersonaRuntime(FakeAskClient(responder), em).handle(start_msg(env, seed_from_general=True)))
    done = em.of("persona_done")[0]
    assert done["imported"]["bank"] == 2 and done["kept"] == 4
    assert done["compiled"]["bank"] >= 2                        # the standing answers survive into the compiled persona
    em = ListEmitter()
    run(PersonaRuntime(FakeAskClient(responder), em).handle(
        start_msg(env, session_dir=str(env["sessions"] / "globex-call"), seed_from_general=True)))
    assert em.of("persona_done")[0]["imported"] is None          # once only


def test_seed_from_general_skips_a_missing_general_prep(env):
    shutil.rmtree(env["sessions"] / "general-core")
    em = ListEmitter()
    run(PersonaRuntime(FakeAskClient(responder), em).handle(start_msg(env, seed_from_general=True)))
    assert em.of("persona_done")[0]["imported"] is None and em.of("persona_done")[0]["kept"] == 4


def test_status_lists_open_contradictions_and_writes_nothing(env):
    client = FakeAskClient(responder)
    run(update(env, "acme-intro", client))
    run(update(env, "globex-call", client))
    before = tree_hashes(env["tmp"])
    em = ListEmitter()
    run(PersonaRuntime(FakeAskClient(responder), em).handle(start_msg(env, action="status", session_dir=None,
                                                                      sessions_root=str(env["sessions"]))))
    done = em.of("persona_done")[0]
    assert done["open_contradictions"] == 1 and len(done["open"]) == 1 and done["compiled"] is None
    c = done["open"][0]
    assert set(c) == {"id", "topic", "a", "b"} and c["id"].startswith("c")
    assert {"95,000" in c["a"]["quote"], "110,000" in c["b"]["quote"]} == {True}
    assert c["a"]["ref"].startswith(KA) and c["b"]["ref"].startswith(KB) and c["a"]["date"] and c["b"]["date"]
    assert tree_hashes(env["tmp"]) == before
    assert client.requests and len(client.requests) == 2           # status sent nothing


def test_resolve_settles_one_side_saves_and_compiles(env):
    client = FakeAskClient(responder)
    run(update(env, "acme-intro", client))
    run(update(env, "globex-call", client))
    em = ListEmitter()
    run(PersonaRuntime(FakeAskClient(responder), em).handle(start_msg(env, action="status", session_dir=None,
                                                                      sessions_root=str(env["sessions"]))))
    cid = em.of("persona_done")[0]["open"][0]["id"]
    em = ListEmitter()
    run(PersonaRuntime(FakeAskClient(responder), em).handle(start_msg(env, action="resolve", session_dir=None, id=cid, keep="2",
                                                                      sessions_root=str(env["sessions"]))))
    done = em.of("persona_done")[0]
    assert done["open"] == [] and done["open_contradictions"] == 0 and done["compiled"]["out"].endswith("persona-core")
    md = (env["store"].dir / PERSONA_MD).read_text()
    assert f"resolved: kept" in md and "95,000" in md            # the loser stays visible, marked superseded
    em = ListEmitter()
    run(PersonaRuntime(FakeAskClient(responder), em).handle(start_msg(env, action="resolve", session_dir=None, id=cid, keep="1",
                                                                      sessions_root=str(env["sessions"]))))
    assert em.of("persona_error")[0]["kind"] == "error"          # no longer open
    em = ListEmitter()
    run(PersonaRuntime(FakeAskClient(responder), em).handle(start_msg(env, action="resolve", session_dir=None)))
    assert em.of("persona_error")[0]["kind"] == "bad_request"


def test_local_actions_never_read_the_keychain(env):
    # No --fake: with --no-api (how the app starts them) a status or compile runs without any client or Keychain read.
    for action in ("status", "compile"):
        msg = json.dumps(start_msg(env, action=action, session_dir=None, sessions_root=str(env["sessions"]))) + "\n"
        r = subprocess.run([sys.executable, "-m", "verse_brain.runtime", "--no-api"], input=msg, capture_output=True, text=True,
                           cwd=str(BRAIN), timeout=60, env={"PATH": "/usr/bin:/bin", "VERSE_OWNER_FILE": "/nonexistent",
                                                            "HOME": str(env["tmp"])})
        events = [json.loads(l) for l in r.stdout.splitlines() if l.strip()]
        kinds = [e.get("kind") for e in events if e["type"] == "persona_error"]
        assert "auth" not in kinds, r.stderr[-800:]
        assert any(e["type"] in ("persona_done", "persona_error") for e in events), r.stderr[-800:]
    msg = json.dumps(start_msg(env)) + "\n"                                  # an update is refused without the client
    r = subprocess.run([sys.executable, "-m", "verse_brain.runtime", "--no-api"], input=msg, capture_output=True, text=True,
                       cwd=str(BRAIN), timeout=60)
    events = [json.loads(l) for l in r.stdout.splitlines() if l.strip()]
    assert [e["kind"] for e in events if e["type"] == "persona_error"] == ["bad_request"]
    assert not env["store"].dir.exists()


def test_a_stop_during_the_commit_is_held_until_the_files_are_whole():
    import os
    import signal

    from verse_brain.persona import runtime as rt

    delivered = []
    with rt.commit(on_deferred=lambda: delivered.append(True)):
        os.kill(os.getpid(), signal.SIGTERM)                       # would end the test process without the guard
        with rt.commit(on_deferred=lambda: delivered.append("inner")):
            pass
        assert delivered == []                                     # held through the nested section
    assert delivered == [True]
    assert signal.getsignal(signal.SIGTERM) is signal.SIG_DFL      # the default action is back


def test_the_seed_import_alone_compiles_even_when_the_call_adds_nothing(env):
    from verse_brain.persona.runtime import fake_persona_responder

    em = ListEmitter()
    run(PersonaRuntime(FakeAskClient(fake_persona_responder), em).handle(start_msg(env, seed_from_general=True)))
    done = em.of("persona_done")[0]
    assert done["kept"] == 0 and done["imported"]["bank"] == 2
    assert done["compiled"] is not None and done["compiled"]["bank"] == 2


# ---------------------------------------------------------------- review fixes: disputed seed values, edited claims, the prompt rule
def test_an_open_contradiction_with_a_seed_fact_keeps_the_seed_answers_on_that_topic_out(env):
    from verse_brain.persona.extract import Item

    s = env["store"]
    with s.locked():
        s.load()
        import_general_core(s, env["sessions"] / "general-core")
        r = s.merge([Item("claim", "notice period", "My notice period is 90 days.", "notice period is 90 days", KA, "0:14",
                          "own")], "acme-intro", "2026-11-20")
        s.save()
    assert r.contradictions                                          # against the seed fact "Notice period in days | 30"
    out = env["sessions"] / "persona-core"
    run(compile_async(s, out))
    pack = (out / "pack.md").read_text()
    written = pack + "".join((out / f).read_text() for f in ("bank.jsonl", "facts.jsonl", "snippets.jsonl"))
    assert "unsettled | notice period" in pack
    assert "30 days" not in written and "90 days" not in written    # neither value reaches the call
    bank = [json.loads(l) for l in (out / "bank.jsonl").read_text().splitlines()]
    assert [b["question"] for b in bank] == ["Tell me about yourself"]   # the answer on another topic stays
    assert json.loads((out / "meta.json").read_text())["held_back"] == 2  # the notice-period answer and snippet
    with s.locked():
        s.load()
        s.resolve(r.contradictions[0], "1")                          # he keeps the seed: its answers come back
        s.save()
    run(compile_async(s, out))
    assert "30 days" in (out / "bank.jsonl").read_text() and "90 days" not in (out / "pack.md").read_text()


def test_an_edited_claim_goes_out_as_his_correction_never_with_the_call_cite(env):
    from verse_brain.runtime.prompt import SAID_BEFORE_REF, build_request
    from verse_brain.runtime.settings import route_params

    run(update(env, "globex-call", FakeAskClient(responder)))
    s = env["store"]
    md = s.dir / PERSONA_MD
    t = md.read_text()
    old = next(l for l in t.splitlines() if "start date" in l and l.startswith("- [p"))
    eid = old.split("]")[0][3:]
    md.write_text(t.replace(old, f"- [{eid}] start date | I could start in May | my wording"))
    s.load()
    out = env["sessions"] / "persona-core"
    run(compile_async(s, out))
    snippets = [json.loads(l) for l in (out / "snippets.jsonl").read_text().splitlines()]
    mine = [x for x in snippets if "start in May" in x["text"]]
    assert mine and all(x["ref"] == "owner correction" for x in mine)
    assert not any(x["ref"].startswith(SAID_BEFORE_REF) and "May" in x["text"] for x in snippets)
    # an unedited claim still goes out quoted, with its cite, and its pack turns the live SAID BEFORE rule on
    run(update(env, "acme-intro", FakeAskClient(responder)))
    s.load()
    run(compile_async(s, out))
    pack = (out / "pack.md").read_text()
    said = [x for x in (json.loads(l) for l in (out / "snippets.jsonl").read_text().splitlines())
            if x["ref"].startswith(SAID_BEFORE_REF)]
    assert said and all(x["text"].startswith('"') for x in said)
    req = build_request("F", route_params("F"), pack, [], "tail")
    assert "only through such a snippet" in req["system"][0]["text"]
