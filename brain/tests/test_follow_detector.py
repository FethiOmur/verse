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
        m.clock.t = 0.4 * i
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
    r = run("What I like at Halden is that Compass re-plans the routes every ninety seconds with live traffic")
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
        clock.t = 0.4 * i
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
    """>= 1.2 s of his speech that matches nothing (with at least three content words) also diverges."""
    text = "Honestly marathon training taught me patience"
    r = run(text, params=replace(FollowParams(), diverge_words=9))
    assert diverged(r) is not None


def test_a_single_stray_card_word_inside_other_talk_is_not_a_match():
    """"small", "reduced" and "supplier" occur on the card, but far apart and alone they are no cluster of one line."""
    r = run("Honestly my small marathon training app had a reduced budget and a supplier problem with shirts at the finish")
    assert diverged(r) is not None
