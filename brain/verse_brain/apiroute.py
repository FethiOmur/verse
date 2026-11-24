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

Stalls (a proxy that accepts the connection and then goes quiet) are caught by time, not by the read timeout:

- Hedged start: a proxy stream with no first content after `HEDGE_S` gets the same request on the fallback in parallel; the
  first of the two to reach its first content (`CONTENT`: a content block started, of any kind, or the message ended) is used
  and the other is cancelled and closed. Both are judged on that same milestone, not on `message_start`: the direct API sends
  `message_start` at once, a buffering proxy only with its first content, so judging on the first event would hand every race
  the proxy cannot win early to the paid key. An attempt's events before the milestone are held and reach the consumer only when
  it wins. A proxy that loses this race is a failover with reason `stalled`. A proxy that wins it after all changes no route.
  Non-streaming calls race the same way after `CALL_HEDGE_S` when their caller asks for it (`call_routed(..., hedge_s=)`).
- Adaptive hedge delay: the router remembers the proxy's recent first-content latencies per model (`HEDGE_WINDOW`), and a race
  waits at least `HEDGE_WIDEN` x the slowest of them (never more than `HEDGE_MAX_FACTOR` x the base delay), so a proxy that is
  healthy but slower than the base delay (Sonnet, a cold prompt cache) does not start a paid duplicate on every request.
- Idle limit: once a proxy stream has started, no event (pings included where the SDK stream can be tapped) for `IDLE_S` outside a
  thinking block is a `stalled` failure, handled like any other mid-stream break (restart before text, error after it).
- Prep: a first-byte deadline (`PREP_FIRST_BYTE_S`, prep/model.py) on the proxy, then the sequential restart above.

All four are module constants, each overridable by an environment variable read when a client builds its router (a value of 0
turns that guard off).

