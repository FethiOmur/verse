"""Prep from a conversation: extract, sourced research, the prep note and the offline end-to-end run.
Every thread, company and person in these tests is fictional. No network, no Keychain."""

import asyncio
import json
import socket
from datetime import datetime, timezone
from pathlib import Path

import pytest

from verse_brain.prep import keychain
from verse_brain.prep.__main__ import main
from verse_brain.prep.conversation import (ConversationError, Fact, FakeConversationPrepModel, Inference, norm_url,
                                           parse_extract, parse_facts, render_prep_note, run_async, verify_facts)
from verse_brain.prep.conversation_model import (FakeConversationModel, Page, ResearchOutput, collect_sources)
from verse_brain.prep.model import ModelOutput, Usage
from verse_brain.prep.pipeline import _collect, seed_queries
from verse_brain.prep.sources import SourceBook

FIX = Path(__file__).parent / "fixtures" / "conversation"
THREAD = (FIX / "thread_fictional.md").read_text(encoding="utf-8")
POSTING = (FIX / "posting_fictional.txt").read_text(encoding="utf-8")
VOICE = Path(__file__).parent / "fixtures" / "voice" / "profile_fictional.md"
NOW = datetime(2026, 10, 15, 9, 30, tzinfo=timezone.utc)

QUOTE = "Please be ready to talk about how you keep an assistant from inventing facts."

EXTRACT = {
    "title": "First call with Marta Lindqvist, Brightwater Analytics",
    "company": "Brightwater Analytics", "role": "Applied AI Engineer",
    "people": [
        {"name": "Marta Lindqvist", "role": "Head of Product", "company": "Brightwater Analytics", "notes": "wrote first"},
        {"name": "Jonas Ek", "role": "tech lead", "company": "Brightwater Analytics", "notes": "may join the last ten minutes"},
        {"name": "Priya Nair", "role": "CEO", "company": "Brightwater Analytics", "notes": "not in the thread"},
    ],
    "what_they_want": ["An assistant that explains late deliveries"],
    "meeting": {"purpose": "A first call to talk through the role", "when": "Thursday 8 October, 16:00 CEST",
                "format": "Google Meet, 30 minutes"},
    "open_questions": ["Who else joins the call?"],
    "promises": [{"who": "Marta Lindqvist", "text": "send the invite tonight and share the API docs before the call"}],
    "candidate_said": ["Asked for around 420 EUR per day and can start on 1 December"],
    "terms": ["Budget 380 to 460 EUR per day (Marta)"],
    "quotes": [{"who": "Marta Lindqvist", "text": QUOTE},
               {"who": "Marta Lindqvist", "text": "We will pay you a million euros for this."}],
}


class Scripted:
    """The extract/research transport: fixed answers, records what it was asked."""

    model = "claude-sonnet-5-5"

    def __init__(self, extract=None, research_text="", pages=None, searches=3, usage=None, fetches=None):
        self.extract_json = json.dumps(extract if extract is not None else EXTRACT)
        self.research_text = research_text
        self.pages = pages or {}
        self.searches = searches
        self.usage = usage or Usage(input=4000, output=1500)
        self.fetches = fetches or []
        self.calls: list[tuple] = []

    async def extract(self, system, user, max_tokens):
        self.calls.append(("extract", system, user))
        return ModelOutput("Here you go:\n```json\n" + self.extract_json + "\n```", Usage(input=2000, output=800), "end_turn")

    async def research(self, system, user, max_uses, max_fetches, max_tokens):
        self.calls.append(("research", system, user, max_uses, max_fetches))
        return ResearchOutput(self.research_text, self.pages, ["brightwater analytics", "brightwater analytics funding"],
                              self.searches, [], self.fetches, len(self.fetches), self.usage, "end_turn")


