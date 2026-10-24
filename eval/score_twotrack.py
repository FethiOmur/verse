#!/usr/bin/env python3
"""Scores one two-track replay (eval/run_twotrack.py output) against its fixture: answered-turn counts, me turns, wrong
triggers and the echo numbers. Stdlib only.

An "answer" is a turn for which the brain produced a call whose text is not the statement acknowledgement. That test fits
the fake brain (`--fake-brain`: statements get "Thanks, noted.", questions the canned answer); with the live brain pass
`ack_text` that fits its acknowledgement or read the `calls` listing in the result.

Wrong triggers, as defined for P1:
  answer_on_me_turn       any model output attached to one of the owner's own turns
  answer_on_spurious_turn a remote turn that matches no spoken utterance (nobody said it) got an answer
  answer_on_no_answer     a statement/fragment got an answer
  double_answer           one question got answers on two or more turns
  missed_answer           a question for the user got no answer (counted apart: a suppressed answer, not a wrong trigger)
  false_me_turn           a me turn that matches none of the owner's utterances (his mic heard something he did not say)
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

MATCH_BEFORE = 0.3
MATCH_AFTER = 1.8
ME_MATCH_BEFORE = 0.3
ME_MATCH_AFTER = 2.0
ACK_DEFAULT = "Thanks, noted"

TRACE_ME = re.compile(r"trace event me t=([\d.]+) audio=([\d.]+)-([\d.]+) final=([yn]) (.*)$")


def load_events(jsonl: Path) -> list[tuple[float, dict]]:
    out = []
    for ln in jsonl.read_text(encoding="utf-8").splitlines():
        if ln.strip():
            r = json.loads(ln)
            out.append((r["wall"], r["line"]))
    return out


def trace_me_events(stderr_log: Path | None) -> list[dict]:
    """The me-channel transcript events that reached the turn engine (verse-run --trace), text and times only."""
    if stderr_log is None or not stderr_log.exists():
        return []
    out = []
    for ln in stderr_log.read_text(encoding="utf-8", errors="replace").splitlines():
        m = TRACE_ME.search(ln)
        if m:
            out.append({"emitted": float(m[1]), "start": float(m[2]), "end": float(m[3]), "final": m[4] == "y", "text": m[5]})
    return out


def assemble_calls(events: list[tuple[float, dict]]) -> dict[str, dict]:
    """call id -> {turn_id, tier, text} from the delta lines."""
    calls: dict[str, dict] = {}
    for _, o in events:
        if o.get("type") == "delta":
            c = calls.setdefault(o["id"], {"turn_id": o.get("turn_id"), "tier": o.get("tier"), "text": ""})
            c["text"] += o.get("text", "")
    return calls


def lines_of(deltas: list[tuple[float, dict]]) -> list[tuple[float, str]]:
    """(wall time of its last piece, text) of every complete line in a stream of delta pieces (`line_done` ends a line)."""
    out, buf = [], ""
    for w, o in deltas:
        buf += o.get("text", "")
        if o.get("line_done"):
            out.append((w, buf.strip()))
            buf = ""
    return out


def follow_stats(label: dict, events: list[tuple[float, dict]], meta: dict, origin_m: float, wall0: float) -> dict | None:
    """Follow my answer: the follow cards the brain sent, per owner utterance that carries a `follow` label.

    Times are wall-clock ms measured from the moment the owner *spoke* the first off-card word (`off_from_word`, spread evenly over
    the utterance's true speech interval): `detection_ms` until the brain's first `follow` event, `first_sentence_ms` until the
    first complete `SAY:` line of the follow card. `wall0` is the wall time of audio time 0 (`session_t0.t`; exact in
    run_follow.py, an approximation for a verse-run replay)."""
    follows = [(w, o) for w, o in events if o.get("type") == "follow"]
    covered = [(w, o) for w, o in events if o.get("type") == "covered"]
    c_deltas = [(w, o) for w, o in events if o.get("type") == "delta" and o.get("tier") == "C"]
    labelled = [(i, u) for i, u in enumerate(label["utterances"]) if u.get("follow")]
    if not follows and not labelled and not covered:
        return None
    tl = {t["index"]: t for t in meta["timeline"]}
    metrics = {}
    for _, o in events:
        if o.get("type") == "metric" and o.get("stage") in ("follow_diverged", "follow_card", "follow_refresh"):
            metrics.setdefault(o["stage"], []).append(o)
    rows = []
    for i, u in labelled:
        t = tl[i]
        a, b = wall0 + origin_m + t["t_start"], wall0 + origin_m + t["t_end"]
        words = u["text"].split()
        off_t = None
        if u["follow"] == "diverge":
            off_t = a + (b - a) * u["off_from_word"] / max(1, len(words))
        win_end = b + 8.0
        fl = [(w, o) for w, o in follows if a <= w <= win_end]
        row = {"index": i, "label": u["follow"], "text": u["text"], "follow_events": len(fl),
               "reasons": [o.get("reason") for _, o in fl]}
        if off_t is not None and fl:
            row["detection_ms"] = round((fl[0][0] - off_t) * 1000)
            cid = fl[0][1].get("card_id")
            card_lines = lines_of([(w, o) for w, o in c_deltas if o.get("card_id") == cid])
            say = next((w for w, ln in card_lines if ln.startswith("SAY:")), None)
            if say is not None:
                row["first_sentence_ms"] = round((say - off_t) * 1000)
            row["card_points"] = sum(1 for _, ln in card_lines if ln.startswith("- "))
            row["card_text"] = "\n".join(ln for _, ln in card_lines)
        row["ok"] = (len(fl) == 0) if u["follow"] == "none" else (len(fl) >= 1)
        rows.append(row)
    cov = [(o.get("card_id"), o.get("point")) for _, o in covered]
    return {"follow_events": len(follows), "c_cards": len({o.get("card_id") for _, o in c_deltas}),
            "covered_events": len(covered), "covered": cov, "rows": rows,
            "unlabelled_follow_events": len(follows) - sum(r["follow_events"] for r in rows),
            "brain_diverged_metrics": [{k: o.get(k) for k in ("reason", "unmatched", "embed", "margin", "ms", "ms_since_start")}
                                       for o in metrics.get("follow_diverged", [])],
            "brain_card_metrics": [{k: o.get(k) for k in ("first_sentence_ms", "since_decision_ms")} for o in metrics.get("follow_card", [])]}


def score(label: dict, events: list[tuple[float, dict]], meta: dict, ack_text: str = ACK_DEFAULT,
          stderr_log: Path | None = None) -> dict:
    t0 = next((o for _, o in events if o.get("type") == "metric" and o.get("stage") == "session_t0"), None)
    if t0 is None:
        return {"id": label["id"], "error": "no session_t0 metric (verse-run did not start listening)"}
    summ = next((o for _, o in reversed(events) if o.get("type") == "metric" and o.get("stage") == "listen_summary"), {})
    origin_r = float(summ.get("origin_remote", t0.get("origin_remote", 0.0)))
    origin_m = float(summ.get("origin_me", t0.get("origin_me", origin_r)))
    utts = label["utterances"]
    tl = {t["index"]: t for t in meta["timeline"]}
    rem_wins, me_wins = [], []
    for i, u in enumerate(utts):
        t = tl[i]
        if t["channel"] == "me":
            me_wins.append({"index": i, "u": u, "s_start": origin_m + t["t_start"], "s_end": origin_m + t["t_end"]})
        else:
            rem_wins.append({"index": i, "u": u, "s_start": origin_r + t["t_start"], "s_end": origin_r + t["t_end"]})

    turns = [dict(o, wall=w) for w, o in events if o.get("type") == "turn" and o.get("dir") == "to_brain"]
    remote_turns = [t for t in turns if t.get("speaker") == "remote"]
    me_turns = [t for t in turns if t.get("speaker") == "me"]
    calls = assemble_calls(events)
    by_turn: dict[str, list[dict]] = {}
    for cid, c in calls.items():
        by_turn.setdefault(c["turn_id"], []).append(dict(c, id=cid))

    def answered(tid: str) -> bool:
        return any(ack_text not in c["text"] and c["text"].strip() for c in by_turn.get(tid, []))

    def has_output(tid: str) -> bool:
        return any(c["text"].strip() for c in by_turn.get(tid, []))

    # remote turns -> utterances
    per_label: dict[int, list[dict]] = {w["index"]: [] for w in rem_wins}
    spurious_remote = []
    for t in remote_turns:
        ta = float(t.get("t_audio_end", 0.0))
        cands = [w for w in rem_wins if w["s_start"] - MATCH_BEFORE <= ta <= w["s_end"] + MATCH_AFTER]
        if not cands:
            spurious_remote.append(t)
            continue
        per_label[min(cands, key=lambda w: abs(ta - w["s_end"]))["index"]].append(t)
    # me turns -> utterances
    per_me: dict[int, list[dict]] = {w["index"]: [] for w in me_wins}
    false_me = []
    for t in me_turns:
        ta = float(t.get("t_audio_end", 0.0))
        # a run whose me track is bleed only (the owner silent): every me turn is false, whatever the utterance windows say
        cands = [] if meta.get("owner_silent") else [w for w in me_wins if w["s_start"] - ME_MATCH_BEFORE <= ta <= w["s_end"] + ME_MATCH_AFTER]
        if not cands:
            false_me.append(t)
            continue
        per_me[min(cands, key=lambda w: abs(ta - w["s_end"]))["index"]].append(t)

    wrong: list[dict] = []
    rows = []
    for w in rem_wins:
        u, ts = w["u"], per_label[w["index"]]
        ans = [t for t in ts if answered(t["turn_id"])]
        row = {"index": w["index"], "expect": u["expect"], "role": u.get("role", ""), "text": u["text"],
               "heard": [{"turn_id": t["turn_id"], "text": t.get("text", ""), "kind": t.get("kind"), "addressee": t.get("addressee"),
                          "answered": answered(t["turn_id"])} for t in ts],
               "turns": len(ts), "answered_turns": len(ans)}
        if u["expect"] == "answer":
            row["verdict"] = "ok" if len(ans) == 1 else "missed" if not ans else "double"
            if len(ans) > 1:
                wrong.append({"kind": "double_answer", "label": w["index"], "turns": [t["turn_id"] for t in ans]})
        elif u["expect"] == "no_answer":
            row["verdict"] = "ok" if not ans else "wrong"
            if ans:
                wrong.append({"kind": "answer_on_no_answer", "label": w["index"], "turns": [t["turn_id"] for t in ans]})
        else:
            row["verdict"] = "answered" if ans else "not answered"
            if len(ans) > 1:
                wrong.append({"kind": "double_answer", "label": w["index"], "turns": [t["turn_id"] for t in ans]})
        rows.append(row)
    me_rows = []
    for w in me_wins:
        ts = per_me[w["index"]]
        me_rows.append({"index": w["index"], "expect": w["u"]["expect"], "role": w["u"].get("role", ""), "text": w["u"]["text"],
                        "heard": [t.get("text", "") for t in ts], "me_turns": len(ts)})
    for t in spurious_remote:
        if answered(t["turn_id"]):
            wrong.append({"kind": "answer_on_spurious_turn", "turn_id": t["turn_id"], "text": t.get("text", "")})
    for t in me_turns:
        if has_output(t["turn_id"]):
            wrong.append({"kind": "answer_on_me_turn", "turn_id": t["turn_id"], "text": t.get("text", "")})
    for t in false_me:
        wrong.append({"kind": "false_me_turn", "turn_id": t["turn_id"], "text": t.get("text", ""), "t_audio_end": t.get("t_audio_end")})

    a_rows = [r for r in rows if r["expect"] == "answer"]
    n_rows = [r for r in rows if r["expect"] == "no_answer"]
    e_rows = [r for r in rows if r["expect"] == "either"]
    gate = [o for _, o in events if o.get("type") == "metric" and o.get("stage") == "echo_gate_dropped"]
    guard = [o for _, o in events if o.get("type") == "metric" and o.get("stage") == "echo_guard_dropped"]
    me_ev = trace_me_events(stderr_log)
    # What the envelope gate dropped while the owner was really speaking (the gate-fix acceptance number). Only meaningful when
    # his speech is on the me track: with bleed only (owner_silent) nothing he says exists. The dropped event's audio range
    # is on the me channel's clock; overlap with one of his utterance windows counts.
    gate_events = [o for _, o in events if o.get("type") == "metric" and o.get("stage") == "echo_gate_dropped"]
    real_dropped = []
    if not meta.get("owner_silent"):
        for g in gate_events:
            gs, ge = float(g.get("audio_start", 0.0)), float(g.get("audio_end", 0.0))
            if any(min(ge, w["s_end"]) - max(gs, w["s_start"]) > 0 for w in me_wins):
                real_dropped.append(g.get("text", ""))
    deferred = [o for _, o in events if o.get("type") == "metric" and o.get("stage") == "echo_gate_decision" and o.get("verdict") == "defer"]
    t0_wall = float(t0.get("t", 0.0))
    fol = follow_stats(label, events, meta, origin_m, t0_wall)
    return {
        "id": label["id"],
        "follow": fol,
        "questions": {"n": len(a_rows), "answered_once": sum(r["verdict"] == "ok" for r in a_rows),
                      "missed": sum(r["verdict"] == "missed" for r in a_rows), "double": sum(r["verdict"] == "double" for r in a_rows)},
        "no_answer_labels": {"n": len(n_rows), "wrongly_answered": sum(r["verdict"] == "wrong" for r in n_rows)},
        "either_labels": {"n": len(e_rows), "answered": sum(r["verdict"] == "answered" for r in e_rows)},
        "me_labels": {"n": len(me_rows), "landed_as_me_turn": sum(r["me_turns"] > 0 for r in me_rows),
                      "me_turns": sum(r["me_turns"] for r in me_rows)},
        "remote_turns": len(remote_turns), "answered_remote_turns": sum(answered(t["turn_id"]) for t in remote_turns),
        "me_turns": len(me_turns), "false_me_turns": len(false_me), "spurious_remote_turns": len(spurious_remote),
        "answers_on_me_turns": sum(has_output(t["turn_id"]) for t in me_turns),
        "echo_gate_dropped": len(gate), "echo_guard_dropped": len(guard),
        "gate_dropped_over_own_speech": len(real_dropped), "gate_dropped_over_own_speech_texts": real_dropped,
        "echo_gate_deferred": len(deferred),
        "me_events_reaching_engine": len(me_ev) if stderr_log else None,
        "wrong_triggers": wrong, "wrong_trigger_count": sum(1 for x in wrong if x["kind"] != "false_me_turn"),
        "rows": rows, "me_rows": me_rows,
        "false_me_texts": [t.get("text", "") for t in false_me],
        "gate_dropped_texts": [g.get("text", "") for g in gate], "guard_dropped_texts": [g.get("text", "") for g in guard],
    }


def table(res: dict) -> str:
    q, n, e, m = res["questions"], res["no_answer_labels"], res["either_labels"], res["me_labels"]
    lines = [
        f"{res['id']}: questions {q['answered_once']}/{q['n']} answered once (missed {q['missed']}, double {q['double']}); "
        f"statements wrongly answered {n['wrongly_answered']}/{n['n']}; ambiguous answered {e['answered']}/{e['n']}",
        f"  remote turns {res['remote_turns']} (answered {res['answered_remote_turns']}, spurious {res['spurious_remote_turns']}); "
        f"me turns {res['me_turns']} (false {res['false_me_turns']}); answers on me turns {res['answers_on_me_turns']}; "
        f"the owner's utterances landing as me turns {m['landed_as_me_turn']}/{m['n']}",
        f"  echo dropped: gate {res['echo_gate_dropped']} (over the owner's own speech {res['gate_dropped_over_own_speech']}, deferred to the text guard "
        f"{res['echo_gate_deferred']}), text guard {res['echo_guard_dropped']}; me events that reached the engine "
        f"{res['me_events_reaching_engine']}; wrong triggers {res['wrong_trigger_count']}",
    ]
    f = res.get("follow")
    if f:
        lines.append(f"  follow: {f['follow_events']} follow events, {f['c_cards']} follow cards, {f['covered_events']} points struck through, "
                     f"{f['unlabelled_follow_events']} follow events outside a labelled utterance")
        for r in f["rows"]:
            tail = ""
            if r["label"] == "diverge" and "detection_ms" in r:
                tail = (f"  detection {r['detection_ms']} ms, first sentence {r.get('first_sentence_ms', 'n/a')} ms, "
                        f"{r.get('card_points', 0)} points")
            lines.append(f"    {'ok ' if r['ok'] else 'BAD'} u{r['index']} follow={r['label']}: {r['follow_events']} follow events{tail}")
    for w in res["wrong_triggers"]:
        lines.append(f"    ! {w['kind']}: {w.get('text') or w.get('turns') or w.get('label')}")
    return "\n".join(lines)


def main() -> int:
    import argparse
    import twotrack
    ap = argparse.ArgumentParser()
    ap.add_argument("jsonl", type=Path)
    ap.add_argument("--fixture", default=None)
    ap.add_argument("--ack-text", default=ACK_DEFAULT)
    a = ap.parse_args()
    meta = json.loads(a.jsonl.with_suffix(".meta.json").read_text())
    fixture = twotrack.load(a.fixture or meta["fixture"])
    res = score(fixture, load_events(a.jsonl), meta, a.ack_text, a.jsonl.with_suffix(".stderr.log"))
    print(table(res))
    return 0


if __name__ == "__main__":
    sys.exit(main())
