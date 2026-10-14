"""S1: sim prep. Posting + experience sources -> sim.json / sim_pack.md / posting.txt (no network in these tests)."""

import hashlib
import json
import socket
from datetime import datetime, timezone
from pathlib import Path

import pytest

from verse_brain.prep import keychain
from verse_brain.prep.__main__ import main
from verse_brain.prep.model import ModelOutput, PrepError, Usage
from verse_brain.prep.sim import FakeSimModel, build_sim, read_cv
from verse_brain.prep.sim_pack import question_count, render_sim_pack
from verse_brain.prep.sources import norm
from verse_brain.prep.vault import VaultRecord

FIX = Path(__file__).parent / "fixtures" / "sim"
POSTING = FIX / "posting_brightwave.txt"
CV = FIX / "cv_fictional.txt"
NOW = datetime(2026, 10, 14, 21, 30, 0, tzinfo=timezone.utc)
LATER = datetime(2026, 11, 2, 8, 5, 0, tzinfo=timezone.utc)

Q_TRACES = ("You can read traces. Given a bad answer in production, you can find why: retrieval missed, "
            "the prompt was wrong, the model picked the wrong tool.")
Q_PYTHON = "Strong Python and backend fundamentals, and the instinct to measure latency, cost and quality instead of guessing."
Q_RAG = "You know how RAG actually behaves: embeddings, vector search, chunking, reranking, and where each one breaks."
CV_HALLU = 'Cut the share of "out of stock" hallucinations from 9% to 2% by adding an exact SKU and size lookup'
CV_LATENCY = "Reduced median answer latency from 4.1 s to 2.3 s by caching embeddings"
CV_LANGFUSE = "Set up Langfuse tracing for every conversation and a golden set of 220 questions"


class Scripted:
    """Stands in for the Sonnet prep call; returns a fixed JSON payload."""

    model = "claude-sonnet-5-5"

    def __init__(self, payload: dict | str):
        self.payload = payload
        self.calls: list[tuple[str, str, str, int]] = []

    async def generate_sim(self, system, sources, params, max_tokens):
        self.calls.append((system, sources, params, max_tokens))
        text = self.payload if isinstance(self.payload, str) else json.dumps(self.payload)
        return ModelOutput(text, Usage(input=100, output=200), "end_turn")


def payload(**over) -> dict:
    p = {
        "company": "Brightwave", "role": "AI Engineer",
        "competencies": [
            {"id": "c1", "name": "Reading production traces", "posting_quote": Q_TRACES},
            {"id": "c2", "name": "Python and measurement", "posting_quote": Q_PYTHON},
            {"id": "c3", "name": "RAG behaviour", "posting_quote": Q_RAG},
        ],
        "evidence": [
            {"id": "e1", "kind": "metric", "text": "Cut out-of-stock hallucinations from 9% to 2% with an exact SKU lookup.",
             "sources": [{"handle": "cv:L10", "quote": CV_HALLU}]},
            {"id": "e2", "kind": "project", "text": "Set up Langfuse tracing and a 220-question golden set run in CI.",
             "sources": [{"handle": "cv:L12", "quote": CV_LANGFUSE}]},
        ],
        "questions": [
            {"id": "q1", "kind": "opener", "text": "Tell me about yourself.", "competency_ids": [], "evidence_ids": []},
            {"id": "q2", "kind": "behavioural", "text": "Tell me about a bad production answer you debugged.",
             "competency_ids": ["c1"], "evidence_ids": ["e1", "e2"], "follow_ups": ["What was the metric?"], "target_s": [60, 120]},
            {"id": "q3", "kind": "technical", "text": "How do you balance exact match and semantic search?",
             "competency_ids": ["c3"], "evidence_ids": ["e1"], "follow_ups": ["What broke first?", "What would you change?", "third"]},
            {"id": "q4", "kind": "role", "text": "How do you measure latency and cost?",
             "competency_ids": ["c2"], "evidence_ids": ["e2"], "follow_ups": []},
            {"id": "q5", "kind": "motivation", "text": "Why Brightwave?", "competency_ids": [], "evidence_ids": []},
        ],
        "rubric": {c: {"1": "vague", "3": "concrete", "5": "concrete with numbers"} for c in ("c1", "c2", "c3")},
    }
    p.update(over)
    return p