ABOUT = "https://www.brightwater-analytics.example/about"
TERMS = "https://www.brightwater-analytics.example/terms"
NEWS = "https://news.example.org/brightwater-raises-seed"
FB = "https://www.facebook.com/brightwater"
ENTITY_LINE = "Brightwater Analytics AB, registered in Sweden, company number 556000-0000"
RESEARCH_TEXT = f"""I will search now.
@FACT
topic: company
text: Brightwater Analytics sells route-reporting software to haulage firms across Europe.
url: {ABOUT}
evidence: route-reporting software to haulage firms
@END
@FACT
topic: entity
text: The legal entity is Brightwater Analytics AB, registered in Sweden.
url: {TERMS}
evidence: {ENTITY_LINE}
@END
@FACT
topic: entity
text: The head office is in Lund.
url: {FB}
evidence: Lund, Sweden
@END
@FACT
topic: funding
text: Brightwater Analytics raised a 4 million euro seed round.
url: {NEWS}
evidence: raised a 4 million euro seed round
@END
@FACT
topic: size
text: The company has about 30 employees.
url: none
@END
@FACT
topic: stack
text: Its backend runs on Rust.
url: https://guessed.example.com/stack
evidence: built in Rust
@END
@FACT
topic: product
text: The product has a free tier.
url: {TERMS}
evidence: every customer gets a free tier forever
@END
@INFER
text: It is probably a small founder-led team.
basis: no team page found
@END
@FACT
topic: news
text: A fact block that never ends
url: {ABOUT}
@GAP
text: Their customer list was not found.
@END
"""
PAGES = {
    ABOUT: Page(ABOUT, "About us", "March 2026", ["route-reporting software for haulage"],
                text="Welcome. We sell route-reporting software to haulage firms across Europe.", fetched=True),
    TERMS: Page(TERMS, "Terms", text=f"Terms of use. Provider: {ENTITY_LINE}. Governing law: Sweden.", fetched=True),
    NEWS: Page(NEWS, "Seed round"),  # a search result only: its quote cannot be checked
    FB: Page(FB, "Brightwater on Facebook"),
}


# ---------------------------------------------------------------------------------------------- extract


def test_extract_people_company_role_promises():
    warnings: list[str] = []
    ex = parse_extract("Sure:\n```json\n" + json.dumps(EXTRACT) + "\n```", THREAD + POSTING, warnings)
    assert ex["company"] == "Brightwater Analytics" and ex["role"] == "Applied AI Engineer"
    assert [p["name"] for p in ex["people"]] == ["Marta Lindqvist", "Jonas Ek"]
    assert ex["promises"] == [{"who": "Marta Lindqvist", "text": "send the invite tonight and share the API docs before the call"}]
    assert ex["meeting"]["when"].startswith("Thursday 8 October")
    assert ex["candidate_said"] and ex["terms"] and ex["open_questions"]
    # the verbatim quote stays; the invented one and the invented person are dropped and named
    assert [q["text"] for q in ex["quotes"]] == [QUOTE]
    assert any("Priya Nair" in w for w in warnings) and any("not verbatim" in w for w in warnings)


@pytest.mark.parametrize("bad", ["no json here", '{"title": ', "[1, 2]"])
def test_extract_rejects_non_json(bad):
    with pytest.raises(ConversationError):
        parse_extract(bad, THREAD, [])


def test_extract_tolerates_missing_fields():
    ex = parse_extract('{"company": "Acme"}', "Acme", [])
    assert ex["company"] == "Acme" and ex["people"] == [] and ex["meeting"]["purpose"] == ""


# ---------------------------------------------------------------------------------------------- research


def test_parse_facts_drops_unclosed_block_and_keeps_gaps():
    raw, infers, gaps = parse_facts(RESEARCH_TEXT)
    assert [f["topic"] for f in raw] == ["company", "entity", "entity", "funding", "size", "stack", "product"]
    assert raw[1]["evidence"] == ENTITY_LINE
    assert infers == [Inference("It is probably a small founder-led team.", "no team page found")]
    assert gaps == ["Their customer list was not found."]


