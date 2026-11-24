"""The review's tuning on real-call shapes, with fictional rows: which rows make a question -> answer pair (real questions,
split questions, acknowledgements, rolling transcript rows), one verdict with one reason, the confirmed-source pool the
improved answers draw on, the name rule on transcribed names, and a session run again replacing its earlier contribution.
Temp dirs, a fake client, no network; no model text is compared."""

import asyncio
import json

import pytest

from verse_brain.memory.index import session_key
from verse_brain.persona.extract import Confirmed, RawItem, names_not_in_row, verify_items
from verse_brain.persona.review import (RawReview, SourceBook, asks, build_pairs, me_line_text, render_note, verify_reviews)
from verse_brain.persona.rows import PRow, SessionRows, is_backchannel, merge_rows, owner_turns
from verse_brain.persona.runtime import update_session
from verse_brain.persona.store import PERSONA_MD, PersonaStore
from verse_brain.runtime.ask import FakeAskClient, words_script


def R(role, text, kind="", stamp=None, lang="en"):
    R.n += 1
    return PRow(stamp or f"{R.n // 60}:{R.n % 60:02d}", role, text, f"t{R.n}", lang, "own" if role == "me" else None, 0.0, kind)


R.n = 0


def pairs_of(*rows):
    return build_pairs(SessionRows("x", list(rows)))


# ---------------------------------------------------------------- rows of a rolling transcript
@pytest.mark.parametrize("rows,merged", [
    (["I built the billing service", "I built the billing service in Go for the payments team"],
     "I built the billing service in Go for the payments team"),                     # a longer take replaces the first
    (["we moved the batch jobs to the new", "to the new scheduler last spring"],
     "we moved the batch jobs to the new scheduler last spring"),                    # an overlap is joined once
    (["the whole team signed off", "team signed off"], "the whole team signed off"),  # already said
    (["yes", "and then we shipped it"], "yes and then we shipped it"),
    ([], ""),
])
def test_merge_rows_counts_each_spoken_word_once(rows, merged):
    assert merge_rows(rows) == merged


@pytest.mark.parametrize("text,ack", [("yeah", True), ("okay okay okay", True), ("mhm", True), ("of course", True),
                                      ("esatto", True), ("tamam", True), ("exactly exactly", True),
                                      ("oh in her spine", False), ("actually I", False), ("we are fast paced", False)])
def test_backchannel(text, ack):
    assert is_backchannel(text) is ack


@pytest.mark.parametrize("text,lang,q", [
    ("So tell me a little bit about your last project", "en", True),
    ("um how do you stay on top of new tools", "en", True),
    ("and uh I want to understand what drives you", "en", True),
    ("can you send over two references", "en", True),
    ("Is there anything you would change", "en", True),
    ("What did the team ship", "en", True),
    ("it ships next week, right?", "en", True),
    ("is not the best fit for everyone if you need very clear structure", "en", False),   # a half-sentence, not "is it"
    ("can coordinate with the designers and the sales people", "en", False),
    ("we are a small team and things move fast", "en", False),
    ("Mi racconti un progetto di cui sei fiero", "it", True),
    ("mi piace molto il vostro prodotto", "it", False),          # "mi" is a pronoun in Italian, not a question particle
    ("En son projeni anlatır mısın", "tr", True),
    ("Bu rol uzaktan mı", "tr", True),
])
def test_what_asks_him_something(text, lang, q):
    assert asks(text, lang) is q


# ---------------------------------------------------------------- pairs
def test_statements_and_monologue_fragments_are_not_pairs_even_when_the_transcript_says_question():
    ps = pairs_of(R("other", "we are a small team and the hours are long", "statement"),
                  R("other", "is not the best fit for everyone if you need clear processes", "question"),   # live kind: wrong
                  R("me", "yes", "fragment"),
                  R("other", "and our investors expect a lot", "statement"),
                  R("me", "I like pressure because I built my last product alone at night", "statement"))
    assert ps == []


def test_a_question_split_across_rows_is_one_pair_and_his_answer_runs_across_their_acknowledgements():
    ps = pairs_of(R("other", "so tell me a bit about you", "question"),
                  R("other", "what is it like when you fall in love with a product", "question"),
                  R("me", "actually I", "fragment"),                                  # an interjection
                  R("other", "the thing that gets you out of bed every morning", "statement"),   # the question goes on
                  R("me", "honestly I like building things and my side project shows it best", "statement"),
                  R("other", "okay okay", "fragment"),                                # acknowledgement: the answer goes on
                  R("me", "I ship a release every week and talk to the runners who use it", "statement"),
                  R("other", "nice", "fragment"),
                  R("me", "that loop keeps me going", "statement"),
                  R("other", "Let me tell you about our roadmap for next year then", "statement"),   # ends his answer
                  R("me", "sure", "fragment"))
    [p] = ps
    assert len(p.question_rows) == 3 and len(p.answer_rows) == 4
    assert "release every week" in p.answer_text and "sure" not in p.answer_text
    assert p.question_text.startswith("tell me a bit about you")                     # filler gone


