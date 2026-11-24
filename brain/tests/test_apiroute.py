"""The API route (verse_brain/apiroute.py, docs/api-route.md): an optional base URL (a local Anthropic-compatible proxy) with the
direct API as its fallback. Fake transports and fake SDK clients only: no network, no Keychain, no model call."""

from __future__ import annotations

import asyncio
import json
from argparse import Namespace
from types import SimpleNamespace

import pytest
from test_runtime_helpers import make, run, session_copy, start

from verse_brain import apiroute
from verse_brain.apiroute import (DIRECT, DIRECT_API_URL, EV_FALLBACK, EV_PRIMARY, FALLBACK, PROXY, PROXY_PLACEHOLDER_KEY,
                                  Credentials, Router, RoutedStream, call_routed, failover_reason, load_credentials)
from verse_brain.prep import keychain
from verse_brain.prep.keychain import KeychainError
from verse_brain.runtime import __main__ as entry
from verse_brain.runtime.engine import Brain
from verse_brain.runtime.fake import FakeTransport, FaultTransport, lines_script
from verse_brain.runtime.protocol import ListEmitter
from verse_brain.runtime.settings import Config
from verse_brain.runtime.transport import (AnthropicTransport, AuthFailed, BadRequest, CreditExhausted, Ev, Offline,
                                           Overloaded, RateLimited, StreamBroken, TransportError)

URL = "http://127.0.0.1:8317"
PROXY_KEY = "sk-proxy-test-0000000000"
DIRECT_KEY = "sk-direct-test-1111111111"


class Clock:
    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t


def router(fallback: bool = True, base: str | None = URL):
    events: list[tuple[str, dict]] = []
    clock = Clock()
    r = Router(base, fallback, clock=clock, sink=lambda ev, **f: events.append((ev, f)))
    return r, clock, events


# ---------------------------------------------------------------- configuration
def test_no_base_url_by_default(monkeypatch, tmp_path):
    monkeypatch.delenv("VERSE_API_BASE_URL", raising=False)
    monkeypatch.setenv("VERSE_API_CONFIG_FILE", str(tmp_path / "missing.json"))
    assert apiroute.base_url() is None


def test_base_url_from_the_config_file_and_env_wins(monkeypatch, tmp_path):
    f = tmp_path / "api.json"
    f.write_text(json.dumps({"base_url": "http://127.0.0.1:8317/"}), encoding="utf-8")
    monkeypatch.setenv("VERSE_API_CONFIG_FILE", str(f))
    monkeypatch.delenv("VERSE_API_BASE_URL", raising=False)
    assert apiroute.base_url() == URL                      # trailing slash dropped
    monkeypatch.setenv("VERSE_API_BASE_URL", "http://127.0.0.1:9999")
    assert apiroute.base_url() == "http://127.0.0.1:9999"
    monkeypatch.setenv("VERSE_API_BASE_URL", "")             # set but empty: direct, whatever the file says
    assert apiroute.base_url() is None


@pytest.mark.parametrize("raw", ["127.0.0.1:8317", "ftp://127.0.0.1", "   ", "http://", "http://:8317", "http://127.0.0.1:port",
                                 "http://user:pw@127.0.0.1:8317", "http://user@127.0.0.1:8317", "http://127.0.0.1:8317/?k=v",
                                 "http://127.0.0.1:8317/#frag"])
def test_a_base_url_that_is_not_a_plain_http_url_is_ignored(monkeypatch, caplog, raw):
    monkeypatch.setenv("VERSE_API_BASE_URL", raw)
    assert apiroute.base_url() is None
    assert all(raw.strip() not in r.getMessage() for r in caplog.records if raw.strip())   # the value is never logged


@pytest.mark.parametrize("raw, warns", [
    ("http://127.0.0.1:8317", False), ("http://localhost:8317", False), ("http://[::1]:8317", False),
    ("https://proxy.example.com", False), ("http://proxy.example.com:8317", True), ("http://10.0.0.5:8317", True),
])
def test_http_to_a_remote_host_is_accepted_with_a_warning(monkeypatch, caplog, raw, warns):
    monkeypatch.setenv("VERSE_API_BASE_URL", raw)
    with caplog.at_level("WARNING", logger="verse.apiroute"):
        assert apiroute.base_url() == raw
    assert any("clear text" in r.getMessage() for r in caplog.records) is warns
    assert all(raw not in r.getMessage() for r in caplog.records)


def test_an_unreadable_config_file_means_direct(monkeypatch, tmp_path):
    f = tmp_path / "api.json"
    f.write_text("{not json", encoding="utf-8")
    monkeypatch.setenv("VERSE_API_CONFIG_FILE", str(f))
    monkeypatch.delenv("VERSE_API_BASE_URL", raising=False)
    assert apiroute.base_url() is None