def test_every_fact_has_a_url_or_is_unverified():
    raw, _, _ = parse_facts(RESEARCH_TEXT)
    facts = verify_facts(raw, ResearchOutput("", PAGES))
    by = {(f.topic, f.text[:12]): f for f in facts}
    company = next(f for f in facts if f.topic == "company")
    assert company.status == "sourced" and company.url == ABOUT and company.title == "About us"
    assert company.check == "quote found on the fetched page"
    funding = next(f for f in facts if f.topic == "funding")
    assert funding.status == "sourced" and funding.check == "search result, quote not checkable"
    size = next(f for f in facts if f.topic == "size")
    assert size.status == "unverified" and size.url == "" and "no source page" in size.reason
    # a URL the search never returned is a guess: unverified, and the guess is kept visible
    stack = next(f for f in facts if f.topic == "stack")
    assert stack.status == "unverified" and stack.url == "https://guessed.example.com/stack"
    assert "not among the pages" in stack.reason
    assert all(f.url for f in facts if f.status == "sourced")
    assert len(by) == len(facts)


def test_entity_facts_need_an_official_page_and_a_real_quote():
    raw, _, _ = parse_facts(RESEARCH_TEXT)
    facts = verify_facts(raw, ResearchOutput("", PAGES))
    entity = [f for f in facts if f.topic == "entity"]
    assert [f.status for f in entity] == ["sourced", "unverified"]
    assert entity[0].url == TERMS and entity[0].check == "quote found on the fetched page"
    assert "company's own page or an official registry" in entity[1].reason, "a Facebook page cannot carry the head office"
    # a quote that is not on the fetched page demotes the fact, even with a valid URL
    product = next(f for f in facts if f.topic == "product")
    assert product.status == "unverified" and "not on the fetched page" in product.reason


def test_url_matching_ignores_www_slash_fragment_and_tracking():
    assert norm_url("https://www.Example.com/a/?utm_source=x&id=2#top") == norm_url("http://example.com/a?id=2")
    assert norm_url("https://example.com/a") != norm_url("https://example.com/b")
    raw = [{"topic": "company", "text": "T", "url": "https://brightwater-analytics.example/about/?utm_campaign=z"}]
    assert verify_facts(raw, ResearchOutput("", PAGES))[0].status == "sourced"


def test_collect_sources_reads_the_documented_response_shape():
    content = [
        {"type": "text", "text": "I'll search. "},
        {"type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": {"query": "brightwater analytics"}},
        {"type": "web_search_tool_result", "tool_use_id": "srvtoolu_1", "content": [
            {"type": "web_search_result", "url": ABOUT, "title": "About us", "encrypted_content": "xx", "page_age": "March 2026"}]},
        {"type": "server_tool_use", "id": "srvtoolu_2", "name": "web_search", "input": {"query": "second"}},
        {"type": "web_search_tool_result", "tool_use_id": "srvtoolu_2",
         "content": {"type": "web_search_tool_result_error", "error_code": "max_uses_exceeded"}},
        {"type": "server_tool_use", "id": "srvtoolu_3", "name": "web_fetch", "input": {"url": TERMS}},
        {"type": "web_fetch_tool_result", "tool_use_id": "srvtoolu_3", "content": {
            "type": "web_fetch_result", "url": TERMS, "retrieved_at": "2026-10-15T16:49:20",
            "content": {"type": "document", "title": "Terms", "source": {"type": "text", "media_type": "text/plain", "data": "Terms text"}}}},
        {"type": "server_tool_use", "id": "srvtoolu_4", "name": "web_fetch", "input": {"url": FB}},
        {"type": "web_fetch_tool_result", "tool_use_id": "srvtoolu_4",
         "content": {"type": "web_fetch_tool_result_error", "error_code": "url_not_accessible"}},
        {"type": "text", "text": "@FACT", "citations": [
            {"type": "web_search_result_location", "url": ABOUT, "title": "About us", "encrypted_index": "e", "cited_text": "route-reporting"},
            {"type": "web_search_result_location", "url": NEWS, "title": "Seed", "encrypted_index": "e", "cited_text": "raised"}]},
    ]
    got = collect_sources(content)
    assert got.text == "I'll search. @FACT" and got.queries == ["brightwater analytics", "second"]
    assert got.errors == ["web_search: max_uses_exceeded", "web_fetch: url_not_accessible"]
    assert got.fetches == [TERMS, FB]
    assert list(got.pages) == [ABOUT, TERMS, NEWS]
    assert got.pages[ABOUT].page_age == "March 2026" and got.pages[ABOUT].cited == ["route-reporting"] and not got.pages[ABOUT].fetched
    assert got.pages[TERMS].fetched and got.pages[TERMS].text == "Terms text" and got.pages[TERMS].title == "Terms"


