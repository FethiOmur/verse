#!/usr/bin/env python3
"""Verse P0-A: API latency and rate-limit benchmark (throwaway CLI).

Run:  .venv/bin/python -u bench_api.py --all
      .venv/bin/python -u bench_api.py --cases warm_haiku,cold_haiku
      .venv/bin/python -u bench_api.py --cases idle6m_haiku      (optional, ~7 min real idle)

Security: the API key is read from the macOS Keychain (service `verse-anthropic`,
account $USER) at runtime, handed to the SDK client and never printed, logged or
written. Results contain numbers, header values (no auth headers) and short
synthetic text only. No audio is involved.

Everything is measured from the instant just before the request is sent
(t0 = perf_counter). SDK `max_retries=0` everywhere, as the spec asks for S/F.
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import getpass
import json
import os
import platform
import random
import subprocess
import sys
import time
from pathlib import Path

import anthropic
import httpx2  # the SDK's own HTTP layer in anthropic 1.x (httpx fork)

HERE = Path(__file__).resolve().parent
KEYCHAIN_SERVICE = "verse-anthropic"

HAIKU = "claude-haiku-5-5"
SONNET = "claude-sonnet-5-5"

# $/MTok (input, output). Cache write 5m = 1.25x input, 1h = 2x, cache read = 0.1x.
PRICES = {HAIKU: (0.10, 0.50), SONNET: (2.00, 10.00)}
CACHE_WRITE_5M = 1.25
CACHE_READ = 0.10

SOFT_BUDGET_USD = 1.00   # warn
HARD_BUDGET_USD = 1.50   # abort run (global hard stop is $2)

PACK_ITEMS = 55          # tuned so the pack is ~6k Haiku tokens (checked with count_tokens)


class FatalStop(Exception):
    """401/403, missing Keychain item, refusal we cannot explain, or budget."""


# --------------------------------------------------------------------------- key


def read_key() -> str:
    user = os.environ.get("USER") or getpass.getuser()
    try:
        r = subprocess.run(
            ["security", "find-generic-password", "-a", user, "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=30,
        )
    except Exception as e:  # noqa: BLE001
        raise FatalStop(f"Keychain read failed: {type(e).__name__}") from None
    if r.returncode != 0 or not r.stdout.strip():
        raise FatalStop(f"Keychain item service={KEYCHAIN_SERVICE} account={user} missing (exit {r.returncode})")
    return r.stdout.strip()


# ---------------------------------------------------------------------- spend


class Spend:
    def __init__(self) -> None:
        self.usd = 0.0
        self.by_model: dict[str, float] = {}
        self.calls = 0
        self.warned = False

    def add(self, model: str, usage: dict | None, *, assume_output: int | None = None) -> float:
        if not usage:
            return 0.0
        pin, pout = PRICES[model]
        inp = usage.get("input_tokens") or 0
        out = assume_output if assume_output is not None else (usage.get("output_tokens") or 0)
        cw = usage.get("cache_creation_input_tokens") or 0
        cr = usage.get("cache_read_input_tokens") or 0
        usd = (inp * pin + cw * pin * CACHE_WRITE_5M + cr * pin * CACHE_READ + out * pout) / 1e6
        self.usd += usd
        self.by_model[model] = self.by_model.get(model, 0.0) + usd
        self.calls += 1
        if self.usd > SOFT_BUDGET_USD and not self.warned:
            self.warned = True
            print(f"!! spend ${self.usd:.4f} passed the soft budget (${SOFT_BUDGET_USD})", flush=True)
        if self.usd > HARD_BUDGET_USD:
            raise FatalStop(f"spend ${self.usd:.4f} passed the hard budget ${HARD_BUDGET_USD}")
        return usd


SPEND = Spend()


# ------------------------------------------------------------------ test data

SYSTEM_PROMPT = """You are Verse, a silent assistant that helps the owner answer questions during a live meeting.
You receive a MEETING PACK (facts, glossary, answer bank), the last finalized transcript turns, and then one QUESTION.

Reply in the language of the QUESTION, in exactly this plain-text line format and nothing else:
SAY: <one short spoken-style sentence the owner can say right away, at most 18 words>
- <supporting point, self-contained, cite fact ids like [F012]>
- <supporting point>
- <supporting point>