# ---------------------------------------------------------------- credentials
def _no_proxy_read():
    raise AssertionError("the proxy item must not be read without a base URL")


def missing():
    raise KeychainError("Keychain item service=verse-anthropic account=x missing (exit 44)")


def test_no_base_url_ignores_the_proxy_item(monkeypatch):
    monkeypatch.setenv("VERSE_API_BASE_URL", "")
    c = load_credentials(lambda: DIRECT_KEY, _no_proxy_read)
    assert (c.key, c.base_url, c.proxy_key, c.has_fallback) == (DIRECT_KEY, None, None, False)
    assert c.targets() == {DIRECT: (DIRECT_KEY, None)}
    with pytest.raises(KeychainError):
        load_credentials(missing, _no_proxy_read)


def test_base_url_sends_the_proxy_key_to_the_proxy_and_the_anthropic_key_direct(monkeypatch):
    monkeypatch.setenv("VERSE_API_BASE_URL", URL)
    c = load_credentials(lambda: DIRECT_KEY, lambda: PROXY_KEY)
    assert c.base_url == URL and c.has_fallback
    assert c.targets() == {PROXY: (PROXY_KEY, URL), FALLBACK: (DIRECT_KEY, "https://api.anthropic.com")}


def test_an_existing_install_that_only_sets_a_base_url_never_sends_its_anthropic_key_to_the_proxy(monkeypatch, caplog):
    """The review blocker: `verse-anthropic` holds the real Anthropic key (the app's Settings screen writes it). Setting only the
    base URL must make that key the fallback, never the proxy's credential."""
    monkeypatch.setenv("VERSE_API_BASE_URL", URL)
    with caplog.at_level("WARNING", logger="verse.apiroute"):
        c = load_credentials(lambda: DIRECT_KEY, lambda: None)
    t = c.targets()
    assert t[PROXY] == (PROXY_PLACEHOLDER_KEY, URL) and t[FALLBACK] == (DIRECT_KEY, DIRECT_API_URL)
    assert all(key != DIRECT_KEY for key, url in t.values() if url == URL)
    assert any("placeholder" in r.getMessage() for r in caplog.records)
    assert all(DIRECT_KEY not in r.getMessage() for r in caplog.records)


def test_the_anthropic_key_is_required_with_a_base_url_too(monkeypatch):
    monkeypatch.setenv("VERSE_API_BASE_URL", URL)
    with pytest.raises(KeychainError):
        load_credentials(missing, lambda: PROXY_KEY)


def test_keys_never_appear_in_repr():
    c = Credentials(DIRECT_KEY, URL, PROXY_KEY)
    assert PROXY_KEY not in repr(c) and DIRECT_KEY not in repr(c)


def test_redact_scrubs_both_keys_once_read(monkeypatch):
    class R:
        def __init__(self, out):
            self.returncode, self.stdout = 0, out + "\n"

    def fake_run(cmd, **kw):
        return R(PROXY_KEY if cmd[cmd.index("-s") + 1] == keychain.PROXY_KEYCHAIN_SERVICE else DIRECT_KEY)

    monkeypatch.setattr(keychain.subprocess, "run", fake_run)
    monkeypatch.setattr(keychain, "_LOADED", set())
    assert keychain.read_api_key() == DIRECT_KEY and keychain.read_proxy_key() == PROXY_KEY
    text = keychain.redact(f"proxy {PROXY_KEY} direct {DIRECT_KEY}", None)
    assert PROXY_KEY not in text and DIRECT_KEY not in text and text.count("[redacted-key]") == 2
    assert PROXY_KEY not in keychain.redact(f"x {PROXY_KEY}", DIRECT_KEY)   # the caller's key plus every key read


def test_a_missing_proxy_item_is_none(monkeypatch):
    class R:
        returncode, stdout = 44, ""

    monkeypatch.setattr(keychain.subprocess, "run", lambda cmd, **kw: R())
    assert keychain.read_proxy_key() is None


# ---------------------------------------------------------------- classification
@pytest.mark.parametrize("err, reason", [
    (Offline("APIConnectionError"), "offline"),
    (Offline("ConnectError"), "offline"),
    (Offline("APITimeoutError"), "timeout"),
    (Offline("ReadTimeout"), "timeout"),
    (StreamBroken("cut"), "stream_broken"),
    (AuthFailed("401", status=401), "auth"),
    (AuthFailed("403", status=403), "auth"),
    (RateLimited("429", status=429), "rate_limited"),
    (Overloaded("500", status=500), "overloaded"),
    (Overloaded("529 overloaded_error", status=529), "overloaded"),
    (CreditExhausted("402", status=402), "credit"),
    (BadRequest("404 not_found_error", status=404), "not_supported"),
    (BadRequest("400 invalid_request_error", status=400), None),
    (BadRequest("413 request_too_large", status=413), None),
    (BadRequest("422", status=422), None),
    (TransportError("ValueError"), None),
])
def test_failover_reason(err, reason):
    assert failover_reason(err) == reason