def test_run_passes_the_search_cap_and_hides_private_terms_from_the_search_model(tmp_path):
    m = Scripted(research_text=RESEARCH_TEXT, pages=PAGES)
    asyncio.run(run_async(THREAD, out=tmp_path, model=m, prep_model=FakeConversationPrepModel(), posting=POSTING,
                          company_url="https://www.brightwater-analytics.example", now=NOW, max_searches=8))
    kind, system, user, max_uses, max_fetches = next(c for c in m.calls if c[0] == "research")
    assert (max_uses, max_fetches) == (8, 5) and "at most 8 searches" in system and "at most 5 page fetches" in system
    assert "https://www.brightwater-analytics.example" in user
    assert "Brightwater Analytics" in user and "Marta Lindqvist" in user
    for private in ("450", "EUR", "1 December", "inventing facts", "northwind"):
        assert private not in user, private


# ---------------------------------------------------------------------------------------------- prep note


def _note(facts=None):
    raw, infers, gaps = parse_facts(RESEARCH_TEXT)
    facts = facts or verify_facts(raw, ResearchOutput("", PAGES))
    ex = parse_extract(json.dumps(EXTRACT), THREAD + POSTING, [])
    return render_prep_note(ex, facts, gaps, infers, owner="the owner", now=NOW, posting=POSTING, posting_url="https://jobs.example/1",
                            company_url=None, note="Keep it short.\nAsk about the API docs."), facts


def test_prep_note_marks_unverified_and_cites_sources():
    note, _ = _note()
    assert f"(source: {ABOUT})" in note and f"(source: {TERMS})" in note
    # sourced facts sit under topic headings, entity first; what failed its check is listed apart, never under a topic
    head, _, unver = note.partition("## Unverified research claims")
    assert "### entity" in head and head.index("### entity") < head.index("### company")
    assert "unverified" not in head.split("## Research")[1].split("## Likely")[0]
    assert "unverified: no source page" in unver and "unverified: the URL was not among" in unver
    assert "The head office is in Lund." in unver and "The head office is in Lund." not in head
    assert "## Likely / inferred (no direct source; say it only with hedging)" in note
    assert "- It is probably a small founder-led team. (basis: no team page found)" in note
    assert "## Not found" in note and "Their customer list was not found." in note
    assert "## Terms discussed (keep private)" in note
    assert "- Marta Lindqvist promised: send the invite tonight" in note
    lines = [ln for ln in note.splitlines() if ln.startswith("- ") and "route-reporting software" in ln and "source:" in ln]
    assert len(lines) == 1  # one source per line, on the same line as the fact


def test_prep_note_parses_with_the_existing_reader(tmp_path):
    note, _ = _note()
    p = tmp_path / "prep_note.md"
    p.write_text(note, encoding="utf-8")
    text, commits, handles = _collect(p, [], None, [])  # the pipeline's own reader
    assert text == note and commits == {} and handles == {}
    assert seed_queries(note, [])[0].startswith("Prep note: First call with Marta Lindqvist")
    book = SourceBook(prep_lines=note.splitlines())
    line = "Brightwater Analytics sells route-reporting software to haulage firms across Europe."
    src = book.resolve("prep:L1", line)
    assert src is not None and note.splitlines()[int(src.ref.split("L")[1]) - 1].count(ABOUT) == 1
    assert book.resolve("prep:L1", "Invented sentence that is not in the note at all.") is None


