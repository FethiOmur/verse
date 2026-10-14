import asyncio
import json
import os
from datetime import datetime, timezone
from pathlib import Path

import pytest

from verse_brain.prep import build
from verse_brain.prep.model import ModelOutput, Usage
from verse_brain.prep.pack import TOKEN_CAP, fit_pack
from verse_brain.prep.vault import VaultRecord
from test_prep_git import make_repo

FIX = Path(__file__).parent / "fixtures" / "prep"
NOTE = FIX / "prep_note.md"
NOW = datetime(2026, 10, 14, 9, 0, 0, tzinfo=timezone.utc)
CONTRACT_FILES = {"meta.json", "bank.jsonl", "facts.jsonl", "glossary.jsonl", "snippets.jsonl", "pack.md", "review.md"}


class FakeModel:
    model = "claude-sonnet-5-5"

    def __init__(self, output: str | None = None, key: str | None = None):
        self.output = output if output is not None else (FIX / "model_output.txt").read_text(encoding="utf-8")
        self._key = key  # stands in for the SDK client's copy of the API key
        self.calls: list[tuple[str, str, int]] = []

    async def generate(self, system, user, max_tokens):
        self.calls.append((system, user, max_tokens))
        return ModelOutput(self.output, Usage(input=2500, output=3000, cache_read=0, cache_write=0), "end_turn")

    async def count_tokens(self, text):
        return len(text) // 4

    async def count_request_tokens(self, system, user):
        return (len(system) + len(user)) // 4


class FakeVault:
    def __init__(self):
        self.queries: list[str] = []

    def search(self, query, limit=3, budget_chars=2500):
        self.queries.append(query)
        # deterministic by query: same query -> same records
        if "Lantern" in query or "LLM" in query:
            return [VaultRecord("md-1", "300-Projects/Lantern/Retro.md", "Lantern retro: the operator queue was the best decision we made.")]
        return [VaultRecord("md-2", "500-Knowledge/Evaluation.md", "Freeze an evaluation set and rerun it on every prompt change.")]


def _build(tmp_path, out_name="out", **kw):
    model = kw.pop("model", None) or FakeModel()
    vault = kw.pop("vault", FakeVault())
    return build(NOTE, kw.pop("repos", []), ["en", "it"], tmp_path / out_name, max_questions=80, model=model, vault=vault,
                 now=NOW, **kw), model, vault


def test_session_folder_contract(tmp_path):
    session, model, vault = _build(tmp_path, repos=[make_repo(tmp_path)])
    assert {p.name for p in session.iterdir()} == CONTRACT_FILES
    meta = json.loads((session / "meta.json").read_text(encoding="utf-8"))
    assert meta["session_id"] == session.name and meta["languages"] == ["en", "it"]
    assert meta["prep_model"] == "claude-sonnet-5-5"
    assert meta["prep_usage"] == {"input": 2500, "output": 3000, "cache_read": 0, "cache_write": 0}
    assert meta["dropped_unsourced_points"] == 2
    assert meta["stats"]["bank_entries"] == 3 and meta["prep_spend_usd"] == pytest.approx(0.035)
    for name in ("bank", "facts", "glossary", "snippets"):
        recs = [json.loads(ln) for ln in (session / f"{name}.jsonl").read_text(encoding="utf-8").splitlines()]
        assert [r["id"] for r in recs] == sorted(r["id"] for r in recs)
    snippets = [json.loads(ln) for ln in (session / "snippets.jsonl").read_text(encoding="utf-8").splitlines()]
    assert snippets and all(s["ref"].startswith("vault:") and s["bank_ids"] is not None for s in snippets)
    review = (session / "review.md").read_text(encoding="utf-8")
    assert "Tell me about a project where you used an LLM" in review and "prep:L14" in review
    assert "## Dropped" in review and "unsourced" in review
    # the model saw the commit digest and the note, with line numbers
    user = model.calls[0][1]
    assert "L14: - Lantern cut manual data entry" in user and "Add invoice schema" in user
    # vault retrieval ran only here, via the injected vault
    assert vault.queries


def test_pack_deterministic(tmp_path):
    a, _, _ = _build(tmp_path, "a")
    b, _, _ = _build(tmp_path, "b")
    assert (a / "pack.md").read_bytes() == (b / "pack.md").read_bytes()
    for name in ("bank.jsonl", "facts.jsonl", "glossary.jsonl", "snippets.jsonl"):
        assert (a / name).read_bytes() == (b / name).read_bytes()
    pack = (a / "pack.md").read_text(encoding="utf-8")
    assert pack.index("## FACTS") < pack.index("## GLOSSARY") < pack.index("## ANSWER BANK") < pack.index("## SNIPPETS")
    # no per-run values leak into the cache prefix
    assert a.name not in pack and "2026-10-14" not in pack
    # bank section is opener + points only: no deep text
    assert "SAY: Sure, the clearest example is Lantern" in pack and "Lantern was an LLM pipeline" not in pack


