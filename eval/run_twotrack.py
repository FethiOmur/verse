#!/usr/bin/env python3
"""Two-track replay: a remote track and a "me" track side by side through `verse-run --file ... --me-file ...`.

    VERSE_EVAL_OUT=/some/scratch python run_twotrack.py --fixture t01 --name clean
    python run_twotrack.py --fixture t01 --name bleed25 --bleed-db 25 --bleed-delay-ms 40 --noise-dbfs -55      # silent Alex
    python run_twotrack.py --fixture t01 --name bleed25own --bleed-db 25 --bleed-delay-ms 40 --with-own           # Alex talks too
    python run_twotrack.py --fixture t01 --name x --bleed-db 25 --no-bleed-gate --no-echo-guard                  # defenses off

Without --bleed-db the me track is the owner's speech alone (item 1: me-channel replay). With it, the me track is the remote track
attenuated by that many dB, delayed, plus room noise (item 2), and the owner's speech only with --with-own.
Default brain: fake (no network, no spend). Output: $VERSE_EVAL_OUT/twotrack/<name>.{jsonl,meta.json,stderr.log,score.json}.
Audio lives in a temp dir that is removed after the run.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import audio  # noqa: E402
import checks  # noqa: E402
import run_replay as RR  # noqa: E402
import score_twotrack as ST  # noqa: E402
import twotrack  # noqa: E402
from paths import OUT  # noqa: E402


def build_command(a, fixture: dict, remote: Path, me: Path, session: Path, others: list[str]) -> list[str]:
    cmd = [str(Path(a.verse_run).expanduser()), "--session", str(session), "--lang", "en", "--file", str(remote), "--me-file", str(me),
           "--format", "json", "--echo", "--trace", "--owner", fixture["owner"], "--others", ",".join(others),
           "--budget-usd", f"{a.budget_usd:.2f}"]
    if not a.live_brain:
        cmd.append("--fake-brain")
    if a.no_bleed_gate:
        cmd.append("--no-bleed-gate")
    if a.no_echo_guard:
        cmd.append("--no-echo-guard")
    return cmd


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fixture", default="t01")
    ap.add_argument("--name", required=True)
    ap.add_argument("--verse-run", default=str(RR.DEFAULT_RUN))
    ap.add_argument("--brain-dir")
    ap.add_argument("--session", default=str(RR.DEFAULT_SESSION))
    ap.add_argument("--lead-in", type=float, default=25.0, help="silence before the first utterance (the English engine loads in it)")
    ap.add_argument("--live-brain", action="store_true", help="use the live brain (spends); default is the fake brain")
    ap.add_argument("--budget-usd", type=float, default=0.25)
    ap.add_argument("--bleed-db", type=float, help="me track = remote track attenuated by this many dB (speaker bleed)")
    ap.add_argument("--bleed-delay-ms", type=float, default=40.0)
    ap.add_argument("--noise-dbfs", type=float, default=-55.0, help="room noise RMS on the me track (dBFS); 'none' via --no-noise")
    ap.add_argument("--no-noise", action="store_true")
    ap.add_argument("--with-own", action="store_true", help="the owner's own speech on the me track next to the bleed")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--no-bleed-gate", action="store_true")
    ap.add_argument("--no-echo-guard", action="store_true")
    ap.add_argument("--timeout", type=float, default=300)
    ap.add_argument("--ack-text", default=ST.ACK_DEFAULT)
    a = ap.parse_args()

    fixture = twotrack.load(a.fixture)
    brain = RR.brain_dir_arg(a.brain_dir)
    verse_run = Path(a.verse_run).expanduser()
    if not verse_run.exists():
        sys.exit(f"{verse_run} not found: cd app && swift build -c release")
    out_dir = OUT / "twotrack"
    out_dir.mkdir(parents=True, exist_ok=True)
    jsonl, stderr_log = out_dir / f"{a.name}.jsonl", out_dir / f"{a.name}.stderr.log"

    wd = audio.make_workdir()
    try:
        sess = wd / "session"
        shutil.copytree(Path(a.session).expanduser(), sess)
        t_render = time.time()
        rend = twotrack.render(fixture, wd, lead_in=a.lead_in)
        bleed_info = None
        if a.bleed_db is not None:
            bleed_path = wd / "mic.wav"
            bleed_info = twotrack.bleed_wav(rend.remote_path, rend.me_path if a.with_own else None, bleed_path, a.bleed_db,
                                            a.bleed_delay_ms, None if a.no_noise else a.noise_dbfs, a.seed)
            me_path = bleed_path
        else:
            me_path = rend.me_path
        others = list(fixture["participants"])
        cmd = build_command(a, fixture, rend.remote_path, me_path, sess, others)
        env = {**os.environ, "VERSE_BRAIN_DIR": brain}
        watch = checks.AudioWatch([sess, Path("~/Library/Application Support/Verse").expanduser() / "sessions",
                                   Path(brain) / "tests" / "out"])
        load0 = checks.loadavg()
        watch.start()
        t0 = time.time()
        try:
            res = RR.run_verse(cmd, jsonl, stderr_log, env, a.timeout)
        finally:
            fswatch = watch.stop()
        meta = {"name": a.name, "fixture": fixture["id"], "lead_in_s": a.lead_in, "duration_s": round(rend.duration, 2),
                "timeline": rend.timeline, "wall_start": round(t0, 3), "render_s": round(t0 - t_render, 2),
                "elapsed_s": round(time.time() - t0, 2), "loadavg_before": load0, "loadavg_after": checks.loadavg(),
                "exit_code": res["exit_code"], "timed_out": res["timed_out"], "engine": res["engine"], "lines": res["lines"],
                "fake_brain": not a.live_brain, "bleed": bleed_info, "owner_silent": bleed_info is not None and not a.with_own, "bleed_gate": not a.no_bleed_gate,
                "echo_guard": not a.no_echo_guard, "audio_watch": fswatch}
    finally:
        removed = audio.remove_workdir(wd)
    meta["temp_audio_removed"] = removed
    (out_dir / f"{a.name}.meta.json").write_text(json.dumps(meta, indent=1) + "\n")
    scored = ST.score(fixture, ST.load_events(jsonl), meta, a.ack_text, stderr_log)
    (out_dir / f"{a.name}.score.json").write_text(json.dumps(scored, indent=1, ensure_ascii=False) + "\n")
    switch = [e.get("switchAtSec") for e in res["engine"] if e.get("state") == "engine_switch"]
    print(f"[{a.name}] exit {res['exit_code']}, {res['lines']} lines, load {meta['loadavg_before'][0]}->{meta['loadavg_after'][0]}, "
          f"engine switches at {switch}, audio watch {'clean' if fswatch['pass'] else 'FOUND ' + str(fswatch['audio_files_found'])}, "
          f"temp audio removed {removed}")
    if bleed_info:
        print(f"  bleed: {bleed_info}")
    print(ST.table(scored))
    return 0 if res["exit_code"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
