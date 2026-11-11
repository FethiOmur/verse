"""Review 2026-11-11 H7, M1, M2: month spelling, ellipsis quotes and the bank opener."""

import asyncio

import pytest

from verse_brain.prep.conflicts import _month, apply_conflicts, find_conflicts
from verse_brain.prep.ground import ground
from verse_brain.prep.parse import parse_output
from verse_brain.prep.sources import SourceBook, numbers_supported

LANGS = ["en"]


# ---------------------------------------------------------------------------------------------- H7


@pytest.mark.parametrize("name,num", [
    ("kasim", 11), ("KASIM", 11), ("Kasım", 11), ("KASIM", 11), ("Aralik", 12), ("MAYIS", 5), ("NİSAN", 4),
    ("nisan", 4), ("Subat", 2), ("agustos", 8), ("eylul", 9), ("January", 1), ("SEPT", 9),
])
def test_month_lookup_folds_turkish_spellings(name, num):
    assert _month(name) == num


def test_month_lookup_unknown_is_none_not_an_error():
    assert _month("foobar") is None


@pytest.mark.parametrize("line", [
    "The launch is planned for kasim 2026 in Milan.",
    "Budget review on 3 Aralik 2026 was moved.",
    "Target MAYIS 2027 for the pilot.",
    "Deadline is NİSAN 2027 for the pilot.",
    "Meeting on Kasim 14 2026 about the pilot.",
])
def test_conflict_scan_survives_any_turkish_month_spelling(line):
    b = SourceBook(prep_lines=[line, "- The pilot budget is EUR 42,000 for phase one."])
    find_conflicts(b)  # must not raise (KeyError before the fix)


def test_apply_conflicts_with_ascii_month_does_not_raise():
    from verse_brain.prep.ground import Grounded

    b = SourceBook(prep_lines=["Review on 3 Aralik 2026.", "Review on 4 Aralik 2026."])
    apply_conflicts(b, Grounded(), [])


# ---------------------------------------------------------------------------------------------- M1

NOTE = ["# Note", "Revenue grew strongly this year thanks to the new plan.", "Churn fell to 3 percent."]


def test_short_fragment_after_ellipsis_must_be_found():
    b = SourceBook(prep_lines=NOTE)
    assert b.resolve("prep:L2", "Revenue grew strongly ... 40%") is None


def test_number_in_fragment_cannot_support_a_claim_when_fragment_is_missing():
    b = SourceBook(prep_lines=NOTE)
    v = b.resolve("prep:L2", "Revenue grew strongly ... 40%")
    assert v is None  # nothing verified, so numbers_supported has nothing to read
    assert not numbers_supported("Revenue grew 40% this year", [])


def test_ellipsis_quote_with_every_piece_present_in_order_verifies():
    b = SourceBook(prep_lines=NOTE)
    v = b.resolve("prep:L1", "Revenue grew strongly ... the new plan.")
    assert v is not None and v.ref == "prep:L2"


def test_ellipsis_pieces_out_of_order_are_rejected():
    b = SourceBook(prep_lines=NOTE)
    assert b.resolve("prep:L2", "the new plan ... Revenue grew strongly") is None


def test_short_piece_of_one_or_two_chars_is_checked_too():
    b = SourceBook(prep_lines=NOTE)
    assert b.resolve("prep:L2", "Revenue grew strongly ... zq") is None


def test_ground_drops_point_whose_number_only_lives_in_an_unverified_fragment():
    out = ("@BANK\nlang: en\nquestion: How did revenue do?\nopener: It went well.\n"
           "point: Revenue grew 40% this year.\n"
           'src: prep:L2 | "Revenue grew strongly ... 40%"\n@END\n')
    g = ground(parse_output(out), SourceBook(prep_lines=NOTE), LANGS, 10)
    assert g.bank == []


def test_vault_ellipsis_quote_checks_short_piece():
    from verse_brain.prep.vault import VaultRecord

    b = SourceBook(prep_lines=NOTE, vault={"V1": VaultRecord("m", "a.md", "Revenue grew strongly this year.")})
    assert b.resolve("V1", "Revenue grew strongly ... 40%") is None
    assert b.resolve("V1", "Revenue grew strongly ... this year.") is not None