Each route change is reported to `Router.sink` (the live runtime attaches its events.jsonl writer): `api_route_fallback` and
`api_route_primary`, numbers and enums only, never a key or a URL.
"""

from __future__ import annotations

import asyncio
import ipaddress
import json
import logging
import math
import os
import time
from collections import deque
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

# Stall guards (docs/api-route.md "Stalls"). Each is overridable by its environment variable, read when a router is built; 0 (or a
# negative value) turns the guard off, anything that is not a number is ignored with a warning.
HEDGE_S = 1.5                     # streams: no first content from the proxy after this -> the same request on the fallback in parallel
IDLE_S = 6.0                      # streams: a started proxy stream with no event for this (outside thinking) has stalled
CALL_HEDGE_S = 4.0                # non-streaming live calls (pre-warm, keep-alive, ping, ask count): race the fallback after this
PREP_FIRST_BYTE_S = 15.0          # prep: no response headers from the proxy within this -> restart on the fallback
HEDGE_ENV = "VERSE_API_HEDGE_S"
IDLE_ENV = "VERSE_API_IDLE_S"
CALL_HEDGE_ENV = "VERSE_API_CALL_HEDGE_S"
PREP_FIRST_BYTE_ENV = "VERSE_API_PREP_FIRST_BYTE_S"
# Adaptive hedge delay (Router.hedge_delay): the proxy's own recent latency widens a race's delay, within a cap.
HEDGE_WINDOW = 8                  # recent proxy first-content latencies kept per (kind, model)
HEDGE_WIDEN = 1.25                # a race waits at least this multiple of the slowest of them ...
HEDGE_MAX_FACTOR = 3.0            # ... but never longer than this multiple of its base delay (HEDGE_S 1.5 -> 4.5 s at most)

DIRECT = "direct"       # no base URL: api.anthropic.com with the Anthropic key (behaviour without this module)
PROXY = "proxy"         # the base URL with the proxy's key
FALLBACK = "fallback"   # api.anthropic.com with the Anthropic key

EV_FALLBACK = "api_route_fallback"
EV_PRIMARY = "api_route_primary"

# A routed stream's marker event (its `kind`): the route's first content event arrived (a content_block_start or
# content_block_delta of any kind, thinking included). The race's milestone; RoutedStream never yields it to its consumer.
CONTENT = "content"
_MILESTONE_KINDS = (CONTENT, "text", "stop")   # a route stream without markers reaches the milestone with its first text or stop

# Failover reasons (the `reason` field of `api_route_fallback`).
OFFLINE, TIMEOUT, AUTH, RATE_LIMITED, OVERLOADED, CREDIT, STREAM_BROKEN, NOT_SUPPORTED, STALLED = (
    "offline", "timeout", "auth", "rate_limited", "overloaded", "credit", "stream_broken", "not_supported", "stalled")

_ENV = object()   # Router argument default: read the guard from its environment variable


def env_seconds(name: str, default: float) -> float | None:
    """A stall guard in seconds from the environment: `default` when unset or not a number, None (off) for 0 or less."""
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        v = float(raw)
    except ValueError:
        v = math.nan
    if not math.isfinite(v):
        log.warning("%s ignored: not a number of seconds", name)
        return default
    return v if v > 0 else None


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
    from .runtime.transport import (AuthFailed, BadRequest, CreditExhausted, Offline, Overloaded, RateLimited, StreamBroken,
                                    StreamStalled)

    m = _mapped(e)
    if isinstance(m, StreamStalled):
        return STALLED
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
    token and changes nothing, so a flapping proxy does not cancel the cool-off.

    The stall guards (`hedge_s`, `idle_s`, `call_hedge_s`, `first_byte_s`; None = off) default to the module constants or their
    environment variables. `sleep` is what every guard waits with (tests inject a fake clock's sleep). A race's actual delay is
    `hedge_delay(base, key)`: the base, widened by the proxy's recent latency for that key (`proxy_answered`)."""

    def __init__(self, base_url: str | None, has_fallback: bool, *, cool_off_s: float = COOL_OFF_S,
                 clock: Callable[[], float] = time.monotonic, sink: Callable[..., None] | None = None,
                 hedge_s: Any = _ENV, idle_s: Any = _ENV, call_hedge_s: Any = _ENV, first_byte_s: Any = _ENV,
                 sleep: Callable[[float], Awaitable[Any]] | None = None) -> None:
        self.base_url = base_url or None
        self.has_fallback = bool(self.base_url) and bool(has_fallback)
        self.cool_off_s = cool_off_s
        self.clock = clock
        self.sink = sink
        self.hedge_s = env_seconds(HEDGE_ENV, HEDGE_S) if hedge_s is _ENV else hedge_s
        self.idle_s = env_seconds(IDLE_ENV, IDLE_S) if idle_s is _ENV else idle_s
        self.call_hedge_s = env_seconds(CALL_HEDGE_ENV, CALL_HEDGE_S) if call_hedge_s is _ENV else call_hedge_s
        self.first_byte_s = env_seconds(PREP_FIRST_BYTE_ENV, PREP_FIRST_BYTE_S) if first_byte_s is _ENV else first_byte_s
        self.sleep = sleep or asyncio.sleep
        self.on_fallback = False
        self.failovers = 0          # route switches to the fallback in this process (cool-off renewals not counted)
        self.fallback_calls = 0     # requests answered by the fallback
        self._until = 0.0
        self._since = 0.0
        self._probe = 0             # id of the last probe handed out
        self.late_wins = 0          # races the proxy won after the fallback request had started (a duplicate was paid for)
        self._latency: dict[Any, deque] = {}   # key -> the proxy's recent first-content latencies (seconds)

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

    def hedge_delay(self, base: float | None, key: Any = None) -> float | None:
        """The delay a race on `key` waits before starting the fallback: `base`, or `HEDGE_WIDEN` x the slowest recent proxy
        latency on `key` when that is longer, capped at `HEDGE_MAX_FACTOR` x `base`. None (off) stays None."""
        if base is None:
            return None
        recent = self._latency.get(key)
        if not recent:
            return base
        return min(max(base, max(recent) * HEDGE_WIDEN), base * HEDGE_MAX_FACTOR)

    def proxy_answered(self, key: Any, elapsed: float, late: bool) -> None:
        """A race the proxy won after `elapsed` seconds (`late`: after the fallback request had started)."""
        self._latency.setdefault(key, deque(maxlen=HEDGE_WINDOW)).append(max(0.0, elapsed))
        if late:
            self.late_wins += 1

    def _emit(self, ev: str, **fields: Any) -> None:
        if self.sink is None:
            return
        try:
            self.sink(ev, **fields)
        except Exception:  # noqa: BLE001 - the event log is a diagnosis aid and must never fail a request
            pass


