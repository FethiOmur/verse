"""Live measurement of Haiku's bank verdict (the `BANK:` line -> `bank_verdict`) on near misses and true paraphrases.

Not a pytest file (no `test_` prefix): it calls the real fast tier through the brain's own transport and Keychain key, and costs
money. It drives `engine.Brain` directly (no Swift app), on a session folder it builds from bench/embed/ml/en_bank.json (the
sample-interview bank; the pack has no FACTS or GLOSSARY, each entry's deep answer is a SNIPPETS line), with the 6 opening
turns of bench/llm-local/prompts.py as `history`. D (Sonnet) is never fired (a stub stands in, so the engine's hold / release /
refire of D is timed); S, F and the verdict check V run as live.

    cd brain && .venv/bin/python tests/live_bank_verdict.py --mode dry   --out OUT          # embedding hits only: no API, no cost
    cd brain && .venv/bin/python tests/live_bank_verdict.py --mode embed --out OUT --reps 3 [--prefer-bank] [--budget 0.2]
    cd brain && .venv/bin/python tests/live_bank_verdict.py --mode forced --out OUT --reps 3 [--prefer-bank] [--budget 0.2]

- `dry`: the real embedder, FakeTransport. Each case is spoken word by word (`--pace` s per word, `cue` on) and closed as a
  question; records which cases the paraphrase matcher shows a card for, and which entry. Writes OUT/dry.json.
- `embed`: the same, with the real transport, for the cases that hit in OUT/dry.json (run `dry` first). The card appears at
  the `bank_hit`; the verdict delay is measured from it.
- `forced`: no embedder, no partials: a lexical-style `bank_hit` (Swift's n-gram path, no `via`) for the entry the case
  resembles, sent right before the turn, then the turn. Every near miss and paraphrase gets a card, so this measures the
  verdict on all of them, and the lexical path.

Each run appends one JSON line per case and repetition to OUT/<mode>[-prefer].jsonl and prints the rates. Spend is the brain's
own accounting (`Brain.spend`: usage x the price table in prep/model.py), i.e. gross list price; net is not known here. The run
stops before a case once the spend reaches `--budget`.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import statistics
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
os.environ.setdefault("VERSE_OWNER_FILE", str(HERE / "fixtures" / "owner" / "pinned.json"))   # same owner as the tests
os.environ["VERSE_EVENTS"] = "0"
sys.path.insert(0, str(HERE.parent))

from verse_brain.runtime.engine import Brain  # noqa: E402
from verse_brain.runtime.protocol import ListEmitter  # noqa: E402
from verse_brain.runtime.settings import Config  # noqa: E402

ML = REPO / "bench" / "embed" / "ml"
PREAMBLE = [
    ("r1", "remote", "Thanks for joining. I'm Ingrid, I lead engineering here, and Tomas from the platform team is with me today."),
    ("m1", "me", "Thanks for having me, I'm happy to be here."),
    ("r2", "remote", "We have about forty minutes. First, can you give us a quick overview of what you have been working on recently?"),
    ("m2", "me", "Sure. The main thing was Lantern, an LLM pipeline for supplier invoices, and a small route optimiser for a courier pilot."),
    ("r3", "remote", "Interesting. We have been moving our dispatch from rules to something LLM assisted, so that is relevant for us."),
    ("m3", "me", "That is exactly what drew me to Halden."),
]
_W = re.compile(r"[\w']+")


def build_session(out: Path, prefer_bank: bool) -> Path:
    bank = json.loads((ML / "en_bank.json").read_text())["bank"]
    d = out / ("session-prefer" if prefer_bank else "session")
    d.mkdir(parents=True, exist_ok=True)
    pack = ["## FACTS", "", "## GLOSSARY", "", "## ANSWER BANK"]
    recs = []
    for i, (bid, e) in enumerate(sorted(bank.items()), 1):
        pack.append(f"[{bid}] Q (en): {e['question']}")
        pack.append(f"SAY: {e['opener']}")
        pack += [f"- {p}" for p in e["points"]]
        recs.append({"id": bid, "lang": "en", "question": e["question"], "paraphrases": e["paraphrases"], "opener": e["opener"],
                     "points": e["points"], "deep": e["deep"], "sources": [{"kind": "prep", "ref": f"prep:L{i}", "quote": ""}]})
    pack += ["", "## SNIPPETS"]
    pack += [f"[s{i:03d}] prep:L{i} | {' '.join(e['deep'].split())}" for i, (_, e) in enumerate(sorted(bank.items()), 1)]
    (d / "pack.md").write_text("\n".join(pack) + "\n")
    (d / "bank.jsonl").write_text("".join(json.dumps(r) + "\n" for r in recs))
    (d / "meta.json").write_text(json.dumps({"session_id": "verdict-live", "languages": ["en"]}))
    if prefer_bank:
        (d / "call.json").write_text(json.dumps({"prefer_bank": True}))
    elif (d / "call.json").exists():
        raise SystemExit(f"{d}/call.json exists in a non-prefer session folder")
    return d


def cases() -> list[dict]:
    held = json.loads((ML / "en_heldout.json").read_text())
    near = json.loads((ML / "en_near.json").read_text())
    out = [{"cid": f"hn{i:02d}", "label": "near", "set": "heldout", "text": c["text"], "entry": c["near"]}
           for i, c in enumerate(held["near"])]
    out += [{"cid": f"nn{i:02d}", "label": "near", "set": "en_near", "text": c["text"], "entry": c["near"]}
            for i, c in enumerate(near["near"])]
    for bid, texts in sorted(held["paraphrases"].items()):
        out += [{"cid": f"hp{bid}{j}", "label": "para", "set": "heldout", "text": t, "entry": bid} for j, t in enumerate(texts)]
    return out


class Emitter(ListEmitter):
    pass


def make_brain(transport, embed: bool) -> tuple[Brain, Emitter]:
    em = Emitter()
    cfg = Config(summary_every_turns=10_000, summary_every_s=1e9, d_stable_s=1e9)
    factory = None
    if embed:
        from verse_brain.runtime.embed import LiteRtEmbedder

        factory = lambda: LiteRtEmbedder(cfg.embed_model, cfg.embed_backend)  # noqa: E731
    b = Brain(transport, em, cfg, embedder_factory=factory)
    b.start_background = False
    fired: list[tuple[str, float, bool, str | None]] = []
    shown: list[tuple[str, float, str | None]] = []

    class StubD:
        """No Sonnet in this measurement: a stand-in D call the engine can hold, release or discard (engine `_decide_d`),
        recording when D would be fired and when its lines would reach the screen, and with which entry's deep answer."""
        n = 0

        def __init__(self, tid, buffered, bank):
            StubD.n += 1
            self.id, self.tier, self.turn_id = f"d-stub{StubD.n}", "D", tid
            self.buffered, self.discarded, self.bank_ref = buffered, False, bank
            self.error, self.size, self.input_tokens = None, None, []
            if not buffered:
                shown.append((tid, time.monotonic(), bank))

        def release(self):
            if self.buffered and not self.discarded:
                self.buffered = False
                shown.append((self.turn_id, time.monotonic(), self.bank_ref))

        def discard(self):
            self.discarded = True

    def fire_d(st, text, *, final, buffered, opener=None):
        rec = b._bank_rec(st)
        bank = rec.get("id") if rec else None
        fired.append((st.turn_id, time.monotonic(), buffered, bank))
        return StubD(st.turn_id, buffered, bank)

    b._fire_d = fire_d
    b._d_fired = fired
    b._d_shown = shown
    return b, em


