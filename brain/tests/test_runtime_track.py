"""Reading-track fixes after the live English call of 17 Oct (phone on speaker, unprepared session, general prep):

1. the partials of ONE turn are cumulative; each is judged from the cursor the turn started at and a turn once taken for his keeps
   its label while its share stays above the exit level (no room/me/split flicker, no strict-rule fallback at the final);
2. a held card fires only after 1.2 s without reading-like room speech, and a held text that is mostly the card is dropped;
3. a room text that is mostly the card on screen never reaches the statement probe, and the probe is told what the card says;
4. every line on screen is a card line: S/F SAY and points, D's points, a bank hit's opener and points;
5. a point that talks about the pack / notes / profile is dropped before it is shown (`point_dropped`).

The fixtures are fictional (a data analyst called Mara) and mimic the shape of the live partials, not their text."""

from __future__ import annotations

import json
from pathlib import Path

from test_runtime_helpers import run, settle
from test_runtime_me import make, me_spec, session_dir, start

from verse_brain.runtime.fake import lines_script
from verse_brain.runtime.lines import LineAssembler, is_meta
from verse_brain.runtime.own import OwnSpeech

SAY = "I am a data analyst who builds reporting tools for small logistics teams, most recently a dashboard called Pier Ledger."
P1 = "I studied statistics at Northgate University, then joined a freight firm as a junior analyst in my first year."
P2 = "At Pier Ledger I cut the weekly report time from two days to three hours."
CARD = (SAY, [P1, P2])

# his reading of P1 as the recognizer delivered it: cumulative partials of ONE turn, ending in the final (words dropped / swapped)
# (the 7-word partial has too few of the card's words in a row for the start rule's share: the live partial that fell back to `room`)
READING_P1 = "I studied at the then a joined a freight at as junior analyst in my first year".split()
STEPS = [2, 3, 7, 8, 13, len(READING_P1)]


def own_with_card() -> OwnSpeech:
    o = OwnSpeech()
    o.add("q1", "orig", "say", SAY, new_say=True)
    for p in CARD[1]:
        o.add("q1", "orig", "point", p)
    return o


def read_say(o: OwnSpeech, t: float = 0.0) -> None:
    w = SAY.split()
    for tid, a, b in (("s1", 0, 11), ("s2", 11, len(w))):
        text = " ".join(w[a:b])
        o.judge(text, "en", turn_id=tid, now=t, final=True)
        t += 1.0


# ---------------------------------------------------------------- 1. one turn, cumulative partials
def test_every_partial_and_the_final_of_one_turn_are_his_once_it_has_started():
    o = own_with_card()
    read_say(o)
    labels = []
    for n in STEPS:
        v = o.judge(" ".join(READING_P1[:n]), "en", turn_id="t1", now=3.0 + n * 0.1, final=(n == len(READING_P1)))
        labels.append((n, v.label))
    assert labels[0][1] == "room"                                  # two words prove nothing
    assert [lab for _, lab in labels[1:]] == ["me"] * (len(labels) - 1), labels   # from "I studied at" on: me, to the final


def test_the_cursor_of_the_turn_does_not_move_its_own_anchor():
    """The continue rule measures from the cursor at the turn's first word, also when that was a card nobody had read yet."""
    o = own_with_card()
    v = o.judge("I studied at", "en", turn_id="t1", now=1.0)
    assert v.label == "me" and v.rule == "start"
    track = o._turns["t1"]
    assert track.base == {} and track.entry is not None            # anchored before the partial moved the cursor
    assert o.cursor["orig"] > 0


def test_a_turn_that_stops_lining_up_falls_below_the_exit_level():
    o = own_with_card()
    assert o.judge("I studied at Northgate University", "en", turn_id="t1", now=1.0).label == "me"
    # the same range now holds the next speaker's question: the share of the whole text on the path drops below 0.6 and the
    # turn is cut where the card stops (his prefix is `me`, the rest is a room text)
    v = o.judge("I studied at Northgate University and then why did the team decide to move the whole project to another city", "en",
                turn_id="t1", now=1.5)
    assert v.label == "split" and v.room_text.startswith("why did") and v.rule != "stay"


