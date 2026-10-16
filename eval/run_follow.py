#!/usr/bin/env python3
"""Two-track replay straight into the Python brain, for follow-my-answer (no Swift, no speech recognizer).

    VERSE_EVAL_OUT=/scratch python run_follow.py --fixture t03 --name t03_fake --brain-dir ../brain            # fake brain
    python run_follow.py --fixture t03 --name t03_live --brain-dir ../brain --live --session /scratch/session   # real Haiku

Why not `run_twotrack.py`: that runs `verse-run`, which (until `verse-run --follow` exists in app/Sources/verse-run) starts the
brain with follow off and sends no `partial` for the owner's own speech. This runner plays the same fixtures (`eval/twotrack/t0N.json`)
and keeps what the follow tests need: real `say` voices fix the true acoustic start and end of every utterance (the audio is
rendered in a temp dir only for that and deleted at once), and the words of each utterance are then delivered to the brain the
way a streaming recognizer would: one cumulative `partial` per 560 ms chunk with the words that have been spoken, spread evenly
over the utterance, then a `turn` (remote: 0.35 s after the end, Alex: 1.2 s after, as the TurnEngine does). So the numbers include
the brain's own latency and a recognizer-sized delay but no recognition errors.

Output: $VERSE_EVAL_OUT/twotrack/<name>.{jsonl,meta.json,score.json,stderr.log}, the same files and the same scorer as run_twotrack.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import audio  # noqa: E402
import run_replay as RR  # noqa: E402
import score_twotrack as ST  # noqa: E402
import twotrack  # noqa: E402
from paths import OUT  # noqa: E402

CHUNK_S = 0.56
RECOGNIZER_LAG_S = 0.2
REMOTE_END_DELAY_S = 0.35
ME_END_DELAY_S = 1.2
QUESTION_WORDS = ("can", "could", "what", "how", "why", "when", "where", "who", "which", "do", "does", "did", "would", "tell")


def partials_for(text: str, t_start: float, t_end: float, chunk_s: float = CHUNK_S, lag_s: float = RECOGNIZER_LAG_S) -> list[tuple[float, str]]:
    """(file time, cumulative text) of a streaming recognizer for an utterance spoken over [t_start, t_end] with its words
    spread evenly: chunk k is emitted `lag_s` after k * chunk_s and holds the words that ended before that moment."""
    words = text.split()
    n = len(words)
    dur = max(t_end - t_start, 0.01)
    out: list[tuple[float, str]] = []
    k = 0
    last = 0
    while True:
        k += 1
        t = min(t_start + k * chunk_s + lag_s, t_end + lag_s)          # nothing arrives after the utterance's last word + lag
        upto = min(n, int((t - lag_s - t_start) / dur * n + 1e-9))
        if upto > last:
            out.append((round(t, 3), " ".join(words[:upto])))
            last = upto
        if upto >= n or t > t_end + chunk_s * 2:
            break
    if last < n:
        out.append((round(t_end + lag_s, 3), " ".join(words)))
    return out


def schedule(fixture: dict, timeline: list[dict], lead_in: float) -> list[tuple[float, dict]]:
    owner = fixture["owner"]
    msgs: list[tuple[float, dict]] = []
    rid = mid = 0
    for t in timeline:
        u = fixture["utterances"][t["index"]]
        text = u["text"]
        is_me = u["speaker"] == owner
        if is_me:
            mid += 1
            tid = f"m{mid}"
            for at, part in partials_for(text, t["t_start"], t["t_end"]):
                msgs.append((at, {"type": "partial", "turn_id": tid, "speaker": "me", "text": part, "cue": False, "t_audio_end": at}))
            end = t["t_end"] + ME_END_DELAY_S
            msgs.append((end, {"type": "turn", "turn_id": tid, "speaker": "me", "text": text, "addressee": "unknown",
                               "kind": "statement", "t_audio_end": round(t["t_end"], 3)}))
        else:
            rid += 1
            tid = f"r{rid}"
            q = text.rstrip().endswith("?") or text.lower().split()[0] in QUESTION_WORDS
            hit_sent = False
            for at, part in partials_for(text, t["t_start"], t["t_end"]):
                msgs.append((at, {"type": "partial", "turn_id": tid, "speaker": "remote", "text": part, "cue": q and len(part.split()) >= 3,
                                  "t_audio_end": at}))
                if u.get("bank_id") and not hit_sent and len(part.split()) >= len(text.split()) - 1:
                    msgs.append((at + 0.01, {"type": "bank_hit", "turn_id": tid, "bank_id": u["bank_id"], "score": 0.93}))
                    hit_sent = True
            end = t["t_end"] + REMOTE_END_DELAY_S
            msgs.append((end, {"type": "turn", "turn_id": tid, "speaker": "remote", "text": text, "addressee": "me",
                               "kind": "question" if q else "statement", "t_audio_end": round(t["t_end"], 3)}))
    msgs.sort(key=lambda m: m[0])
    return msgs


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fixture", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--brain-dir", default=os.environ.get("VERSE_BRAIN_DIR"))
    ap.add_argument("--session", default=str(Path("~/Library/Application Support/Verse/sessions/sample-interview").expanduser()))
    ap.add_argument("--live", action="store_true", help="the real brain (spends: Haiku calls on the session's pack)")
    ap.add_argument("--no-embed", action="store_true", help="fake brain without the embedding model (follow then never diverges: coverage only)")
    ap.add_argument("--no-follow", action="store_true", help="start with follow:false (the baseline)")
    ap.add_argument("--lead-in", type=float, default=3.0)
    ap.add_argument("--drain", type=float, default=8.0, help="seconds after the last message before `control stop`")
    ap.add_argument("--budget-usd", type=float, default=0.25)
    ap.add_argument("--ack-text", default=ST.ACK_DEFAULT)
    a = ap.parse_args()
    if not a.brain_dir:
        sys.exit("pass --brain-dir (the brain/ folder, with .venv)")
    brain = Path(a.brain_dir).expanduser().resolve()
    py = brain / ".venv/bin/python"
    fixture = twotrack.load(a.fixture)
    out_dir = OUT / "twotrack"
    out_dir.mkdir(parents=True, exist_ok=True)
    jsonl, stderr_log = out_dir / f"{a.name}.jsonl", out_dir / f"{a.name}.stderr.log"

    wd = audio.make_workdir()
    try:
        rend = twotrack.render(fixture, wd, lead_in=a.lead_in)
        sess = wd / "session"
        shutil.copytree(Path(a.session).expanduser(), sess)
        msgs = schedule(fixture, rend.timeline, a.lead_in)
        cmd = [str(py), "-u", "-m", "verse_brain.runtime", "--budget-usd", f"{a.budget_usd:.2f}"]
        if not a.live:
            cmd += ["--fake", "--fake-bank"] + ([] if a.no_embed else ["--embed"])
        env = {**os.environ, "PYTHONPATH": str(brain)}
        out_lines: list[tuple[float, str]] = []
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(stderr_log, "w"), text=True, bufsize=1,
                             cwd=str(brain), env=env)

        def pump() -> None:
            for ln in p.stdout:  # type: ignore[union-attr]
                out_lines.append((time.time(), ln.rstrip("\n")))

        th = threading.Thread(target=pump, daemon=True)
        th.start()

        def send(m: dict) -> None:
            out_lines.append((time.time(), json.dumps({**m, "dir": "to_brain"}, ensure_ascii=False)))
            p.stdin.write(json.dumps(m, ensure_ascii=False) + "\n")  # type: ignore[union-attr]
            p.stdin.flush()  # type: ignore[union-attr]

        send({"type": "start", "session_dir": str(sess), "lang": "en", "follow": not a.no_follow})
        t_ready = time.time()
        while time.time() - t_ready < 60:
            if any('"state":"ready"' in ln or '"state":"offline"' in ln for _, ln in out_lines):
                break
            time.sleep(0.05)
        time.sleep(1.5 if not a.live else 0.5)           # the embedding index and the pack vectors load in the background
        wall0 = time.time()
        out_lines.append((wall0, json.dumps({"type": "metric", "stage": "session_t0", "t": wall0, "origin_remote": 0.0, "origin_me": 0.0})))
        for at, m in msgs:
            wait = wall0 + at - time.time()
            if wait > 0:
                time.sleep(wait)
            send(m)
        time.sleep(a.drain)
        send({"type": "control", "action": "stop"})
        try:
            p.wait(timeout=60)
        except subprocess.TimeoutExpired:
            p.kill()
        th.join(timeout=5)
        elapsed = time.time() - wall0
        meta = {"name": a.name, "fixture": fixture["id"], "lead_in_s": a.lead_in, "duration_s": round(rend.duration, 2),
                "timeline": rend.timeline, "wall_start": round(wall0, 3), "elapsed_s": round(elapsed, 2), "exit_code": p.returncode,
                "fake_brain": not a.live, "embed": (a.live or not a.no_embed), "follow": not a.no_follow, "clock": "direct",
                "recognizer": f"synthetic: cumulative partials every {CHUNK_S} s (+{RECOGNIZER_LAG_S} s lag), words spread evenly over the say clip",
                "owner_silent": False}
    finally:
        audio.remove_workdir(wd)
    with open(jsonl, "w", encoding="utf-8") as f:
        for w, ln in out_lines:
            try:
                f.write(json.dumps({"wall": w, "line": json.loads(ln)}, ensure_ascii=False) + "\n")
            except json.JSONDecodeError:
                pass
    (out_dir / f"{a.name}.meta.json").write_text(json.dumps(meta, indent=1) + "\n")
    scored = ST.score(fixture, ST.load_events(jsonl), meta, a.ack_text, stderr_log)
    if a.live:           # the package's spend ledger (cap in run_replay.TOTAL_CAP_USD)
        usd = sum(o.get("cost_usd", 0.0) for _, o in ST.load_events(jsonl) if o.get("type") == "metric" and o.get("stage") in ("done", "prewarm", "keepalive"))
        RR.ledger_add(a.name, f"run_follow {fixture['id']} live", usd)
        print(f"  spend ${usd:.4f}; ledger total ${RR.ledger_total():.4f} of ${RR.TOTAL_CAP_USD:.2f}")
    (out_dir / f"{a.name}.score.json").write_text(json.dumps(scored, indent=1, ensure_ascii=False) + "\n")
    print(f"[{a.name}] exit {p.returncode}, {len(out_lines)} lines, {elapsed:.0f} s, "
          f"{'live' if a.live else 'fake'} brain, follow {'on' if not a.no_follow else 'off'}")
    print(ST.table(scored))
    return 0 if p.returncode == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
