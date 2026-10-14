"""review.md: the human-readable bank, for Alex to read and correct before the call."""

from __future__ import annotations

from .ground import Dropped


def _q(quote: str) -> str:
    return " ".join(quote.split())


def render_review(meta: dict, bank: list[dict], facts: list[dict], glossary: list[dict], snippets: list[dict],
                  dropped: list[Dropped], warnings: list[str]) -> str:
    st = meta["stats"]
    L: list[str] = []
    L.append(f"# Verse prep review: {meta['session_id']}")
    L.append("")
    L.append(f"Prep note: `{meta['prep_note']}`  ")
    L.append(f"Languages: {', '.join(meta['languages'])} | Repos: {', '.join(meta['repos']) or 'none'}  ")
    L.append(f"Model: {meta['prep_model']} (effort high) | Spend: ${meta['prep_spend_usd']:.4f}  ")
    L.append(f"Bank {len(bank)} entries | facts {len(facts)} | glossary {len(glossary)} | snippets {len(snippets)} | "
             f"pack {st.get('pack_tokens', '?')} tokens (cap {st.get('pack_cap', '?')})  ")
    L.append(f"Dropped for missing or unverifiable sources: {meta['dropped_unsourced_points']} points without a source, "
             f"{st.get('points_dropped_unsupported_quote', 0)} with a quote not found in the source, "
             f"{st.get('points_dropped_unsupported_number', 0)} with a number not in the quote.")
    if warnings:
        L.append("")
        L.append("## Warnings")
        L += [f"- {w}" for w in warnings]
    L.append("")
    L.append("Edit `bank.jsonl` (or tell Verse what is wrong) before the call. Each point below shows the line it was "
             "grounded in.")
    L.append("")
    L.append("## Answer bank")
    for b in bank:
        L.append("")
        L.append(f"### {b['id']} ({b['lang']}) {b['question']}")
        for lang, ps in b["paraphrases"].items():
            L.append(f"- also asked ({lang}): " + " / ".join(ps))
        L.append(f"- **SAY:** {b['opener']}")
        for p in b["points"]:
            L.append(f"- {p}")
        if b["deep"]:
            L.append(f"- _Deep:_ {b['deep']}")
        L.append("- Sources: " + "; ".join(f"`{s['ref']}` \"{_q(s['quote'])}\"" for s in b["sources"]))
    L.append("")
    L.append("## Fact sheet")
    for f in facts:
        L.append(f"- **{f['id']}** ({f['kind']}) {f['text']} = `{f['value']}`  <- " +
                 "; ".join(f"`{s['ref']}`" for s in f["sources"]))
    L.append("")
    L.append("## Glossary")
    for g in glossary:
        L.append(f"- **{g['id']}** {g['term']}: {g['line']}  <- " + "; ".join(f"`{s['ref']}`" for s in g["sources"]))
    L.append("")
    L.append("## Vault snippets")
    for s in snippets:
        txt = _q(s["text"])
        L.append(f"- **{s['id']}** `{s['ref']}` (bank: {', '.join(s['bank_ids']) or 'glossary'}): {txt[:200]}")
    L.append("")
    L.append("## Dropped (not in the bank)")
    if not dropped:
        L.append("- nothing")
    for d in dropped:
        L.append(f"- [{d.what}: {d.reason}] {_q(d.text)[:200]}" + (f" (re: {d.where})" if d.where else ""))
        if d.claimed and d.reason != "unsourced":
            L.append(f"  - claimed: {_q(d.claimed)[:300]}")
    return "\n".join(L) + "\n"