def test_number_check_reads_the_document_span_not_the_models_string():
    b = SourceBook(prep_lines=["Churn fell to 3 percent and revenue to 12 million."])
    v = b.resolve("prep:L1", "Churn fell to 3 percent ... revenue to 12 million.")
    assert v is not None
    assert numbers_supported("Revenue is 12 million", [v.span or v.quote])


# ---------------------------------------------------------------------------------------------- M2


def _bank(opener: str, question: str = "How did revenue do?") -> str:
    return (f"@BANK\nlang: en\nquestion: {question}\nopener: {opener}\n"
            "point: Churn fell to 3 percent.\n"
            'src: prep:L3 | "Churn fell to 3 percent."\n@END\n')


def test_opener_with_invented_number_is_stripped():
    g = ground(parse_output(_bank("Revenue grew 40% last year. Happy to go into it.")), SourceBook(prep_lines=NOTE), LANGS, 10)
    assert len(g.bank) == 1
    assert "40" not in g.bank[0]["opener"]
    assert g.bank[0]["opener"] == "Happy to go into it."
    assert any(d.what == "opener" for d in g.dropped)


def test_opener_with_only_unsupported_number_drops_the_entry():
    g = ground(parse_output(_bank("Revenue grew 40% last year.")), SourceBook(prep_lines=NOTE), LANGS, 10)
    assert g.bank == []
    assert g.stats.get("entries_dropped_opener") == 1


def test_opener_with_invented_year_is_stripped():
    g = ground(parse_output(_bank("It started in March 2019. Let me explain.")), SourceBook(prep_lines=NOTE), LANGS, 10)
    assert g.bank[0]["opener"] == "Let me explain."


def test_opener_number_present_in_question_is_kept():
    g = ground(parse_output(_bank("In 2024 it went well.", "How did 2024 go?")), SourceBook(prep_lines=NOTE), LANGS, 10)
    assert g.bank[0]["opener"] == "In 2024 it went well."


def test_opener_without_numbers_is_untouched():
    g = ground(parse_output(_bank("It went well.")), SourceBook(prep_lines=NOTE), LANGS, 10)
    assert g.bank[0]["opener"] == "It went well."


def test_opener_with_month_absent_from_question_is_stripped():
    g = ground(parse_output(_bank("I joined in March. Let me explain.")), SourceBook(prep_lines=NOTE), LANGS, 10)
    assert g.bank[0]["opener"] == "Let me explain."
    assert g.stats.get("opener_sentences_dropped_unsupported_month") == 1


def test_opener_with_month_present_in_question_is_kept():
    g = ground(parse_output(_bank("March went well.", "How did march go in March?")), SourceBook(prep_lines=NOTE), LANGS, 10)
    assert g.bank[0]["opener"] == "March went well."


def test_opener_abbreviated_month_absent_from_question_is_stripped():
    g = ground(parse_output(_bank("It peaked in Sep. Let me explain.")), SourceBook(prep_lines=NOTE), LANGS, 10)
    assert g.bank[0]["opener"] == "Let me explain."


def test_opener_modal_may_is_not_a_month():
    g = ground(parse_output(_bank("You may ask about it.")), SourceBook(prep_lines=NOTE), LANGS, 10)
    assert g.bank[0]["opener"] == "You may ask about it."


def test_opener_lowercase_march_verb_is_not_a_month():
    g = ground(parse_output(_bank("We march on from here.")), SourceBook(prep_lines=NOTE), LANGS, 10)
    assert g.bank[0]["opener"] == "We march on from here."


def test_opener_capitalised_may_mid_sentence_is_a_month():
    g = ground(parse_output(_bank("It closed in May. Let me explain.")), SourceBook(prep_lines=NOTE), LANGS, 10)
    assert g.bank[0]["opener"] == "Let me explain."


def test_opener_italian_month_absent_from_question_is_stripped():
    g = ground(parse_output(_bank("Sono entrato a marzo. Te lo spiego.")), SourceBook(prep_lines=NOTE), LANGS, 10)
    assert g.bank[0]["opener"] == "Te lo spiego."
