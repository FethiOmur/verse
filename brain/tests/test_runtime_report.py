"""Post-call health report (runtime/report.py): synthetic session folders only, built here."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from verse_brain.runtime import report

T0 = 1_700_000_000.0
NAME = "demo-call"


def iso(t: float) -> str:
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{int((t % 1) * 1000):03d}Z"


def row(tid, speaker, text, ta, kind="question", addressee="me", run_start=T0):
    return {"turn_id": tid, "speaker": speaker, "text": text, "kind": kind, "addressee": addressee, "lang": "en",
            "t_audio_end": ta, "t_wall": run_start + ta, "run_start": run_start}


def ev(t, name, **f):
    return {"t": t, "ev": name, **f}


def write_jsonl(path: Path, items) -> None:
    lines = []
    for it in items:
        lines.append(it if isinstance(it, str) else json.dumps(it))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def full_session(tmp: Path) -> tuple[Path, Path]:
    s = tmp / NAME
    s.mkdir()
    (s / "pack.md").write_text("# pack\n", encoding="utf-8")
    rows = [
        row("m1", "me", "Hi, thanks for having me.", 5.0, kind="statement", addressee="unknown"),
        row("r1", "remote", "What is your notice period?", 10.0),
        row("r2", "remote", "How would you scale the pipeline?", 20.0),
        row("r3", "remote", "Can you walk me through the budget?", 30.0),
        row("r4", "remote", "Sam, can you share the screen?", 40.0, addressee="other"),
        row("r5", "remote", "I guess the next part is about the team structure", 50.0, kind="statement"),
        row("r6", "remote", "Why did you leave your last role?", 60.0),
        row("m2", "me", "So that was the main reason.", 200.0, kind="statement", addressee="unknown"),
        row("r7", "remote", "What salary range are you thinking?", 205.0),
        "{broken row",
    ]
    write_jsonl(s / "transcript.jsonl", rows)
    events = [
        ev(T0 + 1, "start", mode="prepared", route="meeting", lang="en", room_auto="questions"),
        ev(T0 + 10.1, "turn", turn="r1", speaker="remote", kind="question", cue=True, text="What is your notice period?"),
        ev(T0 + 11.2, "card", turn="r1", tier="F", id="f0001", kind="say", text="One month from signing."),
        ev(T0 + 11.9, "card_done", turn="r1", tier="F", id="f0001", say="One month from signing, flexible.", points=[]),
        ev(T0 + 20.1, "turn", turn="r2", speaker="remote", kind="question", cue=True, text="How would you scale it?"),
        ev(T0 + 24.5, "card", turn="r2", tier="S", id="s0002", kind="say", text="Shard by tenant first."),
        ev(T0 + 30.1, "turn", turn="r3", speaker="remote", kind="question", cue=True, text="Budget?"),
        ev(T0 + 40.1, "turn", turn="r4", speaker="remote", kind="question", cue=True, text="Share the screen?"),
        ev(T0 + 41.0, "card", turn="r4", tier="F", id="f0004", kind="say", text="Sure, one second."),
        ev(T0 + 50.1, "turn", turn="r5", speaker="remote", kind="statement", cue=False, text="next part"),
        ev(T0 + 50.5, "probe", turn="r5", id="f0005", verdict="none", error="overloaded"),
        ev(T0 + 60.1, "turn", turn="r6", speaker="remote", kind="question", cue=True, text="Why did you leave?"),
        ev(T0 + 60.3, "own_card", turn="r6", source="bank", bank="b001", lines=3),
        ev(T0 + 62.0, "bank_verdict", turn="r6", bank="b001", said="none", agree=False, via="embed"),
        ev(T0 + 205.1, "turn", turn="r7", speaker="remote", kind="question", cue=True, text="Salary range?"),
        ev(T0 + 206.0, "card", turn="r7", tier="D", id="d0007", kind="point", text="Anchor on the market band."),
        ev(T0 + 205.2, "nudge_gate", turn="r7", speaker="remote", candidates=["n001", "n002"], keys=["n001"], reason="keys",
           pending=False),
        ev(T0 + 206.4, "nudge_judge", turn="r7", call="k0001", candidates=["n001", "n002"], result="fired", pick="n001",
           quote="salary range", age_s=1.1, stop="end_turn", raw='NUDGE: n001 | "salary range" | them',
           window="remote: What salary range are you thinking?"),
        ev(T0 + 206.4, "nudge_fire", id="n001", turn="r7", call="k0001", speaker="remote", quote="salary range",
           title="Salary anchor"),
        ev(T0 + 207.0, "nudge_judge", turn="r7", call="k0002", candidates=["n002"], result="quote_not_in_window",
           pick="n002", quote="notice", raw='NUDGE: n002 | "notice" | them', window="remote: ..."),
        ev(T0 + 207.5, "nudge_judge", turn="r7", call="k0003", candidates=["n002"], result="error:overloaded"),
        ev(T0 + 208.0, "nudge_retire", id="n003", turn="r7", why="number", cleared=False),
        ev(T0 + 209.0, "mystery_event", a=1),
        ev(T0 + 209.1, "mystery_event", a=2),
        "{not json",
        "[1, 2]",
        {"t": "later", "ev": "card", "turn": 5, "tier": None},
    ]
    write_jsonl(s / "events.jsonl", events)
    write_jsonl(s / "bank.jsonl", [{"id": "b001", "opener": "I wanted a bigger scope.", "points": []}])
    write_jsonl(s / "nudges.jsonl", [
        {"id": "n001", "title": "Salary anchor", "when": "pay comes up", "keys": ["salary"], "say": ["Anchor high"]},
        {"id": "n002", "title": "Notice period", "when": "start date", "keys": ["notice"], "say": ["One month"]},
        {"id": "n003", "title": "Ask the band", "when": "pay", "keys": ["pay"], "say": ["Ask first"], "until": "number"},
        {"id": "n004", "title": "Team size", "when": "team", "keys": ["team"], "say": ["Ask size"]},
    ])
    (s / "meta.json").write_text(json.dumps({"budget_usd": 1.0}), encoding="utf-8")
    (s / "spend.json").write_text(json.dumps({"runs": [{"cost_usd": 0.85, "started_at": iso(T0)[:19] + "Z"}]}),
                                  encoding="utf-8")
    log = tmp / "verse.log"
    log.write_text("\n".join([
        f"{iso(T0 - 900)} start session=other-call lang=en mode=prepared route=meeting",
        f"{iso(T0 - 800)} run ended code=0",
        f"{iso(T0 - 0.5)} start session={NAME} lang=en mode=prepared route=meeting me=true fake=false",
        f"{iso(T0 + 0.8)} brain status warming pre-warming",
        f"{iso(T0 + 1.5)} brain status ready warm; spend so far $0.04",
        "garbage line without a timestamp",
        f"{iso(T0 + 31.0)} [brain] 2023-11-14 10:00:00,000 verse.runtime WARNING call f0003 (F) failed: 529 overloaded_error",
        f"{iso(T0 + 31.5)} brain status offline no connection (network error)",
        f"{iso(T0 + 100.0)} the brain process ended unexpectedly; restart 1 of 2 in 1 s",
        f"{iso(T0 + 300.0)} run ended code=0",
        f"{iso(T0 + 400.0)} brain status error should not be in the window",
    ]) + "\n", encoding="utf-8")
    return s, log


def by_kind(rep: dict) -> dict[str, list[dict]]:
    out: dict[str, list[dict]] = {}
    for p in rep["problems"] + rep["notes"]:
        out.setdefault(p["kind"], []).append(p)
    return out


def test_full_session_findings(tmp_path):
    s, log = full_session(tmp_path)
    rep = report.analyze(s, log_path=log)
    k = by_kind(rep)
    assert rep["internal_errors"] == []
    assert rep["verdict"]["ok"] is False
    assert rep["verdict"]["line"].startswith("PROBLEMS FOUND:")
    q = k["question_no_card"]
    assert [p["turn"] for p in q] == ["r3"] and q[0]["severity"] == "high" and q[0]["time"] == "00:30"
    assert q[0]["details"]["causes"]                       # the log's call failure / offline status near the turn
    assert [p["turn"] for p in k["card_late"]] == ["r2"]
    assert k["card_late"][0]["details"]["s_to_card"] == 4.5
    assert [p["turn"] for p in k["card_for_other"]] == ["r4"]
    assert [p["turn"] for p in k["probe_failed"]] == ["r5"]
    assert [p["turn"] for p in k["bank_contradicted"]] == ["r6"]
    assert k["transcript_gap"][0]["details"]["s"] == 140.0
    assert k["status_offline"][0]["severity"] == "high"
    assert "status_error" not in k                        # after `run ended`: outside the call window
    assert k["brain_restart"][0]["severity"] == "high"
    assert k["budget_near"][0]["details"]["spend_usd"] == 0.85
    assert k["nudge_rejected"][0]["details"]["reason"] == "quote_not_in_window"
    assert k["nudge_call_error"]
    assert sorted(p["details"]["nudge"] for p in k["nudge_never_fired"]) == ["n002", "n003", "n004"]
    assert "question_no_card" not in [p["kind"] for p in rep["problems"] if p["turn"] in ("r1", "r6", "r7")]


def test_timeline_totals_nudges_and_gaps_in_tool(tmp_path):
    s, log = full_session(tmp_path)
    rep = report.analyze(s, log_path=log)
    run = rep["runs"][0]
    tl = {x["turn"]: x for x in run["timeline"]}
    assert tl["r1"]["tier"] == "F" and tl["r1"]["s_to_card"] == 1.2 and tl["r1"]["card"].startswith("One month")
    assert tl["r6"]["tier"] == "P" and tl["r6"]["bank"] == "b001" and tl["r6"]["bank_contradicted"] is True
    assert tl["r6"]["card"] == "I wanted a bigger scope."
    assert tl["r7"]["nudge"] == "n001"
    assert tl["r3"]["card"] is None
    tot = rep["totals"]
    assert tot["turns_by_speaker"] == {"me": 2, "remote": 7}
    assert tot["questions_to_owner"] == 5 and tot["questions_with_card"] == 4
    assert tot["cards_by_tier"] == {"D": 1, "F": 2, "P": 1, "S": 1}
    assert tot["time_to_card_s"]["n"] == 4
    nd = run["nudges"]
    assert nd["k_calls"] == 3 and nd["k_peak_per_min"] == 3
    assert [j["result"] for j in nd["judges"]] == ["fired", "quote_not_in_window", "error:overloaded"]
    assert nd["fires"][0]["id"] == "n001" and nd["retires"][0]["id"] == "n003"
    assert rep["not_understood"]["event_types"] == {"mystery_event": 2}
    assert rep["not_understood"]["malformed_lines"]["events.jsonl"] == 2
    assert rep["not_understood"]["malformed_lines"]["transcript.jsonl"] == 1
    assert rep["blind_spots"]
    cmds = [c for r in rep["reproduce"] for c in r["commands"]]
    assert 'app/scripts/rehearse.sh them "Can you walk me through the budget?" "demo-call"' in cmds
    assert any("run_nudges.py --arm B --session" in c and "--trace" in c for c in cmds)


def test_markdown_sections(tmp_path):
    s, log = full_session(tmp_path)
    md = report.render_markdown(report.analyze(s, log_path=log))
    assert md.splitlines()[2].startswith("**PROBLEMS FOUND")
    for h in ("## Problems", "## Questions from the other side", "## Nudges", "## Totals", "## How to reproduce",
              "## What this report cannot see", "## Not understood"):
        assert h in md
    assert md.index("[high]") < md.index("[medium]")
    assert "not understood: 2 events of type mystery_event" in md


def test_thresholds_are_flags(tmp_path):
    s, log = full_session(tmp_path)
    rep = report.analyze(s, log_path=log, late_s=5.0, gap_s=200.0)
    kinds = {p["kind"] for p in rep["problems"]}
    assert "card_late" not in kinds and "transcript_gap" not in kinds


def test_log_missing_or_unused(tmp_path):
    s, _ = full_session(tmp_path)
    rep = report.analyze(s, log_path=tmp_path / "nope.log")
    assert rep["log"]["status"] == "missing"
    assert "**missing**" in report.render_markdown(rep)
    assert not any(p["kind"].startswith("status_") or p["kind"] == "brain_restart" for p in rep["problems"])
    rep = report.analyze(s, log_path=None)
    assert rep["log"]["status"] == "not used"
    # without the log the probe failure still comes from events.jsonl
    assert any(p["kind"] == "probe_failed" for p in rep["problems"])


def test_empty_folder_does_not_crash(tmp_path):
    s = tmp_path / "empty"
    s.mkdir()
    rep = report.analyze(s, log_path=None)
    assert rep["verdict"]["ok"] is True and rep["verdict"]["line"].startswith("OK")
    assert rep["totals"]["runs"] == 1
    assert "No questions" in report.render_markdown(rep)


def test_old_format_and_repeated_turn_ids_across_runs(tmp_path):
    """No t_wall / run_start (older transcripts), two runs reusing r1: rows follow their `turn` events."""
    s = tmp_path / "old"
    s.mkdir()
    a, b = T0, T0 + 3600
    rows = [{"turn_id": "r1", "speaker": "remote", "text": "First run question?", "kind": "question", "addressee": "me",
             "t_audio_end": 12.0},
            {"turn_id": "r1", "speaker": "remote", "text": "Second run question?", "kind": "question", "addressee": "me",
             "t_audio_end": 8.0}]
    write_jsonl(s / "transcript.jsonl", rows)
    write_jsonl(s / "events.jsonl", [
        ev(a, "start"), ev(a + 12.5, "turn", turn="r1", speaker="remote", kind="question", text="First run question?"),
        ev(a + 13.5, "card", turn="r1", tier="F", id="f0001", kind="say", text="Answer one."),
        ev(b, "start"), ev(b + 8.4, "turn", turn="r1", speaker="remote", kind="question", text="Second run question?"),
    ])
    rep = report.analyze(s, log_path=None)
    assert rep["totals"]["runs"] == 2
    r1, r2 = rep["runs"]
    assert r1["timeline"][0]["text"] == "First run question?" and r1["timeline"][0]["latency_basis"] == "turn_received"
    assert r1["timeline"][0]["s_to_card"] == 1.0
    assert r2["timeline"][0]["text"] == "Second run question?" and r2["timeline"][0]["card"] is None
    miss = [p for p in rep["problems"] if p["kind"] == "question_no_card"]
    assert [(p["run"], p["turn"]) for p in miss] == [(2, "r1")]
    assert rep["nudges"]["defined"] == [] and "No nudges" in report.render_markdown(rep)


def test_restart_from_history_replay_is_one_run(tmp_path):
    s = tmp_path / "restart"
    s.mkdir()
    write_jsonl(s / "transcript.jsonl", [row("r1", "remote", "Question one?", 10.0), row("r2", "remote", "Question two?", 90.0)])
    write_jsonl(s / "events.jsonl", [
        ev(T0 + 1, "start"), ev(T0 + 10.1, "turn", turn="r1", speaker="remote", kind="question"),
        ev(T0 + 11, "card", turn="r1", tier="F", id="f0001", text="A."),
        ev(T0 + 50, "start"), ev(T0 + 52, "history", turns=3, skipped=0, trimmed=0),
        ev(T0 + 90.1, "turn", turn="r2", speaker="remote", kind="question"),
        ev(T0 + 91, "card", turn="r2", tier="F", id="f0002", text="B."),
    ])
    rep = report.analyze(s, log_path=None)
    assert rep["totals"]["runs"] == 1
    restarts = [p for p in rep["problems"] if p["kind"] == "brain_restart"]
    assert len(restarts) == 1 and restarts[0]["turn"] == "r1"


def test_garbage_fields_never_crash(tmp_path):
    s = tmp_path / "garbage"
    s.mkdir()
    write_jsonl(s / "transcript.jsonl", [
        {"turn_id": 7, "speaker": ["x"], "text": 3, "t_audio_end": "soon"},
        {"turn_id": "r1", "speaker": "remote", "text": None, "t_audio_end": float("nan") if False else None, "kind": 5},
        {"turn_id": "r2", "speaker": "remote", "text": "ok?", "kind": "question", "t_audio_end": 4.0, "t_wall": "x"},
    ])
    write_jsonl(s / "events.jsonl", [
        {"ev": None}, {"t": None, "ev": "turn"}, {"t": T0, "ev": "nudge_judge", "candidates": "x", "turn": ["r1"]},
        {"t": T0, "ev": "nudge_gate", "candidates": None, "skipped": 3}, {"t": T0, "ev": "card", "turn": "r2", "id": 9},
        {"t": T0, "ev": "bank_verdict", "turn": "r2", "agree": "no"}, {"t": True, "ev": "probe", "turn": "r2", "verdict": []},
    ])
    (s / "meta.json").write_text("[1, 2]", encoding="utf-8")
    (s / "spend.json").write_text('{"runs": [1, {"cost_usd": "a"}, {"cost_usd": 0.1, "started_at": 5}]}', encoding="utf-8")
    (s / "nudges.jsonl").write_text("not json\n", encoding="utf-8")
    log = tmp_path / "bad.log"
    log.write_bytes(b"\xff\xfe garbage\n2023-13-45T99:99:99.000Z start session=garbage\n")
    rep = report.analyze(s, log_path=log)
    assert rep["internal_errors"] == []
    assert rep["not_understood"]["event_types"].get("<NoneType>") == 1
    report.render_markdown(rep)
    json.dumps(rep)


def test_cli_writes_both_files_and_refuses_session_folder(tmp_path, capsys):
    s, log = full_session(tmp_path)
    out = tmp_path / "out"
    assert report.main([str(s), "--log", str(log), "--out", str(out)]) == 0
    assert (out / "report.md").read_text(encoding="utf-8").startswith("# Verse call report: demo-call")
    data = json.loads((out / "report.json").read_text(encoding="utf-8"))
    assert data["schema"] == report.SCHEMA and data["session"] == NAME
    assert "# Verse call report" in capsys.readouterr().out
    assert report.main([str(s), "--no-log", "--out", str(out), "--json", "--late", "10"]) == 0
    printed = json.loads(capsys.readouterr().out)
    assert printed["thresholds"]["card_late_s"] == 10.0 and printed["log"]["status"] == "not used"
    assert report.main([str(s), "--no-log", "--out", str(s / "rep")]) == 2
    assert not (s / "rep").exists()


# ------------------------------------------------------------------------------------------------ audio route checks
def route_session(tmp: Path, *, mode="prepared", route="room", nudges=True, log_line=False,
                  route_change: str | None = None) -> tuple[Path, Path]:
    s = tmp / NAME
    s.mkdir()
    write_jsonl(s / "transcript.jsonl", [row("r1", route if route == "room" else "remote", "What is your notice period?", 10.0),
                                         row("r2", route if route == "room" else "remote", "How would you scale it?", 20.0)])
    events = [ev(T0 + 1, "start", mode=mode, route=route, lang="en"),
              ev(T0 + 10.1, "turn", turn="r1", speaker=route if route == "room" else "remote", kind="question", cue=True),
              ev(T0 + 11.0, "card", turn="r1", tier="F", id="f0001", text="One month."),
              ev(T0 + 20.1, "turn", turn="r2", speaker=route if route == "room" else "remote", kind="question", cue=True),
              ev(T0 + 21.0, "card", turn="r2", tier="F", id="f0002", text="Shard first.")]
    if route_change:
        events.insert(1, ev(T0 + 5, "route", route=route_change))
    write_jsonl(s / "events.jsonl", events)
    if nudges:
        write_jsonl(s / "nudges.jsonl", [
            {"id": f"n00{i}", "title": f"Nudge {i}", "when": "w", "keys": ["k"], "say": ["x"]} for i in range(1, 6)])
    lines = [f"{iso(T0 - 0.5)} start session={NAME} lang=en mode={mode} route={route}"]
    if log_line:
        lines.append(f"{iso(T0 + 4.0)} meeting detected in SomeCallApp while a session runs: no prompt")
    lines.append(f"{iso(T0 + 60.0)} run ended code=0")
    log = tmp / "verse.log"
    log.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return s, log


def test_room_route_with_nudges_is_a_problem(tmp_path):
    s, log = route_session(tmp_path)
    rep = report.analyze(s, log_path=log)
    k = by_kind(rep)
    assert rep["internal_errors"] == []
    assert rep["verdict"]["ok"] is False
    assert [p["what"] for p in k["room_route_nudges"]] == [report.ROOM_NUDGES_WHAT]
    assert k["room_route_nudges"][0]["severity"] == "high" and k["room_route_nudges"][0] in rep["problems"]
    assert "meeting_took_microphone" not in k            # the log has no such line
    # the five per-nudge "never fired" notes collapse into one line
    assert "nudge_never_fired" not in k
    assert len(k["nudges_not_run"]) == 1 and "could not run" in k["nudges_not_run"][0]["what"]
    assert rep["nudges"]["never_fired"] and len(rep["nudges"]["never_fired"]) == 5     # the JSON list is unchanged
    md = report.render_markdown(rep)
    assert report.ROOM_ANSWERS_NOTE in md


def test_meeting_app_took_microphone_after_start(tmp_path):
    s, log = route_session(tmp_path, log_line=True)
    rep = report.analyze(s, log_path=log)
    k = by_kind(rep)
    assert [p["what"] for p in k["meeting_took_microphone"]] == [report.ROOM_MEETING_WHAT]
    assert k["meeting_took_microphone"][0] in rep["problems"] and rep["verdict"]["ok"] is False
    assert k["meeting_took_microphone"][0]["time"] == "00:04"
    # without a log the check is skipped silently and the report says it could not look
    rep = report.analyze(s, log_path=None)
    assert "meeting_took_microphone" not in by_kind(rep)
    assert "a meeting app taking the microphone" in report.render_markdown(rep)
    rep = report.analyze(s, log_path=tmp_path / "nope.log")
    assert "meeting_took_microphone" not in by_kind(rep)
    assert "a meeting app taking the microphone" in report.render_markdown(rep)


def test_meeting_route_with_nudges_has_neither_finding(tmp_path):
    s, log = route_session(tmp_path, route="meeting", log_line=True)
    rep = report.analyze(s, log_path=log)
    k = by_kind(rep)
    assert "room_route_nudges" not in k and "meeting_took_microphone" not in k and "nudges_not_run" not in k
    assert len(k["nudge_never_fired"]) == 5               # unchanged behaviour on the meeting route
    assert report.ROOM_ANSWERS_NOTE not in report.render_markdown(rep)


def test_room_route_without_nudges_or_unprepared_has_no_nudge_finding(tmp_path):
    s, log = route_session(tmp_path, nudges=False)
    k = by_kind(report.analyze(s, log_path=log))
    assert "room_route_nudges" not in k and "nudges_not_run" not in k
    other = tmp_path / "other"
    other.mkdir()
    s2, log2 = route_session(other, mode="unprepared")
    rep = report.analyze(s2, log_path=log2)
    k = by_kind(rep)
    assert "room_route_nudges" not in k and "nudges_not_run" not in k
    assert len(k["nudge_never_fired"]) == 5
    assert report.ROOM_ANSWERS_NOTE in report.render_markdown(rep)    # still the room route


def test_room_run_that_moved_to_the_meeting_route_is_not_flagged(tmp_path):
    s, log = route_session(tmp_path, route_change="meeting", log_line=True)
    k = by_kind(report.analyze(s, log_path=log))
    assert "room_route_nudges" not in k and "meeting_took_microphone" not in k
