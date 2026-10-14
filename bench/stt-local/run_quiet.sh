#!/bin/zsh
# Apple + Nemotron rerun under the lower-load conditions of the Moonshine rerun, with a system CPU-idle sampler per run.
cd "$(dirname "$0")"
B=.build/release/SttLocal
df -h / | tail -1
run() {  # engine, tag
  echo "=== $1 $2 $(date +%T) $(uptime | sed -E 's/.*(load averages?:.*)/\1/')"
  ( while true; do echo "$(date +%T) $(top -l 1 -n 0 | grep 'CPU usage')" >> results/cpu-$1-$2.log; sleep 10; done ) &
  S=$!
  $B --engine $1 --tag $2 2>&1 | grep -v '^SYNTH'
  kill $S; wait $S 2>/dev/null
  echo "   uptime after: $(uptime | sed -E 's/.*(load averages?:.*)/\1/')"
}
run apple rerun1
run nemotron rerun1
echo "=== done $(date +%T)"
df -h / | tail -1
