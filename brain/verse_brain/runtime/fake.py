"""A scriptable fake transport (tests and `--fake` subprocess runs). No network, no key.

A responder decides each streamed call: `responder(info) -> Script`, where `info` has the call index, route,
lane, model and the tail text of the request. Every request is recorded, so tests can assert on prefixes.
"""

from __future__ import annotations

import asyncio
import copy
import re
import time
from dataclasses import dataclass, field
from typing import Callable

from .transport import Ev, TransportError


@dataclass
class Script:
    first_byte_delay: float = 0.0
    chunks: list[tuple[float, str]] = field(default_factory=list)   # (delay before chunk, text)
    stop_reason: str = "end_turn"
    error: TransportError | None = None        # raised before the first byte (after first_byte_delay)
    usage: dict = field(default_factory=lambda: {"input_tokens": 50, "output_tokens": 30,
                                                 "cache_read_input_tokens": 4000, "cache_creation_input_tokens": 0})
    headers: dict = field(default_factory=dict)


def lines_script(text: str, *, first_byte_delay: float = 0.0, per_chunk: float = 0.0, **kw) -> Script:
    """Stream `text` word by word (each word with its leading space; newlines as their own chunks)."""
    pieces = re.findall(r" ?[^ \n]+|\n", text)
    return Script(first_byte_delay=first_byte_delay, chunks=[(per_chunk, p) for p in pieces], **kw)


@dataclass
class CallInfo:
    index: int
    route: str
    lane: int
    model: str
    tail: str
    request: dict
    t_open: float


def _tail(request: dict) -> str:
    try:
        return request["messages"][-1]["content"][-1]["text"]
    except (KeyError, IndexError, TypeError):
        return ""


class FakeStream:
    def __init__(self, script: Script, info: CallInfo, transport: "FakeTransport") -> None:
        self.script = script
        self.info = info
        self.headers = dict(script.headers)
        self.new_connection = False
        self.closed = False
        self._t = transport

    async def __aiter__(self):
        s = self.script
        try:
            yield Ev("start", usage={k: v for k, v in s.usage.items() if k != "output_tokens"})
            for delay, text in s.chunks:
                if delay:
                    await asyncio.sleep(delay)
                if self.closed:
                    return
                yield Ev("text", text=text)
            yield Ev("stop", stop_reason=s.stop_reason, usage=dict(s.usage))
        finally:
            pass

    async def aclose(self) -> None:
        if not self.closed:
            self.closed = True
            self._t.closed.append(self.info.index)
            self._t._end(self.info)


class FakeTransport:
    def __init__(self, responder: Callable[[CallInfo], Script] | None = None) -> None:
        self.responder = responder or default_responder
        self.calls: list[CallInfo] = []
        self.creates: list[dict] = []
        self.pings: list[tuple[str, int]] = []
        self.closed: list[int] = []
        self.open_streams: list[FakeStream] = []
        self.active: dict[int, str] = {}
        self.max_inflight: dict[str, int] = {}
        self.cancelled: list[int] = []

    async def open_stream(self, route: str, request: dict, lane: int) -> FakeStream:
        info = CallInfo(len(self.calls), route, lane, request["model"], _tail(request), copy.deepcopy(request),
                        time.monotonic())
        self.calls.append(info)
        self.active[info.index] = route
        n = sum(1 for r in self.active.values() if r == route)
        self.max_inflight[route] = max(self.max_inflight.get(route, 0), n)
        script = self.responder(info)
        try:
            if script.first_byte_delay:
                await asyncio.sleep(script.first_byte_delay)
        except asyncio.CancelledError:
            self.cancelled.append(info.index)
            self._end(info)
            raise
        if script.error is not None:
            self._end(info)
            raise script.error
        st = FakeStream(script, info, self)
        self.open_streams.append(st)
        return st

    def _end(self, info: CallInfo) -> None:
        self.active.pop(info.index, None)

    async def create(self, route: str, request: dict, lane: int):
        self.creates.append({"route": route, "lane": lane, "request": copy.deepcopy(request)})
        return ({"input_tokens": 10, "output_tokens": 0, "cache_read_input_tokens": 0,
                 "cache_creation_input_tokens": 4000}, {}, "max_tokens")

    async def ping(self, model: str, lane: int) -> dict:
        self.pings.append((model, lane))
        return {"ms": 1.0, "headers": {}}

    async def aclose(self) -> None:
        pass

    def by_route(self, route: str) -> list[CallInfo]:
        return [c for c in self.calls if c.route == route]


