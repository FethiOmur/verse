"""persona/extract.py: request shape, parsing and the verification rules. No model text is compared to a golden output: the
items below are hand-written stand-ins for what a model could return, and the tests check what code keeps or drops."""

import json
from pathlib import Path

import pytest

from verse_brain.memory.index import session_key
from verse_brain.persona.extract import (Confirmed, RawItem, build_request, names_in, parse_items, quote_in, system_text,
                                         verify_items)
from verse_brain.persona.rows import PRow, SessionRows, classify, load_session_rows
from verse_brain.runtime.settings import PERSONA_MAX_TOKENS, PERSONA_MIN_TOKENS, persona_params

FIX = Path(__file__).parent / "fixtures" / "persona"
A = load_session_rows(FIX / "sessions" / "acme-intro")
KA = session_key("acme-intro", set())
B = load_session_rows(FIX / "sessions" / "globex-call")
KB = session_key("globex-call", set())
ME = Confirmed([(FIX / "me.md").read_text()])


def item(kind="claim", topic="team size", text="I grew the team to 12 engineers.", quote="grew it to 12 engineers",
         cite=None, **kw):
    return RawItem(kind, topic, text, quote, cite or f"[{KA} 0:14]", **kw)


def kept(raw, key=KA, rows=A, conf=ME):
    return verify_items(raw, key, rows, conf)


def test_a_valid_own_item_is_kept_with_its_cite_and_evidence():
    v = kept([item()])
    assert len(v.items) == 1 and v.items[0].cite == f"[{KA} 0:14]" and v.items[0].evidence == "own"


def test_quote_not_in_the_cited_owner_row_is_dropped():
    v = kept([item(quote="grew it to 15 engineers"), item(quote="Why are you thinking about leaving")])
    assert v.items == [] and v.dropped["quote"] == 2


def test_cites_of_the_other_side_a_missing_stamp_another_session_or_garbage_are_dropped():
    raw = [item(cite=f"[{KA} 0:20]", quote="Why are you thinking about leaving"),       # an OTHER row
           item(cite=f"[{KA} 9:59]"),                                                    # no such stamp
           item(cite=f"[{KB} 0:14]"),                                                    # another session's key
           item(cite="the card"), item(cite="[]")]
    v = kept(raw)
    assert v.items == [] and v.dropped["cite"] == 5


def test_unrelabelled_room_rows_are_never_evidence():
    raw = [RawItem("claim", "what I bring", "I would bring calm to the team.", "bring a lot of calm to the team", f"[{KB} 0:33]"),
           RawItem("claim", "salary", "I expect around 110,000 euros base.", "I expect around 110,000 euros base", f"[{KB} 0:15]")]
    v = kept(raw, KB, B)
    assert [i.stamp for i in v.items] == ["0:15"] and v.dropped["cite"] == 1


def test_a_number_not_in_the_cited_row_is_dropped():
    v = kept([item(text="I grew the team to 14 engineers in 2 years.")])
    assert v.items == [] and v.dropped["number"] == 1


def test_a_read_row_keeps_adopted_wording_but_drops_a_new_number_unless_confirmed():
    read_cite = f"[{KA} 0:31]"
    adopted = RawItem("preference", "company size", "I want a smaller company where I own the product end to end.",
                      "I want a smaller company where I can own the product", read_cite)
    number = RawItem("preference", "team size", "I want a team of about 40 people.", "a team of about 40 people", read_cite)
    v = kept([adopted, number])
    assert [i.topic for i in v.items] == ["company size"] and v.items[0].evidence == "read"
    assert v.dropped["unconfirmed"] == 1
    v2 = kept([number], conf=Confirmed(["I like teams of about 40 people"]))     # a confirmed source has it: kept
    assert len(v2.items) == 1


def test_names_from_a_read_row_need_a_confirmed_source():
    assert names_in("I worked at Northwind in March. The team liked it.") == {"northwind", "march"}
    assert Confirmed(["Northwind and March"]).has_names("At Northwind since March")
    assert not Confirmed(["nothing here"]).has_names("At Northwind")


def one_row(text, card=None, evidence="own", stamp="0:10", key=KA):
    rows = SessionRows("x", [PRow(stamp, "me", text, "m1", "en", evidence)], [card] if card else [])
    return key, rows


