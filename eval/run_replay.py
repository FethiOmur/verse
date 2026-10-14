#!/usr/bin/env python3
"""Replay runner: builds each dialogue's audio in a temp dir, runs the worktree's release `verse-run --file`, and
records every stdout line with its wall time.

    VERSE_BRAIN_DIR=/path/to/Verse/brain python run_replay.py --run live1                # all 12, live brain
    python run_replay.py --run dev --dialogues d01 --fake-brain                          # plumbing only, no network

Output: eval/out/<run>/<id>.jsonl   {"wall": epoch seconds, "line": {...verse-run's JSON object...}}
        eval/out/<run>/<id>.meta.json  timeline actually rendered, engine status, load average, file checks, exit code
        eval/out/<run>/<id>.stderr.log verse-run's stderr (brain logs included)
        eval/out/spend.json            running ledger of live spend (the $1.50 cap for the whole package)

Audio exists only inside a temp dir that is removed after each dialogue; the API key is never read here (the brain reads
the Keychain itself).
"""

from __future__ import annotations

import argparse
import atexit
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import audio  # noqa: E402
import checks  # noqa: E402
import labels  # noqa: E402

REPO = HERE.parent
DEFAULT_RUN = REPO / "app/.build/release/verse-run"
DEFAULT_SESSION = Path("~/Library/Application Support/Verse/sessions/sample-interview").expanduser()
from paths import LEDGER, OUT  # noqa: E402
TOTAL_CAP_USD = 1.50

_children: list[subprocess.Popen] = []


def _kill_children() -> None:
    for p in _children:
        if p.poll() is None:
            try:
                p.terminate()
            except OSError:
                pass
    deadline = time.time() + 8
    for p in _children:
        while p.poll() is None and time.time() < deadline:
            time.sleep(0.1)
        if p.poll() is None:
            try:
                p.kill()
            except OSError:
                pass


atexit.register(_kill_children)
for _sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(_sig, lambda s, f: (_kill_children(), os._exit(130)))


def ledger_total() -> float:
    f = LEDGER
    if not f.exists():
        return 0.0
    return round(sum(e.get("usd", 0.0) for e in json.loads(f.read_text())["entries"]), 6)


def ledger_add(run: str, what: str, usd: float) -> None:
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    f = LEDGER
    d = json.loads(f.read_text()) if f.exists() else {"cap_usd": TOTAL_CAP_USD, "entries": []}
    d["entries"].append({"run": run, "what": what, "usd": round(usd, 6)})
    d["total_usd"] = round(sum(e["usd"] for e in d["entries"]), 6)
    f.write_text(json.dumps(d, indent=1) + "\n")


def brain_dir_arg(explicit: str | None) -> str:
    b = explicit or os.environ.get("VERSE_BRAIN_DIR")
    if not b:
        sys.exit("set VERSE_BRAIN_DIR or pass --brain-dir (the main checkout's brain/ folder)")
    return str(Path(b).expanduser())


def tree_listing(root: Path) -> dict[str, tuple[int, float]]:
    return {str(p.relative_to(root)): (p.stat().st_size, p.stat().st_mtime) for p in sorted(root.rglob("*")) if p.is_file()}


def run_verse(cmd: list[str], jsonl: Path, stderr_log: Path, env: dict, timeout: float) -> dict:
    """Runs verse-run, writing each stdout line with its wall time. Returns exit code, engine statuses, first/last line."""
    engine: list[dict] = []
    lines = 0
    with open(jsonl, "w", encoding="utf-8") as out, open(stderr_log, "w", encoding="utf-8") as err:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, bufsize=1)
        _children.append(p)

        def pump_err() -> None:
            for ln in p.stderr:  # type: ignore[union-attr]
                err.write(ln)
                err.flush()
                if '"state"' in ln and "engine" in ln:
                    try:
                        o = json.loads(ln)
                        if o.get("state", "").startswith("engine_"):
                            o["wall"] = time.time()
                            engine.append(o)
                    except json.JSONDecodeError:
                        pass

        t = threading.Thread(target=pump_err, daemon=True)
        t.start()
        started = time.time()
        timed_out = False

        def watchdog() -> None:
            nonlocal timed_out
            while p.poll() is None:
                if time.time() - started > timeout:
                    timed_out = True
                    p.send_signal(signal.SIGINT)
                    time.sleep(8)
                    if p.poll() is None:
                        p.kill()
                    return
                time.sleep(0.5)

        threading.Thread(target=watchdog, daemon=True).start()
        for ln in p.stdout:  # type: ignore[union-attr]
            w = time.time()
            ln = ln.strip()
            if not ln:
                continue
            try:
                obj = json.loads(ln)
            except json.JSONDecodeError:
                obj = {"type": "raw", "text": ln[:200]}
            out.write(json.dumps({"wall": round(w, 4), "line": obj}, ensure_ascii=False, separators=(",", ":")) + "\n")
            lines += 1
        code = p.wait()
        t.join(timeout=5)
    _children.remove(p)
    return {"exit_code": code, "engine": engine, "lines": lines, "timed_out": timed_out}


