"""Model access for the prep stage: Sonnet 5.5 at effort high, streaming, plus free token counting.

Client setup follows bench/api/bench_api.py (SDK 1.x runs on httpx2). Prep is not latency-bound, so the SDK's
default retries stay on. The API key is passed to the SDK client and nowhere else.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass, field
from typing import Protocol

PREP_MODEL = "claude-sonnet-5-5"
HAIKU = "claude-haiku-5-5"
OPUS = "claude-opus-5-5"
MAX_OUTPUT_TOKENS = 64_000

# $/MTok (input, output, cache read); cache write 5m = 1.25x input. Sonnet and Haiku cache reads are 0.1x input (as they
# always were), Opus 5.5's is $0.20 (claude-api skill, cached 2026-10-06).
PRICES = {PREP_MODEL: (2.00, 10.00, 0.20), HAIKU: (0.10, 0.50, 0.01), OPUS: (4.00, 20.00, 0.20)}
# Haiku 5.5 prompts over 100k tokens (input + cache read + cache write) cost more. The 0.05 cache read and the 1.25x write
# multiplier on this tier are derived, not stated by the skill: unconfirmed (docs/specs/2026-10-20-verse-five-features-design.md 3.4).
HAIKU_LONG_PRICES = (0.50, 2.50, 0.05)
HAIKU_LONG_PROMPT_TOKENS = 100_000


class PrepError(RuntimeError):
    pass


@dataclass
class Usage:
    input: int = 0
    output: int = 0
    cache_read: int = 0
    cache_write: int = 0

    def as_dict(self) -> dict:
        return {"input": self.input, "output": self.output, "cache_read": self.cache_read, "cache_write": self.cache_write}


@dataclass
class ModelOutput:
    text: str
    usage: Usage = field(default_factory=Usage)
    stop_reason: str | None = "end_turn"


def spend_usd(model: str, u: Usage) -> float:
    pin, pout, pread = PRICES[model]
    if model == HAIKU and u.input + u.cache_read + u.cache_write > HAIKU_LONG_PROMPT_TOKENS:
        pin, pout, pread = HAIKU_LONG_PRICES
    return (u.input * pin + u.cache_write * pin * 1.25 + u.cache_read * pread + u.output * pout) / 1e6


class PrepModel(Protocol):
    model: str

    async def generate(self, system: str, user: str, max_tokens: int) -> ModelOutput: ...

    async def count_tokens(self, text: str) -> int:
        """Tokens of `text` as a user message (the pack cap)."""
        ...

    async def count_request_tokens(self, system: str, user: str) -> int: ...


class AnthropicPrepModel:
    def __init__(self, api_key: str, model: str = PREP_MODEL, progress: bool = False) -> None:
        import anthropic
        import httpx2

        http = anthropic.DefaultAsyncHttpxClient(
            http2=True,
            limits=httpx2.Limits(max_connections=10, max_keepalive_connections=10, keepalive_expiry=300),
        )
        self._client = anthropic.AsyncAnthropic(
            api_key=api_key, http_client=http, max_retries=2, timeout=anthropic.Timeout(600.0, connect=10.0)
        )
        self.model = model
        self._progress = progress

    async def generate(self, system: str, user: str, max_tokens: int) -> ModelOutput:
        parts: list[str] = []
        shown = 0
        async with self._client.messages.stream(
            model=self.model,
            max_tokens=max_tokens,
            system=system,
            messages=[{"role": "user", "content": user}],
            thinking={"type": "adaptive"},
            output_config={"effort": "high"},
        ) as stream:
            async for chunk in stream.text_stream:
                parts.append(chunk)
                if self._progress:
                    n = sum(map(len, parts))
                    if n - shown >= 4000:
                        shown = n
                        print(f"  ... {n} chars", file=sys.stderr, flush=True)
            final = await stream.get_final_message()
        u = final.usage
        usage = Usage(
            input=u.input_tokens or 0,
            output=u.output_tokens or 0,
            cache_read=getattr(u, "cache_read_input_tokens", 0) or 0,
            cache_write=getattr(u, "cache_creation_input_tokens", 0) or 0,
        )
        if final.stop_reason == "refusal":
            raise PrepError("the model refused the prep request (stop_reason=refusal)")
        return ModelOutput("".join(parts), usage, final.stop_reason)

    async def count_tokens(self, text: str) -> int:
        # The pack is read by Haiku (S/F) and Sonnet (D): size it for the larger count.
        counts = []
        for m in (HAIKU, self.model):
            r = await self._client.messages.count_tokens(model=m, messages=[{"role": "user", "content": text}])
            counts.append(r.input_tokens)
        return max(counts)

    async def count_request_tokens(self, system: str, user: str) -> int:
        r = await self._client.messages.count_tokens(
            model=self.model, system=system, messages=[{"role": "user", "content": user}]
        )
        return r.input_tokens

    async def aclose(self) -> None:
        await self._client.close()
