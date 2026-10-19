"""F4b: a mock interview built from a prepared MEETING session (`--sim --from-session`). No network in these tests.

The fixture `tests/fixtures/sim_session/` is a fictional prepared session (pack.md, bank.jsonl with 7 entries, meta.json) plus a
fictional profile (me.md). The questions are decided by code; the scripted model only describes them.
"""

import json
import shutil
import socket
from datetime import datetime, timezone
from pathlib import Path

import pytest

from verse_brain.prep import keychain
from verse_brain.prep.__main__ import main
from verse_brain.prep.model import ModelOutput, PrepError, Usage
from verse_brain.prep.sim import (OPENER_TEXT, FakeSimModel, asks_background, build_sim_from_session)
from verse_brain.prep.sim_pack import question_count
from verse_brain.prep.sim_prompt import SESSION_SYSTEM
from verse_brain.prep.voice import VOICE_HEADING

FIX = Path(__file__).parent / "fixtures" / "sim_session"
VOICE = Path(__file__).parent / "fixtures" / "voice" / "profile_fictional.md"
NOW = datetime(2026, 10, 20, 14, 5, 0, tzinfo=timezone.utc)

BANK_TEXTS = {
    "b001": "Can you tell me about yourself?",
    "b002": "What is the hardest data quality problem you have solved?",
    "b003": "How do you decide when a forecast is good enough to ship?",
    "b004": "Tell me about a time you disagreed with an analyst.",
    "b005": "Why Harbor & Pine, and why now?",
    "b006": "How would you handle a late data feed from a chain?",
    "b007": "What would you do in your first month?",
}
Q_BEACON = "Beacon cut the time to produce a customer report from 5 days to 1 day."
Q_GOLDEN = "The golden set for Beacon holds 140 questions and runs on every release."
Q_FORECAST = "The team is hiring a senior data engineer to own the forecast pipeline."
Q_ME_STREAM = "At my last job I moved nightly batch jobs to a streaming setup, and late reports fell by 70%."


class Scripted:
    """Stands in for the Sonnet prep call; returns a fixed JSON payload and records the call."""

    model = "claude-sonnet-5-5"

    def __init__(self, payload: dict | str):
        self.payload = payload
        self.calls: list[tuple[str, str, str, int]] = []

    async def generate_sim(self, system, sources, params, max_tokens):
        self.calls.append((system, sources, params, max_tokens))
        text = self.payload if isinstance(self.payload, str) else json.dumps(self.payload)
        return ModelOutput(text, Usage(input=100, output=200), "end_turn")


def meta_q(bank_id, kind="behavioural", comps=("c1",), ev=("e1",), fu=("What was the number?",), **extra):
    q = {"bank_id": bank_id, "kind": kind, "competency_ids": list(comps), "evidence_ids": list(ev), "follow_ups": list(fu)}
    q.update(extra)
    return q


def payload(**over) -> dict:
    p = {
        "company": "Harbor & Pine Analytics", "role": "Senior Data Engineer",
        "competencies": [
            {"id": "c1", "name": "Owning the forecast pipeline", "pack_quote": Q_FORECAST},
            {"id": "c2", "name": "Release discipline", "pack_quote": Q_GOLDEN},
        ],
        "evidence": [
            {"id": "e1", "kind": "metric", "text": "Beacon cut report time from 5 days to 1 day.",
             "sources": [{"handle": "pack:L3", "quote": Q_BEACON}]},
            {"id": "e2", "kind": "story", "text": "Moved nightly batch jobs to streaming; late reports fell by 70%.",
             "sources": [{"handle": "me:L5", "quote": Q_ME_STREAM}]},
        ],
        "questions": [
            meta_q("opener", "opener", ev=("e1",), fu=()),
            meta_q("b001", "opener", comps=(), ev=("e1",), fu=("should be emptied",)),
            meta_q("b002", "behavioural", ("c2",), ("e1",)),
            meta_q("b003", "technical", ("c2",), ("e1",), fu=("What broke first?", "What would you change?", "third")),
            meta_q("b004", "behavioural", ("c1",), ()),
            meta_q("b005", "motivation", (), (), fu=()),
        ],
        "rubric": {c: {"1": "vague", "3": "concrete", "5": "concrete with numbers"} for c in ("c1", "c2")},
    }
    p.update(over)
    return p


