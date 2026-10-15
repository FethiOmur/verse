"""S5: delivery numbers, grading parse + number check, deterministic render, end-to-end report with a fake transport."""

from __future__ import annotations

import asyncio
import json
import shutil
from pathlib import Path

import pytest

from verse_brain.runtime.fake import FakeTransport, Script
from verse_brain.runtime.settings import SONNET
from verse_brain.runtime.transport import Overloaded
from verse_brain.sim import delivery, grade, render
from verse_brain.sim.report import build_report

FIX = Path(__file__).resolve().parent / "fixtures" / "sim_report"
SIM = json.loads((FIX / "sim.json").read_text())
RESULTS = json.loads((FIX / "sim_results.json").read_text())
GRADE_RAW = (FIX / "grade_output.txt").read_text()


@pytest.fixture(autouse=True)
def _no_retry_delay(monkeypatch):
    monkeypatch.setattr(grade, "RETRY_DELAY_S", 0.0)


def run(coro):
    return asyncio.run(coro)


def answers_of(q_id: str) -> list[dict]:
    return next(q for q in RESULTS["questions"] if q["q_id"] == q_id)["answers"]


def all_answers() -> list[dict]:
    return [a for q in RESULTS["questions"] for a in q["answers"]]


def session_copy(tmp_path: Path) -> Path:
    dst = tmp_path / "sim-20261014-1530-brightwave"
    dst.mkdir()
    for name in ("sim.json", "sim_pack.md", "sim_results.json"):
        shutil.copy(FIX / name, dst / name)
    return dst


def responder_with(text: str):
    def responder(info):
        return Script(chunks=[(0.0, text)])
    return responder


# ---------------------------------------------------------------- delivery

def test_delivery_numbers():
    # q1: 105 words in 42 s -> 150.0 wpm; q2: 220 words in 90 + 28 = 118 s -> 111.9; q4: 220 words in 100 s -> 132.0
    assert delivery.wpm(answers_of("q1")) == 150.0
    assert delivery.wpm(answers_of("q2")) == 111.9
    assert delivery.wpm(answers_of("q4")) == 132.0
    # whole session: 545 words in 260 s -> 125.8
    assert delivery.wpm(all_answers()) == 125.8
    assert delivery.wpm([]) == 0.0
    assert delivery.wpm([{"text": "x", "t_start": 3.0, "t_end": 3.0, "words": 5, "fillers": 0}]) == 0.0

    # fillers are counted from the text: q1 um + like + you know = 3; q2 basically + kind of / actually = 2 + 1; q4 um = 1
    assert [delivery.filler_count(a["text"], "en") for a in answers_of("q1")] == [3]
    assert [delivery.filler_count(a["text"], "en") for a in answers_of("q2")] == [2, 1]
    assert [delivery.filler_count(a["text"], "en") for a in answers_of("q4")] == [1]

    # longest pause: q2's follow-up starts 162.5 - 150.0 = 12.5 s after the first answer ended; one answer -> 0
    assert delivery.longest_pause(answers_of("q2")) == 12.5
    assert delivery.longest_pause(answers_of("q1")) == 0.0
    assert delivery.longest_pause([]) == 0.0
    # unsorted input is ordered by t_start first
    assert delivery.longest_pause(list(reversed(answers_of("q2")))) == 12.5

    # answer length against target_s
    assert delivery.answer_seconds(answers_of("q2")) == 118.0
    assert delivery.length_status(42.0, [60, 120]) == "short"
    assert delivery.length_status(118.0, [60, 120]) == "on_target"
    assert delivery.length_status(130.0, [60, 120]) == "long"
    assert delivery.length_status(0.0, [60, 120]) is None
    assert delivery.length_status(50.0, None) is None


def test_filler_word_boundaries():
    assert delivery.filler_count("The umbrella is unlikely. Likewise, basicallyx is not a word.", "en") == 0
    text = "Um, so like, you know, it's basically uh like the same, kind of... Actually sort of."
    assert delivery.filler_count(text, "en") == 9
    assert delivery.filler_count("YOU   KNOW, You know", "en") == 2
    # no filler list for other languages yet: the count is 0 rather than a wrong English match
    assert delivery.filler_count("um like you know", "it") == 0


# ---------------------------------------------------------------- grading

