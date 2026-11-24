"""persona/review.py: the after-call review. Pure decisions as table tests (verdict, action, grounding, wording, marks, recurring
topics), then the plumbing end to end with a fake client: the review rides in the one request, weak answers are not learned,
better answers enter the persona and the compiled bank ahead of older entries, BAD marks demote the card's bank entry, the Review
note, owner edits and rejections, and the CLI backfill (dry run cost, seeding). Fictional fixtures, temp dirs, no network."""

import asyncio
import copy
import json
import re
import logging
import shutil
from pathlib import Path

import pytest

from verse_brain.memory.index import session_key
from verse_brain.persona import __main__ as cli
from verse_brain.persona.compile import build, compile_async, import_general_core
from verse_brain.persona.extract import Confirmed, system_text
from verse_brain.persona.review import (REVIEW_SYSTEM, RawReview, SourceBook, build_pairs, choose_action, ground_lines,
                                        note_rel, note_text, parse_reviews, recurring_weak, render_note, spoken_verdict, verbatim,
                                        verify_reviews, wording_ok)
from verse_brain.persona.rows import Mark, final_marks, load_session_rows, read_marks
from verse_brain.persona.runtime import plan_session, update_session
from verse_brain.persona.store import PERSONA_MD, PersonaStore, same_question
from verse_brain.runtime.ask import FakeAskClient, words_script

FIX = Path(__file__).parent / "fixtures" / "persona"
KI, KH = session_key("initech-screen", set()), session_key("hooli-call", set())
OWNER = "Alex Rivera"


# ---------------------------------------------------------------- the fake model's answers
def initech_answer() -> dict:
    return {
        "items": [
            {"kind": "claim", "topic": "mentoring", "text": "I mentor the juniors on my team every week.",
             "quote": "I mentor the juniors on my team every week", "cite": f"[{KI} 0:16]"},
            {"kind": "style", "topic": "general answers", "text": "I talk about my team in general terms.",
             "quote": "a pretty big team, a lot of people", "cite": f"[{KI} 0:42]"},          # a weak answer: never learned
        ],
        "reviews": [
            {"pair": "q1", "topic": "introduction", "question": "Tell me about yourself.", "verdict": "strong", "reason": "",
             "contradicts": "", "why": "clear and personal",
             "wording": "I am a data engineer who builds platforms people actually enjoy using, and I mentor the juniors on my "
                        "team every week."},
            {"pair": "q2", "topic": "notice period", "question": "What is your notice period?", "verdict": "weak",
             "reason": "nothing_specific", "contradicts": "", "why": "no figure",
             "improved": {"lines": [{"text": "My notice period is 30 days, and it is negotiable.", "src": ["g002"]}]}},
            {"pair": "q3", "topic": "team size", "question": "How big was your team?", "verdict": "weak",
             "reason": "nothing_specific", "contradicts": "", "why": "no number",
             "improved": {"lines": [{"text": "I grew the platform team at Northwind to 12 engineers.", "src": ["m401"]}]}},
            {"pair": "q4", "topic": "reason for leaving", "question": "Why do you want to leave your current job?",
             "verdict": "weak", "reason": "nothing_specific", "contradicts": "", "why": "generic"},
            {"pair": "q5", "topic": "engineers led", "question": "How many engineers did you lead?", "verdict": "weak",
             "reason": "contradicts_source", "contradicts": "m401", "why": "wrong figure",
             "improved": {"lines": [{"text": "I led a platform team of 12 engineers at Northwind.", "src": ["m401"]}]}},
            {"pair": "q6", "topic": "biggest achievement", "question": "What is your biggest achievement?", "verdict": "weak",
             "reason": "nothing_specific", "contradicts": "", "why": "no example",
             "improved": {"lines": [{"text": "I cut infrastructure costs by 40% at Northwind.", "src": ["m401"]}]}},
            {"pair": "m1", "topic": "five year plan", "question": "Where do you see yourself in five years?",
             "verdict": "weak", "reason": "missed_question", "contradicts": "", "why": "not asked"},
            {"pair": "q99", "topic": "ghost", "question": "?", "verdict": "fine"},
        ],
    }


def hooli_answer() -> dict:
    return {"items": [],
            "reviews": [
                {"pair": "q1", "topic": "notice period", "question": "What is your notice period?", "verdict": "weak",
                 "reason": "missed_question", "contradicts": "", "why": "no figure again",
                 "improved": {"lines": [{"text": "My notice period is 30 days.", "src": ["g002"]}]}},
                {"pair": "q2", "topic": "mentoring", "question": "Do you mentor people?", "verdict": "fine", "reason": "",
                 "contradicts": "", "why": "concrete"}]}


def responder(request, n):
    user = request["messages"][0]["content"]
    ans = initech_answer() if f"[{KI} " in user else hooli_answer()
    return words_script(json.dumps(ans), model=request["model"])


@pytest.fixture
def env(tmp_path):
    sessions = tmp_path / "sessions"
    shutil.copytree(FIX / "review_sessions", sessions)
    shutil.copytree(FIX / "sessions" / "general-core", sessions / "general-core")
    vault = tmp_path / "vault"
    vault.mkdir()
    store = PersonaStore(vault / "Verse Persona", tmp_path / "profile" / "persona.meta.json")
    return {"tmp": tmp_path, "sessions": sessions, "store": store, "me": [(FIX / "me.md").read_text()]}


def run(coro):
    return asyncio.run(coro)


def fresh(env) -> PersonaStore:
    s = PersonaStore(env["store"].dir, env["store"].state_path)
    s.load()
    return s


async def update(env, name, client, seed=True, **kw):
    s = env["store"]
    with s.locked():
        s.load()
        if seed and not s.state.get("seed"):
            import_general_core(s, env["sessions"] / "general-core")
        return await update_session(s, env["sessions"] / name, client, owner=OWNER, me_texts=env["me"], **kw)


