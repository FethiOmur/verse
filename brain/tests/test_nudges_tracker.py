"""Live nudges, runtime state (runtime/nudges.py): loader, gates, money rule, candidate choice, output parse, quote check."""

from __future__ import annotations

import json

import pytest

from verse_brain.runtime.nudges import (WINDOW_WORDS, Evaluation, Nudge, NudgeTracker, fake_judge_line, key_hits, load,
                                         norm_tokens, parse_output, quote_in, says_money)
from verse_brain.runtime.prompt import nudge_tail


class Clock:
    def __init__(self) -> None:
        self.t = 100.0

    def __call__(self) -> float:
        return self.t


PAY = Nudge("n001", "Pay story", "pay or salary is being discussed now", ("salary", "pay", "compensat"),
            ("Tell the story of the pilot first.", "Then name the range."), until="number")
TOOLS = Nudge("n002", "Tooling", "the tools they use are being discussed", ("tooling", "stack"), ("Ask which tracker they use.",))
MINE = Nudge("n003", "My launch", "the owner talks about his launch", ("launch",), ("Mention the waitlist.",), who="me")
LATE = Nudge("n004", "Wrap up", "the call is wrapping up", ("next steps",), ("Ask about the timeline.",), after_s=600.0)


def tracker(*nudges: Nudge, clock: Clock | None = None, **kw) -> NudgeTracker:
    return NudgeTracker(list(nudges or (PAY, TOOLS)), clock=clock or Clock(), **kw)


def answer_for(ev, nid: str | None = None, quote: str | None = None) -> str:
    text = ev.window[-1][1]
    who = "them" if ev.window[-1][0] == "remote" else "me"
    return f'NUDGE: {nid or ev.candidates[0]} | "{quote or " ".join(text.split()[-5:])}" | {who}'


# ------------------------------------------------------------------------------------------------ loader
def _write(tmp_path, lines) -> object:
    p = tmp_path / "nudges.jsonl"
    p.write_text("".join((ln if isinstance(ln, str) else json.dumps(ln)) + "\n" for ln in lines), encoding="utf-8")
    return p


GOOD = {"id": "n001", "title": "Pay", "when": "pay now", "keys": ["pay"], "who": "any", "until": None, "after_s": 0,
        "say": ["One line."], "ref": "prep:L3"}


def test_load_missing_file_is_empty(tmp_path):
    assert load(tmp_path / "nudges.jsonl") == []


def test_load_valid_file(tmp_path):
    got = load(_write(tmp_path, [{**GOOD, "id": "n002"}, GOOD]))
    assert [n.id for n in got] == ["n001", "n002"] and got[0].say == ("One line.",)


@pytest.mark.parametrize("bad", [
    "{not json",
    {**GOOD, "keys": []},
    {**GOOD, "say": []},
    {**GOOD, "say": ["a", "b", "c", "d"]},
    {**GOOD, "who": "everyone"},
    {**GOOD, "id": 7},
    {**GOOD, "after_s": -1},
    [1, 2, 3],
])
def test_load_malformed_file_means_no_nudges(tmp_path, bad):
    assert load(_write(tmp_path, [GOOD, bad])) == []


def test_load_duplicate_ids_means_no_nudges(tmp_path):
    assert load(_write(tmp_path, [GOOD, GOOD])) == []


def test_load_directory_or_binary_is_empty(tmp_path):
    (tmp_path / "nudges.jsonl").mkdir()
    assert load(tmp_path / "nudges.jsonl") == []
    other = tmp_path / "b"
    other.mkdir()
    (other / "nudges.jsonl").write_bytes(b"\xff\xfe\x00")
    assert load(other / "nudges.jsonl") == []


# ------------------------------------------------------------------------------------------------ text rules
def test_keys_match_word_prefixes_case_insensitive():
    assert key_hits(("compensat",), "What about COMPENSATION then?") == 1
    assert key_hits(("pay",), "we will repay it") == 0
    assert key_hits(("next steps",), "so the next steps are") == 1
    assert key_hits(("next steps",), "the next big steps") == 0


