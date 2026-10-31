"""CLI: python -u -m verse_brain.runtime [--budget-usd N] [--fake] [--no-embed]

One process serves one session, and its first message decides which: `start` runs the meeting runtime (engine.Brain),
`sim_start` the interview simulation (sim.SimRuntime, plan S2), `ask_start` the chat about one past session (ask.AskRuntime; its own
Anthropic client, built from the Keychain key by ask.make_client), `memory_ask_start` the chat across meetings
(memory_ask.MemoryAskRuntime, same client) and `brief_start` one pre-meeting brief (memory.brief.BriefRuntime, same client; it ends the
process), `memory_index_start` the writer of the memory index
(memory.indexer.IndexRuntime: no model calls; `--fake` embeds with the hash stand-in, `--no-embed` skips phase 2, and
`--no-api` serves only this mode without reading the Keychain). `--budget-usd` and the embedding matcher apply to
meetings only.

Reads Swift -> brain JSON lines on stdin, writes brain -> Swift JSON lines on stdout (flushed per line), logs to
stderr. Exits on `{"type":"control","action":"stop"}` or stdin EOF. `--fake` uses the canned fake transport
(no network, no key) for IPC tests; it also leaves the embedding matcher off (`--embed` loads it anyway and `--fake-bank`
answers S/F from the pack's answer bank: both for replays). `--no-embed` turns the F3 paraphrase
matcher (EmbeddingGemma, LiteRT-LM) off; without it the matcher loads at `start` and stays off by itself when
`litert_lm` or the model is missing.

Verse is online-only: there is no local model. With no connection, no API key or a rejected key the brain says so in a
`status` event with a `reason` (`no_connection`, `no_api_key`, `invalid_api_key`, `no_credit`; see runtime/engine.py).
`VERSE_SIMULATE_API=offline|rate_limited|overloaded|auth|credit` makes every API call fail (no key read, no network) to
exercise those messages live.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys

from .engine import NO_API_KEY, Brain
from .protocol import Emitter, parse_line
from .settings import Config
from .ask import AskRuntime
from .sim import SimRuntime, sim_fake_responder


async def _stdin_lines():
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(limit=1 << 22)
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
    while True:
        line = await reader.readline()
        if not line:
            return
        yield line.decode("utf-8", errors="replace")


def _index_runtime(args, emitter):
    from ..memory.indexer import IndexRuntime

    cfg = Config()
    return IndexRuntime(emitter, fake=args.fake, no_embed=args.no_embed, embed_model=cfg.embed_model,
                        embed_backend=cfg.embed_backend)


def _memory_runtime(kind, client, args, emitter, cfg):
    """`memory_ask_start` -> MemoryAskRuntime (runtime/memory_ask.py); `brief_start` -> BriefRuntime (memory/brief.py). Both read the
    index read-only and call Claude through the client from `ask.make_client`; `--fake` embeds with the hash stand-in and
    `--no-embed` searches with FTS only."""
    kw = dict(fake=args.fake, no_embed=args.no_embed, embed_model=cfg.embed_model, embed_backend=cfg.embed_backend)
    if kind == "memory_ask_start":
        from .memory_ask import MemoryAskRuntime

        return MemoryAskRuntime(client, emitter, **kw)
    from ..memory.brief import BriefRuntime

    return BriefRuntime(client, emitter, **kw)


async def _amain_index_only(args, emitter) -> int:
    """`--no-api`: a process that only writes the memory index. No Keychain read, no API client; any other first message is ignored."""
    runtime = None
    try:
        async for raw in _stdin_lines():
            try:
                msg = parse_line(raw)
            except (ValueError, json.JSONDecodeError) as e:
                logging.getLogger("verse.runtime").warning("bad input line: %s", type(e).__name__)
                continue
            if msg is None:
                continue
            if runtime is None:
                if msg.get("type") != "memory_index_start":
                    continue
                runtime = _index_runtime(args, emitter)
            await runtime.handle(msg)
            if runtime.stopped.is_set():
                break
    finally:
        if runtime is not None:
            await runtime.shutdown()
    return 0


async def amain(args) -> int:
    emitter = Emitter(sys.stdout)
    if args.no_api:
        return await _amain_index_only(args, emitter)
    key = None
    sim_fault = None
    if not args.fake:
        from .fake import simulated_fault

        sim_fault = simulated_fault(os.environ.get("VERSE_SIMULATE_API", ""))
    if args.fake:
        from .fake import FakeTransport, bank_responder

        transport = FakeTransport(bank_responder if args.fake_bank else None)
    elif sim_fault is not None:   # live check of the failure messages: every API call fails, no key, no network
        from .fake import FaultTransport

        transport = FaultTransport(None, sim_fault)
    else:
        from ..prep.keychain import KeychainError, read_api_key
        from .transport import AnthropicTransport

        try:
            key = read_api_key()
        except KeychainError as e:
            emitter.status("error", f"No API key: {e}", reason=NO_API_KEY)
            return 2
        transport = AnthropicTransport(key)
        del key  # the SDK clients hold the only copy
    cfg = Config(budget_usd=args.budget_usd)
    factory = None
    if (args.embed or not args.fake) and not args.no_embed:
        from .embed import LiteRtEmbedder

        factory = lambda: LiteRtEmbedder(cfg.embed_model, cfg.embed_backend)  # noqa: E731
    runtime = None
    try:
        async for raw in _stdin_lines():
            try:
                msg = parse_line(raw)
            except (ValueError, json.JSONDecodeError) as e:
                logging.getLogger("verse.runtime").warning("bad input line: %s", type(e).__name__)
                continue
            if msg is None:
                continue
            if runtime is None:   # the first message decides the mode for the life of the process
                if msg.get("type") == "sim_start":
                    if args.fake:
                        transport.responder = sim_fake_responder
                    runtime = SimRuntime(transport, emitter)
                elif msg.get("type") == "ask_start":
                    from ..prep.keychain import KeychainError
                    from .ask import make_client

                    try:
                        runtime = AskRuntime(make_client(fake=args.fake), emitter)
                    except KeychainError as e:
                        emitter.status("error", str(e))
                        return 2
                elif msg.get("type") == "memory_index_start":
                    runtime = _index_runtime(args, emitter)
                elif msg.get("type") in ("memory_ask_start", "brief_start"):
                    from ..prep.keychain import KeychainError
                    from .ask import make_client

                    try:
                        client = make_client(fake=args.fake)
                    except KeychainError as e:
                        emitter.status("error", str(e))
                        return 2
                    runtime = _memory_runtime(msg["type"], client, args, emitter, cfg)
                else:
                    runtime = Brain(transport, emitter, cfg, embedder_factory=factory)
            await runtime.handle(msg)
            if runtime.stopped.is_set():
                break
    finally:
        if runtime is not None:
            await runtime.shutdown()
        else:
            await transport.aclose()
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -u -m verse_brain.runtime", description=__doc__)
    ap.add_argument("--budget-usd", type=float, default=None, help="optional hard spend cap for this process (default: none)")
    ap.add_argument("--fake", action="store_true", help="canned fake transport (tests); no embedding matcher")
    ap.add_argument("--no-embed", action="store_true", help="turn the F3 paraphrase matcher off")
    ap.add_argument("--embed", action="store_true", help="with --fake: load the embedding model anyway (replays)")
    ap.add_argument("--fake-bank", action="store_true", help="with --fake: S/F answer from the pack's answer bank (replays)")
    ap.add_argument("--no-api", action="store_true",
                    help="serve only memory_index_start: no Keychain read, no API client (the memory index writer needs neither)")
    ap.add_argument("--log-level", default="WARNING")
    args = ap.parse_args(argv)
    logging.basicConfig(stream=sys.stderr, level=args.log_level, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    # The SDK's own logger can print request details at debug level; keep it quiet.
    logging.getLogger("anthropic").setLevel(logging.WARNING)
    logging.getLogger("httpx2").setLevel(logging.WARNING)
    return asyncio.run(amain(args))


if __name__ == "__main__":
    sys.exit(main())
