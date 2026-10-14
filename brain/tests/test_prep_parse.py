import json
from pathlib import Path

from verse_brain.prep.ground import ground
from verse_brain.prep.parse import parse_output
from verse_brain.prep.sources import SourceBook, numbers_supported

FIX = Path(__file__).parent / "fixtures" / "prep"
LANGS = ["en", "it"]


def _book() -> SourceBook:
    return SourceBook(prep_lines=(FIX / "prep_note.md").read_text(encoding="utf-8").splitlines())


def _validate_bank_record(r: dict) -> None:
    assert set(r) == {"id", "lang", "question", "paraphrases", "opener", "points", "deep", "sources"}
    assert r["id"].startswith("b") and len(r["id"]) == 4
    assert r["lang"] in LANGS and r["question"].strip() and r["opener"].strip()
    assert 1 <= len(r["points"]) <= 3 and all(isinstance(p, str) and p.strip() for p in r["points"])
    assert isinstance(r["deep"], str)
    assert all(isinstance(v, list) and all(isinstance(x, str) for x in v) for v in r["paraphrases"].values())
    assert r["sources"], "an entry always carries at least one source"
    for s in r["sources"]:
        assert set(s) == {"kind", "ref", "quote"} and s["kind"] in ("prep", "vault", "commit")
        assert s["ref"].startswith(s["kind"] + ":") and s["quote"].strip()


def test_parse_bank():
    parsed = parse_output((FIX / "model_output.txt").read_text(encoding="utf-8"))
    assert len(parsed.facts) == 3 and len(parsed.terms) == 1
    assert len(parsed.bank) == 5  # the sixth block is cut off before @END
    assert parsed.incomplete_blocks == 1

    g = ground(parsed, _book(), LANGS, max_questions=80)

    # bank.jsonl records validate
    assert [b["id"] for b in g.bank] == ["b001", "b002", "b003"]
    for rec in g.bank:
        _validate_bank_record(rec)
        json.dumps(rec, ensure_ascii=False)

    first = g.bank[0]
    assert first["question"].startswith("Tell me about a project")
    assert len(first["points"]) == 3 and first["deep"].startswith("Lantern was an LLM pipeline")
    assert len(first["paraphrases"]["en"]) == 3 and len(first["paraphrases"]["it"]) == 3

    # entry 2 keeps only its two grounded points; entry "weakness" has none and is dropped
    second = g.bank[1]
    assert second["points"] == ["Totals were correct 96.4 percent of the time.",
                                "About 7 percent of invoices were routed to an operator."]

    # drop accounting
    assert g.stats["points_dropped_unsourced"] == 2
    assert g.stats["points_dropped_unsupported_quote"] == 1  # quote not in the note
    assert g.stats["points_dropped_unsupported_number"] == 1  # "99 percent" is not in its quote
    assert g.stats["entries_dropped_no_points"] == 1
    assert g.stats["entries_dropped_duplicate"] == 1
    assert g.stats["blocks_incomplete"] == 1
    assert g.stats["facts_dropped_value_not_in_quote"] == 1

    assert [f["id"] for f in g.facts] == ["f001", "f002"]
    assert g.facts[0]["value"] == "38000" and g.facts[1]["kind"] == "date"
    assert [t["term"] for t in g.glossary] == ["ETA drift"]
    reasons = {(d.what, d.reason) for d in g.dropped}
    assert ("point", "unsourced") in reasons and ("entry", "duplicate") in reasons


def test_source_ref_is_rewritten_to_the_real_line():
    parsed = parse_output(
        "@BANK\nlang: en\nquestion: q?\nopener: o\npoint: Totals were 96.4 percent.\n"
        'src: prep:L1 | "96.4 percent for totals"\n@END\n'
    )
    g = ground(parsed, _book(), LANGS, 10)
    assert g.bank[0]["sources"][0]["ref"] == "prep:L18"  # the model claimed L1


def test_vault_and_commit_sources_resolve_and_fail_closed():
    from verse_brain.prep.git_digest import Commit
    from verse_brain.prep.vault import VaultRecord

    book = _book()
    book.vault = {"V1": VaultRecord("md-1", "300-Projects/Lantern.md", "Lantern retro: we stopped at 96 percent recall.")}
    book.commits = {"abc1234": Commit("demo", "abc1234", "2026-10-12", "Add retry on low confidence", ("pipeline.py",))}
    ok_v = book.resolve("vault:V1", "stopped at 96 percent recall")
    ok_c = book.resolve("commit:abc1234", "Add retry on low confidence")
    # a quote copied from the commit line exactly as the prompt shows it (repo tag, file list in parentheses)
    assert book.resolve("commit:abc1234", "[demo] Add retry on low confidence (pipeline.py)")
    assert ok_v and ok_v.ref == "vault:300-Projects/Lantern.md"
    assert ok_c and ok_c.ref == "commit:demo@abc1234"
    assert book.resolve("vault:V2", "stopped at 96 percent recall") is None  # unknown handle
    assert book.resolve("vault:V1", "stopped at 99 percent recall") is None  # quote not in the record
    assert book.resolve("commit:abc1234", "short") is None  # quote too short to prove anything


def test_numbers_are_compared_by_value():
    assert numbers_supported("Budget EUR 42,000", ["a budget of 42K for the pilot"])
    assert numbers_supported("rate was 96,4 percent", ["96.4 percent for totals"])
    assert not numbers_supported("rate was 97 percent", ["96.4 percent for totals"])
    assert numbers_supported("3 steps", ["no numbers here"])  # single digits need no support
