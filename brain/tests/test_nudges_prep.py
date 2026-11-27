"""Live nudges, prep side (prep/nudges.py and the pipeline): parser, drops, stable ids, blanking, nudges-only compile."""

from __future__ import annotations

import json

from test_prep_pipeline import NOTE, NOW, FakeModel, FakeVault
from verse_brain.prep import build
from verse_brain.prep.nudges import MAX_NUDGES, main as nudges_main, model_lines, model_note, parse_nudges

BLOCKS = """
### Nudge: Pay story
When: pay, salary or the commercial terms are being discussed now
Keys: Salary, pay, commercials, , compensation
Who: any
Until: number
After: 2m
Say: First tell the pilot story.
  Then give the range.
  Then stop talking.

Some prose that sits inside the block and is ignored.

### Cue: Tooling
When: the tools they use come up
Keys: tooling, stack
Who: them
Say: Ask which tracker they use.
---
## Back to normal notes
- A normal line the model must keep seeing.
"""


def lines(text: str) -> list[str]:
    return text.splitlines()


def test_parse_fields_continuation_and_block_end():
    p = parse_nudges(lines(BLOCKS))
    assert [r["id"] for r in p.records] == ["n001", "n002"]
    pay, tools = p.records
    assert pay == {"id": "n001", "title": "Pay story", "when": "pay, salary or the commercial terms are being discussed now",
                   "keys": ["salary", "pay", "commercials", "compensation"], "who": "any", "until": "number", "after_s": 120.0,
                   "say": ["First tell the pilot story.", "Then give the range.", "Then stop talking."], "ref": "prep:L2"}
    assert tools["who"] == "them" and tools["until"] is None and tools["after_s"] == 0.0 and tools["ref"] == "prep:L14"
    assert any("not a nudge field" in w for w in p.warnings)
    # the block ends at the --- rule: the rule and the normal notes after it are not nudge lines
    rule = lines(BLOCKS).index("---") + 1
    assert rule not in p.lines and rule - 1 in p.lines and rule + 2 not in p.lines


def _block(title: str, *, when=True, keys=True, say="One line.", extra="") -> str:
    out = [f"### Nudge: {title}"]
    if when:
        out.append("When: it comes up")
    if keys:
        out.append("Keys: alpha")
    if say is not None:
        out.append(f"Say: {say}")
    if extra:
        out.append(extra)
    return "\n".join(out) + "\n"


def test_drops_with_warnings_keep_the_others_and_ids_stable():
    note = (_block("ok one") + _block("no when", when=False) + _block("no keys", keys=False) + _block("no say", say=None)
            + _block("too long", say=" ".join(["word"] * 46)) + _block("bad who", extra="Who: everybody")
            + _block("bad until", extra="Until: tomorrow") + _block("bad after", extra="After: soon")
            + _block("four lines", say="a\n  b\n  c\n  d") + _block("ok two"))
    p = parse_nudges(lines(note))
    assert [r["id"] for r in p.records] == ["n001", "n010"]     # ids follow the block order, drops do not renumber
    joined = "\n".join(p.warnings)
    for why in ("no `When:`", "no `Keys:`", "no `Say:`", "46 words", "Who: everybody", "Until: tomorrow", "After: soon",
                "4 lines"):
        assert why in joined


def test_at_most_eight_nudges():
    p = parse_nudges(lines("".join(_block(f"n{i}") for i in range(10))))
    assert len(p.records) == MAX_NUDGES and [r["id"] for r in p.records][-1] == "n008"
    assert sum("at most 8 nudges" in w for w in p.warnings) == 2


def test_blanking_keeps_numbering_and_other_lines():
    src = lines("# Title\nintro line\n" + BLOCKS)
    out = model_lines(src)
    assert len(out) == len(src)
    assert out[0] == "# Title" and out[1] == "intro line"
    assert not any("Nudge:" in ln or "Cue:" in ln or "pilot story" in ln for ln in out)
    assert "- A normal line the model must keep seeing." in out
    assert model_note("no nudges here\n") == "no nudges here\n"


def _note_with_blocks(tmp_path):
    p = tmp_path / "note_with_nudges.md"
    p.write_text(NOTE.read_text(encoding="utf-8").rstrip("\n") + "\n" + BLOCKS, encoding="utf-8")
    return p


def _build(note, out):
    model = FakeModel()
    vault = FakeVault()
    session = build(note, [], ["en", "it"], out, max_questions=80, model=model, vault=vault, now=NOW)
    return session, model, vault


def test_pipeline_writes_nudges_and_the_pack_is_unchanged(tmp_path):
    plain, m_plain, v_plain = _build(NOTE, tmp_path / "plain")
    with_n, m_n, v_n = _build(_note_with_blocks(tmp_path), tmp_path / "with")
    assert (plain / "pack.md").read_bytes() == (with_n / "pack.md").read_bytes()
    assert (plain / "bank.jsonl").read_bytes() == (with_n / "bank.jsonl").read_bytes()
    assert not (plain / "nudges.jsonl").exists()
    recs = [json.loads(ln) for ln in (with_n / "nudges.jsonl").read_text(encoding="utf-8").splitlines()]
    assert [r["id"] for r in recs] == ["n001", "n002"] and recs[0]["ref"].startswith("prep:L")
    # the model never saw the nudge text, and the vault was asked the same questions
    user = m_n.calls[0][1]
    assert "pilot story" not in user and "Nudge:" not in user and "A normal line the model must keep seeing." in user
    assert not [q for q in v_n.queries if "Pay story" in q or "Tooling" in q]   # a nudge heading is no vault query
    meta = json.loads((with_n / "meta.json").read_text(encoding="utf-8"))
    assert meta["stats"]["nudges"] == 2 and "nudges" not in json.loads((plain / "meta.json").read_text())["stats"]
    assert any("not a nudge field" in w for w in meta["warnings"])
    review = (with_n / "review.md").read_text(encoding="utf-8")
    assert "## Nudges" in review and "### n001 Pay story" in review and "not a nudge field" in review
    assert "## Nudges" not in (plain / "review.md").read_text(encoding="utf-8")


def test_nudges_only_cli_writes_one_file(tmp_path, capsys):
    session, _, _ = _build(NOTE, tmp_path / "s")
    before = {p.name: p.read_bytes() for p in session.iterdir()}
    note = _note_with_blocks(tmp_path)
    assert nudges_main([str(note), str(session)]) == 0
    after = {p.name: p.read_bytes() for p in session.iterdir()}
    assert set(after) - set(before) == {"nudges.jsonl"}
    assert all(after[k] == v for k, v in before.items())
    assert [json.loads(ln)["id"] for ln in after["nudges.jsonl"].decode().splitlines()] == ["n001", "n002"]


def test_nudges_only_cli_refuses_a_non_session_and_writes_nothing_without_nudges(tmp_path):
    empty = tmp_path / "empty"
    empty.mkdir()
    assert nudges_main([str(NOTE), str(empty)]) == 2
    session, _, _ = _build(NOTE, tmp_path / "s")
    assert nudges_main([str(NOTE), str(session)]) == 1
    assert not (session / "nudges.jsonl").exists()