def better(store, kind=None):
    return [e for e in store.state["entries"].values() if e["kind"] in ("improved", "adopted", "kept")
            and (kind is None or e["kind"] == kind)]


# ---------------------------------------------------------------- marks (pure)
@pytest.mark.parametrize("seq,expect", [
    ([("good", 1.0)], "good"),
    ([("good", 1.0), ("bad", 2.0)], "bad"),
    ([("bad", 1.0), ("cleared", 2.0)], None),
    ([("bad", 1.0), ("cleared", 2.0), ("good", 3.0)], "good"),
    ([("good", 3.0), ("bad", 2.0)], "good"),          # the latest by time wins, not the latest line
    ([("bad", 2.0), ("good", 2.0)], "good"),          # same time: the later line
])
def test_the_last_mark_on_a_card_wins(seq, expect):
    marks = [Mark("F-1", m, t) for m, t in seq]
    got = final_marks(marks).get("F-1")
    assert (got.mark if got else None) == expect


def test_mark_lines_are_read_by_the_contract_and_bad_lines_skipped():
    events = [{"t": 5.0, "ev": "card_mark", "card": "F-r2", "mark": "bad", "turn": "r2", "question": " What  is it? "},
              {"t": 6.0, "ev": "card_mark", "card": "F-r3", "mark": "meh"},          # unknown mark
              {"t": 7.0, "ev": "card_mark", "mark": "good"},                          # no card
              {"ev": "card_mark", "card": "F-r4", "mark": "good"},                    # no time
              {"t": 8.0, "ev": "card_mark", "card": "F-r5", "mark": "cleared"}]
    assert read_marks(events) == [Mark("F-r2", "bad", 5.0, "r2", "What is it?"), Mark("F-r5", "cleared", 8.0)]


def test_pairs_carry_their_card_and_last_mark_and_an_orphan_mark_becomes_a_pair():
    s = load_session_rows(FIX / "review_sessions" / "initech-screen")
    pairs = {p.id: p for p in build_pairs(s)}
    assert list(pairs) == ["q1", "q2", "q3", "q4", "q5", "q6", "m1"]
    assert pairs["q1"].mark is None and pairs["q1"].card.id == "F-r1"            # bad, then cleared
    assert pairs["q4"].mark.mark == "good"                                       # good, bad, good: the last wins
    assert pairs["q2"].a_stamps == ["0:25"] and pairs["q2"].q_stamp == "0:22"
    assert pairs["m1"].hint == "Where do you see yourself in five years?" and not pairs["m1"].answer_rows
    assert pairs["q6"].card is None
    # a cut request reviews only the rows it carries; a mark whose question was cut stands on the question it names
    cut = build_pairs(s, upto=4)
    assert [p.id for p in cut] == ["q1", "q2", "m1", "m2"] and cut[2].hint == "Why do you want to leave your current job?"


def test_a_question_followed_only_by_unlabelled_room_rows_is_not_reviewed():
    s = load_session_rows(FIX / "sessions" / "globex-call")
    pairs = build_pairs(s)
    assert [p.q_stamp for p in pairs] == ["0:08"]          # the salary question, answered by a relabelled row
    assert pairs[0].a_stamps == ["0:15", "0:24"]


# ---------------------------------------------------------------- decisions (pure)
@pytest.mark.parametrize("args,verdict,reasons", [
    # (has_answer, reviewed, verdict, reason, contradiction verified) -> one verdict, its one reason the only label
    ((False, True, "strong", "", False), "none", []),
    ((True, False, "", "", False), "unreviewed", []),             # the model left it out (no real question): never weak
    ((True, True, "", "", False), "unreviewed", []),
    ((True, True, "fine", "", False), "ok", []),
    ((True, True, "fine", "nothing_specific", False), "ok", []),  # a stray reason never turns a fine answer weak
    ((True, True, "strong", "", False), "strong", []),
    ((True, True, "weak", "missed_question", False), "weak", ["not_answered"]),
    ((True, True, "weak", "nothing_specific", False), "weak", ["vague"]),
    ((True, True, "weak", "trailed_off", False), "weak", ["trailed_off"]),
    ((True, True, "weak", "contradicts_source", True), "weak", ["contradiction"]),
    ((True, True, "weak", "contradicts_source", False), "ok", []),  # code could not confirm the contradiction
    ((True, True, "weak", "", False), "ok", []),                    # weak needs one of the four reasons
])
def test_spoken_verdict(args, verdict, reasons):
    assert spoken_verdict(*args) == (verdict, reasons)


@pytest.mark.parametrize("spoken,mark,rejected,card,action", [
    ("weak", "good", False, True, "kept"),
    ("strong", "", False, True, "adopted"),
    ("strong", "bad", False, True, "adopted"),       # his words beat the card he marked bad
    ("weak", "", False, True, "improve"),
    ("ok", "bad", False, True, "improve"),
    ("none", "bad", False, True, "improve"),
    ("weak", "", True, True, "rejected"),
    ("ok", "", False, True, "none"),
    ("unreviewed", "", False, False, "none"),
    ("weak", "good", False, False, "improve"),       # a GOOD mark needs a card to keep
])
def test_choose_action(spoken, mark, rejected, card, action):
    assert choose_action(spoken, mark, rejected, card) == action


BOOK = SourceBook({"m401": "engineers in the platform team at Northwind | 12 | owner",
                   "g002": "What is your notice period?: My notice period is 30 days. 30 days, negotiable.",
                   "k001": "I never relocate for a job."})


