"""Follow my answer, the detector (runtime/follow.py): divergence on the user's speech against the card of the open question.

Pure and deterministic: fake clock, concept embedder, speech delivered one word per 0.4 s. The cases that matter to
the owner: reading the card verbatim triggers nothing, a paraphrase triggers nothing (the embedding path is what holds it), a
new topic diverges within five content words, fillers are nothing, and going back to the card does not flip anything."""

from __future__ import annotations

from dataclasses import replace

import pytest
from follow_helpers import CARD, PACK_FOR_DETECTOR, ConceptEmbedder

from verse_brain.runtime.follow import Covered, Diverged, FollowMachine, FollowParams, NeedEmbed, Refresh, is_content, tokenize
from verse_brain.runtime.follow_drive import Clock, SyncDriver, simulate

WORD = dict(wps=2.5, chunk_s=0.4)        # one word per update, like a slow stream


def run(text, *, embed=True, params=None, **kw):
    kw = {**WORD, **kw}
    return simulate(CARD, text, params=params, embedder=ConceptEmbedder() if embed else None, pack=PACK_FOR_DETECTOR, **kw)


def diverged(r):
    return r.first(Diverged)


VERBATIM = ("Sure, I'll give you the short version. I built it mostly solo. Lantern cut manual data entry from eleven "
            "minutes to two minutes per invoice.")
NEW_PROJECT = ("Actually the thing I'm most proud of is a running app for the marathon, it is called TrailHead and it "
               "is on the App Store.")


def test_reading_the_card_verbatim_triggers_nothing():
    r = run(VERBATIM)
    assert diverged(r) is None
    assert [e.fx.point for e in r.of(Covered)] == [0, 1]


def test_verbatim_with_recognizer_slips_triggers_nothing():
    r = run("Sure I'll give you the short version. I built it most of solo. Lantern cut manual data entry from 11 minute "
            "to 2 minute per invoice")
    assert diverged(r) is None


PARAPHRASES = [
    "I built most of it on my own",                                  # the spec's example
    "I did all of the engineering work completely by myself over several long evenings",   # 7 words that match nothing
    "With Lantern the time people spent typing invoice data went down from eleven minutes to just two",
    "Before that I made a small tool for a courier pilot that planned the routes better and cut the empty runs by fourteen percent",
]


@pytest.mark.parametrize("text", PARAPHRASES)
def test_a_paraphrase_triggers_nothing(text):
    r = run(text)
    assert diverged(r) is None, "the embedding path keeps a paraphrase on the card"


def test_the_lexical_test_alone_would_flip_a_long_paraphrase_and_the_embedding_is_what_holds_it():
    """Measured, not assumed: the second paraphrase has 7 content words that match nothing, so the lexical test fires; only
    the embedding says it is still the card. (Without the embedder the card simply stays: see test_follow_review.)"""
    text = PARAPHRASES[1]
    m = FollowMachine(clock=Clock(), embed_ok=True)
    m.new_turn("q1")
    m.add_line("orig-q1", "F", "say", CARD["say"])
    for p_ in CARD["points"]:
        m.add_line("orig-q1", "F", "point", p_)
    m.drain()
    fired = False
    for i, w in enumerate(text.split(), 1):
        m.clock.t = 0.8 * i                 # a slow speaker: the count rule needs its unmatched words to span 4 s
        m.on_me("m1", " ".join(text.split()[:i]), False)
        fired = fired or m._lex_trigger()[0]
        m.drain()
    assert fired
    assert diverged(run(text, embed=True)) is None


def test_a_new_project_diverges_within_five_content_words():
    r = run(NEW_PROJECT)
    d = diverged(r)
    assert d is not None
    # the first off-card content word is "proud"; count content words from there up to the arrival of the detection
    words = NEW_PROJECT.split()
    n_at = max(i for i in range(len(words) + 1) if i / 2.5 + 1e-9 <= d.t)       # words delivered when it fired
    spoken = " ".join(words[:n_at])
    start = tokenize(spoken).index("proud")
    content = [w for w in tokenize(spoken)[start:] if is_content(w)]
    assert len(content) <= 5, (len(content), spoken)
    assert d.fx.reason == "lexical+embed" and d.fx.embed is not None and d.fx.embed < 0.80


