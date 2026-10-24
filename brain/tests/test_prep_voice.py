"""V1: the voice profile. Distillation parsing and cap, and the profile in meeting packs, sim packs and the CLI.

Every profile and source text here is fictional ("Ada Marlowe"); the real profile is personal data and never enters the
repo.
"""

import asyncio
import json
from pathlib import Path

import pytest

from test_prep_pipeline import NOTE, NOW, FakeModel, FakeVault, extra_fields
from test_prep_sim import FakeSimModel, Scripted, build_with, payload
from verse_brain.prep import build
from verse_brain.prep import voice as V
from verse_brain.prep.__main__ import main
from verse_brain.prep.model import ModelOutput, PrepError, Usage
from verse_brain.prep.pack import fit_pack, render_pack
from verse_brain.prep.sim_pack import render_sim_pack

FIX = Path(__file__).parent / "fixtures" / "voice"
PROFILE = (FIX / "profile_fictional.md").read_text(encoding="utf-8")
SOURCE = FIX / "source_fictional.txt"


def run(coro):
    return asyncio.run(coro)


@pytest.fixture
def voice_file(tmp_path):
    p = tmp_path / "profile" / "voice.md"
    p.parent.mkdir()
    p.write_text(PROFILE, encoding="utf-8")
    return p


# ------------------------------------------------------------------------------------------ parsing and cap


def test_parse_fixture_profile():
    p = V.parse_profile(PROFILE)
    assert list(p.sections) == list(V.SECTIONS)
    assert len(p.sections[V.SAMPLES]) == 5
    assert p.sections["Tone"][0].startswith("Warm, calm")
    assert p.render() == PROFILE  # canonical form is stable


def test_parse_tolerates_fence_preamble_and_wrapped_bullets():
    raw = "Here is the profile:\n```markdown\n" + PROFILE.replace("Short sentences, about", "Short sentences,\n  about") + "```\n"
    p = V.parse_profile(raw)
    assert p.sections["Sentence length and level"][0].startswith("Short sentences, about 8 to 14 words")


@pytest.mark.parametrize("mutate,msg", [
    (lambda t: t.replace("### Words to avoid", "### Other"), "unknown section"),
    (lambda t: t.split("### Words to avoid")[0] + "### Positions he holds" + t.split("### Positions he holds")[1], "missing"),
    (lambda t: t + "\n### Tone\n- again\n", "twice"),
    (lambda t: t.replace("- \"Leverage\", \"synergy\", \"passionate\", \"great question\", and any big-sounding claim.\n", ""), "empty"),
    (lambda t: "\n".join(ln for ln in t.splitlines() if not ln.startswith(("- Sometimes", "- Small tools are", "- I say it plainly", "- I built"))), "style example"),
    (lambda t: t.replace("- If a list and a button solve it, stop there.\n", "").replace("- Ship first, then ask people what they really need.\n", ""), "position"),
])
def test_parse_rejects(mutate, msg):
    with pytest.raises(PrepError, match=msg):
        V.parse_profile(mutate(PROFILE))


def test_cap_drops_examples_from_the_tail_but_keeps_two():
    p = V.parse_profile(PROFILE)
    total = p.words()
    text, kept = V.fit_profile(p, cap=total)
    assert kept == 5 and text == PROFILE
    text, kept = V.fit_profile(p, cap=total - 1)  # one word too many: the last example goes
    assert kept == 4 and "Small tools are my thing" not in text and "Sometimes I keep polishing" in text
    text, kept = V.fit_profile(p, cap=p.words(2))
    assert kept == 2 and len(text.split()) <= p.words(2)
    with pytest.raises(PrepError, match="cap is"):
        V.fit_profile(p, cap=p.words(2) - 1)


def test_question_tags_are_stripped_from_examples():
    tagged = PROFILE.replace("- I built a seed-swap", "- [Tell me about a project] I built a seed-swap")
    p = V.parse_profile(tagged)
    assert p.sections[V.SAMPLES][0].startswith("I built a seed-swap")
    assert "[" not in p.render() and p.render() == PROFILE


def test_positions_are_required_and_between_three_and_five():
    p = V.parse_profile(PROFILE)
    assert len(p.sections[V.POSITIONS]) == 3 and V.POSITIONS in p.render()
    six = PROFILE.replace("### Style examples", "- a\n- b\n- c\n\n### Style examples")
    with pytest.raises(PrepError, match="position"):
        V.parse_profile(six)