def build_with(tmp_path, model, *, cv=CV, note=None, now=NOW, out="sessions", **kw):
    return build_sim(POSTING, out=tmp_path / out, cv=cv, note=note, model=model, now=now, **kw)


def load(session: Path) -> dict:
    return json.loads((session / "sim.json").read_text(encoding="utf-8"))


# ------------------------------------------------------------------------------------------ contract


def test_session_folder_and_schema(tmp_path):
    session = build_with(tmp_path, FakeSimModel(), posting_url="https://jobs.ashbyhq.com/brightwave/x")
    assert session.parent == tmp_path / "sessions"
    assert session.name == "sim-20261014-2130-brightwave"
    assert {p.name for p in session.iterdir()} == {"posting.txt", "sim.json", "sim_pack.md"}
    sim = load(session)
    assert list(sim) == ["session_id", "created_at", "lang", "company", "role", "interview_type", "difficulty", "length_min",
                         "posting", "competencies", "evidence", "questions", "rubric", "warnings", "prep_model", "prep_usage"]
    assert sim["session_id"] == session.name and sim["created_at"].startswith("2026-10-14T21:30:00")
    assert (sim["lang"], sim["interview_type"], sim["difficulty"], sim["length_min"]) == ("en", "mixed", "standard", 30)
    text = POSTING.read_text(encoding="utf-8")
    assert (session / "posting.txt").read_text(encoding="utf-8") == text
    assert sim["posting"] == {"source_url": "https://jobs.ashbyhq.com/brightwave/x", "text_path": "posting.txt",
                              "sha256": hashlib.sha256(text.encode()).hexdigest()}
    assert set(sim["prep_usage"]) == {"input", "output", "cache_read", "cache_write"}
    for q in sim["questions"]:
        assert set(q) == {"id", "kind", "text", "competency_ids", "evidence_ids", "follow_ups", "target_s"}
        assert q["kind"] in {"opener", "behavioural", "role", "technical", "motivation"} and len(q["target_s"]) == 2
    for e in sim["evidence"]:
        assert e["kind"] in {"project", "metric", "story", "skill"} and e["sources"]
        assert all(set(s) == {"kind", "ref", "quote"} for s in e["sources"])
    assert set(sim["rubric"]) == {c["id"] for c in sim["competencies"]}


def test_posting_url_defaults_to_null(tmp_path):
    assert load(build_with(tmp_path, FakeSimModel()))["posting"]["source_url"] is None


def test_same_minute_same_company_gets_a_suffix(tmp_path):
    a = build_with(tmp_path, FakeSimModel())
    b = build_with(tmp_path, FakeSimModel())
    assert a != b and b.name == a.name + "-2"


# ------------------------------------------------------------------------------------------ determinism


def test_sim_pack_deterministic(tmp_path):
    a = build_with(tmp_path, FakeSimModel(), out="a", now=NOW)
    b = build_with(tmp_path, FakeSimModel(), out="b", now=LATER)
    assert a.name != b.name  # different times: the folders differ, the packs must not
    pa, pb = (a / "sim_pack.md").read_bytes(), (b / "sim_pack.md").read_bytes()
    assert pa == pb and len(pa) > 500
    pack = pa.decode()
    assert a.name not in pack and "2026-10" not in pack  # nothing per-run in the cache prefix
    assert pack == render_sim_pack(load(a)) == render_sim_pack(load(b))


def test_sim_pack_lists_everything_the_runtime_needs(tmp_path):
    session = build_with(tmp_path, Scripted(payload()))
    sim = load(session)
    pack = (session / "sim_pack.md").read_text(encoding="utf-8")
    for c in sim["competencies"]:
        assert c["id"] in pack and c["posting_quote"] in pack
    for e in sim["evidence"]:
        assert f"[{e['id']}]" in pack and e["text"] in pack and e["sources"][0]["quote"] in pack
    for q in sim["questions"]:
        assert f"[{q['id']}]" in pack and q["text"] in pack
    assert "concrete with numbers" in pack and "Brightwave" in pack


# ------------------------------------------------------------------------------------------ grounding


