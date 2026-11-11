#!/usr/bin/env python3
"""Criterion 2 (bank hits) of a stored replay, re-decided under the brain's current embedding accept rule. Offline, no API.

    PYTHONPATH=../brain python rescore_bank.py --run f3-embed

The live brain records a `metric stage:"embed"` line for every partial its paraphrase matcher evaluated (top entry, its
cosine, the runner-up's). Those evaluations do not depend on the accept rule (the brain keeps evaluating after its own
hit; only a Swift n-gram hit stops it, and that is in the recording too), so the rule can be replayed on them exactly.
The recorded `bank_hit via:"embed"` lines are dropped, new ones are inserted, and score.py / report.py score the result
unchanged. Nothing is written.

Approximations (printed with the result):
- the final-text pass (`embed_final_pass`) did not exist when f3-embed was recorded: a turn that ends with no hit is given
  one more evaluation equal to its last recorded one, placed 60 ms after the turn was sent;
- the late-hit / newer-turn gates of the engine are not replayed.
A run recorded without the embedding path (live1: no `stage:"embed"` lines) cannot change: its paraphrase hits stay n-gram.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(1, str(HERE.parent / "brain"))
import labels  # noqa: E402
import report  # noqa: E402
import score  # noqa: E402
from verse_brain.runtime.embed import accepted  # noqa: E402
from verse_brain.runtime.settings import Config  # noqa: E402

OLD_RULE = (0.865, 0.02, 2)          # before 2026-11-11
FINAL_PASS_DELAY_S = 0.06            # an embedding job on the GPU takes 20-60 ms (bench/embed/results/latency_runs.txt)


def decide(evals: list[dict], threshold: float, margin: float, consec: int, final: bool) -> list[tuple[int, str, float, bool]]:
    """evals: one turn's recorded evaluations in order. -> [(index into evals, bank_id, score, from_final_pass)]."""
    cand, cnt, sent, out = None, 0, None, []
    for j, o in enumerate(evals):
        top, s1, s2 = o.get("top"), float(o.get("score", -1.0)), float(o.get("second", -1.0))
        last = final and j == len(evals) - 1 and sent is None
        if top is None or not accepted(s1, s2, threshold, margin):
            cand, cnt = None, 0
            continue
        cnt = cnt + 1 if top == cand else 1
        cand = top
        if (cnt >= consec or last) and top != sent:
            sent = top
            out.append((j, top, s1, last and cnt < consec))
    return out


def redecide(events: list[tuple[float, dict]], threshold: float, margin: float, consec: int, final: bool) -> list[tuple[float, dict]]:
    evals: dict[str, list[tuple[float, dict]]] = {}
    sent_at: dict[str, float] = {}
    for w, o in events:
        if o.get("type") == "metric" and o.get("stage") == "embed" and o.get("turn_id"):
            evals.setdefault(o["turn_id"], []).append((w, o))
        elif o.get("type") == "turn" and o.get("dir") == "to_brain":
            sent_at[o["turn_id"]] = w
    new = []
    for tid, ev in evals.items():
        for j, bid, s, from_final in decide([o for _, o in ev], threshold, margin, consec, final):
            w = ev[j][0]
            if from_final and tid in sent_at:
                w = max(w, sent_at[tid] + FINAL_PASS_DELAY_S)
            new.append((w, {"type": "bank_hit", "turn_id": tid, "bank_id": bid, "score": round(s, 4), "via": "embed"}))
    kept = [(w, o) for w, o in events if not (o.get("type") == "bank_hit" and o.get("via") == "embed")]
    return sorted(kept + new, key=lambda x: x[0])


def bank_scores(run_dir: Path, rule: tuple[float, float, int] | None, final: bool, embed: bool = True) -> dict:
    all_labels = {d["id"]: d for d in labels.load_all(labels.DIALOGUES_DIR)}
    score.COUNT_EMBED_HITS = embed
    scored, metas = [], {}
    for jl in sorted(run_dir.glob("*.jsonl")):
        if jl.stem not in all_labels:
            continue
        mf = run_dir / f"{jl.stem}.meta.json"
        meta = json.loads(mf.read_text()) if mf.exists() else None
        if meta:
            metas[jl.stem] = meta
        ev = score.load_events(jl)
        if rule is not None:
            ev = redecide(ev, *rule, final)
        scored.append(score.score_dialogue(all_labels[jl.stem], ev, meta))
    bank = score.aggregate(scored, metas)["bank"]
    vis = sorted(next(h["visible_s"] for h in r["bank_hits"] if h["bank_id"] == r["bank_id"])
                 for d in scored for r in d.get("rows", [])
                 if r["category"] == "paraphrase" and not r["warmup"] and r.get("bank_hits") and r["bank_hits"][-1]["bank_id"] == r["bank_id"])
    bank["paraphrase_visible"] = score.summarize(vis)
    return bank


def row(name: str, b: dict) -> str:
    g = report.bank_gate(b)
    p, e, v = b["by_category"]["paraphrase"], b["by_category"]["exact"], b["paraphrase_visible"]
    lat = f"{v['p50']:+.2f} / {v['p90']:+.2f} s" if v["n"] else "n/a"
    rate = "n/a" if g["wrong_rate_shown"] is None else f"{100 * g['wrong_rate_shown']:.1f} %"
    return (f"| {name} | {p['hit']}/{p['n']} | {e['hit']}/{e['n']} | {g['wrong_shown']}/{g['shown_hits']} = {rate} | "
            f"{b['wrong_hits_transient']} | {lat} | {g['status']} |")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", default="f3-embed")
    a = ap.parse_args()
    from paths import OUT
    run_dir = OUT / a.run
    cfg = Config()
    cur = (cfg.embed_threshold, cfg.embed_margin, cfg.embed_consecutive)
    has_embed = any('"stage":"embed"' in jl.read_text() or '"stage": "embed"' in jl.read_text() for jl in run_dir.glob("*.jsonl"))
    print(f"run {a.run}; current rule: threshold {cur[0]}, margin {cur[1]}, {cur[2]} in a row, final-text pass "
          f"{'on' if cfg.embed_final_pass else 'off'}")
    print("| decision | paraphrase hits | exact hits | wrong among shown | wrong at any moment | paraphrase card visible p50 / p90 (from acoustic end) | criterion 2 |")
    print("|---|---|---|---|---|---|---|")
    print(row("as recorded", bank_scores(run_dir, None, False)))
    print(row("n-gram hits only", bank_scores(run_dir, None, False, embed=False)))
    if not has_embed:
        print(f"\n{a.run} has no recorded embedding evaluations (recorded without the paraphrase matcher): nothing to re-decide.")
        return 0
    print(row(f"old rule {OLD_RULE}", bank_scores(run_dir, OLD_RULE, False)))
    print(row(f"old rule {OLD_RULE} + final pass*", bank_scores(run_dir, OLD_RULE, True)))
    print(row(f"current rule {cur}", bank_scores(run_dir, cur, False)))
    print(row(f"current rule {cur} + final pass*", bank_scores(run_dir, cur, cfg.embed_final_pass)))
    print("\n* final-text pass approximated by each hitless turn's last recorded evaluation (see the module docstring).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