@pytest.mark.parametrize("text", ["I was thinking 80k", "around $90,000", "eighty five thousand francs", "120 thousand",
                                  "CHF 95", "5000 euros", "fifty dollars", "it's 1.5m a year"])
def test_money_hits(text):
    assert says_money(text)


@pytest.mark.parametrize("text", ["we have 12 people", "about 30 percent", "let's talk money later", "in 2026", "three of them"])
def test_money_misses(text):
    assert not says_money(text)


def test_parse_output_three_fields():
    v = parse_output('NUDGE: n003 | "we should talk about pay" | them')
    assert (v.id, v.quote, v.who) == ("n003", "we should talk about pay", "them")
    v = parse_output("noise\nNUDGE: [n002] | \u201ctooling question\u201d | me")
    assert (v.id, v.quote, v.who) == ("n002", "tooling question", "me")
    v = parse_output("NUDGE: n001 | 'you're right about the hours' | them")
    assert v.quote == "you're right about the hours"


def test_parse_output_without_a_pick():
    assert parse_output("NUDGE: none").why == "none"
    assert parse_output("SAY: Sure, here is the short answer.\nBANK: none").why == "garbage"
    assert parse_output("NUDGE: maybe n003").why == "garbage"
    assert parse_output("NUDGE: n001 | the other side asks about pay").why == "not_quotation"
    assert parse_output('NUDGE: n001 | ""').why == "not_quotation"
    assert parse_output('NUDGE: n001 | "cut off by the token lim').why == "unclosed"
    v = parse_output('NUDGE: n004 | "The other side asks to discuss pay or commercial terms" \u2014 not happening. The turns')
    assert v.id is None and v.why == "negated"


def test_parse_output_missing_or_odd_who_field():
    assert parse_output('NUDGE: n003 | "we should talk about pay"').who is None
    assert parse_output('NUDGE: n003 | "we should talk about pay" | the recruiter').who is None
    assert parse_output('NUDGE: n003 | "we should talk about pay" | [them]').who == "them"


# ------------------------------------------------------------------------------------------------ stage A
def test_key_in_newest_turn_nominates():
    tr = tracker()
    res = tr.on_turn("r1", "remote", "So, about the salary for this role", 10.0)
    assert res.evaluation is not None and res.evaluation.candidates == ["n001"] and res.evaluation.reason == "keys"
    assert tr.on_turn("m1", "me", "Sure, happy to talk.", 12.0).evaluation is None


def test_room_speaker_is_ignored():
    tr = tracker()
    assert tr.on_turn("x1", "room", "the salary is", 1.0).evaluation is None
    assert tr.utts == []


def test_repeated_turn_counts_once():
    tr = tracker()
    assert tr.on_turn("r1", "remote", "salary talk", 1.0).evaluation is not None
    assert tr.on_turn("r1", "remote", "salary talk", 1.0).evaluation is None


def test_who_gate():
    tr = tracker(MINE)
    assert tr.on_turn("r1", "remote", "how did the launch go", 5.0).evaluation is None
    ev = tr.on_turn("m1", "me", "the launch went well", 8.0).evaluation
    assert ev is not None and ev.candidates == ["n003"]


def test_who_gate_at_judge_time_checks_the_quoted_speaker():
    tr = tracker(MINE)
    tr.on_turn("r1", "remote", "tell me about the launch plan", 5.0)
    ev = tr.on_turn("m1", "me", "the launch went well", 8.0).evaluation
    tr.launched(ev)
    fire, reason, _ = tr.judge(ev, 'NUDGE: n003 | "tell me about the launch plan" | them')
    assert fire is None and reason == "who"


def test_after_gate_uses_the_audio_clock():
    tr = tracker(LATE)
    assert tr.on_turn("r1", "remote", "what are the next steps", 120.0).evaluation is None
    assert tr.on_turn("r2", "remote", "so what are the next steps", 610.0).evaluation is not None


