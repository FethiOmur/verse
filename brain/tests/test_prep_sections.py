"""Sectioned prep (a long note runs in sections), the per-call output budget, the budget stop, the truncated-section retry
and the `$1.152` parse. Offline: the fake model only quotes lines it was given, so every block grounds."""

import json
import re
from datetime import datetime, timezone

import pytest

from verse_brain.prep import build
from verse_brain.prep.conflicts import find_conflicts, mentions_in
from verse_brain.prep.model import ModelOutput, PrepError, Usage
from verse_brain.prep.pipeline import MAX_PREP_NOTE_CHARS, call_max_tokens
from verse_brain.prep.sections import SECTION_MAX_CHARS, split_note
from verse_brain.prep.sources import norm
from test_prep_conflicts import book

NOW = datetime(2026, 10, 20, 9, 0, 0, tzinfo=timezone.utc)
SHARED_Q = "Walk me through your most important result."
HEADER = "# Interview prep: Staff Engineer at Halden\n\nCall: Thursday 22 October 2026, 15:00 CEST, Google Meet.\n"


def long_note(sections: int = 5, items: int = 110) -> str:
    out = [HEADER]
    for k in range(1, sections + 1):
        out.append(f"## Section {k}")
        out += [f"- Section {k} item {i}: the team shipped feature x{k}y{i} to production."
                for i in range(1, items + 1)]
        out.append("")
    return "\n".join(out)


class SectionFake:
    """Writes `quota` bank blocks from the `- Section ...` lines of the prompt, one fact from the header, one term.
    `truncate_calls`: 0-based call numbers whose output is cut in the middle of a block (stop_reason max_tokens)."""
    model = "claude-sonnet-5-5"

    def __init__(self, out_tokens: int = 3000, truncate_calls: tuple[int, ...] = ()):
        self.out_tokens = out_tokens
        self.truncate_calls = truncate_calls
        self.calls: list[dict] = []

    async def generate(self, system, user, max_tokens, effort="high"):
        n = len(self.calls)
        self.calls.append({"user": user, "max_tokens": max_tokens, "effort": effort})
        quota = int(re.search(r"Write up to (\d+) @BANK", user)[1])
        lines = [(int(m[1]), m[2]) for ln in user.splitlines() if (m := re.match(r"^L(\d+): (.*)$", ln))]
        call = next((no, t) for no, t in lines if t.startswith("Call: "))
        items = [(no, t[2:]) for no, t in lines if t.startswith("- Section")]
        out = ["@FACT", "kind: date", f"text: {call[1]}", "value: 2026-10-22", f"src: prep:L{call[0]} | {call[1]}", "@END", ""]
        if items:
            out += ["@TERM", f"term: Latency {items[0][0]}", "line: Response time.", f"src: prep:L{items[0][0]} | {items[0][1]}", "@END", ""]
        for r, (no, text) in enumerate(items[:quota]):
            q = SHARED_Q if r == 0 else f"What happened with {text.split(':')[0].lower()}?"
            out += ["@BANK", "lang: en", f"question: {q}", "para.en: Tell me more.", "para.en: What was that about?",
                    "para.en: Can you explain?", f"opener: Here is the short version of item {no}.",
                    f"point: {text}", f"src: prep:L{no} | {text}", "@END", ""]
        text = "\n".join(out) + "\n"
        if n in self.truncate_calls:
            text = text[: text.rindex("@BANK") + 60]  # the last block never reaches @END
            return ModelOutput(text, Usage(input=4000, output=max_tokens, cache_read=0, cache_write=0), "max_tokens")
        return ModelOutput(text, Usage(input=4000, output=self.out_tokens), "end_turn")

    async def count_tokens(self, text):
        return len(text) // 4

    async def count_request_tokens(self, system, user):
        return (len(system) + len(user)) // 4


def run(tmp_path, note: str, model, max_questions: int = 40, **kw):
    p = tmp_path / "note.md"
    p.write_text(note, encoding="utf-8")
    session = build(p, [], ["en"], tmp_path / "out", max_questions, model=model, vault=None, now=NOW, **kw)
    meta = json.loads((session / "meta.json").read_text(encoding="utf-8"))
    bank = [json.loads(ln) for ln in (session / "bank.jsonl").read_text(encoding="utf-8").splitlines()]
    return session, meta, bank


