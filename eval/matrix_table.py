#!/usr/bin/env python3
"""Prints the bleed matrix (runs named m_<condition>_<defenses>) from a two-track output folder as a table.

    python matrix_table.py $VERSE_EVAL_OUT/twotrack
"""
import json
import sys
from pathlib import Path

CONDS = {"A": "-25 dB, 40 ms, noise -55", "C": "-30 dB, 80 ms, noise -50", "D": "-30 dB, 20 ms, noise -45", "O": "-25 dB, 40 ms, noise -55, Alex talking"}
DEF = {"none": "none", "gate": "envelope gate (today)", "guard": "text guard only", "both": "gate + text guard"}


def main() -> None:
    d = Path(sys.argv[1])
    print("| condition | defenses | questions answered once | remote turns | me turns (false) | me events at engine | gate / guard dropped | wrong triggers | Alex landed as me |")
    print("|---|---|---|---|---|---|---|---|---|")
    for c in CONDS:
        for k in DEF:
            f = d / f"m_{c}_{k}.score.json"
            if not f.exists():
                continue
            s = json.loads(f.read_text())
            q = s["questions"]
            print(f"| {CONDS[c]} | {DEF[k]} | {q['answered_once']}/{q['n']} | {s['remote_turns']} | {s['me_turns']} ({s['false_me_turns']}) | "
                  f"{s['me_events_reaching_engine']} | {s['echo_gate_dropped']} / {s['echo_guard_dropped']} | {s['wrong_trigger_count']} | "
                  f"{s['me_labels']['landed_as_me_turn']}/{s['me_labels']['n']} |")


if __name__ == "__main__":
    main()
