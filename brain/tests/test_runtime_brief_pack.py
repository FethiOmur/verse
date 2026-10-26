"""The brief in the live model (P3, spec 2.4 "Into the live model"): `brief.md` -> `Session.brief` -> `pack_for_model` -> the pack block
of every meeting request. Without a `brief.md` every request is what it was (golden: test_runtime_layout.py stays unchanged)."""

from __future__ import annotations

import shutil

from test_runtime_helpers import FIX, make, run, session_copy, settle, start, turn

from verse_brain.memory.brief import render_brief_md
from verse_brain.runtime.prompt import PACK_HEADER, TRANSCRIPT_HEADER
from verse_brain.runtime.protocol import load_session
from verse_brain.runtime.settings import BRIEF_PACK_CHARS

BRIEF = ("PAST MEETINGS WITH Marta Velin (from Verse's memory, as of 21 Oct 2026; background only: what was said before, not facts of "
         "this meeting)\nDiscussed: The pilot covers two teams.\nPromised by them: Joe confirms the truck list on Monday.\n")


def pack_block(req: dict) -> str:
    return req["messages"][0]["content"][0]["text"]


def two_requests(tmp_path, brief: str | None):
    d = session_copy(tmp_path)
    if brief is not None:
        (d / "brief.md").write_text(brief, encoding="utf-8")

    async def go():
        b, t, em = make()
        await start(b, d)
        await turn(b, "r1", "how did you build the invoice pipeline?")
        await settle(b)
        return t

    t = run(go())
    return d, [c.request for c in t.by_route("F")], [c.request for c in t.by_route("D")]


def test_load_session_reads_brief_md(tmp_path):
    d = session_copy(tmp_path)
    s = load_session(d)
    assert s.brief == "" and s.pack_for_model == s.pack
    (d / "brief.md").write_text(BRIEF, encoding="utf-8")
    s = load_session(d)
    assert s.brief == BRIEF.strip() and s.pack_for_model == s.pack.rstrip() + "\n\n" + BRIEF.strip()
    assert s.pack == (FIX / "pack.md").read_text(encoding="utf-8")        # everything else that reads session.pack is unchanged


def test_brief_md_is_capped_again_at_whole_lines_and_bad_bytes_are_empty(tmp_path):
    d = session_copy(tmp_path)
    head = BRIEF.splitlines()[0]
    long_lines = [f"Discussed: {'word ' * 60}{i}." for i in range(30)]
    (d / "brief.md").write_text("\n".join([head, *long_lines]) + "\n", encoding="utf-8")
    s = load_session(d)
    assert len(s.brief) <= BRIEF_PACK_CHARS and s.brief.startswith(head) and s.brief.splitlines()[-1] in long_lines
    (d / "brief.md").write_bytes(b"PAST MEETINGS \xff\xfe broken")
    assert load_session(d).brief == ""


def test_pack_block_ends_with_the_brief_block(tmp_path):
    d, fs, ds = two_requests(tmp_path, BRIEF)
    pack = (d / "pack.md").read_text(encoding="utf-8")
    want = PACK_HEADER + pack.rstrip() + "\n\n" + BRIEF.strip() + TRANSCRIPT_HEADER
    assert fs and ds
    for req in fs + ds:
        assert pack_block(req) == want
        assert pack_block(req).endswith(BRIEF.strip() + TRANSCRIPT_HEADER)
        assert req["messages"][0]["content"][0]["cache_control"] == {"type": "ephemeral"}


def test_without_brief_md_every_request_is_what_it_was(tmp_path):
    d, fs, ds = two_requests(tmp_path, None)
    pack = (d / "pack.md").read_text(encoding="utf-8")
    for req in fs + ds:
        assert pack_block(req) == PACK_HEADER + pack + TRANSCRIPT_HEADER
    # the same session with a brief differs in the pack block only
    (tmp_path / "with").mkdir()
    _, fb, db_ = two_requests(tmp_path / "with", BRIEF)
    for plain, briefed in zip(fs + ds, fb + db_):
        assert {k: v for k, v in plain.items() if k != "messages"} == {k: v for k, v in briefed.items() if k != "messages"}
        assert plain["messages"][0]["content"][1:] == briefed["messages"][0]["content"][1:]
        assert pack_block(plain) != pack_block(briefed)


def test_follow_unprepared_and_snippet_readers_still_see_the_plain_pack(tmp_path):
    """Only the two prompt builds use `pack_for_model`; the conflict check, snippet refs and the unprepared test read `pack`."""
    d = session_copy(tmp_path)
    (d / "brief.md").write_text(BRIEF, encoding="utf-8")

    async def go():
        b, t, em = make()
        await start(b, d)
        return b

    b = run(go())
    assert b.session.brief and "PAST MEETINGS" not in b.session.pack
    assert b.unprepared is False


def test_renderer_output_is_what_the_loader_accepts(tmp_path):
    brief = {"made_at": "2026-10-21T09:12:00Z", "name": "Marta Velin",
             "sections": [{"id": "discussed", "points": [{"text": "The pilot covers two teams", "cites": []}]},
                          {"id": "promised_owner", "points": []}, {"id": "promised_them", "points": []},
                          {"id": "open", "points": []}, {"id": "tone", "points": []}]}
    md = render_brief_md(brief, "Alex Rivera")
    d = tmp_path / "s"
    shutil.copytree(FIX, d)
    (d / "brief.md").write_text(md, encoding="utf-8")
    assert load_session(d).brief == md.strip() and load_session(d).brief.splitlines()[1] == "Discussed: The pilot covers two teams."