def test_his_short_reply_then_their_next_question_makes_two_pairs():
    ps = pairs_of(R("other", "What is your notice period?", "question"), R("me", "It depends really.", "statement"),
                  R("other", "How big was your team?", "question"), R("me", "About twelve people in two squads.", "statement"))
    assert [len(p.answer_rows) for p in ps] == [1, 1] and [p.id for p in ps] == ["q1", "q2"]


def test_a_question_they_talk_past_lapses_and_one_he_only_acknowledged_is_no_pair():
    ps = pairs_of(R("other", "do you know our product", "question"),
                  *[R("other", f"we built the first version in {y} with a small crew of engineers", "statement")
                    for y in ("spring", "summer", "autumn", "winter", "march")],
                  R("me", "I have been building payment tools for six years now", "statement"),
                  R("other", "Are you fine with a start in January?", "question"),
                  R("me", "yeah", "fragment"),
                  R("other", "great so the next step is a call with the founders", "statement"))
    assert ps == []


# ---------------------------------------------------------------- one verdict, one reason
def _session():
    rows = [R("other", "What did you build at your last job?", "question"),
            R("me", "I built the billing service and cut the monthly close from five days to two", "statement"),
            R("other", "Why do you want to leave?", "question"),
            R("me", "well you know things are things and it is what it is I guess so", "statement"),
            R("other", "How do you handle on-call?", "question"),
            R("me", "We rotate weekly and I wrote the runbooks for the payment alerts myself", "statement"),
            R("other", "Can you start soon?", "question"),
            R("me", "Yes I can start in two weeks after my notice", "statement")]
    return SessionRows("x", rows)


def test_the_labels_follow_the_one_verdict_and_a_weak_verdict_needs_one_of_the_four_reasons():
    s = _session()
    ps = build_pairs(s)
    raw = [RawReview("q1", question="What did you build at your last job?", verdict="strong", note="named the service and a figure"),
           RawReview("q2", question="Why do you want to leave?", verdict="weak", reason="missed_question", note="no reason given"),
           RawReview("q3", question="How do you handle on-call?", verdict="weak", reason="", note="long"),   # no reason: fine
           RawReview("q4", question="Can you start soon?", verdict="fine", reason="trailed_off", note="direct")]
    rv = verify_reviews(raw, ps, SourceBook(), s, Confirmed([]))
    got = {p.pair: p for p in rv.pairs}
    assert (got["q1"].spoken, got["q1"].reasons, got["q1"].specific) == ("strong", [], "specific")
    assert (got["q2"].spoken, got["q2"].reasons, got["q2"].answered) == ("weak", ["not_answered"], "no")
    assert (got["q3"].spoken, got["q3"].reasons, got["q3"].length) == ("ok", [], "ok") and rv.dropped["weak_reason"] == 1
    assert (got["q4"].spoken, got["q4"].reasons, got["q4"].length) == ("ok", [], "ok")      # a stray reason is ignored
    assert rv.counts()["fine"] == 2 and rv.counts()["weak"] == 1 and rv.counts()["strong"] == 1
    assert got["q2"].note == "no reason given"


def test_a_pair_the_model_left_out_is_never_weak_and_never_listed(tmp_path):
    s = _session()
    rv = verify_reviews([RawReview("q1", verdict="strong", question="What did you build at your last job?")], build_pairs(s),
                        SourceBook(), s, Confirmed([]))
    assert {p.spoken for p in rv.pairs[1:]} == {"unreviewed"} and rv.counts()["weak"] == 0
    store = PersonaStore(tmp_path / "Verse Persona", tmp_path / "state.json")
    store.state["reviews"] = {"x": {"records": [
        {"question": "What did you build at your last job?", "q_stamp": "0:01", "spoken": "strong", "note": "a figure"},
        {"question": "How do you handle on-call?", "q_stamp": "0:05", "spoken": "ok"},
        {"question": "raw half sentence of theirs", "q_stamp": "0:09", "spoken": "unreviewed"}]}}
    note, _ = render_note(store, "x", "sabcdef", "2026-11-01", [])
    went, fine = note.split("## Went well")[1].split("## Fine")
    assert "What did you build at your last job?" in went and "why: a figure" in went
    assert "How do you handle on-call?" in fine.split("## Weak answers")[0]
    assert "raw half sentence" not in note


