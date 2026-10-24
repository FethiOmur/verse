"""G1: local Gemma as the degraded-mode brain. The API is faked (FakeTransport behind FaultTransport), Gemma is faked
(FakeBackend: a scripted conversation, no model, no GPU). The wrapper sits below the unchanged engine."""

from __future__ import annotations

import asyncio
import time

import pytest
from test_runtime_helpers import FAST_OK, FIX, run, settle, start, turn

from verse_brain.runtime import fallback as fb
from verse_brain.runtime import local_llm as ll
from verse_brain.runtime.engine import Brain
from verse_brain.runtime.fake import FakeTransport, Script, default_responder, lines_script
from verse_brain.runtime.fallback import FallbackTransport, FaultTransport, wrap
from verse_brain.runtime.local_llm import LocalGemma
from verse_brain.runtime.prompt import PACK_HEADER, TRANSCRIPT_HEADER, Turn, build_request, fast_tail
from verse_brain.runtime.protocol import ListEmitter
from verse_brain.runtime.ratelimit import ModelLimiter
from verse_brain.runtime.settings import Config, route_params
from verse_brain.runtime.transport import CreditExhausted, Offline, Overloaded, RateLimited


class FakeConv:
    def __init__(self, be: "FakeBackend", system: str) -> None:
        self.be, self.system, self.msgs, self.tokens, self.cancelled, self.closed = be, system, [], 0, False, False

    def send(self, text):
        self.be.sent.append(text)
        self.msgs.append(text)
        self.tokens += len(text.split())
        if self.be.hang:
            while not self.cancelled:
                time.sleep(0.005)
            return
        if self.be.fail_send:
            raise RuntimeError("gpu exploded")
        reply = "READY" if "PRIMING" in text else self.be.reply
        for w in reply.replace("\n", " \n").split(" "):
            if w:
                yield w + (" " if w != "\n" else "")
        self.tokens += len(reply.split())

    def token_count(self) -> int:
        return self.tokens

    def cancel(self) -> None:
        self.cancelled = True

    def close(self) -> None:
        self.closed = True


class FakeBackend:
    def __init__(self) -> None:
        self.loads = 0
        self.convs: list[FakeConv] = []
        self.sent: list[str] = []
        self.reply = FAST_OK
        self.hang = False
        self.fail_send = False
        self.fail_load: str | None = None
        self.closed = False

    def load(self) -> None:
        self.loads += 1
        if self.fail_load:
            raise ll.LocalUnavailable(self.fail_load)

    def count_tokens(self, text: str) -> int:
        return len(text.split())

    def new_conv(self, system: str) -> FakeConv:
        c = FakeConv(self, system)
        self.convs.append(c)
        return c

    def close(self) -> None:
        self.closed = True


@pytest.fixture(autouse=True)
def _usable_local(monkeypatch):
    monkeypatch.setattr(fb, "available", lambda cfg: (True, ""))
    yield
    ModelLimiter.bypass = None


def rig(fault=None, fault_for_s=None, primary=None, backend=None, **cfg):
    """-> (brain, emitter, fallback transport, primary fault transport, fake API, backend)"""
    api = primary or FakeTransport(default_responder)
    ft_primary = FaultTransport(api, fault, fault_for_s)
    config = Config(**cfg)
    em = ListEmitter()
    box: dict = {}
    fe = fb.FallbackEmitter(em, lambda: box.get("t"))
    backend = backend or FakeBackend()
    local = LocalGemma(config, backend=backend, on_metric=lambda stage, **kw: fe.metric("", stage, **kw))
    ft = FallbackTransport(ft_primary, local, fe, config)
    box["t"] = ft
    b = Brain(ft, fe, config)
    b.start_background = False
    return b, em, ft, ft_primary, api, backend


def states(em):
    return [(e["state"], e.get("message", ""), e) for e in em.of("status")]


def texts(em, tier=None):
    return [e["text"] for e in em.of("delta") if tier is None or e["tier"] == tier]


async def ask(b, tid="r1", text="Can you tell me about yourself?"):
    await turn(b, tid, text)
    await settle(b, 8.0)


FAULTS = [
    ("offline", lambda: Offline("down"), "offline"),
    ("rate_limited", lambda: RateLimited("429", retry_after=1.0, status=429), "rate_limited"),
    ("overloaded", lambda: Overloaded("529", status=529), "rate_limited"),
    ("credit", lambda: CreditExhausted("402", status=402), "credit_exhausted"),
]