def test_another_pack_topic_diverges_through_the_margin():
    """Talking about Compass is on the pack but not on this card: the margin (another pack line beats the card) says so."""
    r = run("What I like at Halden is that Compass replans the dispatch routes every ninety seconds with live traffic")
    d = diverged(r)
    assert d is not None and d.fx.margin is not None and d.fx.margin >= 0.04


def test_fillers_and_backchannels_are_nothing():
    m = FollowMachine(clock=Clock(), embed_ok=True)
    m.new_turn("q1")
    m.add_line("orig-q1", "F", "say", CARD["say"])
    for t in CARD["points"]:
        m.add_line("orig-q1", "F", "point", t)
    m.drain()
    for i, text in enumerate(["so", "so um yeah", "so um yeah okay right", "so um yeah okay right uh huh mm hmm well",
                              "so um yeah okay right uh huh mm hmm well you know i mean like"]):
        m.clock.t = 0.4 * (i + 1)
        m.on_me("m1", text, False)
    fx = m.drain()
    assert not [e for e in fx if isinstance(e, (Diverged, Covered, Refresh))]
    assert not [e for e in fx if isinstance(e, NeedEmbed)], "nothing to embed: no content word was said"


def test_divergence_waits_for_the_card():
    """Words said before any card line exists are kept, nothing is decided until there is a card to diverge from."""
    clock = Clock()
    m = FollowMachine(clock=clock, embed_ok=True)
    drv = SyncDriver(m, ConceptEmbedder(), PACK_FOR_DETECTOR)
    m.new_turn("q1")
    fx: list = []
    for i in range(1, 9):
        clock.t = 0.8 * i                       # a word every 0.8 s: the run spans more than the time rule's 4 s
        m.on_me("m1", " ".join(NEW_PROJECT.split()[: i + 6]), False)
    drv.pump(fx.append, now=clock.t)
    assert not fx
    m.add_line("orig-q1", "F", "say", CARD["say"])
    drv.pump(fx.append, now=clock.t)
    assert [e for e in fx if isinstance(e, Diverged)], "the card arrived: his words so far are compared at once"


def test_diverge_then_return_to_the_card_does_not_flicker():
    """After the follow card started, reading the original card again marks its points covered; no second divergence, no
    refresh, no switch back."""
    clock = Clock()
    m, drv = None, None
    from verse_brain.runtime.follow_drive import make_machine
    m, drv = make_machine(CARD, None, ConceptEmbedder(), clock, card_id="orig-q1", pack=PACK_FOR_DETECTOR)
    fx = []
    sink = fx.append

    def say(text, t0, per=0.4, turn="m1"):
        ws = text.split()
        for i in range(1, len(ws) + 1):
            clock.t = round(t0 + per * i, 3)
            m.on_me(turn, " ".join(ws[:i]), False)
            drv.pump(sink, now=clock.t)
            m.tick()
            drv.pump(sink, now=clock.t)
        return clock.t

    t = say(NEW_PROJECT, 0.0)
    assert [e for e in fx if isinstance(e, Diverged)]
    m.c_started("c0001")                                  # the engine launched the follow call
    m.add_line("c0001", "C", "say", "It is a running coach for iOS.")
    m.add_line("c0001", "C", "point", "It is live on the App Store.")
    m.c_done()
    fx.clear()
    t = say(VERBATIM, t + 0.2, turn="m2")
    for i in range(1, 40):                                # a long pause after reading the card
        clock.t = round(t + 0.1 * i, 3)
        m.tick()
        drv.pump(sink, now=clock.t)
    assert not [e for e in fx if isinstance(e, (Diverged, Refresh))], fx
    assert {(e.fx.card_id, e.fx.point) for e in [type("E", (), {"fx": x}) for x in fx] if isinstance(e.fx, Covered)} >= {
        ("orig-q1", 0), ("orig-q1", 1)}


def test_the_time_rule_fires_without_the_count():
    """>= 4 s of his speech that matches nothing (with at least three content words) also diverges. 0.8 s per word: the run of
    "marathon training taught patience" (four content words) spans 2.4 s, so the stream carries on past 4 s with more talk."""
    text = "Honestly marathon training taught me patience and discipline and also humility during every long winter"
    r = simulate(CARD, text, params=replace(FollowParams(), diverge_words=99), embedder=ConceptEmbedder(),
                 pack=PACK_FOR_DETECTOR, wps=1.25, chunk_s=0.8)
    e = diverged(r)
    assert e is not None
    assert e.t >= 4.0, "no time rule below 4 s of unmatched speech"


