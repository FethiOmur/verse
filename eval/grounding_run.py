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


def tier_of(it: dict) -> str:
    """Tier that wrote the line: recorded on the item, else the first letter of its call id (s0001, f0008, d0011 in older scores.json)."""
    t = it.get("tier") or (it.get("call") or "")[:1].upper()
    return t if t in ("S", "F", "D") else "?"


def run_grounding(res: dict, session_dir: Path, judge: bool, budget_usd: float, run: str, passes: int = 2,
                  second_on_all: bool = False) -> dict:
    """String check on every shown line, then the judges.

    Rules (eval review E1, E2, E5):
    - every verdict is stored in `verdicts` (dialogue, line, tier, model, pass, supported, evidence, evidence_found, flagged);
    - a verdict is *flagged* when the judge says unsupported, or says supported with a quote that is not in the pack (after `grounding.norm`
      on both sides). A supported verdict with no quote at all is not flagged (generic lines have nothing to quote); it is counted apart;
    - a line is a violation when EITHER judge flags it. The second judge (Sonnet) reads the lines the first (Haiku, `passes` passes) flagged, or
      every line with `second_on_all`; it can no longer clear a line, and the two judges' agreement is reported separately;
    - passes are kept: per-line flag frequency, and the range and union of the per-pass counts.
    """
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
    verdicts_out: list[dict] = []
    first_flags: dict[int, list[dict]] = {}       # item index -> its flagged first-judge verdicts (one per pass that flagged it)
    first_seen: dict[int, int] = {}               # item index -> passes in which the first judge returned a verdict for it
    per_pass_flagged = [0] * passes
    judged_ok: set[int] = set()
    no_quote = 0
    evidence_missing = 0

    def record(k: int, model: str, pass_id, v: dict) -> dict:
        nonlocal no_quote, evidence_missing
        supported = bool(v.get("supported"))
        ev_raw = v.get("evidence") if isinstance(v.get("evidence"), str) else None
        found = grounding.evidence_found(ev_raw, pack) if supported else None
        if supported and found is None:
            no_quote += 1
        flagged = (not supported) or found is False
        if supported and found is False:
            evidence_missing += 1
        claim = v.get("unsupported_claim") if not supported else ("evidence quote not found in the pack: " + ev_raw if found is False else None)
        tier = tier_of(items[k])
        rec = {"dialogue": items[k]["dialogue"], "line": items[k]["line"], "tier": tier, "model": model, "own_model": J.own_model(tier, model),
               "pass": pass_id, "supported": supported, "evidence": ev_raw, "evidence_found": found, "flagged": flagged, "claim": claim}
        verdicts_out.append(rec)
        return rec

    def ask(chunk_idx: list[int], model: str, label: str):
        nonlocal spent
        for attempt in (1, 2):    # one retry: the judge now and then returns text that is not JSON
            try:
                verdicts, cost = J.judge_lines(pack, [{"i": n, "question": items[k]["question"], "line": items[k]["line"]}
                                                      for n, k in enumerate(chunk_idx)], model=model)
            except J.JudgeError as e:
                out.setdefault("judge_errors", []).append(f"{label}: {e}")
                continue
            spent += cost
            RR.ledger_add(run, label, cost)
            return {v.get("i"): v for v in verdicts if isinstance(v, dict)}, chunk_idx
        return {}, chunk_idx

    def over_budget() -> bool:
        return RR.ledger_total() + 0.01 > RR.TOTAL_CAP_USD or spent + 0.01 > budget_usd

    # First judge (Haiku) reads every line `passes` times: one pass misses lines that another flags (it is not deterministic).
    for p in range(passes):
        for start in range(0, len(items), batch):
            if over_budget():
                continue
            chunk_idx = list(range(start, min(start + batch, len(items))))
            by_i, _ = ask(chunk_idx, J.MODEL, f"grounding-judge pass {p + 1}")
            for n, k in enumerate(chunk_idx):
                v = by_i.get(n)
                if v is None:
                    continue
                judged_ok.add(k)
                first_seen[k] = first_seen.get(k, 0) + 1
                rec = record(k, J.MODEL, p + 1, v)
                if rec["flagged"]:
                    first_flags.setdefault(k, []).append(rec)
                    per_pass_flagged[p] += 1
    out["judged"] = len(judged_ok)
    out["judge_passes"] = passes
    out["unjudged"] = [{k2: items[k][k2] for k2 in ("dialogue", "line", "unresolved")} for k in range(len(items)) if k not in judged_ok]
    out["judge_supported_in_every_pass"] = len(judged_ok) - len(first_flags)
    out["unresolved_but_judged_supported"] = sum(1 for k in judged_ok if k not in first_flags and items[k]["unresolved"])
    out["evidence_not_in_pack"] = evidence_missing      # per verdict; the verdicts are in `verdicts`, so each can be audited
    out["supported_without_quote"] = no_quote
    out["haiku_flagged"] = len(first_flags)

    # Second judge (Sonnet): the lines the first one flagged in any pass, or every line with second_on_all.
    order = sorted(range(len(items))) if second_on_all else sorted(first_flags)
    order = [k for k in order if k in judged_ok]
    second: dict[int, dict] = {}
    for start in range(0, len(order), batch):
        chunk_idx = order[start:start + batch]
        if RR.ledger_total() + 0.03 > RR.TOTAL_CAP_USD:
            out["second_opinion_error"] = "ledger cap reached before the second opinion"
            break
        by_i, _ = ask(chunk_idx, J.SECOND_MODEL, "grounding-second-opinion")
        if not by_i:
            out["second_opinion_error"] = "second opinion failed for a batch (see judge_errors)"
        for n, k in enumerate(chunk_idx):
            v = by_i.get(n)
            if v is not None:
                second[k] = record(k, J.SECOND_MODEL, "second", v)

    violations, cleared = [], []
    agree = {"read_by_both": 0, "both_flagged": 0, "first_only": 0, "second_only": 0, "both_clear": 0}
    for k in sorted(set(first_flags) | {k for k, r in second.items() if r["flagged"]}):
        f_recs = first_flags.get(k, [])
        s_rec = second.get(k)
        by = "both" if f_recs and s_rec and s_rec["flagged"] else ("first" if f_recs else "second")
        first_claim = next((r["claim"] for r in f_recs if r["claim"]), None)
        rec = {"dialogue": items[k]["dialogue"], "category": items[k]["category"], "question": items[k]["question"], "line": items[k]["line"],
               "tier": tier_of(items[k]), "unresolved": items[k]["unresolved"], "judge_claim": first_claim or (s_rec or {}).get("claim"),
               "flagged_by": by, "flagged_in_passes": [r["pass"] for r in f_recs],
               "second_opinion": None if s_rec is None else {"supported": not s_rec["flagged"], "claim": s_rec["claim"]}}
        violations.append(rec)
        if f_recs and s_rec is not None and not s_rec["flagged"]:
            cleared.append(rec)
    for k, s_rec in second.items():
        agree["read_by_both"] += 1
        f, sf = k in first_flags, s_rec["flagged"]
        agree["both_flagged" if f and sf else "first_only" if f else "second_only" if sf else "both_clear"] += 1
    out["violations"] = violations
    out["violation_rule"] = "either judge"
    out["cleared_lines"] = cleared                      # first judge flagged, second judge did not: still violations, listed for audit
    out["cleared_by_second_opinion"] = len(cleared)
    out["judge_agreement"] = agree
    out["second_on_all"] = second_on_all
    out["verdicts"] = verdicts_out
    freq = [{"dialogue": items[k]["dialogue"], "line": items[k]["line"], "tier": tier_of(items[k]), "flagged_in": len(r), "of": first_seen.get(k, 0)}
            for k, r in sorted(first_flags.items())]
    ranged = [n for n in per_pass_flagged]
    out["pass_summary"] = {"per_pass_flagged": per_pass_flagged, "violations_range": [min(ranged), max(ranged)] if ranged else [0, 0],
                           "violations_union": len(first_flags), "flag_frequency": freq}
    by_tier: dict[str, dict] = {}
    for k in judged_ok:
        t = by_tier.setdefault(tier_of(items[k]), {"lines": 0, "flagged": 0})
        t["lines"] += 1
    for v in violations:
        by_tier[v["tier"]]["flagged"] += 1
    out["by_tier"] = by_tier
    out["judge_cost_usd"] = round(spent, 5)
    return out


def corpus_pack(session_dir: Path) -> str:
    return (session_dir / "pack.md").read_text(encoding="utf-8")