Rules: ground every number and name in the pack and cite the id. If the pack does not contain the answer,
write "SAY: Let me check and come back to you." and one bullet saying what is missing. No preamble, no markdown
other than the leading "- ", no JSON."""

TURNS = [
    "[Marco] Thanks everyone for joining. We have forty minutes and three topics: the pilot results, the budget for Q3, and the depot rollout.",
    "[Giulia] Before the numbers, a quick note: the Milan depot sent its figures late, so the on-time rate in the draft may still move by a point.",
    "[Marco] Understood. the owner, you prepared the summary of the pilot, so you will walk us through it after the budget item.",
    "[Elif] I would like to hear how the new optimiser behaved on the mountain routes, because that was our main worry in the spring.",
    "[Giulia] And please keep the cost figures net of the carrier rebate, otherwise finance will ask us to redo the slide.",
    "[Marco] Good. Let us start with the budget. Elif, can you give us the headline before we open questions?",
]


PACKS: dict[str, tuple[str, list[tuple]]] = {}


def build_pack(salt: str, items: int = PACK_ITEMS) -> str:
    """Deterministic synthetic meeting pack (fictional company). `salt` forces a distinct cache key.
    The facts are remembered so questions can be generated that the pack can actually answer."""
    if salt in PACKS:
        return PACKS[salt][0]
    facts: list[tuple] = []
    rng = random.Random(f"pack-{salt}")
    metrics = [
        "on-time delivery rate", "average cost per delivery", "fuel use per 100 km", "driver overtime hours",
        "empty-run share", "customer complaints per 1000 drops", "depot dwell time", "route re-plans per day",
        "pallet damage rate", "sensor uptime", "carrier rebate", "training hours per driver",
    ]
    places = ["Milan", "Milano", "Lyon", "Genova", "Bologna", "Marseille", "Verona", "Nice"]
    people = ["Marco Rinaldi", "Giulia Ferri", "Elif Demir", "Paolo Greco", "Sara Conti", "Kaan Arslan"]
    docs = ["Pilot Review v3", "Q3 Budget Sheet", "Depot Rollout Plan", "Carrier Contract 2026", "Risk Register", "Audit Note 14"]
    lines = [f"MEETING PACK (synthetic, fictional company Larkspur Logistics). Salt {salt}.",
             "", "== FACT SHEET =="]
    for i in range(1, items + 1):
        m = metrics[i % len(metrics)]
        p = places[rng.randrange(len(places))]
        v = round(rng.uniform(2, 98), 1)
        q = rng.choice(["Q1", "Q2", "Q3", "last quarter", "pilot period"])
        d = docs[rng.randrange(len(docs))]
        facts.append((i, m, p, q, v))
        lines.append(f"F{i:03d} | {m} at the {p} depot, {q}: {v} (unit as in the source sheet) | owner {rng.choice(people)} | source: {d}, p.{rng.randint(1, 40)}")
    lines += ["", "== GLOSSARY =="]
    terms = ["optimiser", "pilot cell", "dwell", "re-plan", "rebate", "dispatch window", "cross-dock", "tail lift", "geofence", "ETA drift"]
    for i, t in enumerate(terms[: max(6, items // 6)]):
        lines.append(f"G{i + 1:02d} | {t}: in this company the word means the operational definition used in the {rng.choice(docs)}, "
                     f"which differs slightly from the textbook definition because of the {rng.choice(places)} contract terms.")
    lines += ["", "== ANSWER BANK =="]
    for i in range(1, max(10, items // 3) + 1):
        m = metrics[rng.randrange(len(metrics))]
        lines.append(f"B{i:03d} | Q: How is the {m} doing? | A: It is {round(rng.uniform(2, 98), 1)}, "
                     f"{rng.choice(['up', 'down', 'flat'])} against the previous period; the owner is {rng.choice(people)}; see F{rng.randint(1, items):03d}.")
    lines += ["", "== SNIPPETS =="]
    for i in range(1, max(5, items // 8) + 1):
        lines.append(f"S{i:02d} | The {rng.choice(['steering group', 'dispatch team', 'finance lead', 'pilot cell'])} noted that the "
                     f"{rng.choice(metrics)} needs a closer look in {rng.choice(places)}, and agreed to review it with {rng.choice(people)} "
                     f"before the next meeting; the decision is recorded in {rng.choice(docs)}.")
    text = "\n".join(lines)
    PACKS[salt] = (text, facts)
    return text


def question_for(salt: str, i: int) -> str:
    """Question i about a fact that exists in the pack with this salt; en / it / tr in rotation."""
    build_pack(salt)
    _, facts = PACKS[salt]
    _, m, p, q, _v = facts[(i * 7 + 3) % len(facts)]
    return [f"What was the {m} at the {p} depot in {q}?",
            f"Com'era il dato di {m} al deposito di {p} ({q})?",
            f"{p} deposunda {q} icin {m} ne kadardi?"][i % 3]


ROUTES = {
    # name: (model, thinking, effort, max_tokens)
    "haiku": (HAIKU, {"type": "disabled"}, "low", 300),
    "sonnet_bt": (SONNET, {"type": "between_tools"}, "medium", 800),
    "sonnet_ad": (SONNET, {"type": "adaptive"}, "medium", 3000),
    # extras for the model_compare case
    "haiku_ad": (HAIKU, {"type": "adaptive"}, "low", 2000),
    "haiku_default": (HAIKU, None, None, 2000),   # no thinking / effort params at all (model defaults)
}


def build_request(route: str, salt: str, question: str, *, pack: str | None = None, effort: str | None = None,
                  max_tokens: int | None = None) -> dict:
    model, thinking, eff, mt = ROUTES[route]
    pack = pack if pack is not None else build_pack(salt)
    content = [{"type": "text", "text": pack, "cache_control": {"type": "ephemeral"}}]  # breakpoint 1
    for i, t in enumerate(TURNS):
        blk = {"type": "text", "text": t}
        if i == len(TURNS) - 1:
            blk["cache_control"] = {"type": "ephemeral"}  # breakpoint 2 on newest finalized turn
        content.append(blk)
    content.append({"type": "text", "text": f"QUESTION: {question}"})  # after the last breakpoint
    req = dict(
        model=model,
        max_tokens=max_tokens if max_tokens is not None else mt,
        system=[{"type": "text", "text": SYSTEM_PROMPT}],
        messages=[{"role": "user", "content": content}],
    )
    if thinking is not None:
        req["thinking"] = thinking
    if (effort or eff) is not None:
        req["output_config"] = {"effort": effort or eff}
    return req


# ------------------------------------------------------------------- clients


def make_client(key: str) -> anthropic.AsyncAnthropic:
    http = anthropic.DefaultAsyncHttpxClient(
        http2=True,
        limits=httpx2.Limits(max_connections=20, max_keepalive_connections=20, keepalive_expiry=300),
    )
    return anthropic.AsyncAnthropic(api_key=key, http_client=http, max_retries=0, timeout=anthropic.Timeout(60.0, connect=10.0))


KEEP_HEADERS_PREFIX = ("anthropic-", "request-id", "retry-after", "x-envoy", "cf-ray", "server-timing", "via", "x-should-retry")


def pick_headers(h) -> dict:
    out = {}
    for k, v in h.items():
        kl = k.lower()
        if kl.startswith(KEEP_HEADERS_PREFIX) and "key" not in kl and "auth" not in kl:
            out[kl] = v
    return out


# ------------------------------------------------------------------- one call


def p90_nearest(vals: list[float]) -> float | None:
    """Nearest-rank 90th percentile: the ceil(0.9 n)-th smallest value (robust for n = 10..30)."""
    if not vals:
        return None
    import math
    s = sorted(vals)
    return s[max(0, math.ceil(0.9 * len(s)) - 1)]


def pct(vals: list[float], p: float) -> float | None:
    if not vals:
        return None
    s = sorted(vals)
    if len(s) == 1:
        return s[0]
    k = (len(s) - 1) * p
    f = int(k)
    c = min(f + 1, len(s) - 1)
    return s[f] + (s[c] - s[f]) * (k - f)


async def stream_call(client: anthropic.AsyncAnthropic, req: dict, *, cancel_after_first_delta: bool = False,
                      label: str = "") -> dict:
    """One streamed request. Returns a dict of per-stage timings (ms from t0) and server usage."""
    rec: dict = {"label": label, "model": req["model"], "ok": False}
    t0 = time.perf_counter()
    ms = lambda: round((time.perf_counter() - t0) * 1000, 1)  # noqa: E731
    text = ""
    usage: dict = {}
    first_block_type = None
    block_types: list[str] = []
    try:
        raw = await client.messages.with_raw_response.create(**req, stream=True)
        rec["t_headers"] = ms()
        rec["http_version"] = getattr(raw.http_response, "http_version", None)
        rec["headers"] = pick_headers(raw.headers)
        rec["request_id"] = raw.headers.get("request-id")
        stream = await raw.parse()
        try:
            async for ev in stream:
                t = ms()
                et = ev.type
                if "t_first_event" not in rec:
                    rec["t_first_event"] = t
                if et == "message_start":
                    usage = {k: v for k, v in ev.message.usage.model_dump().items() if isinstance(v, int)}
                    rec["message_start_usage"] = dict(usage)
                elif et == "content_block_start":
                    bt = ev.content_block.type
                    block_types.append(bt)
                    if first_block_type is None:
                        first_block_type = bt
                        rec["t_first_block"] = t
                    if bt == "thinking" and "t_first_thinking" not in rec:
                        rec["t_first_thinking"] = t
                elif et == "content_block_delta":
                    d = ev.delta
                    if d.type == "text_delta":
                        if "t_first_text" not in rec:
                            rec["t_first_text"] = t
                            if cancel_after_first_delta:
                                rec["cancelled_at_ms"] = t
                                break
                        text += d.text
                        # a line is complete once its "\n" has arrived
                        if "t_say" not in rec or "t_point1" not in rec:
                            for ln in text.split("\n")[:-1]:
                                if ln.startswith("SAY:") and "t_say" not in rec:
                                    rec["t_say"] = t
                                if ln.startswith("- ") and "t_point1" not in rec:
                                    rec["t_point1"] = t
                elif et == "message_delta":
                    u = ev.usage
                    if u is not None:
                        for k, v in u.model_dump().items():
                            if isinstance(v, int):
                                usage[k] = v
                    sd = ev.delta
                    rec["stop_reason"] = sd.stop_reason
                    det = getattr(sd, "stop_details", None)
                    if det is not None:
                        rec["stop_details"] = det.model_dump() if hasattr(det, "model_dump") else str(det)
        finally:
            if cancel_after_first_delta:
                t_close = time.perf_counter()
                await stream.close()
                rec["close_ms"] = round((time.perf_counter() - t_close) * 1000, 1)
            else:
                await stream.close()
        rec["t_done"] = ms()
        # a trailing line without "\n" counts as complete at end of stream
        if not cancel_after_first_delta:
            last = text.split("\n")[-1]
            if last.startswith("SAY:") and "t_say" not in rec:
                rec["t_say"] = rec["t_done"]
            if last.startswith("- ") and "t_point1" not in rec:
                rec["t_point1"] = rec["t_done"]
        rec["ok"] = True
    except anthropic.AuthenticationError as e:
        raise FatalStop(f"401 authentication error: {e.message}") from None
    except anthropic.PermissionDeniedError as e:
        raise FatalStop(f"403 permission denied: {e.message}") from None
    except anthropic.RateLimitError as e:
        rec["error"] = "429 rate_limit"
        rec["headers"] = pick_headers(e.response.headers)
    except anthropic.APIStatusError as e:
        rec["error"] = f"{e.status_code} {e.message}"[:300]
    except (anthropic.APIConnectionError, anthropic.APITimeoutError) as e:
        c = e.__cause__
        rec["error"] = f"{type(e).__name__}: {type(c).__name__ if c else ''} {str(c)[:100] if c else ''}".strip()
        rec["t_error"] = ms()
    rec["block_types"] = block_types
    rec["usage"] = usage
    rec["text_chars"] = len(text)
    rec["text_head"] = text[:220]
    if rec.get("stop_reason") == "refusal":
        raise FatalStop(f"refusal stop_reason, details={rec.get('stop_details')}")
    if usage and rec["ok"]:
        rec["cost_usd"] = round(SPEND.add(req["model"], usage), 6)
    if "t_first_text" in rec and "t_done" in rec and usage.get("output_tokens") and not cancel_after_first_delta:
        dur = (rec["t_done"] - rec["t_first_text"]) / 1000
        rec["out_tok_per_s"] = round(usage["output_tokens"] / dur, 1) if dur > 0 else None
    return rec


async def plain_call(client: anthropic.AsyncAnthropic, req: dict, label: str = "") -> dict:
    """Non-streaming request (used for max_tokens: 0 pre-warm)."""
    rec: dict = {"label": label, "model": req["model"], "ok": False}
    t0 = time.perf_counter()
    try:
        raw = await client.messages.with_raw_response.create(**req)
        rec["t_done"] = round((time.perf_counter() - t0) * 1000, 1)
        rec["http_version"] = getattr(raw.http_response, "http_version", None)
        rec["headers"] = pick_headers(raw.headers)
        rec["request_id"] = raw.headers.get("request-id")
        msg = await raw.parse()
        usage = {k: v for k, v in msg.usage.model_dump().items() if isinstance(v, int)}
        rec["usage"] = usage
        rec["stop_reason"] = msg.stop_reason
        rec["n_content_blocks"] = len(msg.content)
        rec["ok"] = True
        rec["cost_usd"] = round(SPEND.add(req["model"], usage), 6)
        if msg.stop_reason == "refusal":
            raise FatalStop(f"refusal on plain call: {getattr(msg, 'stop_details', None)}")
    except anthropic.AuthenticationError as e:
        raise FatalStop(f"401 authentication error: {e.message}") from None
    except anthropic.PermissionDeniedError as e:
        raise FatalStop(f"403 permission denied: {e.message}") from None
    except anthropic.RateLimitError as e:
        rec["error"] = "429 rate_limit"
        rec["headers"] = pick_headers(e.response.headers)
    except anthropic.APIStatusError as e:
        rec["error"] = f"{e.status_code} {e.message}"[:400]
    except (anthropic.APIConnectionError, anthropic.APITimeoutError) as e:
        rec["error"] = f"{type(e).__name__}"
    return rec


# -------------------------------------------------------------------- stats


def summarize(calls: list[dict], *, need_cache_read: bool = False) -> dict:
    good = [c for c in calls if c.get("ok") and "t_first_text" in c]
    if need_cache_read:
        reads = [c for c in good if (c.get("usage", {}).get("cache_read_input_tokens") or 0) > 0]
    else:
        reads = good
    def col(k, rows):
        return [c[k] for c in rows if k in c]
    out = {"n_requested": len(calls), "n_ok": len(good), "n_errors": len([c for c in calls if not c.get("ok")]),
           "n_cache_read_gt0": len([c for c in good if (c.get("usage", {}).get("cache_read_input_tokens") or 0) > 0]),
           "n_in_stats": len(reads)}
    for k in ("t_headers", "t_first_event", "t_first_block", "t_first_text", "t_say", "t_point1", "t_done", "out_tok_per_s"):
        v = col(k, reads)
        out[k] = {"n": len(v), "p50": pct(v, 0.5), "p90": p90_nearest(v), "p90_interp": pct(v, 0.9),
                  "min": min(v) if v else None, "max": max(v) if v else None,
                  "mean": round(sum(v) / len(v), 1) if v else None}
    out["cost_usd"] = round(sum(c.get("cost_usd", 0) for c in calls), 5)
    return out


# -------------------------------------------------------------------- cases


async def setup(client, results: dict) -> None:
    """Connection warm-up + pack size + org id (count_tokens is free)."""
    sizes = {}
    for route in ("haiku", "sonnet_bt"):
        req = build_request(route, "A", "warmup")
        model = req["model"]
        t0 = time.perf_counter()
        for attempt in range(4):  # the first connect to the API occasionally hangs on this network (see RESULTS_api.md)
            try:
                raw = await client.messages.with_raw_response.count_tokens(model=model, system=req["system"], messages=req["messages"])
                break
            except (anthropic.APIConnectionError, anthropic.APITimeoutError) as e:
                print(f"   setup attempt {attempt + 1} failed: {type(e).__name__}", flush=True)
                if attempt == 3:
                    raise FatalStop("API unreachable during setup") from None
        m = await raw.parse()
        sizes[model] = {"total_input_tokens_incl_question": m.input_tokens,
                        "count_tokens_ms": round((time.perf_counter() - t0) * 1000, 1)}
        results["meta"]["organization_id"] = raw.headers.get("anthropic-organization-id") or results["meta"].get("organization_id")
        results["meta"].setdefault("http_version", getattr(raw.http_response, "http_version", None))
    results["pack_tokens"] = sizes
    # pack-only count for Haiku (system + pack + turns, no question) is total minus ~20 tokens of question block
    print(f"org id: {results['meta']['organization_id']}  http: {results['meta']['http_version']}", flush=True)
    print(f"prompt size (count_tokens): {json.dumps(sizes)}", flush=True)


async def case_prewarm(client, results):
    """max_tokens:0 non-streaming pre-warm with the identical tuple, then real calls read the cache.
    Plus a mismatch control (pre-warm with different effort)."""
    out = {"config": "haiku, effort low, thinking disabled, salt P"}
    warm_req = build_request("haiku", "P", "warmup", max_tokens=0)
    warm = await plain_call(client, warm_req, "prewarm max_tokens=0")
    out["prewarm"] = warm
    note = None
    if not warm.get("ok"):
        note = f"max_tokens:0 failed: {warm.get('error')}; falling back to max_tokens=1"
        warm = await plain_call(client, build_request("haiku", "P", "warmup", max_tokens=1), "prewarm max_tokens=1")
        out["prewarm_fallback"] = warm
    out["note"] = note
    real = []
    for i in range(3):
        real.append(await stream_call(client, build_request("haiku", "P", question_for("P", i)), label=f"real after prewarm #{i + 1}"))
    out["calls"] = real
    out["summary"] = summarize(real, need_cache_read=False)
    # control: pre-warm with a different effort, then real call
    ctrl_warm = await plain_call(client, build_request("haiku", "N", "warmup", max_tokens=0, effort="medium"),
                                 "control prewarm effort=medium (mismatch)")
    ctrl_real = await stream_call(client, build_request("haiku", "N", question_for("N", 5)), label="control real effort=low")
    out["mismatch_control"] = {"prewarm": ctrl_warm, "real": ctrl_real}
    return out


async def case_warm_haiku(client, results, n=30):
    out = {"config": "haiku, effort low, thinking disabled, cache warm, one kept-alive HTTP/2 connection"}
    warmup = await stream_call(client, build_request("haiku", "A", "warmup question"), label="warm-up (writes cache, not counted)")
    out["warmup"] = warmup
    calls = []
    for i in range(n):
        calls.append(await stream_call(client, build_request("haiku", "A", question_for("A", i)), label=f"warm #{i + 1}"))
    out["calls"] = calls
    out["summary"] = summarize(calls, need_cache_read=False)
    return out


async def case_cold_haiku(key, results, n=10):
    """Fresh client (new TCP+TLS+HTTP/2 handshake) for every call; the cache stays warm (salt A)."""
    out = {"config": "haiku as warm_haiku, but a NEW client/connection per call (no real >6 min idle; see idle6m_haiku)"}
    calls = []
    for i in range(n):
        c = make_client(key)
        try:
            calls.append(await stream_call(c, build_request("haiku", "A", question_for("A", i + 7)), label=f"fresh-conn #{i + 1}"))
        finally:
            await c.close()
    out["calls"] = calls
    out["summary"] = summarize(calls, need_cache_read=False)
    return out


async def case_idle10_haiku(client, results, n=6):
    out = {"config": "haiku as warm_haiku, 10 s idle before each call on the kept-alive connection (B10)"}
    calls = []
    for i in range(n):
        await asyncio.sleep(10)
        calls.append(await stream_call(client, build_request("haiku", "A", question_for("A", i + 13)), label=f"after 10 s idle #{i + 1}"))
    out["calls"] = calls
    out["summary"] = summarize(calls, need_cache_read=False)
    return out


async def case_burst3_haiku(client, results, bursts=5):
    out = {"config": "extra: 3 concurrent haiku calls (S <= 3 in flight) over one HTTP/2 connection, cache warm"}
    calls = []
    for b in range(bursts):
        rs = await asyncio.gather(*[
            stream_call(client, build_request("haiku", "A", question_for("A", b * 3 + j + 3)), label=f"burst {b + 1}.{j + 1}") for j in range(3)])
        calls.extend(rs)
        await asyncio.sleep(2)
    out["calls"] = calls
    out["summary"] = summarize(calls, need_cache_read=False)
    return out


async def case_sonnet(client, results, n=15):
    """between_tools vs adaptive, effort medium, interleaved to share drift."""
    out = {"config": "sonnet-5-5, effort medium; thinking between_tools vs adaptive (interleaved)"}
    for route, salt in (("sonnet_bt", "SB"), ("sonnet_ad", "SA")):
        out[f"{route}_warmup"] = await stream_call(client, build_request(route, salt, "warmup question"),
                                                    label=f"{route} warm-up (not counted)")
    calls = {"sonnet_bt": [], "sonnet_ad": []}
    for i in range(n):
        for route, salt in (("sonnet_bt", "SB"), ("sonnet_ad", "SA")):
            calls[route].append(await stream_call(client, build_request(route, salt, question_for(salt, i + 2)), label=f"{route} #{i + 1}"))
    for route in calls:
        out[route] = {"calls": calls[route], "summary": summarize(calls[route], need_cache_read=False)}
    return out


async def case_floor(client, results, n=20):
    """Extra: no-inference round trip on the warm HTTP/2 connection (count_tokens, free) = network + gateway floor."""
    out = {"config": "extra: count_tokens on a tiny prompt over the warm kept-alive connection; free"}
    ts = []
    for _ in range(n):
        t0 = time.perf_counter()
        raw = await client.messages.with_raw_response.count_tokens(model=HAIKU, messages=[{"role": "user", "content": "hi"}])
        await raw.parse()
        ts.append(round((time.perf_counter() - t0) * 1000, 1))
        await asyncio.sleep(0.3)
    out["ms"] = ts
    out["p50"] = pct(ts, 0.5)
    out["p90"] = p90_nearest(ts)
    out["min"] = min(ts)
    out["max"] = max(ts)
    return out


async def case_ab_salt(client, results, n=12):
    """Extra: same route, two different packs (salts A and H1), interleaved. Checks that pack content / case order does not change TTFT."""
    out = {"config": "extra: haiku(disabled,low), pack salt A vs pack salt H1, interleaved"}
    for salt in ("A", "H1"):
        out[f"{salt}_warmup"] = await stream_call(client, build_request("haiku", salt, "warmup question"), label=f"salt {salt} warm-up")
    calls = {"A": [], "H1": []}
    for i in range(n):
        for salt in ("A", "H1"):
            calls[salt].append(await stream_call(client, build_request("haiku", salt, question_for(salt, i + 40)), label=f"salt {salt} #{i + 1}"))
    for salt in calls:
        out[salt] = {"calls": calls[salt], "summary": summarize(calls[salt], need_cache_read=False)}
    return out


async def case_ab_salt4(client, results, n=12):
    """Extra (not in --all): 4 different packs, interleaved with a rotating start, same route. Is pack A special?"""
    salts = ["A", "H1", "B2", "C3"]
    out = {"config": "extra: haiku(disabled,low) on 4 different packs, round-robin with rotating start"}
    for salt in salts:
        out[f"{salt}_warmup"] = await stream_call(client, build_request("haiku", salt, "warmup question"), label=f"salt {salt} warm-up")
    calls = {k: [] for k in salts}
    for i in range(n):
        order = salts[i % 4:] + salts[:i % 4]
        for salt in order:
            calls[salt].append(await stream_call(client, build_request("haiku", salt, question_for(salt, i + 60)), label=f"salt {salt} #{i + 1}"))
    for salt in salts:
        out[salt] = {"calls": calls[salt], "summary": summarize(calls[salt], need_cache_read=False)}
    return out


async def case_model_compare(client, results, n=10):
    """Extra: is Haiku really faster than Sonnet here? Interleaved round-robin so drift hits all routes equally.
    Each route has its own pack salt (own cache entry) and an uncounted warm-up."""
    routes = [("haiku", "H1"), ("haiku_ad", "H2"), ("haiku_default", "H3"), ("sonnet_bt", "H4")]
    out = {"config": "extra: interleaved haiku(disabled,low) / haiku(adaptive,low) / haiku(no params) / sonnet(between_tools,medium)"}
    for r, salt in routes:
        out[f"{r}_warmup"] = await stream_call(client, build_request(r, salt, "warmup question"), label=f"{r} warm-up")
    calls = {r: [] for r, _ in routes}
    for i in range(n):
        for r, salt in routes:
            calls[r].append(await stream_call(client, build_request(r, salt, question_for(salt, i)), label=f"{r} #{i + 1}"))
    for r, _ in routes:
        out[r] = {"calls": calls[r], "summary": summarize(calls[r], need_cache_read=False)}
        out[r]["calls_with_thinking_block"] = sum(1 for c in calls[r] if "thinking" in c.get("block_types", []))
    return out


async def case_cancel(client, results):
    """Close a Sonnet stream after the first delta; compare with an un-cancelled control."""
    out = {"config": "sonnet-5-5 between_tools effort medium, long-output prompt (max_tokens 1500)"}
    long_q = ("Ignore the usual length limit for this test. Go through facts F001 to F040 one by one; for each fact write a "
              "SAY line and three bullets. Do not stop early.")
    def req():
        return build_request("sonnet_bt", "SB", long_q, max_tokens=1500)
    # make sure the cache is warm (and get baseline headers)
    base = await stream_call(client, build_request("sonnet_bt", "SB", "baseline question"), label="baseline before cancel")
    out["baseline"] = base
    cancelled = await stream_call(client, req(), cancel_after_first_delta=True, label="cancelled after first delta")
    out["cancelled"] = cancelled
    after = await stream_call(client, build_request("sonnet_bt", "SB", "baseline question after"), label="baseline after cancel")
    out["after_cancel"] = after
    control = await stream_call(client, req(), label="control: same prompt, not cancelled")
    out["control_uncancelled"] = control
    # cost bookkeeping: cancelled call has no final usage. Charge the budget pessimistically (full max_tokens).
    if cancelled.get("message_start_usage"):
        SPEND.add(SONNET, cancelled["message_start_usage"], assume_output=1500)
    cu = cancelled.get("message_start_usage", {})
    out["finding"] = {
        "cancelled_message_start_usage": cu,
        "cancelled_final_usage_available": bool(cancelled.get("usage", {}).get("output_tokens", 0) > cu.get("output_tokens", 0)),
        "control_output_tokens": control.get("usage", {}).get("output_tokens"),
        "output_tokens_ratelimit_remaining": {
            "baseline_before": base.get("headers", {}).get("anthropic-ratelimit-output-tokens-remaining"),
            "cancelled_response": cancelled.get("headers", {}).get("anthropic-ratelimit-output-tokens-remaining"),
            "baseline_after": after.get("headers", {}).get("anthropic-ratelimit-output-tokens-remaining"),
            "control_response": control.get("headers", {}).get("anthropic-ratelimit-output-tokens-remaining"),
        },
        "request_ids": {"cancelled": cancelled.get("request_id"), "control": control.get("request_id")},
        "billing_stopped": "UNCONFIRMED (no usage or billing endpoint is reachable with this key; check the Console usage page for the cancelled request id)",
    }
    return out


async def case_idle6m_haiku(client, results):
    """Optional (--long-idle): idle ladder on one kept-alive connection, then a real >5 min gap (cache TTL + client keepalive expire)."""
    out = {"config": "haiku as warm_haiku; one call after each idle gap on the same client (keepalive_expiry 300 s); the last gap (390 s) outlives both the 5 min cache TTL and the client's 300 s keepalive",
           "ladder": {}}
    out["before_idle"] = await stream_call(client, build_request("haiku", "L", "warmup question"), label="writes cache before idle")
    i = 0
    for gap in (30, 60, 120, 240, 390):
        print(f"   sleeping {gap} s ...", flush=True)
        await asyncio.sleep(gap)
        n_calls = 2 if gap == 390 else 1
        calls = []
        for _ in range(n_calls):
            calls.append(await stream_call(client, build_request("haiku", "L", question_for("L", 20 + i)), label=f"after {gap} s idle"))
            i += 1
        out["ladder"][f"{gap}s"] = {"calls": calls, "summary": summarize(calls, need_cache_read=False)}
    return out


def rate_limits_from(results: dict) -> dict:
    """Latest anthropic-ratelimit-* headers seen per model, plus the first-seen snapshot."""
    seen: dict[str, dict] = {}
    def walk(o):
        if isinstance(o, dict):
            if "headers" in o and "model" in o and isinstance(o["headers"], dict):
                rl = {k: v for k, v in o["headers"].items() if k.startswith("anthropic-ratelimit")}
                if rl:
                    seen.setdefault(o["model"], {"first": rl})["last"] = rl
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(results["cases"])
    return seen


# --------------------------------------------------------------------- output


def fmt(v, w=7):
    return f"{v:>{w}.0f}" if isinstance(v, (int, float)) else f"{'-':>{w}}"


def print_table(results: dict) -> str:
    rows = []
    def add(name, s):
        if not s:
            return
        rows.append((name, s))
    c = results["cases"]
    if "prewarm" in c:
        add("prewarm (real calls)", c["prewarm"].get("summary"))
    if "warm_haiku" in c:
        add("warm_haiku", c["warm_haiku"].get("summary"))
    if "cold_haiku" in c:
        add("cold_haiku (new conn)", c["cold_haiku"].get("summary"))
    if "idle10_haiku" in c:
        add("idle10_haiku", c["idle10_haiku"].get("summary"))
    if "burst3_haiku" in c:
        add("burst3_haiku (3 conc.)", c["burst3_haiku"].get("summary"))
    if "ab_salt" in c:
        add("ab: pack salt A", c["ab_salt"]["A"]["summary"])
        add("ab: pack salt H1", c["ab_salt"]["H1"]["summary"])
    if "ab_salt4" in c:
        for k in ("A", "H1", "B2", "C3"):
            add(f"ab4: pack salt {k}", c["ab_salt4"][k]["summary"])
    if "model_compare" in c:
        for r in ("haiku", "haiku_ad", "haiku_default", "sonnet_bt"):
            add(f"cmp:{r}", c["model_compare"][r]["summary"])
    if "idle6m_haiku" in c:
        for k, v in c["idle6m_haiku"].get("ladder", {}).items():
            add(f"idle ladder {k}", v.get("summary"))
    if "sonnet" in c:
        add("sonnet_between_tools", c["sonnet"]["sonnet_bt"]["summary"])
        add("sonnet_adaptive", c["sonnet"]["sonnet_ad"]["summary"])
    hdr = f"{'case':<26}{'n':>4}{'cache>0':>8} | {'TTFT p50':>9}{'p90':>7}{'max':>7} | {'SAY p50':>8}{'p90':>7} | {'pt1 p50':>8}{'p90':>7} | {'done p50':>9}{'p90':>7} | {'hdrs p50':>9}"
    lines = [hdr, "-" * len(hdr)]
    for name, s in rows:
        lines.append(f"{name:<26}{s['n_ok']:>4}{s['n_cache_read_gt0']:>8} | "
                     f"{fmt(s['t_first_text']['p50'], 9)}{fmt(s['t_first_text']['p90'])}{fmt(s['t_first_text']['max'])} | "
                     f"{fmt(s['t_say']['p50'], 8)}{fmt(s['t_say']['p90'])} | "
                     f"{fmt(s['t_point1']['p50'], 8)}{fmt(s['t_point1']['p90'])} | "
                     f"{fmt(s['t_done']['p50'], 9)}{fmt(s['t_done']['p90'])} | "
                     f"{fmt(s['t_headers']['p50'], 9)}")
    lines.append("(ms from request start; p50 = median, p90 = nearest rank; TTFT = first text delta; SAY = first complete 'SAY:' line; pt1 = first complete '- ' point)")
    if "floor" in c:
        f = c["floor"]
        lines.append(f"no-inference round trip on warm connection (count_tokens x{len(f['ms'])}): p50 {f['p50']:.0f} ms, p90 {f['p90']:.0f} ms, min {f['min']:.0f}, max {f['max']:.0f}")
    return "\n".join(lines)


def save(results: dict, path: Path) -> None:
    results["spend"] = {"total_usd": round(SPEND.usd, 5), "by_model_usd": {k: round(v, 5) for k, v in SPEND.by_model.items()},
                        "priced_calls": SPEND.calls,
                        "prices_per_mtok": {m: {"input": a, "output": b, "cache_write_5m_x": CACHE_WRITE_5M, "cache_read_x": CACHE_READ}
                                            for m, (a, b) in PRICES.items()}}
    results["rate_limits"] = rate_limits_from(results)
    path.write_text(json.dumps(results, indent=1, ensure_ascii=False))


ALL_CASES = ["floor", "prewarm", "warm_haiku", "cold_haiku", "idle10_haiku", "burst3_haiku", "sonnet", "model_compare", "ab_salt", "cancel"]


async def main_async(args) -> int:
    key = read_key()
    ts = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = HERE / "results"
    out_dir.mkdir(exist_ok=True)
    out_path = out_dir / f"api-{ts}.json"
    results: dict = {"meta": {"timestamp": ts, "python": platform.python_version(), "anthropic": anthropic.__version__,
                              "httpx2": httpx2.__version__, "models": {"haiku": HAIKU, "sonnet": SONNET},
                              "host": platform.platform(), "client": "AsyncAnthropic + DefaultAsyncHttpxClient(http2=True, keepalive_expiry=300), max_retries=0"},
                     "cases": {}}
    cases = ALL_CASES if args.all else [c.strip() for c in args.cases.split(",") if c.strip()]
    if args.long_idle and "idle6m_haiku" not in cases:
        cases.append("idle6m_haiku")
    client = make_client(key)
    status = 0
    try:
        await setup(client, results)
        for name in cases:
            print(f"== {name}", flush=True)
            t = time.perf_counter()
            if name == "floor":
                res = await case_floor(client, results)
            elif name == "ab_salt":
                res = await case_ab_salt(client, results)
            elif name == "ab_salt4":
                res = await case_ab_salt4(client, results)
            elif name == "prewarm":
                res = await case_prewarm(client, results)
            elif name == "warm_haiku":
                res = await case_warm_haiku(client, results)
            elif name == "cold_haiku":
                res = await case_cold_haiku(key, results)
            elif name == "idle10_haiku":
                res = await case_idle10_haiku(client, results)
            elif name == "burst3_haiku":
                res = await case_burst3_haiku(client, results)
            elif name == "sonnet":
                res = await case_sonnet(client, results)
            elif name == "model_compare":
                res = await case_model_compare(client, results)
            elif name == "cancel":
                res = await case_cancel(client, results)
            elif name == "idle6m_haiku":
                res = await case_idle6m_haiku(client, results)
            else:
                print(f"unknown case {name}")
                continue
            res["wall_s"] = round(time.perf_counter() - t, 1)
            results["cases"][name] = res
            save(results, out_path)
            s = res.get("summary")
            if s:
                print(f"   n_ok={s['n_ok']}/{s['n_requested']} cache>0={s['n_cache_read_gt0']} TTFT p50={fmt(s['t_first_text']['p50'],0).strip()} p90={fmt(s['t_first_text']['p90'],0).strip()} max={fmt(s['t_first_text']['max'],0).strip()}  spend so far ${SPEND.usd:.4f}", flush=True)
            else:
                print(f"   done, spend so far ${SPEND.usd:.4f}", flush=True)
    except FatalStop as e:
        results["fatal_stop"] = str(e)
        print(f"FATAL STOP: {e}", flush=True)
        status = 2
    except Exception as e:  # noqa: BLE001 - never print a traceback frame with the client in it
        results["unexpected_error"] = f"{type(e).__name__}: {str(e)[:300]}"
        print(f"UNEXPECTED {type(e).__name__}: {str(e)[:300]}", flush=True)
        status = 1
    finally:
        try:
            await client.close()
        except Exception:  # noqa: BLE001
            pass
        # the key must never reach the file
        save(results, out_path)
        if key in out_path.read_text():
            out_path.unlink()
            print("!! key found in results file; file removed", flush=True)
            status = 3
    table = print_table(results)
    results["table_text"] = table
    save(results, out_path)
    print("\n" + table, flush=True)
    print(f"\ntotal spend (from usage): ${SPEND.usd:.4f}  by model: { {k: round(v, 4) for k, v in SPEND.by_model.items()} }", flush=True)
    print(f"org id: {results['meta'].get('organization_id')}", flush=True)
    print(f"results: {out_path}", flush=True)
    return status


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true", help=f"run {', '.join(ALL_CASES)}")
    ap.add_argument("--cases", default="", help="comma separated subset")
    ap.add_argument("--long-idle", action="store_true", help="also run idle6m_haiku (~7 min real idle)")
    args = ap.parse_args()
    if not (args.all or args.cases or args.long_idle):
        ap.error("pass --all or --cases")
    try:
        sys.exit(asyncio.run(main_async(args)))
    except FatalStop as e:
        print(f"FATAL STOP: {e}", flush=True)
        sys.exit(2)


if __name__ == "__main__":
    main()