async def start(b: Brain, session: Path) -> None:
    await b.handle({"type": "start", "session_dir": str(session), "lang": "en"})
    await b.warmed()
    end = time.monotonic() + 30
    while b.embed is not None and b.embed.state == "loading" and time.monotonic() < end:
        await asyncio.sleep(0.05)
    await b.handle({"type": "history", "turns": [{"turn_id": t, "speaker": s, "text": x} for t, s, x in PREAMBLE]})


async def settle(b: Brain, timeout: float = 20.0) -> None:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        busy = [c for c in b.calls if not c.done.is_set()] + [t for t in b.tasks if not t.done()]
        if not busy and (b.embed is None or (b.embed._pending is None and not b.embed._busy)):
            return
        await asyncio.sleep(0.05)


def overlap(a: str, b: str) -> float:
    x, y = set(_W.findall(a.lower())), set(_W.findall(b.lower()))
    return len(x & y) / max(1, min(len(x), len(y)))


async def run_case(b: Brain, em: Emitter, case: dict, tid: str, mode: str, pace: float) -> dict:
    n0 = len(em.events)
    words = case["text"].split()
    t_turn = None
    if mode == "forced":
        await b.handle({"type": "bank_hit", "turn_id": tid, "bank_id": case["entry"], "score": 0.9})
    else:
        for n in range(1, len(words) + 1):
            await b.handle({"type": "partial", "turn_id": tid, "speaker": "remote", "text": " ".join(words[:n]), "cue": True,
                            "t_audio_end": 0.0})
            await asyncio.sleep(pace)
    t_turn = time.monotonic()
    await b.handle({"type": "turn", "turn_id": tid, "speaker": "remote", "text": case["text"], "addressee": "me",
                    "kind": "question", "t_audio_end": 0.0})
    await settle(b)
    evs = list(zip(em.events[n0:], em.times[n0:]))
    hits = [(e, t) for e, t in evs if e["type"] == "bank_hit" and e.get("turn_id") == tid]
    verdicts = [(e, t) for e, t in evs if e["type"] == "bank_verdict" and e.get("turn_id") == tid]
    t_hit = hits[0][1] if hits else (t_turn if mode == "forced" else None)
    hit_id = hits[0][0]["bank_id"] if hits else (case["entry"] if mode == "forced" else None)
    st = b.ts.get(tid)
    fast = st.fast if st is not None else None
    rec = {**case, "tid": tid, "hit": hit_id, "verdict": None, "verdict_reason": None, "delay_hit_s": None, "delay_turn_s": None,
           "fast_tier": fast.tier if fast else None, "fast_bank": fast.bank_id if fast else None,
           "say": fast.say_line if fast else None, "points": list(fast.points) if fast else [],
           "fast_error": fast.error.kind if fast and fast.error else None, "fast_stop": fast.stop_reason if fast else None,
           "fast_input": fast.input_text if fast else None,
           "fast_checked": bool(fast) and "BANK CHECK" in fast.request["messages"][-1]["content"][-1]["text"], "pulled_in_brain": st is not None and st.bank_hit is None}
    if verdicts:
        v, tv = verdicts[0]
        rec["verdict"] = "agree" if v["agree"] else "disagree"
        rec["verdict_reason"] = v.get("reason")
        rec["delay_hit_s"] = round(tv - t_hit, 3) if t_hit is not None else None
        rec["delay_turn_s"] = round(tv - t_turn, 3)
    # D start: the first D fired at the endpoint (held or not); D shown: when its lines would reach the screen, and with which
    # entry's deep answer (a held D dropped on a rejection is never shown); refired: a second D after a rejection
    dfire = [(t, bank) for x, t, buffered, bank in b._d_fired if x == tid and t >= t_turn]
    dshown = [(t, bank) for x, t, bank in b._d_shown if x == tid and t >= t_turn]
    rec["d_after_turn_s"] = round(dfire[0][0] - t_turn, 3) if dfire else None
    rec["d_shown_after_turn_s"] = round(dshown[0][0] - t_turn, 3) if dshown else None
    rec["d_bank"] = dshown[0][1] if dshown else None
    rec["d_fires"] = len(dfire)
    say_t = [t for e, t in evs if e["type"] == "delta" and e.get("turn_id") == tid and e.get("tier") in ("S", "F")]
    rec["first_text_after_turn_s"] = round(min(say_t) - t_turn, 3) if say_t else None
    # which call gave the verdict (S / F / V), the verdict checks launched, and the fast call's length and timing
    mets = [e for e, _ in evs if e["type"] == "metric" and e.get("turn_id") == tid]
    vm = [m for m in mets if m["stage"] == "bank_verdict"]
    rec["verdict_by"] = vm[0]["tier"] if vm else None
    vc = [m for m in mets if m["stage"] == "verdict_check"]
    rec["checks"] = sum(bool(m.get("launched")) for m in vc)
    rec["check_why"] = vc[0].get("why") if vc else None
    chk = [c for c in b.calls if c.turn_id == tid and c.tier == "V"]
    rec["check_stop"] = chk[-1].stop_reason if chk else None
    rec["check_bank"] = chk[-1].bank_id if chk else None
    rec["check_out_tokens"] = chk[-1].usage.get("output_tokens") if chk else None
    rec["fast_out_tokens"] = fast.usage.get("output_tokens") if fast else None
    ft = fast.t if fast else {}
    rec["fast_first_s"] = round(ft["first_delta"] - ft["fire"], 3) if "first_delta" in ft and "fire" in ft else None
    rec["fast_total_s"] = round(ft["done"] - ft["fire"], 3) if "done" in ft and "fire" in ft else None
    rec["fast_tail_s"] = round(ft["done"] - ft["first_delta"], 3) if "done" in ft and "first_delta" in ft else None
    if hit_id and fast and b.session and hit_id in b.session.bank:
        e = b.session.bank[hit_id]
        rec["say_reuses_entry"] = bool(fast.say_line) and overlap(fast.say_line, e["opener"]) >= 0.6
    # the transcript stays at the preamble: every case sees the same context (and the same cached prefix)
    b.turns = b.turns[:len(PREAMBLE)]
    return rec


