"""Interviewer persona of a sim (prep/sim_persona.py), its per-answer checks (sim/checks.py) and the runtime/report wiring.
Everything is opt-in: a sim without a persona is built and run as before (the other sim tests pin that)."""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import pytest
from test_runtime_sim import Rig, run, session_copy

from verse_brain.prep.__main__ import main
from verse_brain.prep.model import PrepError
from verse_brain.prep.sim_persona import build_persona
from verse_brain.prep.sim_prompt import render_params, render_session_params
from verse_brain.runtime.sim import persona_text
from verse_brain.sim.checks import answer_checks, check_lines
from verse_brain.sim.render import assemble, render_html

FIX = Path(__file__).resolve().parent / "fixtures" / "sim_session"
PERSONA = {"name": "Sam Carter", "role": "Head of Engineering", "focus": ["ownership and AI use", "evals", "cost and latency"],
           "answer_target_s": [30, 60]}


def _answer(text: str, secs: float) -> list[dict]:
    return [{"text": text, "t_start": 0.0, "t_end": secs, "words": len(text.split()), "fillers": 0}]


EVIDENCE = [{"id": "e1", "kind": "metric", "text": "Lantern cut manual data entry from 11 minutes to 2 minutes per invoice.",
             "sources": [{"kind": "cv", "ref": "cv:L5", "quote": "cut manual entry from 11 to 2 minutes per invoice"}]}]


# ------------------------------------------------------------------------------------------------------------ persona

def test_build_persona_flags_file_and_defaults(tmp_path):
    assert build_persona() is None
    p = build_persona(name=" Sam  Carter ", role="Head of Engineering", focus="ownership and AI use, evals; evals, cost")
    assert p == {"name": "Sam Carter", "role": "Head of Engineering", "focus": ["ownership and AI use", "evals", "cost"],
                 "answer_target_s": [30, 60]}
    f = tmp_path / "persona.json"
    f.write_text(json.dumps({"name": "Pat", "focus": ["trade-offs"], "answer_target_s": "20-45"}), encoding="utf-8")
    assert build_persona(file=f) == {"name": "Pat", "focus": ["trade-offs"], "answer_target_s": [20, 45]}
    assert build_persona(file=f, name="Sam", answer_target="40-90")["answer_target_s"] == [40, 90]    # flags win
    with pytest.raises(PrepError):
        build_persona(name="Sam", answer_target="soon")
    with pytest.raises(PrepError):
        build_persona(file=tmp_path / "missing.json")


def test_focus_reaches_the_prep_params_only_with_a_persona():
    plain = render_session_params("mixed", "standard", 15, 5, "en", [("b1", "Q?")], 0, None, None)
    assert "interviewer_focus" not in plain
    assert plain == render_session_params("mixed", "standard", 15, 5, "en", [("b1", "Q?")], 0, None, None, None)
    with_focus = render_session_params("mixed", "standard", 15, 5, "en", [("b1", "Q?")], 0, None, None, ["evals", "cost"])
    assert "interviewer_focus: evals; cost" in with_focus
    assert "interviewer_focus" not in render_params("mixed", "standard", 15, 5, "en", None, None)
    assert "interviewer_focus: evals" in render_params("mixed", "standard", 15, 5, "en", None, None, ["evals"])


def test_cli_persona_is_stored_and_sets_the_answer_target(tmp_path, capsys):
    src = tmp_path / "in" / "harbor-pine"
    shutil.copytree(FIX, src, ignore=shutil.ignore_patterns("me.md"))
    args = ["--sim", "--fake", "--no-voice", "--from-session", str(src), "--length", "15"]
    assert main(args + ["--out", str(tmp_path / "a"), "--interviewer-name", "Sam Carter", "--interviewer-role", "Head of Engineering",
                        "--focus", "ownership and AI use, evals", "--focus", "cost and latency"]) == 0
    sim = json.loads((Path(capsys.readouterr().out.strip().splitlines()[-1]) / "sim.json").read_text(encoding="utf-8"))
    assert sim["persona"] == {"name": "Sam Carter", "role": "Head of Engineering",
                              "focus": ["ownership and AI use", "evals", "cost and latency"], "answer_target_s": [30, 60]}
    assert {tuple(q["target_s"]) for q in sim["questions"]} == {(30, 60)}
    assert main(args + ["--out", str(tmp_path / "b")]) == 0
    plain = json.loads((Path(capsys.readouterr().out.strip().splitlines()[-1]) / "sim.json").read_text(encoding="utf-8"))
    assert "persona" not in plain and {tuple(q["target_s"]) for q in plain["questions"]} != {(30, 60)}
    with pytest.raises(SystemExit):
        main(["--prep-note", str(FIX / "pack.md"), "--focus", "evals"])      # persona flags need --sim