def norm_contains(doc: str, quote: str) -> bool:
    return norm(quote) in norm(doc)


def test_competencies_quote_posting(tmp_path):
    posting = POSTING.read_text(encoding="utf-8")
    sim = load(build_with(tmp_path, FakeSimModel()))
    assert len(sim["competencies"]) >= 3
    assert all(norm_contains(posting, c["posting_quote"]) for c in sim["competencies"])


def test_competency_that_misquotes_the_posting_is_dropped(tmp_path):
    bad = payload()
    bad["competencies"].append({"id": "c4", "name": "Leadership", "posting_quote": "You will lead a team of twelve engineers."})
    bad["rubric"]["c4"] = {"1": "a", "3": "b", "5": "c"}
    bad["questions"][1]["competency_ids"] = ["c1", "c4"]
    sim = load(build_with(tmp_path, Scripted(bad)))
    assert [c["name"] for c in sim["competencies"]] == ["Reading production traces", "Python and measurement", "RAG behaviour"]
    assert any("Leadership" in w and "posting" in w for w in sim["warnings"])
    assert "c4" not in json.dumps(sim["rubric"]) and all("Leadership" not in json.dumps(q) for q in sim["questions"])
    assert [q["competency_ids"] for q in sim["questions"] if q["kind"] == "behavioural"] == [["c1"]]


def test_quote_matching_ignores_whitespace_and_markdown(tmp_path):
    p = payload()
    p["competencies"][0]["posting_quote"] = "**You can read traces.**  Given a bad answer in production,\nyou can find why: retrieval missed"
    sim = load(build_with(tmp_path, Scripted(p)))
    assert "Reading production traces" in [c["name"] for c in sim["competencies"]]


def test_evidence_grounded_or_dropped(tmp_path):
    p = payload()
    p["evidence"].append({"id": "e3", "kind": "metric", "text": "Led a 40-person team at Google.",
                          "sources": [{"handle": "cv:L3", "quote": "Led a 40-person team at Google for five years"}]})
    p["questions"][2]["evidence_ids"] = ["e1", "e3"]
    session = build_with(tmp_path, Scripted(p))
    sim = load(session)
    assert [e["id"] for e in sim["evidence"]] == ["e1", "e2"]
    assert any("Led a 40-person team" in w for w in sim["warnings"])
    cv = CV.read_text(encoding="utf-8")
    for e in sim["evidence"]:
        for s in e["sources"]:
            assert s["kind"] == "cv" and norm_contains(cv, s["quote"])
    assert [q["evidence_ids"] for q in sim["questions"] if q["kind"] == "technical"] == [["e1"]]  # dangling id removed


def test_evidence_with_a_number_missing_from_its_quote_is_dropped(tmp_path):
    p = payload()
    p["evidence"][0]["text"] = "Cut out-of-stock hallucinations from 9% to 12% with an exact SKU lookup."
    sim = load(build_with(tmp_path, Scripted(p)))
    assert [e["text"][:10] for e in sim["evidence"]] == ["Set up Lan"]  # renumbered: the survivor is e1
    assert any("number" in w for w in sim["warnings"])


def test_evidence_keeps_only_verified_sources_and_resolves_the_line(tmp_path):
    p = payload()
    p["evidence"][0]["sources"].append({"handle": "cv:L99", "quote": "A sentence that is not in the CV at all"})
    sim = load(build_with(tmp_path, Scripted(p)))
    e1 = sim["evidence"][0]
    assert len(e1["sources"]) == 1 and e1["sources"][0]["ref"] == "cv:L10"  # the real line, not the claimed one