@pytest.mark.parametrize("name,mk,state", FAULTS)
def test_each_failure_class_answers_on_gemma(name, mk, state):
    """Pre-warm fails with the class, the question is answered locally, the engine never halts."""
    b, em, ft, fault, api, be = rig(fault=mk())

    async def go():
        await start(b)
        await ask(b)
        await b.shutdown()

    run(go())
    st = states(em)
    degraded = [s for s in st if s[2].get("degraded") is True]
    assert degraded and degraded[0][0] == state, st
    assert degraded[0][2]["fallback"] == "local-gemma" and "local Gemma" in degraded[0][1]
    assert not any(s[0] == "ready" and not s[2].get("recovered") for s in st), st   # the engine's 'ready' is rewritten
    assert b.halted is None and not b.offline
    assert "".join(texts(em, "F")).startswith("SAY: Sure"), texts(em)
    assert be.loads == 1 and api.calls == []                                           # API never streamed, Gemma did


def test_429_on_f_goes_local_but_d_429_keeps_the_engine_retry_policy():
    """S/F 429 -> Gemma. A D 429 is not ours: it propagates, the engine retries once and reports rate_limited."""
    class D429(FakeTransport):
        pass

    b, em, ft, fault, api, be = rig()
    api.responder = lambda info: (Script(error=RateLimited("429", retry_after=0.01, status=429))
                                  if info.route == "D" else default_responder(info))

    async def go():
        await start(b)
        await ask(b)
        await b.shutdown()

    run(go())
    assert not ft.degraded and be.loads == 0                      # D alone does not flip the mode
    assert len(api.by_route("D")) == 2                            # the engine's one retry
    assert any(s[0] == "rate_limited" and s[2].get("degraded") is None for s in states(em))


def test_speculative_s_429_is_left_to_the_engine():
    b, em, ft, fault, api, be = rig()
    api.responder = lambda info: (Script(error=RateLimited("429", status=429)) if info.route == "S" else default_responder(info))

    async def go():
        await start(b)
        from test_runtime_helpers import speak
        await speak(b, "r1", "can you tell me about yourself please".split(), 0.05)
        await turn(b, "r1", "can you tell me about yourself please")
        await settle(b)
        await b.shutdown()

    run(go())
    assert not ft.degraded and be.loads == 0


def test_timeout_class_first_text_never_comes():
    """The API accepts the stream but sends no text: after fallback_first_text_s the question goes to Gemma."""
    class Stall(FakeTransport):
        pass

    b, em, ft, fault, api, be = rig(fallback_first_text_s=0.3)
    api.responder = lambda info: (Script(first_byte_delay=5.0) if info.route == "F" else default_responder(info))

    async def go():
        await start(b)
        t0 = time.monotonic()
        await ask(b)
        assert time.monotonic() - t0 < 4.0
        await b.shutdown()

    run(go())
    assert ft.degraded and ft.cause == "offline"
    assert "".join(texts(em, "F")).startswith("SAY: Sure")
    assert any(s[2].get("cause") == "offline" for s in states(em))


def test_healthy_path_never_touches_gemma():
    b, em, ft, fault, api, be = rig()

    async def go():
        await start(b)
        await ask(b)
        await ask(b, "r2", "What did you build at Lantern?")
        await b.shutdown()

    run(go())
    assert be.loads == 0 and be.convs == [] and be.sent == []
    assert not ft.local.loaded and not ft.degraded
    assert not any(e.get("degraded") for e in em.events if e["type"] == "status")
    assert not [e for e in em.events if e["type"] == "metric" and str(e["stage"]).startswith("local_")]
    assert len(api.by_route("F")) + len(api.by_route("S")) >= 2


def test_local_prewarm_setting_primes_even_when_healthy():
    b, em, ft, fault, api, be = rig(local_prewarm=True)

    async def go():
        await start(b)
        for _ in range(100):
            if any(e.get("stage") == "local_primed" for e in em.events if e["type"] == "metric"):
                break
            await asyncio.sleep(0.02)
        await b.shutdown()

    run(go())
    assert be.loads == 1 and not ft.degraded
    assert any("PRIMING" in m for m in be.sent)


