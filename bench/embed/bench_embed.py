"""F3: embed every bank phrase and every blind-set query with EmbeddingGemma 2 (text 270M, LiteRT-LM), time it,
and save the vectors for analyze.py.

usage: python bench_embed.py --backend gpu|cpu --mode sym|asym [--threads N]
"""
from __future__ import annotations
import argparse, json, os, resource, statistics, time
import numpy as np
import litert_lm
from common import HERE, bank_docs

MODEL = os.path.expanduser("~/Library/Application Support/Verse/models/embeddinggemma-2-text-270m-litert/embeddinggemma-2-text-270m.litertlm")
PREFIX = {
    "sym": ("task: sentence similarity | text: ", "task: sentence similarity | text: "),   # (query, doc)
    "asym": ("task: search query | text: ", "task: search result | text: "),
}


def rss_mb():
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6   # bytes on macOS


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round((len(xs) - 1) * p)))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", default="gpu")
    ap.add_argument("--mode", default="sym")
    ap.add_argument("--threads", type=int, default=None)
    a = ap.parse_args()
    litert_lm.set_min_log_severity(litert_lm.LogSeverity.ERROR)
    qpre, dpre = PREFIX[a.mode]
    queries = json.load(open(os.path.join(HERE, "results", "queries.json")))["queries"]
    ids, docs, doc_entry = bank_docs()
    perf = {"backend": a.backend, "mode": a.mode, "threads": a.threads}
    perf["rss_mb_before_load"] = rss_mb()
    be = litert_lm.Backend.GPU() if a.backend == "gpu" else litert_lm.Backend.CPU(thread_count=a.threads) if a.threads else litert_lm.Backend.CPU()
    cache = os.path.join(os.path.dirname(MODEL), "cache")
    t0 = time.perf_counter()
    eng = litert_lm.EmbeddingEngine(MODEL, backend=be, cache_dir=cache)
    perf["load_s"] = time.perf_counter() - t0
    with eng:
        emb = lambda s: np.asarray(eng.compute_embedding(s).embedding, dtype=np.float32)
        t0 = time.perf_counter(); emb(qpre + "warm up"); perf["first_embed_ms"] = (time.perf_counter() - t0) * 1000
        for _ in range(5): emb(qpre + "warm up the engine again")
        perf["rss_mb_after_load"] = rss_mb()

        # per-bank indexing time: 88 phrases one by one (what the app would do at session start) and as one batch call
        t0 = time.perf_counter()
        D = np.stack([emb(dpre + d.strip()) for d in docs])
        perf["index_seq_s"] = time.perf_counter() - t0
        perf["index_docs"] = len(docs)
        try:
            t0 = time.perf_counter()
            Db = np.stack([np.asarray(r.embedding, dtype=np.float32) for r in eng.compute_embedding_batch([dpre + d.strip() for d in docs])])
            perf["index_batch_s"] = time.perf_counter() - t0
            perf["batch_vs_seq_max_abs_diff"] = float(np.abs(Db - D).max())
        except Exception as ex:
            perf["index_batch_error"] = repr(ex)
        D /= np.linalg.norm(D, axis=1, keepdims=True)
        doc_entry_a = np.asarray(doc_entry)
        n_entries = len(ids)

        def match(q):
            v = emb(qpre + q.strip()); v /= np.linalg.norm(v)
            s = D @ v
            es = np.full(n_entries, -1.0, dtype=np.float32)
            np.maximum.at(es, doc_entry_a, s)
            top = np.argpartition(-es, 2)[:2]
            top = top[np.argsort(-es[top])]
            return top, es

        # end-to-end per-query match latency on the full-text queries (embed + cosine over the bank + top-2), 3 reps each
        blind = json.load(open(os.path.join(HERE, "blind_set.json")))
        full = [s for v in blind["paraphrases"].values() for s in v] + blind["distractors_tune"] + blind["distractors_heldout"]
        lat = []
        for _ in range(3):
            for q in full:
                t0 = time.perf_counter(); match(q); lat.append((time.perf_counter() - t0) * 1000)
        perf["latency_n"] = len(lat)
        perf["latency_ms"] = {"p50": pct(lat, 0.5), "p90": pct(lat, 0.9), "p99": pct(lat, 0.99), "max": max(lat), "mean": statistics.fmean(lat)}
        # embed-only latency (no numpy), for reference
        lat2 = []
        for q in full[:40]:
            t0 = time.perf_counter(); emb(qpre + q); lat2.append((time.perf_counter() - t0) * 1000)
        perf["embed_only_ms"] = {"p50": pct(lat2, 0.5), "p99": pct(lat2, 0.99)}

        # embed all 880 queries (prefixes included) for the accuracy analysis
        t0 = time.perf_counter()
        Q = np.stack([emb(qpre + q.strip()) for q in queries])
        perf["embed_all_queries_s"] = time.perf_counter() - t0
        Q /= np.linalg.norm(Q, axis=1, keepdims=True)
        perf["rss_mb_peak"] = rss_mb()
    tag = f"{a.backend}_{a.mode}" + (f"_t{a.threads}" if a.threads else "")
    np.savez(os.path.join(HERE, "results", f"emb_{tag}.npz"), D=D, Q=Q)
    json.dump(perf, open(os.path.join(HERE, "results", f"perf_{tag}.json"), "w"), indent=1)
    print(json.dumps(perf, indent=1))


if __name__ == "__main__":
    main()
