"""Verse is online-only: with no connection, no API key or a rejected key the brain says so, with a `reason` the app can show.

Each failure that stops answers is one `status` event: `offline` + `no_connection`, `error` + `no_api_key` / `invalid_api_key`,
`credit_exhausted` + `no_credit`. The Swift side maps `reason` to a localized sentence (OverlayReducer.reasonText)."""

from __future__ import annotations

import json
from argparse import Namespace

import pytest
from test_runtime_helpers import make, run, settle, start, turn

from verse_brain.prep.keychain import KeychainError
from verse_brain.runtime import __main__ as entry
from verse_brain.runtime.engine import Brain
from verse_brain.runtime.fake import FakeTransport, FaultTransport, Script, default_responder, simulated_fault
from verse_brain.runtime.protocol import ListEmitter
from verse_brain.runtime.settings import Config
from verse_brain.runtime.transport import AuthFailed, CreditExhausted, Offline


def brain_with(transport):
    em = ListEmitter()
    b = Brain(transport, em, Config())
    b.start_background = False
    return b, em


@pytest.mark.parametrize("fault, state, reason, message", [
    (Offline("APIConnectionError"), "offline", "no_connection", "no connection"),
    (AuthFailed("401 authentication_error", status=401), "error", "invalid_api_key", "API key rejected"),
    (CreditExhausted("402 billing_error", status=402), "credit_exhausted", "no_credit", "credit used up"),
])
def test_start_with_a_failing_api_says_why(fault, state, reason, message):
    b, em = brain_with(FaultTransport(None, fault))
    run(start(b))
    st = [e for e in em.of("status") if e["state"] not in ("warming",)]
    assert st, "silence: no status after the pre-warm failed"
    assert st[-1]["state"] == state and st[-1]["reason"] == reason and message in st[-1]["message"], st
    assert not [e for e in em.of("status") if e["state"] == "ready"]


def test_offline_in_the_middle_of_a_call_says_no_connection():
    def responder(info):
        return Script(error=Offline("APIConnectionError")) if info.tail.strip() else default_responder(info)

    b, t, em = make(responder)

    async def go():
        await start(b)
        await turn(b, "r1", "Can you tell me about yourself?")
        await settle(b)

    run(go())
    off = [e for e in em.of("status") if e["state"] == "offline"]
    assert off and off[0]["reason"] == "no_connection" and off[0]["message"].startswith("no connection"), em.of("status")


def _args(**kw) -> Namespace:
    base = dict(no_api=False, fake=False, fake_bank=False, no_embed=True, embed=False, budget_usd=None)
    return Namespace(**{**base, **kw})


def test_no_api_key_is_a_status_event_and_exit_code_2(monkeypatch, capsys):
    import verse_brain.prep.keychain as keychain

    def missing():
        raise KeychainError("Keychain item service=verse-anthropic account=x missing (exit 44)")

    monkeypatch.setattr(keychain, "read_api_key", missing)
    monkeypatch.delenv("VERSE_SIMULATE_API", raising=False)
    assert run(entry.amain(_args())) == 2
    lines = [json.loads(l) for l in capsys.readouterr().out.splitlines() if l.strip()]
    st = [l for l in lines if l.get("type") == "status"]
    assert len(st) == 1 and st[0]["state"] == "error" and st[0]["reason"] == "no_api_key", lines
    assert st[0]["message"].startswith("No API key") and "Keychain" in st[0]["message"]


def test_simulated_api_failures_need_no_key(monkeypatch):
    monkeypatch.setenv("VERSE_SIMULATE_API", "offline")
    assert isinstance(simulated_fault("offline"), Offline)
    assert isinstance(simulated_fault("auth"), AuthFailed) and isinstance(simulated_fault("credit"), CreditExhausted)
    assert simulated_fault("") is None and simulated_fault("nonsense") is None