def test_label_openers_are_dropped_but_phrases_stay():
    labelled = PROFILE.replace('- "The plain version is ..."', '- "Short version:"\n- "Bottom line: ..."\n- "The plain version is ..."')
    p = V.parse_profile(labelled)
    ops = p.sections["Openers and phrasings"]
    assert not any("Short version" in o or "Bottom line" in o for o in ops)
    assert any("plain version" in o for o in ops) and p.render() == PROFILE
    only_labels = PROFILE.replace('- "Sure, a good example is ..."', '- "Short version:"').replace('- "The plain version is ..."\n', '').replace(
        '- "I haven\'t done that exactly, but here\'s how I\'d start."', '- "Bottom line:"')
    with pytest.raises(PrepError, match="usable openers"):
        V.parse_profile(only_labels)


def test_openers_are_options_not_defaults():
    p = V.parse_profile(PROFILE)
    assert p.sections["Openers and phrasings"][0].startswith("Options only: use at most one per answer")
    assert "at most one per answer, vary them, and often use none" in V.SYSTEM and "label-style opener" in V.SYSTEM
    assert V.parse_profile(V.FAKE_PROFILE).sections["Openers and phrasings"][0].startswith("Options only")


def test_cap_counts_the_whole_rendered_block():
    long_tone = " ".join(["word"] * 800)
    p = V.parse_profile(PROFILE.replace("- Warm, calm and plain-spoken. Friendly without gushing.", f"- {long_tone}"))
    with pytest.raises(PrepError):
        V.fit_profile(p)
    assert V.WORD_CAP == 650


class ScriptedVoice:
    model = "claude-sonnet-5-5"

    def __init__(self, *outputs):
        self.outputs, self.calls = list(outputs), []

    async def generate(self, system, user, max_tokens):
        self.calls.append((system, user, max_tokens))
        return ModelOutput(self.outputs.pop(0), Usage(input=100, output=50), "end_turn")

    async def count_tokens(self, text):
        return len(text) // 4

    async def count_request_tokens(self, system, user):
        return (len(system) + len(user)) // 4


def test_distill_returns_the_block_and_sums_usage():
    m = ScriptedVoice(PROFILE)
    text, usage, kept = run(V.distill_async(SOURCE.read_text(encoding="utf-8"), m))
    assert text == PROFILE and kept == 5 and usage.input == 100
    system, user, max_tokens = m.calls[0]
    assert system == V.SYSTEM and "<source>" in user and "seed-swap" in user and max_tokens >= 4000


def test_distill_asks_again_once_with_the_reason():
    m = ScriptedVoice("### Tone\n- only this\n", PROFILE)
    text, usage, kept = run(V.distill_async("some source text", m))
    assert text == PROFILE and usage.input == 200 and usage.output == 100
    assert "previous answer was rejected" in m.calls[1][1] and "missing section" in m.calls[1][1]


def test_distill_gives_up_after_two_attempts():
    m = ScriptedVoice("nope", "still nope")
    with pytest.raises(PrepError, match="failed after 2 attempts"):
        run(V.distill_async("some source text", m))


def test_distill_rejects_empty_and_oversized_source_and_tiny_budget():
    m = ScriptedVoice(PROFILE)
    with pytest.raises(PrepError, match="empty"):
        run(V.distill_async("  \n", m))
    with pytest.raises(PrepError, match="limit"):
        run(V.distill_async("x" * (V.MAX_SOURCE_CHARS + 1), m))
    with pytest.raises(PrepError, match="budget"):
        run(V.distill_async("some source text", m, budget_usd=0.001))


def test_load_voice(tmp_path, voice_file):
    assert V.load_voice(None) is None
    assert V.load_voice(tmp_path / "missing.md") is None
    empty = tmp_path / "empty.md"
    empty.write_text(" \n\n", encoding="utf-8")
    assert V.load_voice(empty) is None
    voice_file.write_text("\n\n" + PROFILE + "\n\n\n", encoding="utf-8")
    assert V.load_voice(voice_file) == PROFILE  # stripped, one trailing newline
    bad = tmp_path / "bad.md"
    bad.write_bytes(b"\xff\xfe\x00")
    with pytest.raises(PrepError, match="cannot read"):
        V.load_voice(bad)


def test_strip_voice_removes_only_a_trailing_voice_section():
    pack = "## FACTS\n[f001] x\n\n## SNIPPETS\n[s001] y\n"
    assert V.strip_voice(pack) == pack
    assert V.strip_voice(V.with_voice(pack, PROFILE)) == pack
    legacy = pack + "\n## USER'S VOICE (source: prep:voice)\n- Tone: relaxed.\n  - nested\n"
    assert V.strip_voice(legacy) == pack
    old = pack + "\n## VOICE (earlier header)\n- a\n"
    assert V.strip_voice(old) == pack
    mid = "## FACTS\n[f001] x\n\n## VOICE old\n- a\n\n## SNIPPETS\n[s001] y\n"
    assert V.strip_voice(mid) == mid  # not at the end: left alone


