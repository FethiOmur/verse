"""The pre-meeting brief (P3): inputs, request, parsing, files, errors, the one-shot process.

Fixtures: tests/fixtures/memory/sessions (fictional) and tests/fixtures/memory/brief (scripted model replies). The owner is the
pinned profile of conftest.py ("Alex Rivera"). The live check is opt-in: VERSE_LIVE=1.
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from test_memory_index import put_all
from verse_brain.memory import brief as brief_mod
from verse_brain.memory.brief import (BRIEF_SYSTEM_TEMPLATE, PROBES, SECTIONS, BriefRuntime, brief_system_text, parse_brief,
                                      render_brief_md, session_block, upcoming_line)
from verse_brain.memory.index import MemoryIndex
from verse_brain.runtime.ask import AskScript, FakeAskClient, words_script
from verse_brain.runtime.protocol import ListEmitter
from verse_brain.runtime.settings import BRIEF_EXCERPT_TOKENS, BRIEF_MAX_TOKENS, BRIEF_PACK_CHARS, brief_params
from verse_brain.runtime.transport import Offline

BRAIN = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "memory"
OWNER = "Alex Rivera"
SESSIONS = ["halden-pilot-review", "halden-kickoff"]
UPCOMING = {"title": "Halden weekly", "start": "2026-10-28T10:00:00+01:00",
            "attendees": ["Marta Velin", "Joe Arkwright", "joe@halden.example"]}


def run(coro):
    return asyncio.run(coro)


@pytest.fixture
def idx(tmp_path):
    path = tmp_path / "memory" / "index.sqlite"
    ix = MemoryIndex.open(path)
    keys = put_all(ix)
    ix.close()
    return path, keys


def reply_text(keys: dict) -> str:
    raw = (FIXTURES / "brief" / "reply_five_sections.txt").read_text(encoding="utf-8")
    return raw.replace("{KICK}", keys["halden-kickoff"]).replace("{PILOT}", keys["halden-pilot-review"]).replace(
        "{TARLA}", keys["tarla-intro"])


def start_msg(db: Path, tmp_path: Path, **kw) -> dict:
    msg = {"type": "brief_start", "db": str(db), "owner_name": OWNER,
           "entity": {"id": "e-3k9xq2ma", "kind": "person", "name": "Marta Velin", "company": "Halden Works"},
           "sessions": SESSIONS, "upcoming": UPCOMING, "lang": "en", "out": str(tmp_path / "memory" / "briefs" / "e-3k9xq2ma.json"),
           "session_out": str(tmp_path / "sessions" / "halden-weekly"), "model": "sonnet"}
    msg.update(kw)
    return msg


def make(client: FakeAskClient | None = None, **kw):
    em = ListEmitter()
    c = client or FakeAskClient()
    return BriefRuntime(c, em, no_embed=True, **kw), em, c


def run_brief(msg: dict, reply: str | None = None, client: FakeAskClient | None = None):
    rt, em, c = make(client or (FakeAskClient(lambda r, n: words_script(reply, model=r["model"])) if reply is not None else None))

    async def go():
        await rt.handle(msg)
        await rt.shutdown()

    run(go())
    return rt, em, c


def points_of(brief: dict) -> dict[str, list[dict]]:
    return {s["id"]: s["points"] for s in brief["sections"]}


# ---------------------------------------------------------------- the prompt and the settings
def test_system_prompt_golden_and_variables():
    golden = (FIXTURES / "golden" / "brief_system.golden.txt").read_text(encoding="utf-8")
    assert brief_system_text(OWNER, "Marta Velin", "en") + "\n" == golden
    assert "PROMISED BY ALEX RIVERA, PROMISED BY THEM" in golden and "Write in English. No other text." in golden
    assert "Write in Turkish." in brief_system_text(OWNER, "Emre Kaya", "tr")
    import re

    assert set(re.findall(r"\{\w+\}", BRIEF_SYSTEM_TEMPLATE)) == {"{owner}", "{OWNER}", "{name}", "{lang}"}


def test_brief_params_are_sonnet_with_a_short_cap():
    p = brief_params()
    assert p["model"] == "claude-sonnet-5-5" and p["max_tokens"] == BRIEF_MAX_TOKENS == 1500
    assert BRIEF_EXCERPT_TOKENS == 18_000 and BRIEF_PACK_CHARS == 2_400
    assert brief_params() is not brief_params()


def test_probes_are_three_and_written_in_three_languages():
    assert list(PROBES) == ["commitments", "open", "preferences"]
    for text in PROBES.values():
        assert len(text.split(" | ")) == 3


# ---------------------------------------------------------------- the whole run
def test_brief_run_writes_json_md_and_events(idx, tmp_path):
    db, keys = idx
    msg = start_msg(db, tmp_path)
    rt, em, c = run_brief(msg, reply_text(keys))
    assert [e["type"] for e in em.events] == ["status", "status", "brief_done"]
    assert [e.get("state") for e in em.events[:2]] == ["warming", "ready"] and rt.stopped.is_set()
    done = em.of("brief_done")[0]
    assert done["path"] == msg["out"] and done["dropped_uncited"] == 2 and done["points"] == 5 + 2 + 1
    assert set(done) == {"type", "path", "cost_usd", "usage", "points", "dropped_uncited", "ms_total"}
    assert done["cost_usd"] == round((412 * 2.0 + 388 * 10.0 + 31240 * 0.20) / 1e6, 6)

    brief = json.loads(Path(msg["out"]).read_text(encoding="utf-8"))
    assert Path(msg["session_out"], "brief.json").read_text(encoding="utf-8") == Path(msg["out"]).read_text(encoding="utf-8")
    assert brief["version"] == 1 and brief["entity"] == "e-3k9xq2ma" and brief["name"] == "Marta Velin" and brief["lang"] == "en"
    assert brief["model"] == "claude-sonnet-5-5" and brief["for_session"] == "halden-weekly"
    assert brief["newest_session"] == "halden-pilot-review" and brief["dropped_uncited"] == 2
    assert [s["name"] for s in brief["sessions"]] == SESSIONS
    assert brief["sessions"][0] == {"name": "halden-pilot-review", "key": keys["halden-pilot-review"], "title": "Halden Pilot Review",
                                    "date": "2026-10-26T10:00:00+01:00"}
    assert [s["id"] for s in brief["sections"]] == list(SECTIONS)
    pts = points_of(brief)
    assert len(pts["discussed"]) == 5                                  # the sixth cited point is dropped
    assert pts["discussed"][1] == {"text": "The first gateway passed the Rovigo cold room test and was chosen.",
                                   "cites": [{"key": keys["halden-pilot-review"], "session": "halden-pilot-review", "kind": "turn", "stamp": "1:25"},
                                             {"key": keys["halden-pilot-review"], "session": "halden-pilot-review", "kind": "summary", "stamp": None}]}
    assert [p["text"] for p in pts["promised_owner"]] == ["Send the pilot plan by Friday.",
                                                          "Send the weekly report template and the sixty-truck cost model."]
    assert len(pts["promised_them"]) == 1 and pts["open"] == [] and pts["tone"] == []     # (none) stays an empty section
    assert all(p["cites"] for s in pts.values() for p in s) and "[s" not in json.dumps([p["text"] for s in pts.values() for p in s])
    assert brief["usage"] == done["usage"] and brief["cost_usd"] == done["cost_usd"]

    md = Path(msg["session_out"], "brief.md").read_text(encoding="utf-8")
    assert md.startswith("PAST MEETINGS WITH Marta Velin (from Verse's memory, as of ")
    assert "Promised by Alex Rivera: Send the pilot plan by Friday." in md and "Still open" not in md and "Tone" not in md
    assert len(c.requests) == 1


def test_the_request(idx, tmp_path):
    db, keys = idx
    rt, em, c = run_brief(start_msg(db, tmp_path), reply_text(keys))
    req = c.requests[0]
    assert req["model"] == "claude-sonnet-5-5" and req["max_tokens"] == 1500 and "cache_control" not in req
    assert req["system"] == [{"type": "text", "text": brief_system_text(OWNER, "Marta Velin", "en")}]
    user = req["messages"][0]["content"]
    assert len(req["messages"]) == 1 and user.startswith("UPCOMING: Halden weekly · 28 Oct 2026 10:00 · with Marta Velin, Joe Arkwright\n\n")
    assert "@" not in json.dumps(req)                                  # no email, and the address-shaped attendee is cut
    assert "PAST MEETINGS (newest first)\n== " + keys["halden-pilot-review"] in user
    assert user.index(keys["halden-pilot-review"]) < user.index(keys["halden-kickoff"])
    assert "tarla" not in user.lower() and "ahtapot" not in user
    assert "PREP" not in user and "EARLIER CHAT" not in user and "Old answer about invoices" not in user


def test_no_upcoming_line_when_there_is_none(idx, tmp_path):
    db, keys = idx
    _, _, c = run_brief(start_msg(db, tmp_path, upcoming=None, session_out=None), reply_text(keys))
    assert c.requests[0]["messages"][0]["content"].startswith("PAST MEETINGS (newest first)\n")
    assert upcoming_line(None) is None and upcoming_line({"title": "x", "attendees": []}) == "UPCOMING: x"


def test_without_session_out_only_the_entity_file_is_written(idx, tmp_path):
    db, keys = idx
    msg = start_msg(db, tmp_path, session_out=None)
    _, em, _ = run_brief(msg, reply_text(keys))
    assert Path(msg["out"]).is_file() and not (tmp_path / "sessions").exists()
    assert json.loads(Path(msg["out"]).read_text())["for_session"] is None and em.of("brief_done")


def test_the_session_the_brief_is_for_is_not_an_input(idx, tmp_path):
    db, keys = idx
    msg = start_msg(db, tmp_path, sessions=SESSIONS + ["halden-weekly"], session_out=str(tmp_path / "sessions" / "halden-kickoff"))
    _, _, c = run_brief(msg, reply_text(keys))
    user = c.requests[0]["messages"][0]["content"]
    assert keys["halden-kickoff"] not in user.split("PAST MEETINGS", 1)[1]


def test_no_sessions(idx, tmp_path):
    db, keys = idx
    for sessions in ([], ["nothing-here"], ["halden-weekly-prep"]):       # the last has a prep but no transcript or summary
        rt, em, c = run_brief(start_msg(db, tmp_path, sessions=sessions), "x")
        assert [e["type"] for e in em.events] == ["status", "brief_error"] and em.events[1]["kind"] == "no_sessions"
        assert not c.requests and rt.stopped.is_set()


def test_at_most_eight_sessions_split_the_budget_evenly(tmp_path):
    ix = MemoryIndex.open(tmp_path / "many.sqlite")
    rows = [{"stamp": f"0:{i:02d}", "speaker": "Marta", "text": f"Line {i} about the plan " + "word " * 40} for i in range(40)]
    from verse_brain.runtime.ask import parse_rows

    names = []
    for n in range(10):
        name = f"call-{n:02d}"
        names.append(name)
        ix.put(name=name, dir=tmp_path, fp=f"fp{n}", title=f"Call {n}", date=f"2026-09-{10 + n:02d}T10:00:00+02:00", kind="call",
               lang="en", labels=["Marta Velin"], rows=parse_rows(rows))
    ix.close()
    _, _, c = run_brief(start_msg(tmp_path / "many.sqlite", tmp_path, sessions=names, upcoming=None, session_out=None), "x")
    user = c.requests[0]["messages"][0]["content"]
    assert user.count("\n== ") + (1 if user.startswith("== ") else 0) == 8
    assert "Call 9" in user and "Call 2" in user and "Call 1\n" not in user and "Call 0\n" not in user      # the eight newest
    from verse_brain.runtime.ask import est_tokens

    assert est_tokens(user) < BRIEF_EXCERPT_TOKENS + 1_500


def test_a_stale_brief_md_is_removed_when_the_new_brief_has_no_point(idx, tmp_path):
    db, _ = idx
    msg = start_msg(db, tmp_path)
    folder = Path(msg["session_out"])
    folder.mkdir(parents=True)
    (folder / "brief.md").write_text("OLD BRIEF\n", encoding="utf-8")
    _, em, _ = run_brief(msg, "Nothing in the requested format.")
    assert em.of("brief_done")[0]["points"] == 0 and not (folder / "brief.md").exists() and (folder / "brief.json").is_file()


def test_language_changes_the_system_prompt_only(idx, tmp_path):
    db, keys = idx
    _, _, c = run_brief(start_msg(db, tmp_path, lang="tr"), reply_text(keys))
    assert c.requests[0]["system"][0]["text"] == brief_system_text(OWNER, "Marta Velin", "tr")
    _, _, c = run_brief(start_msg(db, tmp_path, lang="xx"), reply_text(keys))
    assert "Write in English." in c.requests[0]["system"][0]["text"]


@pytest.mark.parametrize("script, kind", [(AskScript(error=Offline("APIConnectionError")), "offline"),
                                          (AskScript(stop_reason="refusal", chunks=[(0.0, "no")]), "refusal")])
def test_errors_become_brief_error(idx, tmp_path, script, kind):
    db, _ = idx
    msg = start_msg(db, tmp_path)
    rt, em, _ = run_brief(msg, client=FakeAskClient(lambda r, n: script))
    err = em.of("brief_error")[0]
    assert err["kind"] == kind and not em.of("brief_done") and rt.stopped.is_set()
    assert not Path(msg["out"]).exists()


def test_bad_requests_and_a_missing_index(idx, tmp_path):
    db, _ = idx
    _, em, _ = run_brief({"type": "brief_start", "db": str(db)})
    assert em.of("brief_error")[0]["kind"] == "bad_request"
    _, em, _ = run_brief(start_msg(tmp_path / "none.sqlite", tmp_path))
    assert em.of("brief_error")[0]["kind"] == "error"


# ---------------------------------------------------------------- inputs
def test_session_block_has_summary_openers_closers_and_no_prep_or_chat(idx):
    db, keys = idx
    ix = MemoryIndex.open(db, readonly=True)
    info = ix.sessions(["halden-kickoff"])[0]
    block = session_block(ix, info, None, 6_000)
    lines = block.splitlines()
    assert lines[0].startswith(f"== {keys['halden-kickoff']} · Mon 19 Oct 2026 · meeting · Halden Kickoff · with Marta Velin")
    assert any(ln.startswith("SUMMARY") for ln in lines)
    stamps = [ln.split("]")[0][1:] for ln in lines if ln.startswith("[") and ln[1].isdigit()]
    # 22 rows: the first four, the last eight, and whatever the probes add in time order
    assert stamps[:4] == ["0:04", "0:21", "0:48", "1:12"]
    assert stamps[-8:] == ["6:02", "6:30", "6:55", "7:18", "7:41", "8:03", "8:26", "8:30"]
    assert len(stamps) == len(set(stamps))                # no line twice
    assert "PREP" not in block and "EARLIER CHAT" not in block and "Old answer" not in block
    tiny = session_block(ix, info, None, 1)                                    # a budget below the fixed part: the fixed part only
    assert len(tiny.splitlines()) <= len(lines)
    ix.close()


def test_session_block_marks_gaps(idx):
    db, _ = idx
    ix = MemoryIndex.open(db, readonly=True)
    info = ix.sessions(["halden-kickoff"])[0]
    block = session_block(ix, info, None, 1)       # 22 rows, only rows 0-3 and 14-21 are fixed
    assert "[...]" in block.splitlines() and block.count("[...]") == 1
    ix.close()


# ---------------------------------------------------------------- parse_brief
def test_parse_brief_headings_bullets_and_empties(idx):
    db, keys = idx
    ix = MemoryIndex.open(db, readonly=True)
    p, k = keys["halden-pilot-review"], keys["halden-kickoff"]
    text = f"""Some preamble that is ignored.