# ---------------------------------------------------------------- stall guards
def _error_of(t: "asyncio.Task") -> BaseException | None:
    """A finished task's exception (retrieved, so it is never reported as unretrieved). A task that ended cancelled although
    nobody cancelled it (the race only cancels its tasks on the way out) is a request that broke: StreamBroken, so a proxy
    attempt fails over and a CancelledError never reaches a caller that was not cancelled."""
    if t.cancelled():
        from .runtime.transport import StreamBroken

        return StreamBroken("the request was cancelled from inside")
    return t.exception()


async def _reap(tasks, discard: Callable[[Any], Awaitable[None]] | None = None) -> None:
    """Cancel `tasks`, wait for them, and hand any result one of them produced anyway to `discard` (closes a stream nobody uses).
    A cancelled gather still waits for its tasks to finish, so a second cancel of the reaper never leaves one running under the
    caller's close (test_reap_waits_for_its_tasks_even_when_cancelled_again)."""
    tasks = [t for t in tasks if t is not None]
    for t in tasks:
        t.cancel()
    if not tasks:
        return
    await asyncio.gather(*tasks, return_exceptions=True)
    if discard is not None:
        for t in tasks:
            if not t.cancelled() and t.exception() is None:
                await _discard_quietly(discard, t.result())


async def _discard_quietly(discard: Callable[[Any], Awaitable[None]], result: Any) -> None:
    """`discard(result)`; an error closing an unused result is logged, never raised over the error the caller is handling."""
    try:
        await discard(result)
    except Exception as e:  # noqa: BLE001 - best effort, like _aclose
        log.debug("closing an unused route result failed: %s", type(e).__name__)


async def _to_the_end(coro: Awaitable[Any]) -> None:
    """Run cleanup `coro` to its end even when the caller is cancelled meanwhile, then re-raise that cancel. A cleanup cut short
    by a second cancel (the engine discarding a call, the ask consumer closing) would leave an opened stream unclosed; shielded,
    the tasks it reaps are cancelled once, by it, and their own cleanup runs to the end too."""
    task = asyncio.ensure_future(coro)
    cancelled = False
    while not task.done():
        try:
            await asyncio.shield(task)
        except asyncio.CancelledError:
            if not task.cancelled():
                cancelled = True                    # the caller's cancel, not the cleanup's own end
        except BaseException:  # noqa: BLE001 - the cleanup's own error, raised below
            pass
    if cancelled:
        if not task.cancelled():
            task.exception()                        # retrieved: the caller's cancel wins over a cleanup error
        raise asyncio.CancelledError
    task.result()


async def _settle_after(cleanup: Callable[[], Awaitable[None]], kept: "asyncio.Task | None",
                        discard: Callable[[Any], Awaitable[None]] | None) -> None:
    """A race's `finally`: run `cleanup` to its end (`_to_the_end`); when the caller was cancelled meanwhile (or the cleanup
    failed), the result `kept` holds for the caller never reaches it, so it goes to `discard` too before the error propagates."""
    try:
        await _to_the_end(cleanup())
    except BaseException:
        if (kept is not None and discard is not None and kept.done() and not kept.cancelled()
                and kept.exception() is None):
            await _to_the_end(_discard_quietly(discard, kept.result()))
        raise