@pytest.fixture
def src(tmp_path) -> Path:
    """A copy of the fixture session named like a real one."""
    d = tmp_path / "sessions-in" / "harbor-pine"
    shutil.copytree(FIX, d, ignore=shutil.ignore_patterns("me.md"))
    return d


def build(src, model, *, tmp_path, me=None, now=NOW, out="out", **kw):
    return build_sim_from_session(src, out=tmp_path / out, model=model, me=me, now=now, **kw)


def load(session: Path) -> dict:
    return json.loads((session / "sim.json").read_text(encoding="utf-8"))


def set_bank(src: Path, entries: list[tuple[str, str]] | None) -> None:
    f = src / "bank.jsonl"
    if entries is None:
        f.unlink()
        return
    f.write_text("".join(json.dumps({"id": i, "lang": "en", "question": q}) + "\n" for i, q in entries), encoding="utf-8")


# ------------------------------------------------------------------------------------------ questions decided by code


def test_questions_are_the_opener_plus_the_bank_in_order_cut_to_question_count(src, tmp_path):
    sim = load(build(src, Scripted(payload()), tmp_path=tmp_path, length_min=15))
    n = question_count(15)
    assert n == 5 and len(sim["questions"]) == 5                       # b006 and b007 are cut
    assert [q["bank_id"] for q in sim["questions"]] == ["b001", "b002", "b003", "b004", "b005"]
    assert [q["text"] for q in sim["questions"]] == [BANK_TEXTS[b] for b in ("b001", "b002", "b003", "b004", "b005")]
    assert [q["id"] for q in sim["questions"]] == ["q1", "q2", "q3", "q4", "q5"]
    assert sim["questions"][0]["kind"] == "opener" and sim["questions"][0]["follow_ups"] == []
    assert sim["warnings"] == [] or all("bank" not in w for w in sim["warnings"])


def test_question_keys_match_the_posting_schema_plus_bank_id(src, tmp_path):
    sim = load(build(src, Scripted(payload()), tmp_path=tmp_path, length_min=15))
    for q in sim["questions"]:
        assert set(q) == {"id", "kind", "text", "competency_ids", "evidence_ids", "follow_ups", "target_s", "bank_id"}
        assert q["kind"] in {"opener", "behavioural", "role", "technical", "motivation"} and len(q["target_s"]) == 2
    assert len(sim["questions"][3]["follow_ups"]) <= 2 and sim["questions"][2]["follow_ups"] == ["What broke first?", "What would you change?"]


def test_a_model_reply_that_reorders_or_rewrites_the_questions_is_ignored(src, tmp_path):
    p = payload()
    p["questions"] = list(reversed(p["questions"]))
    p["questions"][0]["text"] = "A completely different question?"
    p["questions"].append({"bank_id": "b777", "text": "An invented bank id", "kind": "role"})
    sim = load(build(src, Scripted(p), tmp_path=tmp_path, length_min=15))
    assert [q["bank_id"] for q in sim["questions"]] == ["b001", "b002", "b003", "b004", "b005"]
    assert [q["text"] for q in sim["questions"]] == [BANK_TEXTS[b] for b in ("b001", "b002", "b003", "b004", "b005")]
    assert sim["questions"][2]["kind"] == "technical"                  # the per-question fields still follow the bank_id


def test_longer_interview_than_the_bank_is_a_warning_not_an_invention(src, tmp_path):
    sim = load(build(src, Scripted(payload()), tmp_path=tmp_path, length_min=45))   # 11 questions wanted, 7 in the bank
    assert len(sim["questions"]) == 7
    assert any("7 question" in w and "of 11" in w for w in sim["warnings"])


