"""F3 analysis: score the blind set with (a) the n-gram matcher, (b) EmbeddingGemma cosine, (c) hybrids; tune the
accept rule for <= 5 % wrong hits on the tuning distractors; report hit rate, prefixes, lock-on, held-out check."""
from __future__ import annotations
import json, math, os, sys
import numpy as np
from common import HERE, bank_docs, NgramMatcher

R = os.path.join(HERE, "results")
EMB_TAG = sys.argv[1] if len(sys.argv) > 1 else "gpu_sym"
ids, docs, doc_entry = bank_docs()
E = len(ids)
idx = {e: i for i, e in enumerate(ids)}
qd = json.load(open(os.path.join(R, "queries.json")))
queries, items = qd["queries"], qd["items"]
NQ = len(queries)

# ---- (a) n-gram: Python port, checked against the real Swift matcher ----
ng = NgramMatcher(ids, docs, doc_entry)
S_ng = np.array([ng.entry_scores(q) for q in queries])
swift = [json.loads(l) for l in open(os.path.join(R, "ngram_swift.jsonl"))][1:]
assert [s["q"] for s in swift] == queries
maxdiff, id_mismatch = 0.0, 0
for qi, s in enumerate(swift):
    order = np.argsort(-S_ng[qi])[:2]
    for r, c in enumerate(s["top"]):
        maxdiff = max(maxdiff, abs(c["score"] - S_ng[qi][idx[c["id"]]]))
    if s["top"] and S_ng[qi][idx[s["top"][0]["id"]]] < S_ng[qi][order[0]] - 1e-5:
        id_mismatch += 1
parity = dict(queries=NQ, max_abs_score_diff_vs_swift=maxdiff, top1_mismatch=id_mismatch)
print("n-gram Python port vs Swift:", parity)

# ---- (b) EmbeddingGemma ----
z = np.load(os.path.join(R, f"emb_{EMB_TAG}.npz"))
Dm, Qm = z["D"], z["Q"]
cos = Qm @ Dm.T                           # NQ x docs
S_emb = np.full((NQ, E), -1.0, dtype=np.float32)
for d, e in enumerate(doc_entry):
    S_emb[:, e] = np.maximum(S_emb[:, e], cos[:, d])

# ---- (c) hybrids on background-normalised scores (background = mean score between phrases of DIFFERENT bank
# entries; computed from the bank only, never from the blind set) ----
def background(doc_scores_fn):
    vals = []
    for d in range(len(docs)):
        s = doc_scores_fn(d)
        for d2 in range(len(docs)):
            if doc_entry[d2] != doc_entry[d]:
                vals.append(s[d2])
    return float(np.mean(vals))
mu_ng = background(lambda d: ng.doc_scores(docs[d]))
mu_emb = float((Dm @ Dm.T)[np.array(doc_entry)[:, None] != np.array(doc_entry)[None, :]].mean())
norm = lambda S, mu: np.clip((S - mu) / (1 - mu), 0, 1)
N_ng, N_emb = norm(S_ng, mu_ng), norm(S_emb, mu_emb)
print(f"background mean score: n-gram {mu_ng:.3f}, embedding {mu_emb:.3f}")
METHODS = {
    "ngram (current)": S_ng,
    "embedding": S_emb,
    "hybrid max(norm)": np.maximum(N_ng, N_emb),
    "hybrid 0.5/0.5 (norm)": 0.5 * N_ng + 0.5 * N_emb,
    "hybrid 0.3 ng/0.7 emb (norm)": 0.3 * N_ng + 0.7 * N_emb,
}

# ---- decision rule ----
def top12(S):
    o = np.argsort(-S, axis=1)[:, :2]
    r = np.arange(S.shape[0])
    return o[:, 0], S[r, o[:, 0]], S[r, o[:, 1]]

kind = np.array([it["kind"] for it in items]); k_ = np.array([it["k"] for it in items]); n_ = np.array([it["n"] for it in items])
qi_ = np.array([it["qi"] for it in items]); tgt = np.array([idx[it["target"]] if it["target"] else -1 for it in items])
src = np.array([it["src"] for it in items])
full = k_ == n_

def accept(S, T, M):
    b, s1, s2 = top12(S)
    return (s1 >= T) & ((s1 - s2) >= M), b

def evaluate(S, T, M):
    acc, best = accept(S, T, M)
    a, b = acc[qi_], best[qi_]
    para = full & (kind == "para")
    hit = (a & (b == tgt))[para].sum(); wrong_id = (a & (b != tgt))[para].sum()
    dt = (a[full & (kind == "dist_tune")]).sum(); dh = (a[full & (kind == "dist_held")]).sum()
    return hit, wrong_id, dt, dh