async def within(aw: Awaitable[Any], seconds: float, sleep: Callable[[float], Awaitable[Any]], what: str = "response",
                 discard: Callable[[Any], Awaitable[None]] | None = None) -> Any:
    """`await aw`, or StreamStalled once `seconds` passed on `sleep`'s clock first (`aw` is then cancelled, and a result it
    produced anyway goes to `discard`)."""
    from .runtime.transport import StreamStalled

    loop = asyncio.get_running_loop()
    task = asyncio.ensure_future(aw)
    timer = loop.create_task(sleep(seconds))
    try:
        await asyncio.wait({task, timer}, return_when=asyncio.FIRST_COMPLETED)
        if task.done():
            return task.result()
        raise StreamStalled(f"no {what} from the proxy within {seconds:g} s")
    finally:
        pending = not task.done()

        async def cleanup() -> None:
            await _reap([timer])
            if pending:
                await _reap([task], discard)

        await _settle_after(cleanup, None if pending else task, discard)


async def _race(router: Router, attempt: Callable[[str], Awaitable[Any]], hedge_s: float, *,
                discard: Callable[[Any], Awaitable[None]] | None = None,
                on_hedge: Callable[[], None] | None = None, key: Any = None) -> tuple[str, Any]:
    """Hedged start: `attempt(PROXY)`, and when it has not finished after `router.hedge_delay(hedge_s, key)`, `attempt(FALLBACK)`
    in parallel. An attempt finishes at the milestone both routes are judged on (for streams: the first content, RoutedStream._first),
    never earlier on the proxy's side than on the fallback's. A proxy win reports its latency on `key` (`router.proxy_answered`),
    which widens later delays. Returns
    (route, result) of the first attempt that succeeds; the other is cancelled and its result, if it produced one anyway, goes to
    `discard`. Failovers are recorded here: the proxy's own failover error, or `stalled` when the fallback simply won.

    Errors as without the race: a proxy error the direct API would share (a 400-class request error) before the hedge propagates
    unchanged; a proxy failover error before the hedge moves the request to the fallback at once; when both routes fail the
    fallback's error propagates (the proxy's when the proxy's was a request error)."""
    loop = asyncio.get_running_loop()
    started = router.clock()
    tasks: dict[str, asyncio.Task] = {PROXY: loop.create_task(attempt(PROXY))}
    timer = loop.create_task(router.sleep(router.hedge_delay(hedge_s, key)))
    winner: str | None = None
    try:
        proxy = tasks[PROXY]
        await asyncio.wait({proxy, timer}, return_when=asyncio.FIRST_COMPLETED)
        if proxy.done():                                     # answered (or failed) within the hedge delay: no race
            e = _error_of(proxy)
            if e is None:
                winner = PROXY
                router.proxy_answered(key, router.clock() - started, late=False)
                return PROXY, proxy.result()
            reason = router.reason_for(PROXY, e)
            if reason is None:
                raise e
            router.failed_over(reason, _status(e))
            winner = FALLBACK
            return FALLBACK, await attempt(FALLBACK)
        if on_hedge is not None:
            on_hedge()
        fallback = tasks[FALLBACK] = loop.create_task(attempt(FALLBACK))
        proxy_err: BaseException | None = None
        proxy_reason: str | None = None
        fallback_err: BaseException | None = None
        pending = {proxy, fallback}
        while pending:
            done, pending = await asyncio.wait(pending, return_when=asyncio.FIRST_COMPLETED)
            if proxy in done:
                e = _error_of(proxy)
                if e is None:
                    winner = PROXY                           # the proxy answered after all: no failover
                    break
                proxy_err, proxy_reason = e, router.reason_for(PROXY, e)
                if proxy_reason is not None:
                    router.failed_over(proxy_reason, _status(e))
            if fallback in done:
                e = _error_of(fallback)
                if e is None:
                    winner = FALLBACK
                    break
                fallback_err = e
        if winner is None:
            raise proxy_err if proxy_reason is None and proxy_err is not None else fallback_err
        if winner == PROXY:
            router.proxy_answered(key, router.clock() - started, late=True)
        elif proxy_err is None:
            router.failed_over(STALLED)
        return winner, tasks[winner].result()
    finally:
        losers = [t for r, t in tasks.items() if r != winner]

        async def cleanup() -> None:
            await _reap([timer])
            await _reap(losers, discard)

        # A cancel that lands while the loser is being reaped would otherwise lose the winner's opened stream (it is not the
        # caller's yet, so nobody closes it) and cut the loser's own close short: both run to the end, then the cancel goes on.
        await _settle_after(cleanup, tasks.get(winner) if winner is not None else None, discard)