# ---------------------------------------------------------------- the engine: the live sequence, no probe, no new card
def responder(info):
    tail = info.tail
    if "STATEMENT CHECK" in tail:
        return lines_script("KIND: question\nSAY: Sure.\n- a point.\n- b point.\nBANK: none")
    if info.route == "D":
        return lines_script("OPENER_OK\n- I also tracked delivery delays with a weekly check (f001)\n- The pack has no stated reason for the school. "
                            "Say what is true about it (f002)")
    if "about yourself" in tail:
        return lines_script(f"SAY: {SAY}\n- {P1}\n- {P2}\nBANK: none")
    return lines_script("SAY: Sure, here is the short answer.\n- First point.\n- Second point.\nBANK: none")


class Clock:
    def __init__(self) -> None:
        self.t = 100.0

    def __call__(self) -> float:
        return self.t

    def advance(self, s: float) -> None:
        self.t += s


def events_of(sdir, ev=None):
    rows = [json.loads(x) for x in (Path(sdir) / "events.jsonl").read_text(encoding="utf-8").splitlines() if x.strip()]
    return [r for r in rows if ev is None or r["ev"] == ev]


async def rpartial(b, tid, text, **extra):
    await b.handle({"type": "partial", "turn_id": tid, "speaker": "room", "text": text, "cue": False, "t_audio_end": 0.0, **extra})


async def rturn(b, tid, text, kind="statement", **extra):
    await b.handle({"type": "turn", "turn_id": tid, "speaker": "room", "text": text, "addressee": "unknown", "kind": kind,
                    "t_audio_end": 0.0, **extra})


def f_calls(t):
    return [c for c in t.by_route("F") if "SUMMARIZE" not in c.tail]


def n_calls(t):
    return len([c for c in t.calls if "SUMMARIZE" not in c.tail])


def shown(em):
    return "".join(e["text"] for e in em.of("delta"))


def room(tmp_path, monkeypatch, *, bank=False, mode="unprepared"):
    monkeypatch.setenv("VERSE_EVENTS", "1")
    b, t, em, _ = make(tmp_path, embedder=False, responder=responder)
    clock = Clock()
    b._clock = clock
    sdir = session_dir(tmp_path, bank=bank)
    return b, t, em, clock, sdir, start(b, sdir, me=me_spec(), mode=mode, route="room", follow=True)


async def first_card(b, em, clock):
    await rturn(b, "q1", "why don't you tell me about yourself", kind="question", cue=True, cue_why="tell me", cue_strong=True)
    await settle(b)
    assert "Pier Ledger" in shown(em)
    clock.advance(2.0)


def test_the_live_sequence_of_partials_fires_no_probe_and_no_card(tmp_path, monkeypatch):
    async def go():
        b, t, em, clock, sdir, coro = room(tmp_path, monkeypatch)
        await coro
        await first_card(b, em, clock)
        w = SAY.split()
        for tid, a, c in (("s1", 0, 11), ("s2", 11, len(w))):          # the SAY line first, in two finals
            await rturn(b, tid, " ".join(w[a:c]))
            clock.advance(1.0)
        calls, delta = n_calls(t), len(em.of("delta"))
        labels = []
        for n in STEPS:
            text = " ".join(READING_P1[:n])
            if n == len(READING_P1):
                await rturn(b, "t1", text)
            else:
                await rpartial(b, "t1", text)
            labels.append(b._own_turns["t1"])
            clock.advance(0.3)
        await settle(b)
        return b, t, em, calls, delta, labels

    b, t, em, calls, delta, labels = run(go())
    assert labels[1:] == ["me"] * 5, labels
    assert n_calls(t) == calls and len(em.of("delta")) == delta        # no probe, no new card
    assert [x.speaker for x in b.turns][-1] == "me" and not em.of("metric", stage="statement_probe")


