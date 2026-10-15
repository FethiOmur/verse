"""T3: the teleprompter `script` command. A fake model stands in for Sonnet; nothing here touches the network.

The profile is the fictional one from the V1 fixtures ("Ada Marlowe"); the real one is personal data.
"""

import asyncio
import json
from pathlib import Path

import pytest

from verse_brain.prep import script as S
from verse_brain.prep.__main__ import main
from verse_brain.prep.model import ModelOutput, PrepError, Usage

PROFILE = (Path(__file__).parent / "fixtures" / "voice" / "profile_fictional.md").read_text(encoding="utf-8")


def run(coro):
    return asyncio.run(coro)


def words(n: int, start: str = "word") -> str:
    return " ".join(f"{start}{i}" for i in range(n))


def script_of(*page_sizes: int, cue: str = "") -> str:
    pages = [words(n, f"p{i}w") for i, n in enumerate(page_sizes)]
    if cue:
        pages[0] += f"\n{cue}"
    return "\n\n---\n\n".join(pages) + "\n"


class Scripted:
    """Returns the queued answers in order and records every call."""
    model = "claude-sonnet-5-5"

    def __init__(self, *answers: str):
        self.answers = list(answers)
        self.calls: list[tuple[str, str, int]] = []

    async def generate(self, system, user, max_tokens):
        self.calls.append((system, user, max_tokens))
        return ModelOutput(self.answers.pop(0), Usage(input=1000, output=400), "end_turn")


# ------------------------------------------------------------------------------------------ helpers


def test_target_words_follow_use_and_length():
    assert S.target_words(60, "recording") == 150
    assert S.target_words(60, "talk") == 130
    assert S.target_words(120, "recording") == 300
    assert S.target_words(15, "recording") == 40  # rounded to 5, never below 20


def test_spoken_words_skip_cues_and_page_breaks():
    text = "Hello there [pause] my friend.\n\n---\n\nSecond page [look at the camera] here."
    assert S.spoken_words(text) == 7


def test_clean_output_strips_fence_and_normalises_page_breaks():
    raw = "```markdown\nFirst page.\n---\nSecond page.\n\n\n\n---\n\nThird.\n---\n```\n"
    assert S.clean_output(raw) == "First page.\n\n---\n\nSecond page.\n\n---\n\nThird.\n"


def test_split_pages_matches_the_app_page_break_rule():
    assert S.split_pages("A one.\n\n---\n\nB two.\n\n---\n\nC three.\n") == ["A one.", "B two.", "C three."]


@pytest.mark.parametrize("text,fragment", [
    ("# Title\n\nSpoken words here.", "markdown"),
    ("- first point\n- second point", "markdown"),
    ("Short version: I build small tools.", "label"),
    ("Hook: I build small tools.", "label"),
    ("Here is your script:\n\nI build small tools.", "introduction"),
])
def test_problems_reject_markdown_labels_and_preamble(text, fragment):
    structural, _ = S.problems(S.clean_output(text), 5)
    assert structural and fragment in structural[0]


def test_natural_colons_in_the_middle_of_speech_are_fine():
    structural, _ = S.problems("I tell people one thing: what I tested.\n", 8)
    assert structural == []


# ------------------------------------------------------------------------------------------ prompt


def test_prompt_carries_style_guide_target_and_use():
    model = Scripted(script_of(70, 80))
    res = run(S.write_script_async("why I built Verse", 60, "recording", model, voice=PROFILE))
    system, user, _ = model.calls[0]
    assert "## STYLE GUIDE" in system and system.rstrip().endswith(PROFILE.strip())
    assert "Use: a short video recorded to camera" in system
    assert "Short version:" in system  # named only to forbid it
    assert "<topic>\nwhy I built Verse\n</topic>" in user and "150 spoken words" in user and "60 seconds" in user
    assert res.voice and res.pages == 2 and res.words == 150 and res.attempts == 1 and res.warnings == []