def test_failover_reason_maps_raw_http_errors():
    import httpx2

    assert failover_reason(httpx2.ConnectError("refused")) == "offline"
    assert failover_reason(httpx2.ReadTimeout("slow")) == "timeout"
    assert failover_reason(ValueError("bug")) is None


# ---------------------------------------------------------------- router
def test_order_per_setup():
    assert Router(None, True).order() == (DIRECT,)          # no base URL: the fallback is ignored
    assert Router(URL, False).order() == (PROXY,)
    assert Router(URL, True).order() == (PROXY, FALLBACK)
    assert Router(None, True).has_fallback is False


def test_cool_off_then_back_to_the_proxy():
    r, clock, events = router()
    r.failed_over("offline", None)
    assert r.order() == (FALLBACK,)
    clock.t += 59.0
    assert r.order() == (FALLBACK,)
    clock.t += 1.5
    order, probe = r.plan()
    assert order == (PROXY, FALLBACK) and probe is not None  # the cool-off is over: one probe of the proxy
    r.failed_over("offline", None)                           # the probe failed: same route, a new cool-off, no event
    assert r.order() == (FALLBACK,) and [e for e, _ in events] == [EV_FALLBACK]
    r.succeeded(FALLBACK)
    clock.t += 61.0
    order, probe = r.plan()
    r.succeeded(PROXY, probe)
    assert [e for e, _ in events] == [EV_FALLBACK, EV_PRIMARY] and r.order() == (PROXY, FALLBACK)
    ev, f = events[0]
    assert f == {"reason": "offline", "status": None, "cool_off_s": 60.0, "failovers": 1}
    ev, f = events[1]
    assert f["fallback_calls"] == 1 and f["failovers"] == 1 and f["fallback_s"] == pytest.approx(121.5)


def test_events_hold_numbers_and_enums_only():
    r, _clock, events = router()
    r.failed_over("auth", 401)
    clock = r.clock
    clock.t += 61
    r.succeeded(PROXY, r.plan()[1])
    assert [e for e, _ in events] == [EV_FALLBACK, EV_PRIMARY]
    for _ev, fields in events:
        for v in fields.values():
            assert v is None or isinstance(v, (int, float)) or v in ("offline", "timeout", "auth", "rate_limited",
                                                                    "overloaded", "credit", "stream_broken")
    assert "http" not in json.dumps(events) and "sk-" not in json.dumps(events)


def test_not_supported_sends_one_request_direct_without_a_cool_off():
    r, _clock, events = router()
    r.failed_over("not_supported", 404)
    assert r.order() == (PROXY, FALLBACK) and events == []


def test_only_one_request_probes_the_proxy_after_the_cool_off():
    r, clock, _events = router()
    r.failed_over("offline")
    clock.t += 61
    first, probe = r.plan()
    second, none = r.plan()                                  # a concurrent request while the probe is in flight
    assert first == (PROXY, FALLBACK) and probe is not None and second == (FALLBACK,) and none is None
    clock.t += 61                                            # the probe never reported (cancelled): the next one comes a cool-off later
    third, probe2 = r.plan()
    assert third == (PROXY, FALLBACK) and probe2 != probe


def test_a_late_proxy_success_does_not_cancel_the_cool_off():
    """A proxy request that started before the failover and succeeds afterwards carries no probe token."""
    r, _clock, events = router()
    _order, token = r.plan()                                 # request A starts on the proxy (no probe)
    r.failed_over("overloaded", 529)                         # request B fails on the proxy: failover
    r.succeeded(PROXY, token)                                # request A succeeds late
    assert r.on_fallback and r.order() == (FALLBACK,) and [e for e, _ in events] == [EV_FALLBACK]


def test_a_late_proxy_success_through_call_routed_keeps_the_fallback():
    r, _clock, events = router()
    gate = asyncio.Event()

    async def slow(route):
        await gate.wait()
        return "late"

    async def failing(route):
        if route == PROXY:
            raise Overloaded("529 overloaded_error", status=529)
        return "direct"

    async def go():
        a = asyncio.ensure_future(call_routed(r, slow))
        await asyncio.sleep(0)
        assert await call_routed(r, failing) == "direct"
        gate.set()
        return await a

    assert run(go()) == "late"
    assert r.on_fallback and [e for e, _ in events] == [EV_FALLBACK]