def test_second_build_gets_its_own_folder(tmp_path):
    a, _, _ = _build(tmp_path, "same")
    b, _, _ = _build(tmp_path, "same")
    assert a != b and a.exists() and b.exists()


def _mk(prefix, n, extra=""):
    return [{"id": f"{prefix}{i:03d}", **extra_fields(prefix, i, extra)} for i in range(1, n + 1)]


def extra_fields(prefix, i, extra):
    text = f"item {i} " + "word " * 30 + extra
    if prefix == "f":
        return {"kind": "number", "text": text, "value": str(i), "sources": [{"kind": "prep", "ref": f"prep:L{i}", "quote": "q"}]}
    if prefix == "g":
        return {"term": f"term{i}", "line": text, "sources": [{"kind": "prep", "ref": f"prep:L{i}", "quote": "q"}]}
    if prefix == "b":
        return {"lang": "en", "question": f"Question {i}?", "opener": "opener " + text, "points": [text, text, text],
                "paraphrases": {}, "deep": "", "sources": []}
    return {"ref": "vault:x.md", "text": text, "bank_ids": ["b001"] * (i % 3)}  # s: priority varies


def test_pack_cap():
    async def count(t):
        return len(t) // 4

    facts, gloss, bank, snips = _mk("f", 10), _mk("g", 10), _mk("b", 20), _mk("s", 60)
    full, full_tokens, _ = asyncio.run(fit_pack(facts, gloss, bank, snips, count, cap=10**9))
    assert full_tokens > 3000

    # cap that only forces snippet cuts: bank, glossary and facts all survive
    cap = int(full_tokens * 0.8)
    text, tokens, cut = asyncio.run(fit_pack(facts, gloss, bank, snips, count, cap=cap))
    assert tokens <= cap
    assert cut["snippets"] > 0 and cut["bank"] == cut["glossary"] == cut["facts"] == 0
    kept = {ln.split("]")[0][1:] for ln in text.splitlines() if ln.startswith("[s")}
    dropped = {s["id"] for s in snips} - kept
    # the lowest-priority snippets (fewest bank links) go first
    assert max(len(s["bank_ids"]) for s in snips if s["id"] in kept) >= max(
        len(s["bank_ids"]) for s in snips if s["id"] in dropped)
    assert min(len(s["bank_ids"]) for s in snips if s["id"] in dropped) == 0

    # tight cap: all snippets go, then bank entries from the tail; facts and glossary are last to be touched
    cap = int(full_tokens * 0.35)
    text, tokens, cut = asyncio.run(fit_pack(facts, gloss, bank, snips, count, cap=cap))
    assert tokens <= cap and cut["snippets"] == 60 and cut["bank"] > 0 and cut["facts"] == 0
    assert "[b001]" in text and f"[b{20:03d}]" not in text


def test_default_cap_is_12k_tokens():
    assert TOKEN_CAP == 12_000


def test_no_secrets(tmp_path, monkeypatch, capsys):
    key = "sk-ant-api03-SENTINEL-0123456789abcdef-NOT-A-REAL-KEY"
    monkeypatch.setenv("ANTHROPIC_API_KEY", key)
    session, _, _ = _build(tmp_path, model=FakeModel(key=key), repos=[make_repo(tmp_path)])
    for p in tmp_path.rglob("*"):
        if p.is_file() and ".git" not in p.parts:
            assert key.encode() not in p.read_bytes(), p
    out = capsys.readouterr()
    assert key not in out.out and key not in out.err

    # error path: an exception that carries the key is redacted before it is printed
    from verse_brain.prep import __main__ as cli

    def boom(*a, **k):
        raise RuntimeError(f"auth failed for {key}")

    monkeypatch.setattr(cli, "read_api_key", lambda: key)
    monkeypatch.setattr(cli, "build", boom)
    rc = cli.main(["--prep-note", str(NOTE), "--out", str(tmp_path / "x"), "--no-vault"])
    out = capsys.readouterr()
    assert rc == 1 and key not in out.out and key not in out.err and "[redacted-key]" in out.err


def test_failed_build_leaves_no_half_session(tmp_path):
    class Broken(FakeModel):
        async def generate(self, *a):
            raise RuntimeError("network down")

    with pytest.raises(RuntimeError):
        _build(tmp_path, model=Broken())
    out = tmp_path / "out"
    assert not out.exists() or list(out.iterdir()) == []


def test_missing_vault_still_builds_and_says_so(tmp_path):
    from verse_brain.prep.vault import VaultError

    class DeadVault:
        def search(self, *a, **k):
            raise VaultError("beyin.py exit 1")

    session, _, _ = _build(tmp_path, vault=DeadVault())
    meta = json.loads((session / "meta.json").read_text(encoding="utf-8"))
    assert any("vault" in w for w in meta["warnings"])
    assert (session / "snippets.jsonl").read_text(encoding="utf-8") == ""
    assert "## Warnings" in (session / "review.md").read_text(encoding="utf-8")
