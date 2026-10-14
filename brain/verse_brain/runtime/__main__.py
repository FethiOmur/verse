"""CLI: python -u -m verse_brain.runtime [--budget-usd N] [--fake]

Reads Swift -> brain JSON lines on stdin, writes brain -> Swift JSON lines on stdout (flushed per line), logs to
stderr. Exits on `{"type":"control","action":"stop"}` or stdin EOF. `--fake` uses the canned fake transport
(no network, no key) for IPC tests.
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
    brain = Brain(transport, emitter, Config(budget_usd=args.budget_usd))
    try:
        async for raw in _stdin_lines():
            try:
                msg = parse_line(raw)
            except (ValueError, json.JSONDecodeError) as e:
                logging.getLogger("verse.runtime").warning("bad input line: %s", type(e).__name__)
                continue
            if msg is None:
                continue
            await brain.handle(msg)
            if brain.stopped.is_set():
                break
    finally:
        await brain.shutdown()
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -u -m verse_brain.runtime", description=__doc__)
    ap.add_argument("--budget-usd", type=float, default=3.0, help="hard spend cap for this process")
    ap.add_argument("--fake", action="store_true", help="canned fake transport (tests)")
    ap.add_argument("--log-level", default="WARNING")
    args = ap.parse_args(argv)
    logging.basicConfig(stream=sys.stderr, level=args.log_level, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    # The SDK's own logger can print request details at debug level; keep it quiet.
    logging.getLogger("anthropic").setLevel(logging.WARNING)
    logging.getLogger("httpx2").setLevel(logging.WARNING)
    return asyncio.run(amain(args))


if __name__ == "__main__":
    sys.exit(main())