def test_sweep_is_off_by_default():
    tr = tracker(PAY, TOOLS)
    evs = [tr.on_turn(f"t{i}", "remote" if i % 2 else "me", f"nothing relevant here at all {i}", float(i)).evaluation
           for i in range(1, 20)]
    assert evs == [None] * 19


def test_sweep_every_six_finals_without_an_evaluation():
    tr = tracker(PAY, TOOLS, MINE, sweep_every=6)
    evs = [tr.on_turn(f"t{i}", "remote" if i % 2 else "me", f"nothing relevant here at all {i}", float(i)).evaluation
           for i in range(1, 7)]
    assert evs[:5] == [None] * 5
    assert evs[5] is not None and evs[5].reason == "sweep" and len(evs[5].candidates) == 3
    tr.launched(evs[5])
    assert tr.on_turn("t7", "remote", "still nothing relevant here", 7.0).evaluation is None


def test_at_most_three_candidates():
    many = [Nudge(f"n00{i}", f"N{i}", "pay", ("pay",), ("x",)) for i in range(1, 6)]
    ev = tracker(*many).on_turn("r1", "remote", "pay pay pay", 1.0).evaluation
    assert ev is not None and len(ev.candidates) == 3


def test_window_is_two_utterances_or_25_seconds_capped():
    tr = tracker()
    tr.on_turn("a", "remote", "old words " * 3, 0.0)
    tr.on_turn("b", "me", "within range", 40.0)
    tr.on_turn("c", "remote", "also within", 50.0)
    tr.on_turn("d", "me", "newest one", 60.0)
    assert [t for _, t in tr.window()] == ["within range", "also within", "newest one"]
    tr.on_turn("e", "remote", " ".join(f"w{i}" for i in range(200)), 61.0)
    w = tr.window()
    assert sum(len(t.split()) for _, t in w) == WINDOW_WORDS and w[-1][1].endswith("w199")


def test_growing_and_repeated_rows_merge_into_one_utterance():
    tr = tracker()
    tr.on_turn("m1", "me", "I think you can", 1.0)
    tr.on_turn("m2", "me", "I think you can understand it", 2.0)
    tr.on_turn("m3", "me", "I think you can understand it", 3.0)          # an exact repeat
    tr.on_turn("m4", "me", "understand it because of the portfolio", 4.0)  # overlaps the end
    assert tr.window() == [("me", "I think you can understand it because of the portfolio")]
    assert len(tr.utts) == 1


def test_a_repeated_row_with_a_key_is_not_evaluated_twice():
    tr = tracker()
    ev = tr.on_turn("r1", "remote", "and what about the salary", 1.0).evaluation
    assert ev is not None
    tr.launched(ev)
    res = tr.on_turn("r2", "remote", "and what about the salary", 2.0)
    assert res.evaluation is None and res.new_words == 0


def test_fillers_and_stutter_are_dropped_so_a_long_row_keeps_its_key_words():
    tr = tracker(Nudge("n001", "Hours", "they describe long hours", ("hours",), ("x",), who="them"))
    row = "um we have long working hours um we you know " + "if " * 110 + "you are falling in love with it"
    ev = tr.on_turn("r1", "remote", row, 10.0).evaluation
    assert ev is not None
    text = ev.window[-1][1]
    assert "long working hours" in text and "um" not in text.split() and text.count("if") == 1


def test_sweep_counts_utterances_not_rows():
    tr = tracker(PAY, TOOLS, sweep_every=6)
    evs = [tr.on_turn(f"r{i}", "remote", f"more words number {i}", float(i)).evaluation for i in range(1, 10)]
    assert evs == [None] * 9                  # one long utterance of one speaker
    evs = [tr.on_turn(f"x{i}", "me" if i % 2 else "remote", f"a longer reply number {i}", 20.0 + i).evaluation
           for i in range(1, 6)]
    assert evs[:4] == [None] * 4 and evs[4] is not None and evs[4].reason == "sweep"


