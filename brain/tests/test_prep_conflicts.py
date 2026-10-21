"""F1: contradiction check in prep. Deterministic detection over prep note, vault records and commit digest."""

import json
from datetime import datetime, timezone
from pathlib import Path

from test_prep_pipeline import FakeModel
from verse_brain.prep import build
from verse_brain.prep.conflicts import conflict_phrase, find_conflicts
from verse_brain.prep.git_digest import Commit
from verse_brain.prep.sources import SourceBook, norm
from verse_brain.prep.vault import VaultRecord

FIX = Path(__file__).parent / "fixtures" / "prep"
NOW = datetime(2026, 10, 14, 9, 0, 0, tzinfo=timezone.utc)
STEERING = "300-Projects/Halden/Steering.md"


def book(prep: list[str], vault: list[str] | None = None, commits: list[tuple[str, str]] | None = None) -> SourceBook:
    recs = {f"V{i}": VaultRecord(f"md-{i}", f"300-Projects/Halden/Note{i}.md", t) for i, t in enumerate(vault or [], 1)}
    cs = {h: Commit("halden", h, "2026-10-12", subj, ("a.py",)) for h, subj in (commits or [])}
    return SourceBook(prep_lines=prep, vault=recs, commits=cs)


def refs(c) -> set[str]:
    return {e["source_ref"] for e in c.entries}


def values(c) -> set[str]:
    return {e["value"] for e in c.entries}


# ---------------------------------------------------------------------------------------------- detection


def test_number_conflict_money_records_both_refs():
    b = book(["- The pilot budget is EUR 42,000 for phase one."],
             ["Steering call. The pilot budget was raised to €45K for phase one."])
    found = find_conflicts(b)
    assert len(found) == 1
    c = found[0]
    assert c.kind == "number" and c.id == "c001" and "budget" in c.label
    assert values(c) == {"EUR 42,000", "EUR 45,000"}
    assert refs(c) == {"prep:L1", "vault:300-Projects/Halden/Note1.md"}
    for e in c.entries:  # every quote is real text from its own source
        assert set(e) == {"value", "source_ref", "quote"}
        doc = b.prep_text if e["source_ref"].startswith("prep:") else b.vault["V1"].text
        assert norm(e["quote"]) in norm(doc)
    # the quote shown for each side contains that side's figure as written
    by_ref = {e["source_ref"]: e["quote"] for e in c.entries}
    assert "EUR 42,000" in by_ref["prep:L1"] and "€45K" in by_ref["vault:300-Projects/Halden/Note1.md"]


def test_date_conflict_q1_vs_q2():
    b = book(["- The dispatcher pilot is planned for Q1 2027."],
             ["The LLM dispatcher pilot slips to Q2 2027 per the steering call."])
    found = find_conflicts(b)
    assert len(found) == 1 and found[0].kind == "date"
    assert values(found[0]) == {"2027-Q1", "2027-Q2"}
    assert refs(found[0]) == {"prep:L1", "vault:300-Projects/Halden/Note1.md"}


def test_same_value_in_different_formats_is_not_a_conflict():
    b = book(
        ["- Pilot budget: 42,000 EUR for phase one.", "- Notice is 30 days.", "- Share was 14 percent.",
         "- The call is on 22 October 2026."],
        ["The pilot budget is €42K.", "Pilot budget 42.000 euro.", "Budget for the pilot: $42,000 is wrong, ignore.",
         "The notice is 30-day long and the share was 14%.", "Share: %14. Call on 2026-10-22 and again 22/10/2026 or October 22, 2026."],
    )
    found = find_conflicts(b)
    # the $ line is a different currency, so it is not compared with the EUR figures
    assert found == [], [(c.label, c.entries) for c in found]


def test_within_prep_note_conflict():
    b = book(["# Prep", "- The pilot is planned for Q1 2027.", "- Reminder: pilot kickoff is now Q2 2027."])
    found = find_conflicts(b)
    assert len(found) == 1 and refs(found[0]) == {"prep:L2", "prep:L3"}


def test_same_sentence_enumeration_is_not_a_conflict():
    one = book(["- Accuracy was 96.4 percent for totals and 91 percent for line items."])
    assert find_conflicts(one) == []
    two = book(["- Lantern accuracy was 96.4 percent for totals.", "- Lantern accuracy was 91 percent for line items."])
    assert find_conflicts(two) == []  # same percent, different thing: the trailing 'for X' differs