def test_a_failing_sink_never_fails_a_request():
    r = Router(URL, True, sink=lambda ev, **f: 1 / 0)
    r.failed_over("offline")
    assert r.on_fallback


# ---------------------------------------------------------------- call_routed
def calls_by_route(results: dict):
    seen: list[str] = []

    async def fn(route):
        seen.append(route)
        r = results[route]
        if isinstance(r, BaseException):
            raise r
        return r

    return fn, seen


def test_call_routed_fails_over_and_stays_on_the_fallback():
    r, _clock, events = router()
    fn, seen = calls_by_route({PROXY: Offline("ConnectError"), FALLBACK: "ok"})
    assert run(call_routed(r, fn)) == "ok" and seen == [PROXY, FALLBACK]
    assert run(call_routed(r, fn)) == "ok" and seen == [PROXY, FALLBACK, FALLBACK]   # cool-off: no second proxy attempt
    assert [e for e, _ in events] == [EV_FALLBACK] and r.fallback_calls == 2


def test_call_routed_keeps_request_errors_on_the_proxy():
    r, _clock, events = router()
    fn, seen = calls_by_route({PROXY: BadRequest("400 invalid_request_error", status=400), FALLBACK: "ok"})
    with pytest.raises(BadRequest):
        run(call_routed(r, fn))
    assert seen == [PROXY] and events == [] and not r.on_fallback


def test_call_routed_without_a_fallback_key_surfaces_the_proxy_error():
    r, _clock, events = router(fallback=False)
    fn, seen = calls_by_route({PROXY: Offline("ConnectError")})
    with pytest.raises(Offline):
        run(call_routed(r, fn))
    assert seen == [PROXY] and events == []


def test_call_routed_without_a_base_url_is_the_direct_call():
    r, _clock, events = router(base=None)
    fn, seen = calls_by_route({DIRECT: AuthFailed("401", status=401)})
    with pytest.raises(AuthFailed):
        run(call_routed(r, fn))
    assert seen == [DIRECT] and events == []


def test_call_routed_raises_the_fallbacks_error_when_both_fail():
    r, _clock, _events = router()
    fn, _seen = calls_by_route({PROXY: Offline("ConnectError"), FALLBACK: AuthFailed("401", status=401)})
    with pytest.raises(AuthFailed):
        run(call_routed(r, fn))


def test_call_routed_reraises_the_original_sdk_exception():
    import httpx2

    r, _clock, _events = router(fallback=False)
    fn, _seen = calls_by_route({PROXY: httpx2.ConnectError("refused")})
    with pytest.raises(httpx2.ConnectError):                 # prep's retry_transient matches the SDK's own types
        run(call_routed(r, fn))


# ---------------------------------------------------------------- RoutedStream
class ListStream:
    """A route's stream: yields `evs`; an exception in the list is raised at that point."""

    def __init__(self, evs, headers=None):
        self.evs = evs
        self.headers = headers or {}
        self.new_connection = False
        self.closed = False

    async def __aiter__(self):
        for ev in self.evs:
            if isinstance(ev, BaseException):
                raise ev
            yield ev

    async def aclose(self):
        self.closed = True


START = Ev("start", usage={"input_tokens": 5})
STOP = Ev("stop", stop_reason="end_turn", usage={"input_tokens": 5, "output_tokens": 3})


def opener(streams: dict):
    opened: list[str] = []
    made: list[ListStream] = []

    async def open_route(route):
        opened.append(route)
        s = streams[route]
        if isinstance(s, BaseException):
            raise s
        st = ListStream(list(s), headers={"route": route})
        made.append(st)
        return st

    return open_route, opened, made


async def consume(stream):
    out = []
    async for ev in stream:
        out.append(ev)
    return out


def texts(evs):
    return "".join(e.text for e in evs if e.kind == "text")


def test_stream_open_failure_goes_to_the_fallback():
    r, _clock, events = router()
    fn, opened, _ = opener({PROXY: Offline("ConnectError"), FALLBACK: [START, Ev("text", text="hi"), STOP]})

    async def go():
        s = await RoutedStream(r, fn).open()
        assert s.headers == {"route": FALLBACK} and s.route == FALLBACK
        return await consume(s)

    evs = run(go())
    assert opened == [PROXY, FALLBACK] and texts(evs) == "hi" and [e for e, _ in events] == [EV_FALLBACK]


def test_stream_broken_before_text_restarts_without_duplicates():
    r, _clock, events = router()
    fn, opened, made = opener({PROXY: [START, Offline("ReadError")],
                               FALLBACK: [START, Ev("text", text="one"), Ev("text", text=" two"), STOP]})

    evs = run(consume(RoutedStream(r, fn)))
    assert opened == [PROXY, FALLBACK] and made[0].closed
    assert texts(evs) == "one two" and [e.kind for e in evs].count("stop") == 1
    assert events[0][1]["reason"] == "offline"


