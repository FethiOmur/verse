"""The call's dominant language in AUTO (owner decisions 7 and 8, runtime/lang.py): the cards follow the language most of the other
side's substantive speech is in, never a greeting, a few words or his own speech. Table tests over the pure rule, then the engine:
which language each card's tail names. Fictional text; the transport is the canned fake (no network)."""

from __future__ import annotations

import pytest

from verse_brain.runtime.lang import CONSECUTIVE, DEFAULT_LANG, LONG_WORDS, SUBSTANTIVE_WORDS, DominantLanguage, word_count

from test_runtime_helpers import run, settle
from test_runtime_me import make, me_spec, session_dir, start
from test_runtime_unprepared import UNPREPARED

# Utterances of the other side. Word counts are checked below, so a change of the thresholds shows up here first.
EN_GREETING = "hi, how are you"                                                       # 4 words
IT_GREETING = "ciao, come sta oggi"                                                   # 4 words
IT_PHRASE = "perfetto, grazie mille"                                                  # 3 words
EN_Q = "tell me about the project you are proudest of"                               # 9 words
EN_Q2 = "how did you measure whether the new pipeline actually worked"              # 10 words
IT_Q = "mi parli del progetto di cui va piu orgoglioso"                             # 9 words
IT_Q2 = "come ha misurato se la nuova pipeline funzionava davvero"                  # 9 words
IT_LONG = ("allora le spiego come lavoriamo qui da noi, abbiamo tre squadre che si occupano dei dati e ognuna ha un responsabile "
           "che riporta direttamente alla direzione")                                 # 26 words


def test_thresholds_and_fixture_lengths():
    assert (SUBSTANTIVE_WORDS, CONSECUTIVE, LONG_WORDS, DEFAULT_LANG) == (6, 2, 20, "en")
    assert word_count(EN_GREETING) < SUBSTANTIVE_WORDS and word_count(IT_GREETING) < SUBSTANTIVE_WORDS
    assert word_count(IT_PHRASE) < SUBSTANTIVE_WORDS
    for q in (EN_Q, EN_Q2, IT_Q, IT_Q2):
        assert SUBSTANTIVE_WORDS <= word_count(q) < LONG_WORDS, q
    assert word_count(IT_LONG) >= LONG_WORDS
    assert word_count("l'azienda non c'è") == 3, "an apostrophe inside a word keeps it one word"


# (case, start language, [(lang tag, text), ...] of the other side's finished utterances, dominant after each one)
TABLE = [
    ("before any speech: the prepared language", "it", [], []),
    ("without a prepared language: English", None, [], []),
    ("a short Italian greeting in an English call stays English", "en",
     [("it", IT_GREETING), ("en", EN_Q)], ["en", "en"]),
    ("one Italian question alone does not flip", "en",
     [("it", IT_Q), ("en", EN_Q)], ["en", "en"]),
    ("a few Italian words between two Italian questions neither count nor break the run", "en",
     [("it", IT_Q), ("it", IT_PHRASE), ("it", IT_Q2)], ["en", "en", "it"]),
    ("a real switch to Italian by the interviewer is followed", "en",
     [("it", IT_Q), ("it", IT_Q2)], ["en", "it"]),
    ("one long Italian utterance flips on its own", "en",
     [("it", IT_LONG)], ["it"]),
    ("an English question between two Italian ones ends the run", "en",
     [("it", IT_Q), ("en", EN_Q), ("it", IT_Q2)], ["en", "en", "en"]),
    ("switch back by the same rule", "en",
     [("it", IT_Q), ("it", IT_Q2), ("en", EN_GREETING), ("en", EN_Q), ("en", EN_Q2)], ["en", "it", "it", "it", "en"]),
    ("a short English phrase inside an Italian call stays Italian", "it",
     [("en", EN_GREETING), ("it", IT_Q)], ["it", "it"]),
    ("an unknown tag never counts", "en",
     [("fr", IT_Q), ("xx", IT_Q2), (None, IT_LONG)], ["en", "en", "en"]),
    ("Turkish is a language like the others", "en",
     [("tr", "bu projede en çok neyle gurur duyuyorsunuz acaba"), ("tr", "ekibiniz kaç kişiden oluşuyordu ve sizin rolünüz neydi")],
     ["en", "tr"]),
]


@pytest.mark.parametrize("case,initial,utterances,expected", TABLE, ids=[c[0] for c in TABLE])
def test_dominant_language_table(case, initial, utterances, expected):
    d = DominantLanguage(initial)
    assert d.lang == (initial or DEFAULT_LANG)
    got = []
    for lang, text in utterances:
        d.note(lang, text)
        got.append(d.lang)
    assert got == expected, case


