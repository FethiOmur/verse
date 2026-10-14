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


def run_grounding(res: dict, session_dir: Path, judge: bool, budget_usd: float, run: str, passes: int = 2) -> dict:
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
    import judge as J
    import run_replay as RR
    spent = 0.0
    batch = 20
    pack = corpus_pack(session_dir)
    pack_low = " ".join(pack.lower().split())
    flagged: dict[int, dict] = {}     # item index -> the first Haiku verdict that flagged it
    judged_ok: set[int] = set()
    evidence_missing = 0
    # Haiku reads every line `passes` times: one pass misses lines that another flags (it is not deterministic).
    for p in range(passes):
        for start in range(0, len(items), batch):
            chunk_idx = list(range(start, min(start + batch, len(items))))
            if RR.ledger_total() + 0.01 > RR.TOTAL_CAP_USD or spent + 0.01 > budget_usd:
                continue
            verdicts = []
            for attempt in (1, 2):    # one retry: the judge now and then returns text that is not JSON
                try:
                    verdicts, cost = J.judge_lines(pack, [{"i": k, "question": items[k]["question"], "line": items[k]["line"]} for k in chunk_idx])
                except J.JudgeError as e:
                    out.setdefault("judge_errors", []).append(f"pass {p + 1} batch {start}: {e}")
                    continue
                spent += cost
                RR.ledger_add(run, f"grounding-judge pass {p + 1}", cost)
                break
            by_i = {v.get("i"): v for v in verdicts if isinstance(v, dict)}
            for k in chunk_idx:
                v = by_i.get(k)
                if v is None:
                    continue
                judged_ok.add(k)
                if v.get("supported"):
                    ev = " ".join((v.get("evidence") or "").strip().lower().split())
                    if ev and ev not in pack_low:
                        evidence_missing += 1
                elif k not in flagged:
                    flagged[k] = v
    out["judged"] = len(judged_ok)
    out["judge_passes"] = passes
    out["unjudged"] = [{k2: items[k][k2] for k2 in ("dialogue", "line", "unresolved")} for k in range(len(items)) if k not in judged_ok]
    out["judge_supported_in_every_pass"] = len(judged_ok) - len(flagged)
    out["unresolved_but_judged_supported"] = sum(1 for k in judged_ok if k not in flagged and items[k]["unresolved"])
    out["evidence_not_in_pack"] = evidence_missing
    out["haiku_flagged"] = len(flagged)
    # Second opinion (Sonnet) on everything Haiku flagged in any pass: a line is a violation only when both judges say it
    # is unsupported.
    confirmed, cleared = [], []
    order = sorted(flagged)
    if order and RR.ledger_total() + 0.03 < RR.TOTAL_CAP_USD:
        try:
            verdicts, cost = J.judge_lines(pack, [{"i": n, "question": items[k]["question"], "line": items[k]["line"]} for n, k in enumerate(order)],
                                           model=J.SECOND_MODEL)
            spent += cost
            RR.ledger_add(run, "grounding-second-opinion", cost)
            by_i = {v.get("i"): v for v in verdicts if isinstance(v, dict)}
            for n, k in enumerate(order):
                sv = by_i.get(n)
                rec = {"dialogue": items[k]["dialogue"], "category": items[k]["category"], "question": items[k]["question"], "line": items[k]["line"],
                       "unresolved": items[k]["unresolved"], "judge_claim": flagged[k].get("unsupported_claim"),
                       "second_opinion": None if sv is None else {"supported": bool(sv.get("supported")), "claim": sv.get("unsupported_claim")}}
                (cleared if sv is not None and sv.get("supported") else confirmed).append(rec)
        except J.JudgeError as e:
            out["second_opinion_error"] = str(e)
            confirmed = [{"dialogue": items[k]["dialogue"], "category": items[k]["category"], "question": items[k]["question"], "line": items[k]["line"],
                          "unresolved": items[k]["unresolved"], "judge_claim": flagged[k].get("unsupported_claim"), "second_opinion": None} for k in order]
    out["violations"] = confirmed
    out["cleared_lines"] = cleared
    out["cleared_by_second_opinion"] = len(cleared)
    out["judge_cost_usd"] = round(spent, 5)
    return out


def corpus_pack(session_dir: Path) -> str:
    return (session_dir / "pack.md").read_text(encoding="utf-8")
