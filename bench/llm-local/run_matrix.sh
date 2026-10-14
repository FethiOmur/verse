#!/bin/bash
# Sequential F6 matrix (one process per config, never in parallel). Logs the machine's idle CPU % before each run.
cd "$(dirname "$0")"
idle() { top -l 2 -n 0 -s 1 | grep "CPU usage" | tail -1 | sed -E 's/.* ([0-9.]+)% idle.*/\1/'; }
run() { # name args...
  name=$1; shift
  echo "### $name idle_before=$(idle) args: $*"
  /usr/bin/time -l .venv/bin/python bench_llm.py "$@" --out $name 2> results/time_$name.txt | grep -v "^[WI]0000"
  grep -E "maximum resident|peak memory" results/time_$name.txt | tr -s ' ' | tr '\n' ';'; echo
}
run gpu_p2k_ctx8192  --backend gpu --ctx 8192 --prompt p2k --reps 4 --warm
run gpu_p3k_ctx8192b --backend gpu --ctx 8192 --prompt p3k --reps 4 --warm
run gpu_p5k_ctx8192  --backend gpu --ctx 8192 --prompt p5k --reps 4 --warm
run cpu_p2k_ctx8192  --backend cpu --ctx 8192 --prompt p2k --reps 3 --warm
run cpu_p3k_ctx8192  --backend cpu --ctx 8192 --prompt p3k --reps 3 --warm
run cpu_p5k_ctx8192  --backend cpu --ctx 8192 --prompt p5k --reps 3 --warm
run gpu_p3k_ctx4096  --backend gpu --ctx 4096 --prompt p3k --reps 1
run gpu_p5k_ctx4096  --backend gpu --ctx 4096 --prompt p5k --reps 1
run gpu_p12000_ctx16384 --backend gpu --ctx 16384 --prompt p12000 --reps 1
run gpu_p30000_ctx32768 --backend gpu --ctx 32768 --prompt p30000 --reps 1
echo "### done idle=$(idle)"