# ---------------------------------------------------------------- the confirmed sources
ME = """## WHO I AM
[m101] Backend engineer who built the billing service at Northwind | file:career.md#L3
- [m102] Leads the payments guild | owner

## NUMBERS
[m401] monthly close at Northwind | 5 days to 2 days | file:career.md#L9
"""
NOTES = "I want a team that ships every week.\nShort\n# heading\n- I never relocate for a job.\n"


@pytest.mark.parametrize("body,text", [
    ("Backend engineer at Northwind | file:career.md#L3", "Backend engineer at Northwind"),
    ("Leads the payments guild | owner", "Leads the payments guild"),
    ("monthly close | 5 days to 2 days | file:career.md#L9", "monthly close | 5 days to 2 days"),
    ("Kept as it is | Two Fields", "Kept as it is | Two Fields"),
])
def test_a_me_line_loses_only_its_provenance_field(body, text):
    assert me_line_text(body) == text


def test_the_source_pool_holds_the_me_layer_his_notes_and_his_earlier_answers_his_own_layer_first():
    book = SourceBook.build([ME, NOTES])
    assert book.lines["m101"] == "Backend engineer who built the billing service at Northwind"
    assert book.lines["m102"] == "Leads the payments guild" and book.lines["m401"] == "monthly close at Northwind | 5 days to 2 days"
    assert list(v for k, v in book.lines.items() if k.startswith("n")) == ["I want a team that ships every week.",
                                                                           "I never relocate for a job."]
    reviews = {
        "older": {"date": "2026-10-01", "records": [
            {"question": "How do you handle on-call?", "spoken": "strong", "evidence": "own",
             "answer_text": "We rotate weekly and I wrote the runbooks for the payment alerts."},
            {"question": "Why do you want to leave?", "spoken": "weak", "answer_text": "things are things"},     # weak: no
            {"question": "What is your stack?", "spoken": "ok", "evidence": "read", "answer_text": "the card read out"},  # read: no
            {"question": "Do you like sailing?", "spoken": "ok", "evidence": "own", "answer_text": "I sail on weekends."}]},
        "this": {"date": "2026-11-01", "records": [
            {"question": "How do you handle on-call?", "spoken": "strong", "answer_text": "this call's own answer"}]}}
    focus = "on-call rotation runbooks alerts"
    assert book.add_earlier_answers(reviews, "this", focus) == 2
    assert book.lines["a001"].startswith("How do you handle on-call?: We rotate weekly")       # most relevant first
    assert book.lines["a002"] == "Do you like sailing?: I sail on weekends."
    for i in range(30):
        book.add(f"g{i:03d}", f"seed fact number {i} about unrelated cooking recipes and gardens")
    book.add("g900", "on-call runbooks for payment alerts")
    book.focus = focus
    order = book.ordered()
    assert order[:5] == ["m101", "m102", "m401", "n001", "n002"]          # his own layer first, in file order
    assert order.index("g900") < order.index("g000") and order.index("a001") < order.index("g000")
    small = book.block(max_tokens=120)
    assert "[m101]" in small and "[g000]" not in small                    # the budget cuts the least relevant first


# ---------------------------------------------------------------- the name rule
@pytest.mark.parametrize("text,row,extra,missing", [
    ("I shipped Northwind's billing.", "i shipped the north wind billing myself", set(), set()),       # split by recognition
    ("I built it with OpenAI models.", "we built it with open ai models", set(), set()),
    ("I moved to Kubernetes last year.", "we moved to kubernetis last year", set(), set()),            # misheard spelling
    ("We used the Stripe-Connect flow.", "we used the stripe connect flow", set(), set()),             # hyphenated
    ("I worked with Globex on it.", "i worked with a big client on it", set(), {"globex"}),            # said nowhere
    ("I worked with Globex on it.", "i worked with a big client on it", {"globex"}, set()),            # a confirmed source
    ("I started in March.", "i started in match week", set(), {"march"}),                              # months: exact only
    ("You learn it by shipping, I said.", "you learn it by shipping", set(), set()),                   # a pronoun
])
def test_names_said_in_the_row_however_transcribed_pass_and_names_said_nowhere_are_dropped(text, row, extra, missing):
    assert names_not_in_row(text, row, extra) == missing