# ------------------------------------------------------------------------------------------ meeting pack


def test_render_pack_without_voice_is_unchanged():
    facts = [{"id": "f001", "kind": "number", "text": "t", "value": "1", "sources": [{"kind": "prep", "ref": "prep:L1", "quote": "q"}]}]
    base = render_pack(facts, [], [], [])
    assert render_pack(facts, [], [], [], None) == base
    with_v = render_pack(facts, [], [], [], PROFILE)
    assert with_v.startswith(base) and with_v.endswith(PROFILE)
    assert with_v.count("\n## STYLE GUIDE") == 1 and with_v.index("## STYLE GUIDE") > with_v.index("## FACTS")
    assert "not evidence, never cite" in V.MEETING_HEADER and "not evidence, never cite" in V.SIM_HEADER
    assert "## VOICE" not in with_v


def test_fit_pack_never_trims_the_voice_and_counts_it():
    async def count(t):
        return len(t) // 4

    facts = [{"id": f"f{i:03d}", **extra_fields("f", i, "")} for i in range(1, 400)]
    text, tokens, cut = run(fit_pack(facts, [], [], [], count, cap=3000, voice=PROFILE))
    assert text.endswith(PROFILE) and V.VOICE_HEADING in text
    assert tokens <= int(3000 * 0.97) and cut["facts"] > 0
    plain, _, cut_plain = run(fit_pack(facts, [], [], [], count, cap=3000))
    assert cut["facts"] > cut_plain["facts"]  # the voice took room the facts would have had
    assert V.VOICE_HEADING not in plain


def _build(tmp_path, name, **kw):
    return build(NOTE, [], ["en", "it"], tmp_path / name, max_questions=80, model=FakeModel(), vault=FakeVault(), now=NOW, **kw)


def test_pipeline_pack_carries_the_voice_byte_identically(tmp_path, voice_file):
    a, b = _build(tmp_path, "a", voice_path=voice_file), _build(tmp_path, "b", voice_path=voice_file)
    pa = (a / "pack.md").read_bytes()
    assert pa == (b / "pack.md").read_bytes()
    pack = pa.decode()
    assert pack.endswith(V.render_voice_section(PROFILE) )
    assert pack.index("## SNIPPETS") < pack.index(V.VOICE_HEADING)
    assert "Ada" not in pack and a.name not in pack and str(voice_file) not in pack  # nothing per-run
    meta = json.loads((a / "meta.json").read_text(encoding="utf-8"))
    assert meta["stats"]["voice_sha256"] == V.sha256_text(PROFILE)


def test_pipeline_without_a_profile_is_unchanged(tmp_path, voice_file):
    plain = _build(tmp_path, "plain")
    for kw in ({"voice_path": None}, {"voice_path": tmp_path / "nope" / "voice.md"}):
        other = _build(tmp_path, "other", **kw)
        for name in ("pack.md", "bank.jsonl", "facts.jsonl", "glossary.jsonl", "snippets.jsonl"):
            assert (plain / name).read_bytes() == (other / name).read_bytes(), name
        assert "voice_sha256" not in json.loads((other / "meta.json").read_text(encoding="utf-8"))["stats"]
    voiced = _build(tmp_path, "voiced", voice_path=voice_file)
    assert (voiced / "pack.md").read_text(encoding="utf-8").startswith((plain / "pack.md").read_text(encoding="utf-8"))
    for name in ("bank.jsonl", "facts.jsonl", "glossary.jsonl", "snippets.jsonl"):
        assert (plain / name).read_bytes() == (voiced / name).read_bytes(), name  # the voice only touches pack.md


# ------------------------------------------------------------------------------------------ sim pack


def test_sim_pack_voice_section(tmp_path, voice_file):
    plain = build_with(tmp_path, FakeSimModel(), out="plain")
    voiced = build_with(tmp_path, FakeSimModel(), out="voiced", voice_path=voice_file)
    again = build_with(tmp_path, FakeSimModel(), out="again", voice_path=voice_file)
    p_plain = (plain / "sim_pack.md").read_text(encoding="utf-8")
    p_voiced = (voiced / "sim_pack.md").read_text(encoding="utf-8")
    assert (voiced / "sim_pack.md").read_bytes() == (again / "sim_pack.md").read_bytes()
    assert p_voiced.startswith(p_plain) and p_voiced.endswith(PROFILE)
    assert V.SIM_HEADER in p_voiced and "COACH" in V.SIM_HEADER and V.MEETING_HEADER not in p_voiced
    sim = json.loads((voiced / "sim.json").read_text(encoding="utf-8"))
    assert sim["voice_sha256"] == V.sha256_text(PROFILE)
    assert "voice_sha256" not in json.loads((plain / "sim.json").read_text(encoding="utf-8"))
    assert render_sim_pack(sim, PROFILE) == p_voiced
    assert render_sim_pack(json.loads((plain / "sim.json").read_text(encoding="utf-8"))) == p_plain