def test_recovery_after_cooldown_switches_back():
    b, em, ft, fault, api, be = rig(fault=Offline("down"), fault_for_s=0.25, fallback_cooldown_s=0.1,
                                    fallback_cooldown_max_s=0.1)

    async def go():
        await start(b)
        await ask(b)
        assert ft.degraded
        for _ in range(100):
            if not ft.degraded:
                break
            await asyncio.sleep(0.02)
        assert not ft.degraded
        n_local = len(be.sent)
        await ask(b, "r2", "What did you build at Lantern?")
        assert len(be.sent) == n_local                              # back on the API
        await b.shutdown()

    run(go())
    st = states(em)
    rec = [s for s in st if s[2].get("recovered")]
    assert rec and rec[0][0] == "ready" and "recovered" in rec[0][1]
    assert any(e.get("stage") == "fallback_probe" and e["ok"] is False for e in em.events if e["type"] == "metric")
    assert api.by_route("F") or api.by_route("S")


def test_probe_keeps_degraded_while_api_still_down():
    b, em, ft, fault, api, be = rig(fault=Offline("down"), fallback_cooldown_s=0.05, fallback_cooldown_max_s=0.05)

    async def go():
        await start(b)
        await asyncio.sleep(0.4)
        assert ft.degraded and ft._probes >= 2
        await b.shutdown()

    run(go())
    assert not any(s[2].get("recovered") for s in states(em))


def test_credit_cause_uses_longer_cooldown_and_rate_limit_honours_retry_after():
    b, em, ft, *_ = rig(fault=CreditExhausted("402"), fallback_cooldown_s=5.0, fallback_credit_cooldown_s=60.0)
    run(start(b))
    assert ft._cooldown == 60.0
    b, em, ft, *_ = rig(fault=RateLimited("429", retry_after=45.0), fallback_cooldown_s=30.0, fallback_cooldown_max_s=60.0)
    run(start(b))
    assert ft._cooldown == 45.0


def test_kv_is_reused_second_message_carries_only_the_delta():
    b, em, ft, fault, api, be = rig(fault=Offline("down"))

    async def go():
        await start(b)
        await ask(b, "r1", "Can you tell me about yourself?")
        await b.handle({"type": "turn", "turn_id": "m1", "speaker": "me", "text": "I led the Lantern project at work.",
                        "addressee": "unknown", "t_audio_end": 0.0})
        await ask(b, "r2", "What did you build at Lantern?")
        await b.shutdown()

    run(go())
    real = [m for m in be.sent if "PRIMING" not in m]
    assert len(real) == 2 and len(be.convs) == 1                      # one conversation, no rebuild
    assert PACK_HEADER.strip() not in real[1] and "## FACTS" not in real[1]
    assert "I led the Lantern project at work." in real[1] and "CURRENT QUESTION" in real[1]
    assert real[1].startswith(ll.FOLLOWUP_HEADER)


def test_rewritten_transcript_builds_a_fresh_conversation():
    fixture_pack = (FIX / "pack.md").read_text()
    be = FakeBackend()
    local = LocalGemma(Config(), backend=be)

    def req(turns, q):
        return build_request("F", route_params("F"), fixture_pack, [Turn(f"t{i}", s, t) for i, (s, t) in enumerate(turns)], fast_tail(q, "en", True))

    async def go():
        a = [("remote", "hello there"), ("me", "hi")]
        async for _ in local.stream(req(a, "first question?")):
            pass
        async for _ in local.stream(req(a + [("remote", "next")], "second question?")):
            pass
        assert len(be.convs) == 1
        async for _ in local.stream(req([("remote", "different history")], "third question?")):
            pass
        assert len(be.convs) == 2 and be.convs[0].closed
        await local.aclose()

    run(go())


def test_recycle_rebuilds_between_questions():
    pack = (FIX / "pack.md").read_text()
    be = FakeBackend()
    local = LocalGemma(Config(local_recycle_tokens=200, local_max_turns=2), backend=be)

    def req(n, q):
        return build_request("F", route_params("F"), pack, [Turn(f"t{i}", "remote", f"line {i}") for i in range(n)], fast_tail(q, "en", True))

    async def go():
        async for _ in local.stream(req(2, "first question?")):
            pass
        assert len(be.convs) == 1
        async for _ in local.stream(req(40, "second question?")):      # a long follow-up delta pushes the KV over the limit
            pass
        for _ in range(100):                                           # the background rebuild runs after the answer
            if len(be.convs) == 2 and any("PRIMING" in m for m in be.sent):
                break
            await asyncio.sleep(0.02)
        assert len(be.convs) == 2
        n = len(be.sent)
        async for _ in local.stream(req(40, "third question?")):
            pass
        assert len(be.convs) == 2 and len(be.sent) == n + 1            # served by the fresh conversation, no cold build
        await local.aclose()

    run(go())


