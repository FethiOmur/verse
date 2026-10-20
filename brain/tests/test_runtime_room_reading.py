"""The room route's two live failures of 16 Oct (one Mac mic, a phone interview on speaker, unprepared, AUTO language):

(A) while Alex read the card aloud, a NEW card replaced it: the recognizer delivered his reading as many finals of 2-6 words, most
    of them stayed `room` (the strict own-voice rule needs 5 content words), and one of them ("... come questo") carried the
    Italian cue `come` and fired F;
(B) some interviewer questions got no card: Italian yes/no questions have no question word, and nothing recorded what the probe said.

The fixtures are fictional (a backend engineer called Dana, an Italian interview) and mimic the pattern of the fragments, not the
text of the real call. Time is a fake clock: the reading session (4 s) and the card hold (1.2 s) run on `Brain._clock`."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

import pytest
from test_runtime_helpers import run, settle
from test_runtime_me import make, me_spec, session_dir, start

from verse_brain.runtime.fake import lines_script
from verse_brain.runtime.own import OwnParams, OwnSpeech

# ---------------------------------------------------------------- the card: three sentences, two points
CARD_IT = ("Certo, sono una sviluppatrice backend con un forte focus sul prodotto. "
           "Ho trovato che la chiave sia la chiarezza degli obiettivi e il feedback frequente. "
           "Il mio ultimo progetto, Harbor Ledger, ha ridotto la chiusura mensile da sei giorni a due.",
           ["Harbor Ledger è nato per i team finanziari più piccoli.", "Prima ho costruito Trailhead, un'app per escursioni."])
CARD_TEAM = ("Mi descrivo come una collega che ascolta prima di decidere e poi si impegna fino in fondo.",
             ["Ho guidato due colleghi nel progetto Trailhead."])
CARD_SQL = ("Sì, ho presentato i risultati delle analisi al comitato ogni trimestre.", ["Lo facevo con grafici semplici."])

# the card read aloud as the recognizer delivered it: finals of 2-6 words, the last word of the first one cut off
FRAGMENTS = [
    "Certo, sono una sviluppa",
    "backend con un forte",
    "focus sul prodotto",
    "Ho trovato che la chiave",
    "sia la chiarezza degli obiettivi",
    "e il feedback frequente",                        # the card's words, in order
    "Il mio ultimo progetto Harbor",
    "Ledger ha ridotto la chiusura mensile da sei giorni a due",
]
# the same fragment that carried `come` in the live call: a card sentence and then "come questo" (not on the card)
FRAGMENT_COME = "e il feedback frequente come questo"


def card_text(card) -> str:
    return "\n".join([f"SAY: {card[0]}", *[f"- {p}" for p in card[1]], "BANK: none"])


def responder(info):
    tail = info.tail
    if "STATEMENT CHECK" in tail:
        if "esperienza" in tail.split("CURRENT TURN")[-1]:                                   # a good model: the yes/no question is a question
            return lines_script("KIND: question\n" + card_text(CARD_SQL))
        return lines_script("KIND: statement\nNONE")
    if info.route == "D":
        return lines_script("OPENER_OK\n- Un dettaglio (f001)\n- Un altro dettaglio (f002)")
    if "parli di lei" in tail:
        return lines_script(card_text(CARD_IT))
    if "membro di un team" in tail:
        return lines_script(card_text(CARD_TEAM))
    return lines_script("SAY: Certo, ecco la risposta breve.\n- Primo punto.\n- Secondo punto.\nBANK: none")


class Clock:
    def __init__(self) -> None:
        self.t = 100.0

    def __call__(self) -> float:
        return self.t

    def advance(self, s: float) -> None:
        self.t += s


def f_calls(t):
    return [c for c in t.by_route("F") if "SUMMARIZE" not in c.tail]


def n_model_calls(t) -> int:
    """Calls that answer or probe a turn (the rolling summary is not one of them)."""
    return len([c for c in t.calls if "SUMMARIZE" not in c.tail])


def cards(em):
    return [e for e in em.of("delta") if e["tier"] in ("S", "F")]


def shown(em) -> str:
    return "".join(e["text"] for e in em.of("delta"))


async def rpartial(b, tid: str, text: str, **extra) -> None:
    await b.handle({"type": "partial", "turn_id": tid, "speaker": "room", "text": text, "cue": False, "t_audio_end": 0.0, **extra})


async def rturn(b, tid: str, text: str, kind: str = "statement", **extra) -> None:
    await b.handle({"type": "turn", "turn_id": tid, "speaker": "room", "text": text, "addressee": "unknown", "kind": kind,
                    "t_audio_end": 0.0, **extra})


def italian_session(tmp_path, monkeypatch, *, events: bool = False):
    monkeypatch.setenv("VERSE_EVENTS", "1" if events else "0")
    b, t, em, _ = make(tmp_path, embedder=False, responder=responder)
    clock = Clock()
    b._clock = clock
    sdir = session_dir(tmp_path)
    return b, t, em, clock, sdir, start(b, sdir, me=me_spec(), mode="unprepared", route="room", lang="it", follow=True)


async def first_card(b, em, clock, tid="r1"):
    await rturn(b, tid, "mi parli di lei e della sua esperienza", kind="question", cue=True, cue_why="mi parli", cue_strong=True)
    await settle(b)
    assert "Harbor Ledger" in shown(em)
    clock.advance(2.0)


def events_of(sdir: Path, ev: str | None = None) -> list[dict]:
    p = sdir / "events.jsonl"
    rows = [json.loads(x) for x in p.read_text(encoding="utf-8").splitlines() if x.strip()]
    return [r for r in rows if ev is None or r["ev"] == ev]


# ---------------------------------------------------------------- (A) reading in fragments
def test_reading_a_three_sentence_card_in_fragments_fires_nothing_and_every_fragment_is_his(tmp_path, monkeypatch):
    async def go():
        b, t, em, clock, sdir, coro = italian_session(tmp_path, monkeypatch)
        await coro
        await first_card(b, em, clock)
        n_calls, n_cards = n_model_calls(t), len(cards(em))
        for i, frag in enumerate(FRAGMENTS):
            w = frag.split()
            for k in range(2, len(w) + 1, 2):                                   # cumulative partials, as the recognizer sends them
                await rpartial(b, f"f{i}", " ".join(w[:k]))
            await rturn(b, f"f{i}", frag, kind="statement")
            clock.advance(1.0)                                                   # a silence between two finals
        await settle(b)
        return b, t, em, n_calls, n_cards

    b, t, em, n_calls, n_cards = run(go())
    assert n_model_calls(t) == n_calls and len(cards(em)) == n_cards             # not one new call, not one new card
    assert [x.speaker for x in b.turns[1:]] == ["me"] * len(FRAGMENTS)
    assert b._own.cursor["orig"] >= 35                                           # the reading cursor sits at the end of the SAY line (about 40 words)


def test_a_reading_fragment_with_come_questo_fires_nothing(tmp_path, monkeypatch):
    """The sender of the live call marked the fragment as a question (the cue `come`) with 6+ words: it fired F."""
    async def go():
        b, t, em, clock, sdir, coro = italian_session(tmp_path, monkeypatch)
        await coro
        await first_card(b, em, clock)
        n = n_model_calls(t)
        for i, frag in enumerate(FRAGMENTS[:5]):
            await rturn(b, f"f{i}", frag)
            clock.advance(0.8)
        await rturn(b, "fc", FRAGMENT_COME, kind="question", cue=True, cue_why="come", cue_strong=True)
        await settle(b)
        return b, t, n

    b, t, n = run(go())
    assert n_model_calls(t) == n and b.turns[-1].speaker == "me"


def test_the_interviewer_quoting_two_card_words_mid_question_does_not_start_a_reading_session(tmp_path, monkeypatch):
    async def go():
        b, t, em, clock, sdir, coro = italian_session(tmp_path, monkeypatch)
        await coro
        await first_card(b, em, clock)
        # two card words ("feedback", "prodotto"), neither at the start of the card nor at a cursor: not his
        await rturn(b, "q2", "e che tipo di feedback ha ricevuto dagli utenti del prodotto", kind="question", cue=True, cue_why="che", cue_strong=False)
        reading_after_quote = b._own.reading_active()
        # a fragment from the middle of the card straight after is not entering the reading either
        await rturn(b, "q3", "la chiarezza degli obiettivi")
        await settle(b)
        return b, reading_after_quote

    b, reading = run(go())
    assert not reading and b._own.last_me is None
    assert [x.speaker for x in b.turns[1:]] == ["room", "room"]


def test_entering_a_reading_needs_the_start_of_the_card_and_a_session_ends_after_four_seconds(tmp_path, monkeypatch):
    async def go():
        b, t, em, clock, sdir, coro = italian_session(tmp_path, monkeypatch)
        await coro
        await first_card(b, em, clock)
        await rturn(b, "f0", FRAGMENTS[0])                                      # the start of the SAY line: reading begins
        assert b._own.reading_active()
        clock.advance(3.0)
        await rturn(b, "f1", FRAGMENTS[1])                                      # 3 s later: still the same session
        clock.advance(5.0)                                                       # a pause of 5 s: the session is over
        assert not b._own.reading_active()
        await rturn(b, "f2", FRAGMENTS[2])                                      # "focus sul prodotto" continues the card, but nobody is reading
        return b

    b = run(go())
    assert [x.speaker for x in b.turns[1:]] == ["me", "me", "room"]


# ---------------------------------------------------------------- a text that holds his reading and the next question
def test_a_mixed_text_gives_a_me_part_and_a_room_question_and_one_card_after_the_hold(tmp_path, monkeypatch):
    async def go():
        b, t, em, clock, sdir, coro = italian_session(tmp_path, monkeypatch, events=True)
        await coro
        await first_card(b, em, clock)
        for i, frag in enumerate(FRAGMENTS[:7]):
            await rturn(b, f"f{i}", frag)
            clock.advance(0.8)
        n_cards = len(cards(em))
        # his last words, and with no pause the interviewer's next question
        await rturn(b, "m1", "Ledger ha ridotto la chiusura mensile da sei giorni a due. Ottimo, come si descriverebbe come membro di un team", kind="question",
                    cue=True, cue_why="come si", cue_strong=True)
        held = [e for e in em.events if e.get("stage") == "room_held"]
        assert held and len(cards(em)) == n_cards and "Mi descrivo" not in shown(em)          # held: he may still be reading
        clock.advance(0.5)
        await asyncio.sleep(0.1)
        assert "Mi descrivo" not in shown(em)                                                  # 0.5 s of quiet is not enough
        clock.advance(1.0)
        await settle(b)
        return b, t, em, sdir

    b, t, em, sdir = run(go())
    assert [(x.turn_id, x.speaker) for x in b.turns[-2:]] == [("m1m", "me"), ("m1", "room")]
    assert b.turns[-2].text.endswith("da sei giorni a due.") and b.turns[-1].text.startswith("Ottimo, come si descriverebbe")
    assert "Mi descrivo" in shown(em)
    assert len([c for c in f_calls(t) if "membro di un team" in c.tail]) == 1                 # one card, not two
    ev = {r["ev"] for r in events_of(Path(b.session.path))}
    assert {"room_text", "card_held", "card_released", "card"} <= ev


# ---------------------------------------------------------------- the card hold
def test_a_new_card_waits_while_he_reads_and_card_now_always_fires(tmp_path, monkeypatch):
    async def go():
        b, t, em, clock, sdir, coro = italian_session(tmp_path, monkeypatch)
        await coro
        await first_card(b, em, clock)
        await rturn(b, "f0", FRAGMENTS[0])
        n = len(f_calls(t))
        # a weak cue (a bare wh-word) while he is reading: held
        await rturn(b, "w1", "a che cosa serve il suo prodotto nella pratica", kind="question", cue=True, cue_why="che", cue_strong=False)
        assert [e for e in em.events if e.get("stage") == "room_held"] and len(f_calls(t)) == n
        # the card key: fires at once
        await b.handle({"type": "control", "action": "card_now"})
        await settle(b)
        return b, t, em, n

    b, t, em, n = run(go())
    assert len(f_calls(t)) == n + 1 and em.of("metric", stage="room_held_dropped", reason="card_now")


def test_a_strong_cue_with_a_low_score_replaces_the_card_at_once_even_while_he_reads(tmp_path, monkeypatch):
    async def go():
        b, t, em, clock, sdir, coro = italian_session(tmp_path, monkeypatch)
        await coro
        await first_card(b, em, clock)
        await rturn(b, "f0", FRAGMENTS[0])
        n = len(f_calls(t))
        await rturn(b, "s1", "mi parli di lei e di un progetto dove ha guidato dei colleghi", kind="question", cue=True,
                    cue_why="mi parli", cue_strong=True)
        await settle(b)
        return t, em, n

    t, em, n = run(go())
    assert len(f_calls(t)) == n + 1 and not em.of("metric", stage="room_held")


def test_a_text_that_shares_a_lot_with_the_card_waits_even_with_a_strong_cue(tmp_path, monkeypatch):
    async def go():
        b, t, em, clock, sdir, coro = italian_session(tmp_path, monkeypatch)
        await coro
        await first_card(b, em, clock)
        await rturn(b, "f0", FRAGMENTS[0])
        n = len(f_calls(t))
        await rturn(b, "s1", "mi parli ancora del focus sul prodotto e della chiarezza degli obiettivi", kind="question", cue=True,
                    cue_why="mi parli", cue_strong=True)
        held = [e for e in em.events if e.get("stage") == "room_held"]
        return len(f_calls(t)) == n, held

    no_call, held = run(go())
    assert no_call and held and held[0]["reason"].startswith("own_score")


def test_a_newer_card_drops_the_held_one(tmp_path, monkeypatch):
    async def go():
        b, t, em, clock, sdir, coro = italian_session(tmp_path, monkeypatch)
        await coro
        await first_card(b, em, clock)
        await rturn(b, "f0", FRAGMENTS[0])
        await rturn(b, "w1", "a che cosa serve il suo prodotto nella pratica", kind="question", cue=True, cue_why="che", cue_strong=False)
        clock.advance(10.0)                                                       # the reading is long over ...
        await rturn(b, "w2", "mi parli di lei e di Trailhead", kind="question", cue=True, cue_why="mi parli", cue_strong=True)
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    assert b._held is None and em.of("metric", stage="room_held_dropped", reason="superseded")
    assert not any("serve il suo prodotto" in c.tail for c in f_calls(t))        # w1 never fired: w2's card dropped it


# ---------------------------------------------------------------- (B) yes/no questions
def test_a_yes_no_question_without_a_question_word_gets_its_card_through_the_probe(tmp_path, monkeypatch):
    async def go():
        b, t, em, clock, sdir, coro = italian_session(tmp_path, monkeypatch)
        await coro
        await first_card(b, em, clock)
        clock.advance(20.0)                                                       # not reading
        await rturn(b, "y1", "ha avuto esperienza nel presentare i risultati delle sue analisi", kind="statement")
        await settle(b)
        return t, em

    t, em = run(go())
    probes = [c for c in f_calls(t) if "STATEMENT CHECK (ROOM MICROPHONE)" in c.tail]
    assert len(probes) == 1 and "Sì, ho presentato" in shown(em)
    assert "A yes/no question has no question word" in probes[0].tail and "Language: Italian" in probes[0].tail
    assert "Ekip yönetme" in probes[0].tail                                          # the Turkish examples are there as well


def test_a_five_word_yes_no_question_reaches_the_probe_and_four_words_do_not(tmp_path, monkeypatch):
    async def go(text):
        b, t, em, clock, sdir, coro = italian_session(tmp_path, monkeypatch)
        await coro
        await rturn(b, "y1", text, kind="statement")
        await settle(b)
        return t

    assert len(f_calls(run(go("ha esperienza con SQL")))) == 0                       # 4 words
    assert len(f_calls(run(go("ha esperienza con SQL Server")))) == 1                 # 5 words


# ---------------------------------------------------------------- events.jsonl
def test_events_jsonl_records_every_decision(tmp_path, monkeypatch):
    async def go():
        b, t, em, clock, sdir, coro = italian_session(tmp_path, monkeypatch, events=True)
        await coro
        await first_card(b, em, clock)                                             # a card from a cue
        for i, frag in enumerate(FRAGMENTS[:3]):                                    # his reading
            await rturn(b, f"f{i}", frag)
            clock.advance(0.8)
        await rturn(b, "w1", "a che cosa serve il suo prodotto nella pratica", kind="question", cue=True, cue_why="che", cue_strong=False)
        clock.advance(2.0)
        await settle(b)                                                             # the held card is released
        clock.advance(20.0)
        await rturn(b, "y1", "ha avuto esperienza nel presentare i risultati", kind="statement")    # the probe
        await rturn(b, "z1", "grazie mille", kind="statement")                      # too short for anything
        await rturn(b, "o1", "scusi un momento devo rispondere", kind="statement")                  # probed: the model says statement
        await b.handle({"type": "control", "action": "card_now"})
        await settle(b)
        return b, sdir

    b, sdir = run(go())
    rows = events_of(sdir)
    kinds = [r["ev"] for r in rows]
    for needed in ("start", "turn", "room_text", "room_gate", "card", "card_held", "card_released", "probe", "card_suppressed", "card_now"):
        assert needed in kinds, (needed, sorted(set(kinds)))
    texts = [r for r in rows if r["ev"] == "room_text" and r.get("final")]
    mine = [r for r in texts if r["label"] == "me"]
    assert len(mine) >= 3 and {"rule", "share", "matched", "reading", "cursor"} <= set(mine[0])
    assert [r["rule"] for r in mine][0] == "start"                                     # how reading was entered
    card = next(r for r in rows if r["ev"] == "card")
    assert card["tier"] in ("S", "F") and len(card["text"]) <= 61 and card["turn"] == "r1"
    assert next(r for r in rows if r["ev"] == "probe")["verdict"] == "question"
    assert next(r for r in rows if r["ev"] == "card_held")["reason"] == "weak_cue"
    sup = {r["reason"] for r in rows if r["ev"] == "card_suppressed"}
    assert {"room_skipped", "probe_statement"} <= sup
    assert all("t" in r and "ev" in r for r in rows)
    assert not any(k in json.dumps(rows) for k in ("audio_bytes", "pcm"))               # text only


def test_the_log_is_written_in_the_session_folder_and_off_with_the_switch(tmp_path, monkeypatch):
    async def go(events):
        b, t, em, clock, sdir, coro = italian_session(tmp_path, monkeypatch, events=events)
        await coro
        await rturn(b, "r1", "grazie mille")
        return sdir

    assert (run(go(True)) / "events.jsonl").exists()
    assert not (run(go(False)) / "events.jsonl").exists()


# ---------------------------------------------------------------- own.py itself
def card_it() -> OwnSpeech:
    clock = Clock()
    o = OwnSpeech(OwnParams(), clock=clock)
    o.add("r1", "orig", "say", CARD_IT[0], new_say=True)
    for p in CARD_IT[1]:
        o.add("r1", "orig", "point", p)
    o.clock = clock
    return o


def test_italian_words_keep_their_accents_and_stems_merge_the_forms_of_a_word():
    from verse_brain.runtime.own import content_stems, tokenize   # new in this change: the behaviour tests above also run against the old code
    assert content_stems("più progetti", "it") == content_stems("piu progetto", "it")
    assert content_stems("sviluppatore", "it") == content_stems("sviluppa", "it")                 # a word cut off by the recognizer
    assert content_stems("anlattım anlatır", "tr")[0] == content_stems("anlatır", "tr")[0]
    assert [t.content for t in tokenize("il progetto è nato perché", "it")] == [False, True, False, True, False]
    assert [t.word for t in tokenize("month-end ehm close", "en")] == [0, 0, 2]                  # a filler gives no token; a hyphen two


def test_the_cursor_moves_with_the_reading_and_a_new_card_resets_it():
    o = card_it()
    assert o.judge(FRAGMENTS[0], "it").rule == "start"
    c0 = o.cursor["orig"]
    assert o.judge(FRAGMENTS[1], "it").label == "me" and o.cursor["orig"] > c0
    c1 = o.cursor["orig"]
    assert o.judge(FRAGMENTS[2], "it").label == "me" and o.cursor["orig"] > c1
    c2 = o.cursor["orig"]
    assert o.judge(FRAGMENTS[3], "it", turn_id="t3").label == "me" and o.cursor["orig"] > c2
    c3 = o.cursor["orig"]
    assert o.judge(FRAGMENTS[3], "it", turn_id="t3").label == "me" and o.cursor["orig"] == c3     # the same turn again (partial, then final)
    o.add("r2", "orig", "say", "Una risposta diversa sul progetto Trailhead.", new_say=True)
    assert o.cursor == {} and o.last_me is None and not o.reading_active()


def test_split_needs_four_trailing_words_two_of_them_content():
    def reading(k: int) -> OwnSpeech:
        o = card_it()
        for i, frag in enumerate(FRAGMENTS[:k]):
            assert o.judge(frag, "it", turn_id=f"f{i}").label == "me", frag
        return o

    tail = "Ottimo, come si descriverebbe come membro di un team"
    v = reading(7).judge("Ledger ha ridotto la chiusura mensile da sei giorni a due. " + tail, "it", turn_id="m")
    assert v.label == "split" and v.room_text == tail and v.me_text.endswith("giorni a due.")
    v = reading(4).judge("sia la chiarezza degli obiettivi. " + tail, "it", turn_id="m")
    assert v.label == "split" and v.room_text == tail
    # 5 trailing words that are all function words, and a single trailing word, do not split
    assert reading(4).judge("sia la chiarezza degli obiettivi. E poi anche a lei", "it", turn_id="m").label == "me"
    v = reading(4).judge("sia la chiarezza degli obiettivi. Grazie", "it", turn_id="m")
    assert v.label == "me" and not v.room_text


def test_english_fragments_follow_the_same_rules():
    o = OwnSpeech(clock=Clock())
    o.add("r1", "orig", "say", "I chose this school for its co-op program, and I chose accounting because I like turning messy payment data "
                              "into a clear story.", new_say=True)
    assert o.judge("I chose this school", "en").rule == "start"
    assert o.judge("for its co-op program", "en").label == "me"
    assert o.judge("what did you do there", "en").label == "room"


# ---------------------------------------------------------------- me_words on a split room_text (F1: the app relabels the first words as Alex)
def test_a_split_room_text_logs_how_many_leading_words_are_his(tmp_path, monkeypatch):
    mixed = "Ledger ha ridotto la chiusura mensile da sei giorni a due. Ottimo, come si descriverebbe come membro di un team"

    async def go():
        b, t, em, clock, sdir, coro = italian_session(tmp_path, monkeypatch, events=True)
        await coro
        await first_card(b, em, clock)
        for i, frag in enumerate(FRAGMENTS[:7]):
            await rturn(b, f"f{i}", frag)
            clock.advance(0.8)
        await rturn(b, "m1", mixed, kind="question", cue=True, cue_why="come si", cue_strong=True)
        clock.advance(1.5)
        await settle(b)
        return b, sdir

    b, sdir = run(go())
    rows = events_of(Path(b.session.path), "room_text")
    split = [r for r in rows if r.get("label") == "split" and r.get("final")]
    assert len(split) == 1
    me_turn = next(x for x in b.turns if x.turn_id == "m1m")
    n = split[0]["me_words"]
    assert n == len(me_turn.text.split()) > 3                              # the prefix word count, not a guess
    assert " ".join(mixed.split()[:n]) == me_turn.text.strip()             # and those are exactly the first n words of the room text
    assert all("me_words" not in r for r in rows if r.get("label") != "split")