def test_a_name_the_cited_own_row_never_says_is_dropped():
    key, rows = one_row("I led the platform migration for two years myself")
    added = RawItem("claim", "migration lead", "I led the platform migration at Stripe for two years.",
                    "led the platform migration for two years", f"[{key} 0:10]")
    month = RawItem("claim", "migration lead", "I led the platform migration until May for two years.",
                    "led the platform migration for two years", f"[{key} 0:10]")
    v = kept([added, month], key, rows, Confirmed([]))
    assert v.items == [] and v.dropped["name"] == 2
    # the row's own names pass, whatever their case or suffix, and an ordinary first word needs only a shared stem
    key, rows = one_row("so yeah at stripe i was mentoring the juniors for two years")
    fine = [RawItem("claim", "employer", "I was at Stripe's platform team for two years.", "at stripe i was mentoring",
                    f"[{key} 0:10]"),
            RawItem("style", "mentoring", "Mentors like me grow juniors.", "i was mentoring the juniors", f"[{key} 0:10]")]
    v = kept(fine, key, rows, Confirmed([]))
    assert len(v.items) == 2 and v.dropped["name"] == 0


def test_a_short_card_read_out_classified_own_still_needs_a_confirmed_source():
    card = "I managed a team of 12 engineers at Northwind and cut costs by 40 percent."
    text = "a team of 12 engineers at Northwind"
    assert classify(text, [card]) == ("own", 1.0)                 # too few words to be called `read`
    key, rows = one_row(text, card)
    claim = RawItem("claim", "team size", "I managed a team of 12 engineers at Northwind.", "a team of 12 engineers",
                    f"[{key} 0:10]")
    v = kept([claim], key, rows, Confirmed([]))
    assert v.items == [] and v.dropped["unconfirmed"] == 1
    assert len(kept([claim], key, rows, Confirmed(["12 engineers at Northwind"])).items) == 1
    # a number the owner said that no card holds is his own: kept without confirmation
    key, rows = one_row("we were a team of 15 engineers back then", card)
    own = RawItem("claim", "team size", "We were a team of 15 engineers.", "a team of 15 engineers", f"[{key} 0:10]")
    assert len(kept([own], key, rows, Confirmed([])).items) == 1


def test_bad_kind_empty_fields_and_duplicates():
    v = kept([item(kind="gossip"), item(text=""), item(), item()])
    assert len(v.items) == 1 and v.dropped["kind"] == 1 and v.dropped["empty"] == 1


def test_quote_matching_rules():
    row = "Honestly I am looking for around 95,000 euros base, plus equity."
    assert quote_in(row, "looking for AROUND 95,000   euros")
    assert quote_in(row, "Honestly I am ... plus equity")
    assert not quote_in(row, "plus equity ... Honestly")          # pieces must be in order
    assert not quote_in(row, "equity")                            # shorter than the minimum


def test_parse_items_tolerates_fences_and_rejects_garbage():
    body = {"items": [{"kind": "Claim", "topic": "t", "text": "x", "quote": "q", "cite": "[s1 0:01]", "extra": 1}, "junk"]}
    got = parse_items("```json\n" + json.dumps(body) + "\n```")
    assert len(got) == 1 and got[0].kind == "claim"
    assert parse_items("no json here") is None and parse_items('{"other": []}') is None
    assert parse_items(json.dumps({"items": [{"kind": "claim"}] * 50})) is not None
    assert len(parse_items(json.dumps({"items": [{"kind": "claim"}] * 50}))) == 30


def test_request_marks_owner_rows_read_rows_and_context_rows():
    req = build_request(KB, B, ["[p001] claim | salary | I want 95,000."], "Alex Rivera", rows_tokens=10_000,
                        persona_tokens=1_000)
    assert req.system == system_text("Alex Rivera") and "ALEX RIVERA rows are evidence" in req.system
    assert f"[{KB} 0:15] ALEX RIVERA: I expect around" in req.user
    assert f"[{KB} 0:33] ROOM (either voice; never cite):" in req.user
    assert req.user.startswith("CURRENT PERSONA\n[p001]")
    reqa = build_request(KA, A, [], "Alex Rivera", rows_tokens=10_000, persona_tokens=1_000)
    assert f"[{KA} 0:31] ALEX RIVERA (read):" in reqa.user and f"[{KA} 0:20] OTHER:" in reqa.user
    assert "CURRENT PERSONA\n(empty)" in reqa.user
    cut = build_request(KA, A, [], "Alex Rivera", rows_tokens=30, persona_tokens=1_000)
    assert cut.rows_cut > 0


def test_budget_sizes_max_tokens():
    assert persona_params(10_000)["max_tokens"] == PERSONA_MAX_TOKENS
    small = persona_params(10_000, budget_usd=0.05)["max_tokens"]
    assert PERSONA_MIN_TOKENS <= small < PERSONA_MAX_TOKENS
    assert small == int((0.05 - 10_000 * 2 / 1e6) * 1e6 / 10)
    with pytest.raises(ValueError):
        persona_params(10_000, budget_usd=0.02)
    p = persona_params(1000)
    assert p["model"] == "claude-sonnet-5-5" and p["output_config"] == {"effort": "medium"} and "thinking" not in p
