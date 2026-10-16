#!/usr/bin/env python3
"""Tuning run for the follow-my-answer detector (brain/verse_brain/runtime/follow.py) on brain/tests/fixtures/follow/cases.json.

    PYTHONPATH=brain brain/.venv/bin/python eval/tune_follow.py [--out DIR]

Needs the EmbeddingGemma model (the one the bank matcher uses); without it only part 1 runs. Parts:

  1. lexical only (no embedder): false divergences on paraphrases for several count/time rules,
  2. the semantic evidence at every moment the lexical test is suspicious: best cosine to the card and the margin by which a
     line of the rest of the pack beats the card, swept over (floor, margin),
  3. the full machine with the defaults of FollowParams: divergence, detection time, words into the new topic,
  4. coverage of card points, swept over cover_score.

Streaming model: words at 2.7 per second, delivered in 560 ms chunks (the recognizer's chunk size). Times are measured from
the arrival of the first chunk that holds an off-card word.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from collections import defaultdict
from dataclasses import replace
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / "brain"))

from verse_brain.runtime.embed import DEFAULT_MODEL, PREFIX, LiteRtEmbedder  # noqa: E402
from verse_brain.runtime.follow import (Covered, Diverged, FollowMachine, FollowParams, NeedEmbed,  # noqa: E402
                                        score_matrix)
from verse_brain.runtime.follow_drive import Clock, chunks, content_count, simulate  # noqa: E402

CASES = ROOT / "brain/tests/fixtures/follow/cases.json"


def load() -> dict:
    return json.loads(CASES.read_text(encoding="utf-8"))


def first_off_t(c: dict) -> float:
    w0 = len(c["prefix"].split()) if "prefix" in c else 0
    return next((t for t, part in chunks(c["text"]) if len(part.split()) > w0), 0.0)


def pct(xs: list[float], q: float) -> float:
    xs = sorted(xs)
    return xs[max(0, min(len(xs) - 1, int(len(xs) * q + 0.5) - 1))] if xs else float("nan")


def probe(card: dict, text: str, emb, cache, pack, p: FollowParams) -> list[dict]:
    """At every chunk where the (embed-mode) lexical test is suspicious: best cosine of the unmatched run to the card and
    the margin of the best non-card pack line over it. Nothing is rescued or covered: pure measurement."""
    clock = Clock()
    m = FollowMachine(replace(p, sem_floor=-9.0, cover_score=9.0), clock, embed_ok=True)
    m.new_turn("q1")
    m.add_line("f1", "F", "say", card["say"])
    for pt in card["points"]:
        m.add_line("f1", "F", "point", pt)
    m.drain()
    rows = []
    for t, part in chunks(text):
        clock.t = t
        m.on_me("m1", part, False)
        m.drain()
        trig, n, run = m._lex_trigger()
        if not trig:
            continue
        lines = m.ref_lines()
        txt = m._stretch_text(run)[0]
        req = NeedEmbed(0, {"stretch": txt}, [(ln.card_id, ln.kind, ln.index, ln.text) for ln in lines])
        sc, oth = score_matrix(emb.embed, req, cache, PREFIX, pack)
        card_best = max(sc["stretch"])
        rows.append({"t": t, "unmatched": n, "run": len(run), "card": card_best, "margin": oth["stretch"] - card_best})
    return rows


def lex_first_trigger(card: dict, text: str, p: FollowParams) -> float | None:
    """When the lexical test alone (count N / run T of `p`) first fires on this answer; None if never."""
    clock = Clock()
    m = FollowMachine(p, clock, embed_ok=True)
    m.new_turn("q1")
    m.add_line("f1", "F", "say", card["say"])
    for pt in card["points"]:
        m.add_line("f1", "F", "point", pt)
    m.drain()
    for t, part in chunks(text):
        clock.t = t
        m.on_me("m1", part, False)
        m.drain()
        if m._lex_trigger()[0]:
            return t
    return None


def part1(ctx) -> None:
    cards, stay, div, p0 = ctx["cards"], ctx["stay"], ctx["div"], ctx["p0"]
    print("\n== 1. what the lexical test alone would do (count N unmatched in the last 8, or a run of T seconds, >= 3 words)."
          "\n      Shipped behaviour without the embedder: nothing diverges; this is why.")
    lex = []
    for N, T in ((5, 1.2), (7, 2.0), (9, 3.0), (11, 4.0), (13, 5.0)):
        p = replace(p0, diverge_words=N, diverge_s=T)
        fd = [c["id"] for c in stay if lex_first_trigger(cards[c["card"]], c["text"], p) is not None]
        det, miss = [], 0
        for c in div:
            t = lex_first_trigger(cards[c["card"]], c["text"], p)
            if t is None:
                miss += 1
            else:
                det.append(t - first_off_t(c))
        print(f"   N={N:2d} T={T}: would flip {len(fd):2d}/{len(stay)} on-card answers, miss {miss:2d}/{len(div)}, "
              f"detection median {statistics.median(det):.2f}s p90 {pct(det, 0.9):.2f}s")
        lex.append({"N": N, "T": T, "false": len(fd), "missed": miss, "det_median_s": round(statistics.median(det), 2)})
    ctx["out"]["lexical_only"] = lex


def part2(ctx) -> None:
    cards, cases, stay, div, p0, emb, cache, pack = (ctx[k] for k in ("cards", "cases", "stay", "div", "p0", "emb", "cache", "pack"))
    rows = {c["id"]: probe(cards[c["card"]], c["text"], emb, cache, pack, p0) for c in cases}
    print("\n== 2. semantic evidence at suspicious moments (lexical test: %d words / %.1f s, %d-word run)" %
          (p0.diverge_words, p0.diverge_s, p0.time_min_words))
    for exp in ("stay", "diverge"):
        for kind in sorted({c["kind"] for c in cases if c["expect"] == exp}):
            cs = [c for c in cases if c["kind"] == kind]
            cards_ = [r["card"] for c in cs for r in rows[c["id"]]]
            margins = [r["margin"] for c in cs for r in rows[c["id"]]]
            if cards_:
                print(f"   {exp:8s} {kind:14s} moments {len(cards_):3d}  card score p10 {pct(cards_, .1):.3f} med "
                      f"{statistics.median(cards_):.3f} p90 {pct(cards_, .9):.3f} | margin p10 {pct(margins, .1):.3f} "
                      f"med {statistics.median(margins):.3f} p90 {pct(margins, .9):.3f}")
    print("   stay cases that never raise suspicion:", sum(1 for c in stay if not rows[c["id"]]), "of", len(stay))
    print("\n   sweep: diverge at the first suspicious moment with card < floor or margin >= m")
    sweep = []
    for floor in (0.78, 0.80, 0.82, 0.84):
        for mg in (0.03, 0.04, 0.05, 0.06, 9.0):
            fd, miss, det = [], [], []
            for c in cases:
                hit = next((r for r in rows[c["id"]] if r["card"] < floor or r["margin"] >= mg), None)
                if c["expect"] == "stay":
                    if hit:
                        fd.append(c["id"])
                elif hit is None:
                    miss.append(c["id"])
                else:
                    det.append(hit["t"] - first_off_t(c))
            print(f"   floor {floor:.2f} margin {mg if mg < 9 else 'off':>4}: false {len(fd):2d}/{len(stay)}  missed {len(miss):2d}/{len(div)}  "
                  f"detection median {statistics.median(det):.2f}s p90 {pct(det, .9):.2f}s")
            sweep.append({"floor": floor, "margin": mg, "false": len(fd), "missed": len(miss),
                          "det_median_s": round(statistics.median(det), 2)})
    ctx["out"]["sweep"] = sweep


def part3(ctx) -> None:
    cards, cases, p0, emb, cache, pack = (ctx[k] for k in ("cards", "cases", "p0", "emb", "cache", "pack"))
    print("\n== 3. full machine: window %d, N %d, T %.1f s (>= %d words), floor %.2f, margin %.2f, mark %.2f, cover %.2f gap %.2f" %
          (p0.window, p0.diverge_words, p0.diverge_s, p0.time_min_words, p0.sem_floor, p0.sem_margin, p0.sem_mark,
           p0.cover_score, p0.cover_best_gap))
    res = []
    for c in cases:
        r = simulate(cards[c["card"]], c["text"], params=p0, embedder=emb, pack=pack, cache=cache)
        res.append((c, r, r.first(Diverged)))
    per_kind = defaultdict(lambda: [0, 0])
    per_card = defaultdict(lambda: [0, 0])
    det_rows = []
    for c, r, d in res:
        ok = (d is not None) == (c["expect"] == "diverge")
        for tab, key in ((per_kind, c["kind"]), (per_card, c["card"])):
            tab[key][0] += ok
            tab[key][1] += 1
        if not ok:
            print(f"     {'FALSE DIVERGENCE' if d else 'MISSED'}: {c['id']}: {c['text'][:90]}")
        if d is not None and c["expect"] == "diverge":
            w0 = len(c["prefix"].split()) if "prefix" in c else 0
            shown = max((len(part.split()) for tt, part in chunks(c["text"]) if tt <= d.t + 1e-6), default=0)
            det_rows.append({"id": c["id"], "ms": round((d.t - first_off_t(c)) * 1000),
                             "content_words": content_count(" ".join(c["text"].split()[w0:shown])),
                             "embed": d.fx.embed, "margin": d.fx.margin})
    print("   correct per kind:", {k: f"{v[0]}/{v[1]}" for k, v in sorted(per_kind.items())})
    print("   correct per card:", {k: f"{v[0]}/{v[1]}" for k, v in sorted(per_card.items())})
    ms = [x["ms"] for x in det_rows]
    cw = [x["content_words"] for x in det_rows]
    print(f"   detection (n={len(ms)}): ms median {statistics.median(ms):.0f} p90 {pct(ms, .9):.0f} max {max(ms)}; "
          f"content words into the new topic: median {statistics.median(cw):.0f} p90 {pct(cw, .9):.0f} max {max(cw)}")
    ctx["out"]["machine"] = {"per_kind": {k: v for k, v in per_kind.items()}, "detection": det_rows}


def part4(ctx) -> None:
    cards, cases, p0, emb, cache, pack = (ctx[k] for k in ("cards", "cases", "p0", "emb", "cache", "pack"))
    print("\n== 4. coverage of card points (labelled cases), best-line gap %.2f" % p0.cover_best_gap)
    cov_sweep = []
    for cs_ in (0.82, 0.84, 0.86, 0.88, 0.90, 9.0):
        tp = fp = fn = 0
        wrong = []
        for c in cases:
            want = c.get("covers")
            if want is None:
                continue
            r = simulate(cards[c["card"]], c["text"], params=replace(p0, cover_score=cs_), embedder=emb, pack=pack, cache=cache)
            got = {e.fx.point for e in r.of(Covered)}
            tp += len(got & set(want))
            fp += len(got - set(want))
            fn += len(set(want) - got)
            if got - set(want):
                wrong.append((c["id"], sorted(got - set(want))))
        print(f"   cover_score {cs_ if cs_ < 9 else 'lexical only'}: correct {tp}, wrong {fp}, missed {fn}" +
              (f"   wrong: {wrong[:5]}" if wrong else ""))
        cov_sweep.append({"cover_score": cs_, "correct": tp, "wrong": fp, "missed": fn})
    ctx["out"]["coverage"] = cov_sweep


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--parts", default="1,2,3,4")
    ap.add_argument("--set", action="append", default=[], help="FollowParams override, name=value (repeatable)")
    a = ap.parse_args()
    parts = set(a.parts.split(","))
    data = load()
    cases = data["cases"]
    p0 = FollowParams()
    for kv in a.set:
        k, v = kv.split("=")
        p0 = replace(p0, **{k: type(getattr(p0, k))(v)})
    ctx = {"cards": data["cards"], "cases": cases, "pack": data["pack"], "p0": p0, "out": {}, "cache": {},
           "stay": [c for c in cases if c["expect"] == "stay"], "div": [c for c in cases if c["expect"] == "diverge"]}
    print(f"{len(cases)} cases: {len(ctx['stay'])} stay (verbatim, ASR slips, paraphrase, fillers), {len(ctx['div'])} diverge "
          f"(off_pack, off_other, read_then_off)")
    if "1" in parts:
        part1(ctx)
    if parts & {"2", "3", "4"}:
        try:
            ctx["emb"] = LiteRtEmbedder(DEFAULT_MODEL, "gpu")
        except Exception as e:  # noqa: BLE001
            print("embedder unavailable:", e)
            return 0
        try:
            for name, fn in (("2", part2), ("3", part3), ("4", part4)):
                if name in parts:
                    fn(ctx)
        finally:
            ctx["emb"].close()
    if a.out:
        a.out.mkdir(parents=True, exist_ok=True)
        (a.out / "tune.json").write_text(json.dumps(ctx["out"], indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