def test_note_vault_and_commit_sources(tmp_path):
    note = tmp_path / "about.md"
    note.write_text("# About me\nI taught myself Italian by reading support tickets from Italian customers every morning.\n", encoding="utf-8")

    class V:
        def search(self, query, limit=3, budget_chars=2500):
            return [VaultRecord("r1", "300-Projects/Verse/Retro.md", "Verse retro: we froze a 60-question eval set and reran it on every prompt change.")]

    p = payload()
    p["evidence"] = [
        {"id": "e1", "kind": "story", "text": "Learned Italian from customer tickets.",
         "sources": [{"handle": "note:L2", "quote": "taught myself Italian by reading support tickets"}]},
        {"id": "e2", "kind": "project", "text": "Froze a 60-question eval set.",
         "sources": [{"handle": "vault:V1", "quote": "froze a 60-question eval set and reran it"}]},
        {"id": "e3", "kind": "skill", "text": "Not in the vault.", "sources": [{"handle": "vault:V1", "quote": "this sentence is not in the record"}]},
    ]
    p["questions"] = p["questions"][:1] + p["questions"][-1:]
    session = build_sim(POSTING, out=tmp_path / "s", cv=None, note=note, vault=V(), model=Scripted(p), now=NOW)
    ev = load(session)["evidence"]
    assert [(e["id"], e["sources"][0]["kind"], e["sources"][0]["ref"]) for e in ev] == [
        ("e1", "note", "note:L2"), ("e2", "vault", "vault:300-Projects/Verse/Retro.md")]


def test_ids_are_renumbered_after_drops(tmp_path):
    p = payload()
    p["evidence"][0]["sources"][0]["quote"] = "this sentence is nowhere in the CV text"
    sim = load(build_with(tmp_path, Scripted(p)))
    assert [e["id"] for e in sim["evidence"]] == ["e1"] and sim["evidence"][0]["text"].startswith("Set up Langfuse")
    for q in sim["questions"]:
        assert set(q["evidence_ids"]) <= {"e1"}
    assert [q["id"] for q in sim["questions"]] == [f"q{i}" for i in range(1, len(sim["questions"]) + 1)]


# ------------------------------------------------------------------------------------------ question plan


@pytest.mark.parametrize("minutes,count", [(15, 5), (30, 8), (45, 11)])
def test_question_count_by_length(tmp_path, minutes, count):
    assert question_count(minutes) == count
    sim = load(build_with(tmp_path, FakeSimModel(), length_min=minutes))
    assert len(sim["questions"]) == count and sim["length_min"] == minutes
    kinds = [q["kind"] for q in sim["questions"]]
    assert kinds[0] == "opener" and kinds.count("opener") == 1 and "motivation" in kinds


def test_too_many_model_questions_are_cut_keeping_opener_and_motivation(tmp_path):
    p = payload()
    extra = [{"id": f"x{i}", "kind": "role", "text": f"Extra question {i}?", "competency_ids": ["c2"], "evidence_ids": []} for i in range(10)]
    p["questions"] = p["questions"][:4] + extra + p["questions"][4:]  # motivation question is last
    sim = load(build_with(tmp_path, Scripted(p), length_min=15))
    kinds = [q["kind"] for q in sim["questions"]]
    assert len(kinds) == 5 and kinds[0] == "opener" and "motivation" in kinds


def test_missing_opener_and_motivation_are_added_with_a_warning(tmp_path):
    p = payload()
    p["questions"] = p["questions"][1:4]
    sim = load(build_with(tmp_path, Scripted(p)))
    kinds = [q["kind"] for q in sim["questions"]]
    assert kinds[0] == "opener" and "motivation" in kinds
    assert any("opener" in w for w in sim["warnings"]) and any("motivation" in w for w in sim["warnings"])


def test_opener_is_moved_first_and_follow_ups_capped(tmp_path):
    p = payload()
    p["questions"].insert(0, p["questions"].pop(1))
    sim = load(build_with(tmp_path, Scripted(p)))
    assert sim["questions"][0]["kind"] == "opener"
    assert all(len(q["follow_ups"]) <= 2 for q in sim["questions"])


def test_fewer_questions_than_planned_is_a_warning_not_an_invention(tmp_path):
    sim = load(build_with(tmp_path, Scripted(payload()), length_min=45))
    assert len(sim["questions"]) == 5 and any("5 of 11" in w for w in sim["warnings"])


def test_no_evidence_still_plans(tmp_path):
    session = build_with(tmp_path, FakeSimModel(), cv=None)
    sim = load(session)
    assert sim["evidence"] == [] and len(sim["questions"]) == 8
    assert all(q["evidence_ids"] == [] for q in sim["questions"])
    assert any("no experience" in w.lower() for w in sim["warnings"])
    assert "no experience" in (session / "sim_pack.md").read_text(encoding="utf-8").lower()