def test_backchannels_do_not_count_towards_the_sweep():
    tr = tracker(PAY, TOOLS, sweep_every=6)
    evs = []
    for i in range(1, 13):
        sp = "me" if i % 2 else "remote"
        evs.append(tr.on_turn(f"x{i}", sp, "yeah okay" if sp == "me" else f"a longer remark number {i}", float(i)).evaluation)
    assert evs[:11] == [None] * 11 and evs[11] is not None and evs[11].reason == "sweep"   # six real utterances


def test_key_split_over_two_rows_still_hits():
    tr = tracker(Nudge("n005", "Start", "start date", ("start date",), ("x",)))
    assert tr.on_turn("r1", "remote", "so the start", 1.0).evaluation is None
    ev = tr.on_turn("r2", "remote", "so the start date would be soon", 2.0).evaluation
    assert ev is not None and ev.candidates == ["n005"]


# ------------------------------------------------------------------------------------------------ stage B judge
def test_fires_once_only():
    clock = Clock()
    tr = tracker(clock=clock)
    ev = tr.on_turn("r1", "remote", "let us talk about the salary now", 10.0).evaluation
    tr.launched(ev)
    fire, reason, _ = tr.judge(ev, answer_for(ev))
    assert reason == "fired" and fire.nudge.id == "n001" and fire.turn_id == "r1" and fire.speaker == "remote"
    ev2 = tr.on_turn("r2", "remote", "and the salary again", 200.0).evaluation
    assert ev2 is None     # spent: no longer armed, so no candidate


def test_cooldown_between_fires():
    tr = tracker()
    ev = tr.on_turn("r1", "remote", "the salary question", 10.0).evaluation
    tr.launched(ev)
    assert tr.judge(ev, answer_for(ev))[1] == "fired"
    assert tr.on_turn("r2", "remote", "what tooling do you use", 40.0).evaluation is None   # cooling: nothing is evaluated
    assert "n002" in tr.armed
    ev3 = tr.on_turn("r3", "remote", "back to the tooling stack", 75.0).evaluation
    tr.launched(ev3)
    assert tr.judge(ev3, answer_for(ev3))[1] == "fired"


def test_cooldown_applies_to_a_result_launched_before_the_fire():
    tr = tracker()
    tr.on_turn("r0", "remote", "the tooling we use", 9.0)
    ev_a = tr.on_turn("r1", "remote", "the salary question", 10.0).evaluation
    ev_b = Evaluation("r1", ["n002"], tr.window(), "catch_up")
    tr.launched(ev_a)
    tr.launched(ev_b)
    assert tr.judge(ev_a, answer_for(ev_a))[1] == "fired"
    assert tr.judge(ev_b, 'NUDGE: n002 | "the tooling we use" | them')[1] == "cooldown"


def test_quote_not_in_window_is_rejected():
    tr = tracker()
    tr.on_turn("r0", "remote", "we discussed compensation an hour ago", 1.0)
    tr.on_turn("m0", "me", "right", 2.0)
    ev = tr.on_turn("r1", "remote", "the salary later maybe", 60.0).evaluation
    tr.launched(ev)
    fire, reason, _ = tr.judge(ev, 'NUDGE: n001 | "we discussed compensation an hour ago" | them')
    assert fire is None and reason == "quote_not_in_window"
    assert "n001" in tr.armed


def test_quote_must_be_whole_words():
    tr = tracker()
    ev = tr.on_turn("r1", "remote", "we will repay the salary", 1.0).evaluation
    tr.launched(ev)
    assert tr.judge(ev, 'NUDGE: n001 | "pay the salary" | them')[1] == "quote_not_in_window"


def test_quote_too_long_is_rejected():
    tr = tracker()
    text = " ".join(["so let us now talk about the salary and the whole package for this role"] * 3)   # 42 words
    ev = tr.on_turn("r1", "remote", text, 1.0).evaluation
    tr.launched(ev)
    assert tr.judge(ev, f'NUDGE: n001 | "{text}" | them')[1] == "quote_too_long"


