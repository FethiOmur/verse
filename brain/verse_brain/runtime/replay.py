"""Live replay: drive the real runtime process over its pipes with 10 scripted question turns.

    python -m verse_brain.runtime.replay --live [--session DIR] [--out PATH]

The replay plays the Swift side: partials grow one word every `--word-ms` with a question cue where Swift's
P1-4 logic would set it, bank hits where its matcher would fire, `turn` 300 ms after the last word (the
endpoint), and the owner's short reply as a `me` turn. t = 0 here is the moment `turn` is sent, so the numbers
exclude ASR lag and the endpoint decision. Writes per-call and per-tier metrics to `brain/tests/out/live-metrics.json`.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

BRAIN = Path(__file__).resolve().parents[2]
DEFAULT_OUT = BRAIN / "tests" / "out" / "live-metrics.json"

NO_CUE = 10_000  # no word-order cue at all (e.g. an Italian yes/no question that differs only by intonation)

# text, cue_from (0-based word index where Swift's cue turns on), bank (id, score, at word n) or None, addressee,
# the owner's reply (a `me` turn) or None, pause (after word n, seconds) or None
SCRIPT = [
    dict(text="Can you tell me a bit about yourself and your background", cue_from=1, bank=("b001", 0.92, 5),
         addressee="me", reply="Sure, I led Lantern and built a route optimiser for a courier pilot.", pause=None),
    dict(text="So what made you apply for this role at Halden in the first place", cue_from=2, bank=("b002", 0.88, 6),
         addressee="me", reply="The move to an LLM-assisted dispatcher is exactly my overlap.", pause=None),
    dict(text="And the cases where the model was unsure about a field you handled them how", cue_from=NO_CUE,
         bank=("b010", 0.71, 6), addressee="me", reply="Low-confidence fields went to an operator.", pause=None),
    dict(text="Our dispatch team works across four countries so how would you roll out a pilot of an LLM "
              "dispatcher there", cue_from=8, bank=None, addressee="me",
         reply="I would start with one depot and a shadow mode.", pause=(18, 1.0)),
    dict(text="Right that makes sense and what is your notice period", cue_from=5, bank=("b015", 0.86, 8),
         addressee="me", reply="Thirty days.", pause=None),
    dict(text="Tomas could you share the roadmap slide with everyone please", cue_from=1, bank=None,
         addressee="other", reply=None, pause=None),
    dict(text="The accuracy you reached on line items versus totals was what in the end", cue_from=NO_CUE,
         bank=("b011", 0.80, 4), addressee="me", reply="Totals 96.4 percent, line items 91.", pause=None),
    dict(text="And how much did the whole thing cost per month compared with what it saved", cue_from=2,
         bank=("b012", 0.90, 7), addressee="me", reply="About 1,900 euros against 9,500 saved.", pause=None),
    dict(text="The part of our Compass product you would want to work on first is which one", cue_from=NO_CUE,
         bank=None, addressee="me", reply="The re-planning loop, because of my routing work.", pause=None),
    dict(text="Okay last one what are your salary expectations for this position", cue_from=3,
         bank=("b016", 0.93, 6), addressee="me", reply="Between 78 and 85 thousand gross.", pause=None),
]

DEFAULT_SESSION = Path(os.environ.get("VERSE_LIVE_SESSION", "~/Library/Application Support/Verse/sessions"))


def pct(vals: list[float], p: float) -> float | None:
    if not vals:
        return None
    s = sorted(vals)
    if p == 0.9:  # nearest rank, robust for small n
        return s[max(0, math.ceil(0.9 * len(s)) - 1)]
    k = (len(s) - 1) * p
    f = int(k)
    c = min(f + 1, len(s) - 1)
    return s[f] + (s[c] - s[f]) * (k - f)


class Proc:
    def __init__(self, budget: float, log_path: Path, fake: bool = False) -> None:
        self.log = open(log_path, "w", encoding="utf-8")
        cmd = [sys.executable, "-u", "-m", "verse_brain.runtime", "--budget-usd", str(budget), "--log-level", "INFO"]
        self.p = subprocess.Popen(cmd + (["--fake"] if fake else []), cwd=BRAIN, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=self.log, text=True)
        self.q: queue.Queue = queue.Queue()
        self.events: list[tuple[float, dict]] = []
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        for line in self.p.stdout:
            try:
                self.q.put((time.time(), json.loads(line)))
            except json.JSONDecodeError:
                self.q.put((time.time(), {"type": "_bad", "raw": line[:200]}))
        self.q.put((time.time(), None))

    def send(self, msg: dict) -> None:
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()

    def pump(self, until: float, stop=None) -> bool:
        """Collect events until time `until` or until stop(events) is true. Returns False on process exit."""
        while True:
            if stop is not None and stop(self.events):
                return True
            left = until - time.time()
            if left <= 0:
                return True
            try:
                t, ev = self.q.get(timeout=min(left, 0.05))
            except queue.Empty:
                continue
            if ev is None:
                return False
            self.events.append((t, ev))

    def close(self) -> None:
        try:
            if self.p.poll() is None:
                try:
                    self.send({"type": "control", "action": "stop"})
                except (BrokenPipeError, OSError):
                    pass
                try:
                    self.p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.p.kill()
                    self.p.wait(timeout=5)
        finally:
            self.log.close()


def _turn_resolved(tid: str, addressee: str):
    def check(events) -> bool:
        evs = [e for _, e in events if e.get("turn_id") == tid]
        if addressee == "other":
            return any(e.get("stage") == "for_others" for e in evs)
        visible_ids = {e["id"] for e in evs if e["type"] == "metric" and e.get("stage") in ("visible", "release")}
        done_ids = {e["id"] for e in evs if e["type"] == "metric" and e.get("stage") == "done"}
        fast_ok = any(i in done_ids for i in visible_ids if i[0] in "sf") or any(
            e["type"] == "status" and e.get("state") in ("refusal", "error") for e in evs)
        d_fired = {e["id"] for e in evs if e["type"] == "metric" and e.get("stage") == "fire" and e.get("tier") == "D"}
        d_ok = any(e.get("stage") == "d_skipped" for e in evs) or any(
            i in done_ids for i in visible_ids if i[0] == "d") or (d_fired and d_fired <= done_ids and any(
                e.get("stage") in ("d_confirmed",) for e in evs))
        return fast_ok and d_ok
    return check


def run_live(session: Path, out: Path, word_ms: int, budget: float, fake: bool = False) -> dict:
    out.parent.mkdir(parents=True, exist_ok=True)
    proc = Proc(budget, out.with_name("live-runtime.log"), fake=fake)
    turn_log: list[dict] = []
    summarize_s = None
    try:
        proc.send({"type": "start", "session_dir": str(session), "lang": "en"})
        proc.pump(time.time() + 90, stop=lambda evs: any(e.get("type") == "status" and e.get("state") in
                                                          ("ready", "error", "offline", "credit_exhausted") for _, e in evs))
        st = [e for _, e in proc.events if e.get("type") == "status"]
        if not st or st[-1]["state"] != "ready":
            raise SystemExit(f"runtime did not become ready: {st[-1] if st else 'no status'}")
        for i, item in enumerate(SCRIPT, 1):
            text, cue_from, bank, addressee, reply, pause = (item[k] for k in
                                                             ("text", "cue_from", "bank", "addressee", "reply", "pause"))
            tid = f"q{i:02d}"
            words = text.split()
            for n in range(1, len(words) + 1):
                proc.send({"type": "partial", "turn_id": tid, "speaker": "remote", "text": " ".join(words[:n]),
                           "cue": n - 1 >= cue_from, "t_audio_end": time.time()})
                if bank and n == bank[2]:
                    proc.send({"type": "bank_hit", "turn_id": tid, "bank_id": bank[0], "score": bank[1]})
                proc.pump(time.time() + word_ms / 1000)
                if pause and n == pause[0]:
                    proc.pump(time.time() + pause[1])  # the speaker hesitates: the partial stays stable
            proc.pump(time.time() + 0.3)  # endpoint decision
            t_turn = time.time()
            proc.send({"type": "turn", "turn_id": tid, "speaker": "remote", "text": text, "addressee": addressee,
                       "t_audio_end": t_turn - 0.3})
            proc.pump(time.time() + 15, stop=_turn_resolved(tid, addressee))
            turn_log.append({"turn_id": tid, "text": text, "addressee": addressee, "bank": bank, "t_turn_sent": t_turn})
            if reply:
                proc.send({"type": "turn", "turn_id": f"m{i:02d}", "speaker": "me", "text": reply,
                           "addressee": "unknown", "t_audio_end": time.time()})
            proc.pump(time.time() + 1.0)
        t_summarize = time.time()
        proc.send({"type": "control", "action": "summarize"})   # the final Sonnet merge -> summary.md (F2)
        proc.pump(time.time() + 60, stop=lambda evs: any(e.get("type") == "summary" and e.get("final") is not None
                                                         for _, e in evs))
        summarize_s = round(time.time() - t_summarize, 2)
    finally:
        proc.close()
    # drain what is left
    while True:
        try:
            t, ev = proc.q.get_nowait()
        except queue.Empty:
            break
        if ev is not None:
            proc.events.append((t, ev))
    res = analyse(proc.events, turn_log, session)
    res["summarize_s"] = summarize_s
    return res


def analyse(events: list[tuple[float, dict]], turn_log: list[dict], session: Path) -> dict:
    calls: dict[str, dict] = {}
    warm: list[dict] = []
    for t_recv, e in events:
        if e.get("type") != "metric":
            continue
        if e.get("stage") in ("prewarm", "keepalive"):
            warm.append(e)
            continue
        cid = e.get("id")
        if not cid:
            continue
        c = calls.setdefault(cid, {"id": cid, "tier": e.get("tier"), "turn_id": e.get("turn_id"), "t": {}})
        c["t"].setdefault(e["stage"], e["t"])
        if e["stage"] == "done":
            for k in ("usage", "hedged", "winner_lane", "new_connection", "error", "discarded", "cost_usd", "stop_reason"):
                c[k] = e.get(k)
        if e["stage"] == "fire":
            c["words"] = e.get("words")
    turn_recv = {e["turn_id"]: e["t"] for _, e in events if e.get("type") == "metric" and e.get("stage") == "turn_recv"}
    selected = {e["id"] for _, e in events if e.get("type") == "select"}
    skipped = {e["turn_id"] for _, e in events if e.get("type") == "metric" and e.get("stage") == "d_skipped"}
    ms = lambda a, b: round((a - b) * 1000, 1) if a is not None and b is not None else None  # noqa: E731

    rows = []
    for c in calls.values():
        t = c["t"]
        tr = turn_recv.get(c["turn_id"])
        line_key = "first_point" if c["tier"] in ("D", "A") else "say_line"
        vis = t.get("release") or t.get("visible")
        row = {
            "id": c["id"], "tier": c["tier"], "turn_id": c["turn_id"], "words": c.get("words"),
            "selected": c["id"] in selected, "discarded": c.get("discarded"), "error": c.get("error"),
            "hedged": c.get("hedged"), "winner_lane": c.get("winner_lane"), "new_connection": c.get("new_connection"), "stop_reason": c.get("stop_reason"),
            "fire_before_turn_ms": ms(tr, t.get("fire")) if tr else None,
            "req_to_first_byte_ms": ms(t.get("first_byte"), t.get("fire")),
            "req_to_first_delta_ms": ms(t.get("first_delta"), t.get("fire")),
            "req_to_first_line_ms": ms(t.get(line_key), t.get("fire")),
            "turn_to_visible_ms": ms(vis, tr) if vis and tr else None,
            "turn_to_line_visible_ms": ms(max(vis, t[line_key]), tr) if vis and tr and t.get(line_key) else None,
            "usage": c.get("usage"), "cost_usd": c.get("cost_usd"),
        }
        rows.append(row)
    rows.sort(key=lambda r: (r["turn_id"] or "", r["id"]))

    def summary(sel, key):
        vals = [r[key] for r in rows if sel(r) and r[key] is not None]
        return {"n": len(vals), "p50": pct(vals, 0.5), "p90": pct(vals, 0.9), "max": max(vals) if vals else None}

    tiers = {
        "S_selected": lambda r: r["tier"] == "S" and r["selected"],
        "S_all": lambda r: r["tier"] == "S",
        "F": lambda r: r["tier"] == "F",
        "D": lambda r: r["tier"] == "D" and not r["discarded"],
        "D_all": lambda r: r["tier"] == "D",
    }
    keys = ["req_to_first_byte_ms", "req_to_first_delta_ms", "req_to_first_line_ms", "turn_to_visible_ms",
            "turn_to_line_visible_ms"]
    tier_summary = {name: {k: summary(sel, k) for k in keys} for name, sel in tiers.items()}
    # the opener the user sees first per answered turn (S selected or F)
    fast_turn = {}
    for r in rows:
        if r["tier"] in ("S", "F") and (r["selected"] or r["tier"] == "F") and r["turn_to_line_visible_ms"] is not None:
            fast_turn[r["turn_id"]] = min(fast_turn.get(r["turn_id"], 1e9), r["turn_to_line_visible_ms"])
    fv = list(fast_turn.values())
    tier_summary["opener_visible_per_turn"] = {"n": len(fv), "p50": pct(fv, 0.5), "p90": pct(fv, 0.9),
                                               "max": max(fv) if fv else None}

    with_usage = [r for r in rows if r["usage"]]
    cache_reads_after_first = [r["usage"].get("cache_read_input_tokens", 0) for r in with_usage]
    spend = sum(r["cost_usd"] or 0 for r in rows) + sum(w.get("cost_usd") or 0 for w in warm)
    statuses = [e for _, e in events if e.get("type") == "status"]
    actions = [e for _, e in events if e.get("type") == "actions"]
    summaries = [e for _, e in events if e.get("type") == "summary"]
    sum_calls = [r for r in rows if r["tier"] in ("R", "A")]
    result = {
        "session": str(session),
        "note": "t=0 is the moment the replay sent `turn` (ASR lag and endpoint decision excluded); "
                "req_* are from request start; turn_* from turn receipt in the brain.",
        "summary": tier_summary,
        "cache": {
            "prewarm_and_keepalive": [{"stage": w["stage"], "model": w.get("model"), "usage": w.get("usage")} for w in warm],
            "calls_with_usage": len(with_usage),
            "calls_with_cache_read_gt0": sum(1 for v in cache_reads_after_first if v > 0),
            "cache_read_tokens_total": sum(cache_reads_after_first),
            "cache_write_tokens_calls": sum(r["usage"].get("cache_creation_input_tokens", 0) for r in with_usage),
        },
        "hedges_fired": sum(1 for r in rows if r["hedged"]),
        "new_connections_on_calls": sum(1 for r in rows if r["new_connection"]),
        "d_skipped_turns": sorted(skipped),
        "d_early": {"fired": [r["id"] for r in rows if r["tier"] == "D" and (r["fire_before_turn_ms"] or 0) > 0],
                    "confirmed": sorted(e["turn_id"] for _, e in events if e.get("stage") == "d_confirmed"),
                    "dropped": sorted(e["turn_id"] for _, e in events if e.get("stage") == "d_early_dropped")},
        "f_turns": sorted({r["turn_id"] for r in rows if r["tier"] == "F"}),
        "errors": [r for r in rows if r["error"]],
        "statuses": statuses,
        "actions": actions,
        "summary_events": summaries,
        "summary_calls": [{k: r[k] for k in ("id", "tier", "turn_id", "req_to_first_byte_ms", "req_to_first_delta_ms", "usage",
                                              "cost_usd", "error", "stop_reason", "discarded")} for r in sum_calls],
        "summary_spend_usd": round(sum(r["cost_usd"] or 0 for r in sum_calls), 6),
        "spend_usd": round(spend, 6),
        "turns": turn_log,
        "calls": rows,
        "bad_lines": [e for _, e in events if e.get("type") == "_bad"],
        "events": [dict(e, _recv=round(t, 4)) for t, e in events],
    }
    return result


def print_table(res: dict) -> None:
    s = res["summary"]
    print(f"{'tier':<24}{'metric':<26}{'n':>4}{'p50 ms':>10}{'p90 ms':>10}{'max ms':>10}")
    for tier in ("S_selected", "S_all", "F", "D", "D_all"):
        for k in ("req_to_first_delta_ms", "req_to_first_line_ms", "turn_to_visible_ms", "turn_to_line_visible_ms"):
            v = s[tier][k]
            if v["n"]:
                f = lambda x: f"{x:.0f}" if x is not None else "-"  # noqa: E731
                print(f"{tier:<24}{k:<26}{v['n']:>4}{f(v['p50']):>10}{f(v['p90']):>10}{f(v['max']):>10}")
    v = s["opener_visible_per_turn"]
    print(f"{'opener per turn (S|F)':<24}{'turn_to_line_visible_ms':<26}{v['n']:>4}{v['p50'] or 0:>10.0f}{v['p90'] or 0:>10.0f}")
    c = res["cache"]
    print(f"cache: {c['calls_with_cache_read_gt0']}/{c['calls_with_usage']} calls read the cache, "
          f"{c['cache_read_tokens_total']} read tokens; warm-ups: " +
          ", ".join(f"{w['stage']} {w['model']} write={w['usage'].get('cache_creation_input_tokens')} "
                    f"read={w['usage'].get('cache_read_input_tokens')}" for w in c["prewarm_and_keepalive"]))
    sc = res["summary_calls"]
    fin = [e for e in res["summary_events"] if e.get("final") is not None]
    print(f"summary: {sum(1 for c in sc if c['tier'] == 'R')} rolling + {sum(1 for c in sc if c['tier'] == 'A')} final call(s), "
          f"${res['summary_spend_usd']:.4f}; cache read per call: " +
          ", ".join(f"{c['id']}={(c['usage'] or {}).get('cache_read_input_tokens')}" for c in sc) +
          (f"; final merge {res.get('summarize_s')} s, path {fin[-1].get('path')}" if fin else "; no final summary event"))
    print(f"hedges fired: {res['hedges_fired']} | new connections on calls: {res['new_connections_on_calls']} | "
          f"D skipped: {res['d_skipped_turns']} | early D: {res['d_early']} | F turns: {res['f_turns']} | errors: {len(res['errors'])} | spend: ${res['spend_usd']:.4f}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m verse_brain.runtime.replay", description=__doc__)
    ap.add_argument("--live", action="store_true", help="run against the real API (budget < $0.30, hard stop $1)")
    ap.add_argument("--session", type=Path, help="P1-1 session folder")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--word-ms", type=int, default=300)
    ap.add_argument("--budget-usd", type=float, default=1.0)
    ap.add_argument("--fake", action="store_true", help="dry run of the harness against the fake transport")
    a = ap.parse_args(argv)
    if a.live == a.fake:
        ap.error("pass exactly one of --live or --fake")
    if a.session is None:
        ap.error("--session is required")
    res = run_live(a.session.expanduser(), a.out, a.word_ms, min(a.budget_usd, 1.0), fake=a.fake)
    a.out.write_text(json.dumps(res, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print_table(res)
    print(f"wrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
