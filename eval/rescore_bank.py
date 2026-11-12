#!/usr/bin/env python3
"""Criterion 2 (bank hits) of a stored replay, re-decided under the brain's current embedding accept rule. Offline, no API.

    PYTHONPATH=../brain python rescore_bank.py --run f3-embed

The live brain records a `metric stage:"embed"` line for every partial its paraphrase matcher evaluated (top entry, its
cosine, the runner-up's). Those evaluations do not depend on the accept rule (the brain keeps evaluating after its own
hit; only a Swift n-gram hit stops it, and that is in the recording too), so the rule can be replayed on them exactly.
The recorded `bank_hit via:"embed"` lines are dropped, new ones are inserted, and score.py / report.py score the result
unchanged. Nothing is written.

The support and isolation gates (2026-11-12) need the top entry's second-best phrase and the 4th-best entry's score. Runs
recorded since then carry them on every `stage:"embed"` line (`support`, `isolation`). For older runs the recorded partial
texts are re-embedded with the real model against the session bank (sample-interview, or bench/embed/ml/en_bank.json when the
session folder is missing): the evaluated text is the turn's newest partial with the recorded word count at the metric's wall
time (the turn's text for a final-text evaluation). The agreement of the re-embedded top entry and cosine with the recorded
ones is printed; the re-embedded values are used for the gates only, the recorded top / score / second stay.

Approximations (printed with the result):
- the final-text pass (`embed_final_pass`) did not exist when f3-embed was recorded: a turn that ends with no hit is given
  one more evaluation equal to its last recorded one, placed 60 ms after the turn was sent. Runs recorded since then carry
  the pass's own evaluation (`final: true`), which is used instead (only when nothing was shown before it, as in the engine);
- the late-hit / newer-turn gates of the engine are not replayed.
A run recorded without the embedding path (live1: no `stage:"embed"` lines) cannot change: its paraphrase hits stay n-gram.
"""

from __future__ import annotations

import argparse
import functools
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(1, str(HERE.parent / "brain"))
import labels  # noqa: E402
import report  # noqa: E402
import score  # noqa: E402
from verse_brain.runtime.embed import AcceptRule, MatchState, step  # noqa: E402
from verse_brain.runtime.engine import tokens  # noqa: E402
from verse_brain.runtime.settings import Config  # noqa: E402

SESSION = Path("~/Library/Application Support/Verse/sessions/sample-interview").expanduser()
EN_BANK_COPY = HERE.parent / "bench" / "embed" / "ml" / "en_bank.json"

OLD_RULE = (0.865, 0.02, 2)          # before 2026-11-11
FINAL_PASS_DELAY_S = 0.06            # an embedding job on the GPU takes 20-60 ms (bench/embed/results/latency_runs.txt)


def decide(evals: list[dict], threshold: float, margin: float, consec: int, final: bool,
           fast: tuple[float, float, int] | None = None,
           gates: tuple[float | None, float | None, int] | None = None) -> list[tuple[int, str, float, bool]]:
    """evals: one turn's recorded evaluations in order. -> [(index into evals, bank_id, score, from_final_pass)].
    `fast` = (fast_threshold, fast_margin, fast_consecutive) or None; `gates` = (support, isolation, isolation_rank) or None,
    read against each evaluation's `support` / `isolation`. Decided by `embed.step`, the engine's function.

    A recorded final-text evaluation (`final: true`, runs recorded since the pass exists) is used as the final pass, and only
    when nothing was shown before it (the engine queues the pass only for a turn without a hit). Without one, and with
    `final`, the turn's last recorded evaluation stands in for it (older runs)."""
    sup, iso, rank = gates or (None, None, 3)
    rule = AcceptRule(threshold, margin, consec, *(fast or (None,)), support=sup, isolation=iso, isolation_rank=rank)
    recorded_final = any(o.get("final") is True for o in evals)
    st, out = MatchState(), []
    for j, o in enumerate(evals):
        top, s1, s2 = o.get("top"), float(o.get("score", -1.0)), float(o.get("second", -1.0))
        g = {"support": o.get("support"), "isolation": o.get("isolation")}
        if o.get("final") is True:
            if st.sent is None and final:
                hit = step(st, rule, top, s1, s2, final=True, **g)
                if hit is not None:
                    out.append((j, hit, s1, True))
            continue
        last = final and not recorded_final and j == len(evals) - 1 and st.sent is None
        hit = step(st, rule, top, s1, s2, final=last, **g)
        if hit is not None:
            partial = st.count >= rule.consecutive or (rule.fast_threshold is not None and st.fast >= rule.fast_consecutive)
            out.append((j, hit, s1, last and not partial))
    return out