def test_garbage_and_none_do_not_fire():
    tr = tracker()
    ev = tr.on_turn("r1", "remote", "the salary", 1.0).evaluation
    tr.launched(ev)
    assert tr.judge(ev, "SAY: Sure.\n- a\n- b\nBANK: none")[1] == "garbage"
    assert tr.judge(ev, "NUDGE: none")[1] == "none"
    assert tr.judge(ev, "")[1] == "garbage"
    assert "n001" in tr.armed


def test_id_that_was_not_a_candidate_is_rejected():
    tr = tracker()
    ev = tr.on_turn("r1", "remote", "the salary", 1.0).evaluation
    tr.launched(ev)
    assert tr.judge(ev, 'NUDGE: n002 | "the salary" | them')[1] == "not_candidate"


def test_stale_result_is_dropped():
    clock = Clock()
    tr = tracker(clock=clock)
    ev = tr.on_turn("r1", "remote", "the salary", 1.0).evaluation
    tr.launched(ev)
    clock.t += 8.5
    assert tr.judge(ev, answer_for(ev))[1] == "stale"
    assert "n001" in tr.armed


def test_until_number_retires_an_armed_nudge():
    tr = tracker()
    res = tr.on_turn("r1", "remote", "we were thinking about 80k", 1.0)
    assert res.retired == ["n001"] and res.clear == []
    assert "n001" not in tr.armed
    assert tr.on_turn("r2", "remote", "so the salary then", 2.0).evaluation is None


def test_until_number_clears_a_nudge_on_screen():
    clock = Clock()
    tr = tracker(clock=clock)
    ev = tr.on_turn("r1", "remote", "what about the salary", 1.0).evaluation
    tr.launched(ev)
    assert tr.judge(ev, answer_for(ev))[1] == "fired"
    clock.t += 5
    res = tr.on_turn("m1", "me", "I was hoping for ninety thousand", 6.0)
    assert res.retired == ["n001"] and res.clear == ["n001"]


def test_until_number_after_the_ttl_sends_no_clear():
    clock = Clock()
    tr = tracker(clock=clock)
    ev = tr.on_turn("r1", "remote", "what about the salary", 1.0).evaluation
    tr.launched(ev)
    tr.judge(ev, answer_for(ev))
    clock.t += 30
    assert tr.on_turn("m1", "me", "maybe 90k", 40.0).clear == []


def test_money_in_a_result_window_retires_before_fire():
    tr = tracker()
    ev = tr.on_turn("r1", "remote", "what about the salary", 1.0).evaluation
    tr.launched(ev)
    tr.on_turn("m1", "me", "I'd say 85k", 2.0)        # said while the check was in flight
    assert tr.judge(ev, answer_for(ev))[1] == "retired"


def test_history_feeds_the_money_rule_only():
    tr = tracker()
    assert tr.observe("me", "my last offer was 70k", 5.0) == ["n001"]
    assert tr.on_turn("r1", "remote", "the salary", 6.0).evaluation is None


# ------------------------------------------------------------------------------------------------ tail and fake
def test_tail_and_fake_judge_round_trip():
    tr = tracker()
    tr.on_turn("m0", "me", "thanks for having me", 1.0)
    ev = tr.on_turn("r1", "remote", "Let's get into salary expectations.", 3.0).evaluation
    tail = nudge_tail([(nid, tr.nudges[nid].when) for nid in ev.candidates], ev.window)
    assert "[n001] When: pay or salary is being discussed now" in tail
    lines = tail.splitlines()
    assert lines[lines.index("END OF LATEST TURNS") - 1].endswith("Let's get into salary expectations.")
    assert lines[-1].startswith("NUDGE:")                  # the output instruction comes last
    tr.launched(ev)
    fire, reason, _ = tr.judge(ev, fake_judge_line(tail))
    assert reason == "fired" and fire.nudge.id == "n001"


# ------------------------------------------------------------------------------------------------ quote matching
def test_quote_without_the_fillers_matches():
    tr = tracker(Nudge("n005", "Start", "the start date", ("start date",), ("x",)))
    ev = tr.on_turn("r1", "remote", "and uh yeah start date would um um we can pretty much start as soon as", 5.0).evaluation
    tr.launched(ev)
    assert tr.judge(ev, 'NUDGE: n005 | "start date would we can pretty much start" | them')[1] == "fired"


