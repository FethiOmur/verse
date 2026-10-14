"""Grounding claims and the audio timeline (no `say`, no network)."""

import array
import math

import audio
import grounding

CORPUS = ("Lantern cut manual data entry from 11 minutes to 2 minutes per invoice and ran on 38,000 invoices a month. "
          "Ingrid Solberg (VP Engineering). Call: Thursday 22 October 2026. The AI team has 6 people. Accuracy 96.4 percent.")


def test_claims_extracts_numbers_dates_names():
    c = grounding.claims("SAY: Lantern ran on 38,000 invoices in October with Ingrid Solberg and six people.")
    assert "38000" in c["numbers"] and "6" in c["numbers"]
    assert c["dates"] == ["october"]
    assert c["names"] == ["Ingrid Solberg", "Lantern"] or "Ingrid Solberg" in c["names"]


def test_supported_line_has_no_unresolved_claims():
    line = "- Lantern cut entry from 11 minutes to 2 minutes and ran on 38,000 invoices a month."
    assert grounding.unresolved(line, CORPUS) == {}
    assert grounding.unresolved("SAY: The AI team has six people.", CORPUS) == {}   # word form of 6


def test_unsupported_number_and_name_are_found():
    un = grounding.unresolved("- Lantern saved 45 percent of the cost at Acme.", CORPUS)
    assert un["numbers"] == ["45"] and un["names"] == ["Acme"]


def test_number_in_the_question_is_allowed():
    assert grounding.unresolved("SAY: Yes, 99 is right.", CORPUS) != {}
    assert grounding.unresolved("SAY: Yes, 99 is right.", CORPUS, question="Is 99 the figure?") == {}


def test_assemble_lines_joins_chunks():
    ds = [{"id": "s1", "text": "SAY: Sure, ", "line_done": False}, {"id": "s1", "text": "short version.", "line_done": True},
          {"id": "d1", "text": "- A", "line_done": True}, {"id": "s1", "text": "- B", "line_done": True}]
    assert grounding.assemble_lines(ds) == {"s1": ["SAY: Sure, short version.", "- B"], "d1": ["- A"]}


def _tone(seconds, amp=8000, rate=audio.RATE):
    return array.array("h", [int(amp * math.sin(2 * math.pi * 220 * i / rate)) for i in range(int(seconds * rate))])


def test_speech_bounds_finds_the_tone():
    x = audio.silence(0.5) + _tone(1.0) + audio.silence(0.7)
    s, e = audio.speech_bounds(x)
    assert abs(s - 0.5) < 0.03 and abs(e - 1.5) < 0.03


def test_render_timeline(monkeypatch, tmp_path):
    def fake_say(voice, text, workdir, rate_wpm=None):
        samples = audio.silence(0.2) + _tone(1.0 if "long" in text else 0.5) + audio.silence(0.3)
        s, e = audio.speech_bounds(samples)
        return audio.Clip(samples, s, e)
    monkeypatch.setattr(audio, "say_clip", fake_say)
    utts = [{"speaker": "A", "text": "short", "gap_before": 0.0}, {"speaker": "F", "text": "", "silent_s": 3.0, "gap_before": 0.9},
            {"speaker": "A", "text": "long", "gap_before": 1.0}]
    r = audio.render(utts, {"A": "X"}, tmp_path, write_wav=True, lead_in=2.0)
    tl = r.timeline
    assert abs(tl[0]["t_start"] - 2.05) < 0.03 and abs(tl[0]["t_end"] - 2.55) < 0.04   # speech starts PAD_S into the clip
    assert tl[1]["silent"] and abs(tl[1]["t_start"] - (tl[0]["t_end"] + audio.PAD_S + 0.9)) < 0.1 and abs(tl[1]["t_end"] - tl[1]["t_start"] - 3.0) < 0.01
    assert abs((tl[2]["t_end"] - tl[2]["t_start"]) - 1.0) < 0.03
    assert r.path.exists() and abs(r.duration - (tl[2]["t_end"] + audio.PAD_S)) < 0.05
    assert audio.remove_workdir(tmp_path)
