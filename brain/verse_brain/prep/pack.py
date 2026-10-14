"""The frozen meeting pack (the cache prefix). Deterministic: same inputs give byte-identical output.

Order (plan P1-1): instruction-free facts -> glossary -> bank (opener + points only) -> snippets.
No timestamps, session ids or other per-run values may appear in the pack.
"""

from __future__ import annotations

import math
from typing import Awaitable, Callable

TOKEN_CAP = 12_000
SAFETY = 0.97  # trim to 97 % of the cap so a re-count by another tokenizer path still fits

Counter = Callable[[str], Awaitable[int]]


def _one_line(s: str) -> str:
    return " ".join(s.split())


def _first_ref(rec: dict) -> str:
    srcs = rec.get("sources") or []
    return srcs[0]["ref"] if srcs else ""


def render_pack(facts: list[dict], glossary: list[dict], bank: list[dict], snippets: list[dict]) -> str:
    out: list[str] = []
    out.append("## FACTS")
    for f in sorted(facts, key=lambda r: r["id"]):
        out.append(f"[{f['id']}] {f['kind']} | {_one_line(f['text'])} | {_one_line(f['value'])} | {_first_ref(f)}")
    out.append("")
    out.append("## GLOSSARY")
    for g in sorted(glossary, key=lambda r: r["id"]):
        out.append(f"[{g['id']}] {_one_line(g['term'])}: {_one_line(g['line'])} | {_first_ref(g)}")
    out.append("")
    out.append("## ANSWER BANK")
    for b in sorted(bank, key=lambda r: r["id"]):
        out.append(f"[{b['id']}] Q ({b['lang']}): {_one_line(b['question'])}")
        out.append(f"SAY: {_one_line(b['opener'])}")
        for p in b["points"]:
            out.append(f"- {_one_line(p)}")
    out.append("")
    out.append("## SNIPPETS")
    for s in sorted(snippets, key=lambda r: r["id"]):
        out.append(f"[{s['id']}] {s['ref']} | {_one_line(s['text'])}")
    return "\n".join(out) + "\n"


async def fit_pack(
    facts: list[dict], glossary: list[dict], bank: list[dict], snippets: list[dict],
    count: Counter, cap: int = TOKEN_CAP,
) -> tuple[str, int, dict]:
    """Render the pack and trim it to `cap` tokens. Cut order: lowest-priority snippets first (priority = number
    of bank entries a snippet serves, then id), then bank entries from the tail (least likely), then glossary
    tail, then facts tail. Returns (text, tokens, trimmed-counts)."""
    target = int(cap * SAFETY)
    snips = sorted(snippets, key=lambda s: (-len(s.get("bank_ids", [])), s["id"]))  # best first
    keep = {"snippets": list(snips), "bank": sorted(bank, key=lambda r: r["id"]),
            "glossary": sorted(glossary, key=lambda r: r["id"]), "facts": sorted(facts, key=lambda r: r["id"])}
    cut = {"snippets": 0, "bank": 0, "glossary": 0, "facts": 0}
    text = render_pack(keep["facts"], keep["glossary"], keep["bank"], keep["snippets"])
    tokens = await count(text)
    for _ in range(40):
        if tokens <= target:
            break
        section = next((k for k in ("snippets", "bank", "glossary", "facts") if keep[k]), None)
        if section is None:
            break
        over = tokens - target
        items = keep[section]
        avg_chars = max(1, sum(len(_one_line(str(x))) for x in items) // len(items))
        avg_tokens = max(1.0, avg_chars * tokens / max(1, len(text)))
        k = min(len(items), max(1, math.ceil(over / avg_tokens)))
        del items[len(items) - k:]
        cut[section] += k
        text = render_pack(keep["facts"], keep["glossary"], keep["bank"], keep["snippets"])
        tokens = await count(text)
    return text, tokens, cut