def test_stream_broken_after_text_is_not_spliced():
    """Text already reached the consumer (the overlay, the ask panel): no restart into the same stream, the caller gets the
    error, and the router has switched so the caller's own retry goes direct."""
    r, _clock, events = router()
    fn, opened, _ = opener({PROXY: [START, Ev("text", text="half"), Offline("ReadError")],
                            FALLBACK: [START, Ev("text", text="whole"), STOP]})
    got: list = []

    async def go():
        async for ev in RoutedStream(r, fn):
            got.append(ev)

    with pytest.raises(Offline):
        run(go())
    assert opened == [PROXY] and texts(got) == "half"
    assert r.order() == (FALLBACK,) and [e for e, _ in events] == [EV_FALLBACK]
    evs = run(consume(RoutedStream(r, fn)))                 # the retry: straight to the fallback
    assert texts(evs) == "whole" and opened == [PROXY, FALLBACK]


def test_a_proxy_stream_without_a_stop_reason_is_broken():
    r, _clock, events = router()
    fn, opened, _ = opener({PROXY: [START, Ev("stop", stop_reason=None)],
                            FALLBACK: [START, Ev("text", text="ok"), STOP]})
    evs = run(consume(RoutedStream(r, fn)))
    assert opened == [PROXY, FALLBACK] and texts(evs) == "ok" and events[0][1]["reason"] == "stream_broken"

    r2, _c, _e = router()
    fn, opened, _ = opener({PROXY: [START, Ev("text", text="cut")], FALLBACK: [START, STOP]})   # ends with no stop at all

    async def go():
        async for _ev in RoutedStream(r2, fn):
            pass

    with pytest.raises(StreamBroken):
        run(go())
    assert isinstance(StreamBroken(), Offline) and r2.on_fallback


def test_stream_request_error_stays_on_the_proxy():
    r, _clock, events = router()
    fn, opened, _ = opener({PROXY: BadRequest("400 invalid_request_error", status=400), FALLBACK: [START, STOP]})
    with pytest.raises(BadRequest):
        run(RoutedStream(r, fn).open())
    assert opened == [PROXY] and events == []


def test_stream_success_on_the_proxy_after_the_cool_off_reports_primary():
    r, clock, events = router()
    r.failed_over("offline")
    clock.t += 61
    fn, opened, _ = opener({PROXY: [START, Ev("text", text="x"), STOP], FALLBACK: [START, STOP]})
    run(consume(RoutedStream(r, fn)))
    assert opened == [PROXY] and [e for e, _ in events] == [EV_FALLBACK, EV_PRIMARY] and not r.on_fallback


def test_a_stream_closed_by_the_consumer_is_not_a_failure():
    r, _clock, events = router()
    fn, opened, _ = opener({PROXY: [START, Ev("text", text="a"), Ev("text", text="b"), STOP], FALLBACK: [START, STOP]})

    async def go():
        s = RoutedStream(r, fn)
        async for ev in s:
            if ev.kind == "text":
                await s.aclose()
                break

    run(go())
    assert opened == [PROXY] and events == [] and not r.on_fallback


# ---------------------------------------------------------------- the live transport
class BreakingStream:
    """A FakeTransport-like stream that dies after `n_text` text events."""

    def __init__(self, n_text: int, err: BaseException):
        self.n_text, self.err = n_text, err
        self.headers, self.new_connection = {}, False

    async def __aiter__(self):
        yield Ev("start", usage={"input_tokens": 1})
        for i in range(self.n_text):
            yield Ev("text", text=f"p{i} ")
        raise self.err

    async def aclose(self):
        pass


def routed_transport(inners: dict, fallback: bool = True) -> AnthropicTransport:
    """The real AnthropicTransport (real routing, SDK clients built but never used) with each route's calls sent to a fake."""
    t = AnthropicTransport(Credentials(DIRECT_KEY, URL, PROXY_KEY))
    if not fallback:
        t.router = Router(URL, False)

    async def _open(target, route, request, lane):
        return await inners[target].open_stream(route, request, lane)

    async def _create(target, route, request, lane):
        return await inners[target].create(route, request, lane)

    async def _ping(target, model, lane):
        return await inners[target].ping(model, lane)

    t._open, t._create, t._ping = _open, _create, _ping
    return t