def test_approximate_figures_tolerate_rounding_but_exact_ones_do_not():
    hedged = book(["- The low-confidence share was about 7 percent."], ["The low-confidence share is 7.2 percent."])
    assert find_conflicts(hedged) == []
    exact = book(["- The low-confidence share was 7 percent."], ["The low-confidence share is 7.2 percent."])
    assert len(find_conflicts(exact)) == 1


def test_gross_and_net_are_different_quantities():
    b = book(["- Salary expectation: EUR 70,000 gross per year."], ["Salary expectation: EUR 65,000 net per year."])
    assert find_conflicts(b) == []
    plain = book(["- Salary expectation: EUR 70,000 per year."], ["Salary expectation: EUR 80,000 per year."])
    assert len(find_conflicts(plain)) == 1


def test_range_and_point_agree_when_the_point_is_inside_the_range():
    inside = book(["- Salary expectation: EUR 70,000 to 80,000 per year."], ["Salary expectation: EUR 80,000 per year."])
    assert find_conflicts(inside) == []
    outside = book(["- Salary expectation: EUR 70,000 to 80,000 per year."], ["Salary expectation: EUR 95,000 per year."])
    assert len(find_conflicts(outside)) == 1


def test_commit_digest_vs_prep_note_and_commit_header_date_is_not_a_figure():
    b = book(["- The pilot budget is EUR 42,000.", "- Call on 12 October 2026 about the pilot."],
             commits=[("abc1234", "Raise pilot budget to EUR 45,000")])
    found = find_conflicts(b)
    assert len(found) == 1
    assert refs(found[0]) == {"prep:L1", "commit:halden@abc1234"}  # the commit's 2026-10-12 header date is metadata


def test_name_conflict_for_the_same_role():
    b = book(["- Panel: Ingrid Solberg (VP Engineering, hiring manager) and Tomas Weir (tech lead)."],
             ["Recruiter email: the hiring manager is Mark Olsen, and the tech lead is Tomas Weir."])
    found = find_conflicts(b)
    assert len(found) == 1
    c = found[0]
    assert c.kind == "name" and c.label == "hiring manager"
    assert values(c) == {"Ingrid Solberg", "Mark Olsen"}


def _vault(*pairs: tuple[str, str]) -> SourceBook:
    return SourceBook(prep_lines=[], vault={f"V{i}": VaultRecord(f"m{i}", src, txt) for i, (src, txt) in enumerate(pairs, 1)})


def test_snapshots_of_different_days_are_not_conflicts():
    """Live run, false conflicts 1: daily logs. The same figure moves between days (84% to 70%, then 82% to 71%)."""
    b = _vault(
        ("daily/2026-09-02.md", "Disk cleanup done, usage went from 84% to 70% and 155 paths await commit."),
        ("daily/2026-09-13.md", "Disk cleanup repeated, usage went from 82% to 71% and 12 paths await commit."),
    )
    assert find_conflicts(b) == []
    # the same two notes without a date in their path are not snapshots, so the difference is reported
    undated = _vault(("notes/a.md", "Disk cleanup done, usage was 70% afterwards."),
                     ("notes/b.md", "Disk cleanup repeated, usage was 71% afterwards."))
    assert len(find_conflicts(undated)) == 1


def test_title_dates_do_not_make_conflicts():
    """Live run, false conflicts 2: '# Weekly log: <date>' titles in flattened markdown, in notes with undated paths."""
    b = _vault(("notes/a.md", "# Weekly log: 2026-09-02 ## Sessions ### Session one ## Context Disk work."),
               ("notes/b.md", "# Weekly log: 2026-09-13 ## Sessions ### Session two ## Context More disk work."))
    assert find_conflicts(b) == []


def test_metadata_field_dates_do_not_make_conflicts():
    b = _vault(("notes/c.md", "Kickoff sheet **Date:** 2026-09-25 · **Status:** draft."),
               ("notes/d.md", "Kickoff sheet **Date:** 2026-09-26 · **Status:** final."))
    assert find_conflicts(b) == []