def pct(xs: list[float], q: float) -> float | None:
    if not xs:
        return None
    xs = sorted(xs)
    k = max(0, min(len(xs) - 1, round(q * (len(xs) - 1))))
    return xs[k]


def report(recs: list[dict]) -> dict:
    out = {}
    for label in ("near", "para"):
        rs = [r for r in recs if r["label"] == label and r["hit"]]
        if not rs:
            continue
        n = len(rs)
        agree = sum(r["verdict"] == "agree" for r in rs)
        dis = sum(r["verdict"] == "disagree" for r in rs)
        miss = sum(r["verdict"] is None for r in rs)
        delays = [r["delay_hit_s"] for r in rs if r["delay_hit_s"] is not None]
        dturn = [r["delay_turn_s"] for r in rs if r["delay_turn_s"] is not None]
        reuse = sum(bool(r.get("say_reuses_entry")) for r in rs)
        dd = [r["d_after_turn_s"] for r in rs if r.get("d_after_turn_s") is not None]
        ds = [r["d_shown_after_turn_s"] for r in rs if r.get("d_shown_after_turn_s") is not None]
        dwrong = sum(1 for r in rs if r.get("d_bank") is not None)
        out[label] = {"runs": n, "cases": len({r["cid"] for r in rs}), "agree": agree, "disagree": dis, "no_verdict": miss,
                      "say_reuses_entry": reuse,
                      "delay_after_card_p50": pct(delays, 0.5), "delay_after_card_p90": pct(delays, 0.9),
                      "delay_after_turn_p50": pct(dturn, 0.5), "delay_after_turn_p90": pct(dturn, 0.9),
                      "d_fired": len(dd), "d_with_entry_deep_answer": dwrong,
                      "d_after_turn_p50": pct(dd, 0.5), "d_after_turn_p90": pct(dd, 0.9),
                      "d_shown_after_turn_p50": pct(ds, 0.5), "d_shown_after_turn_p90": pct(ds, 0.9),
                      "d_refired": sum(1 for r in rs if (r.get("d_fires") or 0) > 1),
                      "fast_max_tokens": sum(r.get("fast_stop") == "max_tokens" for r in rs),
                      "verdict_by": {k: sum(r.get("verdict_by") == k for r in rs) for k in ("S", "F", "V", None)},
                      "checks_per_run": round(sum(r.get("checks") or 0 for r in rs) / n, 3),
                      "check_no_bank_line": sum(1 for r in rs if r.get("checks") and r.get("check_bank") is None)}
    fasts = [r for r in recs if r.get("fast_out_tokens") is not None]
    if fasts:
        toks = [r["fast_out_tokens"] for r in fasts]
        tails = [r["fast_tail_s"] for r in fasts if r.get("fast_tail_s") is not None]
        firsts = [r["fast_first_s"] for r in fasts if r.get("fast_first_s") is not None]
        out["fast"] = {"runs": len(fasts), "out_tokens_p50": pct(toks, 0.5), "out_tokens_p90": pct(toks, 0.9), "out_tokens_max": max(toks),
                       "over_120": sum(t > 120 for t in toks), "max_tokens_stops": sum(r.get("fast_stop") == "max_tokens" for r in fasts),
                       "first_delta_p50": pct(firsts, 0.5), "first_delta_p90": pct(firsts, 0.9),
                       "first_to_done_p50": pct(tails, 0.5), "first_to_done_p90": pct(tails, 0.9)}
    return out