def test_fake_prep_end_to_end_grounds_against_the_note(tmp_path):
    m = Scripted(research_text=RESEARCH_TEXT, pages=PAGES, searches=3, fetches=[ABOUT, TERMS])
    session, summary = asyncio.run(run_async(THREAD, out=tmp_path, model=m, prep_model=FakeConversationPrepModel(),
                                              posting=POSTING, posting_url="https://jobs.example/1", note="Ask about docs.",
                                              now=NOW))
    assert session.name == "conv-" + session.name[5:] and "brightwater-analytics" in session.name
    bank = [json.loads(ln) for ln in (session / "bank.jsonl").read_text(encoding="utf-8").splitlines()]
    assert bank and all(b["sources"] and all(s["ref"].startswith("prep:L") for s in b["sources"]) for b in bank)
    meta = json.loads((session / "meta.json").read_text(encoding="utf-8"))
    conv = meta["conversation"]
    assert conv["searches"] == 3 and conv["fetch_count"] == 2 and conv["fetches"] == [ABOUT, TERMS]
    assert conv["facts_sourced"] == 3 and conv["facts_unverified"] == 4 and conv["inferred"] == 1
    research_md = (session / "research.md").read_text(encoding="utf-8")
    assert "## Likely / inferred" in research_md and "quote found on the fetched page" in research_md
    assert "## Fetched pages" in research_md and TERMS in research_md
    c = conv["cost_usd"]
    assert c["searches"] == pytest.approx(0.03) and c["extract"] == pytest.approx(2000 * 2 / 1e6 + 800 * 10 / 1e6)
    assert c["research_tokens"] == pytest.approx(4000 * 2 / 1e6 + 1500 * 10 / 1e6)
    assert c["total"] == pytest.approx(c["extract"] + c["research_tokens"] + c["searches"] + c["prep"])
    assert summary["cost"]["total"] == c["total"]
    assert meta["prep_note"] == str(session / "prep_note.md")
    assert any("unverified" in w for w in meta["warnings"])
    assert not list(tmp_path.glob(".*.work")), "the staging folder is removed after a good run"


def test_failed_prep_keeps_the_research(tmp_path):
    class Boom(FakeConversationPrepModel):
        async def generate(self, system, user, max_tokens):
            raise RuntimeError("model down")

    m = Scripted(research_text=RESEARCH_TEXT, pages=PAGES)
    with pytest.raises(ConversationError, match="research is kept in"):
        asyncio.run(run_async(THREAD, out=tmp_path, model=m, prep_model=Boom(), now=NOW))
    work = next(tmp_path.glob(".conv-*.work"))
    assert (work / "prep_note.md").is_file() and (work / "thread.md").is_file()
    assert not any(p.name.startswith("conv-") for p in tmp_path.iterdir() if not p.name.startswith("."))


def test_input_limits(tmp_path):
    for kw, thread in (({}, ""), ({}, "x" * 60_001), ({"posting": "p" * 30_001}, "hello")):
        with pytest.raises(ConversationError):
            asyncio.run(run_async(thread, out=tmp_path, model=Scripted(), prep_model=FakeConversationPrepModel(), **kw))


# ---------------------------------------------------------------------------------------------- CLI, offline


def test_cli_fake_makes_a_session_offline(tmp_path, monkeypatch, capsys):
    def boom(*a, **k):
        raise AssertionError("network, Keychain or a subprocess was touched in --fake mode")

    monkeypatch.setattr(socket.socket, "connect", boom)
    monkeypatch.setattr(socket, "getaddrinfo", boom)
    monkeypatch.setattr(socket, "create_connection", boom)
    monkeypatch.setattr(keychain, "read_api_key", boom)
    monkeypatch.setattr("verse_brain.prep.conversation.read_api_key", boom)
    monkeypatch.setattr("subprocess.run", boom)
    note = tmp_path / "note.md"
    note.write_text("Ask about the API docs.", encoding="utf-8")
    rc = main(["conversation", "--thread", str(FIX / "thread_fictional.md"), "--posting-file", str(FIX / "posting_fictional.txt"),
               "--posting-url", "https://jobs.example/1", "--company-url", "https://example.com", "--note", str(note),
               "--fake", "--voice-profile", str(VOICE), "--out", str(tmp_path / "s")])
    assert rc == 0
    cap = capsys.readouterr()
    lines = cap.out.strip().splitlines()
    assert len(lines) == 1, "stdout is the session folder and nothing else"
    session = Path(lines[0])
    assert session.parent == tmp_path / "s" and session.name.startswith("conv-")
    assert {p.name for p in session.iterdir()} >= {"meta.json", "bank.jsonl", "pack.md", "review.md", "thread.md", "research.md", "prep_note.md"}
    assert "Marta Lindqvist" in (session / "thread.md").read_text(encoding="utf-8")
    assert "STYLE GUIDE" in (session / "pack.md").read_text(encoding="utf-8"), "the voice profile is in the pack"
    assert "cost: $0.0000" in cap.err and "research: 1 searches | 1 fetches" in cap.err and "warning:" in cap.err
    assert oct((session / "thread.md").stat().st_mode & 0o777) == "0o600"


