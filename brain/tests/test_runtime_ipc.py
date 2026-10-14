"""The real process over pipes: every stdout line is flushed when emitted (read within 50 ms), stdin EOF and
`control stop` end the process. Runs `--fake` (no network, no key). Started without `-u`, so only the explicit
per-line flush can make this pass."""

from __future__ import annotations

import json
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

from test_runtime_helpers import session_copy

BRAIN = Path(__file__).resolve().parents[1]


def _spawn():
    env = dict(os.environ)
    env.pop("PYTHONUNBUFFERED", None)
    return subprocess.Popen([sys.executable, "-m", "verse_brain.runtime", "--fake"], cwd=BRAIN, env=env,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def _reader(p, q):
    for line in p.stdout:
        q.put((time.time(), line))
    q.put((time.time(), None))


def _send(p, msg: dict) -> None:
    p.stdin.write(json.dumps(msg) + "\n")
    p.stdin.flush()


def _collect(q, until: float) -> list[tuple[float, dict]]:
    out = []
    while time.time() < until:
        try:
            t, line = q.get(timeout=max(0.0, until - time.time()))
        except queue.Empty:
            break
        if line is None:
            break
        out.append((t, json.loads(line)))
    return out


def test_stdout_flush(tmp_path):
    sess = session_copy(tmp_path)
    p = _spawn()
    try:
        q: queue.Queue = queue.Queue()
        threading.Thread(target=_reader, args=(p, q), daemon=True).start()
        _send(p, {"type": "start", "session_dir": str(sess), "lang": "en"})
        got = _collect(q, time.time() + 10)
        while not any(e.get("state") == "ready" for _, e in got):
            more = _collect(q, time.time() + 5)
            assert more, "no ready status"
            got += more
        _send(p, {"type": "turn", "turn_id": "q1", "speaker": "remote", "text": "what did the pilot achieve?",
                  "addressee": "me", "t_audio_end": time.time()})
        got2 = _collect(q, time.time() + 1.0)  # the process is still running: nothing may wait for exit
        events = [e for _, e in got2]
        assert any(e["type"] == "delta" and e["tier"] == "F" for e in events)
        assert any(e["type"] == "delta" and e["tier"] == "D" for e in events)
        lags = [t_read - e["t"] for t_read, e in got + got2 if e["type"] == "metric"]
        assert lags and max(lags) < 0.050, max(lags)
        assert p.poll() is None
        _send(p, {"type": "control", "action": "stop"})
        assert p.wait(timeout=5) == 0
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)


def test_eof_exits_and_bad_lines_are_ignored():
    p = _spawn()
    try:
        p.stdin.write("not json\n{\"type\":\"nope\"}\n")
        p.stdin.flush()
        p.stdin.close()
        assert p.wait(timeout=5) == 0
        assert p.stdout.read() == ""
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)


def _until(q, pred, timeout: float) -> list[dict]:
    """Read events until one matches `pred`; returns everything read (empty list = timed out)."""
    seen: list[dict] = []
    end = time.time() + timeout
    while time.time() < end:
        try:
            _, line = q.get(timeout=max(0.0, end - time.time()))
        except queue.Empty:
            break
        if line is None:
            break
        seen.append(json.loads(line))
        if pred(seen[-1]):
            return seen
    return []


def test_summary_over_pipes(tmp_path):
    """Six finalized turns -> a `summary` event on the pipe; `control stop` writes summary.md and exits 0."""
    sess = session_copy(tmp_path)
    p = _spawn()
    try:
        q: queue.Queue = queue.Queue()
        threading.Thread(target=_reader, args=(p, q), daemon=True).start()
        _send(p, {"type": "start", "session_dir": str(sess), "lang": "en"})
        assert _until(q, lambda e: e.get("state") == "ready", 10), "no ready status"
        for i in range(3):
            _send(p, {"type": "turn", "turn_id": f"q{i}", "speaker": "remote", "text": f"question {i}?",
                      "addressee": "me", "t_audio_end": time.time()})
            time.sleep(0.4)
            _send(p, {"type": "turn", "turn_id": f"m{i}", "speaker": "me", "text": f"answer {i}",
                      "addressee": "unknown", "t_audio_end": time.time()})
        events = _until(q, lambda e: e["type"] == "summary", 5)
        assert events, "no summary event"
        s = [e for e in events if e["type"] == "summary"]
        assert s and s[0]["decisions"] and s[0]["actions"] and "final" not in s[0]
        assert any(e["type"] == "actions" and e["items"] for e in events)
        _send(p, {"type": "control", "action": "stop"})
        rest = _until(q, lambda e: e["type"] == "summary" and e.get("final") is not None, 5)
        assert p.wait(timeout=5) == 0
        fin = [e for e in rest if e["type"] == "summary" and e.get("final")]
        assert fin and fin[0]["path"] == str(sess / "summary.md")
        assert "## Actions" in (sess / "summary.md").read_text(encoding="utf-8")
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)