def tune(S, max_wrong=1, both=False):
    best = None
    for T in np.arange(0.20, 1.0001, 0.005):
        for M in np.arange(0.0, 0.1501, 0.005):
            hit, wid, dt, dh = evaluate(S, T, M)
            if (dt + dh if both else dt) > max_wrong: continue
            key = (hit, -wid, T, M)
            if best is None or key > best[0]: best = (key, T, M)
    return best[1], best[2]

para_full = full & (kind == "para"); n_para = int(para_full.sum())
rows, summary = [], {"parity": parity, "background": {"ngram": mu_ng, "emb": mu_emb}, "emb_tag": EMB_TAG}
def pct_(x, n): return 100.0 * x / n
print(f"\npara n={n_para}, distractors tune n={int((full & (kind=='dist_tune')).sum())}, held-out n={int((full & (kind=='dist_held')).sum())}")
print("\n=== top-1 accuracy ignoring any threshold (ranking quality) ===")
for name, S in METHODS.items():
    b, _, _ = top12(S)
    acc = (b[qi_] == tgt)
    out = {}
    for lab, frac in (("50%", 0.5), ("75%", 0.75), ("100%", 1.0)):
        sel = (kind == "para") & (k_ == np.maximum(1, np.ceil(n_ * frac)).astype(int))
        out[lab] = pct_(acc[sel].sum(), sel.sum())
    print(f"{name:32s} 50%: {out['50%']:5.1f}   75%: {out['75%']:5.1f}   100%: {out['100%']:5.1f}")
    summary.setdefault("top1_no_threshold", {})[name] = out

print("\n=== tuned rule (max accepted-correct s.t. <= 1/20 wrong hits on tuning distractors) ===")
tuned = {}
for name, S in METHODS.items():
    T, M = tune(S)
    tuned[name] = (T, M)
for name in ("ngram (current)", "embedding", "hybrid max(norm)"):
    T, M = tune(METHODS[name], max_wrong=2, both=True)
    METHODS[name + " [tuned on all 40 dist, <=2]"] = METHODS[name]
    tuned[name + " [tuned on all 40 dist, <=2]"] = (T, M)
tuned["ngram @ product defaults 0.55/0.08"] = (0.55, 0.08)
METHODS["ngram @ product defaults 0.55/0.08"] = S_ng
hdr = f"{'method':36s} {'T':>6s} {'M':>6s} | {'hit%':>6s} {'wrongID%':>8s} {'miss%':>6s} | {'dist-tune%':>10s} {'dist-held%':>10s} | hit@50% hit@75% wrongID@50% wrongID@75%"
print(hdr)
for name, S in METHODS.items():
    T, M = tuned[name]
    hit, wid, dt, dh = evaluate(S, T, M)
    acc, best = accept(S, T, M)
    a, b = acc[qi_], best[qi_]
    pre = {}
    for lab, frac in (("50", 0.5), ("75", 0.75)):
        sel = (kind == "para") & (k_ == np.maximum(1, np.ceil(n_ * frac)).astype(int))
        pre[lab] = (pct_((a & (b == tgt))[sel].sum(), sel.sum()), pct_((a & (b != tgt))[sel].sum(), sel.sum()))
    # distractor prefixes (>= 3 words, strictly shorter than full) accepted at all
    dsel = ((kind == "dist_tune") | (kind == "dist_held")) & (k_ >= 3) & (k_ < n_)
    dpre = pct_(a[dsel].sum(), dsel.sum())
    # per-distractor: ever accepted at any prefix >= 3 words (incl. full)
    dsrc = sorted(set(src[(kind == "dist_tune") | (kind == "dist_held")]))
    ever = sum(1 for s_ in dsrc if a[(src == s_) & (k_ >= 3)].any())
    # lock-on per paraphrase: first prefix that is accepted+correct and stays accepted+correct on the next prefix
    lock_first, lock_stable, early_wrong, never = [], [], 0, 0
    lock3, early_wrong3, never3 = [], 0, 0
    for s_ in sorted(set(src[kind == "para"])):
        sel = np.where((src == s_))[0]; sel = sel[np.argsort(k_[sel])]
        ok = (a & (b == tgt))[sel]; wr = (a & (b != tgt))[sel]; n = n_[sel[0]]
        first = next((i for i in range(len(ok)) if ok[i]), None)
        stab = next((i for i in range(len(ok)) if ok[i] and (i == len(ok) - 1 or ok[i + 1])), None)
        if first is None: never += 1
        else:
            lock_first.append((first + 1) / n)
            if wr[:first].any(): early_wrong += 1
        if stab is not None: lock_stable.append((stab + 1) / n)
        k3 = [i for i in range(len(ok)) if i + 1 >= 3]
        f3 = next((i for i in k3 if ok[i]), None)
        if f3 is None: never3 += 1
        else:
            lock3.append((f3 + 1) / n)
            before = [i for i in k3 if i < f3]
            if before and wr[before].any(): early_wrong3 += 1
    npara = len(set(src[kind == "para"]))
    row = dict(method=name, T=round(float(T), 3), M=round(float(M), 3), hit=pct_(hit, n_para), wrong_id=pct_(wid, n_para), miss=pct_(n_para - hit - wid, n_para),
               dist_tune=pct_(dt, 20), dist_held=pct_(dh, 20), hit50=pre["50"][0], hit75=pre["75"][0], wid50=pre["50"][1], wid75=pre["75"][1],
               dist_prefix_accept=dpre, dist_ever_accepted_of_40=ever,
               lock_first_median=float(np.median(lock_first)) if lock_first else None, lock_first_mean=float(np.mean(lock_first)) if lock_first else None,
               lock_stable_median=float(np.median(lock_stable)) if lock_stable else None, never_locks=never, early_wrong_before_first_hit=early_wrong, lock3_median=float(np.median(lock3)) if lock3 else None, never3=never3, early_wrong3=early_wrong3)
    rows.append(row)
    print(f"{name:36s} {T:6.3f} {M:6.3f} | {row['hit']:6.1f} {row['wrong_id']:8.1f} {row['miss']:6.1f} | {row['dist_tune']:10.1f} {row['dist_held']:10.1f} | {row['hit50']:6.1f} {row['hit75']:6.1f} {row['wid50']:10.1f} {row['wid75']:10.1f}")