def test_talk_prompt_uses_the_talk_rules_and_pace():
    model = Scripted(script_of(65, 65))
    run(S.write_script_async("the demo talk", 60, "talk", model, voice=None))
    system, user, _ = model.calls[0]
    assert "Use: a talk or a presentation" in system and "recorded to camera" not in system
    assert "130 spoken words" in user
    assert "STYLE GUIDE (how" not in system  # no profile: no style section


def test_missing_voice_is_a_warning_not_an_error():
    res = run(S.write_script_async("t", 60, "recording", Scripted(script_of(150)), voice=None))
    assert res.voice is False and any("no voice profile" in w for w in res.warnings)


# ------------------------------------------------------------------------------------------ retry and limits


def test_too_long_is_asked_again_once_quoting_the_problem():
    model = Scripted(script_of(300), script_of(75, 75))
    res = run(S.write_script_async("t", 60, "recording", model, voice=PROFILE))
    assert res.attempts == 2 and res.words == 150
    assert "rejected" in model.calls[1][1] and "300 spoken words" in model.calls[1][1]
    assert res.usage.input == 2000  # both calls are summed


def test_structural_failure_twice_is_an_error():
    bad = "Short version: " + words(150)
    with pytest.raises(PrepError, match="label"):
        run(S.write_script_async("t", 60, "recording", Scripted(bad, bad), voice=None))


def test_length_off_by_a_little_after_the_retry_is_a_warning():
    model = Scripted(script_of(200), script_of(200))  # 133 percent of 150: outside soft, inside hard
    res = run(S.write_script_async("t", 60, "recording", model, voice=PROFILE))
    assert res.words == 200 and any("200 spoken words" in w for w in res.warnings)


def test_length_far_off_after_the_retry_is_an_error():
    with pytest.raises(PrepError, match="spoken words"):
        run(S.write_script_async("t", 60, "recording", Scripted(script_of(20), script_of(20)), voice=PROFILE))


@pytest.mark.parametrize("kw,msg", [
    (dict(topic=" ", seconds=60, use="recording"), "topic is empty"),
    (dict(topic="t", seconds=5, use="recording"), "length"),
    (dict(topic="t", seconds=5000, use="recording"), "length"),
    (dict(topic="t", seconds=60, use="podcast"), "use must be"),
    (dict(topic="x" * 9000, seconds=60, use="recording"), "limit"),
])
def test_input_validation(kw, msg):
    with pytest.raises(PrepError, match=msg):
        run(S.write_script_async(kw["topic"], kw["seconds"], kw["use"], Scripted()))


# ------------------------------------------------------------------------------------------ CLI


def test_cli_fake_json(capsys):
    assert main(["script", "--topic", "why I built Verse", "--seconds", "60", "--use", "recording", "--fake", "--json",
                 "--no-voice"]) == 0
    out, err = capsys.readouterr()
    data = json.loads(out)
    assert data["pages"] >= 2 and 135 <= data["words"] <= 165 and data["voice"] is False
    assert "\n\n---\n\n" in data["text"] and data["target_words"] == 150
    assert "script:" in err and "no voice profile" in err


def test_cli_fake_plain_text_with_a_voice_file(tmp_path, capsys):
    voice = tmp_path / "voice.md"
    voice.write_text(PROFILE, encoding="utf-8")
    assert main(["script", "--topic", "a talk", "--seconds", "120", "--use", "talk", "--fake",
                 "--voice-profile", str(voice)]) == 0
    out, err = capsys.readouterr()
    assert out.count("---") >= 2 and not out.startswith("{")
    assert "voice yes" in err


def test_cli_topic_file_and_errors(tmp_path, capsys):
    topic = tmp_path / "topic.txt"
    topic.write_text("the topic from a file", encoding="utf-8")
    assert main(["script", "--topic-file", str(topic), "--fake", "--no-voice", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["words"] > 0
    assert main(["script", "--topic", "t", "--seconds", "3", "--fake", "--no-voice"]) == 1
    assert "error:" in capsys.readouterr().err
    assert main(["script", "--topic", "t", "--fake", "--voice-profile", str(tmp_path / "nope.md")]) == 1
    assert "voice profile not found" in capsys.readouterr().err
