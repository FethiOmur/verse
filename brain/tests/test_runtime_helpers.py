"""Shared helpers for the runtime tests (fake transport, list emitter, scripted timelines)."""

from __future__ import annotations

import asyncio
import shutil
from pathlib import Path

from verse_brain.runtime.engine import Brain
from verse_brain.runtime.fake import FakeTransport, Script, default_responder, lines_script
from verse_brain.runtime.protocol import ListEmitter
from verse_brain.runtime.settings import Config

FIX = Path(__file__).resolve().parent / "fixtures" / "runtime" / "session"

FAST_OK = "SAY: Sure, here is the short version.\n- I led Lantern.\n- It cut entry to 2 minutes.\nBANK: none"
DEEP_OK = "OPENER_OK\n- Lantern ran on supplier invoices (prep:L13)\n- Entry went from 11 to 2 minutes (f001)"


def make(responder=None, **cfg):
    t = FakeTransport(responder or default_responder)
    em = ListEmitter()
    b = Brain(t, em, Config(**cfg))
    b.start_background = False
    return b, t, em


def session_copy(tmp_path: Path) -> Path:
    """A writable copy of the fixture session (summary.md is written into the session folder)."""
    dst = tmp_path / "session"
    shutil.copytree(FIX, dst)
    return dst


async def start(b: Brain, session_dir: Path | None = None) -> None:
    await b.handle({"type": "start", "session_dir": str(session_dir or FIX), "lang": "en"})


async def partial(b: Brain, tid: str, text: str, cue: bool = True, speaker: str = "remote") -> None:
    await b.handle({"type": "partial", "turn_id": tid, "speaker": speaker, "text": text, "cue": cue, "t_audio_end": 0.0})


async def turn(b: Brain, tid: str, text: str, addressee: str = "me", speaker: str = "remote") -> None:
    await b.handle({"type": "turn", "turn_id": tid, "speaker": speaker, "text": text, "addressee": addressee,
                    "t_audio_end": 0.0})


async def speak(b: Brain, tid: str, words: list[str], every: float, cue: bool = True, step: int = 1) -> None:
    """Grow a partial `step` words at a time, one partial every `every` seconds."""
    for n in range(step, len(words) + 1, step):
        await partial(b, tid, " ".join(words[:n]), cue=cue)
        await asyncio.sleep(every)


async def settle(b: Brain, timeout: float = 5.0) -> None:
    """Wait until every call has finished and no policy task is pending."""
    loop = asyncio.get_running_loop()
    end = loop.time() + timeout
    while loop.time() < end:
        pending = [c for c in b.calls if not c.done.is_set()]
        tasks = [t for t in b.tasks if not t.done()]
        if not pending and not tasks:
            return
        await asyncio.sleep(0.02)
    raise AssertionError("brain did not settle")


def run(coro):
    return asyncio.run(coro)


def rolling_calls(t: FakeTransport) -> list:
    """Incremental-summary calls (they use the S route, so they are told apart by their tail)."""
    return [c for c in t.calls if c.tail.startswith("SUMMARIZE-INCREMENTAL")]


def final_calls(t: FakeTransport) -> list:
    return [c for c in t.calls if c.tail.startswith("SUMMARIZE-FINAL")]


async def exchange(b: Brain, i: int, t_end: float = 0.0) -> None:
    """One remote question, answered (settled), then the owner's reply: two finalized turns."""
    await b.handle({"type": "turn", "turn_id": f"r{i}", "speaker": "remote", "text": f"question {i} about Lantern?",
                    "addressee": "me", "t_audio_end": t_end})
    await settle(b)
    await b.handle({"type": "turn", "turn_id": f"m{i}", "speaker": "me", "text": f"answer {i} about Lantern",
                    "addressee": "unknown", "t_audio_end": t_end})


__all__ = ["FIX", "session_copy", "rolling_calls", "final_calls", "exchange", "FAST_OK", "DEEP_OK", "make", "start", "partial", "turn", "speak", "settle", "run", "Script",
           "lines_script"]