def test_would_be_counts_an_open_utterance_without_changing_anything():
    d = DominantLanguage("en")
    d.note("it", IT_Q)
    assert d.would_be("it", IT_Q2) == "it", "the question that completes the switch is answered in Italian already"
    assert d.would_be("it", IT_PHRASE) == "en", "a few words never would"
    assert d.lang == "en" and d.run == ("it", 1), "nothing changed"


def test_note_reports_the_flip_once_and_reset_drops_the_run():
    d = DominantLanguage("en")
    assert d.note("it", IT_Q) is None
    assert d.note("it", IT_Q2) == "it"
    assert d.note("it", IT_Q) is None
    d.note("en", EN_Q)
    assert d.run == ("en", 1)
    d.reset("en")
    assert d.lang == "en" and d.run is None
    d.reset("xx")
    assert d.lang == "en", "an unknown language is not taken"


# (case, start language, utterances, (answer language, majority) at the end)
MAJORITY = [
    ("before any speech: the starting language", "it", [], ("it", "it")),
    ("a long English call with a two-question Italian run: cards Italian, most speech English", "en",
     [("en", EN_Q), ("en", EN_Q2), ("en", EN_Q), ("it", IT_Q), ("it", IT_Q2)], ("it", "en")),
    ("greetings never count for the majority", "en", [("it", IT_GREETING)] * 5 + [("en", EN_Q)], ("en", "en")),
    ("the Italian part grows past the English one", "en",
     [("en", EN_Q), ("it", IT_Q), ("it", IT_Q2), ("it", IT_Q)], ("it", "it")),
    ("a tie keeps the language the cards are in", "en", [("en", IT_Q), ("it", IT_Q2)], ("en", "en")),
]


@pytest.mark.parametrize("case,initial,utterances,expected", MAJORITY, ids=[c[0] for c in MAJORITY])
def test_the_majority_language_is_kept_apart_from_the_answer_language(case, initial, utterances, expected):
    d = DominantLanguage(initial)
    for lang, text in utterances:
        d.note(lang, text)
    assert (d.lang, d.majority) == expected, case
    d.reset(d.majority)
    assert d.lang == expected[1] and d.majority == expected[1], "a reset to the majority leaves what was heard"


# ---------------------------------------------------------------------------------------------------- engine

def card_heads(t):
    """The `Language:` line of each fast card (S on a partial, F on the final), in call order."""
    return [c.tail.split("\n")[0] for c in t.calls if c.route in ("S", "F") and "SUMMARIZE" not in c.tail]


def per_turn(heads):
    return [h for i, h in enumerate(heads) if i == 0 or h != heads[i - 1]]


async def say(b, tid: str, text: str, lang: str, *, speaker: str = "remote", kind: str = "question"):
    await b.handle({"type": "partial", "turn_id": tid, "speaker": speaker, "text": text, "cue": True, "lang": lang, "t_audio_end": 0.0})
    await b.handle({"type": "turn", "turn_id": tid, "speaker": speaker, "text": text, "addressee": "me", "kind": kind,
                    "t_audio_end": 0.0, "lang": lang})
    await settle(b)


def test_auto_cards_follow_the_dominant_language_not_each_turn(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), lang_auto=True, **UNPREPARED)
        await say(b, "r1", EN_Q, "en")
        await say(b, "g1", IT_GREETING + " e mi parli un po di lei", "it")   # one Italian question: still English
        await say(b, "r2", IT_Q, "it")                                       # the second in a row: the switch
        await say(b, "r3", IT_Q2, "it")
        await say(b, "r4", EN_Q, "en")                                       # one English question in an Italian call
        await say(b, "r5", EN_Q2, "en")                                      # the second: back to English
        return b, t, em

    b, t, em = run(go())
    assert per_turn(card_heads(t)) == ["Language: English", "Language: Italian", "Language: English"], card_heads(t)
    flips = [(e["lang"], e["reason"]) for e in em.of("metric", stage="lang_dominant")]
    assert flips == [("en", "start"), ("it", "sustained"), ("en", "sustained")]
    by_turn = {e["turn_id"]: e["lang"] for e in em.of("metric", stage="answer_lang")}
    assert by_turn["g1"] == "en" and by_turn["r2"] == "it" and by_turn["r4"] == "it" and by_turn["r5"] == "en"
    assert b.dominant.lang == "en"


def test_his_own_speech_never_flips_the_cards(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), lang_auto=True, **UNPREPARED)
        for i, text in enumerate([IT_LONG, IT_Q, IT_Q2]):
            await b.handle({"type": "turn", "turn_id": f"m{i}", "speaker": "me", "text": text, "lang": "it", "t_audio_end": 0.0})
        await say(b, "r1", EN_Q, "en")
        return b, t

    b, t = run(go())
    assert b.dominant.lang == "en"
    assert per_turn(card_heads(t)) == ["Language: English"]


