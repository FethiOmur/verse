#!/usr/bin/env python3
"""Scores a replay run (eval/out/<run>/) against the dialogue labels.

    python score.py --run live1 [--judge]      -> prints a summary and writes eval/out/<run>/scores.json

All times are wall-clock seconds from the *true* acoustic end of each labelled utterance: the runner knows exactly where
every utterance sits in the generated audio, and verse-run's `session_t0` metric ties file time to wall time
(`wall(file t) = t0 + origin_remote + t`). Stdlib only (the judge, when asked for, imports `anthropic`).
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import grounding  # noqa: E402
import labels  # noqa: E402

# Matching: a detected turn belongs to the labelled utterance whose speech ends nearest to the turn's audio end, as long
# as the turn ends between (start - BEFORE) and (end + AFTER) on the session clock.
MATCH_BEFORE = 0.3
MATCH_AFTER = 1.8


# ---------------------------------------------------------------- statistics

def pct(vals: list[float], p: float) -> float | None:
    """p50 = median; p90 = nearest rank (robust for small n, same rule as brain/runtime/replay.py)."""
    if not vals:
        return None
    s = sorted(vals)
    if p == 0.9:
        return s[max(0, math.ceil(0.9 * len(s)) - 1)]
    return statistics.median(s)


def summarize(vals: list[float]) -> dict:
    return {"n": len(vals), "p50": None if not vals else round(pct(vals, 0.5), 3), "p90": None if not vals else round(pct(vals, 0.9), 3),
            "max": None if not vals else round(max(vals), 3)}


# ---------------------------------------------------------------- loading

def load_events(jsonl: Path) -> list[tuple[float, dict]]:
    out = []
    for ln in jsonl.read_text(encoding="utf-8").splitlines():
        if ln.strip():
            r = json.loads(ln)
            out.append((r["wall"], r["line"]))
    return out


def session_clock(events: list[tuple[float, dict]]) -> tuple[float, float] | None:
    """(wall time of session second 0, session second of the file's first sample)."""
    for _, o in events:
        if o.get("type") == "metric" and o.get("stage") == "session_t0":
            return float(o["t"]), float(o.get("origin_remote", 0.0))
    return None


def windows(label: dict, timeline: list[dict] | None, wall0: float, origin: float) -> list[dict]:
    """One entry per spoken (non-silent) utterance: its place on the session clock and in wall time."""
    out = []
    for i, u in enumerate(label["utterances"]):
        if u.get("silent_s"):
            continue
        t0, t1 = u["t_start"], u["t_end"]
        if timeline:
            tl = next((t for t in timeline if t["index"] == i), None)
            if tl:
                t0, t1 = tl["t_start"], tl["t_end"]
        out.append({"index": i, "u": u, "s_start": origin + t0, "s_end": origin + t1, "wall_end": wall0 + origin + t1})
    return out


def detected_turns(events: list[tuple[float, dict]]) -> list[dict]:
    turns = []
    for w, o in events:
        if o.get("type") == "turn" and o.get("dir") == "to_brain" and o.get("speaker") == "remote":
            turns.append({"turn_id": o["turn_id"], "text": o.get("text", ""), "addressee": o.get("addressee", "unknown"),
                          "kind": o.get("kind", "question"), "t_audio_end": float(o.get("t_audio_end", 0.0)), "wall": w})
    return turns


def match_turns(turns: list[dict], wins: list[dict]) -> tuple[dict[int, list[dict]], list[dict]]:
    """label index -> matched turns (in order); plus the turns that match no label."""
    by_label: dict[int, list[dict]] = {w["index"]: [] for w in wins}
    spurious = []
    for t in turns:
        cands = [w for w in wins if w["s_start"] - MATCH_BEFORE <= t["t_audio_end"] <= w["s_end"] + MATCH_AFTER]
        if not cands:
            spurious.append(t)
            continue
        best = min(cands, key=lambda w: abs(t["t_audio_end"] - w["s_end"]))
        by_label[best["index"]].append(t)
    return by_label, spurious


def is_answerable(t: dict) -> bool:
    return t["kind"] == "question" and t["addressee"] != "other"


# ---------------------------------------------------------------- per-dialogue scoring

def score_dialogue(label: dict, events: list[tuple[float, dict]], meta: dict | None, session_dir: Path | None = None) -> dict:
    clock = session_clock(events)
    if clock is None:
        return {"id": label["id"], "error": "no session_t0 metric (verse-run did not start listening)"}
    wall0, origin = clock
    timeline = (meta or {}).get("timeline")
    wins = windows(label, timeline, wall0, origin)
    turns = detected_turns(events)
    by_label, spurious = match_turns(turns, wins)

    # engine warm-up: results before the English engine took over are not steady-state
    warm_until = 0.0
    for e in (meta or {}).get("engine", []):
        if e.get("state") == "engine_switch":
            warm_until = max(warm_until, float(e.get("switchAtSec", 0.0)) + 0.5)
        if e.get("state") == "engine_ready":
            warm_until = max(warm_until, float(e.get("readyAtSec", 0.0)))

    # index events by turn
    turn_sent = {}
    first_delta: dict[str, dict[str, float]] = {}
    deltas_by_turn: dict[str, list[dict]] = {}
    bank_hits: dict[str, list[tuple[float, dict]]] = {}
    chips: dict[str, list[tuple[float, dict]]] = {}
    verdicts: dict[str, list[dict]] = {}
    statuses = []
    for w, o in events:
        ty, tid = o.get("type"), o.get("turn_id")
        if ty == "metric" and o.get("stage") == "turn_sent":
            turn_sent[tid] = w
        elif ty == "delta" and tid:
            deltas_by_turn.setdefault(tid, []).append(o)
            if o.get("text", "").strip():
                first_delta.setdefault(tid, {}).setdefault(o["tier"], w)
        elif ty == "bank_hit" and o.get("dir") == "to_brain":
            bank_hits.setdefault(tid, []).append((w, o))
        elif ty == "chip":
            chips.setdefault(tid, []).append((w, o))
        elif ty == "bank_verdict":
            verdicts.setdefault(tid, []).append(o)
        elif ty == "status":
            statuses.append(o)

    rows = []
    for win in wins:
        u = win["u"]
        ts = by_label[win["index"]]
        answ = [t for t in ts if is_answerable(t)]
        main = answ[-1] if answ else (ts[-1] if ts else None)
        row = {"index": win["index"], "category": u["category"], "text": u["text"], "is_question": u["is_question"], "addressee": u["addressee"],
               "bank_id": u["bank_id"], "warmup": win["s_start"] < warm_until, "turn_ids": [t["turn_id"] for t in ts],
               "heard": " | ".join(t["text"] for t in ts), "detected_answerable": bool(answ),
               "detected_kind": [t["kind"] for t in ts], "heard_addressee": [t["addressee"] for t in ts]}
        # delivery
        tids = [t["turn_id"] for t in ts]
        ds = [d for tid in tids for d in deltas_by_turn.get(tid, [])]
        lines = grounding.assemble_lines(ds)
        row["say_lines"] = sum(1 for ls in lines.values() for ln in ls if ln.startswith("SAY:"))
        row["suggestion_lines"] = [{"call": cid, "line": ln, "turn_id": next((d["turn_id"] for d in ds if d["id"] == cid), None)}
                                   for cid, ls in lines.items() for ln in grounding.suggestion_lines(ls)]
        if main:
            tid = main["turn_id"]
            row["main_turn"] = tid
            row["asr_endpoint_s"] = round(turn_sent[tid] - win["wall_end"], 3) if tid in turn_sent else None
            fd = first_delta.get(tid, {})
            sf = {k: v for k, v in fd.items() if k in ("S", "F")}
            if sf:
                tier = min(sf, key=lambda k: sf[k])
                row["sf_tier"] = tier
                row["sf_first_text_s"] = round(sf[tier] - win["wall_end"], 3)
            if "D" in fd:
                row["d_first_text_s"] = round(fd["D"] - win["wall_end"], 3)
            for tt in ts:
                hits = bank_hits.get(tt["turn_id"], [])
                if hits:
                    row.setdefault("bank_hits", []).extend([{"bank_id": h[1].get("bank_id"), "score": h[1].get("score"),
                                                              "visible_s": round(h[0] - win["wall_end"], 3)} for h in hits])
                for v in verdicts.get(tt["turn_id"], []):
                    row.setdefault("bank_verdicts", []).append({"bank_id": v.get("bank_id"), "agree": v.get("agree")})
                for c in chips.get(tt["turn_id"], []):
                    row.setdefault("chips", []).append({"text": c[1].get("text"), "kind": c[1].get("kind"),
                                                        "visible_s": round(c[0] - win["wall_end"], 3)})
        rows.append(row)

    return {"id": label["id"], "speakers": label.get("speakers"), "rows": rows, "turns": len(turns),
            "spurious_turns": [{"turn_id": t["turn_id"], "text": t["text"], "kind": t["kind"], "addressee": t["addressee"]} for t in spurious],
            "answerable_turns": sum(1 for t in turns if is_answerable(t)),
            "statuses": [{"state": s.get("state"), "message": s.get("message", "")[:120]} for s in statuses if s.get("state") not in ("ready", "warming")],
            "warm_until_session_s": round(warm_until, 2)}


# ---------------------------------------------------------------- aggregate

def aggregate(dialogue_scores: list[dict], metas: dict[str, dict]) -> dict:
    rows = [dict(r, dialogue=d["id"], speakers=d.get("speakers")) for d in dialogue_scores if "rows" in d for r in d["rows"]]
    steady = [r for r in rows if not r["warmup"]]
    excluded = len(rows) - len(steady)

    qs_me = [r for r in steady if r["is_question"] and r["addressee"] == "me"]
    qs_other = [r for r in steady if r["is_question"] and r["addressee"] == "other"]

    # --- question detection (only questions to Alex count as positives). A turn is "predicted positive" when the
    # runner would send it to the brain as a question for Alex: kind question and not addressed to someone else.
    pred_turns = 0
    for d in dialogue_scores:
        if "rows" in d:
            pred_turns += sum(1 for t in d["spurious_turns"] if t["kind"] == "question" and t["addressee"] != "other")
    for r in steady:
        pred_turns += sum(1 for k, a in zip(r["detected_kind"], r["heard_addressee"]) if k == "question" and a != "other")
    covered = sum(1 for r in qs_me if r["detected_answerable"])
    tp_turns = covered   # one true positive per covered question; extra turns for the same question count against precision
    detection = {
        "positives": len(qs_me), "covered": covered,
        "recall": None if not qs_me else round(covered / len(qs_me), 4),
        "predicted_turns": pred_turns, "true_positive_turns": tp_turns,
        "precision": None if not pred_turns else round(tp_turns / pred_turns, 4),
        "missed": [{"dialogue": r["dialogue"], "text": r["text"], "heard": r["heard"], "kinds": r["detected_kind"], "addressee": r["heard_addressee"]}
                   for r in qs_me if not r["detected_answerable"]],
        "false_positives": [{"dialogue": r["dialogue"], "category": r["category"], "text": r["text"], "heard": r["heard"]}
                            for r in steady if not (r["is_question"] and r["addressee"] == "me")
                            and any(k == "question" and a != "other" for k, a in zip(r["detected_kind"], r["heard_addressee"]))],
    }
    # --- addressee other -> no SAY
    other_ok = [r for r in qs_other if r["say_lines"] == 0]
    three = [r for r in qs_other if r.get("speakers") == 3]
    addressee = {
        "questions_to_other": len(qs_other), "no_say": len(other_ok),
        "no_say_rate": None if not qs_other else round(len(other_ok) / len(qs_other), 4),
        "three_speaker_n": len(three), "three_speaker_no_say": sum(1 for r in three if r["say_lines"] == 0),
        "classified_other": sum(1 for r in qs_other if r["heard_addressee"] and all(a == "other" for a in r["heard_addressee"])),
        "not_detected_at_all": sum(1 for r in qs_other if not r["turn_ids"]),
        "failures": [{"dialogue": r["dialogue"], "text": r["text"], "heard": r["heard"], "addressee": r["heard_addressee"], "say_lines": r["say_lines"]}
                     for r in qs_other if r["say_lines"] > 0],
    }
    # --- bank
    banked = [r for r in steady if r["bank_id"] and r["is_question"]]
    probed = [r for r in steady if r["category"] in ("exact", "paraphrase", "offbank", "other", "statement", "fragment", "reply")]

    def hit_ids(r):
        return [h["bank_id"] for h in r.get("bank_hits", [])]

    def agreed_ids(r):
        return [v["bank_id"] for v in r.get("bank_verdicts", []) if v.get("agree")]

    def wrong(r, ids):
        return [i for i in ids if i != r["bank_id"]]
    per_cat = {}
    for cat in ("exact", "paraphrase"):
        rs = [r for r in banked if r["category"] == cat]
        per_cat[cat] = {"n": len(rs), "hit": sum(1 for r in rs if r["bank_id"] in hit_ids(r)),
                        "confirmed": sum(1 for r in rs if r["bank_id"] in agreed_ids(r))}
    wrong_rows = [r for r in probed if wrong(r, hit_ids(r))]
    wrong_conf = [r for r in probed if wrong(r, agreed_ids(r))]
    bank = {
        "banked_questions": len(banked), "hits": sum(1 for r in banked if r["bank_id"] in hit_ids(r)),
        "confirmed_by_haiku": sum(1 for r in banked if r["bank_id"] in agreed_ids(r)),
        "hit_rate": None if not banked else round(sum(1 for r in banked if r["bank_id"] in hit_ids(r)) / len(banked), 4),
        "by_category": per_cat,
        "utterances_probed": len(probed), "wrong_hits": len(wrong_rows), "wrong_hit_rate": None if not probed else round(len(wrong_rows) / len(probed), 4),
        "wrong_after_haiku": len(wrong_conf), "wrong_after_haiku_rate": None if not probed else round(len(wrong_conf) / len(probed), 4),
        "wrong_detail": [{"dialogue": r["dialogue"], "category": r["category"], "text": r["text"], "bank_ids": hit_ids(r), "expected": r["bank_id"]} for r in wrong_rows],
    }
    # --- latency (all from the true acoustic end)
    def col(key, rs=steady):
        return [r[key] for r in rs if r.get(key) is not None]
    answered = [r for r in qs_me if r.get("main_turn")]
    s_path = [r for r in answered if r.get("sf_tier") == "S"]
    f_path = [r for r in answered if r.get("sf_tier") == "F"]
    bank_vis = []
    for r in banked:   # the first hit on the right entry (the matcher repeats a hit while it stays valid)
        first = next((h["visible_s"] for h in r.get("bank_hits", []) if h["bank_id"] == r["bank_id"]), None)
        if first is not None:
            bank_vis.append(first)
    chip_vis = [c["visible_s"] for r in qs_me for c in r.get("chips", [])]
    latency = {
        "acoustic_end_to_turn_sent": summarize(col("asr_endpoint_s", answered)),
        "first_visible_text_any_SF": summarize(col("sf_first_text_s", answered)),
        "speculation_hit_opener_visible": summarize(col("sf_first_text_s", s_path)),
        "fresh_haiku_first_word": summarize(col("sf_first_text_s", f_path)),
        "sonnet_deep_first_words": summarize(col("d_first_text_s", answered)),
        "bank_hit_visible": summarize(bank_vis),
        "fact_chip_visible": summarize(chip_vis),
        "questions_with_no_sf_text": sum(1 for r in answered if r.get("sf_tier") is None),
        "questions_with_d_text": sum(1 for r in answered if r.get("d_first_text_s") is not None),
        "n_speculation_path": len(s_path), "n_fresh_path": len(f_path),
    }
    # --- statements and fragments
    st = [r for r in steady if r["category"] == "statement"]
    fr = [r for r in steady if r["category"] == "fragment"]
    other_cats = {
        "statements": len(st), "statements_with_say": sum(1 for r in st if r["say_lines"]),
        "statements_called_question": sum(1 for r in st if any(k == "question" for k in r["detected_kind"])),
        "fragments": len(fr), "fragments_with_output": sum(1 for r in fr if r["say_lines"] or r["suggestion_lines"]),
    }
    cost = {"per_dialogue_usd": {}, "total_usd": 0.0}
    mins = 0.0
    for did, m in metas.items():
        cost["per_dialogue_usd"][did] = m.get("cost_usd", 0.0)
        cost["total_usd"] += m.get("cost_usd", 0.0)
        mins += max((m.get("duration_s", 0.0) - m.get("lead_in_s", 0.0)), 0.0) / 60
    cost["total_usd"] = round(cost["total_usd"], 5)
    cost["replay_minutes"] = round(mins, 2)
    cost["usd_per_30_min"] = None if not mins else round(cost["total_usd"] / mins * 30, 4)
    return {"questions_to_owner": len(qs_me), "excluded_warmup_utterances": excluded, "detection": detection, "addressee": addressee,
            "bank": bank, "latency": latency, "other": other_cats, "cost": cost}


# ---------------------------------------------------------------- run-level

def score_run(run_dir: Path, session_dir: Path | None = None, dialogues_dir: Path = labels.DIALOGUES_DIR) -> dict:
    all_labels = {d["id"]: d for d in labels.load_all(dialogues_dir)}
    scores, metas = [], {}
    for jl in sorted(run_dir.glob("*.jsonl")):
        did = jl.stem
        if did not in all_labels:
            continue
        mf = run_dir / f"{did}.meta.json"
        meta = json.loads(mf.read_text()) if mf.exists() else None
        if meta:
            metas[did] = meta
        scores.append(score_dialogue(all_labels[did], load_events(jl), meta))
    return {"run": run_dir.name, "dialogues": scores, "aggregate": aggregate(scores, metas), "metas": {k: {kk: v[kk] for kk in (
        "duration_s", "lead_in_s", "loadavg_before", "loadavg_after", "exit_code", "cost_usd", "elapsed_s") if kk in v} for k, v in metas.items()}}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True)
    ap.add_argument("--session", default=str(Path("~/Library/Application Support/Verse/sessions/sample-interview").expanduser()))
    ap.add_argument("--judge", action="store_true", help="grounding: ask the independent Haiku judge about lines with unresolved claims")
    ap.add_argument("--judge-budget-usd", type=float, default=0.10)
    a = ap.parse_args()
    from paths import OUT
    run_dir = OUT / a.run
    res = score_run(run_dir)
    from grounding_run import run_grounding  # local import: keeps score.py network-free
    res["grounding"] = run_grounding(res, Path(a.session), judge=a.judge, budget_usd=a.judge_budget_usd, run=a.run)
    (run_dir / "scores.json").write_text(json.dumps(res, indent=1, ensure_ascii=False) + "\n")
    ag = res["aggregate"]
    print(json.dumps({k: ag[k] for k in ("questions_to_owner", "detection", "addressee", "latency")}, indent=1)[:3000])
    return 0


if __name__ == "__main__":
    sys.exit(main())