# ------------------------------------------------------------------------------------------------------------ checks

def test_checks_length_against_the_target():
    c = answer_checks(_answer("I led it.", 20), [30, 60], evidence=EVIDENCE)
    assert c["length"] == "short" and check_lines(c)[0].startswith("Length: 20 s, under the 30-60 s target")
    assert answer_checks(_answer("I led it.", 45), [30, 60], evidence=EVIDENCE)["length"] == "on_target"
    c = answer_checks(_answer("I led it.", 95), [30, 60], evidence=EVIDENCE)
    assert c["length"] == "long" and "over the 30-60 s target" in check_lines(c)[0]


def test_checks_flag_over_eager_phrasing_but_not_level_answers():
    eager = answer_checks(_answer("I would really love to join, I'm so excited and this is my dream job.", 40), [30, 60], evidence=EVIDENCE)
    assert eager["eager"] and any(l.startswith("Tone: eager phrasing") for l in check_lines(eager))
    level = answer_checks(_answer("I led Lantern and I want to work on assistants that talk to customers.", 40), [30, 60], evidence=EVIDENCE)
    assert level["eager"] == [] and not any(l.startswith("Tone") for l in check_lines(level))
    many = answer_checks(_answer("It was really good, really useful, absolutely great and totally amazing.", 40), [30, 60], evidence=EVIDENCE)
    assert many["intensifiers"] > 3 and any(l.startswith("Tone") for l in check_lines(many))


def test_checks_flag_unsupported_numbers_and_names_only():
    ok = answer_checks(_answer("I led Lantern. It cut entry from 11 to 2 minutes per invoice.", 40), [30, 60], evidence=EVIDENCE)
    assert ok["unsupported_numbers"] == [] and ok["unsupported_names"] == []
    bad = answer_checks(_answer("I led Lantern with Kubernetes and it saved 40 percent, then 7 teams used it.", 40), [30, 60],
                        evidence=EVIDENCE)
    assert bad["unsupported_numbers"] == ["7", "40"] and bad["unsupported_names"] == ["Kubernetes"]
    line = [l for l in check_lines(bad) if l.startswith("Not in your sources")][0]
    assert "numbers 7, 40" in line and "names Kubernetes" in line
    # a number from the posting / source pack text counts as supported
    assert answer_checks(_answer("The team has 12 people.", 40), [30, 60], evidence=EVIDENCE,
                         source_text="A team of 12 people.")["unsupported_numbers"] == []


def test_checks_clarity_flags():
    c = answer_checks(_answer("um so like basically um it was kind of a thing, you know", 40), [30, 60], evidence=EVIDENCE)
    assert c["fillers"] >= 3 and "no number" in c["vague"]
    assert any(l.startswith("Clarity:") and "filler words" in l for l in check_lines(c))


# ------------------------------------------------------------------------------------------------------------ runtime

def _persona_session(tmp_path):
    d = session_copy(tmp_path, persona={**PERSONA})
    sim = json.loads((d / "sim.json").read_text(encoding="utf-8"))
    for q in sim["questions"]:
        q["target_s"] = [30, 60]
    (d / "sim.json").write_text(json.dumps(sim), encoding="utf-8")
    return d