@pytest.mark.parametrize("lines,lang,why", [
    ([("I grew the platform team at Northwind to 12 engineers.", ["m401"])], "en", ""),
    ([("My notice period is 30 days.", ["g002"]), ("It is negotiable.", ["g002"])], "en", ""),
    ([], "en", "improved_empty"),
    ([("", ["m401"])], "en", "improved_empty"),
    ([("x " * 200, ["m401"])], "en", "improved_empty"),
    ([("a.", ["m401"])] * 5, "en", "improved_empty"),
    ([("I grew the platform team to 12 engineers.", [])], "en", "improved_source"),
    ([("I grew the platform team to 12 engineers.", ["m999"])], "en", "improved_source"),
    ([("I grew the platform team to 14 engineers.", ["m401"])], "en", "improved_number"),
    ([("My notice period is 30 days.", ["m401"])], "en", "improved_number"),        # the number is in another source
    ([("I grew the platform team at Globex to 12 engineers.", ["m401"])], "en", "improved_name"),
    ([("I love sailing and baking bread on weekends.", ["k001"])], "en", "improved_ungrounded"),
    ([("Ho fatto crescere il team a 12 ingegneri.", ["m401"])], "it", "improved_ungrounded"),   # it/tr: no English gloss
    ([("Ho fatto crescere il team a 15 ingegneri.", ["m401"])], "it", "improved_number"),
    # single digits and number words need their source too
    ([("I led the platform team at Northwind and cut deploy time by 5% in 3 months.", ["m401"])], "en", "improved_number"),
    ([("I led the platform team of 12 engineers at Northwind for three years.", ["m401"])], "en", "improved_number"),
    ([("I halved the platform team's on-call load at Northwind, cutting it by half.", ["m401"])], "en", "improved_number"),
    ([("My notice period is thirty days.", ["g002"])], "en", ""),                    # the word's value is in the source
])
def test_ground_lines(lines, lang, why):
    assert ground_lines(lines, BOOK, lang) == why


@pytest.mark.parametrize("text,gloss,lang,why", [
    ("Ho fatto crescere il team a 12 ingegneri a Northwind.", "I grew the platform team at Northwind to 12 engineers.", "it", ""),
    ("Ho guidato il team e ho ridotto i costi della metà in 6 mesi.", "I led the team and cut costs by half in 6 months.", "it",
     "improved_number"),                                                              # 6 and "metà" are not in m401
    ("Ho guidato il team e ho ridotto i costi della metà.", "I led the team and cut costs.", "it", "improved_number"),   # metà
    ("Ho guidato il team di piattaforma.", "I love sailing and baking bread on weekends.", "it", "improved_ungrounded"),
    ("Ho guidato il team a Northwind.", "", "it", "improved_ungrounded"),                                                # no gloss
    ("Ho guidato il team a Northwind.", "I led the platform team at Globex.", "it", "improved_name"),                   # the gloss names more
    ("Platform ekibini Northwind'de 12 mühendise çıkardım.", "I grew the platform team at Northwind to 12 engineers.", "tr", ""),
    ("Platform ekibini iki yılda 12 mühendise çıkardım.", "I grew the platform team to 12 engineers in two years.", "tr",
     "improved_number"),
])
def test_ground_lines_in_italian_and_turkish_take_the_english_test_through_their_gloss(text, gloss, lang, why):
    assert ground_lines([(text, ["m401"])], BOOK, lang, glosses=[gloss]) == why


def test_the_english_gloss_is_read_from_the_model_answer():
    [r] = parse_reviews(json.dumps({"reviews": [{"pair": "q1", "answered": "no", "improved": {"lines": [
        {"text": "Ho fatto crescere il team.", "src": ["m401"], "en": "I grew the team."}, {"text": "Poi.", "src": ["m401"]}]}}]}))
    assert r.improved_en == ["I grew the team.", ""]


def test_ground_lines_refuses_a_source_the_model_was_not_shown():
    assert ground_lines([("I grew the platform team to 12 engineers.", ["m401"])], BOOK, "en", offered={"g002"}) == "improved_source"


def test_his_wording_must_be_his_words_and_numbers():
    ans = "So basically I led the migration to the new billing system and we cut the run time from 40 minutes to 6."
    assert wording_ok("I led the migration to the new billing system and cut the run time from 40 minutes to 6.", ans, "en")
    assert not wording_ok("I led the migration and cut the run time from 45 minutes to 6.", ans, "en")      # a new number
    assert not wording_ok("I led the Stripe migration to the new billing system.", ans, "en")               # a new name
    assert not wording_ok("Our company pioneered revolutionary approaches to finance tooling worldwide.", ans, "en")
    assert not wording_ok("One. Two. Three. Four.", "One. Two. Three. Four.", "en")                           # over 3 sentences
    assert verbatim("First one here. Second one is longer. Third.", max_chars=30) == "First one here."


def test_verify_contradiction_needs_a_known_source_and_a_differing_figure():
    s = load_session_rows(FIX / "review_sessions" / "initech-screen")
    pairs = [p for p in build_pairs(s) if p.id in ("q5", "q1")]
    raw = [RawReview("q5", verdict="weak", reason="contradicts_source", contradicts="m401"),
           RawReview("q1", verdict="weak", reason="contradicts_source", contradicts="m401")]
    rv = verify_reviews(raw, pairs, BOOK, s, Confirmed([]))
    got = {p.pair: p for p in rv.pairs}
    assert got["q5"].contradicts == "m401" and got["q5"].reasons == ["contradiction"] and got["q5"].spoken == "weak"
    # no figure of his differs: no contradiction, and the verdict follows (fine, not weak with no reason)
    assert got["q1"].contradicts == "" and got["q1"].spoken == "ok" and got["q1"].reasons == []
    assert rv.dropped["contradiction"] == 1
    rv2 = verify_reviews([RawReview("q5", verdict="weak", reason="contradicts_source", contradicts="m777")], pairs, BOOK,
                         s, Confirmed([]))
    assert rv2.pairs[1].contradicts == "" and rv2.dropped["contradiction"] == 1 and rv2.pairs[1].spoken == "ok"


