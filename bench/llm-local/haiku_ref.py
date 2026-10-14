"""Reference answers from the production S/F route (Haiku 5.5, thinking disabled, effort low) for the same 10
questions and the same prompt as bench_llm.py (p3k). Run with brain/.venv/bin/python. Key from the Keychain,
never printed or written. Prints the spend."""
from __future__ import annotations
import getpass, json, os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
BRAIN = os.path.abspath(os.path.join(HERE, "..", "..", "brain"))
sys.path.insert(0, BRAIN); sys.path.insert(0, HERE)
import prompts as pr
from verse_brain.runtime.settings import route_params
from verse_brain.prep.model import PRICES, HAIKU
import anthropic

key = subprocess.run(["security", "find-generic-password", "-a", os.environ.get("USER") or getpass.getuser(), "-s", "verse-anthropic", "-w"],
                     capture_output=True, text=True, timeout=30).stdout.strip()
assert key, "keychain item missing"
client = anthropic.Anthropic(api_key=key, max_retries=1, timeout=60.0)
out, cost = [], 0.0
pin, pout = PRICES[HAIKU]
for qid, q, kind in pr.QUESTIONS:
    req = pr.P.build_request("S", route_params("S"), pr.PACK, pr.TURNS, pr.P.fast_tail(q, "en", True))
    t = time.perf_counter()
    m = client.messages.create(**req)
    dt = time.perf_counter() - t
    text = "".join(b.text for b in m.content if getattr(b, "type", "") == "text")
    u = m.usage
    ci, co = u.input_tokens, u.output_tokens
    cr, cw = getattr(u, "cache_read_input_tokens", 0) or 0, getattr(u, "cache_creation_input_tokens", 0) or 0
    c = (ci * pin + co * pout + cr * pin * 0.1 + cw * pin * 1.25) / 1e6
    cost += c
    out.append(dict(qid=qid, question=q, text=text, seconds=dt, usage=dict(input=ci, output=co, cache_read=cr, cache_write=cw), usd=c))
    print(qid, f"{dt:.2f}s", dict(input=ci, output=co, cr=cr, cw=cw), f"${c:.5f}")
json.dump(out, open(os.path.join(HERE, "results", "haiku_answers.json"), "w"), indent=1)
print(f"total spend ${cost:.4f}")