async def call_routed(router: Router, fn: Callable[[str], Awaitable[Any]], *, hedge_s: float | None = None,
                      key: Any = None) -> Any:
    """`await fn(route)` on the first route that works. A non-failover error (or the last route's error) propagates unchanged:
    callers that match SDK exception types keep working. With `hedge_s` (small idempotent calls only) a proxy that has not
    answered by then races the fallback (`_race`; `key`, usually the model, keys the adaptive delay)."""
    order, probe = router.plan()
    if hedge_s is not None and order[:2] == (PROXY, FALLBACK):
        route, result = await _race(router, fn, hedge_s, key=("call", key))
        router.succeeded(route, probe)
        return result
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


_END = object()   # a route's stream ended


async def _anext(it) -> Any:
    try:
        return await it.__anext__()
    except StopAsyncIteration:
        return _END


async def _aclose(obj) -> None:
    close = getattr(obj, "aclose", None)
    if close is not None:
        try:
            await close()
        except Exception as e:  # noqa: BLE001 - closing is best effort; leave a trace for diagnosis
            log.debug("closing a route stream failed: %s", type(e).__name__)


async def _close_pair(inner, it) -> None:
    """Close a route's iterator (an async generator mid-iteration) and then its stream."""
    if it is not None and it is not inner:
        await _aclose(it)
    if inner is not None:
        await _aclose(inner)


