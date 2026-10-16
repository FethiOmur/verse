"""Test and tuning helpers for runtime/follow.py: a synchronous embedding driver, a fake clock and a speech-stream
simulation (words arriving in recognizer-sized chunks). The engine does not import this module.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable

from .embed import PREFIX
from .follow import Diverged, Effect, Embedder, FollowMachine, FollowParams, NeedEmbed, Refresh, is_content, score_matrix, tokenize, unit


class Clock:
    def __init__(self, t: float = 0.0) -> None:
        self.t = t

    def __call__(self) -> float:
        return self.t


class SyncDriver:
    """Answers the machine's NeedEmbed requests at once, with `embedder` (the real model or a fake)."""

    def __init__(self, machine: FollowMachine, embedder: Embedder | None, pack: list[str] | None = None,
                 cache: dict[str, list[float]] | None = None) -> None:
        self.m = machine
        self.e = embedder
        self.pack = pack or []
        self.cache: dict[str, list[float]] = cache if cache is not None else {}
        self.requests = 0

    def pump(self, sink: Callable[[Effect], None], now: float | None = None) -> None:
        """Move effects to `sink`; resolve embedding requests (newest first) until none is left."""
        while True:
            fx = self.m.drain()
            req = None
            for e in fx:
                if isinstance(e, NeedEmbed):
                    req = e
                else:
                    sink(e)
            if req is None or self.e is None:
                return
            self.requests += 1
            scores, others = score_matrix(self.e.embed, req, self.cache, PREFIX, self.pack)
            self.m.on_embed(req.seq, scores, others if self.pack else None, now=now)


@dataclass
class Event:
    t: float
    fx: Effect


@dataclass
class Run:
    events: list[Event] = field(default_factory=list)
    machine: FollowMachine | None = None
    embed_requests: int = 0
    trace: list[dict] = field(default_factory=list)       # per chunk: t, tokens, unmatched, best embed

    def of(self, cls) -> list[Event]:
        return [e for e in self.events if isinstance(e.fx, cls)]

    def first(self, cls) -> Event | None:
        xs = self.of(cls)
        return xs[0] if xs else None


def chunks(text: str, wps: float = 2.7, chunk_s: float = 0.56, start: float = 0.0) -> list[tuple[float, str]]:
    """(arrival time, cumulative text) as a streaming recognizer would deliver `text`: words at `wps` per second, one
    update per `chunk_s` (Nemotron streaming chunks are 560 ms)."""
    words = text.split()
    out: list[tuple[float, str]] = []
    n = len(words)
    k = 0
    t = start
    while k < n:
        t += chunk_s
        upto = min(n, int((t - start) * wps + 1e-9))
        if upto > k:
            k = upto
            out.append((round(t, 3), " ".join(words[:k])))
    return out


def make_machine(card: dict, params: FollowParams | None, embedder: Embedder | None, clock: Clock,
                 card_id: str = "f0001", tier: str = "F", pack: list[str] | None = None,
                 cache: dict[str, list[float]] | None = None) -> tuple[FollowMachine, SyncDriver]:
    m = FollowMachine(params, clock, embed_ok=embedder is not None)
    m.new_turn("q1")
    m.add_line(card_id, tier, "say", card["say"])
    for p in card["points"]:
        m.add_line(card_id, tier, "point", p)
    return m, SyncDriver(m, embedder, pack, cache)


def simulate(card: dict, text: str, *, params: FollowParams | None = None, embedder: Embedder | None = None,
             wps: float = 2.7, chunk_s: float = 0.56, tail_s: float = 3.0, turn_id: str = "m1",
             machine: tuple[FollowMachine, SyncDriver] | None = None, clock: Clock | None = None, pack: list[str] | None = None,
             cache: dict[str, list[float]] | None = None,
             start: float = 0.0, final: bool = True, step_s: float = 0.1) -> Run:
    """Feed `text` to a fresh machine (or the given one) as a stream, then let `tail_s` of silence pass in `step_s` ticks."""
    clock = clock or Clock(start)
    m, drv = machine or make_machine(card, params, embedder, clock, pack=pack, cache=cache)
    run = Run(machine=m)

    def sink(fx: Effect) -> None:
        run.events.append(Event(clock.t, fx))

    last_t = start
    for t, part in chunks(text, wps, chunk_s, start):
        clock.t = t
        m.on_me(turn_id, part, False)
        drv.pump(sink, now=t)
        m.tick()
        drv.pump(sink, now=t)
        run.trace.append({"t": t, "words": len(part.split()), "embed": m.last_embed})
        last_t = t
    if final:
        clock.t = last_t + 0.05
        m.on_me(turn_id, text, True)
        drv.pump(sink)
    t = clock.t
    while t < last_t + tail_s:
        t = round(t + step_s, 3)
        clock.t = t
        m.tick()
        drv.pump(sink)
    run.embed_requests = drv.requests
    return run


def content_count(text: str) -> int:
    return sum(1 for w in tokenize(text) if is_content(w))
