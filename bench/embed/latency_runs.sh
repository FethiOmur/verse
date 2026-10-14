#!/bin/bash
# Repeats the embedding bench per backend and logs the machine's CPU idle % before/after each run (other sessions share this Mac).
cd "$(dirname "$0")"
idle() { top -l 2 -n 0 -s 1 | grep "CPU usage" | tail -1 | sed -E 's/.* ([0-9.]+)% idle.*/\1/'; }
for i in 1 2 3; do
  for b in gpu cpu; do
    pre=$(idle)
    .venv/bin/python bench_embed.py --backend $b --mode sym > /dev/null 2>&1
    post=$(idle)
    cp results/perf_${b}_sym.json results/perf_${b}_sym_run$i.json
    .venv/bin/python - <<PY
import json
p=json.load(open("results/perf_${b}_sym_run$i.json"))
print("run $i $b idle_before=$pre idle_after=$post p50=%.1f p90=%.1f p99=%.1f max=%.1f load_s=%.2f index_s=%.2f rss_peak_mb=%.0f" % (p["latency_ms"]["p50"],p["latency_ms"]["p90"],p["latency_ms"]["p99"],p["latency_ms"]["max"],p["load_s"],p["index_seq_s"],p["rss_mb_peak"]))
PY
  done
done