def test_a_name_said_in_the_same_turn_but_another_row_passes_and_one_across_their_statement_does_not():
    key = session_key("turns", set())
    rows = [PRow("0:10", "me", "my last project was the exam pipeline at the university of Arden", "a", "en", "own"),
            PRow("0:14", "me", "and then we added a vector database for the chatbot answers", "b", "en", "own"),
            PRow("0:15", "other", "mhm", "c", "en"),
            PRow("0:18", "me", "the chatbot answers questions about the courses all day", "d", "en", "own"),
            PRow("0:30", "other", "Our company works with Globex on similar things today", "e", "en"),
            PRow("0:40", "me", "we did a lot of retrieval work over the courses as well", "f", "en", "own")]
    s = SessionRows("turns", rows)
    assert owner_turns(rows)[3] == owner_turns(rows)[0] and owner_turns(rows)[5] != owner_turns(rows)[0]
    same_turn = RawItem("claim", "chatbot", "I built the chatbot for the university of Arden.",
                        "the chatbot answers questions about the courses", f"[{key} 0:18]")
    other_turn = RawItem("claim", "retrieval", "I did retrieval work for Globex over the courses.",
                         "retrieval work over the courses", f"[{key} 0:40]")
    v = verify_items([same_turn, other_turn], key, s, Confirmed([]))
    assert [i.topic for i in v.items] == ["chatbot"] and v.dropped["name"] == 1


# ---------------------------------------------------------------- a session run again replaces its earlier contribution
def test_a_session_run_again_replaces_its_unedited_entries_and_keeps_the_owners_edit(tmp_path):
    d = tmp_path / "sessions" / "zeta-call"
    d.mkdir(parents=True)
    T = 1796000000.0
    rows = [("r1", "remote", "What did you build at your last job?", 3.0),
            ("m1", "me", "I built the billing service and we cut the monthly close from five days to two days", 9.0),
            ("r2", "remote", "How do you like to work?", 14.0),
            ("m2", "me", "I like small teams that ship every week and I write the runbooks myself", 20.0)]
    (d / "transcript.jsonl").write_text("".join(json.dumps({"turn_id": t, "speaker": sp, "text": x, "t_audio_end": e,
                                                           "run_start": T, "t_wall": T + e}) + "\n" for t, sp, x, e in rows))
    key = session_key("zeta-call", set())
    runs = [
        {"items": [{"kind": "claim", "topic": "billing service", "text": "I built the billing service.",
                    "quote": "I built the billing service", "cite": f"[{key} 0:09]"},
                   {"kind": "preference", "topic": "team size", "text": "I like small teams that ship every week.",
                    "quote": "I like small teams that ship every week", "cite": f"[{key} 0:20]"},
                   {"kind": "style", "topic": "runbooks", "text": "I write the runbooks myself.",
                    "quote": "I write the runbooks myself", "cite": f"[{key} 0:20]"}],
         "reviews": [{"pair": "q1", "verdict": "strong", "question": "What did you build at your last job?", "why": "a figure"}]},
        {"items": [{"kind": "claim", "topic": "monthly close", "text": "We cut the monthly close to two days.",
                    "quote": "we cut the monthly close from five days to two days", "cite": f"[{key} 0:09]"}],
         "reviews": [{"pair": "q1", "verdict": "fine", "question": "What did you build at your last job?", "why": "clear"}]}]
    n = {"i": 0}

    def responder(request, _):
        ans = runs[min(n["i"], 1)]
        n["i"] += 1
        return words_script(json.dumps(ans), model=request["model"])

    store = PersonaStore(tmp_path / "vault" / "Verse Persona", tmp_path / "state.json")
    (tmp_path / "vault").mkdir()

    def run(**kw):
        with store.locked():
            store.load()
            return asyncio.run(update_session(store, d, FakeAskClient(responder), owner="Sam Lee", me_texts=[], **kw))

    first = run()
    assert len(first.new) == 3 and first.review["adopted"] == 1
    st = json.loads(store.state_path.read_text())
    ids = {e["topic"]: e["id"] for e in st["entries"].values() if e["kind"] in ("claim", "preference", "style")}
    md = store.dir / PERSONA_MD
    md.write_text(md.read_text().replace("I like small teams that ship every week.", "Small teams, weekly releases."))
    second = run(force=True)
    assert len(second.new) == 1 and sorted(second.retracted) == sorted([ids["billing service"], ids["runbooks"],
                                                                        *[i for i in st["entries"] if i.startswith("i")]])
    st = json.loads(store.state_path.read_text())
    learned = {e["topic"]: e for e in st["entries"].values() if e["kind"] in ("claim", "preference", "style")}
    assert set(learned) == {"team size", "monthly close"}                   # no duplicates, the edit stays
    assert "Small teams, weekly releases." in learned["team size"]["edited"]
    text = md.read_text()
    assert f"[{ids['billing service']}]" not in text and f"[{ids['runbooks']}]" not in text
    assert "Small teams, weekly releases." in text and "monthly close" in text
    assert not st.get("deleted_quotes")                                     # a replaced entry is no owner deletion
    third = run(force=True)                                                 # the same answer again: nothing moves
    assert third.retracted == [] and third.repeats == 1