def test_quote_may_skip_two_words_but_not_more():
    hay = norm_tokens("can you shoot over maybe two references of people that I can call")
    assert quote_in(hay, norm_tokens("can you shoot over two references"))
    assert quote_in(hay, norm_tokens("shoot over references of people"))           # two words skipped
    assert not quote_in(hay, norm_tokens("can you references of people"))           # four words skipped
    assert not quote_in(hay, norm_tokens("send two references"))


def test_quote_from_fragments_matches_the_merged_utterance():
    tr = tracker(Nudge("n002", "Questions", "they invite my questions", ("questions",), ("x",), who="them"))
    tr.on_turn("r1", "remote", "we have a couple of minutes left do you", 1.0)
    ev = tr.on_turn("r2", "remote", "have any questions for me", 2.0).evaluation
    tr.launched(ev)
    assert tr.judge(ev, 'NUDGE: n002 | "do you have any questions for me" | them')[1] == "fired"


# ------------------------------------------------------------------------------------------------ catch-up
def test_deferred_candidates_get_one_catch_up_over_the_current_window():
    tr = tracker()
    ev1 = tr.on_turn("r1", "remote", "the salary question", 1.0).evaluation
    tr.launched(ev1)
    ev2 = tr.on_turn("r2", "remote", "and which tooling", 2.0).evaluation    # met a call in flight
    tr.defer(ev2)
    tr.on_turn("m1", "me", "we used a small stack", 3.0)
    assert tr.judge(ev1, "NUDGE: none")[1] == "none"
    cu = tr.take_pending()
    assert cu is not None and cu.reason == "catch_up" and cu.candidates == ["n002"] and cu.turn_id == "m1"
    assert cu.window[-1] == ("me", "we used a small stack")
    assert tr.take_pending() is None                                          # one catch-up only


def test_no_catch_up_while_cooling_or_when_spent():
    tr = tracker()
    ev1 = tr.on_turn("r1", "remote", "the salary question", 1.0).evaluation
    tr.launched(ev1)
    tr.defer(Evaluation("r2", ["n002"], tr.window(), "keys"))
    assert tr.judge(ev1, answer_for(ev1))[1] == "fired"
    assert tr.take_pending() is None                                          # cooling after the fire
    tr2 = tracker()
    tr2.defer(Evaluation("r1", ["n001"], [], "keys"))
    tr2.on_turn("m1", "me", "my number is 80k", 2.0)                           # n001 retired by the money rule
    assert tr2.take_pending() is None


# ------------------------------------------------------------------------------------------------ judge wording
def test_tail_states_who_and_the_question_rule():
    tail = nudge_tail([("n002", "the other side invites my questions", "them"), ("n001", "pay", "any"),
                       ("n003", "I mention my launch", "me")], [("remote", "you are doing your masters right")])
    assert "[n002] When: the other side invites my questions (only the other side's words can show it)" in tail
    assert "[n001] When: pay\n" in tail                                   # `any`: no note
    assert next(ln for ln in tail.splitlines() if ln.startswith("[n003]")).endswith("own words can show it)")
    assert "is not an invitation for his questions" in tail
    assert "a day of the week or a weekend is not working time" in tail and "is not a start date" in tail
    assert "This is a classification task" in tail and "do not use the SAY format" in tail
    assert "pick it even if the words differ" in tail
    assert tail.splitlines()[-2:] == ['NUDGE: <id> | "<copied words>" | <them or me>', "NUDGE: none"]


# ------------------------------------------------------------------------------------------------ quote parts and speaker
def _ev_for(tr, rows):
    ev = None
    for i, (sp, text) in enumerate(rows):
        ev = tr.on_turn(f"t{i}", sp, text, float(i)).evaluation or ev
    tr.launched(ev)
    return ev


HOURS = Nudge("n001", "Hours", "they describe working hours", ("hours",), ("x",), who="them")