# ---------------------------------------------------------------------------------------------- splitting


def test_split_note_covers_every_line_once_and_keeps_the_header():
    note = long_note()
    header, secs = split_note(note, 40)
    assert len(secs) == 5 and [no for no, _ in header] == [1, 2, 3, 4]
    nos = [no for no, _ in header] + [no for s in secs for no, _ in s.lines]
    assert nos == list(range(1, len(note.splitlines()) + 1))
    assert all(s.chars <= SECTION_MAX_CHARS for s in secs) and all(s.lines[0][1].startswith("## Section") for s in secs)
    assert all(4 <= s.quota <= 40 for s in secs) and sum(s.quota for s in secs) >= 40


def test_split_note_at_rules_and_without_any_separator():
    ruled = HEADER + "---\n" + "\n---\n".join(f"Block {k}\n" + "\n".join(f"- fact {k}.{i} " + "x" * 90 for i in range(100)) for k in range(5))
    header, secs = split_note(ruled, 40)
    assert len(secs) >= 3 and [t for _, t in header][0].startswith("# Interview prep")
    flat = "\n".join(t for _, t in header) + "\n" + "\n".join(t for s in secs for _, t in s.lines)
    assert flat == ruled
    plain = "\n".join(f"line {i} " + "y" * 100 for i in range(500))  # 55k chars, no heading, no rule, no blank line
    header2, secs2 = split_note(plain, 40)
    assert header2 == [] and len(secs2) >= 3 and all(s.chars <= SECTION_MAX_CHARS for s in secs2)
    assert [no for s in secs2 for no, _ in s.lines] == list(range(1, 501))


def test_short_note_stays_one_unsectioned_call():
    header, secs = split_note("# T\n\n## A\n- one\n", 40)
    assert header == [] and len(secs) == 1 and secs[0].lines[0][0] == 1


# ---------------------------------------------------------------------------------------------- the sectioned run


def test_long_note_sections_merge_without_duplicates(tmp_path):
    model = SectionFake()
    session, meta, bank = run(tmp_path, long_note(), model)  # 55k chars, 40 questions: the case that overflowed one 64k call
    assert len(model.calls) == 5
    ids = [b["id"] for b in bank]
    assert ids == [f"b{i:03d}" for i in range(1, len(bank) + 1)]  # contiguous, renumbered
    qs = [norm(b["question"]) for b in bank]
    assert len(qs) == len(set(qs)) and qs.count(norm(SHARED_Q)) == 1
    assert 40 >= len(bank) >= 35  # 5 sections x quota 10, one shared question kept once, capped at max_questions
    # interleaved by rank: the entries 2-6 (rank 1) come from five different sections; rank 0 held the shared question once
    assert len({re.search(r"Section (\d)", b["points"][0])[1] for b in bank[1:6]}) == 5
    facts = [json.loads(ln) for ln in (session / "facts.jsonl").read_text(encoding="utf-8").splitlines()]
    header_facts = [f for f in facts if f["text"].startswith("Call: ")]
    assert len(header_facts) == 1 and len({f["id"] for f in facts}) == len(facts)  # given in every section, kept once
    # refs are lines of the whole note
    last = bank[-1]["sources"][0]["ref"]
    assert int(last.split("L")[1]) > 4
    assert (session / "pack.md").read_text(encoding="utf-8").count("## ANSWER BANK") == 1


def test_header_is_in_every_section_prompt_with_original_line_numbers(tmp_path):
    model = SectionFake()
    run(tmp_path, long_note(), model)
    for k, c in enumerate(model.calls, start=1):
        u = c["user"]
        assert "# Interview prep: Staff Engineer at Halden" in u and "Call: Thursday 22 October 2026" in u
        assert f"section {k} of 5" in u and "Write up to 10 @BANK" in u
        assert f"Section {k} item 1:" in u
        assert not any(f"Section {j} item 1:" in u for j in range(1, 6) if j != k)
    assert "L1: # Interview prep" in model.calls[3]["user"] and "L1: - Section" not in model.calls[3]["user"]
    nos = [int(m[1]) for m in re.finditer(r"^L(\d+): ", model.calls[3]["user"], re.M)]
    assert nos[:2] == [1, 3] and nos[2] > 300  # header lines first, then the section at its real place in the note


