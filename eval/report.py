#!/usr/bin/env python3
"""Writes docs/eval-report-v1.md from eval/out/<run>/scores.json (+ eval/report_notes.md, written by hand).

    python report.py --run live1

The secret scan runs over the run folder and the finished report: it compares against the Keychain value in-process
and prints only pass or fail.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import checks  # noqa: E402

REPO = HERE.parent
REPORT = REPO / "docs" / "eval-report-v1.md"


# Criterion 2 gates on a pair (eval review E4): wrong hits among the hits that were shown, AND a floor on the paraphrase hit rate. Without the
# floor a matcher that never fires scores 0 % wrong and passes. OWNER: set this floor. 0.5 is a placeholder default, not a decision.
PARAPHRASE_HIT_FLOOR = 0.5
WRONG_HIT_MAX = 0.05

# Folders the audio watch polls (run_replay.py, run_twotrack.py). The model folder is skipped inside the watch.
WATCHED_LOCATIONS = ("the per-dialogue session copy", "~/Library/Application Support/Verse/sessions", "brain/tests/out")
NOT_WATCHED = "$TMPDIR, ~/Library/Caches, the app's container and the model folder"


def f(x, nd=2, unit=""):
    return "n/a" if x is None else f"{x:.{nd}f}{unit}"


def pc(x):
    return "n/a" if x is None else f"{100 * x:.0f} %"


def pc1(x):
    return "n/a" if x is None else f"{100 * x:.1f} %"


def lat_cell(s):
    return f"{f(s['p50'])} / {f(s['p90'])} s (n={s['n']})" if s["n"] else "no samples"


def lat_status(s, p50_max, p90_max):
    if not s["n"]:
        return "not measured"
    return "met" if s["p50"] <= p50_max and s["p90"] <= p90_max else "missed"


def bank_gate(bank: dict) -> dict:
    """Criterion 2: wrong hits among shown hits (<= WRONG_HIT_MAX) and paraphrase hit rate (>= PARAPHRASE_HIT_FLOOR)."""
    shown = bank["hits"] + bank["wrong_hits"]               # right-entry hits plus hits left on a wrong entry or an off-bank utterance
    wrong_rate = bank["wrong_hits"] / shown if shown else None
    para = bank["by_category"]["paraphrase"]
    para_rate = para["hit"] / para["n"] if para["n"] else None
    reasons = []
    if wrong_rate is None:
        reasons.append("no hit was shown at all")
    elif wrong_rate > WRONG_HIT_MAX:
        reasons.append(f"wrong hits among shown hits {pc1(wrong_rate)} > {pc1(WRONG_HIT_MAX)}")
    if para_rate is not None and para_rate < PARAPHRASE_HIT_FLOOR:
        reasons.append(f"paraphrase hit rate {pc(para_rate)} < floor {pc(PARAPHRASE_HIT_FLOOR)}")
    if para_rate is None and not reasons:
        status = "not measured"
    else:
        status = "missed" if reasons else "met"
    return {"shown_hits": shown, "wrong_shown": bank["wrong_hits"], "wrong_rate_shown": wrong_rate, "paraphrase_rate": para_rate,
            "status": status, "reason": "; ".join(reasons)}


def criterion2_row(bank: dict) -> str:
    g = bank_gate(bank)
    cat = bank["by_category"]
    return (f"| 2 | Blind paraphrase bank hit rate, English | wrong hits among shown hits <= {pc(WRONG_HIT_MAX)} and paraphrase hit rate >= {pc(PARAPHRASE_HIT_FLOOR)} "
            f"(floor is a placeholder: the owner sets it) | wrong hits among shown hits {g['wrong_shown']}/{g['shown_hits']} = {pc1(g['wrong_rate_shown'])}; "
            f"paraphrase hit rate {pc(g['paraphrase_rate'])} ({cat['paraphrase']['hit']}/{cat['paraphrase']['n']}); hit rate on the right entry {pc(bank['hit_rate'])} "
            f"({bank['hits']}/{bank['banked_questions']}; exact {cat['exact']['hit']}/{cat['exact']['n']}); wrong hit left on screen {bank['wrong_hits']}/{bank['utterances_probed']} "
            f"utterances probed = {pc(bank['wrong_hit_rate'])} (wrong at any moment: {bank['wrong_hits_transient']}/{bank['utterances_probed']} = {pc(bank['wrong_hit_rate_transient'])}); "
            f"wrong and confirmed by Haiku {bank['wrong_after_haiku']}/{bank['utterances_probed']}"
            f"{'; ' + g['reason'] if g['reason'] else ''} | {g['status']} |")


def audio_row(fs: dict) -> str:
    wd = list(fs.values())
    ok = all(x["audio_watch"]["pass"] and not x["session_audio_added"] for x in wd) if wd else False
    return (f"| 7 | No audio file written in the watched locations | none in {', '.join(WATCHED_LOCATIONS)} | filesystem watch (250 ms polls) over those locations during all {len(wd)} dialogues: "
            f"{'no audio file appeared there' if ok else 'AUDIO FILE FOUND, see below'}; temp audio removed after every dialogue. A file created and deleted between two polls is missed, "
            f"and {NOT_WATCHED} are not watched, so this is not a claim about the whole machine | {'met' if ok else 'missed'} |")


def grounding_row(gr: dict) -> str:
    vio = len(gr.get("violations", []))
    unj = len(gr.get("unjudged", []))
    head = (f"| 6 | No suggestion states a number, date or fact absent from the pack | zero | {gr['lines_checked']} lines shown: {gr['auto_supported']} passed the string check "
            f"({gr['unresolved_by_string_check']} did not); Haiku read all {gr['judged']} in {gr.get('judge_passes', 1)} passes and flagged {gr.get('haiku_flagged', 0)}")
    if gr.get("violation_rule") == "either judge":
        ps, ag = gr["pass_summary"], gr["judge_agreement"]
        lo, hi = ps["violations_range"]
        mid = (f" (per pass {lo}-{hi}, union {ps['violations_union']}); Sonnet read {ag['read_by_both']} lines; a line is a violation when either judge flags it, "
               f"so {vio} unsupported ({unj} not judged); the judges agree on {ag['both_flagged']} of {ag['read_by_both']} flagged "
               f"(Haiku only {ag['first_only']}, Sonnet only {ag['second_only']})")
        if gr.get("evidence_not_in_pack"):
            mid += f"; {gr['evidence_not_in_pack']} 'supported' verdicts quoted evidence that is not in the pack and count as flagged"
        violations_total = vio
    else:     # scores.json written before the either-judge rule: Sonnet's veto removed lines, its verdicts on cleared lines are in cleared_lines
        either = vio + len(gr.get("cleared_lines", []))
        mid = (f"; Sonnet cleared {gr.get('cleared_by_second_opinion', 0)}, so {vio} confirmed by Sonnet ({unj} not judged) "
               f"(old rule, Sonnet could veto; {either} flagged by either judge under the current rule; the judges' quotes were not stored, so the "
               f"{gr.get('evidence_not_in_pack', 'n/a')} verdicts with quotes not found in the pack could not be re-examined)")
        violations_total = max(vio, either)
    gstat = "met" if violations_total == 0 and unj == 0 else ("missed" if violations_total else "not fully measured")
    return head + mid + f" | {gstat} |"


def audio_watch_by_dialogue(run_dir: Path) -> dict:
    """audio-watch result per dialogue from <id>.meta.json; retry attempts (<id>.try1.meta.json) are not the scored run and are skipped."""
    fs = {}
    for mf in sorted(run_dir.glob("*.meta.json")):
        if ".try" in mf.name:
            continue
        m = json.loads(mf.read_text())
        fs[m["id"]] = {"audio_watch": m["audio_watch"], "session_audio_added": [p for p in m["session_files_added"] if p.lower().endswith(tuple(checks.AUDIO_EXT))]}
    return fs


NOTES_PLACEHOLDER = "\x00NOTES\x00"
_NOTES_RUN = re.compile(r"<!--\s*notes-for-run:\s*(\S+)\s*-->")
# Measured-looking numbers in the hand-written notes: "$0.43", "0.67 s", "3 %", "21/24", "7 of 363".
_NOTE_NUMS = re.compile(r"\$\d+(?:\.\d+)?|\d+(?:\.\d+)?\s?(?:s|%)(?![\w])|\d+/\d+|\d+ of \d+")


def _bare(tok: str) -> list[str]:
    """The forms a note number can take in the generated tables."""
    t = tok.strip().lstrip("$")
    if " of " in t:
        a, b = t.split(" of ")
        return [f"{a}/{b}", t]
    if "/" in t:
        return [t]
    return [re.sub(r"\s?(?:s|%)$", "", t)]


def notes_section(notes: str, run: str, body: str) -> str:
    """The hand-written notes as they go into the report (review E10). Notes tagged for another run (`<!-- notes-for-run: X -->`)
    are left out with a visible line, so a regenerated report never carries prose about a different run. Untagged or matching
    notes go in, followed by a warning that lists every measured-looking number in them that the generated tables do not
    contain (those numbers were written by hand and may be stale)."""
    text = notes.strip()
    if not text:
        return ""
    m = _NOTES_RUN.search(text)
    if m and m.group(1) != run:
        return (f"> The hand-written notes (`eval/report_notes.md`) describe run `{m.group(1)}`, not `{run}`: left out of this report. "
                "Write notes for this run (tag them `<!-- notes-for-run: " + run + " -->`) to include them.")
    text = _NOTES_RUN.sub("", text).strip()
    stale = []
    for tok in _NOTE_NUMS.findall(text):
        if not any(re.search(r"(?<![\d.])" + re.escape(f) + r"(?![\d])", body) for f in _bare(tok)) and tok not in stale:
            stale.append(tok)
    if m is None:
        text = (f"> The hand-written notes below carry no `notes-for-run` tag: they may describe another run than `{run}`.\n\n" + text)
    if stale:
        text += ("\n\n> Numbers in these notes that do not appear in the generated tables of this report (written by hand; check "
                 f"them against run `{run}`): {', '.join(stale)}.")
    return text


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
    w(criterion2_row(bank))
    w("| 2b | ... Italian, Turkish (Turkish separately) | wrong-hit rate <= 5 % | English only in this package | not measured |")
    r3 = adr["three_speaker_no_say"] / adr["three_speaker_n"] if adr["three_speaker_n"] else None
    w(f"| 3 | Questions to others get no SAY line (3-speaker replays) | >= 90 % | {adr['three_speaker_no_say']}/{adr['three_speaker_n']} = {pc(r3)} "
      f"(all dialogues: {adr['no_say']}/{adr['questions_to_other']}) | {'met' if r3 is not None and r3 >= 0.9 else ('missed' if r3 is not None else 'not measured')} |")
    w("| 4 | Replay through the MacBook speakers produces no false \"me\" turns | zero | the me channel and the speaker-bleed test need P1-5 (follow-up) | not measured |")
    ok_d = det["precision"] is not None and det["recall"] is not None and det["precision"] >= 0.8 and det["recall"] >= 0.8
    w(f"| 5 | Question detection, questions to the user | precision and recall >= 80 % | precision {pc(det['precision'])} "
      f"({det['true_positive_turns']}/{det['predicted_turns']}), recall {pc(det['recall'])} ({det['covered']}/{det['positives']}) | {'met' if ok_d else 'missed'} |")
    if gr.get("lines_checked"):
        w(grounding_row(gr))
    else:
        w("| 6 | No suggestion states a number, date or fact absent from the pack | zero | no suggestion lines were produced | not measured |")
    w(audio_row(fs))
    w(f"| 8 | API key never in logs or files | none | {scan['files_scanned']} files scanned (everything under eval/out (every recorded stdout line, stderr log, metadata and score file, the spend ledger) and this report): exact Keychain key and key-shaped strings "
      f"{'not found' if scan['pass'] else 'FOUND'} | {'met' if scan['pass'] else 'missed'} |")
    w(f"| 9 | Cost per 30-minute meeting measured | measured | ${f(cost['usd_per_30_min'], 3)} per 30 min of replayed dialogue (${f(cost['total_usd'], 3)} over {f(cost['replay_minutes'], 1)} min, "
      "pre-warm and summaries included); shown in Settings: needs P1-5 | measured; Settings display not measured |")
    w("")
    if notes.strip():
        w(NOTES_PLACEHOLDER)        # filled in at the end, checked against every generated table (notes_section)
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
    if gr.get("violations") or gr.get("unjudged") or gr.get("cleared_lines"):
        w("## Grounding findings")
        w("")
        for v in gr.get("violations", []):
            who = f", written by tier {v['tier']}, flagged by {v['flagged_by']}" if v.get("flagged_by") else ""
            w(f"- {v['dialogue']} ({v['category']}{who}): \"{v['line']}\" (string check: {v['unresolved']}; judge: {v.get('judge_claim')})")
        if gr.get("violation_rule") != "either judge":
            for v in gr.get("cleared_lines", []):
                w(f"- {v['dialogue']} ({v['category']}): \"{v['line']}\" (flagged by Haiku, cleared by Sonnet; a violation under the either-judge rule; judge: {v.get('judge_claim')})")
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
    body = "\n".join(x for x in lines if x != NOTES_PLACEHOLDER)
    return "\n".join(notes_section(notes, run, body) if x == NOTES_PLACEHOLDER else x for x in lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    a = ap.parse_args()
    from paths import OUT
    run_dir = OUT / a.run
    scores = json.loads((run_dir / "scores.json").read_text())
    fs = audio_watch_by_dialogue(run_dir)
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
