#!/bin/zsh
# Sequential full runs (20 English questions x Albert + Samantha, real-time). One engine process at a time.
cd "$(dirname "$0")"
B=.build/release/SttLocal
df -h / | tail -1
for spec in "apple run1" "nemotron run1" "moonshine run1" "apple run2" "nemotron run2" "moonshine run2"; do
  set -- ${=spec}
  echo "=== $1 $2 $(date +%T)"
  $B --engine $1 --tag $2 2>&1 | grep -v '^SYNTH'
done
echo "=== moonshine interval 0.2 $(date +%T)"
$B --engine moonshine --tag run1-int0.2 --moon-interval 0.2 2>&1 | grep -v '^SYNTH'
echo "=== done $(date +%T)"
df -h / | tail -1