def test_dates_next_to_a_file_or_url_citation_do_not_make_conflicts():
    b = _vault(("notes/e.md", "Voice script rejected on 2026-09-25 (see Style.md)."),
               ("notes/f.md", "Voice script rejected on 2026-09-26 (see Style.md)."),
               ("notes/g.md", "Source: https://example.com/about.json, fetched 2026-09-25."),
               ("notes/h.md", "Source: https://example.com/about.json, fetched 2026-09-26."))
    assert find_conflicts(b) == []
    plain = _vault(("notes/e.md", "Voice script rejected on 2026-09-25."), ("notes/f.md", "Voice script rejected on 2026-09-26."))
    assert len(find_conflicts(plain)) == 1  # without the citation the same sentences are a real disagreement


def test_one_shared_word_in_a_long_context_is_not_a_link():
    """Live run, false conflicts 3: 'duration 100.56 s' (a probe) against '8 s or longer?' (an open question)."""
    b = _vault(("notes/probe.md", "Duration 100.56 s (ffprobe)."),
               ("notes/open.md", "Open: question 12 on duration (8 s or longer?) and the quota."))
    assert find_conflicts(b) == []


def test_dated_notes_are_snapshots_but_still_compared_with_the_prep_note():
    prep = ["- The pilot budget is EUR 42,000."]
    vault = [VaultRecord("m1", "daily/2026-10-01.md", "Pilot budget confirmed at EUR 45,000."),
             VaultRecord("m2", "daily/2026-10-05.md", "Pilot budget confirmed at EUR 48,000.")]
    b = SourceBook(prep_lines=prep, vault={"V1": vault[0], "V2": vault[1]})
    found = find_conflicts(b)
    assert len(found) == 1  # one cluster: the two logs each disagree with the note, not with each other
    assert {e["source_ref"] for e in found[0].entries} == {"prep:L1", "vault:daily/2026-10-01.md", "vault:daily/2026-10-05.md"}
    logs_only = SourceBook(prep_lines=[], vault={"V1": vault[0], "V2": vault[1]})
    assert find_conflicts(logs_only) == []


def test_a_date_in_the_prep_note_title_is_still_a_claim():
    b = book(["# Prep for the call on 22 October 2026", "- The call is on 23 October 2026."])
    assert len(find_conflicts(b)) == 1


def test_realistic_notes_have_no_false_conflicts():
    for name in ("prep_note.md", "prep_note_conflicts.md"):
        lines = (FIX / name).read_text(encoding="utf-8").splitlines()
        assert find_conflicts(SourceBook(prep_lines=lines)) == [], name


# ---------------------------------------------------------------------------------------------- false positives (live run: 16 of 16)
# All fixtures are fictional ("Halden"); each mirrors the shape of a pattern seen on a real session, not its text.


def _no_conflict(b):
    found = find_conflicts(b)
    assert found == [], [(c.label, c.entries) for c in found]


def test_total_and_its_breakdown_are_different_quantities():
    _no_conflict(book([
        "- Spend on the Halden build: about $13 in all: about $8 to 16 Oct, $1.15 of load tests on 20 Oct and about $3.90 of staging runs.",
        "- About $13 hosting spend in total, gross = net.",
        "- Spend for the staging runs: about $3.90.",
        "- Spend for the load tests: $1.152.",
        "| about $13 (gross = net) | Total hosting spend: about $8 to 16 Oct + $1.15 of load tests + about $3.90 of staging runs |",
    ]))


def test_range_and_a_value_inside_it_agree_and_a_value_outside_needs_its_own_scope():
    _no_conflict(book(["- A first report costs $0.06-0.12 and takes 22-43 s."],
                      ["A first report costs about $0.07 and takes 25 s."]))
    # the value outside the range is a different measurement: it says "after the fixes"
    _no_conflict(book(["- A first report costs $0.06-0.12."], ["After the 16 Oct fixes a first report costs $0.16."]))