def test_transport_builds_one_client_set_per_route(monkeypatch):
    import anthropic

    built: list[dict] = []

    class Rec:
        def __init__(self, **kw):
            built.append(kw)

        async def close(self):
            pass

    monkeypatch.setattr(anthropic, "AsyncAnthropic", Rec)
    AnthropicTransport(Credentials(DIRECT_KEY, URL, PROXY_KEY))
    proxy = [b for b in built if b["api_key"] == PROXY_KEY]
    direct = [b for b in built if b["api_key"] == DIRECT_KEY]
    assert len(proxy) == len(direct) == 4                    # (Haiku, Sonnet) x 2 lanes per route
    assert all(b["base_url"] == URL and b["max_retries"] == 0 and b["timeout"].connect == 1.0 for b in proxy)
    assert all(b["base_url"] == "https://api.anthropic.com" and b["timeout"].connect == 10.0 for b in direct)
    built.clear()
    monkeypatch.setenv("VERSE_API_BASE_URL", "")
    AnthropicTransport(DIRECT_KEY)                           # a bare key, no base URL: the single direct set, as before
    assert len(built) == 4 and all(b["base_url"] is None and b["api_key"] == DIRECT_KEY for b in built)


def test_transport_bare_key_reads_the_proxy_item_only_with_a_base_url(monkeypatch):
    seen = []
    monkeypatch.setattr(keychain, "read_proxy_key", lambda: seen.append(1) or PROXY_KEY)
    monkeypatch.setenv("VERSE_API_BASE_URL", "")
    assert AnthropicTransport(DIRECT_KEY).router.order() == (DIRECT,) and seen == []
    monkeypatch.setenv("VERSE_API_BASE_URL", URL)
    assert AnthropicTransport(DIRECT_KEY).router.order() == (PROXY, FALLBACK) and seen == [1]


def test_sdk_clients_ignore_the_auth_token_and_base_url_environment(monkeypatch):
    """An ANTHROPIC_AUTH_TOKEN in the environment is not sent (the SDK reads no credential variable once api_key is given), and an
    ANTHROPIC_BASE_URL cannot redirect the fallback's Anthropic key."""
    from verse_brain.prep.model import AnthropicPrepModel
    from verse_brain.runtime.ask import AnthropicAskClient

    monkeypatch.setenv("ANTHROPIC_AUTH_TOKEN", "tok-env-test-2222222222")
    monkeypatch.setenv("ANTHROPIC_BASE_URL", "http://127.0.0.1:9")
    creds = Credentials(DIRECT_KEY, URL, PROXY_KEY)
    clients = [*AnthropicTransport(creds)._clients.items(),
               *(((t,), c) for t, c in AnthropicAskClient(creds)._clients.items()),
               *(((t,), c) for t, c in AnthropicPrepModel(creds)._clients.items())]
    assert len(clients) == 8 + 2 + 2
    for key, c in clients:
        assert c.auth_token is None
        assert str(c.base_url).rstrip("/") == (URL if key[0] == PROXY else DIRECT_API_URL)


def test_bad_request_text_from_a_proxy_is_scrubbed(monkeypatch):
    import anthropic
    import httpx2

    from verse_brain.runtime.transport import map_sdk_error

    monkeypatch.setattr(keychain, "_LOADED", {PROXY_KEY})
    req = httpx2.Request("POST", URL + "/v1/messages")
    msg = f"bad key {PROXY_KEY}; upstream said Bearer abc.def-ghi and sk-ant-oat01-ZZZZZZZZZZZZ; field max_tokens"
    e = map_sdk_error(anthropic.BadRequestError(msg, response=httpx2.Response(400, request=req), body=None))
    text = str(e)
    assert isinstance(e, BadRequest) and "max_tokens" in text
    assert PROXY_KEY not in text and "abc.def-ghi" not in text and "ZZZZZZZZ" not in text


def test_transport_stream_restarts_on_the_fallback_before_text():
    fb = FakeTransport(lambda info: lines_script("SAY: from the fallback"))

    class Proxy(FakeTransport):
        async def open_stream(self, route, request, lane):
            return BreakingStream(0, Offline("ReadError"))

    t = routed_transport({PROXY: Proxy(), FALLBACK: fb})

    async def go():
        s = await t.open_stream("F", {"model": "claude-haiku-5-5", "messages": []}, 0)
        evs = await consume(s)
        await s.aclose()
        return evs

    evs = run(go())
    assert texts(evs) == "SAY: from the fallback" and len(fb.calls) == 1 and t.router.on_fallback


def test_transport_create_and_ping_fail_over():
    t = routed_transport({PROXY: FaultTransport(None, Offline("ConnectError")), FALLBACK: FakeTransport()})
    usage, _h, stop = run(t.create("F", {"model": "claude-haiku-5-5"}, 0))
    assert usage["cache_creation_input_tokens"] == 4000 and stop == "max_tokens"
    assert run(t.ping("claude-haiku-5-5", 0))["ms"] == 1.0