def test_generation_calls_use_medium_effort_and_a_sized_budget(tmp_path):
    model = SectionFake()
    run(tmp_path, long_note(), model)
    assert {c["effort"] for c in model.calls} == {"medium"}
    assert {c["max_tokens"] for c in model.calls} == {call_max_tokens(10, 1)} and call_max_tokens(10, 1) < 64_000
    assert call_max_tokens(80, 2) == 64_000


def test_session_records_usage_per_section_and_the_total(tmp_path):
    model = SectionFake(out_tokens=3000)
    _, meta, _ = run(tmp_path, long_note(), model, budget_usd=5.0)
    secs = meta["sections"]
    assert [s["index"] for s in secs] == [1, 2, 3, 4, 5] and all(s["status"] == "ok" for s in secs)
    assert all(s["usage"]["output"] == 3000 and s["quota"] == 10 and s["attempts"][0]["effort"] == "medium" for s in secs)
    assert meta["prep_usage"]["output"] == 15000 and meta["prep_usage"]["input"] == 20000
    per = (4000 * 2.0 + 3000 * 10.0) / 1e6
    assert meta["prep_spend_usd"] == pytest.approx(5 * per) and sum(s["spend_usd"] for s in secs) == pytest.approx(5 * per, abs=1e-5)
    assert meta["stats"]["sections"] == 5 and meta["stats"]["sections_run"] == 5 and meta["budget_usd"] == 5.0


def test_budget_stop_skips_the_sections_that_would_pass_it(tmp_path):
    model = SectionFake(out_tokens=20_000)  # ~$0.208 a call
    session, meta, bank = run(tmp_path, long_note(), model, budget_usd=0.55)
    assert len(model.calls) == 2
    assert model.calls[0]["max_tokens"] <= 64_000
    st = [s["status"] for s in meta["sections"]]
    assert st == ["ok", "ok", "skipped_budget", "skipped_budget", "skipped_budget"]
    assert meta["prep_spend_usd"] <= 0.55 and meta["prep_spend_usd"] == pytest.approx(2 * (4000 * 2 + 20000 * 10) / 1e6)
    assert meta["stats"]["sections_run"] == 2
    assert any("budget stop: 3 of 5 sections were not generated" in w for w in meta["warnings"])
    assert len(bank) >= 10 and (session / "pack.md").is_file()


def test_budget_too_small_for_the_first_call_is_an_error(tmp_path):
    with pytest.raises(PrepError, match="leaves only"):
        run(tmp_path, long_note(), SectionFake(), budget_usd=0.01)


def test_truncated_section_is_retried_once_with_a_smaller_quota(tmp_path):
    model = SectionFake(truncate_calls=(1,))
    session, meta, bank = run(tmp_path, long_note(), model)
    assert len(model.calls) == 6  # five sections plus one retry
    assert "Write up to 10 @BANK" in model.calls[1]["user"] and "Write up to 5 @BANK" in model.calls[2]["user"]
    assert "Section 2 item 1:" in model.calls[2]["user"]  # the retry is the same section
    assert [c["effort"] for c in model.calls] == ["medium", "medium", "low", "medium", "medium", "medium"]
    s2 = meta["sections"][1]
    assert s2["status"] == "ok" and [a["stop_reason"] for a in s2["attempts"]] == ["max_tokens", "end_turn"]
    assert s2["attempts"][0]["bank"] >= 1 and s2["bank"] >= 5  # the first attempt's complete blocks were kept
    assert any("section 2/5: model output hit the" in w and "retrying once" in w for w in meta["warnings"])
    assert not any("cut off and dropped" in w for w in meta["warnings"])
    assert meta["prep_usage"]["input"] == 6 * 4000 and any(re.search(r"Section 2 item", b["points"][0]) for b in bank)