def test_scoped_measurements_are_not_contradictions():
    _no_conflict(book([
        "- 16 Oct median report cost $0.070 (n=10).",
        "- On 20 Oct, n=9 reports: median cost $0.045.",
        "- After the fixes the median report cost is $0.16.",
        "| $0.033 median, $0.063 p95 | Intake, 16 Oct | n=11 |",
        "| $0.044 median, $0.071 p95 | Export, 20 Oct | n=14 |",
    ]))
    # the same two lists seen from both sides are the same list, not a contradiction
    _no_conflict(book(["- After the 16 Oct fixes reports cost $0.10-0.12 (n=2) and $0.16 with a repair."],
                      ["| $0.10-0.12; $0.16 | Report after the 16 Oct fixes; with a repair | n=2 |"]))


def test_before_after_statements_are_not_claims():
    _no_conflict(book(["- Your cost per report went from $0.07 to $0.12.", "- Latency moved 8 s -> 5 s."],
                      ["Cost per report is $0.10.", "Latency is 6 s."]))
    _no_conflict(book(["- Free shipping now starts at EUR 150 instead of EUR 50."], ["Free shipping on orders over EUR 80."]))


def test_unit_parsing_junk_does_not_collide_unrelated_numbers():
    _no_conflict(book([
        "- The first section waits at most 5 s for the lookup.",
        "- Lookup latency was 0.8-1.6 s in all 12 live turns of runs 1-2.",
        "- First report 22-43 s (n=9 live turns, 20 Oct).",
        "- Interval check: 0/36 one-offs learned (95% CI 0-9.6%) and 35/36 lasting rules (86-99.5%).",
        "- The Halden spike used 11 sites and 11 export credits.",
        "- Cost for these tests is $0.0056 and $0.007 for the other.",
        "- Widths: the preview is 600 px and 375 px.",
        "| 12 KB; 100 KB; 12 sections; 600 px; 14 px | Section size; page size; sections; width; min text | same |",
    ], ["Brand spike: 11 sites and 11 export credits.", "Spend at list price (gross = net): about 45 export credits.",
        "Live turns: 18 live turns of runs 1-3.", "Runs: 6 live turns, n=6."]))


def test_decision_log_dates_are_labels_not_claims():
    _no_conflict(book(["| DECISIONS 2026-10-16 | pilot scope |", "| DECISIONS 2026-10-20 | pilot scope |"]))


def test_still_flags_unscoped_test_counts_that_differ():
    b = book(["- Tests: 2,399 + 72 in the Halden suite."], ["Tests: 2,622 + 72, all green."])
    found = find_conflicts(b)
    assert len(found) == 1 and found[0].kind == "number"
    assert values(found[0]) == {"2,399 tests", "2,622 tests"}
    both = book(["- The suite has 2,399 unit tests and 72 table tests."], ["There are 2,622 unit tests and 72 table tests."])
    assert [values(c) for c in find_conflicts(both)] == [{"2,399 unit tests", "2,622 unit tests"}]


def test_still_flags_the_same_total_cost_stated_differently():
    b = book(["- Halden build spend: about $8 to 16 Oct and $1.15 on 20 Oct, about $9.20 in all."],
             ["Halden build spend is $12 in all, gross = net."])
    found = find_conflicts(b)
    assert len(found) == 1, [(c.label, c.entries) for c in found]
    assert values(found[0]) == {"USD 9.2", "USD 12"} and "spend" in found[0].label
    plain = book(["- Total hosting cost is $400 in total."], ["Hosting cost came to $450 in total."])
    assert len(find_conflicts(plain)) == 1


def test_detection_is_deterministic_and_order_independent_for_ids():
    kw = dict(prep=["- The pilot budget is EUR 42,000.", "- The pilot is planned for Q1 2027."],
              vault=["Pilot budget now EUR 45,000. The pilot starts in Q2 2027."])
    a, b = find_conflicts(book(**kw)), find_conflicts(book(**kw))
    assert [(c.id, c.kind, c.entries) for c in a] == [(c.id, c.kind, c.entries) for c in b]
    assert [c.id for c in a] == ["c001", "c002"] and [c.kind for c in a] == ["number", "date"]


def test_conflict_phrase_groups_refs_per_value():
    ents = [{"value": "EUR 42,000", "source_ref": "prep:L7", "quote": "x"},
            {"value": "EUR 42,000", "source_ref": "commit:r@abc", "quote": "y"},
            {"value": "EUR 45,000", "source_ref": "vault:a.md", "quote": "z"}]
    assert conflict_phrase(ents) == "conflicting in sources: EUR 42,000 (prep:L7, commit:r@abc) vs EUR 45,000 (vault:a.md)"


