#!/bin/bash
# Drives "Rehearse a line…" in the running Verse app from the terminal, through its verse-rehearse:// URL scheme.
#
#   app/scripts/rehearse.sh start "<session folder name>"   start a rehearsal of that prepared session
#   app/scripts/rehearse.sh them "<line>" ["<session>"]     say a line as the other side (starts the session first if given)
#   app/scripts/rehearse.sh me "<line>" ["<session>"]       say a line as yourself
#   app/scripts/rehearse.sh end                             end the rehearsal (its temporary copy is removed)
#   app/scripts/rehearse.sh open                            show the panel
#
# The line goes in where recognised speech goes in; the island shows what the real pipeline makes of it. No audio is captured
# and the prepared session folder is not written. A request while a real call runs is refused and the refusal shows on the panel.
# `open -g` hands the URL to the app without bringing it to the front.
set -euo pipefail

enc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ $# -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  start)
    [ $# -eq 1 ] || usage
    url="verse-rehearse://start?session=$(enc "$1")" ;;
  them|me)
    [ $# -ge 1 ] && [ $# -le 2 ] || usage
    url="verse-rehearse://say?speaker=$cmd&text=$(enc "$1")"
    if [ $# -eq 2 ]; then url="$url&session=$(enc "$2")"; fi ;;
  end) url="verse-rehearse://end" ;;
  open) url="verse-rehearse://open" ;;
  *) usage ;;
esac
open -g "$url"
