"""Review 2026-11-11 M5, L1, L2, P8, P9 and the opener month-check edge cases."""

import os
import subprocess
import time
from pathlib import Path

import pytest

from verse_brain.prep.event import event_to_prep_note
from verse_brain.prep.git_digest import Commit, read_commits
from verse_brain.prep.ground import Grounded, _ground_opener, _months_in, _value_supported
from verse_brain.prep.sources import SourceBook, numbers_in, numbers_supported


# ---------------------------------------------------------------------------------------------- M5


def test_date_value_needs_year_and_day_not_either():
    # the day 14 is in the quote, the year 2025 is not
    assert not _value_supported("date", "2025-03-14", ["launched on 14 March 2024"])
    # the year is in the quote, the day is not
    assert not _value_supported("date", "2025-03-14", ["launched in March 2025"])


def test_date_value_passes_when_year_and_day_are_both_in_the_quote():
    assert _value_supported("date", "2025-03-14", ["launched on 14 March 2025"])
    assert _value_supported("date", "14/03/2025", ["launched on 14 March 2025"])
    assert _value_supported("date", "14 March 2025", ["launched on 14 March 2025"])
    assert not _value_supported("date", "14 March 2025", ["launched on 14 March 2024"])


# ---------------------------------------------------------------------------------------------- L1


def test_zero_point_xxx_is_a_decimal_not_thousands():
    assert numbers_in("0.125") == {0.125}
    assert numbers_in("0,125 s") == {0.125}
    assert not numbers_supported("the claim is 125 ms", ["latency of 0.125 ms"])
    assert numbers_supported("latency is 0.125 ms", ["latency of 0.125 ms"])


def test_long_integer_part_with_three_decimals_is_a_decimal():
    assert numbers_in("1234.567") == {1234.567}


@pytest.mark.parametrize("tok,val", [("1.250", 1250.0), ("12.500", 12500.0), ("1,250", 1250.0),
                                     ("12,345,678", 12345678.0), ("96,4", 96.4), ("96.4", 96.4)])
def test_thousands_and_ordinary_decimals_keep_working(tok, val):
    assert numbers_in(tok) == {val}


# ---------------------------------------------------------------------------------------------- L2


def _book() -> SourceBook:
    c = Commit(repo="r", hash="abc1234", date="2026-11-01", subject="Fix the retry loop", files=("a.py",))
    return SourceBook(prep_lines=[], commits={c.hash: c})


@pytest.mark.parametrize("handle", ["commit:", "a", "abc", "commit:abc12", "commit:zzzzzzz"])
def test_short_or_non_hex_commit_handle_does_not_resolve(handle):
    assert _book().resolve(handle, "Fix the retry loop") is None


@pytest.mark.parametrize("handle", ["abc1234", "commit:abc1234", "commit:ABC1234", "abc1234" + "0" * 33])
def test_seven_hex_chars_resolve_in_both_prefix_directions(handle):
    src = _book().resolve(handle, "Fix the retry loop")
    assert src is not None and src.ref == "commit:r@abc1234"


# ---------------------------------------------------------------------------------------------- P8


def _git(repo: Path, *args: str, input_bytes: bytes | None = None) -> None:
    env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"}
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=T", "-c", "user.email=t@example.com",
                    "-c", "commit.gpgsign=false", *args], check=True, capture_output=True, env=env, input=input_bytes)


def test_latin1_commit_message_does_not_lose_the_digest(tmp_path, monkeypatch):
    # git re-encodes messages to UTF-8 by itself, so force a Latin-1 log output: the e-acute becomes the raw byte 0xE9
    monkeypatch.setenv("GIT_CONFIG_COUNT", "1")
    monkeypatch.setenv("GIT_CONFIG_KEY_0", "i18n.logOutputEncoding")
    monkeypatch.setenv("GIT_CONFIG_VALUE_0", "ISO-8859-1")
    repo = tmp_path / "latin"
    repo.mkdir()
    _git(repo, "init", "-q")
    (repo / "a.txt").write_text("1")
    _git(repo, "add", ".")
    _git(repo, "commit", "-q", "-F", "-", input_bytes="Café menu update".encode("utf-8"))
    (repo / "b.txt").write_text("2")
    _git(repo, "add", ".")
    _git(repo, "commit", "-q", "-m", "Second commit")
    commits = read_commits(repo)
    assert len(commits) == 2
    assert any(c.subject.startswith("Caf") and c.subject.endswith("menu update") for c in commits)
    assert any(c.subject == "Second commit" for c in commits)


# ---------------------------------------------------------------------------------------------- P9


@pytest.fixture
def rome_tz():
    old = os.environ.get("TZ")
    os.environ["TZ"] = "Europe/Rome"
    time.tzset()
    yield
    if old is None:
        os.environ.pop("TZ", None)
    else:
        os.environ["TZ"] = old
    time.tzset()