def _stream_run(times, text="marathon training patience discipline humility", params=None):
    """Words of `text` arrive at `times` (seconds); the machine has the card and an embedder that sees an off-card topic.
    `params` default: the count rule off (diverge_words=99), so only the time rule can decide. Returns the Diverged effects."""
    from follow_helpers import PACK_FOR_DETECTOR as pack
    from verse_brain.runtime.follow_drive import make_machine
    clock = Clock()
    m, drv = make_machine(CARD, params or replace(FollowParams(), diverge_words=99), ConceptEmbedder(), clock, pack=pack)
    out = []
    ws = text.split()
    for i, t in enumerate(times):
        clock.t = t
        m.on_me("m1", " ".join(ws[:i + 1]), False, now=t)
        drv.pump(out.append, now=t)
    return [e for e in out if isinstance(e, Diverged)]


@pytest.mark.parametrize("span,expect", [(1.5, False), (3.0, False), (3.9, False), (4.0, True), (5.5, True)])
def test_the_time_rule_needs_four_seconds_of_unmatched_speech(span, expect):
    """Three unmatched content words (the minimum) whose first and last arrivals are `span` seconds apart. The count rule
    (diverge_words) is out of the way, so only the time rule can decide; with 4.0 s or more of speech it does."""
    got = _stream_run([0.0, span / 2, span], text="marathon training patience")
    assert bool(got) is expect


def test_the_time_rule_needs_enough_words_even_after_four_seconds():
    """Two unmatched content words five seconds apart are one slow word and one more, not a topic (`time_min_words`)."""
    assert not _stream_run([0.0, 5.0], text="marathon training")
    assert _stream_run([0.0, 2.5, 5.0], text="marathon training patience")


def test_a_single_stray_card_word_inside_other_talk_is_not_a_match():
    """"small", "reduced" and "supplier" occur on the card, but far apart and alone they are no cluster of one line."""
    r = run("Honestly my small marathon training app had a reduced budget and a supplier problem with shirts at the finish")
    assert diverged(r) is not None


SIX = "marathon training patience discipline humility winters"        # six content words that match nothing on the card
COUNT_ONLY = replace(FollowParams(), diverge_s=99.0)                  # the time rule out of the way: only the count rule can decide


@pytest.mark.parametrize("span,expect", [(1.5, False), (3.0, False), (3.9, False), (4.0, True), (6.0, True)])
def test_the_count_rule_needs_its_unmatched_words_to_span_four_seconds(span, expect):
    """Six unmatched content words (more than `diverge_words`) whose first and last arrivals are `span` seconds apart: said
    within 1.5 s, 3 s or 3.9 s they do not diverge by count; spread over 4 s or more they do."""
    times = [span * i / 5 for i in range(6)]
    assert bool(_stream_run(times, text=SIX, params=COUNT_ONLY)) is expect


def test_fast_speech_diverges_only_through_the_time_rule_and_not_before_four_seconds():
    """Twenty unmatched content words at four per second. The count rule cannot see them (its window of 8 words spans under
    2 s); the time rule decides, at 4 s of his unmatched speech and not a moment earlier."""
    words = ("marathon training patience discipline humility winters weather snow cold mountain valley river forest meadow "
             "village cottage orchard harbour garden market").split()
    times = [i / 4.0 for i in range(len(words))]
    got = _stream_run(times, text=" ".join(words), params=FollowParams())
    assert got and got[0].start_ms >= 4000, got
    assert not _stream_run(times, text=" ".join(words), params=COUNT_ONLY), "the count rule alone never fires at this pace"


def test_no_divergence_is_logged_before_four_seconds_of_his_speech():
    """Over a set of scripted answers, with the count rule's old speed, every `follow_diverged` line carries >= 4 s of his speech."""
    from test_follow_log import Sink
    answers = [NEW_PROJECT, PARAPHRASES[1], "Honestly marathon training taught me patience and discipline and also humility "
               "during every long winter in the mountains", "Compass re-plans the dispatch routes every ninety seconds"]
    for text in answers:
        for wps in (2.5, 4.0, 6.0):
            sink = Sink()
            simulate(CARD, text, embedder=ConceptEmbedder(), pack=PACK_FOR_DETECTOR, log=sink, wps=wps, chunk_s=0.4)
            for d in sink.of("follow_diverged"):
                assert d["since_start_s"] >= 4.0 and d["count_span_s"] >= 0 and d["count_min_s"] == 4.0, (text, wps, d)