def test_a_read_card_is_never_better_than_the_card_and_a_good_card_with_an_unconfirmed_figure_is_not_banked(tmp_path):
    d = tmp_path / "s1"
    d.mkdir()
    T = 1795000000.0
    rows = [{"turn_id": "r1", "speaker": "remote", "text": "How fast was the pipeline?", "kind": "question", "t_audio_end": 3.0,
             "run_start": T, "t_wall": T + 3},
            {"turn_id": "m1", "speaker": "me", "text": "The nightly pipeline went from four hours down to forty minutes after the rewrite.",
             "kind": "statement", "t_audio_end": 9.0, "run_start": T, "t_wall": T + 9}]
    say = "The nightly pipeline went from four hours down to forty minutes after the rewrite, saving 85 percent."
    events = [{"t": T + 4, "ev": "card_done", "turn": "r1", "id": "F-r1", "say": say, "points": []},
              {"t": T + 5, "ev": "card_mark", "card": "F-r1", "mark": "good", "turn": "r1"}]
    (d / "transcript.jsonl").write_text("".join(json.dumps(x) + "\n" for x in rows))
    (d / "events.jsonl").write_text("".join(json.dumps(x) + "\n" for x in events))
    s = load_session_rows(d)
    assert s.rows[1].evidence == "read"
    pairs = build_pairs(s)
    rv = verify_reviews([RawReview("q1", verdict="strong")], pairs, BOOK, s, Confirmed([]))
    p = rv.pairs[0]
    assert p.spoken == "strong" and p.evidence == "read"
    assert p.action == "not_banked" and rv.dropped["kept_unconfirmed"] == 1           # 85 is the card's, not his
    # without the GOOD mark, a strong answer he read off the card is not banked as his wording
    unmarked = load_session_rows(d)
    unmarked.marks = []
    rv = verify_reviews([RawReview("q1", verdict="strong")], build_pairs(unmarked), BOOK, unmarked, Confirmed([]))
    assert rv.pairs[0].action == "none" and rv.dropped["adopted_read"] == 1 and not rv.pairs[0].wording
    rv = verify_reviews([], pairs, BOOK, s, Confirmed(["the rewrite saved 85 percent"]))
    assert rv.pairs[0].action == "kept"


def test_parse_reviews_tolerates_garbage_and_bad_enums():
    assert parse_reviews("not json") == [] and parse_reviews('{"items": []}') == []
    got = parse_reviews('```json\n{"items": [], "reviews": [{"pair": "q1", "verdict": "meh", "reason": "trailed_off", '
                        '"why": "drifted", "improved": {"lines": [{"text": "x", "src": ["m1", 3]}]}}, "junk", {"verdict": "fine"},'
                        '{"pair": "q2", "verdict": "Weak", "reason": "rambling"}]}\n```')
    assert len(got) == 2 and got[0].verdict == "" and got[0].reason == "trailed_off" and got[0].note == "drifted"
    assert got[0].improved == [("x", ["m1"])]
    assert got[1].verdict == "weak" and got[1].reason == ""               # "rambling" is not a reason any more


@pytest.mark.parametrize("reviews,expect", [
    ({}, []),
    ({"a": {"date": "2026-11-01", "records": [{"topic": "notice period", "question": "Notice?", "needs_rewrite": True}]}}, []),
    ({"a": {"date": "2026-11-01", "records": [{"topic": "notice period", "question": "What is your notice period?",
                                               "needs_rewrite": True, "date": "2026-11-01"}]},
      "b": {"date": "2026-11-08", "records": [{"topic": "notice period length", "question": "When can you start?",
                                               "needs_rewrite": True, "date": "2026-11-08"},
                                              {"topic": "salary", "question": "Salary?", "needs_rewrite": True,
                                               "date": "2026-11-08"}]}},
     [("notice period length", ["a", "b"])]),
    ({"a": {"date": "2026-11-01", "records": [{"topic": "team size", "needs_rewrite": True, "date": "2026-11-01"}]},
      "b": {"date": "2026-11-02", "records": [{"topic": "team size", "needs_rewrite": False, "date": "2026-11-02"}]}}, []),
])
def test_recurring_weak_topics(reviews, expect):
    assert [(r["topic"], r["sessions"]) for r in recurring_weak(reviews)] == expect


# ---------------------------------------------------------------- the request
def test_the_review_rides_in_the_one_request_and_a_call_without_pairs_sends_what_it_sent_before(env, tmp_path):
    book = SourceBook.build(env["me"])
    plan = plan_session(env["sessions"] / "initech-screen", [], OWNER, {}, None, book=book)
    assert plan.request.system == system_text(OWNER) + "\n\n" + REVIEW_SYSTEM
    user = plan.request.user
    assert "CONFIRMED SOURCES\n[m101]" in user and "[m401] engineers in the platform team at Northwind" in user
    assert f"q2 | question [{KI} 0:22] | answer [{KI} 0:25] | card F-r2: \"My notice period is 30 days." in user
    assert "| mark: BAD" in user and "q4" in user and "| mark: GOOD" in user
    assert "m1 | question (from his mark): \"Where do you see yourself in five years?\" | answer: none" in user
    assert plan.review_est["pairs"] == 7 and plan.review_est["extra_cost_usd"] > 0
    d = tmp_path / "statements"
    d.mkdir()
    (d / "transcript.jsonl").write_text(json.dumps({"turn_id": "m1", "speaker": "me", "text": "I only made a statement here today.",
                                                    "kind": "statement", "t_audio_end": 3.0}) + "\n")
    p = plan_session(d, [], OWNER, {}, None, book=book)
    assert p.request.system == system_text(OWNER) and "QUESTION PAIRS" not in p.request.user and p.pairs == []


