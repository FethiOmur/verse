"""build(): prep note + repos + vault -> a session folder (the contract in docs/plans/2026-10-14-verse-v1.md).

Session folder: <out>/<session-id>/{meta.json, bank.jsonl, facts.jsonl, glossary.jsonl, snippets.jsonl, pack.md,
review.md}. `out` is the sessions root (default on the Mac: ~/Library/Application Support/Verse/sessions).
The folder is written under a temporary name and renamed at the end, so a failed run leaves no half session.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import re
import shutil
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

from .conflicts import apply_conflicts
from .git_digest import Commit, GitError, read_commits
from .ground import ground
from .model import MAX_OUTPUT_TOKENS, PREP_MODEL, PRICES, PrepError, PrepModel, spend_usd
from .pack import TOKEN_CAP, fit_pack
from .parse import parse_output
from .prompt import SYSTEM, render_user
from .review import render_review
from .sources import SourceBook
from .vault import Vault, VaultError, VaultRecord
from .voice import load_voice, sha256_text

MAX_PREP_NOTE_CHARS = 60_000
MAX_VAULT_SEED_RECORDS = 12
SNIPPET_CHARS = 600


def _jsonl(records: list[dict]) -> str:
    return "".join(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n" for r in sorted(records, key=lambda r: r["id"]))


def seed_queries(note: str, repos: list[Path]) -> list[str]:
    """Vault queries for the prep step: the note's title and headings, plus repo names."""
    qs: list[str] = []
    for ln in note.splitlines():
        t = ln.strip()
        if t.startswith("#"):
            qs.append(t.lstrip("#").strip())
    first = next((ln.strip().lstrip("#").strip() for ln in note.splitlines() if ln.strip()), "")
    qs = [first] + qs + [r.name for r in repos]
    out: list[str] = []
    for q in qs:
        q = re.sub(r"\s+", " ", q).strip()
        if len(q) >= 3 and q.casefold() not in {x.casefold() for x in out}:
            out.append(q[:120])
    return out[:8]


def _snippet_text(t: str) -> str:
    t = " ".join(t.split())
    if len(t) <= SNIPPET_CHARS:
        return t
    cut = t[:SNIPPET_CHARS].rsplit(" ", 1)[0]
    return cut + " ..."


def _make_snippets(vault: Vault, bank: list[dict], glossary: list[dict], warnings: list[str]) -> list[dict]:
    """Top-k vault snippets per bank entry (k=2) and glossary term (k=1). Serial-by-key, deterministic order."""
    jobs: list[tuple[str, str | None, int]] = []  # (query, bank_id|None, limit)
    for b in bank:
        jobs.append((b["question"], b["id"], 2))
    for g in glossary:
        jobs.append((f"{g['term']} {g['line']}"[:160], None, 1))

    def run(job: tuple[str, str | None, int]) -> list[VaultRecord] | Exception:
        try:
            return vault.search(job[0], limit=job[2], budget_chars=1500)
        except Exception as e:  # noqa: BLE001
            return e

    with ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(run, jobs))  # map keeps job order -> deterministic
    snippets: dict[tuple[str, str], dict] = {}
    errors = 0
    for (query, bank_id, _), res in zip(jobs, results):
        if isinstance(res, Exception):
            errors += 1
            continue
        for rec in res:
            text = _snippet_text(rec.text)
            key = (rec.source, text)
            s = snippets.get(key)
            if s is None:
                s = {"id": f"s{len(snippets) + 1:03d}", "ref": f"vault:{rec.source}", "text": text, "bank_ids": []}
                snippets[key] = s
            if bank_id and bank_id not in s["bank_ids"]:
                s["bank_ids"].append(bank_id)
    if errors:
        warnings.append(f"vault snippet lookup failed for {errors} of {len(jobs)} queries")
    return list(snippets.values())


def _collect(prep_note: Path, repos: list[Path], vault: Vault | None, warnings: list[str]):
    note = prep_note.read_text(encoding="utf-8")
    if len(note) > MAX_PREP_NOTE_CHARS:
        raise PrepError(f"prep note is {len(note)} chars; the limit is {MAX_PREP_NOTE_CHARS}. Split it instead of truncating.")
    commits: dict[str, Commit] = {}
    for r in repos:
        try:
            for c in read_commits(r):
                commits[c.hash] = c
        except GitError as e:
            warnings.append(f"git digest unavailable: {e}")
    records: dict[str, VaultRecord] = {}
    if vault is not None:
        failures = 0
        queries = seed_queries(note, repos)
        for q in queries:
            try:
                for rec in vault.search(q, limit=3, budget_chars=2500):
                    if len(records) < MAX_VAULT_SEED_RECORDS:
                        records.setdefault(rec.record_id, rec)
            except VaultError as e:
                failures += 1
                last = str(e)
        if failures:
            warnings.append(f"vault retrieval failed for {failures} of {len(queries)} queries (last: {last})")
    handles = {f"V{i}": rec for i, rec in enumerate(records.values(), start=1)}
    return note, commits, handles


