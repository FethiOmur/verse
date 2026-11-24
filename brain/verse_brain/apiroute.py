"""API route: an optional base URL (a local Anthropic-compatible proxy) with the direct API as its fallback (docs/api-route.md).

Configuration, read once per client:

- Base URL: the environment variable `VERSE_API_BASE_URL` when it is set (an empty value means "no base URL", whatever the file
  says), else `base_url` in `~/Library/Application Support/Verse/api.json` (override the file's location with
  `VERSE_API_CONFIG_FILE`). Unset, empty or not an http(s) URL: every client talks to api.anthropic.com, as before.
- Keys (prep/keychain.py): the Keychain item `verse-anthropic` (the one the app's Settings screen fills) is the Anthropic key. It
  is required, as before, and it never goes to the base URL: with a base URL it is the fallback's key, sent to api.anthropic.com
  only. The item `verse-anthropic-proxy` (same account) is the proxy's key, read only when a base URL is set; without it the
  proxy gets `PROXY_PLACEHOLDER_KEY` (for proxies that ignore the key) and a warning is logged.

Routing (`Router`): with a base URL every request goes to the proxy first; when the proxy fails in a way the direct API would not
(`failover_reason`), the same request goes to api.anthropic.com with the Anthropic key, and the router keeps new requests on the
direct API for `COOL_OFF_S` before one request probes the proxy again: a dead proxy costs one failed attempt per cool-off, not one
per request. A proxy that lacks an endpoint (404/405) sends that one request direct without a cool-off.

Streams (`RoutedStream`): a proxy stream that fails before any text reached the consumer is restarted on the fallback, unseen by the
consumer. Once text has reached the consumer it cannot be taken back (the live overlay and the ask panel show text as it streams),
so the stream ends with the mapped error instead; the router has already switched, so the caller's own retry goes direct. Callers
that keep the whole answer before using it (the prep models) restart the whole request through `call_routed`.

Each route change is reported to `Router.sink` (the live runtime attaches its events.jsonl writer): `api_route_fallback` and
`api_route_primary`, numbers and enums only, never a key or a URL.
"""

from __future__ import annotations

import ipaddress
import json
import logging
import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Awaitable, Callable
from urllib.parse import urlsplit

log = logging.getLogger("verse.apiroute")

BASE_URL_ENV = "VERSE_API_BASE_URL"
CONFIG_FILE_ENV = "VERSE_API_CONFIG_FILE"
DEFAULT_CONFIG_FILE = "~/Library/Application Support/Verse/api.json"

DIRECT_API_URL = "https://api.anthropic.com"   # the fallback's host, explicit so an ANTHROPIC_BASE_URL in the environment cannot redirect it
COOL_OFF_S = 60.0                 # after a failover, new requests stay on the direct API this long
PROXY_CONNECT_TIMEOUT_S = 1.0     # the proxy is local: a port that does not answer within this is dead
PROXY_PLACEHOLDER_KEY = "verse-proxy-no-key"   # sent to the proxy when `verse-anthropic-proxy` is missing; never a real key

DIRECT = "direct"       # no base URL: api.anthropic.com with the Anthropic key (behaviour without this module)
PROXY = "proxy"         # the base URL with the proxy's key
FALLBACK = "fallback"   # api.anthropic.com with the Anthropic key

EV_FALLBACK = "api_route_fallback"
EV_PRIMARY = "api_route_primary"

# Failover reasons (the `reason` field of `api_route_fallback`).
OFFLINE, TIMEOUT, AUTH, RATE_LIMITED, OVERLOADED, CREDIT, STREAM_BROKEN, NOT_SUPPORTED = (
    "offline", "timeout", "auth", "rate_limited", "overloaded", "credit", "stream_broken", "not_supported")


# ---------------------------------------------------------------- configuration
def config_file() -> Path:
    return Path(os.environ.get(CONFIG_FILE_ENV) or DEFAULT_CONFIG_FILE).expanduser()