**Discussed**
* The weekly report [{p} 2:46]
## promised by alex rivera:
- Send the plan by Friday. [{k} 1:12], [{p} summary]
PROMISED BY THEM
- (none)
still open
- Who runs the install crew? [{p} 1:25] [{p} 1:52] [{p} 2:20] [{p} 3:12]
TONE AND PREFERENCES
- (nothing clear yet)
- A tone claim with a prep cite [{p} prep]
"""
    sections, dropped = parse_brief(text, ix, SESSIONS, OWNER)
    by = {s["id"]: s["points"] for s in sections}
    assert [s["id"] for s in sections] == list(SECTIONS)
    assert by["discussed"][0]["text"] == "The weekly report" and by["discussed"][0]["cites"][0]["stamp"] == "2:46"
    assert by["promised_owner"][0]["text"] == "Send the plan by Friday." and len(by["promised_owner"][0]["cites"]) == 2
    assert by["promised_them"] == [] and by["tone"] == []
    assert len(by["open"][0]["cites"]) == 3                                   # at most three citations per point
    assert dropped == 1                                                       # the prep citation is not evidence for a brief
    ix.close()


# ---------------------------------------------------------------- brief.md
def fake_brief(points_per_section: int, words: int = 25) -> dict:
    pts = [{"text": f"Point {i} " + "word " * words, "cites": []} for i in range(points_per_section)]
    return {"made_at": "2026-10-21T09:12:00Z", "name": "Marta Velin",
            "sections": [{"id": s, "points": list(pts)} for s in SECTIONS]}


def test_render_brief_md_layout():
    brief = fake_brief(1, 2)
    brief["sections"][3]["points"] = []
    md = render_brief_md(brief, OWNER)
    assert md.splitlines() == [
        "PAST MEETINGS WITH Marta Velin (from Verse's memory, as of 21 Oct 2026; background only: what was said before, not facts of "
        "this meeting)",
        "Discussed: Point 0 word word.", "Promised by Alex Rivera: Point 0 word word.", "Promised by them: Point 0 word word.",
        "Tone and preferences: Point 0 word word."]
    assert render_brief_md({**brief, "sections": [{"id": s, "points": []} for s in SECTIONS]}, OWNER) == ""


def test_render_brief_md_is_capped_at_whole_lines_and_has_no_citation():
    brief = fake_brief(5, 40)                      # about 1,000 characters per section: five sections cannot fit
    brief["sections"][0]["points"][0]["text"] += " [sk3f9qa 12:34]"
    md = render_brief_md(brief, OWNER)
    assert len(md) <= BRIEF_PACK_CHARS and md.endswith(".\n") and "[s" not in md
    lines = md.splitlines()
    assert 1 < len(lines) < 6 and all(ln.endswith(".") for ln in lines[1:])
    assert md == render_brief_md(brief, OWNER, limit=BRIEF_PACK_CHARS)


# ---------------------------------------------------------------- the process
def test_process_ends_by_itself_after_the_brief(idx, tmp_path):
    db, _ = idx
    env = dict(os.environ)
    env["PYTHONPATH"] = str(BRAIN) + os.pathsep + env.get("PYTHONPATH", "")
    p = subprocess.Popen([sys.executable, "-m", "verse_brain.runtime", "--fake", "--no-embed", "--log-level", "INFO"], cwd=BRAIN, env=env,
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        p.stdin.write(json.dumps(start_msg(db, tmp_path)) + "\n")
        p.stdin.flush()                              # stdin stays open: the process must still end
        out = p.stdout.read()
        assert p.wait(timeout=15) == 0
        err = p.stderr.read()
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)
    evs = [json.loads(ln) for ln in out.splitlines()]
    assert [e["type"] for e in evs] == ["status", "status", "brief_done"] and evs[-1]["points"] == 0
    for sentence in ("Rovigo", "Marta", "truck list", "sixty thousand"):
        assert sentence not in err


@pytest.mark.skipif(os.environ.get("VERSE_LIVE") != "1", reason="live: VERSE_LIVE=1 (Keychain key, spends cents)")
def test_live_brief(idx, tmp_path):
    from verse_brain.runtime.ask import make_client

    db, _ = idx
    msg = start_msg(db, tmp_path)
    em = ListEmitter()
    rt = BriefRuntime(make_client(), em, no_embed=True)

    async def go():
        await rt.handle(msg)
        await rt.shutdown()

    run(go())
    done = em.of("brief_done")
    assert done and done[0]["cost_usd"] < 0.2 and done[0]["points"] > 0
