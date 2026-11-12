#!/usr/bin/env python3
"""Accept-rule search for the paraphrase matcher (2026-11-12, near misses), with the real model. Offline, no API.

    cd bench/embed && ../../brain/.venv/bin/python rule_search.py [--cache DIR] [--part en,ml,latency]

Why: on ml/en_near.json (questions on a bank topic that ask something else) the 0.90 rule showed 7 wrong cards of 38 shown,
and no single cosine threshold separates them from paraphrases. This tool measures the alternatives and prints the tables
behind the rule in settings.py (embed_support / embed_isolation).

- `en`: the original English set (blind_set.json paraphrases, en_near.json, the 40 off-bank lines) is where rules are chosen;
  ml/en_heldout.json (written before it was scored) is the fresh held-out set. Every rule runs as the engine runs it: every
  word prefix from `embed_min_words` words on is one evaluated partial, then the final-text pass, decided by `embed.step`.
  Extra gates of the alternatives are applied on every evaluation, like the support and isolation gates.
- `ml`: Italian and Turkish (ml/it.json, ml/tr.json): two folds split by bank entry (odd / even id; near misses by the entry
  they resemble, off-bank lines alternately). A rule (threshold x support x isolation) is chosen on one fold and reported on
  the other.
- `latency`: the scoring cost per evaluation of the new gates (the embedding itself is unchanged).
"""

from __future__ import annotations

import argparse
import json

import os
import re
import statistics
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import ml_calib as mc  # noqa: E402
from verse_brain.runtime import own  # noqa: E402
from verse_brain.runtime.embed import (PREFIX, AcceptRule, BankIndex, LiteRtEmbedder, MatchState, entry_scores,  # noqa: E402
                                       step, unit)
from verse_brain.runtime.follow import STOP  # noqa: E402
from verse_brain.runtime.settings import Config  # noqa: E402

QA_QUERY = "task: question answering | query: "     # EmbeddingGemma's retrieval prompts (bench/embed mode `asym`)
QA_DOC = "title: none | text: "
QFRAME = set("tell talk walk describe explain share through us me give quick short briefly bit little can could would will "
             "do did does have has".split())      # question frame words, on top of follow.STOP
_W = re.compile(r"[\w'-]+")


# ---------------------------------------------------------------- vectors (sym prefix via ml_calib.Vectors; other prompts here)

class Prompted:
    def __init__(self, vec: mc.Vectors, cache_dir: Path | None) -> None:
        self.vec = vec
        self.file = cache_dir / "rule_search_vectors.json" if cache_dir else None
        self.v: dict[str, list[float]] = json.loads(self.file.read_text()) if self.file and self.file.exists() else {}

    def get(self, prefix: str, text: str) -> list[float]:
        key = prefix + text.strip()
        if key not in self.v:
            if self.vec._emb is None:
                self.vec._emb = LiteRtEmbedder()
            self.v[key] = unit(self.vec._emb.embed(key)) if text.strip() else [0.0] * 768
        return self.v[key]

    def save(self) -> None:
        if self.file:
            self.file.write_text(json.dumps(self.v))


def dot(a, b) -> float:
    return sum(x * y for x, y in zip(a, b))


# ---------------------------------------------------------------- English: features per evaluation

def content(text: str) -> set[str]:
    return set(own.content_stems(text, "en")) - {own._stem(w, "en") for w in QFRAME}


def content_only(text: str) -> str:
    drop = set(STOP) | QFRAME
    return " ".join(w for w in _W.findall(text.lower()) if w not in drop and w.split("'")[0] not in drop)


def ask_type(text: str) -> str:
    w = text.lower().replace("'", " ").split()
    for i, x in enumerate(w[:6]):
        if x == "how":
            nx = w[i + 1] if i + 1 < len(w) else ""
            return "howmuch" if nx in ("much", "many") else ("when" if nx in ("long", "soon", "quickly") else "how")
        if x in ("why", "when", "who", "where"):
            return x
        if x in ("what", "which", "whats"):
            return "what"
    return "other"


