"""Review fixes Q1, Q4 and Q5 for the prep package: fact verification on fetched pages, the spend of retried research turns,
and spend recorded when a build fails. Fictional data, no network."""

from verse_brain.prep.conversation import verify_facts
from verse_brain.prep.conversation_model import Page, ResearchOutput

URL = "https://acme.example/about"
PAGE = Page(URL, "About Acme", text="Acme was founded in 2019 and has its offices in Milan, Italy.", fetched=True)


def _verify(text: str, evidence: str, topic: str = "company"):
    raw = [{"topic": topic, "text": text, "url": URL, "evidence": evidence}]
    return verify_facts(raw, ResearchOutput("", {URL: PAGE}))[0]


def test_q1_fetched_page_fact_without_a_quote_is_unverified():
    f = _verify("Acme raised a 40 million euro Series B in 2024.", "")
    assert f.status == "unverified" and "quote" in f.reason


def test_q1_fetched_page_fact_with_a_trivially_short_quote_is_unverified():
    for text, ev in (("Acme's headquarters are in Berlin.", "Milan"), ("Acme has 500 employees.", "in")):
        f = _verify(text, ev)
        assert f.status == "unverified" and "quote" in f.reason, (text, f.reason)


def test_q1_numbers_must_be_in_the_quote():
    f = _verify("Acme was founded in 2015.", "was founded in 2019 and has its offices")
    assert f.status == "unverified" and "number" in f.reason


def test_q1_a_real_quote_with_matching_numbers_stays_sourced():
    f = _verify("Acme was founded in 2019 and has offices in Milan.", "was founded in 2019 and has its offices in Milan")
    assert f.status == "sourced" and f.check == "quote found on the fetched page"


# ---------------------------------------------------------------------------------------------- proper names in a sourced fact

from verse_brain.prep.conversation import proper_names  # noqa: E402

FAR = "x" * 900  # filler longer than the "near the quote" window
BIO_URL = "https://acme.example/team"
BIO = Page(BIO_URL, "About Acme", fetched=True,
           text=f"Acme builds routing software. {FAR} Our CEO Maria Bianchi said: the company now has 40 employees in Milan. {FAR}")


def _verify_bio(text: str, evidence: str, page: Page = BIO):
    raw = [{"topic": "person", "text": text, "url": page.url, "evidence": evidence}]
    return verify_facts(raw, ResearchOutput("", {page.url: page}))[0]


def test_names_a_name_that_is_not_in_the_quote_or_near_it_is_unverified():
    f = _verify_bio("Globex has 40 employees in Milan.", "the company now has 40 employees in Milan")
    assert f.status == "sourced"  # a lone sentence-initial capital is not read as a name
    f = _verify_bio("Analysts say Globex has 40 employees in Milan.", "the company now has 40 employees in Milan")
    assert f.status == "unverified" and "name" in f.reason


def test_names_a_wrong_person_is_unverified_and_the_right_one_near_the_quote_is_sourced():
    quote = "the company now has 40 employees in Milan"
    wrong = _verify_bio("CEO Marco Verdi says there are 40 employees.", quote)
    assert wrong.status == "unverified" and "name" in wrong.reason
    right = _verify_bio("CEO Maria Bianchi says there are 40 employees.", quote)  # not in the quote, but within the window
    assert right.status == "sourced"


def test_names_the_pages_own_subject_passes_even_far_from_the_quote_or_missing_from_the_body():
    f = _verify_bio("Analysts say Acme has 40 employees in Milan.", "the company now has 40 employees in Milan")
    assert f.status == "sourced"  # "Acme" is in the title and on the page, 900+ characters from the quote
    page = Page("https://www.globex.example/about", "About us", fetched=True, text="Our company now has 40 employees in Milan, Italy.")
    f = _verify_bio("Analysts say Globex has 40 employees in Milan.", "company now has 40 employees in Milan", page)
    assert f.status == "sourced"  # the host names the subject; the body never repeats it
    f = _verify_bio("Analysts say Initech has 40 employees in Milan.", "company now has 40 employees in Milan", page)
    assert f.status == "unverified" and "name" in f.reason  # a different company on that page is not the subject


def test_names_matching_ignores_accents_and_case_and_allows_a_plural_or_translated_place():
    page = Page("https://x.example/p", "Profile", fetched=True, text="Anna Müller joined Stripe as head of ops. Offices in MILANO.")
    f = _verify_bio("Anna Muller joined Stripe in Milan as head of ops.", "joined Stripe as head of ops. Offices in MILANO", page)
    assert f.status == "sourced", f.reason


def test_proper_names_skips_sentence_openers_months_and_legal_suffixes():
    assert proper_names("Founded in March 2012 by Anna Müller; based in Zurich.") == ["anna", "muller", "zurich"]
    assert proper_names("Stripe raised money. Then Acme Robotics did too, said the CEO of Globex Inc.") == ["acme", "robotics", "globex"]
    assert proper_names("the company has 40 employees") == []


