#!/bin/zsh
# Reruns Moonshine after the first set was run while another session's iOS Simulator kept the CPU saturated (load average 70-100).
# Logs system CPU idle every 10 s next to each run so contention is on record.
cd "$(dirname "$0")"
B=.build/release/SttLocal
df -h / | tail -1
run() {  # tag, extra args
  echo "=== moonshine $1 $(date +%T) $(uptime | sed -E 's/.*(load averages?:.*)/\1/')"
  ( while true; do echo "$(date +%T) $(top -l 1 -n 0 | grep 'CPU usage')" >> results/cpu-$1.log; sleep 10; done ) &
  S=$!
  $B --engine moonshine --tag $1 ${=2} 2>&1 | grep -v '^SYNTH'
  kill $S; wait $S 2>/dev/null
  echo "   uptime after: $(uptime | sed -E 's/.*(load averages?:.*)/\1/')"
}
run rerun1 ""
run rerun2 ""
run rerun1-int0.2 "--moon-interval 0.2"
echo "=== done $(date +%T)"
df -h / | tail -1