# ---------------------------------------------------------------- end to end
def test_review_end_to_end_better_answers_bank_order_and_the_note(env, caplog):
    caplog.set_level(logging.DEBUG)
    client = FakeAskClient(responder)
    res = run(update(env, "initech-screen", client))
    rv = res.review
    assert rv["pairs"] == 7 and rv["reviewed"] == 7 and rv["marks"] == 3
    assert (rv["improved"], rv["adopted"], rv["kept"], rv["no_better"]) == (3, 1, 1, 2)
    assert rv["dropped"]["review_pair"] == 1 and rv["dropped"]["improved_number"] == 1
    # a weak answer is never learned: the style item cited in it is dropped, the strong answer's claim is kept
    assert res.dropped["weak"] == 1 and res.kept == 1
    s = fresh(env)
    kinds = sorted(e["kind"] for e in better(s))
    assert kinds == ["adopted", "improved", "improved", "improved", "kept"]
    imp = {e["question"]: e for e in better(s, "improved")}
    assert imp["What is your notice period?"]["opener"] == "My notice period is 30 days, and it is negotiable."
    assert imp["What is your notice period?"]["sources"][0]["id"] == "g002"
    assert "How big was your team at Northwind?" in imp["How big was your team?"]["paraphrases"]
    # the BAD mark took the notice-period card's bank entry (the seed) out of the bank
    seed = next(e for e in s.state["entries"].values() if e.get("origin") == "general-core bank b002")
    assert seed["status"] == "superseded" and seed["superseded"]["mark"] == "F-r2"
    assert rv["demoted"] == [seed["id"]]
    md = (s.dir / PERSONA_MD).read_text()
    assert "## BETTER ANSWERS" in md and "improved after" in md and "his words" in md and "kept card F-r4 (GOOD mark)" in md
    # the compiled bank: better answers first (GOOD card, then his words, then improved), older entries outranked
    rec = build(s)
    bank = rec["bank"]
    assert [b["rank"] for b in bank[:5]] == ["kept", "adopted", "improved", "improved", "improved"]
    assert bank[0]["opener"] == "I want a smaller company where I can own the product."
    assert bank[1]["question"] == "Tell me about yourself." and "Introduce yourself" in bank[1]["paraphrases"]["en"]
    assert rec["outranked"] == 1                          # the seed's "Tell me about yourself" gave way to his own words
    notice = next(b for b in bank if b["question"] == "What is your notice period?")
    assert notice["origin"].startswith("improved after ") and notice["improved_at"]
    assert sum(1 for b in bank if same_question([b["question"]], ["What is your notice period?"])) == 1
    # the Review note: sections, the better versions, the marks, the contradiction with his own profile
    note = (s.dir / rv["note"]).read_text()
    for head in ("## Weak in more than one call", "## Went well", "## Weak answers", "## Marks", "## Open contradictions"):
        assert head in note
    assert "Tell me about yourself." in note.split("## Weak answers")[0]
    weak_part = note.split("## Weak answers")[1].split("## Marks")[0]
    assert "My notice period is 30 days, and it is negotiable." in weak_part and "marked BAD" in weak_part
    assert "no better answer: the rewrite did not trace to confirmed sources" in weak_part
    assert "card F-r4: GOOD" in note and "card F-r2: BAD" in note and "card F-r1" not in note.split("## Marks")[1]
    assert "disagrees with [m401]" in note
    # logs: counts only
    logged = "\n".join(r.getMessage() for r in caplog.records)
    for secret in ("notice period", "Northwind", "30 days", "mentor", "five years"):
        assert secret not in logged


def test_a_topic_weak_in_two_calls_is_listed_first_and_the_newer_better_answer_supersedes(env):
    client = FakeAskClient(responder)
    run(update(env, "initech-screen", client))
    res = run(update(env, "hooli-call", client))
    assert res.review["improved"] == 1
    s = fresh(env)
    notice = [e for e in better(s, "improved") if same_question([e["question"]], ["What is your notice period?"])]
    assert len(notice) == 2 and sorted(e["status"] for e in notice) == ["live", "superseded"]
    assert next(e for e in notice if e["status"] == "live")["session"] == "hooli-call"
    note = (s.dir / res.review["note"]).read_text()
    first = note.split("## Weak in more than one call")[1].split("## Went well")[0]
    assert "notice period: weak in 2 calls" in first and "(this call too)" in first
    assert "(weak before too)" in note.split("## Weak answers")[1]
    assert "Do you mentor people?" in note.split("## Fine")[1].split("## Weak answers")[0]


def test_a_rejected_better_answer_is_remembered_and_never_regenerated(env):
    client = FakeAskClient(responder)
    run(update(env, "initech-screen", client))
    s = fresh(env)
    iid = next(e["id"] for e in better(s, "improved") if e["question"] == "How big was your team?")
    md = s.dir / PERSONA_MD
    md.write_text("\n".join(ln for ln in md.read_text().splitlines() if not ln.startswith(f"- [{iid}]")) + "\n")
    s = fresh(env)
    assert iid not in s.state["entries"] and s.state["rejected"][0]["question"] == "How big was your team?"
    assert s.is_rejected("How big was your team?", "team size")
    res = run(update(env, "initech-screen", client, force=True))
    assert res.review["rejected"] == 1
    s = fresh(env)
    assert not [e for e in better(s, "improved") if e["question"] == "How big was your team?"]
    assert "rejected before" in (s.dir / res.review["note"]).read_text()