def test_quote_with_an_ellipsis_checks_each_part_in_order():
    tr = tracker(HOURS)
    ev = _ev_for(tr, [("remote", "we have long working hours and you know sometimes also the weekend if we have deadlines")])
    assert tr.judge(ev, 'NUDGE: n001 | "we have long working hours ... weekend if we have deadlines" | them')[1] == "fired"


def test_ellipsis_parts_out_of_order_or_missing_are_rejected():
    tr = tracker(HOURS)
    ev = _ev_for(tr, [("remote", "we have long working hours and you know sometimes also the weekend if we have deadlines")])
    assert tr.judge(ev, 'NUDGE: n001 | "weekend if we have deadlines ... we have long working hours" | them')[1] == \
        "quote_not_in_window"
    assert tr.judge(ev, 'NUDGE: n001 | "we have long working hours \u2026 nights and holidays too" | them')[1] == \
        "quote_not_in_window"


def test_short_ellipsis_parts_are_ignored_unless_alone():
    tr = tracker(HOURS)
    ev = _ev_for(tr, [("remote", "we have long working hours most weeks")])
    assert tr.judge(ev, 'NUDGE: n001 | "so ... we have long working hours ... ok" | them')[1] == "fired"
    tr = tracker(HOURS)
    ev = _ev_for(tr, [("remote", "the hours are long")])
    assert tr.judge(ev, 'NUDGE: n001 | "hours ... long" | them')[1] == "quote_not_in_window"   # two short parts: nothing checked


def test_quotes_up_to_thirty_words_are_accepted():
    tr = tracker(HOURS)
    text = "do you have any questions for me anything that I can help you with about the hours here or the team"
    ev = _ev_for(tr, [("remote", text)])
    assert len(text.split()) > 12
    assert tr.judge(ev, f'NUDGE: n001 | "{text}" | them')[1] == "fired"


def test_stated_speaker_must_match_the_quoted_turn():
    tr = tracker(Nudge("n004", "Pay", "pay is discussed", ("pay",), ("x",)))
    ev = _ev_for(tr, [("remote", "and the pay for this role is fixed"), ("me", "let us talk about the pay then")])
    assert tr.judge(ev, 'NUDGE: n004 | "let us talk about the pay then" | them')[1] == "who_mismatch"
    assert tr.judge(ev, 'NUDGE: n004 | "let us talk about the pay then" | me')[1] == "fired"


def test_missing_who_field_is_rejected():
    tr = tracker(HOURS)
    ev = _ev_for(tr, [("remote", "we have long working hours most weeks")])
    assert tr.judge(ev, 'NUDGE: n001 | "we have long working hours"')[1] == "no_who"
    assert "n001" in tr.armed


def test_quote_parts_from_two_speakers_are_rejected():
    tr = tracker(Nudge("n004", "Pay", "pay is discussed", ("pay",), ("x",)))
    ev = _ev_for(tr, [("remote", "and the pay for this role is fixed"), ("me", "let us talk about the pay then")])
    assert tr.judge(ev, 'NUDGE: n004 | "the pay for this role ... let us talk about" | them')[1] == "who_mismatch"


def test_negated_line_is_none_and_spends_nothing():
    tr = tracker(Nudge("n004", "Pay", "pay is discussed", ("pay",), ("x",)))
    ev = _ev_for(tr, [("remote", "we can talk about pay later")])
    fire, reason, _ = tr.judge(ev, 'NUDGE: n004 | "we can talk about pay later" \u2014 not happening now | them')
    assert fire is None and reason == "negated" and "n004" in tr.armed


def test_a_word_the_judge_added_is_tolerated_only_in_long_quotes():
    hay = norm_tokens("and yeah start date would um um we can pretty much start as soon as we have sorted out the contractual side")
    assert quote_in(hay, norm_tokens("the start date would we can pretty much start as soon as we sorted out contractual side"))
    assert not quote_in(hay, norm_tokens("the start date would"))                     # short: every word must be there
    assert not quote_in(hay, norm_tokens("the first start date would we can pretty much begin as soon as we sorted it"))
