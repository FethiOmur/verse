#!/bin/bash
# Re-run of the configs that ran while other sessions saturated the CPU (idle ~0 %), plus the context-limit probe.
cd "$(dirname "$0")"
idle() { top -l 2 -n 0 -s 1 | grep "CPU usage" | tail -1 | sed -E 's/.* ([0-9.]+)% idle.*/\1/'; }
run() { name=$1; shift
  echo "### $name idle_before=$(idle) args: $*"
  /usr/bin/time -l .venv/bin/python bench_llm.py "$@" --out $name 2> results/time_$name.txt | grep -v "^[WI]0000"
  grep -E "maximum resident|peak memory" results/time_$name.txt | tr -s ' ' | tr '\n' ';'; echo; echo "   idle_after=$(idle)"; }
run r2_cpu_p2k --backend cpu --ctx 8192 --prompt p2k --reps 3 --warm
run r2_cpu_p3k --backend cpu --ctx 8192 --prompt p3k --reps 3 --warm
run r2_cpu_p5k --backend cpu --ctx 8192 --prompt p5k --reps 3 --warm
run r2_gpu_p5k --backend gpu --ctx 8192 --prompt p5k --reps 4 --warm
run r2_gpu_p3k_ctx65536 --backend gpu --ctx 65536 --prompt p3k --reps 1
run r2_gpu_p3k_ctx131072 --backend gpu --ctx 131072 --prompt p3k --reps 1
echo "### done idle=$(idle)"