# ---------------------------------------------------------------------------------------------- pipeline


class ConflictVault:
    """Returns the same two records for any query; Steering.md disagrees with the prep note."""

    def search(self, query, limit=3, budget_chars=2500):
        return [
            VaultRecord("md-1", STEERING, "Steering call notes. The dispatcher pilot budget was raised to €45K for phase one. "
                                          "The pilot now starts in Q2 2027 because the traffic feed contract is late."),
            VaultRecord("md-2", "500-Knowledge/Evaluation.md", "Freeze an evaluation set and rerun it on every prompt change."),
        ]


def _build(tmp_path, name="out"):
    model = FakeModel((FIX / "model_output_conflicts.txt").read_text(encoding="utf-8"))
    return build(FIX / "prep_note_conflicts.md", [], ["en", "it"], tmp_path / name, max_questions=80, model=model,
                 vault=ConflictVault(), now=NOW)


def _jsonl(session, name):
    return [json.loads(ln) for ln in (session / f"{name}.jsonl").read_text(encoding="utf-8").splitlines()]


def test_conflicts_land_in_facts_jsonl(tmp_path):
    s = _build(tmp_path)
    facts = {f["id"]: f for f in _jsonl(s, "facts")}
    assert len(facts) == 3  # model facts only: both conflicts are covered by a model fact, so nothing synthetic is added
    budget, when, ok = facts["f001"], facts["f002"], facts["f003"]
    assert budget["status"] == "conflict" and when["status"] == "conflict"
    assert {(e["value"], e["source_ref"]) for e in budget["conflict"]} == {
        ("EUR 42,000", "prep:L7"), ("EUR 45,000", f"vault:{STEERING}")}
    assert all(e["quote"].strip() for e in budget["conflict"])
    assert {e["value"] for e in when["conflict"]} == {"2027-Q1", "2027-Q2"}
    assert "status" not in ok and "conflict" not in ok  # the courier fact is untouched


def test_conflict_without_a_model_fact_gets_a_detected_fact(tmp_path):
    only_bank = "\n".join(b for b in (FIX / "model_output_conflicts.txt").read_text(encoding="utf-8").split("\n\n")
                          if not b.startswith("@FACT")) + "\n"
    s = build(FIX / "prep_note_conflicts.md", [], ["en"], tmp_path / "o", model=FakeModel(only_bank),
              vault=ConflictVault(), now=NOW)
    facts = _jsonl(s, "facts")
    assert [f["status"] for f in facts] == ["conflict", "conflict"] and [f["kind"] for f in facts] == ["number", "date"]
    assert all(len(f["conflict"]) == 2 and len(f["sources"]) == 2 for f in facts)
    pack = (s / "pack.md").read_text(encoding="utf-8")
    assert "conflicting in sources: EUR 42,000 (prep:L7) vs EUR 45,000 (vault:" in pack


def test_review_md_leads_with_the_conflict_section(tmp_path):
    review = (_build(tmp_path) / "review.md").read_text(encoding="utf-8")
    assert "## ⚠ Conflicts to resolve" in review
    assert review.index("## ⚠ Conflicts to resolve") < review.index("## Answer bank") < review.index("## Fact sheet")
    section = review.split("## ⚠ Conflicts to resolve")[1].split("\n## ")[0]
    assert "The dispatcher pilot budget is EUR 42,000 for phase one" in section  # both quotes
    assert "The dispatcher pilot budget was raised to €45K for phase one" in section
    assert "prep:L7" in section and f"vault:{STEERING}" in section
    assert "Q1 2027" in section and "Q2 2027" in section
    assert "f001" in section and "b001" in section