# ---------------------------------------------------------------------------------------------- Q5: spend on failure

import asyncio
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
from test_prep_conversation import PAGES, RESEARCH_TEXT, THREAD, Scripted  # noqa: E402
from verse_brain.prep.conversation import ConversationError, FakeConversationPrepModel, run_async  # noqa: E402

NOW = datetime(2026, 10, 15, 9, 30, tzinfo=timezone.utc)


def test_q5_a_failed_build_still_records_the_extract_and_research_spend(tmp_path):
    class Boom(FakeConversationPrepModel):
        async def generate(self, system, user, max_tokens):
            raise RuntimeError("model down")

    lines: list[str] = []
    m = Scripted(research_text=RESEARCH_TEXT, pages=PAGES, searches=3)
    with pytest.raises(ConversationError, match="research is kept in"):
        asyncio.run(run_async(THREAD, out=tmp_path, model=m, prep_model=Boom(), now=NOW, log=lines.append))
    work = next(tmp_path.glob(".conv-*.work"))
    spend = json.loads((work / "spend.json").read_text(encoding="utf-8"))
    assert spend["extract"] > 0 and spend["research_tokens"] > 0
    assert spend["searches"] == pytest.approx(3 * 0.01)
    assert spend["total"] == pytest.approx(spend["extract"] + spend["research_tokens"] + spend["searches"], abs=1e-5)
    assert any("spending" in ln and "build failed" in ln for ln in lines)


# ---------------------------------------------------------------------------------------------- Q4: retried research turn

from types import SimpleNamespace  # noqa: E402

from verse_brain.prep.conversation_model import AnthropicConversationModel  # noqa: E402


class _Stream:
    """A fake `messages.stream(...)` context: the first `drops` streams yield one event and then die, the next one finishes."""

    def __init__(self, client):
        self.client, self.dies = client, client.opened < client.drops
        client.opened += 1
        client.max_uses.append({t["name"]: t["max_uses"] for t in client.tools_seen})

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        return False

    def __aiter__(self):
        return self._events()

    async def _events(self):
        import httpx2

        yield SimpleNamespace(type="content_block_start")
        if self.dies:
            raise httpx2.ReadError("")

    async def get_final_message(self):
        usage = SimpleNamespace(input_tokens=10, output_tokens=5, cache_read_input_tokens=0, cache_creation_input_tokens=0,
                                server_tool_use=SimpleNamespace(web_search_requests=1, web_fetch_requests=0))
        return SimpleNamespace(usage=usage, stop_reason="end_turn", content=[{"type": "text", "text": "done"}])


class _Client:
    def __init__(self, drops):
        self.drops, self.opened, self.max_uses, self.tools_seen = drops, 0, [], []
        self.messages = self

    def stream(self, **kw):
        self.tools_seen = kw["tools"]
        return _Stream(self)


def _research(monkeypatch, drops, max_uses=8, max_fetches=5):
    async def no_sleep(s):
        pass

    monkeypatch.setattr("verse_brain.prep.conversation_model.asyncio.sleep", no_sleep)
    model = AnthropicConversationModel("sk-ant-test-not-a-real-key")
    model._client = _Client(drops)
    return asyncio.run(model.research("sys", "user", max_uses, max_fetches, 1000)), model._client


def test_q4_a_retry_after_the_stream_started_charges_the_lost_searches(monkeypatch):
    out, client = _research(monkeypatch, drops=1, max_uses=8)
    assert client.opened == 2
    assert client.max_uses[0] == {"web_search": 8, "web_fetch": 5}
    # the dead attempt may have run up to 8 billed searches: they are charged, so the retry gets no search tool at all
    assert out.lost_searches == 8 and out.searches == 8 + 1
    assert client.max_uses[1] == {"web_fetch": 5}
    assert out.cost_estimated is True


def test_q4_the_cost_line_says_estimated(tmp_path):
    from verse_brain.prep.conversation import render_research_md

    ex = {"company": "Acme", "title": "", }
    rs = ResearchOutput("", searches=9, lost_searches=8, cost_estimated=True)
    md = render_research_md(ex, [], [], rs, now=NOW, cost={"total": 0.123})
    assert "Cost $0.1230 (estimated" in md and "8 searches" in md
    clean = render_research_md(ex, [], [], ResearchOutput(""), now=NOW, cost={"total": 0.123})
    assert "estimated" not in clean


def test_q4_a_partly_spent_cap_shrinks_the_retry(monkeypatch):
    out2, client2 = _research(monkeypatch, drops=2, max_uses=3)
    assert client2.opened == 3 and out2.lost_searches == 3  # the second drop had no search tool left to lose
    assert out2.searches <= 3 + 1