class RoutedStream:
    """A stream of normalized events (`kind` in start | text | stop, `stop_reason` on stop) over the router's routes.

    `open_fn(route)` returns (awaitably) the stream of one route: an async iterable with an optional `aclose()`, `headers` and
    `new_connection`, and optionally `activity` (a counter of everything the server sent, pings included) and `quiet_ok` (True
    while long silent gaps are normal, inside a thinking block) for the idle limit. A route stream may also yield a `CONTENT`
    marker when its first content event arrives (thinking blocks yield no normalized event of their own); markers are never
    yielded by this stream. A proxy stream that ends without a stop event, or with a stop event that has no stop_reason, is broken.

    With a fallback and `router.hedge_s`, `open()` races the proxy against the fallback (`_race`) on the first content (a `CONTENT`
    marker, else the first text or stop event, or the end of the stream), so it returns once one route has reached it. The
    events an attempt read before that (its `start`, which carries the usage) are held: the winner's are the first ones this
    stream yields, in order and once; the loser's are dropped with its stream. `racing` is True while that
    race's proxy attempt is still pending (the live transport's lane hedge stands down when it sees it at its hedge time; a proxy
    that failed before then leaves a single direct request, which the lane hedge covers as any other) and `hedged` once the
    fallback request was started. `key` (usually the model) keys the race's adaptive delay (`Router.hedge_delay`)."""

    def __init__(self, router: Router, open_fn: Callable[[str], Awaitable[Any]], key: Any = None) -> None:
        self.router = router
        self._open_fn = open_fn
        self._key = ("stream", key)
        self._order, self._probe = router.plan()
        self._i = 0
        self.inner: Any = None
        self.route: str | None = None
        self.output_seen = False
        self.racing = False
        self.hedged = False
        self._it: Any = None          # the inner stream's iterator
        self._pending: deque = deque()   # events already read (the race winner's held events), yielded next
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

    def _can_race(self, route: str) -> bool:
        r = self.router
        return (route == PROXY and r.has_fallback and r.hedge_s is not None
                and self._order[self._i + 1:self._i + 2] == (FALLBACK,))

    async def _first(self, route: str) -> tuple[Any, Any, list]:
        """Open `route` and read it up to its first content, the race's milestone: (stream, iterator, held events). The held
        events are in order and end with the milestone event (a text or stop event, or _END from a fallback that ended); a
        `CONTENT` marker ends the reading but is not kept. Once the proxy has sent something, the idle limit watches its next
        events (the race's hedge watches the wait for the first)."""
        from .runtime.transport import StreamBroken

        inner = await self._open_fn(route)
        it = None
        held: list = []
        idle_s = self.router.idle_s if route == PROXY else None
        try:
            it = inner.__aiter__()
            while True:
                ev = await (self._next_watched(inner, it, idle_s) if held and idle_s is not None else _anext(it))
                if ev is _END:
                    if route == PROXY:
                        raise StreamBroken("stream ended before the message was complete")
                    held.append(_END)
                    break
                kind = getattr(ev, "kind", None)
                if kind == CONTENT:
                    break
                if kind == "stop" and route == PROXY and getattr(ev, "stop_reason", None) is None:
                    raise StreamBroken("stream ended before the message was complete")
                held.append(ev)
                if kind in _MILESTONE_KINDS:
                    break
        except BaseException:
            await _close_pair(inner, it)
            raise
        return inner, it, held

    async def _discard(self, opened: tuple[Any, Any, Any]) -> None:
        await _close_pair(opened[0], opened[1])

    def _on_hedge(self) -> None:
        self.hedged = True

    async def _first_racing(self, route: str) -> tuple[Any, Any, Any]:
        """`_first` for the race: the proxy attempt clears `racing` the moment it finishes (won, failed or cancelled)."""
        try:
            return await self._first(route)
        finally:
            if route == PROXY:
                self.racing = False

    async def open(self) -> "RoutedStream":
        while True:
            route = self._order[self._i]
            if self._can_race(route):
                self.racing = True
                try:
                    route, (inner, it, first) = await _race(self.router, self._first_racing, self.router.hedge_s,
                                                            discard=self._discard, on_hedge=self._on_hedge, key=self._key)
                finally:
                    self.racing = False
                self._i = self._order.index(route)
                self.inner, self._it, self.route = inner, it, route
                self._pending = deque(first)
                return self
            try:
                self.inner = await self._open_fn(route)
            except Exception as e:  # noqa: BLE001
                if not self._next_route(route, e):
                    raise
                continue
            self._it = None
            self._pending.clear()
            self.route = route
            return self

    async def _close_inner(self) -> None:
        inner, it = self.inner, self._it
        self.inner = self._it = None
        self._pending.clear()
        await _close_pair(inner, it)

    async def _next_watched(self, inner, it, idle_s: float) -> Any:
        """The next event of a proxy stream, or StreamStalled when nothing at all arrived for `idle_s` (pings and thinking deltas
        count, and inside a thinking block the limit waits: the proxy's read timeout still applies there)."""
        from .runtime.transport import StreamStalled

        loop = asyncio.get_running_loop()
        nxt = loop.create_task(_anext(it))
        try:
            seen = getattr(inner, "activity", None)
            while True:
                timer = loop.create_task(self.router.sleep(idle_s))
                try:
                    await asyncio.wait({nxt, timer}, return_when=asyncio.FIRST_COMPLETED)
                finally:
                    await _reap([timer])
                if nxt.done():
                    return nxt.result()
                now = getattr(inner, "activity", None)
                if now != seen:
                    seen = now
                    continue
                if getattr(inner, "quiet_ok", False):
                    continue
                raise StreamStalled(f"no event from the proxy for {idle_s:g} s")
        finally:
            if not nxt.done():
                await _reap([nxt])

    async def _next(self, route: str) -> Any:
        if self._closed or self.inner is None:
            return _END
        if self._pending:
            return self._pending.popleft()
        if self._it is None:
            self._it = self.inner.__aiter__()
        if route == PROXY and self.router.has_fallback and self.router.idle_s is not None:
            return await self._next_watched(self.inner, self._it, self.router.idle_s)
        return await _anext(self._it)

    async def __aiter__(self):
        from .runtime.transport import StreamBroken

        if self.inner is None:
            await self.open()
        while True:
            route = self.route
            try:
                stopped = False
                while True:
                    ev = await self._next(route)
                    if ev is _END:
                        break
                    kind = getattr(ev, "kind", None)
                    if kind == CONTENT:
                        continue                             # the race's marker, never the consumer's
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