def jsonl_cost(path: Path) -> float:
    total = 0.0
    for ln in path.read_text(encoding="utf-8").splitlines():
        try:
            o = json.loads(ln)["line"]
        except (json.JSONDecodeError, KeyError):
            continue
        if o.get("type") == "metric" and isinstance(o.get("cost_usd"), (int, float)):
            total += o["cost_usd"]
    return total


def run_dialogue(a, d: dict, verse_run: Path, brain: str, session_src: Path, out_dir: Path, lead_in: float, budget: float) -> dict:
    """One dialogue: render the audio in a temp dir, run verse-run on it, delete the audio, return the run's metadata."""
    did = d["id"]
    wd = audio.make_workdir()
    sess = wd / "session"
    shutil.copytree(session_src, sess)
    utts = [{"speaker": u["speaker"], "text": u["text"], "gap_before": u.get("gap_before", 0.0),
             **({"silent_s": u["silent_s"]} if u.get("silent_s") else {})} for u in d["utterances"]]
    t_render = time.time()
    rend = audio.render(utts, d["voices"], wd, lead_in=lead_in)
    others = list(d["participants"])
    for n in list(others):
        others += d.get("name_variants", {}).get(n, [])
    cmd = [str(verse_run), "--session", str(sess), "--lang", "en", "--file", str(rend.path), "--format", "json", "--echo",
           "--owner", d["owner"], "--others", ",".join(others), "--budget-usd", f"{budget:.2f}"]
    if d.get("owner_aliases"):
        cmd += ["--alias", ",".join(d["owner_aliases"])]
    if a.fake_brain:
        cmd.append("--fake-brain")
    env = {**os.environ, "VERSE_BRAIN_DIR": brain}
    watch = checks.AudioWatch([sess, Path("~/Library/Application Support/Verse").expanduser() / "sessions", Path(brain) / "tests" / "out"])
    before = tree_listing(sess)
    load0 = checks.loadavg()
    watch.start()
    t0 = time.time()
    try:
        res = run_verse(cmd, out_dir / f"{did}.jsonl", out_dir / f"{did}.stderr.log", env, a.timeout)
    finally:
        fswatch = watch.stop()
    load1 = checks.loadavg()
    new_files = sorted(set(tree_listing(sess)) - set(before))
    wav_gone = audio.remove_workdir(wd)
    cost = jsonl_cost(out_dir / f"{did}.jsonl")
    meta = {
        "id": did, "lead_in_s": lead_in, "duration_s": round(rend.duration, 2), "timeline": rend.timeline,
        "wall_start": round(t0, 3), "render_s": round(t0 - t_render, 2), "elapsed_s": round(time.time() - t0, 2),
        "loadavg_before": load0, "loadavg_after": load1, "exit_code": res["exit_code"], "timed_out": res["timed_out"],
        "engine": res["engine"], "lines": res["lines"], "cost_usd": round(cost, 6), "fake_brain": a.fake_brain,
        "session_files_added": new_files, "audio_watch": fswatch, "temp_audio_removed": wav_gone,
        "others_passed": others, "budget_usd": budget,
    }
    (out_dir / f"{did}.meta.json").write_text(json.dumps(meta, indent=1) + "\n")
    return meta


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run", default=time.strftime("run-%Y%m%d-%H%M%S"))
    ap.add_argument("--dialogues", default="all", help="comma-separated ids, or all")
    ap.add_argument("--verse-run", default=str(DEFAULT_RUN))
    ap.add_argument("--brain-dir")
    ap.add_argument("--session", default=str(DEFAULT_SESSION), help="a P1-1 session folder; copied per dialogue")
    ap.add_argument("--fake-brain", action="store_true")
    ap.add_argument("--budget-usd", type=float, default=0.25, help="hard cap per dialogue, passed to the brain")
    ap.add_argument("--lead-in", default="auto", help="seconds of silence before the first utterance, or auto (engine load time + 3 s)")
    ap.add_argument("--timeout", type=float, default=400)
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()

    all_labels = {d["id"]: d for d in labels.load_all()}
    ids = list(all_labels) if a.dialogues == "all" else [x.strip() for x in a.dialogues.split(",")]
    if a.list:
        for i in ids:
            print(i)
        return 0
    brain = brain_dir_arg(a.brain_dir)
    verse_run = Path(a.verse_run).expanduser()
    if not verse_run.exists():
        sys.exit(f"{verse_run} not found: cd app && swift build -c release")
    session_src = Path(a.session).expanduser()
    out_dir = OUT / a.run
    out_dir.mkdir(parents=True, exist_ok=True)

    auto = a.lead_in == "auto"
    lead_in = 45.0 if auto else float(a.lead_in)   # silence first: the English engine takes this long to load under load

    run_spend = 0.0
    results = []
    for did in ids:
        d = all_labels[did]
        attempt = 1
        while True:
            remaining = TOTAL_CAP_USD - ledger_total()
            if not a.fake_brain and remaining < 0.05:
                print(f"stopping before {did}: the ${TOTAL_CAP_USD:.2f} cap is nearly used (${ledger_total():.3f})", flush=True)
                return finish(out_dir, a, ids, lead_in, run_spend, results)
            meta = run_dialogue(a, d, verse_run, brain, session_src, out_dir, lead_in, min(a.budget_usd, max(remaining - 0.03, 0.02)))
            run_spend += meta["cost_usd"]
            if not a.fake_brain:
                ledger_add(a.run, f"{did} attempt {attempt}", meta["cost_usd"])
            switch = [e.get("switchAtSec") for e in meta["engine"] if e.get("state") == "engine_switch" and e.get("switchAtSec") is not None]
            ready = [e.get("readyAtSec") for e in meta["engine"] if e.get("state") == "engine_ready" and e.get("readyAtSec") is not None]
            first_spoken = min((t["t_start"] for t in meta["timeline"] if not t["silent"]), default=0.0)
            warm = bool(switch) and max(switch) > first_spoken - 0.5
            print(f"{did}: exit {meta['exit_code']}, {meta['lines']} lines, ${meta['cost_usd']:.4f}, load {meta['loadavg_before'][0]}->{meta['loadavg_after'][0]}, "
                  f"engine ready {max(ready) if ready else 'never'} s (lead-in {lead_in:.0f} s), audio watch "
                  f"{'clean' if meta['audio_watch']['pass'] else 'FOUND ' + str(meta['audio_watch']['audio_files_found'])}, temp removed {meta['temp_audio_removed']}", flush=True)
            if auto and ready:
                nxt = min(max(max(ready) + 4.0, 10.0), 90.0)
            else:
                nxt = lead_in
            if warm and auto and attempt == 1 and meta["exit_code"] == 0:
                print(f"  the English engine took over at {max(switch):.1f} s, after speech had started; running {did} again with a longer lead-in", flush=True)
                for f in list(out_dir.glob(f"{did}.*")):
                    if ".try" not in f.name:
                        f.rename(out_dir / f.name.replace(f"{did}.", f"{did}.try1.", 1))
                lead_in = max(nxt, max(switch) + 5.0)
                attempt += 1
                continue
            lead_in = nxt
            results.append(meta)
            if meta["exit_code"] != 0:
                print(f"  {did} did not exit cleanly (code {meta['exit_code']}); see {out_dir / (did + '.stderr.log')}", flush=True)
            break
    return finish(out_dir, a, ids, lead_in, run_spend, results)


def finish(out_dir: Path, a, ids: list[str], lead_in: float, run_spend: float, results: list[dict]) -> int:
    (out_dir / "run.json").write_text(json.dumps({"run": a.run, "dialogues": [r["id"] for r in results], "requested": ids, "spend_usd": round(run_spend, 6),
                                                  "ledger_total_usd": ledger_total(), "fake_brain": a.fake_brain}, indent=1) + "\n")
    print(f"run {a.run}: spend ${run_spend:.4f}, ledger total ${ledger_total():.4f}")
    return 0 if all(r["exit_code"] == 0 for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