def test_all_evidence_dropped_warns_too(tmp_path):
    p = payload()
    for e in p["evidence"]:
        e["sources"][0]["quote"] = "nothing like this is in the CV file"
    sim = load(build_with(tmp_path, Scripted(p)))
    assert sim["evidence"] == [] and any("no experience" in w.lower() or "no evidence" in w.lower() for w in sim["warnings"])


def test_unusable_model_output_raises_without_leaving_a_session(tmp_path):
    for bad in ("not json at all", '{"company": "X"}', json.dumps(payload(competencies=[]))):
        with pytest.raises(PrepError):
            build_with(tmp_path, Scripted(bad))
    assert not (tmp_path / "sessions").exists() or not any((tmp_path / "sessions").iterdir())


def test_json_inside_a_code_fence_is_accepted(tmp_path):
    sim = load(build_with(tmp_path, Scripted("```json\n" + json.dumps(payload()) + "\n```")))
    assert len(sim["competencies"]) == 3


# ------------------------------------------------------------------------------------------ prompt


def test_prompt_carries_posting_cv_and_parameters(tmp_path):
    m = Scripted(payload())
    build_with(tmp_path, m, interview_type="technical", difficulty="tough", length_min=45, lang="en")
    system, sources, params, max_tokens = m.calls[0]
    assert "<posting>" in sources and "agentic runtime for proactive agents" in sources
    assert "<cv>" in sources and "L10: " in sources and CV_HALLU in sources
    assert "technical" in params and "tough" in params and "11" in params and "Brightwave" not in params
    assert "verbatim" in system and max_tokens >= 8000
    assert "sk-" not in system + sources + params


def test_company_and_role_overrides_win(tmp_path):
    sim = load(build_with(tmp_path, Scripted(payload()), company="Acme Corp", role="ML Engineer"))
    assert (sim["company"], sim["role"]) == ("Acme Corp", "ML Engineer")
    assert load(build_with(tmp_path, Scripted(payload()), now=LATER)) ["company"] == "Brightwave"


# ------------------------------------------------------------------------------------------ inputs


