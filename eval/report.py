#!/usr/bin/env python3
"""Writes docs/eval-report-v1.md from eval/out/<run>/scores.json (+ eval/report_notes.md, written by hand).

    python report.py --run live1

The secret scan runs over the run folder and the finished report: it compares against the Keychain value in-process
and prints only pass or fail.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import checks  # noqa: E402

REPO = HERE.parent
REPORT = REPO / "docs" / "eval-report-v1.md"


def f(x, nd=2, unit=""):
    return "n/a" if x is None else f"{x:.{nd}f}{unit}"


def pc(x):
    return "n/a" if x is None else f"{100 * x:.0f} %"


def lat_cell(s):
    return f"{f(s['p50'])} / {f(s['p90'])} s (n={s['n']})" if s["n"] else "no samples"


def lat_status(s, p50_max, p90_max):
    if not s["n"]:
        return "not measured"
    return "met" if s["p50"] <= p50_max and s["p90"] <= p90_max else "missed"


def build(run: str, scores: dict, scan: dict, fs: dict, notes: str, git: str) -> str:
    ag = scores["aggregate"]
    short = scores.get("aggregate_short")
    lat, det, adr, bank, cost, oth = ag["latency"], ag["detection"], ag["addressee"], ag["bank"], ag["cost"], ag["other"]
    gr = scores.get("grounding", {})
    metas = scores["metas"]
    main_ids = [d["id"] for d in scores["dialogues"] if d.get("suite", "main") == "main"]
    loads = [m["loadavg_before"][0] for m in metas.values() if m.get("loadavg_before")]
    loads_after = [m["loadavg_after"][0] for m in metas.values() if m.get("loadavg_after")]
    lines: list[str] = []
    w = lines.append
    w("# Verse v1: replay evaluation (P1-6)")
    w("")
    w(f"Generated {time.strftime('%Y-%m-%d %H:%M')} from run `{run}` ({git}). English only; Italian and Turkish are listed as not measured.")
    w("")
    w("## Setup")
    w("")
    n_d = len(metas)
    w(f"- {len(main_ids)} synthetic dialogues made with macOS `say` (6 with two speakers, 6 with three), {ag['questions_to_user']} questions to the user, "
      f"{adr['questions_to_other']} questions to the other interviewer, plus statements, fragments and short replies; exact bank questions, blind paraphrases "
      "(`bench/embed/blind_set.json`) and off-bank questions. One more dialogue (d13) has six 2-3 word questions, scored apart, to exercise the "
      "fresh-Haiku path (speculation cannot fire on fewer than four words). Labels: `eval/dialogues/*.json`. "
      "Audio is generated at run time in a temp folder and deleted after each dialogue; each dialogue starts with silence while the English engine loads.")
    w("- Remote channel only: `verse-run --file` plays the mix of interviewers; the user's answers are silence. Speech recognition: the app's English "
      "engine (Nemotron 0.6B, 560 ms chunks) after a lead-in long enough for it to load.")
    w("- Brain: the live runtime (Haiku 5.5 for S/F, Sonnet 5.5 for D) against the P1-1 sample session (`sample-interview`, 22 bank entries).")
    w(f"- All times are measured from the true acoustic end of each question (known exactly from the generated audio). "
      f"Machine load average at the start of each dialogue: min {f(min(loads) if loads else None, 1)}, max {f(max(loads) if loads else None, 1)} "
      f"(end of dialogue: max {f(max(loads_after) if loads_after else None, 1)}). The Mac was shared with other sessions, so latencies are pessimistic and noisy.")
    w("- Time zero: the generated audio is played at real-time pace, so the wall-clock time of every utterance's acoustic end is known to within about "
      "50 ms (the file starts within tens of milliseconds of the session clock; `session_t0` reports the origin as 0).")
    if ag["excluded_warmup_utterances"]:
        w(f"- {ag['excluded_warmup_utterances']} utterances were excluded because they started before the English engine had taken over from the fallback engine.")
    w("")
    w("## Spec section 9: done means")
    w("")
    w("| # | Criterion | Target | Measured | Status |")
    w("|---|---|---|---|---|")
    fresh = lat["fresh_haiku_first_word"]
    fresh_name = "No hit, fresh Haiku, first word"
    if not fresh["n"] and short:
        fresh = short["latency"]["fresh_haiku_first_word"]
        fresh_name += " (d13 only)"
    lat_rows = [
        ("Bank hit visible", lat["bank_hit_visible"], 0.3, 0.4),
        ("Fact chip visible", lat["fact_chip_visible"], 0.3, 0.4),
        ("Correct speculation, opener visible", lat["speculation_hit_opener_visible"], 0.3, 0.5),
        (fresh_name, fresh, 2.0, 2.8),
        ("Sonnet deep points, first words", lat["sonnet_deep_first_words"], 2.0, 3.0),
    ]
    statuses = [lat_status(s, a, b) for _, s, a, b in lat_rows]
    overall = "met" if all(s == "met" for s in statuses) else ("missed" if "missed" in statuses else "not measured")
    w(f"| 1 | Section 6 latency targets in replay (en) | all five paths within target | see the latency table: {'; '.join(f'{n.split(',')[0].lower()} {st}' for (n, *_), st in zip(lat_rows, statuses))} | {overall} |")
    w("| 1b | ... in one live Meet call per language | all paths | no live call run | not measured |")
    wr = bank["wrong_hit_rate"]
    w(f"| 2 | Blind paraphrase bank hit rate, English | wrong-hit rate <= 5 % | hit rate on the right entry {pc(bank['hit_rate'])} "
      f"({bank['hits']}/{bank['banked_questions']}; exact {bank['by_category']['exact']['hit']}/{bank['by_category']['exact']['n']}, "
      f"paraphrase {bank['by_category']['paraphrase']['hit']}/{bank['by_category']['paraphrase']['n']}); wrong hit left on screen {bank['wrong_hits']}/{bank['utterances_probed']} "
      f"= {pc(wr)} (wrong at any moment: {bank['wrong_hits_transient']}/{bank['utterances_probed']} = {pc(bank['wrong_hit_rate_transient'])}); "
      f"wrong and confirmed by Haiku {bank['wrong_after_haiku']}/{bank['utterances_probed']} | "
      f"{'met on the wrong-hit rate; paraphrase hit rate ' + pc(bank['by_category']['paraphrase']['hit'] / bank['by_category']['paraphrase']['n'] if bank['by_category']['paraphrase']['n'] else None) if wr is not None and wr <= 0.05 else 'missed'} |")
    w("| 2b | ... Italian, Turkish (Turkish separately) | wrong-hit rate <= 5 % | English only in this package | not measured |")
    r3 = adr["three_speaker_no_say"] / adr["three_speaker_n"] if adr["three_speaker_n"] else None
    w(f"| 3 | Questions to others get no SAY line (3-speaker replays) | >= 90 % | {adr['three_speaker_no_say']}/{adr['three_speaker_n']} = {pc(r3)} "
      f"(all dialogues: {adr['no_say']}/{adr['questions_to_other']}) | {'met' if r3 is not None and r3 >= 0.9 else ('missed' if r3 is not None else 'not measured')} |")
    w("| 4 | Replay through the MacBook speakers produces no false \"me\" turns | zero | the me channel and the speaker-bleed test need P1-5 (follow-up) | not measured |")
    ok_d = det["precision"] is not None and det["recall"] is not None and det["precision"] >= 0.8 and det["recall"] >= 0.8
    w(f"| 5 | Question detection, questions to the user | precision and recall >= 80 % | precision {pc(det['precision'])} "
      f"({det['true_positive_turns']}/{det['predicted_turns']}), recall {pc(det['recall'])} ({det['covered']}/{det['positives']}) | {'met' if ok_d else 'missed'} |")
    if gr.get("lines_checked"):
        vio = len(gr.get("violations", []))
        unj = len(gr.get("unjudged", []))
        gstat = "met" if vio == 0 and unj == 0 else ("missed" if vio else "not fully measured")
        w(f"| 6 | No suggestion states a number, date or fact absent from the pack | zero | {gr['lines_checked']} lines shown: {gr['auto_supported']} passed the string check "
          f"({gr['unresolved_by_string_check']} did not); Haiku read all {gr['judged']} in {gr.get('judge_passes', 1)} passes and flagged {gr.get('haiku_flagged', 0)}; "
          f"Sonnet cleared {gr.get('cleared_by_second_opinion', 0)}, so {vio} unsupported ({unj} not judged) | {gstat} |")
    else:
        w("| 6 | No suggestion states a number, date or fact absent from the pack | zero | no suggestion lines were produced | not measured |")
    wd = [m for m in fs.values()]
    audio_ok = all(x["audio_watch"]["pass"] and not x["session_audio_added"] for x in wd) if wd else False
    w(f"| 7 | No audio file written anywhere | none | filesystem watch (250 ms polls) over the session folder, the app's Verse folder and the brain's output folder during all {len(wd)} dialogues: "
      f"{'no audio file appeared' if audio_ok else 'AUDIO FILE FOUND, see below'}; temp audio removed after every dialogue | {'met' if audio_ok else 'missed'} |")
    w(f"| 8 | API key never in logs or files | none | {scan['files_scanned']} files scanned (everything under eval/out (every recorded stdout line, stderr log, metadata and score file, the spend ledger) and this report): exact Keychain key and key-shaped strings "
      f"{'not found' if scan['pass'] else 'FOUND'} | {'met' if scan['pass'] else 'missed'} |")
    w(f"| 9 | Cost per 30-minute meeting measured | measured | ${f(cost['usd_per_30_min'], 3)} per 30 min of replayed dialogue (${f(cost['total_usd'], 3)} over {f(cost['replay_minutes'], 1)} min, "
      "pre-warm and summaries included); shown in Settings: needs P1-5 | measured; Settings display not measured |")
    w("")
    if notes.strip():
        w(notes.strip())
        w("")
    w("## Section 6 latency, from the acoustic end of the question")
    w("")
    w("| Path | Target p50 / p90 | Measured p50 / p90 | Status |")
    w("|---|---|---|---|")
    for (name, s, a, b), st in zip(lat_rows, statuses):
        w(f"| {name} | {a:.1f} / {b:.1f} s | {lat_cell(s)} | {st} |")
    w("")
    w("Stage by stage (all questions to the user that the system answered):")
    w("")
    w("| Stage | p50 / p90 |")
    w("|---|---|")
    w(f"| acoustic end to `turn` sent (recognizer lag + endpoint wait) | {lat_cell(lat['acoustic_end_to_turn_sent'])} |")
    w(f"| acoustic end to first visible S/F text | {lat_cell(lat['first_visible_text_any_SF'])} |")
    w(f"| S/F text came from a speculative call / from the fresh F call | {lat['n_speculation_path']} / {lat['n_fresh_path']} questions |")
    w(f"| questions with no S/F text at all | {lat['questions_with_no_sf_text']} |")
    w(f"| questions with D text | {lat['questions_with_d_text']} |")
    w("")
    w("Negative numbers mean the item was visible before the question had ended. Fact chips and bank hits are shown while the question is still being spoken, "
      "so they are measured against the end of the whole question, as the spec states.")
    w("")
    w("## Question detection and addressing")
    w("")
    w(f"- Questions to the user missed: {len(det['missed'])} of {det['positives']}.")
    for m in det["missed"][:12]:
        w(f"  - \"{m['text']}\" -> heard \"{m['heard']}\" kinds {m['kinds']} addressee {m['addressee']}")
    w(f"- Statements, replies, fragments or other-addressed questions that were sent on as questions for the user: {len(det['false_positives'])}.")
    for m in det["false_positives"][:12]:
        w(f"  - ({m['category']}) \"{m['text']}\" -> heard \"{m['heard']}\"")
    w(f"- Questions to the other interviewer: {adr['classified_other']}/{adr['questions_to_other']} recognised as addressed to someone else; "
      f"{adr['not_detected_at_all']} not detected as a turn at all; {len(adr['failures'])} produced a SAY line.")
    for m in adr["failures"][:12]:
        w(f"  - \"{m['text']}\" -> heard \"{m['heard']}\" addressee {m['addressee']}, {m['say_lines']} SAY line(s)")
    w(f"- Statements: {oth['statements']} ({oth['statements_with_say']} got a short acknowledgement, {oth['statements_called_question']} were called questions). "
      f"Fragments: {oth['fragments']} ({oth['fragments_with_output']} produced output).")
    w("")
    w("## Bank matching")
    w("")
    w(f"- Matcher's last hit is the right entry: {bank['hits']}/{bank['banked_questions']}; confirmed by Haiku's `BANK:` check: {bank['confirmed_by_haiku']}.")
    w(f"- Wrong hits: {bank['wrong_hits']} of {bank['utterances_probed']} spoken utterances ended on a wrong hit (including off-bank questions, statements and questions to the other interviewer); "
      f"{bank['wrong_hits_transient']} showed a wrong hit at some moment, even if corrected later.")
    for m in bank["wrong_detail"][:10]:
        w(f"  - ({m['category']}) \"{m['text']}\" -> {m['bank_ids']} (expected {m['expected']})")
    w("")
    if gr.get("violations") or gr.get("unjudged"):
        w("## Grounding findings")
        w("")
        for v in gr.get("violations", []):
            w(f"- {v['dialogue']} ({v['category']}): \"{v['line']}\" (string check: {v['unresolved']}; judge: {v.get('judge_claim')})")
        for v in gr.get("unjudged", [])[:10]:
            w(f"- not judged: {v['dialogue']}: \"{v['line']}\" ({v['unresolved']})")
        w("")
    bad = {k: v for k, v in fs.items() if not v["audio_watch"]["pass"] or v["session_audio_added"]}
    if bad:
        w("## Audio files found")
        w("")
        for k, v in bad.items():
            w(f"- {k}: {v['audio_watch']['audio_files_found']} {v['session_audio_added']}")
        w("")
    w("## Runs")
    w("")
    w("| Dialogue | Speakers | Audio length (with lead-in) | Lead-in | Speech engine | Exit | Cost | Load avg start / end |")
    w("|---|---|---|---|---|---|---|---|")
    spk = {d["id"]: d.get("speakers") for d in scores["dialogues"]}
    eng = {d["id"]: d.get("engine", "") for d in scores["dialogues"]}
    for did, m in sorted(metas.items()):
        w(f"| {did} | {spk.get(did)} | {m['duration_s']:.0f} s | {m['lead_in_s']:.0f} s | {eng.get(did, '')} | {m['exit_code']} | ${m['cost_usd']:.4f} | {m['loadavg_before'][0]} / {m['loadavg_after'][0]} |")
    w("")
    w("## Not run in this package")
    w("")
    w("- Italian and Turkish dialogues (English first, as decided).")
    w("- The me channel and the speaker-bleed test (replay through the speakers into the microphone): needs the P1-5 overlay app merged.")
    w("- A live Google Meet call per language.")
    w("- Cost shown in Settings (P1-5).")
    w("")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    a = ap.parse_args()
    from paths import OUT
    run_dir = OUT / a.run
    scores = json.loads((run_dir / "scores.json").read_text())
    fs = {}
    for mf in sorted(run_dir.glob("*.meta.json")):
        m = json.loads(mf.read_text())
        fs[m["id"]] = {"audio_watch": m["audio_watch"], "session_audio_added": [p for p in m["session_files_added"] if p.lower().endswith(tuple(checks.AUDIO_EXT))]}
    notes_f = HERE / "report_notes.md"
    notes = notes_f.read_text() if notes_f.exists() else ""
    import subprocess
    git = subprocess.run(["git", "-C", str(REPO), "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip() or "no commit"
    key = checks.keychain_key()
    scan = checks.scan_for_secrets([OUT, REPORT] if REPORT.exists() else [OUT], key)
    text = build(a.run, scores, scan, fs, notes, f"worktree at {git}")
    REPORT.write_text(text, encoding="utf-8")
    scan2 = checks.scan_for_secrets([OUT, REPORT], key)    # now the report exists, so it is counted too
    text = build(a.run, scores, scan2, fs, notes, f"worktree at {git}")
    REPORT.write_text(text, encoding="utf-8")
    scan2 = checks.scan_for_secrets([OUT, REPORT], key)
    print(f"report written: {REPORT}; secret scan {'pass' if scan2['pass'] else 'FAIL'} ({scan2['files_scanned']} files)")
    return 0 if scan2["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