@pytest.mark.parametrize("start,end", [
    ("2026-10-22T15:00:00", "2026-10-22T15:45:00+02:00"),  # naive start, aware end
    ("2026-10-22T15:00:00+02:00", "2026-10-22T15:45:00"),  # aware start, naive end
])
def test_mixed_naive_and_aware_event_times_do_not_raise(rome_tz, start, end):
    note = event_to_prep_note({"title": "Sync", "start": start, "end": end})
    assert "45 minutes" in note  # naive is read as local time (Rome, UTC+2 on that date)


def test_naive_end_before_start_is_handled_like_an_aware_one(rome_tz):
    note = event_to_prep_note({"title": "Sync", "start": "2026-10-22T15:00:00+02:00", "end": "2026-10-22T14:00:00"})
    assert "minutes" not in note and "Thursday 22 October 2026, 15:00" in note


# ---------------------------------------------------------------------------------------------- month check


@pytest.mark.parametrize("text,months", [
    ("May was the busiest month.", {5}),
    ("March, the team shipped it.", {3}),
    ("May has been quiet.", {5}),
    ("March 2025 was the start.", {3}),
    ("We met early. May brought rain.", {5}),
    ("May I ask a question?", set()),
    ("May we start now?", set()),
    ("We met early. May I ask?", set()),
    ("March on the capital.", set()),
    ("March forward together.", set()),
    ("Last March we shipped it.", {3}),
    ("We may go in march.", set()),
    ("It was due 14 May.", {5}),
])
def test_ambiguous_month_words(text, months):
    assert _months_in(text) == months


@pytest.mark.parametrize("text,months", [
    ("Il mar e il dec sono parole.", set()),
    ("Il mare era calmo, e il dec non c'entra.", set()),
    ("mar 14 was it", {3}),
    ("Due in dec.", {12}),
    ("Report from Jan was late.", {1}),
    ("Sep 2025 closed it.", {9}),
    ("Delivered 3 oct to the client.", {10}),
    ("The deadline moved to JUN.", {6}),
    ("Sept. 4 is the day.", {9}),
])
def test_three_letter_abbreviations_need_capital_period_or_number(text, months):
    assert _months_in(text) == months


def test_opener_with_italian_mar_and_dec_is_not_dropped():
    g = Grounded()
    out = _ground_opener("Il mar e il dec sono passati.", "How did the pilot go?", g)
    assert out == "Il mar e il dec sono passati."
    assert not g.dropped


def test_opener_sentence_starting_with_may_was_is_dropped_when_the_question_has_no_month():
    g = Grounded()
    out = _ground_opener("May was hard. We stayed on track.", "How did the pilot go?", g)
    assert out == "We stayed on track."
    assert g.dropped and g.dropped[0].reason == "unsupported_month"


# ---------------------------------------------------------------------------------------------- number format by language


@pytest.mark.parametrize("lang,tok,val", [
    ("en", "3.141", 3.141), ("en", "3,141", 3141.0), ("en", "1,234.56", 1234.56), ("en", "1.250", 1.25), ("en", "0,125", 0.125),
    ("it", "3.141", 3141.0), ("it", "3,141", 3.141), ("it", "1.234,56", 1234.56), ("it", "1,250", 1.25), ("it", "0.125", 0.125),
    ("tr", "3.141", 3141.0), ("tr", "3,141", 3.141), ("tr", "12.345.678", 12345678.0),
])
def test_number_format_follows_the_language(lang, tok, val):
    assert numbers_in(tok, lang) == {val}


def test_unknown_or_missing_language_keeps_the_format_blind_guess():
    for lang in (None, "", "de", "xx"):
        assert numbers_in("3.141", lang) == {3141.0} and numbers_in("96,4", lang) == {96.4}


def test_a_claim_is_checked_against_the_quote_in_the_language_both_are_written_in():
    # English: "3.141" is a decimal, so a claim of 3141 is not in the quote; Italian: the same quote says 3141
    assert not numbers_supported("it took 3141 ms", ["it took 3.141 ms"], "en")
    assert numbers_supported("it took 3141 ms", ["it took 3.141 ms"], "it")
    assert not numbers_supported("it took 3.141 ms", ["it took 3,141 ms"], "en")  # decimal vs thousands
    assert numbers_supported("it took 3,141 ms", ["it took 3,141 ms"], "it")  # the same decimal in Italian
    assert not numbers_supported("it took 3141 ms", ["it took 3,141 ms"], "it")


def test_verify_facts_reads_numbers_in_the_given_language():
    from verse_brain.prep.conversation import verify_facts
    from verse_brain.prep.conversation_model import Page, ResearchOutput
    url = "https://acme.example/it"
    page = Page(url, "Acme", fetched=True, text="Il ricavo del 2024 e di 3.141 euro per cliente.")
    raw = [{"topic": "size", "text": "Revenue is 3141 euro per customer in 2024.", "url": url, "evidence": "del 2024 e di 3.141 euro per cliente"}]
    res = ResearchOutput("", {url: page})
    assert verify_facts(raw, res, "it")[0].status == "sourced"
    f = verify_facts(raw, res, "en")[0]
    assert f.status == "unverified" and "number" in f.reason