# ---------------------------------------------------------------- the meeting brain (startup check, events.jsonl)
def brain_on(transport):
    em = ListEmitter()
    b = Brain(transport, em, Config())
    b.start_background = False
    return b, em


def _ready(em):
    st = [e for e in em.of("status") if e["state"] != "warming"]
    return st[-1] if st else None


def test_dead_proxy_with_a_fallback_is_not_fatal_and_is_logged(tmp_path, monkeypatch):
    monkeypatch.setenv("VERSE_EVENTS", "1")
    t = routed_transport({PROXY: FaultTransport(None, Offline("ConnectError")), FALLBACK: FakeTransport()})
    b, em = brain_on(t)
    sdir = session_copy(tmp_path)
    run(start(b, sdir))
    assert _ready(em)["state"] == "ready", em.of("status")
    run(b.shutdown())
    evs = [json.loads(ln) for ln in (sdir / "events.jsonl").read_text(encoding="utf-8").splitlines()]
    route = [e for e in evs if e["ev"].startswith("api_route")]
    assert [e["ev"] for e in route] == [EV_FALLBACK] and route[0]["reason"] == "offline" and route[0]["cool_off_s"] == 60.0
    text = (sdir / "events.jsonl").read_text(encoding="utf-8")
    assert PROXY_KEY not in text and DIRECT_KEY not in text and "127.0.0.1" not in text


def test_rejected_proxy_key_with_a_fallback_is_not_fatal():
    t = routed_transport({PROXY: FaultTransport(None, AuthFailed("401 authentication_error", status=401)),
                          FALLBACK: FakeTransport()})
    b, em = brain_on(t)
    run(start(b))
    assert _ready(em)["state"] == "ready", em.of("status")


@pytest.mark.parametrize("fault, state, reason", [
    (Offline("ConnectError"), "offline", "no_connection"),
    (AuthFailed("401 authentication_error", status=401), "error", "invalid_api_key"),
])
def test_without_a_fallback_the_proxy_failure_is_the_status(fault, state, reason):
    t = routed_transport({PROXY: FaultTransport(None, fault)}, fallback=False)
    b, em = brain_on(t)
    run(start(b))
    st = _ready(em)
    assert st["state"] == state and st["reason"] == reason, em.of("status")


def test_dead_proxy_and_rejected_fallback_is_invalid_api_key():
    t = routed_transport({PROXY: FaultTransport(None, Offline("ConnectError")),
                          FALLBACK: FaultTransport(None, AuthFailed("401 authentication_error", status=401))})
    b, em = brain_on(t)
    run(start(b))
    st = _ready(em)
    assert st["state"] == "error" and st["reason"] == "invalid_api_key", em.of("status")


def _args(**kw) -> Namespace:
    base = dict(no_api=False, fake=False, fake_bank=False, no_embed=True, embed=False, budget_usd=None)
    return Namespace(**{**base, **kw})


def test_no_key_at_all_with_a_base_url_is_no_api_key(monkeypatch, capsys):
    monkeypatch.setenv("VERSE_API_BASE_URL", URL)
    monkeypatch.delenv("VERSE_SIMULATE_API", raising=False)
    monkeypatch.setattr(keychain, "read_api_key", missing)
    monkeypatch.setattr(keychain, "read_proxy_key", lambda: PROXY_KEY)   # a proxy key alone is not enough
    assert run(entry.amain(_args())) == 2
    lines = [json.loads(ln) for ln in capsys.readouterr().out.splitlines() if ln.strip()]
    st = [ln for ln in lines if ln.get("type") == "status"]
    assert len(st) == 1 and st[0]["reason"] == "no_api_key", lines


def test_startup_with_a_base_url_builds_a_routed_transport(monkeypatch):
    monkeypatch.setenv("VERSE_API_BASE_URL", URL)
    monkeypatch.delenv("VERSE_SIMULATE_API", raising=False)
    monkeypatch.delenv("VERSE_SIMULATE_STALL_S", raising=False)
    monkeypatch.setattr(keychain, "read_api_key", lambda: DIRECT_KEY)
    monkeypatch.setattr(keychain, "read_proxy_key", lambda: PROXY_KEY)
    built = []

    class Stop(Exception):
        pass

    def fake_transport(creds):
        built.append(creds)
        raise Stop

    import verse_brain.runtime.transport as tmod

    monkeypatch.setattr(tmod, "AnthropicTransport", fake_transport)
    with pytest.raises(Stop):
        run(entry.amain(_args()))
    assert built[0].targets() == {PROXY: (PROXY_KEY, URL), FALLBACK: (DIRECT_KEY, DIRECT_API_URL)}