def test_a_bank_with_fewer_than_three_entries_lets_the_model_plan_the_rest(src, tmp_path):
    set_bank(src, [("b001", BANK_TEXTS["b001"]), ("b002", BANK_TEXTS["b002"])])
    p = payload()
    p["questions"] += [
        {"kind": "technical", "text": "How would you design the weekly forecast job?", "competency_ids": ["c1"], "evidence_ids": ["e1"],
         "follow_ups": ["Where does it break?"]},
        {"kind": "role", "text": "How do you work with analysts?", "competency_ids": ["c2"], "evidence_ids": [], "follow_ups": []},
        {"text": "Third planned", "kind": "opener"},
        {"text": "Fourth planned"},
        {"text": "Fifth planned, one too many"},
    ]
    m = Scripted(p)
    sim = load(build(src, m, tmp_path=tmp_path, length_min=15))     # n = 5: 2 from the bank, 3 planned
    qs = sim["questions"]
    assert len(qs) == 5
    assert [q.get("bank_id") for q in qs] == ["b001", "b002", None, None, None]
    assert [q["text"] for q in qs[2:]] == ["How would you design the weekly forecast job?", "How do you work with analysts?",
                                           "Third planned"]
    assert qs[4]["kind"] == "role"                                     # a planned question can not be a second opener
    assert "extra_questions: 3" in m.calls[0][2]
    assert any("only 2 question" in w for w in sim["warnings"])


def test_without_a_bank_file_the_standard_opener_starts_and_the_model_plans_the_rest(src, tmp_path):
    set_bank(src, None)
    p = payload()
    p["questions"] = [{"text": f"Planned {i}?", "kind": "role", "competency_ids": ["c1"], "evidence_ids": [], "follow_ups": []}
                      for i in range(1, 7)]
    sim = load(build(src, Scripted(p), tmp_path=tmp_path, length_min=15))
    assert sim["questions"][0]["text"] == OPENER_TEXT and "bank_id" not in sim["questions"][0]
    assert sim["questions"][0]["kind"] == "opener"
    assert [q["text"] for q in sim["questions"][1:]] == ["Planned 1?", "Planned 2?", "Planned 3?", "Planned 4?"]


def test_the_model_planning_too_few_extras_is_named(src, tmp_path):
    set_bank(src, [("b002", BANK_TEXTS["b002"])])
    sim = load(build(src, Scripted(payload()), tmp_path=tmp_path, length_min=15))
    assert len(sim["questions"]) == 2                                  # standard opener + b002; the model planned none
    assert any("planned 0 of 3 extra" in w for w in sim["warnings"])


def test_b001_is_the_opener_only_when_it_asks_about_background(src, tmp_path):
    set_bank(src, [("b001", "What is your current notice period?")] + [(b, BANK_TEXTS[b]) for b in ("b002", "b003", "b004", "b005")])
    sim = load(build(src, Scripted(payload()), tmp_path=tmp_path, length_min=15))
    assert sim["questions"][0]["text"] == OPENER_TEXT and "bank_id" not in sim["questions"][0]
    assert [q.get("bank_id") for q in sim["questions"]] == [None, "b001", "b002", "b003", "b004"]


@pytest.mark.parametrize("q,expected", [
    ("Can you tell me about yourself?", True), ("Walk us through your background.", True), ("Parlami di te.", True),
    ("Kendinizden biraz bahseder misiniz?", True), ("Why do you want this job?", False)])
def test_asks_background(q, expected):
    assert asks_background(q) is expected


def test_duplicate_bank_ids_are_refused(src, tmp_path):
    set_bank(src, [("b001", BANK_TEXTS["b001"]), ("b002", "One?"), ("b002", "Two?"), ("b003", "Three?")])
    with pytest.raises(PrepError, match="twice"):
        build(src, Scripted(payload()), tmp_path=tmp_path)


# ------------------------------------------------------------------------------------------ grounding