def test_runtime_persona_system_checks_and_coach_lines(tmp_path):
    rig = Rig(tmp_path, session=_persona_session(tmp_path))

    async def go():
        await rig.start("coach")
        await rig.wait_listen("q1")
        await rig.answer("q1", "I would love to join. I led Lantern with Kubernetes and it saved 40 percent.", dur=75.0)
        await rig.wait_listen("q2")
        await rig.control("end")
        await rig.finished()
        await rig.close()

    run(go())
    system = rig.t.calls[0].request["system"][0]["text"]
    assert system.endswith(persona_text(PERSONA)) and "Sam Carter (Head of Engineering)" in system
    assert "ownership and AI use; evals; cost and latency" in system and "30 to 60 seconds" in system
    first_ask = [c for c in rig.t.calls if c.tail.startswith("TASK: ASK")][0].tail
    assert "Introduce yourself by the name Sam Carter" in first_ask
    coach = [e for e in rig.em.events if e["type"] == "coach" and e["q_id"] == "q1"][0]["lines"]
    assert coach[0].startswith("You opened") and any(l.startswith("Length: 75 s, over the 30-60 s target") for l in coach)
    assert any(l.startswith("Tone: eager") for l in coach) and any("Kubernetes" in l and "40" in l for l in coach)
    q1 = rig.results()["questions"][0]
    assert q1["checks"]["length"] == "long" and q1["checks"]["unsupported_numbers"] == ["40"]
    assert q1["coach"][0].startswith("You opened") and not any(l.startswith("Length") for l in q1["coach"])


def test_runtime_without_persona_is_unchanged(tmp_path):
    rig = Rig(tmp_path)

    async def go():
        await rig.start("coach")
        await rig.wait_listen("q1")
        await rig.answer("q1", "I would love to join. I led Lantern and it saved 40 percent.", dur=75.0)
        await rig.wait_listen("q2")
        await rig.control("end")
        await rig.finished()
        await rig.close()

    run(go())
    assert "Your persona" not in rig.t.calls[0].request["system"][0]["text"]
    coach = [e for e in rig.em.events if e["type"] == "coach" and e["q_id"] == "q1"][0]["lines"]
    assert len(coach) == 2 and not any(l.startswith(("Length", "Tone")) for l in coach)
    assert "checks" not in rig.results()["questions"][0]


# ------------------------------------------------------------------------------------------------------------ report

def test_report_carries_the_checks_only_for_a_persona_sim(tmp_path):
    sim = json.loads((session_copy(tmp_path, persona={**PERSONA}) / "sim.json").read_text(encoding="utf-8"))
    checks = answer_checks(_answer("I would love to join; it saved 40 percent.", 80), [30, 60], evidence=sim["evidence"])
    results = {"questions": [{"q_id": "q1", "asked": [], "answers": _answer("I would love to join; it saved 40 percent.", 80),
                              "coach": [], "skipped": False, "checks": checks}]}
    r = assemble(sim, results, None, error="x", usage={})
    assert r["questions"][0]["check_lines"] and "Answer checks" in render_html(r) and "over the" in render_html(r)
    del results["questions"][0]["checks"]
    r2 = assemble(sim, results, None, error="x", usage={})
    assert "check_lines" not in r2["questions"][0] and "Answer checks" not in render_html(r2)


def test_grader_lists_unsupported_claims_only_for_a_persona_sim(tmp_path):
    from verse_brain.sim import grade

    sim = json.loads((session_copy(tmp_path) / "sim.json").read_text(encoding="utf-8"))
    raw = json.dumps({"overall": 3, "competencies": {}, "practise_next": [],
                      "questions": [{"q_id": "q1", "strong": ["a"], "missing": ["b"], "unsupported": ["I cut cost by half"],
                                     "better_answer": []}]})
    assert "unsupported" not in grade._tail(sim) and "unsupported" not in grade.parse_grades(raw, sim)["questions"][0]
    sim["persona"] = dict(PERSONA)
    assert '"unsupported": ["..."]' in grade._tail(sim)
    assert grade.parse_grades(raw, sim)["questions"][0]["unsupported"] == ["I cut cost by half"]