ROLLING_CANNED = ("DECISION: Start the pilot with one depot in shadow mode\n"
                  "ACTION: Alex — share the pilot plan by Friday\nOPEN: Who approves the budget?")
FINAL_CANNED = ("SUMMARY: The pilot starts with one depot in shadow mode; the budget owner is still open.\n"
                "DECISION: Start the pilot with one depot in shadow mode\n"
                "ACTION: Alex — share the pilot plan by Friday\nOPEN: Who approves the budget?\n"
                "CONFLICT: Said entry takes 3 minutes; the fact sheet says 2 minutes (f001)")


FOLLOW_CANNED = ("SAY: And that is where I keep the model on a short leash.\n"
                 "- Fields below 0.8 confidence go to a human operator.\n- That was about 7 percent of invoices.")


CARD_NOW_CANNED = "SAY: Here is what I can say right now.\n- First point.\n- Second point.\nBANK: none"


def default_responder(info: CallInfo) -> Script:
    if "FOLLOW MY ANSWER" in info.tail:
        return lines_script(FOLLOW_CANNED)
    if info.tail.startswith("SUMMARIZE-INCREMENTAL"):
        return lines_script(ROLLING_CANNED)
    if info.tail.startswith("SUMMARIZE-FINAL"):
        return lines_script(FINAL_CANNED)
    if "STATEMENT CHECK" in info.tail:
        return lines_script("KIND: statement\nSAY: Thanks, noted.")
    if "CARD NOW." in info.tail and info.route != "D":
        return lines_script(CARD_NOW_CANNED)
    if info.route == "D":
        return lines_script("OPENER_OK\n- A detail point from the pack (prep:L1)\n- Another detail (f001)")
    return lines_script("SAY: Sure, here is the short answer.\n- First point.\n- Second point.\nBANK: none")


_BANK_ENTRY = re.compile(r"^\[(b\d+)\] Q \([a-z]+\): (.+)$")
_QUESTION_TAIL = re.compile(r"CURRENT QUESTION \([^)]*\):\s*(.*)\Z", re.S)


def _norm_q(q: str) -> str:
    return " ".join(re.sub(r"[^\w\s]", " ", q.lower()).split())


def bank_responder(info: CallInfo) -> Script:
    """`--fake-bank`: S/F answer a question from the pack's ANSWER BANK the way Haiku is told to (the entry's opener and its
    first two points, then `BANK: <id>`), so a replay with the canned transport shows a real card. Everything else is
    `default_responder`. A question that matches no entry gets the generic canned answer."""
    m = _QUESTION_TAIL.search(info.tail)
    if info.route in ("S", "F") and m and not info.tail.startswith(("SUMMARIZE", "STATEMENT")) and "STATEMENT CHECK" not in info.tail:
        want = _norm_q(m.group(1))
        try:
            pack = info.request["messages"][0]["content"][0]["text"]
        except (KeyError, IndexError, TypeError):
            pack = ""
        lines = pack.splitlines()
        for i, ln in enumerate(lines):
            e = _BANK_ENTRY.match(ln)
            if e and _norm_q(e.group(2)) == want:
                say, pts = None, []
                for body in lines[i + 1:]:
                    if body.startswith("[b") or not body.strip():
                        break
                    if body.startswith("SAY:") and say is None:
                        say = body
                    elif body.startswith("- "):
                        pts.append(body)
                if say:
                    return lines_script("\n".join([say, *pts[:2], f"BANK: {e.group(1)}"]))
    return default_responder(info)