async def build_async(
    prep_note: Path, repos: list[Path], langs: list[str], out: Path, max_questions: int, *,
    model: PrepModel, vault: Vault | None, budget_usd: float = 1.0, now: datetime | None = None,
    session_id: str | None = None, voice_path: Path | None = None,
) -> Path:
    prep_note = Path(prep_note).expanduser().resolve()
    repos = [Path(r).expanduser().resolve() for r in repos]
    langs = [c.strip().lower() for c in langs if c.strip()]
    if not langs:
        raise PrepError("at least one language is required")
    warnings: list[str] = []
    now = now or datetime.now(timezone.utc)
    note, commits, handles = _collect(prep_note, repos, vault, warnings)
    book = SourceBook(prep_lines=note.splitlines(), vault=handles, commits=commits)

    user = render_user(book.prep_lines, handles, commits, langs, max_questions)
    in_tokens = await model.count_request_tokens(SYSTEM, user)
    pin, pout = PRICES[model.model]
    max_tokens = min(MAX_OUTPUT_TOKENS, int((budget_usd - in_tokens * pin / 1e6) / (pout / 1e6)))
    if max_tokens < 4000:
        raise PrepError(f"budget ${budget_usd:.2f} leaves only {max_tokens} output tokens; raise it or shrink the input")
    res = await model.generate(SYSTEM, user, max_tokens)
    if res.stop_reason == "max_tokens":
        warnings.append(f"model output hit the {max_tokens}-token limit; the last block was cut off and dropped")

    parsed = parse_output(res.text)
    g = ground(parsed, book, langs, max_questions)
    if vault is not None:
        snippets = await asyncio.to_thread(_make_snippets, vault, g.bank, g.glossary, warnings)
    else:
        snippets = []
    conflicts = apply_conflicts(book, g, snippets)  # marks facts, bank entries and snippets; must run before the pack
    voice = load_voice(voice_path)  # None (no path, no file) leaves the pack exactly as before
    pack, pack_tokens, trimmed = await fit_pack(g.facts, g.glossary, g.bank, snippets, model.count_tokens, TOKEN_CAP, voice)

    sid = session_id or f"{now:%Y%m%d-%H%M%S}-" + hashlib.sha256(
        (note + "|" + ",".join(langs) + "|" + ",".join(r.name for r in repos)).encode()
    ).hexdigest()[:8]
    out = Path(out).expanduser()
    out.mkdir(parents=True, exist_ok=True)
    final = out / sid
    n = 2
    while final.exists():
        final = out / f"{sid}-{n}"
        n += 1
    sid = final.name

    spend = spend_usd(model.model, res.usage)
    stats = {
        **g.stats,
        "bank_entries": len(g.bank), "facts": len(g.facts), "conflicts": len(conflicts), "glossary_terms": len(g.glossary), "snippets": len(snippets),
        "pack_tokens": pack_tokens, "pack_cap": TOKEN_CAP, "pack_trimmed": trimmed,
        "vault_records_given": len(handles), "commits_given": len(commits), "stop_reason": res.stop_reason,
        "prep_note_sha256": hashlib.sha256(note.encode()).hexdigest(),
        **({"voice_sha256": sha256_text(voice)} if voice is not None else {}),
    }
    meta = {
        "session_id": sid, "created_at": now.isoformat(timespec="seconds"), "prep_note": str(prep_note),
        "repos": [str(r) for r in repos], "languages": langs, "prep_model": model.model,
        "prep_usage": res.usage.as_dict(), "prep_spend_usd": round(spend, 6),
        "dropped_unsourced_points": g.stats.get("points_dropped_unsourced", 0),
        "warnings": warnings, "stats": stats,
    }

    tmp = out / f".{sid}.tmp"
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir()
    try:
        (tmp / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        (tmp / "bank.jsonl").write_text(_jsonl(g.bank), encoding="utf-8")
        (tmp / "facts.jsonl").write_text(_jsonl(g.facts), encoding="utf-8")
        (tmp / "glossary.jsonl").write_text(_jsonl(g.glossary), encoding="utf-8")
        (tmp / "snippets.jsonl").write_text(_jsonl(snippets), encoding="utf-8")
        (tmp / "pack.md").write_text(pack, encoding="utf-8")
        (tmp / "review.md").write_text(
            render_review(meta, g.bank, g.facts, g.glossary, snippets, g.dropped, warnings, conflicts),
            encoding="utf-8")
        tmp.rename(final)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    return final


def build(
    prep_note: Path, repos: list[Path], langs: list[str], out: Path, max_questions: int = 80, *,
    model: PrepModel | None = None, vault: Vault | None = None, budget_usd: float = 1.0,
    now: datetime | None = None, session_id: str | None = None, voice_path: Path | None = None,
) -> Path:
    """Build a session folder and return its path. Without `model`, a real Sonnet client is created from the
    Keychain key (service `verse-anthropic`). `voice_path`: a voice profile (prep/voice.py) whose section is appended
    to the pack when the file exists; None builds the pack without one."""
    from .keychain import read_api_key
    from .model import AnthropicPrepModel

    async def _run() -> Path:
        own = None
        m = model
        if m is None:
            own = m = AnthropicPrepModel(read_api_key(), PREP_MODEL, progress=True)
        try:
            return await build_async(prep_note, repos, langs, out, max_questions, model=m, vault=vault,
                                     budget_usd=budget_usd, now=now, session_id=session_id, voice_path=voice_path)
        finally:
            if own is not None:
                await own.aclose()

    return asyncio.run(_run())