print("\n=== prefix wrong-accept on distractors and lock-on ===")
for r in rows:
    f = lambda x: "-" if x is None else f"{x*100:.0f}%"
    print(f"{r['method']:36s} distractor prefixes(>=3w, <full) accepted: {r['dist_prefix_accept']:5.1f}% | distractors ever accepted (of 40): {r['dist_ever_accepted_of_40']:2d} | lock-on first (median/mean): {f(r['lock_first_median'])}/{f(r['lock_first_mean'])}, stable median {f(r['lock_stable_median'])}, never {r['never_locks']}/60, wrong-before-hit {r['early_wrong_before_first_hit']} | ignoring prefixes <3 words: lock median {f(r['lock3_median'])}, never {r['never3']}/60, wrong-before-hit {r['early_wrong3']}")
def wilson(k, n, z=1.96):
    p = k / n; d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d; h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return 100 * (c - h), 100 * (c + h)
for r in rows:
    k = round(r["hit"] * n_para / 100); r["hit_ci95"] = wilson(k, n_para)
print("\n=== 95 % Wilson CI of hit rate (n=60) ===")
for r in rows: print(f"{r['method']:56s} {r['hit']:5.1f}%  [{r['hit_ci95'][0]:.0f}, {r['hit_ci95'][1]:.0f}]")
summary["rows"] = rows

# ---- per-entry failures of the embedding and n-gram at their tuned rules ----
print("\n=== paraphrases not hit (full text), by method ===")
fails = {}
for name in ("ngram (current)", "embedding", "hybrid 0.5/0.5 (norm)"):
    T, M = tuned[name]; S = METHODS[name]
    acc, best = accept(S, T, M)
    lst = []
    for i in np.where(para_full)[0]:
        q = qi_[i]
        if not (acc[q] and best[q] == tgt[i]):
            b, s1, s2 = top12(S[q:q+1])
            lst.append(f"{items[i]['src']} '{queries[q][:60]}' -> top {ids[b[0]]} {s1[0]:.3f} (2nd {s2[0]:.3f}) {'ACCEPTED-WRONG' if acc[q] else 'rejected'}")
    fails[name] = lst
    print(f"-- {name}: {len(lst)} not hit"); [print("   ", l) for l in lst]
summary["fails"] = fails

# ---- sensitivity: embedding wrong-hit vs T (no margin) ----
print("\n=== score distributions (full text, top-1 score) ===")
for name in ("ngram (current)", "embedding"):
    S = METHODS[name]; b, s1, s2 = top12(S)
    ok = (b[qi_] == tgt)
    sel_c = para_full & ok; sel_w = para_full & ~ok
    sel_d = full & ((kind == "dist_tune") | (kind == "dist_held"))
    f = lambda v: f"min {np.min(v):.3f} p10 {np.percentile(v,10):.3f} med {np.median(v):.3f} p90 {np.percentile(v,90):.3f} max {np.max(v):.3f}" if len(v) else "n/a"
    print(f"{name}: paraphrase correct top1 [{f(s1[qi_][sel_c])}]  paraphrase wrong top1 [{f(s1[qi_][sel_w])}]  distractors [{f(s1[qi_][sel_d])}]")
json.dump(summary, open(os.path.join(R, f"summary_{EMB_TAG}.json"), "w"), indent=1, default=float)