def _is_loopback(host: str) -> bool:
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _clean_url(raw: object) -> str | None:
    """The base URL, or None. The value itself is never logged."""
    if not isinstance(raw, str):
        return None
    s = raw.strip()
    if not s:
        return None
    try:
        p = urlsplit(s)
        host = p.hostname
        p.port                                  # raises ValueError on a malformed port
    except ValueError:
        p, host = None, None
    if p is None or p.scheme not in ("http", "https") or not host:
        log.warning("API base URL ignored: not an http(s) URL")
        return None
    if p.username is not None or p.password is not None or p.query or p.fragment:
        log.warning("API base URL ignored: it must not carry a user name, password, query or fragment")
        return None
    if p.scheme == "http" and not _is_loopback(host):
        log.warning("API base URL is http:// to a host that is not this machine: the proxy key travels in clear text")
    return s.rstrip("/")


def base_url() -> str | None:
    """The configured base URL, or None for api.anthropic.com."""
    if BASE_URL_ENV in os.environ:
        return _clean_url(os.environ.get(BASE_URL_ENV, ""))
    try:
        data = json.loads(config_file().read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        log.warning("API config file unreadable; using api.anthropic.com")
        return None
    return _clean_url(data.get("base_url")) if isinstance(data, dict) else None


@dataclass(frozen=True)
class Credentials:
    """What the clients need. Keys are never shown by `repr`.

    `key` is always the Anthropic key (`verse-anthropic`) and only ever goes to api.anthropic.com: DIRECT without a base URL,
    FALLBACK with one. `proxy_key` goes only to the base URL."""

    key: str = field(repr=False)
    base_url: str | None = None
    proxy_key: str | None = field(default=None, repr=False)

    @property
    def has_fallback(self) -> bool:
        return bool(self.base_url)

    def router(self, **kw) -> "Router":
        return Router(self.base_url, self.has_fallback, **kw)

    def targets(self) -> dict[str, tuple[str, str | None]]:
        """route -> (key, base_url) for every route this setup can use. DIRECT keeps base_url None (the SDK's default, as before)."""
        if not self.base_url:
            return {DIRECT: (self.key, None)}
        return {PROXY: (self.proxy_key or PROXY_PLACEHOLDER_KEY, self.base_url), FALLBACK: (self.key, DIRECT_API_URL)}


def _read_proxy_key() -> str | None:
    from .prep import keychain

    return keychain.read_proxy_key()


def credentials_for(key: "str | Credentials", read_proxy: Callable[[], str | None] | None = None) -> Credentials:
    """Credentials for the Anthropic key `key` (`verse-anthropic`, which every caller reads first, so a missing item is the same
    KeychainError as before). It follows the configured route: with a base URL the proxy's item is read and `key` becomes the
    fallback's key."""
    if isinstance(key, Credentials):
        return key
    url = base_url()
    if url is None:
        return Credentials(key)
    proxy_key = (read_proxy or _read_proxy_key)() or None
    if proxy_key is None:
        log.warning("API base URL set without the verse-anthropic-proxy Keychain item: the proxy gets a placeholder key")
    return Credentials(key, url, proxy_key)


def load_credentials(read_key: Callable[[], str] | None = None,
                     read_proxy: Callable[[], str | None] | None = None) -> Credentials:
    """The Anthropic key + base URL (+ the proxy's key when a base URL is set). Raises KeychainError when `verse-anthropic` is
    missing, with or without a base URL (as before this module); the proxy's item is optional."""
    from .prep import keychain

    return credentials_for((read_key or keychain.read_api_key)(), read_proxy)


# ---------------------------------------------------------------- failure classification
def _mapped(e: BaseException):
    from .runtime.transport import TransportError, map_sdk_error

    return e if isinstance(e, TransportError) else map_sdk_error(e)


def failover_reason(e: BaseException) -> str | None:
    """Why a proxy error should go to the direct API, or None when the direct API would fail the same way (a 400-class request
    error) or the error is not a transport failure at all."""
    from .runtime.transport import (AuthFailed, BadRequest, CreditExhausted, Offline, Overloaded, RateLimited, StreamBroken)

    m = _mapped(e)
    if isinstance(m, StreamBroken):
        return STREAM_BROKEN
    if isinstance(m, Offline):
        return TIMEOUT if "timeout" in str(m).lower() else OFFLINE
    if isinstance(m, AuthFailed):
        return AUTH
    if isinstance(m, RateLimited):
        return RATE_LIMITED
    if isinstance(m, Overloaded):
        return OVERLOADED
    if isinstance(m, CreditExhausted):
        return CREDIT                   # the proxy's account, not the fallback key's
    if isinstance(m, BadRequest) and m.status in (404, 405):
        return NOT_SUPPORTED            # the proxy lacks this endpoint (count_tokens, beta messages)
    return None


def _status(e: BaseException) -> int | None:
    try:
        s = getattr(_mapped(e), "status", None)
    except Exception:  # noqa: BLE001
        return None
    return s if isinstance(s, int) else None


# ---------------------------------------------------------------- router
class Router:
    """Route state of one client (each client builds its own: the live transport's lanes and hedges share one, the ask client and
    each prep model have theirs). `sink(ev, **fields)` receives the route changes.

    After the cool-off exactly one request probes the proxy (`plan` hands it a probe token and renews the cool-off for everyone
    else); only that probe's success switches back. A proxy request that started before the failover and succeeds late carries no
    token and changes nothing, so a flapping proxy does not cancel the cool-off."""

    def __init__(self, base_url: str | None, has_fallback: bool, *, cool_off_s: float = COOL_OFF_S,
                 clock: Callable[[], float] = time.monotonic, sink: Callable[..., None] | None = None) -> None:
        self.base_url = base_url or None
        self.has_fallback = bool(self.base_url) and bool(has_fallback)
        self.cool_off_s = cool_off_s
        self.clock = clock
        self.sink = sink
        self.on_fallback = False
        self.failovers = 0          # route switches to the fallback in this process (cool-off renewals not counted)
        self.fallback_calls = 0     # requests answered by the fallback
        self._until = 0.0
        self._since = 0.0
        self._probe = 0             # id of the last probe handed out

    @property
    def primary(self) -> str:
        return PROXY if self.base_url else DIRECT

    def plan(self) -> tuple[tuple[str, ...], int | None]:
        """The routes a new request tries, in order, and its probe token (not None only for the one request that probes the
        proxy after a cool-off; pass it back to `succeeded`)."""
        if not self.base_url:
            return (DIRECT,), None
        if not self.has_fallback:
            return (PROXY,), None
        if not self.on_fallback:
            return (PROXY, FALLBACK), None
        now = self.clock()
        if now < self._until:
            return (FALLBACK,), None
        self._until = now + self.cool_off_s     # one probe per cool-off: concurrent requests stay on the fallback meanwhile
        self._probe += 1
        return (PROXY, FALLBACK), self._probe

    def order(self) -> tuple[str, ...]:
        """`plan()`'s routes (it hands out the probe when one is due)."""
        return self.plan()[0]

    def reason_for(self, route: str, e: BaseException) -> str | None:
        """The failover reason when `route`'s error should move the request to the fallback, else None."""
        if route != PROXY or not self.has_fallback:
            return None
        return failover_reason(e)

    def failed_over(self, reason: str, status: int | None = None) -> None:
        if reason == NOT_SUPPORTED:     # one request goes direct; the proxy stays primary for everything else
            return
        now = self.clock()
        self._until = now + self.cool_off_s
        if self.on_fallback:
            return                      # a probe after the cool-off failed again: same route, no event
        self.on_fallback = True
        self._since = now
        self.failovers += 1
        log.warning("API proxy failed (%s%s); using the direct API for %.0f s", reason,
                    f" {status}" if status is not None else "", self.cool_off_s)
        self._emit(EV_FALLBACK, reason=reason, status=status, cool_off_s=self.cool_off_s, failovers=self.failovers)

    def succeeded(self, route: str, probe: int | None = None) -> None:
        if route == FALLBACK:
            self.fallback_calls += 1
        elif route == PROXY and self.on_fallback and probe is not None and probe == self._probe:
            self.on_fallback = False
            log.warning("API proxy answers again; back on the proxy")
            self._emit(EV_PRIMARY, fallback_s=round(self.clock() - self._since, 1), fallback_calls=self.fallback_calls,
                       failovers=self.failovers)

    def _emit(self, ev: str, **fields: Any) -> None:
        if self.sink is None:
            return
        try:
            self.sink(ev, **fields)
        except Exception:  # noqa: BLE001 - the event log is a diagnosis aid and must never fail a request
            pass


async def call_routed(router: Router, fn: Callable[[str], Awaitable[Any]]) -> Any:
    """`await fn(route)` on the first route that works. A non-failover error (or the last route's error) propagates unchanged:
    callers that match SDK exception types keep working."""
    order, probe = router.plan()
    for i, route in enumerate(order):
        try:
            result = await fn(route)
        except Exception as e:  # noqa: BLE001 - CancelledError is not an Exception and always propagates
            reason = router.reason_for(route, e) if i + 1 < len(order) else None
            if reason is None:
                raise
            router.failed_over(reason, _status(e))
            continue
        router.succeeded(route, probe)
        return result
    raise RuntimeError("no API route")   # unreachable: order() is never empty


class RoutedStream:
    """A stream of normalized events (`kind` in start | text | stop, `stop_reason` on stop) over the router's routes.

    `open_fn(route)` returns (awaitably) the stream of one route: an async iterable with an optional `aclose()`, `headers` and
    `new_connection`. A proxy stream that ends without a stop event, or with a stop event that has no stop_reason, is broken."""

    def __init__(self, router: Router, open_fn: Callable[[str], Awaitable[Any]]) -> None:
        self.router = router
        self._open_fn = open_fn
        self._order, self._probe = router.plan()
        self._i = 0
        self.inner: Any = None
        self.route: str | None = None
        self.output_seen = False
        self._closed = False

    @property
    def headers(self) -> dict:
        return getattr(self.inner, "headers", None) or {}

    @property
    def new_connection(self) -> bool | None:
        return getattr(self.inner, "new_connection", None)

    @property
    def request_id(self) -> str | None:
        return getattr(self.inner, "request_id", None)

    def _next_route(self, route: str, e: BaseException) -> bool:
        """Record a failed route; True when the request should move on to the next one."""
        reason = self.router.reason_for(route, e) if self._i + 1 < len(self._order) else None
        if reason is None:
            return False
        self.router.failed_over(reason, _status(e))
        if self.output_seen:
            return False
        self._i += 1
        return True

    async def open(self) -> "RoutedStream":
        while True:
            route = self._order[self._i]
            try:
                self.inner = await self._open_fn(route)
            except Exception as e:  # noqa: BLE001
                if not self._next_route(route, e):
                    raise
                continue
            self.route = route
            return self

    async def _close_inner(self) -> None:
        inner, self.inner = self.inner, None
        close = getattr(inner, "aclose", None)
        if close is not None:
            try:
                await close()
            except Exception:  # noqa: BLE001
                pass

    async def __aiter__(self):
        from .runtime.transport import StreamBroken

        if self.inner is None:
            await self.open()
        while True:
            route = self.route
            try:
                stopped = False
                async for ev in self.inner:
                    kind = getattr(ev, "kind", None)
                    if kind == "stop":
                        if route == PROXY and getattr(ev, "stop_reason", None) is None and not self._closed:
                            raise StreamBroken("stream ended before the message was complete")
                        stopped = True
                    elif kind == "text":
                        self.output_seen = True
                    yield ev
                    if stopped:
                        break
                if not stopped and route == PROXY and not self._closed:
                    raise StreamBroken("stream ended before the message was complete")
            except Exception as e:  # noqa: BLE001
                if self._closed or not self._next_route(route, e):
                    raise
                await self._close_inner()
                await self.open()
                continue
            if stopped:
                self.router.succeeded(route, self._probe)
            return

    async def aclose(self) -> None:
        self._closed = True
        await self._close_inner()