def test_cli_errors_go_to_stderr_with_exit_1(tmp_path, capsys):
    rc = main(["conversation", "--thread", str(tmp_path / "missing.md"), "--fake", "--out", str(tmp_path / "s")])
    assert rc == 1
    cap = capsys.readouterr()
    assert cap.out == "" and cap.err.startswith("error: cannot read the thread")
    empty = tmp_path / "empty.md"
    empty.write_text("  \n", encoding="utf-8")
    assert main(["conversation", "--thread", str(empty), "--fake", "--out", str(tmp_path / "s")]) == 1
    assert main(["conversation", "--thread", str(empty), "--fake", "--no-voice", "--voice-profile", str(tmp_path / "x"), "--out", str(tmp_path / "s")]) == 1


# ---------------------------------------------------------------------------------------------- transient failures
# Live run 2 died in the meeting-prep stage with an empty error text and no retry. The same prep note succeeded when it was
# replayed, so the failure was a dropped or stalled stream: the SDK retries only the request that opens a stream, and the raw
# transport error it leaves (often with an empty message) was wrapped without its type.


def _no_sleep(monkeypatch):
    slept: list[float] = []

    async def fake_sleep(s):
        slept.append(s)

    monkeypatch.setattr("verse_brain.prep.conversation_model.asyncio.sleep", fake_sleep)
    return slept


def test_retry_transient_retries_a_dropped_stream_and_names_the_error(monkeypatch):
    import httpx2
    from verse_brain.prep.conversation_model import retry_transient

    slept = _no_sleep(monkeypatch)
    calls, logs = [], []

    async def flaky():
        calls.append(1)
        if len(calls) < 3:
            raise httpx2.ReadTimeout("")  # the shape of the failure: a transport error with an empty message
        return "ok"

    assert asyncio.run(retry_transient(flaky, log=logs.append)) == "ok"
    assert len(calls) == 3 and slept == [5.0, 10.0]
    assert logs[0].startswith("warning: ReadTimeout: ") and "ReadTimeout('')" in logs[0] and "(2/3)" in logs[0]


def test_retry_transient_gives_up_after_the_last_attempt_and_skips_other_errors(monkeypatch):
    import httpx2
    from verse_brain.prep.conversation_model import retry_transient

    _no_sleep(monkeypatch)
    n = []

    async def always():
        n.append(1)
        raise httpx2.RemoteProtocolError("peer closed connection")

    with pytest.raises(httpx2.RemoteProtocolError):
        asyncio.run(retry_transient(always, log=lambda m: None))
    assert len(n) == 3

    m = []

    async def bug():
        m.append(1)
        raise ValueError("a real bug is not retried")

    with pytest.raises(ValueError):
        asyncio.run(retry_transient(bug, log=lambda m_: None))
    assert len(m) == 1


def test_meeting_prep_call_survives_a_dropped_stream(monkeypatch):
    import httpx2
    from verse_brain.prep.conversation_model import AnthropicConversationModel
    from verse_brain.prep.model import AnthropicPrepModel

    _no_sleep(monkeypatch)
    tries = []

    async def flaky_generate(self, system, user, max_tokens):
        tries.append(1)
        if len(tries) == 1:
            raise httpx2.ReadError("")
        return ModelOutput("@FACT\n", Usage(input=1, output=1), "end_turn")

    monkeypatch.setattr(AnthropicPrepModel, "generate", flaky_generate)
    model = AnthropicConversationModel("sk-ant-test-not-a-real-key")
    out = asyncio.run(model.generate("sys", "user", 100))
    assert out.text == "@FACT\n" and len(tries) == 2