# ---------------------------------------------------------------- the prep model (whole-request restart)
class SdkStream:
    def __init__(self, chunks, err=None, stop="end_turn"):
        self.chunks, self.err, self.stop = chunks, err, stop

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        return False

    @property
    def text_stream(self):
        async def gen():
            for c in self.chunks:
                yield c
            if self.err is not None:
                raise self.err
        return gen()

    async def get_final_message(self):
        u = SimpleNamespace(input_tokens=10, output_tokens=4, cache_read_input_tokens=0, cache_creation_input_tokens=0)
        return SimpleNamespace(usage=u, stop_reason=self.stop)


class SdkClient:
    def __init__(self, make_stream, count=7):
        self.make_stream, self.count, self.calls = make_stream, count, 0
        self.messages = self

    def stream(self, **kw):
        self.calls += 1
        return self.make_stream()

    async def count_tokens(self, **kw):
        if isinstance(self.count, BaseException):
            raise self.count
        return SimpleNamespace(input_tokens=self.count)

    async def close(self):
        pass


def prep_model(proxy: SdkClient, direct: SdkClient | None):
    from verse_brain.prep.model import AnthropicPrepModel

    m = AnthropicPrepModel(Credentials(DIRECT_KEY, URL, PROXY_KEY))
    m._client = proxy
    if direct is not None:
        m._clients[FALLBACK] = direct
    else:
        m._router = Router(URL, False)
    return m


def test_prep_restarts_a_broken_stream_from_scratch_on_the_fallback():
    import httpx2

    proxy = SdkClient(lambda: SdkStream(["partial ", "answer"], err=httpx2.ReadError("")))
    direct = SdkClient(lambda: SdkStream(["the whole ", "answer"]))
    out = run(prep_model(proxy, direct).generate("sys", "user", 100))
    assert out.text == "the whole answer" and proxy.calls == 1 and direct.calls == 1


def test_prep_without_a_fallback_raises_the_proxy_error():
    import httpx2

    proxy = SdkClient(lambda: SdkStream(["partial"], err=httpx2.ReadError("")))
    with pytest.raises(httpx2.ReadError):
        run(prep_model(proxy, None).generate("sys", "user", 100))


def test_prep_count_tokens_goes_direct_when_the_proxy_lacks_the_endpoint():
    import anthropic
    import httpx2

    req = httpx2.Request("POST", URL + "/v1/messages/count_tokens")
    nf = anthropic.NotFoundError("not found", response=httpx2.Response(404, request=req), body=None)
    m = prep_model(SdkClient(lambda: None, count=nf), SdkClient(lambda: None, count=42))
    assert run(m.count_request_tokens("s", "u")) == 42
    assert not m._router.on_fallback                         # one request went direct; the proxy stays primary


# ---------------------------------------------------------------- the ask client
def test_ask_client_restarts_before_text_and_counts_usage_once(monkeypatch):
    from verse_brain.runtime.ask import AnthropicAskClient, AskEv

    c = AnthropicAskClient(Credentials(DIRECT_KEY, URL, PROXY_KEY))

    async def fake_on(client, request, tap=None):
        if client is c._clients[PROXY]:
            yield AskEv("start", usage={"input_tokens": 9}, model="claude-sonnet-5-5")
            raise Overloaded("529 overloaded_error", status=529)
        yield AskEv("start", usage={"input_tokens": 9}, model="claude-sonnet-5-5")
        yield AskEv("text", text="answer")
        yield AskEv("stop", stop_reason="end_turn", usage={"input_tokens": 9, "output_tokens": 2})

    monkeypatch.setattr(c, "_stream_on", fake_on)

    async def go():
        out = []
        async for ev in c.stream({"model": "claude-sonnet-5-5"}):
            out.append(ev)
        return out

    evs = run(go())
    assert texts(evs) == "answer" and [e.kind for e in evs].count("stop") == 1 and c._router.on_fallback
    stop = [e for e in evs if e.kind == "stop"][0]
    assert stop.usage == {"input_tokens": 9, "output_tokens": 2}


def test_make_client_reads_the_proxy_item_only_with_a_base_url(monkeypatch):
    import verse_brain.runtime.ask as ask_mod

    seen = []
    monkeypatch.setattr(ask_mod, "read_api_key", lambda: DIRECT_KEY)
    monkeypatch.setattr(keychain, "read_proxy_key", lambda: seen.append(1) or PROXY_KEY)
    monkeypatch.setenv("VERSE_API_BASE_URL", "")
    assert ask_mod.make_client()._router.order() == (DIRECT,) and seen == []
    monkeypatch.setenv("VERSE_API_BASE_URL", URL)
    assert ask_mod.make_client()._router.order() == (PROXY, FALLBACK) and seen == [1]