def test_bank_points_using_a_conflicted_value_are_flagged(tmp_path):
    s = _build(tmp_path)
    bank = {b["id"]: b for b in _jsonl(s, "bank")}
    b1, b2 = bank["b001"], bank["b002"]
    assert b1["conflict"] is True
    flagged = {p["point"]: p["facts"] for p in b1["conflict_points"]}
    assert flagged == {0: ["f001"], 1: ["f002"], "deep": ["f001", "f002"]}  # point 2 (10 weeks) is clean
    assert "conflict" not in b2 and "conflict_points" not in b2  # the courier entry is not touched
    review = (s / "review.md").read_text(encoding="utf-8")
    entry = review.split("### b001")[1].split("### b002")[0]
    assert "⚠" in entry.split("\n")[0]
    assert "- ⚠ The pilot budget is EUR 42,000 for phase one." in entry
    assert "- ⚠ The pilot is planned for Q1 2027." in entry
    assert "- The courier pilot ran for 10 weeks." in entry  # unflagged line keeps its plain form
    assert "### b002" in review and "⚠" not in review.split("### b002")[1].split("\n## ")[0].split("- Sources")[0]


def test_pack_never_states_a_conflicted_value_as_fact(tmp_path):
    s = _build(tmp_path)
    pack = (s / "pack.md").read_text(encoding="utf-8")
    facts_section = pack.split("## FACTS")[1].split("## GLOSSARY")[0]
    f1 = next(ln for ln in facts_section.splitlines() if ln.startswith("[f001]"))
    assert f1 == (f"[f001] number | dispatcher pilot budget | conflicting in sources: EUR 42,000 (prep:L7) vs "
                  f"EUR 45,000 (vault:{STEERING})")
    assert "| 42000 |" not in f1 and "The dispatcher pilot budget is EUR 42,000" not in f1
    f2 = next(ln for ln in facts_section.splitlines() if ln.startswith("[f002]"))
    assert "conflicting in sources: 2027-Q1 (prep:L8) vs 2027-Q2 (vault:" in f2
    f3 = next(ln for ln in facts_section.splitlines() if ln.startswith("[f003]"))
    assert f3.startswith("[f003] number | The courier pilot ran for 10 weeks. | 10 | prep:L10")  # clean fact, old format
    bank_section = pack.split("## ANSWER BANK")[1].split("## SNIPPETS")[0]
    lines = bank_section.splitlines()
    budget_pt = next(ln for ln in lines if ln.startswith("- The pilot budget is EUR 42,000"))
    assert "conflicting in sources: EUR 42,000 (prep:L7) vs EUR 45,000 (vault:" in budget_pt
    when_pt = next(ln for ln in lines if ln.startswith("- The pilot is planned for Q1 2027"))
    assert "conflicting in sources: 2027-Q1 (prep:L8) vs 2027-Q2 (vault:" in when_pt
    assert "- The courier pilot ran for 10 weeks." in lines  # clean point is verbatim
    snippets_section = pack.split("## SNIPPETS")[1]
    steering = next(ln for ln in snippets_section.splitlines() if STEERING in ln)
    assert "conflicting figures" in steering
    assert "conflicting" not in next(ln for ln in snippets_section.splitlines() if "Evaluation.md" in ln)


def test_pack_stays_byte_deterministic_with_conflicts(tmp_path):
    a, b = _build(tmp_path, "a"), _build(tmp_path, "b")
    for name in ("pack.md", "bank.jsonl", "facts.jsonl", "glossary.jsonl", "snippets.jsonl"):
        assert (a / name).read_bytes() == (b / name).read_bytes(), name
    assert "conflicting in sources" in (a / "pack.md").read_text(encoding="utf-8")
    meta = json.loads((a / "meta.json").read_text(encoding="utf-8"))
    assert meta["stats"]["conflicts"] == 2 and meta["stats"]["conflict_bank_entries"] == 1
    assert any("conflict" in w for w in meta["warnings"]) is False  # conflicts are not warnings, they have their own section


def test_clean_build_has_no_conflict_keys_and_says_so(tmp_path):
    from test_prep_pipeline import FakeVault, NOTE

    s = build(NOTE, [], ["en", "it"], tmp_path / "clean", model=FakeModel(), vault=FakeVault(), now=NOW)
    for rec in _jsonl(s, "facts") + _jsonl(s, "bank") + _jsonl(s, "snippets"):
        assert not ({"status", "conflict", "conflict_points"} & set(rec))
    assert "conflicting" not in (s / "pack.md").read_text(encoding="utf-8")
    review = (s / "review.md").read_text(encoding="utf-8")
    assert "## ⚠ Conflicts to resolve" not in review and "No conflicting figures" in review
    assert json.loads((s / "meta.json").read_text(encoding="utf-8"))["stats"]["conflicts"] == 0
