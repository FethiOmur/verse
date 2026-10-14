#!/bin/bash
# GPU with FLOAT32 activations (the fp16 default corrupts digits, see results/llm_quality.json): quality set + timings.
cd "$(dirname "$0")"
idle() { top -l 2 -n 0 -s 1 | grep "CPU usage" | tail -1 | sed -E 's/.* ([0-9.]+)% idle.*/\1/'; }
run() { name=$1; shift
  echo "### $name idle_before=$(idle) args: $*"
  /usr/bin/time -l .venv/bin/python bench_llm.py "$@" --out $name 2> results/time_$name.txt | grep -v "^[WI]0000"
  grep -E "maximum resident|peak memory" results/time_$name.txt | tr -s ' ' | tr '\n' ';'; echo; echo "   idle_after=$(idle)"; }
run r3_fp32_p2k --backend gpu --act FLOAT32 --ctx 8192 --prompt p2k --reps 4 --warm
run r3_fp32_p3k --backend gpu --act FLOAT32 --ctx 8192 --prompt p3k --reps 4 --warm
run r3_fp32_p5k --backend gpu --act FLOAT32 --ctx 8192 --prompt p5k --reps 4 --warm
run quality_fp32 --backend gpu --act FLOAT32 --ctx 8192 --prompt p3k --reps 10 --questions q01,q02,q03,q04,q05,q06,q07,q08,q09,q10
echo "### done idle=$(idle)"