def test_s_is_skipped_d_is_empty_rolling_skipped_final_unsupported():
    b, em, ft, fault, api, be = rig(fault=Offline("down"))

    async def go():
        await start(b)
        assert ft.degraded
        pack = (FIX / "pack.md").read_text()
        s_req = build_request("S", route_params("S"), pack, [], fast_tail("what is this", "en", False))
        with pytest.raises(ll.LocalSkipped):
            await ft.open_stream("S", s_req, 0)
        d_req = build_request("D", route_params("D"), pack, [], "OPENER ALREADY SHOWN: (none)\nCURRENT QUESTION (finished): x")
        d = await ft.open_stream("D", d_req, 0)
        evs = [e async for e in d]
        assert [e.kind for e in evs] == ["start", "stop"]
        r_req = build_request("S", route_params("S"), pack, [], "SUMMARIZE-INCREMENTAL\nLanguage: English")
        with pytest.raises(ll.LocalSkipped):
            await ft.open_stream("S", r_req, 0)
        a_req = build_request("D", route_params("D"), pack, [], "SUMMARIZE-FINAL\nLanguage: English")
        with pytest.raises(ll.LocalUnsupported):
            await ft.open_stream("D", a_req, 0)
        await b.shutdown()

    run(go())


def test_final_summary_without_api_falls_back_to_the_draft(tmp_path):
    from test_runtime_helpers import session_copy
    b, em, ft, fault, api, be = rig(fault=Offline("down"))
    sess = session_copy(tmp_path)

    async def go():
        await b.handle({"type": "start", "session_dir": str(sess), "lang": "en"})
        await ask(b)
        await b.summarize(timeout=5)
        await b.shutdown()

    run(go())
    summ = [e for e in em.events if e["type"] == "summary" and "final" in e]
    assert summ and summ[0]["final"] is False and summ[0]["draft_reason"] == "local_unsupported"


def test_hedge_duplicate_runs_once_on_gemma():
    b, em, ft, fault, api, be = rig(fault=Offline("down"))

    async def go():
        await start(b)
        pack = (FIX / "pack.md").read_text()
        req = build_request("F", route_params("F"), pack, [], fast_tail("tell me about yourself", "en", True))
        s0 = await ft.open_stream("F", req, 0)
        with pytest.raises(ll.LocalSkipped):
            await ft.open_stream("F", req, 1)
        out = "".join([e.text async for e in s0 if e.kind == "text"])
        assert out.startswith("SAY:")
        await b.shutdown()

    run(go())


def test_gemma_exception_surfaces_a_clean_error():
    be = FakeBackend()
    be.fail_send = True
    b, em, ft, fault, api, _ = rig(fault=Offline("down"), backend=be)

    async def go():
        await start(b)
        await ask(b)
        await b.shutdown()

    run(go())
    errs = [s for s in states(em) if s[0] == "error"]
    assert errs and "local_error" in errs[0][1] and "gpu exploded" in errs[0][1], states(em)


def test_gemma_hang_times_out_instead_of_hanging():
    be = FakeBackend()
    be.hang = True
    b, em, ft, fault, api, _ = rig(fault=Offline("down"), backend=be, local_first_token_s=0.3)

    async def go():
        await start(b)
        t0 = time.monotonic()
        await ask(b)
        assert time.monotonic() - t0 < 5.0
        await b.shutdown()

    run(go())
    errs = [s for s in states(em) if s[0] == "error"]
    assert errs and "local_error" in errs[0][1] and "no first token" in errs[0][1], states(em)
    assert be.convs[-1].cancelled                                    # the process was cancelled, not abandoned


def test_gemma_cancelled_by_the_engine_releases_the_lock():
    be = FakeBackend()
    be.hang = True
    local = LocalGemma(Config(), backend=be)
    pack = (FIX / "pack.md").read_text()
    req = build_request("F", route_params("F"), pack, [], fast_tail("tell me about yourself", "en", True))

    async def go():
        gen = local.stream(req)
        t = asyncio.ensure_future(gen.__anext__())
        await asyncio.sleep(0.2)
        t.cancel()
        with pytest.raises(asyncio.CancelledError):
            await t
        await gen.aclose()
        be.hang = False
        out = "".join([p async for p in local.stream(req)])
        assert out.startswith("SAY:")
        await local.aclose()

    run(go())


def test_gemma_unavailable_behaves_like_no_fallback():
    be = FakeBackend()
    be.fail_load = "model not found: /nope"
    b, em, ft, fault, api, _ = rig(fault=Offline("down"), backend=be)

    async def go():
        await start(b)
        await ask(b)
        await b.shutdown()

    run(go())
    assert ft.local_disabled and not ft.degraded
    st = states(em)
    assert any(s[2].get("fallback") == "unavailable" and "model not found" in s[1] for s in st), st
    assert b.offline                                                   # the engine saw the original Offline