def redecide(events: list[tuple[float, dict]], threshold: float, margin: float, consec: int, final: bool,
             fast: tuple[float, float, int] | None = None,
             gates: tuple[float | None, float | None, int] | None = None) -> list[tuple[float, dict]]:
    evals: dict[str, list[tuple[float, dict]]] = {}
    sent_at: dict[str, float] = {}
    for w, o in events:
        if o.get("type") == "metric" and o.get("stage") == "embed" and o.get("turn_id"):
            evals.setdefault(o["turn_id"], []).append((w, o))
        elif o.get("type") == "turn" and o.get("dir") == "to_brain":
            sent_at[o["turn_id"]] = w
    new = []
    for tid, ev in evals.items():
        for j, bid, s, from_final in decide([o for _, o in ev], threshold, margin, consec, final, fast, gates):
            w = ev[j][0]
            if from_final and tid in sent_at and ev[j][1].get("final") is not True:
                w = max(w, sent_at[tid] + FINAL_PASS_DELAY_S)
            new.append((w, {"type": "bank_hit", "turn_id": tid, "bank_id": bid, "score": round(s, 4), "via": "embed"}))
    kept = [(w, o) for w, o in events if not (o.get("type") == "bank_hit" and o.get("via") == "embed")]
    return sorted(kept + new, key=lambda x: x[0])


class Rescorer:
    """Re-embeds recorded partial texts (real model, offline) to fill `support` / `isolation` on runs recorded before the
    metric carried them. One engine and one index for the whole run; texts are cached."""

    def __init__(self) -> None:
        from verse_brain.runtime.embed import PREFIX, BankIndex, LiteRtEmbedder, unit
        self._prefix, self._unit = PREFIX, unit
        bank_file = SESSION / "bank.jsonl"
        if bank_file.exists():
            bank = {d["id"]: d for d in (json.loads(x) for x in bank_file.read_text(encoding="utf-8").splitlines() if x.strip())}
        else:
            bank = json.loads(EN_BANK_COPY.read_text(encoding="utf-8"))["bank"]
        self.emb = LiteRtEmbedder()
        self.index = BankIndex(self.emb, bank, "en")
        self.cache: dict[str, object] = {}
        self.n = self.agree = 0
        self.max_diff = 0.0

    def scores(self, text: str):
        if text not in self.cache:
            self.cache[text] = self.index.score(self._unit(self.emb.embed(self._prefix + text.strip())))
        return self.cache[text]

    def fill(self, events: list[tuple[float, dict]], rank: int) -> list[tuple[float, dict]]:
        partials: dict[str, list[str]] = {}
        turns: dict[str, str] = {}
        out = []
        for w, o in events:
            if o.get("type") == "partial" and o.get("dir") == "to_brain" and o.get("turn_id"):
                partials.setdefault(o["turn_id"], []).append(str(o.get("text", "")))
            elif o.get("type") == "turn" and o.get("dir") == "to_brain" and o.get("turn_id"):
                turns[o["turn_id"]] = str(o.get("text", ""))
            if o.get("type") == "metric" and o.get("stage") == "embed" and o.get("turn_id") and "support" not in o:
                tid, words = o["turn_id"], o.get("words")
                if o.get("final") is True:
                    text = turns.get(tid, "")
                else:
                    cands = partials.get(tid, [])
                    same = [t for t in cands if len(tokens(t)) == words]
                    text = (same or cands or [""])[-1]
                if text.strip():
                    sc = self.scores(text)
                    o = dict(o, support=sc.support, isolation=sc.isolation(rank))
                    self.n += 1
                    self.agree += sc.entries[0][0] == o.get("top")
                    self.max_diff = max(self.max_diff, abs(sc.entries[0][1] - float(o.get("score", 0.0))))
            out.append((w, o))
        return out

    def close(self) -> None:
        self.emb.close()


_RESCORER: Rescorer | None = None