def test_competency_quotes_not_in_the_pack_are_dropped_with_a_warning(src, tmp_path):
    p = payload()
    p["competencies"].append({"id": "c3", "name": "Streaming", "pack_quote": Q_ME_STREAM})            # this is in me.md, not the pack
    p["competencies"].append({"id": "c4", "name": "Invented", "pack_quote": "Harbor & Pine sells weather forecasts to airlines."})
    sim = load(build(src, Scripted(p), tmp_path=tmp_path, length_min=15, me=FIX / "me.md"))
    assert [c["name"] for c in sim["competencies"]] == ["Owning the forecast pipeline", "Release discipline"]
    assert sum("dropped: its posting_quote is not text from the prep pack" in w for w in sim["warnings"]) == 2
    assert all(c["posting_quote"] in (Q_FORECAST, Q_GOLDEN) for c in sim["competencies"])


def test_competency_quote_matching_ignores_whitespace_and_markdown(src, tmp_path):
    p = payload()
    p["competencies"][0]["pack_quote"] = "the  team is **hiring** a senior data engineer\nto own the forecast pipeline."
    sim = load(build(src, Scripted(p), tmp_path=tmp_path, length_min=15))
    assert len(sim["competencies"]) == 2


def test_no_usable_competency_raises_and_leaves_no_session(src, tmp_path):
    p = payload()
    p["competencies"] = [{"id": "c1", "name": "x", "pack_quote": "This sentence is not in the pack at all, sorry."}]
    with pytest.raises(PrepError, match="prep pack"):
        build(src, Scripted(p), tmp_path=tmp_path)
    assert not (tmp_path / "out").exists() or list((tmp_path / "out").iterdir()) == []


def test_evidence_from_the_pack_and_the_profile_is_verified_and_the_line_resolved(src, tmp_path):
    p = payload()
    p["evidence"][0]["sources"][0]["handle"] = "pack:L1"                       # a wrong line number is corrected from the text
    sim = load(build(src, Scripted(p), tmp_path=tmp_path, length_min=15, me=FIX / "me.md"))
    e1, e2 = sim["evidence"]
    assert e1["sources"] == [{"kind": "pack", "ref": "pack:L3", "quote": Q_BEACON}]
    assert e2["sources"] == [{"kind": "me", "ref": "me:L5", "quote": Q_ME_STREAM}]
    pack_lines = (src / "pack.md").read_text(encoding="utf-8").splitlines()
    assert Q_BEACON in pack_lines[2]


def test_evidence_citing_the_profile_without_a_profile_is_dropped(src, tmp_path):
    sim = load(build(src, Scripted(payload()), tmp_path=tmp_path, length_min=15))          # no --me
    assert [e["id"] for e in sim["evidence"]] == ["e1"]
    assert any("evidence dropped" in w and "Moved nightly" in w for w in sim["warnings"])
    assert sim["questions"][1]["evidence_ids"] == ["e1"]


def test_evidence_with_an_ungrounded_number_is_dropped_and_ids_renumber(src, tmp_path):
    p = payload()
    p["evidence"].insert(0, {"id": "e0", "kind": "metric", "text": "Beacon cut report time from 9 days to 1 day.",
                             "sources": [{"handle": "pack:L3", "quote": Q_BEACON}]})
    sim = load(build(src, Scripted(p), tmp_path=tmp_path, length_min=15, me=FIX / "me.md"))
    assert [e["id"] for e in sim["evidence"]] == ["e1", "e2"]
    assert any("a number is not in its source quote" in w for w in sim["warnings"])
    assert sim["questions"][1]["evidence_ids"] == ["e1"]                # b002 pointed at the old e1, which is now the real e1


def test_no_verified_evidence_still_plans_with_a_warning(src, tmp_path):
    p = payload(evidence=[])
    sim = load(build(src, Scripted(p), tmp_path=tmp_path, length_min=15))
    assert sim["evidence"] == [] and any("No evidence item could be verified" in w for w in sim["warnings"])


# ------------------------------------------------------------------------------------------ the folder and sim.json


