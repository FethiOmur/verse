"""Model transport: the only module that talks to the Anthropic SDK.

Two warm lanes per model (lane 0 = primary, lane 1 = hedge), each its own `DefaultAsyncHttpxClient(http2=True,
keepalive_expiry=300)` and therefore its own HTTP/2 connection: a hedged duplicate must not ride the connection
that stalled. SDK retries are off on every client (`max_retries=0`); the runtime does D's single retry itself so it
can honour `retry-after` and drop a stale answer.

Normalized stream events: ("start", usage) | ("text", str) | ("stop", stop_reason, usage). SDK errors are mapped
to the exception classes below; no message text that could contain request data is forwarded.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import AsyncIterator, Protocol

from .settings import HAIKU, SONNET


class TransportError(Exception):
    kind = "error"

    def __init__(self, message: str = "", *, retry_after: float | None = None, status: int | None = None):
        super().__init__(message)
        self.retry_after = retry_after
        self.status = status


class RateLimited(TransportError):
    kind = "rate_limited"


class Overloaded(TransportError):
    kind = "overloaded"


class Offline(TransportError):
    kind = "offline"


class CreditExhausted(TransportError):
    kind = "credit_exhausted"


class AuthFailed(TransportError):
    kind = "auth"


class BadRequest(TransportError):
    kind = "bad_request"


@dataclass
class Ev:
    kind: str                     # start | text | stop
    text: str = ""
    stop_reason: str | None = None
    usage: dict = field(default_factory=dict)


class CallStream(Protocol):
    headers: dict
    new_connection: bool | None

    def __aiter__(self) -> AsyncIterator[Ev]: ...

    async def aclose(self) -> None: ...


class Transport(Protocol):
    async def open_stream(self, route: str, request: dict, lane: int) -> CallStream: ...

    async def create(self, route: str, request: dict, lane: int) -> tuple[dict, dict, str | None]:
        """Non-streaming call (pre-warm / keep-alive with max_tokens 0). Returns (usage, headers, stop_reason)."""
        ...

    async def ping(self, model: str, lane: int) -> dict: ...

    async def aclose(self) -> None: ...


KEEP_HEADERS = ("anthropic-ratelimit-", "retry-after", "request-id")


def pick_headers(h) -> dict:
    out = {}
    for k, v in h.items():
        kl = k.lower()
        if kl.startswith(KEEP_HEADERS) and "key" not in kl and "auth" not in kl:
            out[kl] = v
    return out


def _int_usage(obj) -> dict:
    if obj is None:
        return {}
    d = obj.model_dump() if hasattr(obj, "model_dump") else dict(obj)
    return {k: v for k, v in d.items() if isinstance(v, int)}


def _retry_after(headers) -> float | None:
    try:
        v = headers.get("retry-after")
        return float(v) if v is not None else None
    except (TypeError, ValueError):
        return None


def map_sdk_error(e: BaseException) -> TransportError:
    import anthropic

    if isinstance(e, anthropic.RateLimitError):
        return RateLimited("429 rate_limit", retry_after=_retry_after(e.response.headers), status=429)
    if isinstance(e, (anthropic.AuthenticationError, anthropic.PermissionDeniedError)):
        return AuthFailed(f"{e.status_code} {getattr(e, 'type', '')}", status=e.status_code)
    if isinstance(e, anthropic.APIStatusError):
        etype = getattr(e, "type", None) or ""
        msg = (getattr(e, "message", "") or "").lower()
        if e.status_code == 402 or etype == "billing_error" or "credit balance" in msg:
            return CreditExhausted(f"{e.status_code} {etype}", status=e.status_code)
        if e.status_code >= 500 or etype == "overloaded_error":
            return Overloaded(f"{e.status_code} {etype}", status=e.status_code)
        # 400s: the message is the API's validation text (no key material); keep it short for the log.
        return BadRequest(f"{e.status_code} {etype}: {(getattr(e, 'message', '') or '')[:200]}", status=e.status_code)
    if isinstance(e, (anthropic.APIConnectionError, anthropic.APITimeoutError)):
        return Offline(type(e).__name__)
    return TransportError(type(e).__name__)


class _SdkStream:
    def __init__(self, raw, sdk_stream, new_connection: bool | None):
        self.headers = pick_headers(raw.headers)
        self.request_id = raw.headers.get("request-id")
        self.new_connection = new_connection
        self._stream = sdk_stream
        self._closed = False

    async def __aiter__(self):
        usage: dict = {}
        stop_reason = None
        try:
            async for ev in self._stream:
                et = ev.type
                if et == "message_start":
                    usage = _int_usage(ev.message.usage)
                    yield Ev("start", usage=dict(usage))
                elif et == "content_block_delta":
                    d = ev.delta
                    if getattr(d, "type", None) == "text_delta":
                        yield Ev("text", text=d.text)
                elif et == "message_delta":
                    usage.update(_int_usage(ev.usage))
                    stop_reason = getattr(ev.delta, "stop_reason", None)
        except Exception as e:  # noqa: BLE001
            if self._closed:
                return
            raise map_sdk_error(e) from None
        yield Ev("stop", stop_reason=stop_reason, usage=usage)

    async def aclose(self) -> None:
        if not self._closed:
            self._closed = True
            try:
                await self._stream.close()
            except Exception:  # noqa: BLE001
                pass


class AnthropicTransport:
    """Real transport. The API key is handed to the SDK clients and kept nowhere else."""

    def __init__(self, api_key: str, lanes: int = 2) -> None:
        import anthropic
        import httpx2

        self._anthropic = anthropic
        self._http: dict[tuple[str, int], object] = {}
        self._clients: dict[tuple[str, int], object] = {}
        for model in (HAIKU, SONNET):
            for lane in range(lanes):
                http = anthropic.DefaultAsyncHttpxClient(
                    http2=True,
                    limits=httpx2.Limits(max_connections=4, max_keepalive_connections=4, keepalive_expiry=300),
                )
                timeout = anthropic.Timeout(60.0, connect=10.0) if model == SONNET else anthropic.Timeout(30.0, connect=10.0)
                self._http[(model, lane)] = http
                self._clients[(model, lane)] = anthropic.AsyncAnthropic(
                    api_key=api_key, http_client=http, max_retries=0, timeout=timeout)

    # -- connection tracking: lets the metrics prove that no connection is opened at t = 0
    def _conn_ids(self, model: str, lane: int) -> set[int]:
        try:
            pool = self._http[(model, lane)]._transport._pool  # httpx2 internals; best effort
            return {id(c) for c in pool.connections}
        except Exception:  # noqa: BLE001
            return set()

    def _messages(self, route: str, model: str, lane: int):
        c = self._clients[(model, lane)]
        return c.beta.messages if route == "D" else c.messages

    async def open_stream(self, route: str, request: dict, lane: int) -> CallStream:
        model = request["model"]
        before = self._conn_ids(model, lane)
        try:
            raw = await self._messages(route, model, lane).with_raw_response.create(**request, stream=True)
            after = self._conn_ids(model, lane)
            new = bool(after - before) if (before or after) else None
            sdk_stream = await raw.parse()
        except TransportError:
            raise
        except Exception as e:  # noqa: BLE001
            raise map_sdk_error(e) from None
        return _SdkStream(raw, sdk_stream, new)

    async def create(self, route: str, request: dict, lane: int) -> tuple[dict, dict, str | None]:
        model = request["model"]
        try:
            raw = await self._messages(route, model, lane).with_raw_response.create(**request)
            msg = await raw.parse()
        except Exception as e:  # noqa: BLE001
            raise map_sdk_error(e) from None
        return _int_usage(msg.usage), pick_headers(raw.headers), msg.stop_reason

    async def ping(self, model: str, lane: int) -> dict:
        t0 = time.perf_counter()
        try:
            raw = await self._clients[(model, lane)].messages.with_raw_response.count_tokens(
                model=model, messages=[{"role": "user", "content": "ping"}])
        except Exception as e:  # noqa: BLE001
            raise map_sdk_error(e) from None
        return {"ms": round((time.perf_counter() - t0) * 1000, 1), "headers": pick_headers(raw.headers)}

    async def aclose(self) -> None:
        for c in self._clients.values():
            try:
                await c.close()
            except Exception:  # noqa: BLE001
                pass