def minimal_pdf(lines: list[str]) -> bytes:
    stream = "BT /F1 11 Tf 72 740 Td 14 TL " + " ".join(f"({ln}) Tj T*" for ln in lines) + " ET"
    objs = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        f"<< /Length {len(stream)} >>\nstream\n{stream}\nendstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = b"%PDF-1.4\n"
    offsets = []
    for i, body in enumerate(objs, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n{body}\nendobj\n".encode("latin-1")
    xref = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
    out += b"".join(f"{o:010d} 00000 n \n".encode() for o in offsets)
    out += f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return out


def test_cv_pdf_text_is_extracted(tmp_path):
    pdf = tmp_path / "cv.pdf"
    pdf.write_bytes(minimal_pdf(["Marta Lindqvist", "Reduced median answer latency from 4.1 s to 2.3 s by caching embeddings"]))
    text = read_cv(pdf)
    assert "Marta Lindqvist" in text and "median answer latency from 4.1 s to 2.3 s" in text


def test_cv_pdf_end_to_end_grounds_against_pdf_text(tmp_path):
    pdf = tmp_path / "cv.pdf"
    pdf.write_bytes(minimal_pdf(["Marta Lindqvist", CV_LATENCY + " and trimming the prompt"]))
    p = payload()
    p["evidence"] = [{"id": "e1", "kind": "metric", "text": "Cut median latency from 4.1 s to 2.3 s.",
                      "sources": [{"handle": "cv:L2", "quote": CV_LATENCY}]}]
    p["questions"] = p["questions"][:1] + p["questions"][-1:]
    sim = load(build_with(tmp_path, Scripted(p), cv=pdf))
    assert [e["id"] for e in sim["evidence"]] == ["e1"] and sim["evidence"][0]["sources"][0]["ref"] == "cv:L2"


def test_cv_without_text_or_unknown_type_is_rejected(tmp_path):
    empty = tmp_path / "scan.pdf"
    empty.write_bytes(minimal_pdf([]))
    with pytest.raises(PrepError, match="no text"):
        read_cv(empty)
    odd = tmp_path / "cv.docx"
    odd.write_text("x")
    with pytest.raises(PrepError, match=r"\.pdf, \.txt or \.md"):
        read_cv(odd)
    with pytest.raises(PrepError, match="cannot read"):
        read_cv(tmp_path / "missing.txt")


def test_bad_inputs_are_rejected_before_any_model_call(tmp_path):
    m = Scripted(payload())
    for kw in ({"interview_type": "panel"}, {"difficulty": "brutal"}, {"length_min": 3}, {"length_min": 400}):
        with pytest.raises(PrepError):
            build_with(tmp_path, m, **kw)
    blank = tmp_path / "blank.txt"
    blank.write_text("  \n")
    with pytest.raises(PrepError, match="posting"):
        build_sim(blank, out=tmp_path / "o", model=m, now=NOW)
    assert m.calls == []


# ------------------------------------------------------------------------------------------ offline / CLI


def test_fake_mode_offline(tmp_path, monkeypatch, capsys):
    def boom(*a, **k):
        raise AssertionError("network or Keychain touched in --fake mode")

    monkeypatch.setattr(socket.socket, "connect", boom)  # the event loop's own socketpair still works
    monkeypatch.setattr(socket, "getaddrinfo", boom)
    monkeypatch.setattr(socket, "create_connection", boom)
    monkeypatch.setattr(keychain, "read_api_key", boom)
    monkeypatch.setattr("verse_brain.prep.__main__.read_api_key", boom)
    monkeypatch.setattr("subprocess.run", boom)  # no `security`, no vault, no git
    rc = main(["--sim", "--fake", "--posting-file", str(POSTING), "--cv", str(CV), "--out", str(tmp_path / "s"),
               "--type", "mixed", "--difficulty", "standard", "--length", "30", "--lang", "en"])
    assert rc == 0
    out = capsys.readouterr().out.strip().splitlines()
    session = Path(out[-1])
    assert session.parent == tmp_path / "s" and session.name.startswith("sim-") and session.name.endswith("-brightwave")
    sim = load(session)
    assert sim["prep_model"] == "fake" and len(sim["questions"]) == 8 and sim["evidence"]
    assert (session / "sim_pack.md").stat().st_size > 0


def test_fake_mode_is_deterministic_across_runs(tmp_path):
    a = build_with(tmp_path, FakeSimModel(), out="a")
    b = build_with(tmp_path, FakeSimModel(), out="b")
    sa, sb = load(a), load(b)
    assert sa == sb


def test_cli_validation(tmp_path, capsys):
    with pytest.raises(SystemExit):
        main(["--sim", "--fake"])  # --posting-file is required
    with pytest.raises(SystemExit):
        main(["--sim", "--fake", "--posting-file", str(POSTING), "--prep-note", str(CV)])
    assert main(["--sim", "--fake", "--posting-file", str(tmp_path / "nope.txt"), "--out", str(tmp_path)]) == 1
    assert "cannot read" in capsys.readouterr().err
    assert main(["--sim", "--fake", "--posting-file", str(POSTING), "--out", str(tmp_path), "--length", "2"]) == 1


def test_existing_fake_flag_still_needs_from_event(tmp_path):
    with pytest.raises(SystemExit):
        main(["--fake", "--prep-note", str(CV)])


def test_recorded_live_pack_is_what_the_renderer_produces():
    """tests/fixtures/sim/live_brightwave is a real Sonnet run on the Brightwave posting and the fictional CV (for S2/S4 tests)."""
    d = FIX / "live_brightwave"
    sim = json.loads((d / "sim.json").read_text(encoding="utf-8"))
    assert (d / "sim_pack.md").read_text(encoding="utf-8") == render_sim_pack(sim)
    posting, cv = POSTING.read_text(encoding="utf-8"), CV.read_text(encoding="utf-8")
    assert all(norm_contains(posting, c["posting_quote"]) for c in sim["competencies"])
    assert all(norm_contains(cv, s["quote"]) for e in sim["evidence"] for s in e["sources"])
    assert len(sim["questions"]) == 8 and sim["questions"][0]["kind"] == "opener"
