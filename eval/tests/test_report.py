"""report.py pieces on small synthetic score fixtures: criterion 2 gate, audio-watch rows, retry metas, grounding row."""

import json

import checks
import report


def bank(hits=21, wrong=1, ex=(21, 21), para=(0, 24), probed=93):
    return {"hits": hits, "wrong_hits": wrong, "utterances_probed": probed, "banked_questions": ex[1] + para[1],
            "hit_rate": hits / (ex[1] + para[1]), "wrong_hit_rate": wrong / probed, "wrong_hits_transient": wrong,
            "wrong_hit_rate_transient": wrong / probed, "wrong_after_haiku": 0, "confirmed_by_haiku": 0,
            "by_category": {"exact": {"n": ex[1], "hit": ex[0]}, "paraphrase": {"n": para[1], "hit": para[0]}}}


# ---- E4: criterion 2 is a pair

def test_a_matcher_that_never_fires_on_paraphrases_is_missed_even_with_few_wrong_hits():
    g = report.bank_gate(bank(21, 1, para=(0, 24)))
    assert g["wrong_rate_shown"] == 1 / 22 and g["paraphrase_rate"] == 0.0
    assert g["status"] == "missed" and "paraphrase" in g["reason"]


def test_a_matcher_that_never_fires_at_all_is_missed():
    g = report.bank_gate(bank(0, 0, ex=(0, 21), para=(0, 24)))
    assert g["wrong_rate_shown"] is None and g["status"] == "missed"


def test_both_halves_must_hold():
    assert report.bank_gate(bank(40, 1, ex=(21, 21), para=(19, 24)))["status"] == "met"
    assert report.bank_gate(bank(40, 6, ex=(21, 21), para=(19, 24)))["status"] == "missed"          # 6/46 wrong among shown
    just = round(report.PARAPHRASE_HIT_FLOOR * 24)
    assert report.bank_gate(bank(40, 0, para=(just, 24)))["status"] == "met"                         # exactly at the floor passes
    assert report.bank_gate(bank(40, 0, para=(just - 1, 24)))["status"] == "missed"


def test_no_paraphrase_probes_means_not_measured_and_the_floor_is_a_named_constant():
    assert report.bank_gate(bank(21, 0, para=(0, 0)))["status"] == "not measured"
    assert report.PARAPHRASE_HIT_FLOOR == 0.5


def test_criterion_2_row_states_the_pair_and_the_status():
    row = report.criterion2_row(bank(21, 1, para=(0, 24)))
    assert row.startswith("| 2 |") and "paraphrase hit rate" in row and "1/22" in row and row.rstrip().endswith("| missed |")


# ---- E8: retry attempts do not overwrite the scored run

def meta(i, polls):
    return {"id": i, "audio_watch": {"pass": True, "polls": polls, "audio_files_found": []}, "session_files_added": []}


def test_try_metas_are_skipped(tmp_path):
    (tmp_path / "d04.meta.json").write_text(json.dumps(meta("d04", 464)))
    (tmp_path / "d04.try1.meta.json").write_text(json.dumps(meta("d04", 325)))
    (tmp_path / "d05.meta.json").write_text(json.dumps(meta("d05", 436)))
    fs = report.audio_watch_by_dialogue(tmp_path)
    assert sorted(fs) == ["d04", "d05"] and fs["d04"]["audio_watch"]["polls"] == 464


# ---- E3: the audio criterion names what was watched

def test_audio_row_covers_the_watched_locations_not_anywhere():
    fs = {"d01": {"audio_watch": {"pass": True, "polls": 400}, "session_audio_added": []}}
    row = report.audio_row(fs)
    assert "anywhere" not in row.lower() and "watched locations" in row
    for loc in report.WATCHED_LOCATIONS:
        assert loc in row
    assert "$TMPDIR" in row and "not watched" in row and row.rstrip().endswith("| met |")
    fs["d01"]["audio_watch"]["pass"] = False
    assert report.audio_row(fs).rstrip().endswith("| missed |")


# ---- E1/E5 in the report: either-judge rule, old scores.json still reads

def test_grounding_row_new_shape_shows_either_judge_agreement_and_range():
    gr = {"lines_checked": 100, "auto_supported": 95, "unresolved_by_string_check": 5, "judged": 100, "judge_passes": 2, "haiku_flagged": 9,
          "violation_rule": "either judge", "violations": [{}] * 9, "unjudged": [], "cleared_by_second_opinion": 4,
          "judge_agreement": {"read_by_both": 9, "both_flagged": 5, "first_only": 4, "second_only": 0, "both_clear": 0},
          "pass_summary": {"per_pass_flagged": [6, 8], "violations_range": [6, 8], "violations_union": 9, "flag_frequency": []}}
    row = report.grounding_row(gr)
    assert "either judge" in row and "9 unsupported" in row and "6-8" in row and "union 9" in row and "5 of 9" in row
    assert row.rstrip().endswith("| missed |")


def test_grounding_row_old_shape_is_labelled_and_counts_the_cleared_lines_too():
    gr = {"lines_checked": 363, "auto_supported": 357, "unresolved_by_string_check": 6, "judged": 363, "judge_passes": 2, "haiku_flagged": 15,
          "violations": [{}] * 7, "cleared_lines": [{}] * 8, "cleared_by_second_opinion": 8, "unjudged": [], "evidence_not_in_pack": 162}
    row = report.grounding_row(gr)
    assert "old rule" in row and "7 confirmed by Sonnet" in row and "15 flagged by either" in row and row.rstrip().endswith("| missed |")


# ---- E10: hand-written notes are checked against the regenerated tables

NOTES = "<!-- notes-for-run: live1 -->\n## What this means\n\n- Opener 0.67 s p50; 7 of 363 lines; $0.43 per 30 min; paraphrases 0/24."


def test_notes_written_for_another_run_are_left_out():
    out = report.notes_section(NOTES, "f3-embed", "| bank | 0/24 |")
    assert "0.67" not in out and "describe run `live1`, not `f3-embed`" in out


def test_numbers_missing_from_the_tables_are_listed():
    body = "| Bank hit | 0.67 / 1.22 s |\n| grounding | 7/363 |\n| bank | 13/24 |"
    out = report.notes_section(NOTES, "live1", body)
    assert out.startswith("## What this means")
    warn = out.split("\n")[-1]
    assert "$0.43" in warn and "0/24" in warn            # not in the tables: stale
    assert "0.67 s" not in warn and "7 of 363" not in warn   # found (as 0.67 and 7/363)


def test_untagged_notes_carry_a_warning_and_empty_notes_add_nothing():
    assert "no `notes-for-run` tag" in report.notes_section("- 1/2 done", "x", "1/2")
    assert report.notes_section("  \n", "x", "") == ""