# ---------------------------------------------------------------- 2. the hold
def test_a_held_card_fires_only_after_1_2_seconds_without_reading_speech(tmp_path, monkeypatch):
    """Live: `card_held` then `card_released held_s 0.0` -- the quiet clock only knew the last text taken for his, which was older."""
    import asyncio

    async def go():
        b, t, em, clock, sdir, coro = room(tmp_path, monkeypatch)
        await coro
        await first_card(b, em, clock)
        await rturn(b, "s1", " ".join(SAY.split()[:11]))               # he reads: a reading session opens
        await settle(b)
        clock.advance(2.5)                                              # ... 2.5 s ago: the session is still open, his quiet is > 1.2 s
        n = n_calls(t)
        # a weak-cue question that shares some of the card (score between 0.35 and 0.5): it waits for the end of the reading
        await rturn(b, "w1", "and how did a junior analyst cope in the first year at the freight firm", kind="question", cue=True,
                    cue_why="how", cue_strong=False)
        assert [e for e in em.events if e.get("stage") == "room_held"] and n_calls(t) == n
        clock.advance(0.6)
        await asyncio.sleep(0.15)
        assert n_calls(t) == n                                         # 0.6 s of quiet: still held
        clock.advance(0.8)
        await settle(b)
        return b, t, em, sdir, n

    b, t, em, sdir, n = run(go())
    assert n_calls(t) > n
    rel = events_of(b.session.path, "card_released")
    assert rel and rel[0]["held_s"] >= 1.2, rel


def test_a_held_text_that_is_mostly_the_card_is_dropped_and_card_now_still_fires(tmp_path, monkeypatch):
    async def go():
        b, t, em, clock, sdir, coro = room(tmp_path, monkeypatch)
        await coro
        await first_card(b, em, clock)
        await rturn(b, "s1", " ".join(SAY.split()[:11]))
        await settle(b)
        n = n_calls(t)
        # a question with a strong cue whose words are mostly the card's (score 0.55, six words matched) while he is reading it
        await rturn(b, "r2", "so please tell me whether you studied statistics at Northgate University and what happened later during your "
                    "first year at the freight firm", kind="question", cue=True, cue_why="tell me", cue_strong=True)
        clock.advance(5.0)
        await settle(b)
        assert n_calls(t) == n and b._held is None                      # never fired, not even after the quiet
        await b.handle({"type": "control", "action": "card_now"})
        await settle(b)
        return b, t, em, n

    b, t, em, n = run(go())
    assert n_calls(t) > n                                               # card-now is the only way
    sup = events_of(b.session.path, "card_suppressed")
    assert any(str(r.get("reason", "")).startswith("held_dropped:own_score") for r in sup), sup


# ---------------------------------------------------------------- 3. the probe
def test_a_statement_that_is_mostly_the_card_gets_no_probe_and_the_probe_is_told_the_card(tmp_path, monkeypatch):
    async def go():
        b, t, em, clock, sdir, coro = room(tmp_path, monkeypatch)
        await coro
        await first_card(b, em, clock)
        clock.advance(10.0)                                             # no reading session: only the score can tell
        n = n_calls(t)
        # the rules say `room` (the share is 0.55), the score says it is mostly the card
        await rturn(b, "r2", "so please tell me whether you studied statistics at Northgate University and what happened later during your "
                    "first year at the freight firm", kind="statement")
        await settle(b)
        assert n_calls(t) == n and not em.of("metric", stage="statement_probe")
        # a statement that is not the card: probed, and the probe sees the card on his screen
        await rturn(b, "r3", "thanks for sharing that with us and now let me tell you a little about the company", kind="statement")
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    probes = [c for c in f_calls(t) if "STATEMENT CHECK" in c.tail]
    assert len(probes) == 1
    tail = probes[0].tail
    assert "THE CARD ON HIS SCREEN" in tail and SAY in tail and P1 in tail
    assert "it is the candidate reading the card: KIND: statement" in tail


# ---------------------------------------------------------------- 4. card coverage: D points and bank cards
def test_reading_a_d_point_is_his_even_from_its_first_words(tmp_path, monkeypatch):
    async def go():
        b, t, em, clock, sdir, coro = room(tmp_path, monkeypatch)
        await coro
        await first_card(b, em, clock)
        assert "weekly check" in shown(em)                              # D's first point is on screen
        calls = n_calls(t)
        text = "I also tracked delivery delays with a weekly check".split()
        labels = []
        for n in (2, 3, 5, len(text)):
            if n == len(text):
                await rturn(b, "d1", " ".join(text))
            else:
                await rpartial(b, "d1", " ".join(text[:n]))
            labels.append(b._own_turns["d1"])
        await settle(b)
        return b, t, em, calls, labels

    b, t, em, calls, labels = run(go())
    assert labels == ["room", "me", "me", "me"] and n_calls(t) == calls      # "I also tracked" is the start of a line of the card


