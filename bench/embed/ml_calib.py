#!/usr/bin/env python3
"""Calibration of the paraphrase matcher for Italian and Turkish (and the English reference), with the real model.

    cd bench/embed && ../../brain/.venv/bin/python ml_calib.py [--cache DIR] [--grid] [--configs it,tr]

Data (written before any score was computed): ml/it.json, ml/tr.json (bank, blind paraphrases, recognizer-style
paraphrases, near misses, off-bank questions and statements), ml/en_near.json; the English side is blind_set.json and the
sample-interview bank. Configurations (each one bank index as the brain builds it, `embed.bank_phrases(rec, lang)`):

  en         English entries + English paraphrases, English queries (the reference the 0.90 rule was tuned on)
  it, tr     entries written in it/tr + it/tr paraphrases, it/tr queries
  it-mixed   English entries + Italian paraphrases (an English question in the bank of an Italian meeting), it queries
  tr-mixed   the same for Turkish
  en-rev-it  Italian entries + English paraphrases (an Italian question in the bank, the meeting language is English), en queries
  en-rev-tr  the same with Turkish entries

For every query: the full-text top-1/top-2, and a streamed replay (every word prefix from `embed_min_words` words on is one
evaluated partial, then the final-text pass) decided by `embed.step`, the function the engine uses. Every-word prefixes are
conservative for wrong hits: the live recognizer delivers a partial every ~0.56 s (1-3 words), so fewer chances to chain.
Nothing here calls an API.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(REPO / "brain"))
from verse_brain.runtime.embed import PREFIX, AcceptRule, LiteRtEmbedder, MatchState, step, unit  # noqa: E402
from verse_brain.runtime.engine import tokens  # noqa: E402
from verse_brain.runtime.settings import Config  # noqa: E402

SESSIONS = [Path("~/Library/Application Support/Verse/sessions/sample-interview").expanduser(),
            Path("~/RESTORE_STAGING/Users/fethiomur/Library/Application Support/Verse/sessions/sample-interview").expanduser()]


def en_bank() -> dict[str, dict]:
    for s in SESSIONS:
        f = s / "bank.jsonl"
        if f.exists():
            return {d["id"]: d for d in (json.loads(x) for x in f.read_text(encoding="utf-8").splitlines() if x.strip())}
    sys.exit("sample-interview bank.jsonl not found in " + ", ".join(map(str, SESSIONS)))


def load(name: str) -> dict:
    return json.loads((HERE / "ml" / name).read_text(encoding="utf-8"))


# ---------------------------------------------------------------- data sets

def en_queries() -> dict:
    blind = json.loads((HERE / "blind_set.json").read_text(encoding="utf-8"))
    near = load("en_near.json")["near"]
    return {"blind": blind["paraphrases"], "asr": {}, "near": near,
            "offbank": blind["distractors_tune"] + blind["distractors_heldout"]}


def configs() -> dict[str, tuple[dict[str, list[str]], dict]]:
    """name -> (entry id -> index phrases, queries)."""
    en = en_bank()
    out = {"en": ({k: [r["question"]] + r["paraphrases"]["en"] for k, r in en.items()}, en_queries())}
    for lg in ("it", "tr"):
        d = load(f"{lg}.json")
        q = {"blind": d["blind"], "asr": d["asr"], "near": d["near"], "offbank": d["offbank"]}
        out[lg] = ({k: [r["question"]] + r["paraphrases"] for k, r in d["bank"].items()}, q)
        out[f"{lg}-mixed"] = ({k: [en[k]["question"]] + d["bank"][k]["paraphrases"] for k in d["bank"]}, q)
        out[f"en-rev-{lg}"] = ({k: [d["bank"][k]["question"]] + en[k]["paraphrases"]["en"] for k in d["bank"]}, en_queries())
    return out


def items(q: dict) -> list[dict]:
    """Every query sentence with its class and target."""
    out = []
    for cls in ("blind", "asr"):
        for eid, ss in sorted(q[cls].items()):
            for s in ss:
                out.append({"cls": cls, "target": eid, "text": s})
    for n in q["near"]:
        out.append({"cls": "near", "target": None, "near": n["near"], "text": n["text"]})
    for s in q["offbank"]:
        out.append({"cls": "offbank", "target": None, "text": s})
    return out


def prefixes(text: str, min_words: int) -> list[str]:
    w = text.split()
    return [" ".join(w[:k]) for k in range(1, len(w) + 1) if len(tokens(" ".join(w[:k]))) >= min_words]


# ---------------------------------------------------------------- embedding

class Vectors:
    def __init__(self, cache_dir: Path | None) -> None:
        self.cache_file = cache_dir / "ml_vectors.json" if cache_dir else None
        self.v: dict[str, list[float]] = {}
        if self.cache_file and self.cache_file.exists():
            self.v = json.loads(self.cache_file.read_text())
        self._emb = None

    def get(self, text: str) -> list[float]:
        t = text.strip()
        if t not in self.v:
            if self._emb is None:
                self._emb = LiteRtEmbedder()
            self.v[t] = unit(self._emb.embed(PREFIX + t))
        return self.v[t]

    def save(self) -> None:
        if self.cache_file:
            self.cache_file.parent.mkdir(parents=True, exist_ok=True)
            self.cache_file.write_text(json.dumps(self.v))
        if self._emb is not None:
            self._emb.close()


def top2(vec: list[float], index: list[tuple[str, list[float]]]) -> tuple[str, float, float]:
    best: dict[str, float] = {}
    for eid, dv in index:
        s = sum(a * b for a, b in zip(vec, dv))
        if s > best.get(eid, -1.0):
            best[eid] = s
    order = sorted(best.items(), key=lambda kv: kv[1], reverse=True)
    return order[0][0], order[0][1], order[1][1]


# ---------------------------------------------------------------- scoring

def q(vals: list[float], p: float) -> float | None:
    if not vals:
        return None
    s = sorted(vals)
    return s[min(len(s) - 1, max(0, math.ceil(p * len(s)) - 1))]


def dist(vals: list[float]) -> str:
    if not vals:
        return "n=0"
    return f"n={len(vals)} p10/p50/p90/max {q(vals, .1):.3f}/{q(vals, .5):.3f}/{q(vals, .9):.3f}/{max(vals):.3f}"


def evaluate(cfg_name: str, phr: dict[str, list[str]], qs: dict, vec: Vectors, min_words: int) -> list[dict]:
    index = [(eid, vec.get(p)) for eid, ps in sorted(phr.items()) for p in ps if p.strip()]
    out = []
    for it in items(qs):
        full = top2(vec.get(it["text"]), index)
        pre = [top2(vec.get(p), index) for p in prefixes(it["text"], min_words)]
        out.append({**it, "full": full, "pre": pre, "n_words": len(it["text"].split())})
    return out


def simulate(rows: list[dict], rule: AcceptRule, every: int = 1) -> dict:
    """Stream each query through `step`: prefixes (every `every`-th, always the last), then the final text."""
    res = {"blind": [0, 0, 0], "asr": [0, 0, 0], "near_hits": 0, "off_hits": 0, "wrong_ids": [], "on_partial": 0,
           "words_left": [], "n_near": 0, "n_off": 0}
    for r in rows:
        st = MatchState()
        pre = r["pre"]
        idx = [i for i in range(len(pre)) if (len(pre) - 1 - i) % every == 0]
        shown = []
        for i in idx:
            top, s1, s2 = pre[i]
            hit = step(st, rule, top, s1, s2)
            if hit:
                shown.append((hit, len(pre) - 1 - i, False))
        if not shown:
            top, s1, s2 = r["full"]
            hit = step(st, rule, top, s1, s2, final=True)
            if hit:
                shown.append((hit, 0, True))
        if r["cls"] in ("blind", "asr"):
            c = res[r["cls"]]
            c[2] += 1
            if shown:
                if shown[-1][0] == r["target"] and all(h[0] == r["target"] for h in shown):
                    c[0] += 1
                    if not shown[0][2]:
                        res["on_partial"] += 1
                        res["words_left"].append(shown[0][1])
                    else:
                        res["words_left"].append(-1)
                else:
                    c[1] += 1
                    res["wrong_ids"].append((r["text"][:50], r["target"], [h[0] for h in shown]))
        elif r["cls"] == "near":
            res["n_near"] += 1
            if shown:
                res["near_hits"] += 1
                res["wrong_ids"].append((r["text"][:50], "near", [h[0] for h in shown]))
        else:
            res["n_off"] += 1
            if shown:
                res["off_hits"] += 1
                res["wrong_ids"].append((r["text"][:50], "off", [h[0] for h in shown]))
    return res


def describe(name: str, rows: list[dict]) -> None:
    def cl(c):
        return [r for r in rows if r["cls"] == c]
    right = [r["full"][1] for r in rows if r["cls"] == "blind" and r["full"][0] == r["target"]]
    wrong = [r["full"][1] for r in rows if r["cls"] == "blind" and r["full"][0] != r["target"]]
    aright = [r["full"][1] for r in rows if r["cls"] == "asr" and r["full"][0] == r["target"]]
    awrong = [r["full"][1] for r in rows if r["cls"] == "asr" and r["full"][0] != r["target"]]
    near = [r["full"][1] for r in cl("near")]
    off = [r["full"][1] for r in cl("offbank")]
    near_pre = [max([p[1] for p in r["pre"]] + [r["full"][1]]) for r in cl("near")]
    off_pre = [max([p[1] for p in r["pre"]] + [r["full"][1]]) for r in cl("offbank")]
    mr = [r["full"][1] - r["full"][2] for r in rows if r["cls"] in ("blind", "asr") and r["full"][0] == r["target"]]
    mw = [r["full"][1] - r["full"][2] for r in rows if r["cls"] in ("near", "offbank") or (r["cls"] in ("blind", "asr") and r["full"][0] != r["target"])]
    print(f"\n## {name}  (full text, top-1 cosine)")
    print(f"  blind paraphrase, right entry   {dist(right)}")
    print(f"  blind paraphrase, wrong entry   {dist(wrong)}")
    print(f"  recognizer-style, right entry   {dist(aright)}")
    print(f"  recognizer-style, wrong entry   {dist(awrong)}")
    print(f"  near miss                       {dist(near)}")
    print(f"  off-bank                        {dist(off)}")
    print(f"  near miss, max over prefixes    {dist(near_pre)}")
    print(f"  off-bank, max over prefixes     {dist(off_pre)}")
    print(f"  margin, right top-1             {dist(mr)}")
    print(f"  margin, wrong/near/off top-1    {dist(mw)}")


def line(name: str, res: dict) -> str:
    b, a = res["blind"], res["asr"]
    shown = b[0] + b[1] + a[0] + a[1] + res["near_hits"] + res["off_hits"]
    wrong = b[1] + a[1] + res["near_hits"] + res["off_hits"]
    wl = [w for w in res["words_left"] if w >= 0]
    return (f"| {name} | {b[0]}/{b[2]} | {a[0]}/{a[2] if a[2] else '-'} | {b[1] + a[1]} | {res['near_hits']}/{res['n_near']} | "
            f"{res['off_hits']}/{res['n_off']} | {wrong}/{shown} | {res['on_partial']} | "
            f"{(statistics.median(wl) if wl else '-')} |")


HEAD = ("| rule | blind hits | asr hits | para wrong id | near hits | off-bank hits | wrong/shown | hits on a partial | "
        "median words left at a partial hit |\n|---|---|---|---|---|---|---|---|---|")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default=os.environ.get("ML_CALIB_CACHE"), help="folder for the vector cache (default: none)")
    ap.add_argument("--configs", default="en,it,it-mixed,en-rev-it,tr,tr-mixed,en-rev-tr")
    ap.add_argument("--grid", action="store_true", help="threshold grid (base lane, 3 in a row + final pass)")
    ap.add_argument("--every", type=int, default=1)
    ap.add_argument("--dump", help="write per-query rows (json) here")
    a = ap.parse_args()
    cfg = Config()
    vec = Vectors(Path(a.cache) if a.cache else None)
    allc = configs()
    dump = {}
    try:
        for name in a.configs.split(","):
            phr, qs = allc[name]
            rows = evaluate(name, phr, qs, vec, cfg.embed_min_words)
            dump[name] = rows
            describe(name, rows)
            lang = name.split("-")[0] if not name.startswith("en-rev") else "en"
            print("\n" + HEAD)
            cur = cfg.embed_rule(lang if lang in cfg.embed_langs else "en")
            print(line(f"configured rule for {lang} {cur}", simulate(rows, cur, a.every)))
            if a.grid:
                for th in [x / 1000 for x in range(870, 961, 5)]:
                    for m in (0.005, 0.02):
                        print(line(f"{th:.3f} / {m} / 3", simulate(rows, AcceptRule(th, m, 3), a.every)))
            res = simulate(rows, cur, a.every)
            for w in res["wrong_ids"]:
                print("   wrong:", w)
    finally:
        vec.save()
    if a.dump:
        Path(a.dump).write_text(json.dumps(dump))
    return 0


if __name__ == "__main__":
    sys.exit(main())