def test_section_that_truncates_again_is_kept_and_flagged(tmp_path):
    model = SectionFake(truncate_calls=(0, 1))
    _, meta, bank = run(tmp_path, long_note(), model)
    assert len(model.calls) == 6
    assert meta["sections"][0]["status"] == "truncated" and meta["stats"]["stop_reason"] == "max_tokens"
    assert any("section 1/5" in w and "the last block was cut off and dropped" in w for w in meta["warnings"])
    assert any("Section 1 item" in b["points"][0] for b in bank)


def test_single_call_run_truncation_also_retries(tmp_path):
    note = "# T\n\nCall: Thursday 22 October 2026, 15:00 CEST.\n\n## A\n" + "\n".join(
        f"- Section 1 item {i}: the team shipped feature x1y{i} to production." for i in range(1, 30))
    model = SectionFake(truncate_calls=(0,))
    _, meta, _ = run(tmp_path, note, model, max_questions=12)
    assert len(model.calls) == 2 and len(meta["sections"]) == 1
    assert "Write up to 12 @BANK" in model.calls[0]["user"] and "Write up to 6 @BANK" in model.calls[1]["user"]
    assert "section" not in model.calls[0]["user"].lower().split("<prep_note>")[0].replace("sections", "")  # not sectioned


# ---------------------------------------------------------------------------------------------- note limit


def test_note_over_60k_now_runs_and_over_250k_is_a_clear_error(tmp_path):
    model = SectionFake()
    run(tmp_path, long_note(sections=7, items=110), model, budget_usd=5.0)  # ~77k chars: the old limit was 60k
    assert len(model.calls) >= 5
    p = tmp_path / "huge.md"
    p.write_text("x" * (MAX_PREP_NOTE_CHARS + 1), encoding="utf-8")
    with pytest.raises(PrepError, match=r"limit is 250000.*Split it into several notes"):
        build(p, [], ["en"], tmp_path / "out2", 40, model=SectionFake(), vault=None, now=NOW)


# ---------------------------------------------------------------------------------------------- $1.152


def money(text):
    return [m for m in mentions_in(text, "prep:L1", "prep") if m.kind == "money"]


def test_dollar_amount_with_a_point_is_dollars_and_cents():
    assert money("Each request costs $1.152 on average.")[0].lo == pytest.approx(1.152)
    assert money("Latency budget costs $0.152 per call.")[0].lo == pytest.approx(0.152)
    assert money("Spend was $12.5 per seat.")[0].lo == pytest.approx(12.5)
    assert sorted(m.lo for m in money("The price is $1.152 or $1.5 each.")) == pytest.approx([1.152, 1.5])


def test_dollar_thousands_separators_still_work():
    assert money("The contract is worth $1,152 a year.")[0].lo == 1152
    assert money("The contract is worth $1,152.50 a year.")[0].lo == pytest.approx(1152.5)
    assert money("Revenue reached $12.345.678 last year.")[0].lo == 12_345_678
    assert money("Costs 1.152 EUR.")[0].lo == 1152  # only the $ sign changes the reading


def test_same_dollar_figure_written_with_different_decimals_is_not_a_conflict():
    b = book(["- Cost per request is $1.152 on average."], ["Cost per request is $1.1520 on average."])
    assert find_conflicts(b) == []
    c = find_conflicts(book(["- Cost per request is $1.152 on average."], ["Cost per request is $1,152 on average."]))
    assert len(c) == 1  # 1.152 dollars vs 1,152 dollars really do differ


# ---------------------------------------------------------------------------------------------- CLI summary


def test_cli_prints_the_per_section_summary(tmp_path, monkeypatch, capsys):
    from verse_brain.prep import __main__ as cli
    note = tmp_path / "note.md"
    note.write_text(long_note(), encoding="utf-8")
    real_build = cli.build
    monkeypatch.setattr(cli, "read_api_key", lambda: "k")
    monkeypatch.setattr(cli, "build", lambda *a, **k: real_build(*a, model=SectionFake(out_tokens=3000), now=NOW, **k))
    rc = cli.main(["--prep-note", str(note), "--out", str(tmp_path / "o"), "--no-vault", "--no-voice", "--max-questions", "40",
                   "--budget-usd", "2"])
    out = capsys.readouterr().out
    assert rc == 0 and "sections: 5 run of 5" in out and "section 5: lines L" in out and "of $2.00 budget" in out