async def amain(args) -> int:
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    session = build_session(out, args.prefer_bank)
    all_cases = cases()
    if args.only:
        want = set(args.only.split(","))
        all_cases = [c for c in all_cases if c["label"] in want]
    if args.cids:
        all_cases = [c for c in all_cases if c["cid"] in set(args.cids.split(","))]
    if args.mode == "embed":
        dry = json.loads((out / "dry.json").read_text())
        hit_ids = {r["cid"] for r in dry if r["hit"]}
        all_cases = [c for c in all_cases if c["cid"] in hit_ids]
    if args.para_sample and args.mode != "dry":
        paras = [c for c in all_cases if c["label"] == "para"]
        keep = {c["cid"] for c in paras[::max(1, len(paras) // args.para_sample)][:args.para_sample]}
        all_cases = [c for c in all_cases if c["label"] != "para" or c["cid"] in keep]
    if args.limit:
        all_cases = all_cases[:args.limit]
    if args.mode == "dry":
        from verse_brain.runtime.fake import FakeTransport

        transport = FakeTransport()
    else:
        from verse_brain.prep.keychain import read_api_key
        from verse_brain.runtime.transport import AnthropicTransport

        transport = AnthropicTransport(read_api_key())
    b, em = make_brain(transport, embed=args.mode in ("dry", "embed"))
    await start(b, session)
    name = "dry" if args.mode == "dry" else f"{args.mode}{'-prefer' if args.prefer_bank else ''}{args.tag}"
    recs: list[dict] = []
    log = None if args.mode == "dry" else (out / f"{name}.jsonl").open("a")
    stopped = None
    try:
        reps = 1 if args.mode == "dry" else args.reps
        for rep in range(reps):
            for i, case in enumerate(all_cases):
                if args.mode != "dry" and b.spend >= args.budget:
                    stopped = f"budget {args.budget} reached at spend {b.spend:.4f}"
                    break
                rec = await run_case(b, em, case, f"{case['cid']}-{rep}", args.mode if args.mode != "dry" else "embed", args.pace)
                rec["rep"] = rep
                rec["spend_after"] = round(b.spend, 6)
                recs.append(rec)
                if log:
                    log.write(json.dumps(rec) + "\n")
                    log.flush()
                print(f"[{rep}] {case['cid']:10s} {case['label']:4s} hit={rec['hit']} entry={case['entry']} verdict={rec['verdict']} "
                      f"fast={rec['fast_bank']} by={rec['verdict_by']} chk={rec['checks']} tok={rec['fast_out_tokens']} d={rec['delay_hit_s']} "
                      f"spend={b.spend:.4f}", flush=True)
            if stopped:
                break
    finally:
        if log:
            log.close()
        await b.shutdown()
    if args.mode == "dry":
        (out / "dry.json").write_text(json.dumps(recs, indent=1))
        for label in ("near", "para"):
            rs = [r for r in recs if r["label"] == label]
            print(f"{label}: {sum(bool(r['hit']) for r in rs)}/{len(rs)} shown a card "
                  f"(right entry {sum(r['hit'] == r['entry'] for r in rs)})")
        return 0
    summary = {"name": name, "spend_usd_gross": round(b.spend, 6), "stopped": stopped, "rates": report(recs)}
    print(json.dumps(summary, indent=1))
    (out / f"{name}.summary.json").write_text(json.dumps(summary, indent=1))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=("dry", "embed", "forced"), required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--pace", type=float, default=0.3, help="seconds per word of the spoken partials")
    ap.add_argument("--prefer-bank", action="store_true", help="the session has call.json {prefer_bank: true}")
    ap.add_argument("--budget", type=float, default=0.15, help="stop once Brain.spend reaches this (USD, gross)")
    ap.add_argument("--only", default="", help="near,para")
    ap.add_argument("--para-sample", type=int, default=0, help="keep this many paraphrase cases (evenly spaced)")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--cids", default="", help="only these case ids (comma separated)")
    ap.add_argument("--tag", default="", help="suffix of the output file name")
    args = ap.parse_args()
    return asyncio.run(amain(args))


if __name__ == "__main__":
    sys.exit(main())