def test_grade_parse_and_number_check():
    g = grade.parse_grades(GRADE_RAW, SIM)
    assert g is not None
    assert g["overall"] == 3
    # unknown competency c9 is dropped; the out-of-range score 7 is clamped to 5
    assert set(g["competencies"]) == {"c1", "c2", "c3"}
    assert g["competencies"]["c2"]["score"] == 5
    assert g["competencies"]["c1"] == {"score": 3, "rubric_line": "Shipped something, vague on production concerns.",
                                       "q_ids": ["q2"]}
    # exactly three practise items
    assert g["practise_next"] == ["Lead with one numbered result.", "Name a trade-off in every story.",
                                  "Prepare a Why-this-company answer."]
    q2 = next(q for q in g["questions"] if q["q_id"] == "q2")
    kept = [b["sentence"] for b in q2["better_answer"]]
    assert kept == [
        "At Lantern I added an LLM extraction step with a human review screen.",     # no number
        "Entry time per document dropped from 11 minutes to 2 minutes.",             # 11 and 2 are in e2
        "I ran 4 ad experiments for Trailhead.",                                     # 4 is in e3; e99 is not an evidence id
    ]
    # the uncited 40 and the 4 cited against e2 (which does not contain it) were dropped
    assert q2["better_answer"][2]["evidence_ids"] == ["e3"]
    assert g["dropped_sentences"] == 2


def test_number_check_units():
    ev = {"e1": "Cut entry from 11 minutes to 2 minutes, about 1,200 documents; ran four experiments."}
    ok = grade.number_supported
    assert ok("It went from 11 to 2.", ["e1"], ev)
    assert ok("We handled 1200 documents.", ["e1"], ev)          # thousands separator ignored
    assert ok("We ran 4 experiments.", ["e1"], ev)               # spelled-out number in the evidence
    assert ok("We ran four experiments.", ["e1"], ev)
    assert not ok("It went from 11 to 3.", ["e1"], ev)
    assert not ok("It went from 11 to 2.", [], ev)               # a number needs a citation
    assert not ok("That was 211 minutes.", ["e1"], ev)           # token match, not substring
    assert ok("I led the project.", [], ev)                       # no number, no citation needed


def test_parse_grades_defensive():
    assert grade.parse_grades("", SIM) is None
    assert grade.parse_grades("no json here", SIM) is None
    assert grade.parse_grades("{not json}", SIM) is None
    # bare object, no code fence, missing optional parts
    g = grade.parse_grades('{"overall": "4", "questions": "oops"}', SIM)
    assert g is not None and g["overall"] == 4 and g["questions"] == [] and g["competencies"] == {}
    assert g["practise_next"] == []


def test_grade_request_shape():
    pack = (FIX / "sim_pack.md").read_text()
    req = grade.build_request(pack, SIM, RESULTS, SONNET)
    assert req["model"] == SONNET
    assert req["max_tokens"] >= 4000
    blocks = req["messages"][0]["content"]
    # the pack is the cached prefix; the transcript follows it
    assert blocks[0]["cache_control"] == {"type": "ephemeral"}
    assert "Interview pack: Brightwave" in blocks[0]["text"]
    transcript = "".join(b["text"] for b in blocks[1:])
    assert "Why Brightwave?" in transcript and "(skipped)" in transcript
    assert "I like, you know, building things end to end" in transcript
    # coach notes are not shown to the grader
    assert "Name the one project you want them to ask about" not in transcript


# ---------------------------------------------------------------- render + report

def graded_report():
    g = grade.parse_grades(GRADE_RAW, SIM)
    return render.assemble(SIM, RESULTS, g, error=None, usage={"input_tokens": 100, "output_tokens": 50})


def test_assemble_shape():
    rep = graded_report()
    assert rep["graded"] is True
    assert [q["q_id"] for q in rep["questions"]] == ["q1", "q2", "q3", "q4"]
    q2 = rep["questions"][1]
    assert q2["delivery"] == {"seconds": 118.0, "words": 220, "wpm": 111.9, "fillers": 3, "longest_pause_s": 12.5,
                              "target_s": [60, 120], "length": "on_target"}
    assert rep["questions"][2]["skipped"] is True
    assert rep["delivery"]["wpm"] == 125.8 and rep["delivery"]["fillers"] == 7 and rep["delivery"]["longest_pause_s"] == 12.5
    # better-answer sentences carry the evidence sources
    src = q2["grade"]["better_answer"][1]["sources"]
    assert src == [{"id": "e2", "kind": "cv", "ref": "cv.pdf p1", "quote": "Reduced invoice entry from 11 to 2 minutes"}]
    assert rep["competencies"][0]["name"] == "Shipping LLM products"
    assert "generated_at" not in json.dumps(rep)