def test_sim_pack_voice_with_a_scripted_plan(tmp_path, voice_file):
    s = build_with(tmp_path, Scripted(payload()), voice_path=voice_file)
    assert (s / "sim_pack.md").read_text(encoding="utf-8").count("## STYLE GUIDE") == 1


# ------------------------------------------------------------------------------------------ CLI


def test_cli_voice_fake_writes_profile_and_meta(tmp_path, capsys):
    target = tmp_path / "p" / "voice.md"
    assert main(["voice", "--source", str(SOURCE), "--voice-profile", str(target), "--fake"]) == 0
    text = target.read_text(encoding="utf-8")
    assert V.parse_profile(text).render() == text and len(text.split()) <= V.WORD_CAP
    meta = json.loads((tmp_path / "p" / "voice.meta.json").read_text(encoding="utf-8"))
    assert meta["source_sha256"] and meta["words"] == len(text.split()) and meta["profile_sha256"] == V.sha256_text(text)
    assert "voice profile:" in capsys.readouterr().out
    # a second run keeps the first profile as .bak
    assert main(["voice", "--source", str(SOURCE), "--voice-profile", str(target), "--fake"]) == 0
    assert (tmp_path / "p" / "voice.md.bak").read_text(encoding="utf-8") == text


def test_cli_voice_needs_source_or_apply(capsys):
    with pytest.raises(SystemExit):
        main(["voice"])
    assert main(["voice", "--source", "/nonexistent/file.md", "--fake"]) == 1
    assert "source not found" in capsys.readouterr().err


def test_cli_apply_rewrites_the_voice_section_and_keeps_the_old_pack(tmp_path, voice_file, capsys):
    session = _build(tmp_path, "s")
    pack_path = session / "pack.md"
    original = pack_path.read_text(encoding="utf-8")
    pack_path.write_text(original + "\n## USER'S VOICE (hand written)\n- old style\n", encoding="utf-8")
    hand = pack_path.read_text(encoding="utf-8")
    assert main(["voice", "--apply", str(session), "--voice-profile", str(voice_file)]) == 0
    assert pack_path.read_text(encoding="utf-8") == V.with_voice(original, PROFILE)
    assert (session / "pack.md.bak-before-voice-v1").read_text(encoding="utf-8") == hand
    out = capsys.readouterr().out
    assert "voice section written" in out
    # applying again changes nothing and creates no second backup
    assert main(["voice", "--apply", str(session), "--voice-profile", str(voice_file)]) == 0
    assert "already up to date" in capsys.readouterr().out
    assert not (session / "pack.md.bak-before-voice-v1-2").exists()


def test_cli_apply_handles_a_sim_session_and_errors(tmp_path, voice_file, capsys):
    s = build_with(tmp_path, FakeSimModel())
    assert main(["voice", "--apply", str(s), "--voice-profile", str(voice_file)]) == 0
    assert (s / "sim_pack.md").read_text(encoding="utf-8").endswith(PROFILE)
    assert (s / "sim_pack.md.bak-before-voice-v1").exists() and not (s / "pack.md").exists()
    assert main(["voice", "--apply", str(tmp_path), "--voice-profile", str(voice_file)]) == 1
    assert "no pack.md or sim_pack.md" in capsys.readouterr().err
    assert main(["voice", "--apply", str(s), "--voice-profile", str(tmp_path / "none.md")]) == 1
    assert "no voice profile" in capsys.readouterr().err


def test_cli_prep_flags_voice_profile_and_no_voice(tmp_path, voice_file, capsys):
    from verse_brain.prep.__main__ import _resolve_voice, _main  # noqa: F401
    import argparse
    ns = argparse.Namespace(no_voice=False, voice_profile=voice_file)
    assert _resolve_voice(ns) == voice_file
    assert _resolve_voice(argparse.Namespace(no_voice=True, voice_profile=voice_file)) is None
    with pytest.raises(PrepError, match="not found"):
        _resolve_voice(argparse.Namespace(no_voice=False, voice_profile=tmp_path / "typo.md"))