def test_the_prepared_language_answers_before_any_speech_is_heard(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await b.handle({"type": "start", "session_dir": str(session_dir(tmp_path)), "lang": "en", "lang_hint": "it", "lang_auto": True,
                        **UNPREPARED})
        await b.warmed()
        await say(b, "r1", EN_Q, "en")              # one English question in a call prepared in Italian
        return b, t

    b, t = run(go())
    assert per_turn(card_heads(t)) == ["Language: Italian"]
    assert b.lang == "en", "the recognizers' language is still the one `lang` named"


def test_without_lang_auto_each_turn_keeps_its_own_tag(tmp_path):
    """Pinned calls and older senders: the behaviour before AUTO, unchanged."""
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **UNPREPARED)
        await say(b, "r1", IT_Q, "it")
        await say(b, "r2", EN_Q, "en")
        return t, em

    t, em = run(go())
    assert per_turn(card_heads(t)) == ["Language: Italian", "Language: English"]
    assert em.of("metric", stage="lang_dominant") == [] and em.of("metric", stage="answer_lang") == []


def test_lang_auto_can_be_turned_on_and_off_mid_call(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), lang_auto=True, **UNPREPARED)
        await b.handle({"type": "control", "action": "lang_auto", "on": False})
        await say(b, "r1", IT_Q, "it")                        # pinned again: the turn's tag
        await b.handle({"type": "control", "action": "lang_auto", "on": True})
        await say(b, "r2", IT_Q2, "it")                       # AUTO from English again: one Italian question is not enough
        return b, t, em

    b, t, em = run(go())
    assert per_turn(card_heads(t)) == ["Language: Italian", "Language: English"]
    assert [e["on"] for e in em.of("metric", stage="lang_auto")] == [False, True]


def test_a_restarted_brain_rebuilds_the_dominant_language_from_the_history(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), lang_auto=True, **UNPREPARED)
        await b.handle({"type": "history", "turns": [
            {"turn_id": "h1", "speaker": "remote", "text": IT_Q, "lang": "it"},
            {"turn_id": "h2", "speaker": "me", "text": EN_Q, "lang": "en"},
            {"turn_id": "h3", "speaker": "remote", "text": IT_Q2, "lang": "it"},
        ]})
        return b

    assert run(go()).dominant.lang == "it", "his English turn between them is not the other side's speech"


def test_a_flip_reports_the_majority_and_regenerate_to_it_answers_in_it_and_resets(tmp_path):
    """The owner's example (decision 9): an Italian card in a mostly English call; regenerate asks for English with a reset."""
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), lang_auto=True, **UNPREPARED)
        for i, q in enumerate([EN_Q, EN_Q2, EN_Q]):
            await say(b, f"r{i + 1}", q, "en")
        await say(b, "r4", IT_Q, "it")
        await say(b, "r5", IT_Q2, "it")                                      # the cards flip to Italian here
        flip = em.of("metric", stage="lang_dominant", reason="sustained")
        await b.handle({"type": "control", "action": "regenerate", "turn": "r5", "lang": b.dominant.majority, "reset": True})
        await settle(b)
        return b, t, em, flip

    b, t, em, flip = run(go())
    assert [(e["lang"], e["majority"]) for e in flip] == [("it", "en")], "the cards are Italian, most of the call is English"
    assert em.of("metric", stage="lang_dominant", reason="start")[0]["majority"] == "en"
    assert b.dominant.lang == "en"
    [c] = [c for c in t.calls if c.route in ("S", "F") and "CARD NOW" in c.tail]
    assert c.tail.startswith("Language: English")


def test_the_majority_is_reported_when_it_changes_without_a_flip(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), lang_auto=True, **UNPREPARED)
        await say(b, "r1", EN_Q, "en")
        await say(b, "r2", IT_Q, "it")
        await say(b, "r3", IT_Q2, "it")                                      # flip and majority change together
        await say(b, "r4", EN_Q2, "en")                                      # 19 English words to 18: majority English, no flip
        await say(b, "r5", IT_LONG, "it")
        return em

    em = run(go())
    assert [(e["turn_id"], e["lang"], e["prev"]) for e in em.of("metric", stage="lang_majority")] == [
        ("r3", "it", "en"), ("r4", "en", "it"), ("r5", "it", "en")]
    assert [e["turn_id"] for e in em.of("metric", stage="lang_dominant", reason="sustained")] == ["r3"]