def test_unavailable_precheck_leaves_the_engine_untouched(monkeypatch):
    monkeypatch.setattr(fb, "available", lambda cfg: (False, "model not found: x"))
    b, em, ft, fault, api, be = rig(fault=Offline("down"))
    run(start(b))
    assert ft.local_disabled and be.loads == 0
    assert states(em)[-1][0] == "offline"


def test_auth_failure_is_never_taken_over():
    from verse_brain.runtime.transport import AuthFailed
    b, em, ft, fault, api, be = rig(fault=AuthFailed("401", status=401))
    run(start(b))
    assert not ft.degraded and b.halted == "error" and be.loads == 0


def test_limiter_bypass_while_degraded():
    b, em, ft, fault, api, be = rig(fault=Offline("down"))
    lim = b.limiters[next(iter(b.limiters))]
    lim.buckets["requests"].level = 0
    assert ModelLimiter.bypass is not None
    run(start(b))
    assert ft.degraded and lim.try_acquire(10, 10) is True
    lim2 = ModelLimiter()
    ModelLimiter.bypass = None
    lim2.buckets["requests"].level = 0
    assert lim2.try_acquire(10, 10) is False


def test_wrap_helper_and_cli_simulation(monkeypatch):
    em = ListEmitter()
    ft, fe = wrap(FaultTransport(None, fb.simulated_fault("credit")), em, Config())
    assert isinstance(ft, FallbackTransport) and not ft.local.loaded      # nothing is loaded by wrapping
    fe.status("ready", "engine ready")
    assert em.events[-1]["state"] == "ready"
    assert fb.simulated_fault("rate_limited").retry_after == 5.0 and fb.simulated_fault("") is None
    run(ft.aclose())


def test_trim_pack_rule():
    pack = (
        "## FACTS\n" + "\n".join(f"[f{i:03d}] name | fact number {i} about Lantern | x | prep:L{i}" for i in range(20)) + "\n\n"
        "## GLOSSARY\n[g001] Lantern: invoice pipeline | prep:L1\n\n"
        "## ANSWER BANK\n"
        "[b001] Q (en): Can you tell me about yourself?\nSAY: Sure.\n- I led Lantern. " + "pad " * 90 + "\n"
        "[b002] Q (en): What is your notice period?\nSAY: Thirty days.\n- My earliest start is mid December. " + "pad " * 90 + "\n"
        "[b003] Q (en): Tell me about your salary expectations package?\nSAY: Flexible.\n- Salary depends. " + "pad " * 90 + "\n\n"
        "## SNIPPETS\n[s001] vault:x | " + "long noise " * 200 + "\n\n"
        "## USER'S VOICE (source: prep:voice)\n- Tone: direct.\n"
    )
    out, dropped = ll.trim_pack(pack, 1200)
    assert "## SNIPPETS" not in out and "long noise" not in out
    assert "## FACTS" in out and "## GLOSSARY" in out and "USER'S VOICE" in out and "[b001]" in out
    assert len(out) <= 1200
    assert [d.id for d in dropped]                                         # something was cut from the bank
    cut = ll.retrieve(dropped, "What salary and package do you expect from us?", 2)
    assert cut and cut[0].id == "b003"
    assert ll.retrieve(dropped, "completely unrelated zebra question", 2) == []
    assert ll.trim_pack(pack, 10 ** 6) == (pack, [])                       # fits: untouched


def test_extras_reach_the_message_for_cut_entries():
    pack = (FIX / "pack.md").read_text()
    bank = "\n".join(f"[b{i:03d}] Q (en): Question about topic{i} widgets{i}?\nSAY: Answer {i}.\n- Point {i}." for i in range(1, 40))
    big = pack.split("## ANSWER BANK")[0] + "## ANSWER BANK\n" + bank + "\n"
    be = FakeBackend()
    local = LocalGemma(Config(local_pack_chars=1200), backend=be)
    req = build_request("F", route_params("F"), big, [], fast_tail("Tell me about topic30 widgets30", "en", True))

    async def go():
        async for _ in local.stream(req):
            pass
        await local.aclose()

    run(go())
    msg = be.sent[0]
    assert ll.EXTRA_HEADER in msg and "[b030]" in msg and "[b039]" not in msg.split(ll.EXTRA_HEADER)[0] + "x"
