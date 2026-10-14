"""F6: local Gemma 4 E4B (LiteRT-LM) on the S/F-route prompt of the brain. One process = one (backend, ctx, prompt) config.

usage: python bench_llm.py --backend gpu|cpu --ctx 8192 --prompt p2k|p3k|p5k|pN --reps 5 [--warm] [--fresh-cache] [--out name]
 p2k: pack trimmed to ~2k tokens; p3k: the sample session pack as is; p5k: pack + 14 extra earlier turns + padding.
 pN with N a number: pad the transcript to ~N tokens (context-limit probing).
Per rep: fresh conversation -> stream one answer (max 120 tokens). Reports load time, TTFT, first full SAY line, tokens/s.
--warm: after the first answer, ask a SECOND question in the same conversation (KV of the prefix is reused) and time it.
"""
from __future__ import annotations
import argparse, json, os, resource, statistics, sys, time
import litert_lm
import prompts as pr

MODEL = os.path.expanduser("~/Library/Application Support/Verse/models/gemma-4-E4B-it-litert-lm/gemma-4-E4B-it.litertlm")
HERE = os.path.dirname(os.path.abspath(__file__))


def rss_mb(): return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6


def build(prompt: str, eng):
    system = pr.P.SYSTEM_FAST
    pack, turns = pr.PACK, list(pr.TURNS)
    if prompt == "p2k":
        pack = pr.trimmed_pack(4400)
    elif prompt == "p5k":
        turns = pr.EXTRA_TURNS + turns
        # pad with more history until ~5000 tokens
        i = 0
        while len(eng.tokenize(system + pr.render(system, pack, turns, "x")[1])) < 4900 and i < 200:
            turns = [pr.Turn(f"pad{i}", "remote" if i % 2 == 0 else "me", f"Filler line {i}: we are covering general logistics topics and background context for the panel notes.")] + turns
            i += 1
    elif prompt.startswith("p") and prompt[1:].isdigit():
        target = int(prompt[1:])
        turns = pr.EXTRA_TURNS + turns
        i = 0
        while len(eng.tokenize(system + pr.render(system, pack, turns, "x")[1])) < target and i < 3000:
            turns = [pr.Turn(f"pad{i}", "remote" if i % 2 == 0 else "me", f"Filler line {i}: we are covering general logistics topics and background context for the panel notes.")] + turns
            i += 1
    return system, pack, turns


