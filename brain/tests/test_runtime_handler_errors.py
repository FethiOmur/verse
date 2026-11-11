"""Review H4: an exception in a message handler must not end the brain. The main loop logs it, reports a non-fatal `status`
(reason `internal`, throttled) and keeps serving; a line without the `turn_id` its type needs is rejected by `parse_line`.
Runs the real process with `--fake` (no network, no key)."""

from __future__ import annotations

import json
import logging
import os
import subprocess
import sys
from pathlib import Path

import pytest
from test_runtime_helpers import FIX, run, session_copy, settle

from verse_brain.runtime.__main__ import HandlerGuard
from verse_brain.runtime.engine import Brain
from verse_brain.runtime.fake import FakeTransport, default_responder
from verse_brain.runtime.protocol import ListEmitter, parse_line
from verse_brain.runtime.settings import Config

BRAIN = Path(__file__).resolve().parents[1]


def _run(lines: list[dict], timeout: float = 30.0) -> tuple[int, list[dict], str]:
    env = dict(os.environ, VERSE_EVENTS="0")
    p = subprocess.run([sys.executable, "-u", "-m", "verse_brain.runtime", "--fake"], cwd=BRAIN, env=env,
                       input="".join(json.dumps(m) + "\n" for m in lines), capture_output=True, text=True, timeout=timeout)
    out = [json.loads(l) for l in p.stdout.splitlines() if l.strip()]
    return p.returncode, out, p.stderr


class _Boom(Brain):
    """A brain whose partial handler raises for one turn id (a stand-in for any bug in a handler path)."""

    def on_partial(self, msg: dict) -> None:
        if msg["turn_id"] == "boom":
            raise RuntimeError("handler bug")
        super().on_partial(msg)


def test_handler_guard_logs_reports_once_and_keeps_serving(caplog):
    em = ListEmitter()
    b = _Boom(FakeTransport(default_responder), em, Config())
    b.start_background = False
    guard = HandlerGuard(em)

    async def go():
        await guard.handle(b, {"type": "start", "session_dir": str(FIX), "lang": "en"})
        for _ in range(2):
            await guard.handle(b, {"type": "partial", "turn_id": "boom", "speaker": "remote", "text": "x", "cue": True, "t_audio_end": 0.0})
        await guard.handle(b, {"type": "turn", "turn_id": "r3", "speaker": "remote", "text": "what did the pilot achieve",
                               "addressee": "me", "t_audio_end": 3.0})
        await settle(b)

    with caplog.at_level(logging.WARNING, logger="verse.runtime"):
        run(go())
    internal = [e for e in em.of("status") if e.get("reason") == "internal"]
    assert len(internal) == 1, f"one throttled status for two failures: {internal}"
    assert internal[0]["state"] == "error" and "partial" in internal[0]["message"] and "RuntimeError" in internal[0]["message"]
    assert guard.count == 2
    assert any(e["turn_id"] == "r3" for e in em.of("delta")), "no answer after the handler error"
    assert "handler bug" in caplog.text and "again" in caplog.text   # traceback once, then a one-line warning


def test_null_text_does_not_end_the_brain_or_poison_the_transcript(tmp_path):
    sess = session_copy(tmp_path)
    code, out, err = _run([
        {"type": "start", "session_dir": str(sess), "lang": "en"},
        # `text: null` used to be stored in the transcript and then raise in every later request
        {"type": "turn", "turn_id": "r1", "speaker": "remote", "text": None, "addressee": "me", "t_audio_end": 1.0},
        {"type": "partial", "turn_id": "r3", "speaker": "remote", "text": "what did the pilot achieve", "cue": True, "t_audio_end": 3.0},
        {"type": "turn", "turn_id": "r3", "speaker": "remote", "text": "what did the pilot achieve", "addressee": "me", "t_audio_end": 3.0},
        {"type": "control", "action": "stop"},
    ])
    assert code == 0, err[-2000:]
    assert any(e.get("type") == "delta" and e.get("turn_id") == "r3" for e in out), "no answer after the bad line"


def test_partial_without_turn_id_is_rejected_not_fatal(tmp_path):
    sess = session_copy(tmp_path)
    code, out, err = _run([
        {"type": "start", "session_dir": str(sess), "lang": "en"},
        {"type": "partial", "speaker": "remote", "text": "no turn id here"},
        {"type": "turn", "turn_id": "r3", "speaker": "remote", "text": "what did the pilot achieve", "addressee": "me", "t_audio_end": 3.0},
        {"type": "control", "action": "stop"},
    ])
    assert code == 0, err[-2000:]
    assert any(e.get("type") == "delta" and e.get("turn_id") == "r3" for e in out)


@pytest.mark.parametrize("line", [
    '{"type":"partial","speaker":"remote","text":"x"}',
    '{"type":"turn","turn_id":7,"speaker":"remote","text":"x"}',
    '{"type":"bank_hit","bank_id":"b1","score":0.9}',
    '{"type":"turn","turn_id":"r1","speaker":"remote","text":null}',
])
def test_parse_line_requires_a_turn_id(line):
    with pytest.raises(ValueError):
        parse_line(line)


def test_parse_line_still_accepts_messages_without_turn_ids():
    assert parse_line('{"type":"control","action":"stop"}')["action"] == "stop"
    assert parse_line('{"type":"start","session_dir":"/x"}')["type"] == "start"


def test_turn_with_a_non_string_speaker_is_rejected():
    import json

    import pytest

    from verse_brain.runtime.protocol import parse_line

    for kind in ("turn", "partial"):
        with pytest.raises(ValueError):
            parse_line(json.dumps({"type": kind, "turn_id": "r1", "speaker": ["remote"], "text": "hi"}))
    assert parse_line(json.dumps({"type": "turn", "turn_id": "r1", "speaker": "remote", "text": "hi"}))["speaker"] == "remote"