def test_output_folder_name_and_source_fields(src, tmp_path):
    session = build(src, Scripted(payload()), tmp_path=tmp_path, length_min=15)
    assert session.parent == tmp_path / "out" and session.name == "sim-20261020-1405-harbor-pine"
    assert {p.name for p in session.iterdir()} == {"source_pack.md", "sim.json", "sim_pack.md"}      # no posting.txt
    sim = load(session)
    assert sim["session_id"] == session.name and sim["source"] == "session" and sim["source_session"] == "harbor-pine"
    assert sim["posting"]["source_url"] is None and sim["posting"]["text_path"] == "source_pack.md"
    assert sim["company"] == "Harbor & Pine Analytics" and sim["role"] == "Senior Data Engineer"
    assert (sim["interview_type"], sim["difficulty"], sim["length_min"]) == ("mixed", "standard", 15)
    assert (session / "source_pack.md").read_text(encoding="utf-8") == (src / "pack.md").read_text(encoding="utf-8")
    assert set(sim["prep_usage"]) == {"input", "output", "cache_read", "cache_write"}


def test_a_second_build_in_the_same_minute_gets_a_suffix(src, tmp_path):
    a = build(src, Scripted(payload()), tmp_path=tmp_path)
    b = build(src, Scripted(payload()), tmp_path=tmp_path)
    assert a.name == "sim-20261020-1405-harbor-pine" and b.name == "sim-20261020-1405-harbor-pine-2"