def test_reading_a_bank_hit_card_is_his(tmp_path, monkeypatch):
    async def go():
        b, t, em, clock, sdir, coro = room(tmp_path, monkeypatch, bank=True, mode="prepared")
        await coro
        await b.handle({"type": "bank_hit", "turn_id": "q9", "bank_id": "b001", "score": 0.9})
        assert "bank" in [r.get("source") for r in events_of(b.session.path, "own_card")]
        calls = n_calls(t)
        text = "Sure, here is the short version. I led Lantern, an invoice-extraction pipeline. It cut data entry from 11 to 2 minutes".split()
        for n in (3, 6, 11, len(text)):
            if n == len(text):
                await rturn(b, "bk1", " ".join(text))
            else:
                await rpartial(b, "bk1", " ".join(text[:n]))
        await settle(b)
        return b, t, calls

    b, t, calls = run(go())
    assert b._own_turns["bk1"] == "me" and [x.speaker for x in b.turns][-1] == "me"


# ---------------------------------------------------------------- 5. meta points
def test_a_point_about_the_pack_is_dropped_before_it_is_shown_and_logged(tmp_path, monkeypatch):
    async def go():
        b, t, em, clock, sdir, coro = room(tmp_path, monkeypatch)
        await coro
        await first_card(b, em, clock)
        return b, em

    b, em = run(go())
    text = shown(em)
    assert "weekly check" in text and "no stated reason" not in text and "Say what is true" not in text
    dropped = events_of(b.session.path, "point_dropped")
    assert dropped and dropped[0]["tier"] == "D" and "no stated reason" in dropped[0]["text"]


def test_the_meta_patterns():
    for bad in ("- The pack has no stated reason for the school. Say what is true about it", "- Your notes do not say why",
                "- Not stated in the profile", "- The profile does not mention this", "- Say what is true about the school"):
        assert is_meta(bad), bad
    for good in ("- I took careful notes during every client call", "- I built a profile page for each supplier",
                 "- At Pier Ledger I cut the weekly report time from two days to three hours."):
        assert not is_meta(good), good


def test_the_assembler_drops_a_meta_point_whole_and_keeps_streaming_the_others():
    got, dropped = [], []
    la = LineAssembler(lambda c, d, line: got.append((c, d)), lambda c: None, on_drop=dropped.append)
    la.feed("- The pack has no stated ")
    la.feed("reason for it.\n- I led the report team")
    la.feed(" for two years.\n")
    assert dropped == ["- The pack has no stated reason for it."]
    assert "".join(c for c, _ in got).strip() == "I led the report team for two years." or "".join(c for c, _ in got).endswith("for two years.")
    assert "pack" not in "".join(c for c, _ in got)


# ---------------------------------------------------------------- bonus: replay a room_text log against a card
def replay(rows: list[dict], card: list[tuple[str, str]], lang: str = "en") -> list[tuple[str, str]]:
    """events.jsonl `room_text`-style rows ({"turn", "text", "final"}) in order against the card lines: (turn, label) per row."""
    o = OwnSpeech()
    for i, (kind, text) in enumerate(card):
        o.add("c", "orig", kind, text, new_say=(i == 0 and kind == "say"))
    out, t = [], 0.0
    for r in rows:
        t += 0.3
        out.append((r["turn"], o.judge(r["text"], lang, turn_id=r["turn"], now=t, final=bool(r.get("final"))).label))
    return out


def test_replay_helper_gives_the_decisions_of_a_logged_turn():
    rows = [{"turn": "t1", "text": " ".join(READING_P1[:n]), "final": n == len(READING_P1)} for n in STEPS]
    got = replay(rows, [("say", SAY), ("point", P1), ("point", P2)])
    assert [lab for _, lab in got][1:] == ["me"] * 5


def test_the_me_and_unprepared_prompts_forbid_lines_about_the_preparation():
    from verse_brain.runtime import prompt
    for system in (*prompt.SYSTEMS_ME.values(), *prompt.SYSTEMS_UNPREPARED.values()):
        assert "No line may talk about the preparation" in system and "no stated reason" in system
    assert "no line about the pack" in prompt.follow_tail("q", "en", "words", ["SAY: x"], [], None, "diverged")