class EnModel:
    """The English bank, its phrase vectors and the views the alternatives need."""

    def __init__(self, vec: mc.Vectors, pv: Prompted) -> None:
        self.bank = mc.en_bank()
        self.ids = sorted(self.bank)
        self.phr = {k: [self.bank[k]["question"]] + self.bank[k]["paraphrases"]["en"] for k in self.ids}
        self.vec, self.pv = vec, pv
        self.index = [(k, vec.get(p)) for k in self.ids for p in self.phr[k]]
        self.doc_entry = [self.ids.index(k) for k, _ in self.index]
        ans = {k: [self.bank[k].get("opener", "")] + list(self.bank[k].get("points", [])) for k in self.ids}
        self.ans_sym = {k: [vec.get(a) for a in ans[k] if a.strip()] for k in self.ids}
        self.ans_qa = {k: [pv.get(QA_DOC, a) for a in ans[k] if a.strip()] for k in self.ids}
        self.q_qa = {k: [pv.get(QA_DOC, p) for p in self.phr[k]] for k in self.ids}
        self.q_co = {k: [pv.get(PREFIX, content_only(p)) for p in self.phr[k]] for k in self.ids}
        self.lex_phr = {k: set().union(*(content(p) for p in self.phr[k])) for k in self.ids}
        self.lex_all = {k: self.lex_phr[k] | set().union(*(content(a) for a in ans[k]))
                        | content(self.bank[k].get("deep", "")) for k in self.ids}
        self.asks = {k: {ask_type(p) for p in self.phr[k]} for k in self.ids}

    def _argmax(self, views: dict[str, list[list[float]]], q: list[float]) -> tuple[str, dict[str, float]]:
        s = {k: max((dot(q, d) for d in views[k]), default=-1.0) for k in self.ids}
        return max(s, key=s.get), s

    def evaluation(self, text: str) -> dict:
        q = self.vec.get(text)
        sc = entry_scores([dot(q, d) for _, d in self.index], self.doc_entry, self.ids)
        top = sc.entries[0][0]
        qq = content(text)
        a_top, _ = self._argmax(self.ans_sym, q)
        qa = self.pv.get(QA_QUERY, text)
        qa_top, qa_s = self._argmax(self.ans_qa, qa)
        qq_top, qq_s = self._argmax(self.q_qa, qa)
        co_top, _ = self._argmax(self.q_co, self.pv.get(PREFIX, content_only(text)))
        others = sorted((v for k, v in qq_s.items() if k != top), reverse=True)
        return {"ev": (top, sc.entries[0][1], sc.entries[1][1], sc.support, [s for _, s in sc.entries]),
                "shared": len(qq & self.lex_phr[top]), "uncovered": len(qq - self.lex_all[top]),
                "ask_ok": ask_type(text) in self.asks[top] or ask_type(text) == "other",
                "ans_agree": a_top == top, "qa_ans_agree": qa_top == top, "qa_ans": qa_s[top],
                "qa_q_margin": qq_s[top] - others[0], "co_agree": co_top == top}


def en_rows(m: EnModel, qs: dict, min_words: int) -> list[dict]:
    rows = []
    for it in mc.items(qs):
        it = dict(it)
        it["full"] = m.evaluation(it["text"])
        it["pre"] = [m.evaluation(p) for p in mc.prefixes(it["text"], min_words)]
        rows.append(it)
    return rows