def test_q4_a_clean_run_is_not_marked_estimated(monkeypatch):
    out, client = _research(monkeypatch, drops=0)
    assert client.opened == 1 and out.lost_searches == 0 and out.searches == 1 and out.cost_estimated is False


# ---------------------------------------------------------------------------------------------- Q5: retry loops and budgets

from test_prep_me import OUTPUT as ME_OUTPUT  # noqa: E402,F401
from test_prep_me import setup as me_setup  # noqa: E402
from verse_brain.prep import me as ME  # noqa: E402
from verse_brain.prep import script as SCRIPT  # noqa: E402
from verse_brain.prep import voice as VOICE  # noqa: E402
from verse_brain.prep.model import ModelOutput, PRICES, PrepError, Usage, spend_usd  # noqa: E402

_PIN, _POUT = PRICES["claude-sonnet-5-5"][:2]


class _Garbage:
    """Answers nothing usable, billing `output` tokens each call; records the max_tokens it was given."""
    model = "claude-sonnet-5-5"

    def __init__(self, output=38000):
        self.output, self.max_tokens = output, []

    async def generate(self, system, user, max_tokens):
        self.max_tokens.append(max_tokens)
        return ModelOutput("no usable answer", Usage(input=4000, output=self.output), "end_turn")

    async def count_tokens(self, text):
        return len(text) // 4

    async def count_request_tokens(self, system, user):
        return 4000


def _second_call_fits(model, budget, first=Usage(input=4000, output=38000)):
    """What the first call really cost, plus the second call at its max_tokens, stays within the budget (the old sizing
    gave both calls the full budget)."""
    spent = spend_usd("claude-sonnet-5-5", first)
    return spent + 4000 * _PIN / 1e6 + model.max_tokens[1] * _POUT / 1e6 <= budget + 1e-3


def test_q5_me_second_attempt_is_sized_from_the_budget_left():
    m = _Garbage(output=38000)
    with pytest.raises(ME.MeError) as ei:
        asyncio.run(ME.generate(m, [], "", [], budget_usd=0.5))
    assert len(m.max_tokens) == 2 and m.max_tokens[1] < m.max_tokens[0]
    assert _second_call_fits(m, 0.5), "two attempts must fit one budget"
    spent = spend_usd("claude-sonnet-5-5", Usage(input=8000, output=76000))
    assert ei.value.usage == Usage(input=8000, output=76000)
    assert f"${spent:.4f}" in str(ei.value)


def test_q5_me_stops_when_the_budget_left_cannot_fund_a_second_call():
    m = _Garbage(output=45000)  # $0.45 of a $0.5 budget gone: under 8000 output tokens left
    with pytest.raises(ME.MeError, match="budget") as ei:
        asyncio.run(ME.generate(m, [], "", [], budget_usd=0.5))
    assert len(m.max_tokens) == 1 and ei.value.usage.output == 45000


def test_q5_me_failed_build_records_the_spend_in_the_meta(tmp_path):
    from test_prep_me import NOW
    prof, vault = me_setup(tmp_path)
    m = _Garbage(output=1000)
    meta = prof / "me.meta.json"
    meta.write_text(json.dumps({"spend_usd_total": 0.25, "sources": {}}), encoding="utf-8")
    with pytest.raises(ME.MeError):
        asyncio.run(ME.build_profile(prof, model=m, vault=vault, now=NOW))
    spent = spend_usd("claude-sonnet-5-5", Usage(input=8000, output=2000))
    got = json.loads(meta.read_text(encoding="utf-8"))
    assert got["spend_usd_total"] == pytest.approx(0.25 + spent, abs=1e-5)
    assert got["last_failed_spend_usd"] == pytest.approx(spent, abs=1e-5)


def test_q5_voice_second_attempt_is_sized_from_the_budget_left():
    m = _Garbage(output=38000)
    with pytest.raises(PrepError) as ei:
        asyncio.run(VOICE.distill_async("some source text", m, budget_usd=0.5))
    assert len(m.max_tokens) == 2 and m.max_tokens[1] < m.max_tokens[0]
    assert _second_call_fits(m, 0.5)
    spent = spend_usd("claude-sonnet-5-5", Usage(input=8000, output=76000))
    assert ei.value.usage == Usage(input=8000, output=76000) and f"${spent:.4f}" in str(ei.value)


def test_q5_script_failure_reports_the_summed_spend():
    m = _Garbage(output=300)
    with pytest.raises(PrepError) as ei:
        asyncio.run(SCRIPT.write_script_async("a topic", 60, "recording", m))
    spent = spend_usd("claude-sonnet-5-5", Usage(input=8000, output=600))
    assert len(m.max_tokens) == 2
    assert ei.value.usage == Usage(input=8000, output=600) and f"${spent:.4f}" in str(ei.value)
