"""Grounding over a scored run: string check on every shown SAY line and bullet, then the Haiku judge on the rest."""

from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import grounding  # noqa: E402


def collect(res: dict) -> list[dict]:
    items = []
    for d in res["dialogues"]:
        for r in d.get("rows", []):
            if r["warmup"]:
                continue
            q = r["text"] + (" / heard: " + r["heard"] if r["heard"] else "")
            for sl in r["suggestion_lines"]:
                items.append({"dialogue": d["id"], "index": r["index"], "category": r["category"], "turn_id": sl["turn_id"],
                              "call": sl["call"], "question": q, "line": sl["line"]})
    return items


def run_grounding(res: dict, session_dir: Path, judge: bool, budget_usd: float, run: str) -> dict:
    corpus = grounding.corpus_text(session_dir)
    items = collect(res)
    auto_clean, pending = [], []
    for it in items:
        un = grounding.unresolved(it["line"], corpus, it["question"])
        it["claims"] = grounding.claims(it["line"])
        if un:
            it["unresolved"] = un
            pending.append(it)
        else:
            auto_clean.append(it)
    out = {"lines_checked": len(items), "auto_supported": len(auto_clean), "unresolved_by_string_check": len(pending),
           "judged": 0, "judge_supported": 0, "violations": [], "unjudged": [], "judge_cost_usd": 0.0,
           "unresolved_but_judged_supported": 0}
    if not judge:
        out["unjudged"] = [{k: p[k] for k in ("dialogue", "line", "unresolved")} for p in pending]
        return out
    # The judge reads every line (cheap: Haiku, about a cent for a whole run), not only the ones the string check could not
    # resolve: a claim without a number, date or name ("we rewrote it in Rust") would pass the string check unseen.
    for it in auto_clean:
        it["unresolved"] = {}
    pending = items
    import judge as J
    import run_replay as RR
    spent = 0.0
    batch = 20
    pack_low = " ".join(corpus_pack(session_dir).lower().split())
    for start in range(0, len(pending), batch):
        chunk = pending[start:start + batch]
        if RR.ledger_total() + 0.01 > RR.TOTAL_CAP_USD or spent + 0.01 > budget_usd:
            out["unjudged"] += [{k: p[k] for k in ("dialogue", "line", "unresolved")} for p in chunk]
            continue
        verdicts, cost = J.judge_lines(corpus_pack(session_dir), [{"i": i, "question": c["question"], "line": c["line"]} for i, c in enumerate(chunk)])
        spent += cost
        RR.ledger_add(run, "grounding-judge", cost)
        by_i = {v.get("i"): v for v in verdicts if isinstance(v, dict)}
        for i, c in enumerate(chunk):
            v = by_i.get(i)
            if v is None:
                out["unjudged"].append({k: c[k] for k in ("dialogue", "line", "unresolved")})
                continue
            out["judged"] += 1
            if v.get("supported"):
                ev = (v.get("evidence") or "").strip().lower()
                if ev and " ".join(ev.split()) not in pack_low:
                    out.setdefault("evidence_not_in_pack", 0)
                    out["evidence_not_in_pack"] += 1
                out["judge_supported"] += 1
                if c["unresolved"]:
                    out["unresolved_but_judged_supported"] += 1
            else:
                out["violations"].append({"dialogue": c["dialogue"], "category": c["category"], "question": c["question"], "line": c["line"],
                                          "unresolved": c["unresolved"], "judge_claim": v.get("unsupported_claim")})
    # Second opinion (Sonnet) on what Haiku flagged: a line is a violation only when both judges say it is unsupported.
    flagged = out["violations"]
    out["haiku_flagged"] = len(flagged)
    confirmed = []
    if flagged and RR.ledger_total() + 0.03 < RR.TOTAL_CAP_USD:
        try:
            verdicts, cost = J.judge_lines(corpus_pack(session_dir), [{"i": i, "question": v["question"], "line": v["line"]} for i, v in enumerate(flagged)],
                                           model=J.SECOND_MODEL)
            spent += cost
            RR.ledger_add(run, "grounding-second-opinion", cost)
            by_i = {v.get("i"): v for v in verdicts if isinstance(v, dict)}
            for i, v in enumerate(flagged):
                sv = by_i.get(i)
                v["second_opinion"] = None if sv is None else {"supported": bool(sv.get("supported")), "claim": sv.get("unsupported_claim")}
                if sv is None or not sv.get("supported"):
                    confirmed.append(v)
            out["cleared_by_second_opinion"] = len(flagged) - len(confirmed)
            out["cleared_lines"] = [v for v in flagged if v not in confirmed]
            out["violations"] = confirmed
        except J.JudgeError as e:
            out["second_opinion_error"] = str(e)
    out["judge_cost_usd"] = round(spent, 5)
    return out


def corpus_pack(session_dir: Path) -> str:
    return (session_dir / "pack.md").read_text(encoding="utf-8")