def run(rows: list[dict], rule: AcceptRule, extra=None) -> dict:
    """Stream every query through embed.step with `extra(features) -> bool` as one more per-evaluation gate."""
    r = {"hits": 0, "n_para": 0, "wrong_entry": 0, "near": 0, "n_near": 0, "off": 0, "n_off": 0, "wrong": []}
    for it in rows:
        st, shown = MatchState(), []
        for f in it["pre"]:
            ev = f["ev"]
            ok = extra is None or extra(f)
            h = step(st, rule, ev[0] if ok else None, ev[1], ev[2], support=ev[3], isolation=mc.isolation(ev, rule.isolation_rank))
            if h:
                shown.append(h)
        if not shown:
            f = it["full"]
            ev = f["ev"]
            ok = extra is None or extra(f)
            h = step(st, rule, ev[0] if ok else None, ev[1], ev[2], final=True, support=ev[3],
                     isolation=mc.isolation(ev, rule.isolation_rank))
            if h:
                shown.append(h)
        cls = {"blind": "para", "asr": "para", "near": "near", "offbank": "off"}[it["cls"]]
        r["n_" + cls] += 1
        if not shown:
            continue
        if cls == "para":
            if all(h == it["target"] for h in shown):
                r["hits"] += 1
            else:
                r["wrong_entry"] += 1
                r["wrong"].append((it["text"], it["target"], shown))
        else:
            r[cls] += 1
            r["wrong"].append((it["text"], cls, shown))
    r["bad"] = r["wrong_entry"] + r["near"] + r["off"]
    r["shown"] = r["hits"] + r["bad"]
    return r


def cell(r: dict) -> str:
    return (f"{r['hits']}/{r['n_para']} | {r['wrong_entry']} | {r['near']}/{r['n_near']} | {r['off']}/{r['n_off']} | "
            f"{r['bad']}/{r['shown']}")


def part_en(vec: mc.Vectors, pv: Prompted, cfg: Config) -> None:
    m = EnModel(vec, pv)
    orig = en_rows(m, mc.en_queries(), cfg.embed_min_words)
    fresh = en_rows(m, mc.en_fresh_queries(), cfg.embed_min_words)
    chosen = cfg.embed_rule("en")
    before = AcceptRule(0.90, 0.005, 3, 0.93, 0.03, 1)
    g = dict(support=chosen.support, isolation=chosen.isolation, isolation_rank=chosen.isolation_rank)
    rules = [
        ("0.90 / 0.005 / 3 + fast 0.93 (before)", before, None),
        ("threshold 0.905", AcceptRule(0.905, 0.005, 3, 0.93, 0.03, 1), None),
        ("threshold 0.915", AcceptRule(0.915, 0.005, 3, 0.93, 0.03, 1), None),
        ("threshold 0.925", AcceptRule(0.925, 0.005, 3, 0.935, 0.03, 1), None),
        ("0.90 + support 0.855 only", AcceptRule(0.90, 0.005, 3, 0.93, 0.03, 1, support=0.855), None),
        ("0.90 + isolation 0.045 only", AcceptRule(0.90, 0.005, 3, 0.93, 0.03, 1, isolation=0.045), None),
        (f"CHOSEN {chosen.threshold} + support {chosen.support} + isolation {chosen.isolation}", chosen, None),
        ("chosen, fast lane off", AcceptRule(chosen.threshold, chosen.margin, chosen.consecutive, None, **g), None),
        ("chosen, threshold 0.89 (best on this set; adds 2 wrong cards on the stored replay f3-embed)",
         AcceptRule(0.89, 0.005, 3, 0.93, 0.03, 1, **g), None),
        ("chosen, support 0.87", AcceptRule(chosen.threshold, 0.005, 3, 0.93, 0.03, 1, support=0.87, isolation=chosen.isolation),
         None),
    ]
    alts = [
        ("lexical: >= 1 content word shared with the entry's phrases", lambda f: f["shared"] >= 1),
        ("lexical: <= 2 content words the entry (phrases, answer) lacks, or top-1 >= 0.92",
         lambda f: f["uncovered"] <= 2 or f["ev"][1] >= 0.92),
        ("ask type (what/why/how/how much/when/who) agrees", lambda f: f["ask_ok"]),
        ("answer points (same prefix) rank the same entry first", lambda f: f["ans_agree"]),
        ("QA prefix: answer points rank the same entry first", lambda f: f["qa_ans_agree"]),
        ("QA prefix: answer points cosine >= 0.72", lambda f: f["qa_ans"] >= 0.72),
        ("QA prefix query vs the entry's questions: margin >= 0.03", lambda f: f["qa_q_margin"] >= 0.03),
        ("content words only (function words dropped): same entry first", lambda f: f["co_agree"]),
    ]
    head = ("| rule | original: hits | wrong entry | near | off-bank | wrong/shown | fresh: hits | wrong entry | near | "
            "off-bank | wrong/shown |\n|---|---|---|---|---|---|---|---|---|---|---|")
    print("\n## English: original set (rules chosen here) and fresh held-out set\n")
    print(head)
    for name, rule, extra in rules:
        print(f"| {name} | {cell(run(orig, rule, extra))} | {cell(run(fresh, rule, extra))} |")
    print("\n## English: alternatives as one more gate (on the 0.90 rule / on the chosen rule)\n")
    print(head)
    for name, extra in alts:
        print(f"| 0.90 rule + {name} | {cell(run(orig, before, extra))} | {cell(run(fresh, before, extra))} |")
        print(f"| chosen + {name} | {cell(run(orig, chosen, extra))} | {cell(run(fresh, chosen, extra))} |")
    for label, rows in (("original", orig), ("fresh", fresh)):
        print(f"\nwrong cards of the chosen rule, {label} set:")
        for w in run(rows, chosen)["wrong"]:
            print("  ", w)