def test_language_comes_from_meta_then_the_argument(src, tmp_path):
    assert load(build(src, Scripted(payload()), tmp_path=tmp_path, out="a"))["lang"] == "en"      # languages ["en", "it"]
    meta = json.loads((src / "meta.json").read_text(encoding="utf-8"))
    meta["languages"] = ["it", "en"]
    (src / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
    m = Scripted(payload())
    assert load(build(src, m, tmp_path=tmp_path, out="b"))["lang"] == "it"
    assert "language: Italian (it)" in m.calls[0][2]
    assert load(build(src, Scripted(payload()), tmp_path=tmp_path, out="c", lang="TR"))["lang"] == "tr"
    (src / "meta.json").unlink()
    assert load(build(src, Scripted(payload()), tmp_path=tmp_path, out="d"))["lang"] == "en"


def test_company_comes_from_meta_conversation_unless_overridden(src, tmp_path):
    p = payload(company="Something The Model Read")
    assert load(build(src, Scripted(p), tmp_path=tmp_path, out="a"))["company"] == "Harbor & Pine Analytics"
    assert load(build(src, Scripted(p), tmp_path=tmp_path, out="b", company="Override Inc"))["company"] == "Override Inc"
    meta = json.loads((src / "meta.json").read_text(encoding="utf-8"))
    del meta["conversation"]
    (src / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
    assert load(build(src, Scripted(p), tmp_path=tmp_path, out="c"))["company"] == "Something The Model Read"


def test_sim_pack_is_deterministic_and_the_runtime_can_read_it(src, tmp_path):
    a = build(src, Scripted(payload()), tmp_path=tmp_path, out="a", length_min=15)
    b = build(src, Scripted(payload()), tmp_path=tmp_path, out="b", length_min=15)
    assert (a / "sim_pack.md").read_text(encoding="utf-8") == (b / "sim_pack.md").read_text(encoding="utf-8")
    text = (a / "sim_pack.md").read_text(encoding="utf-8")
    assert BANK_TEXTS["b003"] in text and "## QUESTION PLAN" in text and "pack:L3" in text


def test_the_style_guide_is_not_a_source_but_the_voice_profile_is_appended(src, tmp_path):
    pack = (src / "pack.md").read_text(encoding="utf-8").rstrip("\n")
    (src / "pack.md").write_text(pack + f"\n\n{VOICE_HEADING} (how to speak)\nNever say synergy. Short sentences.\n", encoding="utf-8")
    m = Scripted(payload())
    session = build(src, m, tmp_path=tmp_path, length_min=15, voice_path=VOICE)
    source = (session / "source_pack.md").read_text(encoding="utf-8")
    assert VOICE_HEADING not in source and "synergy" not in source and "## SNIPPETS" in source
    assert "synergy" not in m.calls[0][1]
    assert VOICE_HEADING in (session / "sim_pack.md").read_text(encoding="utf-8")
    assert "voice_sha256" in load(session)


def test_prompt_carries_the_pack_the_profile_and_the_fixed_questions(src, tmp_path):
    m = Scripted(payload())
    build(src, m, tmp_path=tmp_path, length_min=15, me=FIX / "me.md", interview_type="technical", difficulty="tough")
    system, sources, params, max_tokens = m.calls[0]
    assert system == SESSION_SYSTEM and max_tokens == 32_000
    assert sources.startswith("<pack>\nL1: ## FACTS") and "L3: [f002] number | Beacon cut" in sources
    assert "<me>\nL1: # About Tomas Varga (fictional)" in sources and sources.index("<pack>") < sources.index("<me>")
    assert "interview_type: technical" in params and "difficulty: tough" in params and "question_count: 5" in params
    assert "Q b001 | Can you tell me about yourself?" in params and "Q b005 | Why Harbor & Pine, and why now?" in params
    assert "b006" not in params and "extra_questions: 0" in params
    assert "company_hint: Harbor & Pine Analytics" in params


def test_the_sources_block_is_byte_identical_across_builds_so_it_can_be_cached(src, tmp_path):
    a, b = Scripted(payload()), Scripted(payload())
    build(src, a, tmp_path=tmp_path, out="a", length_min=15, difficulty="friendly")
    build(src, b, tmp_path=tmp_path, out="b", length_min=45, difficulty="tough")
    assert a.calls[0][1] == b.calls[0][1] and a.calls[0][2] != b.calls[0][2]


def test_bad_inputs_are_rejected_before_any_model_call(src, tmp_path):
    m = Scripted(payload())
    for kw in ({"interview_type": "panel"}, {"difficulty": "brutal"}, {"length_min": 3}, {"length_min": 400}):
        with pytest.raises(PrepError):
            build(src, m, tmp_path=tmp_path, **kw)
    with pytest.raises(PrepError, match="does not exist"):
        build(tmp_path / "nope", m, tmp_path=tmp_path)
    (src / "pack.md").write_text("  \n", encoding="utf-8")
    with pytest.raises(PrepError, match="empty"):
        build(src, m, tmp_path=tmp_path)
    (src / "pack.md").unlink()
    with pytest.raises(PrepError, match="cannot read pack.md"):
        build(src, m, tmp_path=tmp_path)
    empty_me = tmp_path / "me.md"
    empty_me.write_text("\n")
    shutil.copy(FIX / "pack.md", src / "pack.md")
    with pytest.raises(PrepError, match="profile"):
        build(src, m, tmp_path=tmp_path, me=empty_me)
    assert m.calls == []


def test_unusable_model_output_raises_without_leaving_a_session(src, tmp_path):
    with pytest.raises(PrepError, match="not JSON"):
        build(src, Scripted("sorry, no"), tmp_path=tmp_path)
    assert not list((tmp_path / "out").glob("sim-*")) if (tmp_path / "out").exists() else True


def test_a_bad_bank_line_is_skipped_and_named(src, tmp_path):
    f = src / "bank.jsonl"
    f.write_text("{not json\n" + f.read_text(encoding="utf-8"), encoding="utf-8")
    sim = load(build(src, Scripted(payload()), tmp_path=tmp_path, length_min=15))
    assert len(sim["questions"]) == 5 and any("bank.jsonl line 1" in w for w in sim["warnings"])


# ------------------------------------------------------------------------------------------ offline / CLI


def _no_network(monkeypatch):
    def boom(*a, **k):
        raise AssertionError("network or Keychain touched in --fake mode")

    monkeypatch.setattr(socket.socket, "connect", boom)
    monkeypatch.setattr(socket, "getaddrinfo", boom)
    monkeypatch.setattr(socket, "create_connection", boom)
    monkeypatch.setattr(keychain, "read_api_key", boom)
    monkeypatch.setattr("verse_brain.prep.__main__.read_api_key", boom)
    monkeypatch.setattr("subprocess.run", boom)


def test_fake_model_builds_a_grounded_interview_from_the_pack_and_the_profile(src, tmp_path):
    session = build(src, FakeSimModel(), tmp_path=tmp_path, length_min=15, me=FIX / "me.md")
    sim = load(session)
    assert sim["prep_model"] == "fake" and len(sim["questions"]) == 5 and sim["competencies"] and sim["evidence"]
    assert [q["bank_id"] for q in sim["questions"]] == ["b001", "b002", "b003", "b004", "b005"]
    assert any(s["kind"] == "me" for e in sim["evidence"] for s in e["sources"])
    assert not any("dropped" in w for w in sim["warnings"]), sim["warnings"]


def test_fake_model_plans_the_missing_questions_when_the_bank_is_small(src, tmp_path):
    set_bank(src, [("b001", BANK_TEXTS["b001"])])
    sim = load(build(src, FakeSimModel(), tmp_path=tmp_path, length_min=15))
    assert len(sim["questions"]) == 5
    assert sim["questions"][0]["bank_id"] == "b001" and all("bank_id" not in q for q in sim["questions"][1:])


def test_cli_fake_from_session_is_offline(src, tmp_path, monkeypatch, capsys):
    _no_network(monkeypatch)
    rc = main(["--sim", "--fake", "--from-session", str(src), "--me", str(FIX / "me.md"), "--out", str(tmp_path / "s"),
               "--type", "manager", "--difficulty", "friendly", "--length", "15"])
    assert rc == 0
    cap = capsys.readouterr()
    session = Path(cap.out.strip().splitlines()[-1])
    assert session.parent == tmp_path / "s" and session.name.endswith("-harbor-pine") and session.name.startswith("sim-")
    sim = load(session)
    assert sim["source"] == "session" and sim["lang"] == "en" and (sim["interview_type"], sim["difficulty"]) == ("manager", "friendly")
    assert len(cap.out.strip().splitlines()) == 1 and "questions 5" in cap.err


def test_cli_lang_default_is_the_session_language_and_explicit_lang_wins(src, tmp_path, monkeypatch, capsys):
    _no_network(monkeypatch)
    meta = json.loads((src / "meta.json").read_text(encoding="utf-8"))
    meta["languages"] = ["tr"]
    (src / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
    assert main(["--sim", "--fake", "--from-session", str(src), "--out", str(tmp_path / "a"), "--length", "15"]) == 0
    assert load(Path(capsys.readouterr().out.strip().splitlines()[-1]))["lang"] == "tr"
    assert main(["--sim", "--fake", "--from-session", str(src), "--out", str(tmp_path / "b"), "--length", "15", "--lang", "it,en"]) == 0
    assert load(Path(capsys.readouterr().out.strip().splitlines()[-1]))["lang"] == "it"


def test_cli_validation(src, tmp_path, capsys):
    with pytest.raises(SystemExit):
        main(["--sim", "--fake", "--from-session", str(src), "--posting-file", str(src / "pack.md")])
    with pytest.raises(SystemExit):
        main(["--sim", "--fake", "--from-session", str(src), "--cv", str(src / "pack.md")])
    with pytest.raises(SystemExit):
        main(["--sim", "--fake", "--posting-file", str(src / "pack.md"), "--me", str(FIX / "me.md")])
    assert main(["--sim", "--fake", "--from-session", str(tmp_path / "nope"), "--out", str(tmp_path)]) == 1
    assert "does not exist" in capsys.readouterr().err
    assert main(["--sim", "--fake", "--from-session", str(src), "--out", str(tmp_path), "--me", str(tmp_path / "nope.md")]) == 1
    assert "cannot read profile" in capsys.readouterr().err