def bank_scores(run_dir: Path, rule: tuple | None, final: bool, embed: bool = True, dialogues_dir: Path | None = None) -> dict:
    """rule: (threshold, margin, consecutive[, fast_threshold, fast_margin, fast_consecutive[, support, isolation,
    isolation_rank]]) or None (as recorded). With support or isolation on, evaluations recorded without them are re-embedded
    (Rescorer)."""
    global _RESCORER
    all_labels = {d["id"]: d for d in labels.load_all(dialogues_dir or labels.DIALOGUES_DIR)}
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
            gates = tuple(rule[6:9]) if len(rule) > 6 and (rule[6] is not None or rule[7] is not None) else None
            if gates is not None and any(o.get("type") == "metric" and o.get("stage") == "embed" and "support" not in o
                                         for _, o in ev):
                if _RESCORER is None:
                    _RESCORER = Rescorer()
                ev = _RESCORER.fill(ev, gates[2])
            ev = redecide(ev, *rule[:3], final, tuple(rule[3:6]) if len(rule) > 3 and rule[3] is not None else None, gates)
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
    ap.add_argument("--dialogues-dir", default=str(labels.DIALOGUES_DIR), help="label folder (eval/dialogues_it for the Italian set)")
    a = ap.parse_args()
    global bank_scores
    bank_scores = functools.partial(bank_scores, dialogues_dir=Path(a.dialogues_dir))
    from paths import OUT
    run_dir = OUT / a.run
    cfg = Config()
    r = cfg.embed_rule("en")
    base = (r.threshold, r.margin, r.consecutive)
    cur = base + ((r.fast_threshold, r.fast_margin, r.fast_consecutive) if r.fast_threshold is not None else ())
    has_embed = any('"stage":"embed"' in jl.read_text() or '"stage": "embed"' in jl.read_text() for jl in run_dir.glob("*.jsonl"))
    has_final = any(o.get("type") == "metric" and o.get("stage") == "embed" and o.get("final") is True
                    for jl in run_dir.glob("*.jsonl") for _, o in score.load_events(jl))
    print(f"run {a.run}; current rule (en): threshold {r.threshold}, margin {r.margin}, {r.consecutive} in a row; fast lane "
          f"{'off' if r.fast_threshold is None else f'{r.fast_consecutive} partial(s) at >= {r.fast_threshold} / margin {r.fast_margin}'}; "
          f"support >= {r.support}; isolation >= {r.isolation} (top-1 minus entry #{r.isolation_rank + 1}); "
          f"final-text pass {'on' if cfg.embed_final_pass else 'off'}")
    print("| decision | paraphrase hits | exact hits | wrong among shown | wrong at any moment | paraphrase card visible p50 / p90 (from acoustic end) | criterion 2 |")
    print("|---|---|---|---|---|---|---|")
    print(row("as recorded", bank_scores(run_dir, None, False)))
    print(row("n-gram hits only", bank_scores(run_dir, None, False, embed=False)))
    if not has_embed:
        print(f"\n{a.run} has no recorded embedding evaluations (recorded without the paraphrase matcher): nothing to re-decide.")
        return 0
    star = "" if has_final else "*"
    print(row(f"old rule {OLD_RULE}", bank_scores(run_dir, OLD_RULE, False)))
    print(row(f"old rule {OLD_RULE} + final pass{star}", bank_scores(run_dir, OLD_RULE, True)))
    print(row(f"base lane {base} (no support / isolation) + final pass{star}", bank_scores(run_dir, base, cfg.embed_final_pass)))
    before = (0.90, 0.005, 3, 0.93, 0.03, 1)
    print(row(f"0.90 rule {before} without support / isolation (before 2026-11-12) + final pass{star}",
              bank_scores(run_dir, before, cfg.embed_final_pass)))
    gated = cur + (None,) * (6 - len(cur)) + (r.support, r.isolation, r.isolation_rank)
    print(row(f"current rule {cur} + support {r.support} + isolation {r.isolation} + final pass{star}",
              bank_scores(run_dir, gated, cfg.embed_final_pass)))
    if _RESCORER is not None:
        print(f"\nsupport / isolation re-embedded for {_RESCORER.n} recorded evaluations (real model, offline): top entry agrees "
              f"on {_RESCORER.agree}/{_RESCORER.n}, max |cosine difference| {_RESCORER.max_diff:.4f}")
        _RESCORER.close()
    if not has_final:
        print("\n* final-text pass approximated by each hitless turn's last recorded evaluation (see the module docstring).")
    else:
        print("\nfinal-text pass: the recorded final evaluations are used; a turn hit on partials under one rule and not "
              "under another has no recorded final pass and is approximated by its last evaluation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