def test_render_deterministic():
    a = render.render_html(graded_report())
    b = render.render_html(graded_report())
    assert a == b
    assert a.startswith("<!doctype html>")
    assert "<script" not in a and "gradient" not in a and "shadow" not in a
    assert "http://" not in a and "https://" not in a.replace("https://example.com/jobs/ai-engineer", "")
    for q in SIM["questions"]:
        assert f'<b>{q["id"].upper()}</b>' in a


def test_render_escapes_user_text():
    res = json.loads(json.dumps(RESULTS))
    res["questions"][0]["answers"][0]["text"] = "<script>alert(1)</script> & done"
    html = render.render_html(render.assemble(SIM, res, None, error="grading unavailable", usage={}))
    assert "<script>alert" not in html
    assert "&lt;script&gt;alert(1)&lt;/script&gt; &amp; done" in html


def test_build_report_end_to_end_fake(tmp_path):
    sd = session_copy(tmp_path)
    t = FakeTransport(responder_with(GRADE_RAW))
    out = run(build_report(sd, t))
    assert out == sd / "report.html" and out.exists()
    html = out.read_text()
    for q in SIM["questions"]:
        assert q["id"].upper() in html or q["text"][:20] in html
    for name in ("grades.json", "report.json"):
        assert (sd / name).exists()
    rep = json.loads((sd / "report.json").read_text())
    assert [q["q_id"] for q in rep["questions"]] == ["q1", "q2", "q3", "q4"]
    assert json.loads((sd / "grades.json").read_text())["overall"] == 3
    # one Sonnet call, route D, model passed through, cached pack prefix
    assert len(t.calls) == 1
    call = t.calls[0]
    assert call.route == "D" and call.model == SONNET
    assert call.request["messages"][0]["content"][0]["cache_control"] == {"type": "ephemeral"}
    # nothing the model dropped appears in the page
    assert "Corrections fell by 40 percent" not in html
    assert "Entry time per document dropped from 11 minutes to 2 minutes." in html
    # the sim_pack.md the runtime wrote is untouched
    assert (sd / "sim_pack.md").read_text() == (FIX / "sim_pack.md").read_text()


def test_build_report_is_byte_identical_on_rerun(tmp_path):
    sd = session_copy(tmp_path)
    run(build_report(sd, FakeTransport(responder_with(GRADE_RAW))))
    first = (sd / "report.html").read_bytes()
    run(build_report(sd, FakeTransport(responder_with(GRADE_RAW))))
    assert (sd / "report.html").read_bytes() == first


def test_build_report_grading_failure_still_writes_page(tmp_path):
    sd = session_copy(tmp_path)

    def failing(info):
        return Script(error=Overloaded("529 overloaded"))

    t = FakeTransport(failing)
    out = run(build_report(sd, t))
    html = out.read_text()
    assert "Grading unavailable" in html
    assert "Why Brightwave?" in html and "125.8" in html      # transcript and delivery numbers survive
    rep = json.loads((sd / "report.json").read_text())
    assert rep["graded"] is False and rep["grading_error"]


def test_build_report_unparseable_model_output(tmp_path):
    sd = session_copy(tmp_path)
    t = FakeTransport(responder_with("I cannot do that."))
    out = run(build_report(sd, t))
    assert "Grading unavailable" in out.read_text()
    assert len(t.calls) == 2    # one retry on unparseable output


def test_no_evidence_is_flagged(tmp_path):
    sd = session_copy(tmp_path)
    sim = json.loads((sd / "sim.json").read_text())
    sim["evidence"] = []
    for q in sim["questions"]:
        q["evidence_ids"] = []
    sim["warnings"] = ["No experience source was provided."]
    (sd / "sim.json").write_text(json.dumps(sim))
    out = run(build_report(sd, FakeTransport(responder_with(GRADE_RAW))))
    html = out.read_text()
    assert "could not be checked against your background" in html
    assert "No experience source was provided." in html
    # without evidence every sentence containing a number is dropped
    assert "dropped from 11 minutes" not in html
    assert "I ran 4 ad experiments for Trailhead." not in html


def test_missing_sim_results_raises(tmp_path):
    sd = tmp_path / "s"
    sd.mkdir()
    shutil.copy(FIX / "sim.json", sd / "sim.json")
    with pytest.raises(FileNotFoundError):
        run(build_report(sd, FakeTransport()))