def test_reject_written_in_the_note_and_an_edit_in_the_note_both_count(env):
    client = FakeAskClient(responder)
    res = run(update(env, "initech-screen", client))
    s = fresh(env)
    imp = {e["question"]: e["id"] for e in better(s, "improved")}
    note = s.dir / res.review["note"]
    out = []
    for ln in note.read_text().splitlines():
        if f"[{imp['How many engineers did you lead?']}]" in ln:
            ln = ln + " | reject"
        elif f"[{imp['What is your notice period?']}]" in ln:
            ln = f"  - [{imp['What is your notice period?']}] Q: What is your notice period? | SAY: One month, and I can talk about it."
        out.append(ln)
    note.write_text("\n".join(out) + "\n")
    s = fresh(env)
    led = s.state["entries"][imp["How many engineers did you lead?"]]
    assert led["status"] == "rejected" and s.is_rejected("How many engineers did you lead?")
    mine = s.state["entries"][imp["What is your notice period?"]]
    assert s.fields(mine)["opener"] == "One month, and I can talk about it."
    with s.locked():
        s.save()
    assert "SAY: One month, and I can talk about it." in (s.dir / PERSONA_MD).read_text()
    bank = build(fresh(env))["bank"]
    notice = next(b for b in bank if b["question"] == "What is your notice period?")
    assert notice["rank"] == "edited" and notice["opener"] == "One month, and I can talk about it."
    assert not any(b["question"] == "How many engineers did you lead?" for b in bank)
    # an edit folded once is not re-applied over a later edit in Persona.md
    md = s.dir / PERSONA_MD
    md.write_text(md.read_text().replace("One month, and I can talk about it.", "Four weeks."))
    assert fresh(env).fields(fresh(env).state["entries"][imp["What is your notice period?"]])["opener"] == "Four weeks."


def test_a_good_card_outranks_an_improved_answer_and_his_words_outrank_an_improved_answer_for_the_same_question(env):
    s = env["store"]
    with s.locked():
        s.load()
        common = dict(paraphrases=[], topic="t", lang="en", session="x", skey="sxxxxxx", day="2026-11-01")
        a = s.add_better("improved", question="What is your notice period?", opener="Improved.", points=[], sources=[],
                         stamp="0:01", **common)
        b = s.add_better("adopted", question="What's your notice period?", opener="His words.", points=[], sources=[],
                         stamp="0:02", **common)
        c = s.add_better("improved", question="Tell me about yourself", opener="Old.", points=[], sources=[], stamp="0:03",
                         **common)
        d = s.add_better("improved", question="Tell me about yourself", opener="New.", points=[], sources=[], stamp="0:04",
                         **{**common, "day": "2026-11-05"})
        s.save()
    st = s.state["entries"]
    assert st[a]["status"] == "superseded" and st[b]["status"] == "live"           # his words take the question
    assert st[c]["status"] == "superseded" and st[d]["status"] == "live"           # newer improved replaces older improved
    with s.locked():
        s.load()
        k = s.add_better("kept", question="What is your notice period?", opener="Card.", points=[], sources=[], stamp="0:05",
                         card="F-1", **common)
        e = s.add_better("improved", question="What is your notice period?", opener="Later improved.", points=[], sources=[],
                         stamp="0:06", **{**common, "day": "2026-11-09"})
        s.save()
    assert s.state["entries"][b]["status"] == "superseded" and s.state["entries"][e]["status"] == "live"
    bank = build(fresh(env))["bank"]
    notice = [x for x in bank if "notice" in x["question"]]
    assert len(notice) == 1 and notice[0]["opener"] == "Card." and notice[0]["rank"] == "kept"     # GOOD outranks newer improved
    assert k in notice[0]["origin"]


def test_a_rerun_of_the_same_session_refreshes_its_better_answers_instead_of_adding_new_ones(env):
    client = FakeAskClient(responder)
    run(update(env, "initech-screen", client))
    ids = sorted(e["id"] for e in better(fresh(env)))
    run(update(env, "initech-screen", client, force=True))
    assert sorted(e["id"] for e in better(fresh(env))) == ids