def test_research_turn_survives_a_dropped_stream(monkeypatch):
    import httpx2
    from types import SimpleNamespace
    from verse_brain.prep.conversation_model import AnthropicConversationModel

    _no_sleep(monkeypatch)
    turns = []

    async def flaky_turn(self, system, messages, tools, max_tokens):
        turns.append([t["name"] for t in tools])
        if len(turns) == 1:
            raise httpx2.RemoteProtocolError("")
        usage = SimpleNamespace(input_tokens=10, output_tokens=5, cache_read_input_tokens=0, cache_creation_input_tokens=0,
                                server_tool_use=SimpleNamespace(web_search_requests=1, web_fetch_requests=1))
        content = [{"type": "server_tool_use", "name": "web_fetch", "input": {"url": ABOUT}},
                   {"type": "web_fetch_tool_result", "content": {"type": "web_fetch_result", "url": ABOUT, "content": {
                       "type": "document", "title": "About", "source": {"type": "text", "data": "page text"}}}},
                   {"type": "text", "text": RESEARCH_TEXT}]
        return SimpleNamespace(usage=usage, stop_reason="end_turn", content=content)

    monkeypatch.setattr(AnthropicConversationModel, "_stream_turn", flaky_turn)
    out = asyncio.run(AnthropicConversationModel("sk-ant-test-not-a-real-key").research("sys", "user", 8, 5, 1000))
    assert turns == [["web_search", "web_fetch"], ["web_search", "web_fetch"]]
    assert out.searches == 1 and out.fetch_count == 1 and out.pages[ABOUT].fetched and out.pages[ABOUT].text == "page text"
    assert out.usage.input == 10 and "@FACT" in out.text


def test_a_failure_with_an_empty_message_still_names_its_type(tmp_path):
    class Boom(FakeConversationPrepModel):
        async def generate(self, system, user, max_tokens):
            raise RuntimeError()  # str(e) == ""

    with pytest.raises(ConversationError, match=r"RuntimeError: RuntimeError\(\) \(the research is kept in"):
        asyncio.run(run_async(THREAD, out=tmp_path, model=Scripted(research_text=RESEARCH_TEXT, pages=PAGES),
                              prep_model=Boom(), now=NOW))


def test_cli_fetch_cap_is_bounded(tmp_path, capsys):
    for bad in ("6", "-1"):
        with pytest.raises(SystemExit):
            main(["conversation", "--thread", str(FIX / "thread_fictional.md"), "--fake", "--max-fetches", bad,
                  "--out", str(tmp_path / "s")])
    capsys.readouterr()
    assert main(["conversation", "--thread", str(FIX / "thread_fictional.md"), "--fake", "--no-voice", "--max-fetches", "0",
                 "--out", str(tmp_path / "s")]) == 0


def test_a_fetched_page_wins_over_the_same_url_from_a_search_result():
    """Live run 3: the model fetched `https://site.io` and a search returned `https://site.io/`; the evidence check must use
    the fetched text, not skip because the search copy came last."""
    fetched = Page("https://site.io", "Home", text="We run grid scans every month.", fetched=True)
    searched = Page("https://site.io/", "Home")
    raw = [{"topic": "product", "text": "Grid scans run monthly.", "url": "https://site.io/", "evidence": "grid scans every month"},
           {"topic": "product", "text": "It sells drones.", "url": "https://site.io/", "evidence": "we sell drones"}]
    for pages in ({fetched.url: fetched, searched.url: searched}, {searched.url: searched, fetched.url: fetched}):
        a, b = verify_facts(raw, ResearchOutput("", dict(pages)))
        assert (a.status, a.check) == ("sourced", "quote found on the fetched page")
        assert b.status == "unverified" and "not on the fetched page" in b.reason
