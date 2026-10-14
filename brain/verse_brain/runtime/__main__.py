"""CLI: python -u -m verse_brain.runtime [--budget-usd N] [--fake] [--no-embed]

One process serves one session, and its first message decides which: `start` runs the meeting runtime (engine.Brain),
`sim_start` the interview simulation (sim.SimRuntime, plan S2). `--budget-usd` and the embedding matcher apply to
meetings only.

Reads Swift -> brain JSON lines on stdin, writes brain -> Swift JSON lines on stdout (flushed per line), logs to
stderr. Exits on `{"type":"control","action":"stop"}` or stdin EOF. `--fake` uses the canned fake transport
(no network, no key) for IPC tests; it also leaves the embedding matcher off. `--no-embed` turns the F3 paraphrase
matcher (EmbeddingGemma, LiteRT-LM) off; without it the matcher loads at `start` and stays off by itself when
`litert_lm` or the model is missing.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys

from .engine import Brain
from .protocol import Emitter, parse_line
from .settings import Config
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


async def amain(args) -> int:
    emitter = Emitter(sys.stdout)
    key = None
    if args.fake:
        from .fake import FakeTransport

        transport = FakeTransport()
    else:
        from ..prep.keychain import KeychainError, read_api_key
        from .transport import AnthropicTransport

        try:
            key = read_api_key()
        except KeychainError as e:
            emitter.status("error", str(e))
            return 2
        transport = AnthropicTransport(key)
        del key  # the SDK clients hold the only copy
    cfg = Config(budget_usd=args.budget_usd)
    factory = None
    if not (args.fake or args.no_embed):
        from .embed import LiteRtEmbedder

        factory = lambda: LiteRtEmbedder(cfg.embed_model, cfg.embed_backend)  # noqa: E731
    runtime: Brain | SimRuntime | None = None
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
    ap.add_argument("--log-level", default="WARNING")
    args = ap.parse_args(argv)
    logging.basicConfig(stream=sys.stderr, level=args.log_level, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    # The SDK's own logger can print request details at debug level; keep it quiet.
    logging.getLogger("anthropic").setLevel(logging.WARNING)
    logging.getLogger("httpx2").setLevel(logging.WARNING)
    return asyncio.run(amain(args))


if __name__ == "__main__":
    sys.exit(main())