def run_stream(conv, text, t0):
    """-> dict(text, t_first, t_say_line, t_end, chunks)"""
    out, t_first, t_line, n = "", None, None, 0
    for chunk in conv.send_message_async(text):
        now = time.perf_counter() - t0
        piece = "".join(i.get("text", "") for i in chunk.get("content", []) if i.get("type") == "text")
        if not piece:
            continue
        n += 1
        if t_first is None: t_first = now
        out += piece
        if t_line is None and "SAY:" in out and "\n" in out[out.index("SAY:"):]:
            t_line = now
    t_end = time.perf_counter() - t0
    return dict(text=out, t_first=t_first, t_say_line=t_line, t_end=t_end, chunks=n)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", default="gpu"); ap.add_argument("--ctx", type=int, default=8192)
    ap.add_argument("--prompt", default="p3k"); ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--warm", action="store_true"); ap.add_argument("--fresh-cache", action="store_true")
    ap.add_argument("--questions", default="q01,q02,q03,q04,q05"); ap.add_argument("--out", default=None)
    ap.add_argument("--max-new", type=int, default=120)
    ap.add_argument("--act", default=None, help="activation dtype name, e.g. FLOAT32")
    ap.add_argument("--mtp", action="store_true", help="enable_speculative_decoding")
    a = ap.parse_args()
    litert_lm.set_min_log_severity(litert_lm.LogSeverity.ERROR)
    be = litert_lm.Backend.GPU() if a.backend == "gpu" else litert_lm.Backend.CPU()
    cache = os.path.join(os.path.dirname(MODEL), "cache" if not a.fresh_cache else f"cache_cold_{int(time.time())}")
    os.makedirs(cache, exist_ok=True)
    res = dict(cfg=vars(a), rss_before_mb=rss_mb(), cache=os.path.basename(cache))
    t0 = time.perf_counter()
    try:
        kw = {}
        if a.act: kw["activation_data_type"] = getattr(litert_lm.ActivationDataType, a.act)
        if a.mtp: kw["enable_speculative_decoding"] = True
        eng = litert_lm.Engine(MODEL, backend=be, max_num_tokens=a.ctx, cache_dir=cache, **kw)
        eng.__enter__()
    except Exception as ex:
        res["load_error"] = repr(ex); print(json.dumps(res)); return
    res["load_s"] = time.perf_counter() - t0
    res["rss_after_load_mb"] = rss_mb()
    qs = {q[0]: q[1] for q in pr.QUESTIONS}
    system, pack, turns = build(a.prompt, eng)
    full_text = system + pr.render(system, pack, turns, qs["q01"])[1]
    res["prompt_tokens_text"] = len(eng.tokenize(full_text))
    res["prompt_chars"] = len(full_text)
    qids = a.questions.split(",")
    runs, warm_runs, errs = [], [], []
    sampler = litert_lm.SamplerConfig(top_k=40, top_p=0.9, temperature=0.4, seed=1)
    think = litert_lm.ThinkingConfig(enable_thinking=False)
    for rep in range(a.reps):
        qid = qids[rep % len(qids)]
        _, user = pr.render(system, pack, turns, qs[qid])
        try:
            conv = eng.create_conversation(system_message=system, thinking_config=think, sampler_config=sampler, max_output_tokens=a.max_new)
            conv.__enter__()
            t = time.perf_counter()
            r = run_stream(conv, user, t)
            r["qid"] = qid; r["out_tokens"] = len(eng.tokenize(r["text"]))
            if r["t_first"] is not None and r["out_tokens"] > 1:
                r["decode_tok_s"] = (r["out_tokens"] - 1) / max(r["t_end"] - r["t_first"], 1e-6)
            runs.append(r)
            if a.warm:
                q2 = qids[(rep + 1) % len(qids)]
                tail = pr.P.fast_tail(qs[q2], "en", True)
                t = time.perf_counter()
                w = run_stream(conv, tail, t); w["qid"] = q2; w["out_tokens"] = len(eng.tokenize(w["text"]))
                warm_runs.append(w)
            conv.__exit__(None, None, None)
        except Exception as ex:
            errs.append(repr(ex)); break
    res["runs"], res["warm_runs"], res["errors"] = runs, warm_runs, errs
    def stat(rs, k):
        v = [r[k] for r in rs if r.get(k) is not None]
        return dict(n=len(v), p50=statistics.median(v), min=min(v), max=max(v)) if v else None
    res["summary"] = {k: stat(runs, k) for k in ("t_first", "t_say_line", "t_end", "decode_tok_s", "out_tokens")}
    if warm_runs: res["summary_warm"] = {k: stat(warm_runs, k) for k in ("t_first", "t_say_line", "t_end", "out_tokens")}
    res["rss_peak_mb"] = rss_mb()
    eng.__exit__(None, None, None)
    name = a.out or f"{a.backend}_{a.prompt}_ctx{a.ctx}"
    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    json.dump(res, open(os.path.join(HERE, "results", f"llm_{name}.json"), "w"), indent=1)
    s = res["summary"]
    print(f"{name}: load {res['load_s']:.2f}s prompt~{res['prompt_tokens_text']} tok | TTFT p50 {s['t_first']['p50'] if s['t_first'] else None} | SAY line p50 {s['t_say_line']['p50'] if s['t_say_line'] else None} | tok/s p50 {s['decode_tok_s']['p50'] if s['decode_tok_s'] else None} | errors {errs}")
    if warm_runs: print("  warm:", res["summary_warm"]["t_first"], res["summary_warm"]["t_say_line"])


if __name__ == "__main__":
    main()