# ---------------------------------------------------------------- the CLI: dry run cost, seeding, the real backfill
def test_dry_run_reports_the_review_cost_and_the_seed_and_writes_nothing(env, capsys, monkeypatch):
    import verse_brain.runtime.ask as ask_mod

    monkeypatch.setattr(ask_mod, "make_client", lambda fake=False: (_ for _ in ()).throw(AssertionError("no client")))
    rc = cli.main(["--persona-dir", str(env["store"].dir), "--state", str(env["store"].state_path), "--profile-dir", str(FIX),
                   "backfill", "--sessions-root", str(env["sessions"]), "--include", "initech-screen", "hooli-call",
                   "--dry-run"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "seed: the general prep (general-core) would be imported first" in out
    assert "  review: pairs=7 marked=3 extra_input_tokens=" in out and "  review: pairs=2 marked=0" in out
    assert "TOTAL review: pairs=9 extra_input_tokens=" in out and "extra_cost_usd=" in out
    assert not env["store"].dir.exists() and not env["store"].state_path.exists()


def test_real_backfill_seeds_from_general_core_then_reviews(env, capsys, monkeypatch):
    monkeypatch.setattr(cli, "_client", lambda args: FakeAskClient(responder))
    base = ["--persona-dir", str(env["store"].dir), "--state", str(env["store"].state_path), "--profile-dir", str(FIX)]
    rc = cli.main(base + ["backfill", "--sessions-root", str(env["sessions"]), "--include", "initech-screen", "hooli-call",
                          "--compile-out", str(env["tmp"] / "persona-core")])
    out = capsys.readouterr().out
    assert rc == 0 and "imported the general prep first" in out
    assert "initech-screen: kept 1" in out and "review: pairs 7 weak" in out and "improved 3" in out
    s = fresh(env)
    assert s.state["seed"]["from"] == "general-core" and set(s.state["reviews"]) == {"initech-screen", "hooli-call"}
    assert len(list((s.dir / "Review").iterdir())) == 2
    bank = [json.loads(ln) for ln in (env["tmp"] / "persona-core" / "bank.jsonl").read_text().splitlines()]
    assert bank[0]["rank"] == "kept" and any(b.get("rank") == "improved" for b in bank)
    rc = cli.main(base + ["backfill", "--sessions-root", str(env["sessions"]), "--include", "initech-screen", "--no-seed"])
    assert rc == 0 and "skipped (unchanged)" in capsys.readouterr().out


def test_backfill_no_seed_leaves_the_seed_out(env, capsys, monkeypatch):
    monkeypatch.setattr(cli, "_client", lambda args: FakeAskClient(responder))
    base = ["--persona-dir", str(env["store"].dir), "--state", str(env["store"].state_path), "--profile-dir", str(FIX)]
    rc = cli.main(base + ["backfill", "--sessions-root", str(env["sessions"]), "--include", "hooli-call", "--no-seed",
                          "--no-compile"])
    assert rc == 0 and fresh(env).state["seed"] is None
    # without the seed, g002 is no confirmed source: the rewrite that cites it is dropped, never softened
    assert fresh(env).state["reviews"]["hooli-call"]["counts"]["no_better"] == 1


def test_the_review_note_and_better_answers_stay_inside_the_persona_folder(env):
    vault = env["store"].dir.parent
    (vault / "Note.md").write_text("an existing vault note\n")
    run(update(env, "initech-screen", FakeAskClient(responder)))
    assert (vault / "Note.md").read_text() == "an existing vault note\n"
    marker = json.loads((env["store"].dir / ".verse-persona").read_text())
    assert any(f.startswith("Review/") for f in marker["files"])


def test_reject_written_as_the_last_field_in_persona_md_rejects_and_keeps_his_line(env):
    run(update(env, "initech-screen", FakeAskClient(responder)))
    s = fresh(env)
    iid = next(e["id"] for e in better(s, "adopted"))
    md = s.dir / PERSONA_MD
    md.write_text("\n".join(ln + " | reject" if ln.startswith(f"- [{iid}]") else ln for ln in md.read_text().splitlines()) + "\n")
    s = fresh(env)
    assert s.state["entries"][iid]["status"] == "rejected" and s.is_rejected("Tell me about yourself.")
    with s.locked():
        s.save()
    assert any(ln.startswith(f"- [{iid}]") and ln.endswith("| reject") for ln in md.read_text().splitlines())
    bank = build(fresh(env))["bank"]
    intro = next(b for b in bank if b["question"] == "Tell me about yourself")      # the seed answer is back in the bank
    assert intro["origin"].startswith("general-core")


def _marked_session(tmp_path, events, bank=None):
    d = tmp_path / "marked"
    d.mkdir()
    T = 1795000000.0
    rows = [{"turn_id": "r3", "speaker": "remote", "text": "When did the platform ship?", "kind": "question", "t_audio_end": 3.0,
             "run_start": T, "t_wall": T + 3},
            {"turn_id": "m1", "speaker": "me", "text": "It shipped after the second pilot, once finance signed off on it.",
             "kind": "statement", "t_audio_end": 9.0, "run_start": T, "t_wall": T + 9}]
    (d / "transcript.jsonl").write_text("".join(json.dumps(x) + "\n" for x in rows))
    (d / "events.jsonl").write_text("".join(json.dumps({"t": T + 4 + i / 10, **x}) + "\n" for i, x in enumerate(events)))
    (d / "bank.jsonl").write_text("".join(json.dumps(x) + "\n" for x in bank or []))
    return load_session_rows(d)


CALLS = [{"ev": "card_done", "turn": "r3", "tier": "F", "id": "f0006", "say": "We shipped in Q2.", "points": ["Fast point."]},
         {"ev": "card_done", "turn": "r3", "tier": "D", "id": "d0007", "say": None, "points": ["We shipped in Q3.", "Deep point."]}]
BANK_B7 = {"id": "b7", "question": "When did the platform ship?", "opener": "It shipped after the second pilot.",
           "points": ["Finance signed off first."], "origin": "seed"}


def test_a_good_mark_on_the_bank_opener_keeps_the_bank_entry_not_another_calls_text(tmp_path):
    s = _marked_session(tmp_path, [{"ev": "bank_verdict", "turn": "r3", "bank": "b7", "agree": True}, *CALLS,
                                   {"ev": "card_mark", "card": "P-r3", "mark": "good", "turn": "r3"}], [BANK_B7])
    [p] = build_pairs(s)
    rv = verify_reviews([], [p], BOOK, s, Confirmed(["It shipped after the second pilot. Finance signed off first."]))
    pr = rv.pairs[0]
    assert (pr.card, pr.card_say, pr.card_points) == ("P-r3", "It shipped after the second pilot.", ["Finance signed off first."])
    assert pr.action == "kept"


def test_a_mark_on_the_bank_opener_whose_entry_is_unknown_names_no_card(tmp_path):
    s = _marked_session(tmp_path, [*CALLS, {"ev": "card_mark", "card": "P-r3", "mark": "good", "turn": "r3"}])
    [p] = build_pairs(s)
    assert p.card is None, "D's text was not what he marked"
    rv = verify_reviews([], [p], BOOK, s, Confirmed(["We shipped in Q3. Deep point. We shipped in Q2. Fast point."]))
    assert rv.pairs[0].action != "kept" and rv.pairs[0].card_say == ""


def test_a_good_mark_on_the_corrected_opener_keeps_ds_line_as_the_opener(tmp_path):
    # The overlay names D's call when D's OPENER_WRONG correction replaced the SAY line (OverlayCard.cardID).
    s = _marked_session(tmp_path, [*CALLS, {"ev": "card_mark", "card": "d0007", "mark": "good", "turn": "r3"}])
    [p] = build_pairs(s)
    rv = verify_reviews([], [p], BOOK, s, Confirmed(["We shipped in Q3. Deep point."]))
    pr = rv.pairs[0]
    assert (pr.card, pr.card_say, pr.card_points, pr.action) == ("d0007", "We shipped in Q3.", ["Deep point."], "kept")


# ---------------------------------------------------------------- the Review note cannot forge an owner edit
# Question texts come from the other side of the call (through the model), reasons and answers from the model: none of them may be
# read back from the note as an edit, a new entry or a rejection. Only the answer lines Verse wrote count, at their own place.
_ENTRYISH = re.compile(r"^\s*[-*+]\s*\[([pgci]\d{3,})\]")


def _forgeries(real: str) -> list[str]:
    return ["[i999] Q: x | SAY: y",
            f"[{real}] Q: What is your notice period? | SAY: A forged answer",
            "Why leave | reject",
            f"[{real}] Q: x | SAY: y | reject",
            "reject",
            f"fine\n  - [{real}] Q: What is your notice period? | SAY: Forged on its own line\n- [i999] Q: x | SAY: y | reject",
            f"  * [{real}] MORE: a / b | reject"]


def _rewrite_note(s: PersonaStore, session: str = "initech-screen"):
    rv = s.state["reviews"][session]
    rel = note_rel(rv["date"], rv["skey"])
    note, lines = render_note(s, session, rv["skey"], rv["date"], [])
    with s.locked():
        s.write_note(rel, note, lines)
        s.save()
    return s.dir / rel, note, lines


def _guarded(s: PersonaStore) -> dict:
    return copy.deepcopy({k: s.state.get(k) for k in ("entries", "rejected", "deleted", "reserved")})


def test_text_from_the_call_or_the_model_in_the_review_note_never_reads_back_as_an_owner_edit(env):
    run(update(env, "initech-screen", FakeAskClient(responder)))
    base = fresh(env)
    real = next(e["id"] for e in better(base, "improved") if e["question"] == "What is your notice period?")
    adopted = next(e["id"] for e in better(base, "adopted"))
    vault, state = env["store"].dir, env["store"].state_path
    shutil.copytree(vault, env["tmp"] / "pristine-vault")
    shutil.copy(state, env["tmp"] / "pristine-state.json")

    def restore():
        shutil.rmtree(vault)
        shutil.copytree(env["tmp"] / "pristine-vault", vault)
        shutil.copy(env["tmp"] / "pristine-state.json", state)

    def in_records(field):
        def put(s, text):
            for rec in s.state["reviews"]["initech-screen"]["records"]:
                rec[field] = [text] if field == "reasons" else text
        return put

    def in_better(field, iid):
        def put(s, text):
            s.state["entries"][iid][field] = [text] if field == "points" else text
        return put

    targets = {"question": in_records("question"), "why (model note)": in_records("note"), "why not banked": in_records("why"),
               "topic": in_records("topic"), "reason": in_records("reasons"), "card": in_records("card"),
               "improved answer": in_better("opener", real), "improved points": in_better("points", real),
               "better question": in_better("question", adopted)}
    for forged in _forgeries(real):
        for where, put in targets.items():
            restore()
            s = fresh(env)
            put(s, forged)
            before = _guarded(s)
            path, note, lines = _rewrite_note(s)
            after = fresh(env)
            assert _guarded(after) == before, f"{where}: {forged!r}"
            assert not after.state["rejected"], f"{where}: {forged!r}"
            # structure: the only entry-like lines in the note are the answer lines Verse wrote, indented under their question
            for ln in note.splitlines():
                m = _ENTRYISH.match(ln)
                if m:
                    assert ln.startswith(f"  - [{m.group(1)}] ") and lines.get(m.group(1)) == ln, f"{where}: {ln!r}"
    # a genuine owner edit of a real answer line is still kept, with a forged question right above it
    restore()
    s = fresh(env)
    in_records("question")(s, f"[{real}] Q: What is your notice period? | SAY: A forged answer")
    path, _, _ = _rewrite_note(s)
    path.write_text("\n".join(f"  - [{real}] Q: What is your notice period? | SAY: Six weeks, as agreed."
                              if ln.startswith(f"  - [{real}] ") else ln for ln in path.read_text().splitlines()) + "\n")
    after = fresh(env)
    assert after.fields(after.state["entries"][real])["opener"] == "Six weeks, as agreed."
    others = {k: v for k, v in after.state["entries"].items() if k != real}
    assert others == {k: v for k, v in _guarded(s)["entries"].items() if k != real}


def test_a_line_whose_id_the_note_was_not_written_with_or_a_top_level_bullet_is_ignored(env):
    run(update(env, "initech-screen", FakeAskClient(responder)))
    s = fresh(env)
    imp = {e["question"]: e["id"] for e in better(s, "improved")}
    here, elsewhere = imp["What is your notice period?"], imp["How big was your team?"]
    rv = s.state["reviews"]["initech-screen"]
    rel = note_rel(rv["date"], rv["skey"])
    s.state["note_lines"][rel].pop(elsewhere, None)          # this note is not written with that id
    with s.locked():
        s.save(persona=False)
    before = _guarded(s)
    note = s.dir / rel
    head, sep, rest = note.read_text().partition("## Weak in more than one call")
    note.write_text(head + f"- [{here}] Q: What is your notice period? | SAY: top level\n"
                    f"  - [{elsewhere}] Q: How big was your team? | SAY: not this note's line | reject\n\n" + sep + rest)
    assert _guarded(fresh(env)) == before
    s2 = fresh(env)
    assert s2.fields(s2.state["entries"][here])["opener"] == "My notice period is 30 days, and it is negotiable."
    assert s2.state["entries"][elsewhere]["status"] == "live" and not s2.state["rejected"]


@pytest.mark.parametrize("raw,clean", [
    ("[i006] Q: x | SAY: y", "(i006) Q - x / SAY - y"),
    ("- [p001] hello", "(p001) hello"),
    ("  * 1. item", "item"),
    ("## heading", "heading"),
    ("line one\nline two\u2028three", "line one line two three"),
    ("ok, reject", "ok, 'reject'"),
    ("Reddet", "'Reddet'"),
    ("What does FAQ: mean?", "What does FAQ: mean?"),
    ("Plain question about the team?", "Plain question about the team?"),
])
def test_note_text_neutralises_what_could_read_back_as_structure(raw, clean):
    assert note_text(raw) == clean