# ---------------------------------------------------------------- Italian / Turkish: two folds by entry

def fold_of(it: dict, k: int) -> int:
    eid = it.get("target") or it.get("near")
    return int(eid[1:]) % 2 if eid else k % 2


def ml_line(res: dict) -> str:
    b, a = res["blind"], res["asr"]
    shown = b[0] + b[1] + a[0] + a[1] + res["near_hits"] + res["off_hits"]
    wrong = b[1] + a[1] + res["near_hits"] + res["off_hits"]
    return (f"{b[0]}/{b[2]} + {a[0]}/{a[2]} | {b[1] + a[1]} | {res['near_hits']}/{res['n_near']} | {res['off_hits']}/{res['n_off']} | "
            f"{wrong}/{shown}")


def ml_score(res: dict) -> tuple[int, int, int]:
    b, a = res["blind"], res["asr"]
    shown = b[0] + b[1] + a[0] + a[1] + res["near_hits"] + res["off_hits"]
    return b[0] + a[0], b[1] + a[1] + res["near_hits"] + res["off_hits"], shown


def part_ml(vec: mc.Vectors, cfg: Config) -> None:
    allc = mc.configs()
    grid = [AcceptRule(th / 1000, 0.005, 3, 0.93 if th < 930 else None, 0.03, 1, support=sp, isolation=iso)
            for th in range(870, 951, 5) for sp in (None, 0.85, 0.855, 0.86, 0.87, 0.88)
            for iso in (None, 0.03, 0.045, 0.06, 0.07, 0.08)]
    en_rule = cfg.embed_rule("en")
    print("\n## Italian / Turkish: rule chosen on one fold (max hits with at most 1 wrong card), reported on the other\n")
    print("| config | fold chosen on | rule | chosen fold: hits (blind + asr) | wrong entry | near | off-bank | wrong/shown | "
          "held-out fold: hits | wrong entry | near | off-bank | wrong/shown |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for name in ("it", "tr"):
        phr, qs = allc[name]
        rows = mc.evaluate(name, phr, qs, vec, cfg.embed_min_words)
        folds = [[r for k, r in enumerate(rows) if fold_of(r, k) == f] for f in (0, 1)]
        for f in (0, 1):
            tr, te = folds[f], folds[1 - f]
            best = None
            for rule in grid:
                hits, bad, _ = ml_score(mc.simulate(tr, rule))
                if bad <= 1 and (best is None or (hits, -bad) > best[:2]):
                    best = (hits, -bad, rule)
            rule = best[2]
            desc = (f"{rule.threshold:.3f} / support {rule.support} / isolation {rule.isolation} / fast "
                    f"{'off' if rule.fast_threshold is None else rule.fast_threshold}")
            print(f"| {name} | {'even' if f == 0 else 'odd'} ids | {desc} | {ml_line(mc.simulate(tr, rule))} | "
                  f"{ml_line(mc.simulate(te, rule))} |")
        print(f"| {name} | (English rule as is) | {en_rule.threshold} / support {en_rule.support} / isolation {en_rule.isolation} | "
              f"{ml_line(mc.simulate(rows, en_rule))} | | | | | |")
        print(f"| {name} | (before, 0.90 no gates) | 0.90 / - / - | {ml_line(mc.simulate(rows, AcceptRule(0.90, 0.005, 3, 0.93, 0.03, 1)))} "
              f"| | | | | |")
    # The Italian candidate fixed from the two folds above (both chose isolation 0.06 alone; the threshold is not binding there:
    # 0.87-0.89 give the same result, 0.89 was written down), then scored once on the fresh Italian set, written before it was
    # scored. Its 8 near-miss cards there are why Italian stays off (settings.embed_langs).
    it_rule = AcceptRule(0.89, 0.005, 3, 0.93, 0.03, 1, support=None, isolation=0.06)
    print("\n## Italian fresh held-out set (ml/it_heldout.json)\n")
    print("| rule | hits | wrong entry | near | off-bank | wrong/shown |\n|---|---|---|---|---|---|")
    phr, qs = allc["it-fresh"]
    rows = mc.evaluate("it-fresh", phr, qs, vec, cfg.embed_min_words)
    for label, rule in (("Italian candidate 0.89 / isolation 0.06", it_rule), ("English rule as is", en_rule),
                        ("before, 0.90 no gates", AcceptRule(0.90, 0.005, 3, 0.93, 0.03, 1))):
        res = mc.simulate(rows, rule)
        print(f"| {label} | {ml_line(res)} |")
        if rule is it_rule:
            for w in res["wrong_ids"]:
                print("   wrong:", w)


# ---------------------------------------------------------------- latency of the scoring step

def part_latency() -> None:
    import random
    rnd = random.Random(7)

    def rv():
        return unit([rnd.gauss(0, 1) for _ in range(768)])

    class E:
        def embed(self, text):
            return rv()

        def close(self):
            pass

    bank = {f"b{i:03d}": {"question": f"q{i}", "paraphrases": {"en": [f"p{i}a", f"p{i}b", f"p{i}c"]}} for i in range(22)}
    idx = BankIndex(E(), bank, "en")
    qs = [rv() for _ in range(200)]
    from operator import mul

    def old_top2(qv):                       # the scoring before 2026-11-12 (best phrase per entry, top 2)
        best = [-1.0] * len(idx.ids)
        for di, dv in enumerate(idx.vecs):
            s = sum(map(mul, qv, dv))
            e = idx.doc_entry[di]
            if s > best[e]:
                best[e] = s
        order = sorted(range(len(best)), key=lambda i: best[i], reverse=True)[:2]
        return [(idx.ids[i], best[i]) for i in order]

    rule = Config().embed_rule("en")
    for name, fn in (("before: top-2 only", old_top2),
                     ("now: Scores + gates", lambda q: (lambda s: step(MatchState(), rule, s.entries[0][0], s.entries[0][1],
                                                                       s.entries[1][1], support=s.support,
                                                                       isolation=s.isolation(3)))(idx.score(q)))):
        for q in qs[:20]:
            fn(q)
        t = []
        for q in qs:
            t0 = time.perf_counter()
            fn(q)
            t.append((time.perf_counter() - t0) * 1000)
        print(f"{name}: 22 entries x 4 phrases, 768-d, pure Python: p50 {statistics.median(t):.3f} ms, "
              f"p90 {sorted(t)[int(0.9 * len(t))]:.3f} ms")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default=os.environ.get("ML_CALIB_CACHE"), help="folder for the vector caches (default: none)")
    ap.add_argument("--part", default="en,ml,latency")
    a = ap.parse_args()
    cfg = Config()
    cache = Path(a.cache) if a.cache else None
    vec = mc.Vectors(cache)
    pv = Prompted(vec, cache)
    parts = a.part.split(",")
    try:
        if "en" in parts:
            part_en(vec, pv, cfg)
        if "ml" in parts:
            part_ml(vec, cfg)
    finally:
        pv.save()
        vec.save()
    if "latency" in parts:
        print("\n## Scoring cost per evaluation (the embedding, 20-60 ms on the GPU, is unchanged)\n")
        part_latency()
    return 0


if __name__ == "__main__":
    sys.exit(main())
