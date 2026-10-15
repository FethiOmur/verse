"""Teleprompter scripts (T3): Verse writes a script from a topic, a target length and a use, in the user's voice.

  python -m verse_brain.prep script --topic "why I built Verse" --seconds 60 --use recording [--json] [--fake]

It is a prep-stage command, not a runtime one: a script is written once, on demand, outside any meeting session, so it
runs as a one-shot process on the prep model (Sonnet, the same `AnthropicPrepModel` transport `voice` uses) and not
inside the long-lived meeting brain. The style comes from the voice profile (`profile/voice.md`, V1), appended to the
system prompt as a STYLE GUIDE section exactly like a pack carries it.

Output is the text the teleprompter reads (`PromptScript` in the app):
  - spoken text only, no title, headings, bullets or markdown;
  - pages separated by a blank line, a line holding only `---`, and a blank line;
  - optional `[cues]`: bracketed notes that are shown but not spoken and not counted.
"""

from __future__ import annotations

import asyncio
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

from .model import PRICES, PrepError, Usage, spend_usd
from .voice import DEFAULT_VOICE_PATH, VOICE_HEADING, load_voice

USES = ("recording", "talk")
# Spoken words per minute used to turn the target length into a word count. A talk has pauses and slide changes.
WORDS_PER_MINUTE = {"recording": 150, "talk": 130}
MIN_SECONDS, MAX_SECONDS = 15, 1800
MAX_TOPIC_CHARS = 8000
MAX_OUTPUT = 16_000          # tokens, thinking included; about $0.16 of output at most
SOFT_TOLERANCE = (0.80, 1.20)  # outside this the model is asked again once
HARD_TOLERANCE = (0.60, 1.45)  # outside this after the last attempt is an error; between the two it is a warning

SCRIPT_HEADER = (
    f"{VOICE_HEADING} (how the speaker talks; not evidence, never cite. Wording only: every sentence of the script is "
    "phrased like this. Take no facts, numbers or names from it. \"Positions he holds\" are his own views: voice one "
    "only when the topic calls for it, in his words. The openers are options: at most one in the whole script, often "
    "none. The examples show style only)")

SYSTEM = """You write scripts that one person reads aloud from a teleprompter, to a camera or to a room. The script must \
sound like the speaker talking, not like an AI and not like an essay. The speaker's STYLE GUIDE is at the end of this \
message when there is one; follow it for wording, rhythm and level.

Output format, exactly:
- Spoken text only. No title, no headings, no bullets, no numbering, no markdown, no bold, no emoji, no quotation \
marks around the whole thing, and nothing before or after the script ("Here is your script" is wrong).
- Pages: split the script into pages the way the speaker would breathe. Put a blank line, then a line that holds only \
three dashes (---), then a blank line between two pages. No page break at the start or at the end.
- Cues: a few short notes in [square brackets] on their own, for example [pause], [look at the camera], [next slide]. \
They are shown on the prompter but not spoken. Use as few as help: none is fine. Never put spoken words in brackets.
- Never start a sentence or a page with a label and a colon (no "Short version:", "Hook:", "Bottom line:").
- Write for the ear: short sentences, one idea each, contractions where the speaker uses them. Write every number and \
symbol the way it is said: "forty percent" or "40 percent", never "40%"; "and", never "&".
- Use only the facts the topic gives you. When a concrete number, name or date is needed and you do not have it, leave a \
cue such as [add the figure] instead of inventing one. No invented biography, employers, clients or quotes.
- Length: the number of spoken words (cues are not counted) is the target given in the request, within 10 percent. \
Count before you answer.
"""

USE_RULES = {
    "recording": """Use: a short video recorded to camera (Shorts, YouTube, a pitch clip).
- The first sentence is the hook: the point or the problem, said straight away. No greeting, no "welcome back", no \
"in this video".
- Three to five pages of 30 to 60 spoken words, one beat each (the hook, the middle, the close).
- End on one clear closing line the speaker can say and stop. No "thanks for watching" unless the topic asks for it.""",
    "talk": """Use: a talk or a presentation given to people in a room or a call.
- One page per section, 80 to 140 spoken words each. The first page opens the talk and says what it will cover in one \
sentence; the last page closes it.
- Join the pages with one spoken sentence each, so the speaker never says "next slide" out loud. Where the speaker \
changes slide, add [next slide] on its own line at the end of the page.""",
}

_FENCE = re.compile(r"^```[a-zA-Z]*\s*\n|\n```\s*$")
_CUE = re.compile(r"\[[^\]]*\]")
_PAGE_SPLIT = re.compile(r"\n[ \t]*\n[ \t]*---[ \t]*\n[ \t]*\n")
# a label opener ("Short version:", "Hook:") is one or two words and a colon at the start of a paragraph
_LABEL = re.compile(r"^[\"'“]?[A-Za-z][A-Za-z']*( [A-Za-z][A-Za-z']*)?:(\s|$)")
_PREAMBLE = re.compile(r"^(here('s| is| are)|sure|certainly|of course|okay)\b[^\n]*:\s*$", re.I)
_MARKDOWN = re.compile(r"^(#{1,6}\s|[-*+]\s|\d+[.)]\s|>\s)|\*\*|__|`")


def target_words(seconds: int, use: str) -> int:
    return max(20, round(seconds * WORDS_PER_MINUTE[use] / 60 / 5) * 5)


def spoken_words(text: str) -> int:
    """Words the speaker says: everything except the page breaks and the [cues]."""
    body = _CUE.sub(" ", text)
    return len([w for w in body.split() if w != "---" and any(c.isalnum() for c in w)])


def split_pages(text: str) -> list[str]:
    return [p.strip() for p in _PAGE_SPLIT.split(text.strip()) if p.strip()]


def clean_output(raw: str) -> str:
    """Strip a code fence, normalise line endings and the page-break lines; no wording is changed."""
    text = raw.replace("\r\n", "\n").replace("\r", "\n").strip()
    text = _FENCE.sub("", text).strip()
    lines = [ln.rstrip() for ln in text.split("\n")]
    out: list[str] = []
    for ln in lines:
        if ln.strip() == "---":
            while out and out[-1] == "":
                out.pop()
            if out:                       # no break at the very start
                out += ["", "---", ""]
            continue
        out.append(ln)
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip()
    while text.endswith("---"):           # no break at the very end
        text = text[:-3].rstrip()
    return text + "\n"


def problems(text: str, target: int) -> tuple[list[str], list[str]]:
    """(structural problems, length problems) of a cleaned script."""
    structural: list[str] = []
    length: list[str] = []
    if not text.strip():
        return ["the script is empty"], []
    if _PREAMBLE.match(text.lstrip().split("\n")[0].strip()):
        structural.append("it starts with an introduction line; the answer is the script and nothing else")
    for ln in text.split("\n"):
        if ln.strip() != "---" and _MARKDOWN.search(ln.strip()):
            structural.append("it contains markdown (headings, bullets, bold or code); write plain spoken text")
            break
    for para in re.split(r"\n\s*\n", text):
        first = para.strip().split("\n")[0].strip()
        if first != "---" and _LABEL.match(first):
            structural.append(f"a paragraph starts with a label and a colon ({first[:30]!r}); say the sentence itself")
            break
    n = spoken_words(text)
    lo, hi = SOFT_TOLERANCE
    if n < lo * target:
        length.append(f"it has {n} spoken words; the target is {target} (within 10 percent): add spoken content")
    elif n > hi * target:
        length.append(f"it has {n} spoken words; the target is {target} (within 10 percent): cut")
    return structural, length


def build_system(use: str, voice: str | None) -> str:
    system = SYSTEM + "\n" + USE_RULES[use]
    if voice is not None:
        system += "\n\n" + SCRIPT_HEADER + "\n" + voice.strip() + "\n"
    return system


def build_user(topic: str, seconds: int, use: str, target: int) -> str:
    return (f"<topic>\n{topic.strip()}\n</topic>\n\n"
            f"Use: {use}. Length: {seconds} seconds at the speaker's pace, which is {target} spoken words "
            f"(cues and page breaks not counted). Write the script now.")


@dataclass
class ScriptResult:
    text: str
    words: int
    pages: int
    target_words: int
    usage: Usage
    model: str
    voice: bool
    attempts: int = 1
    warnings: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        spend = spend_usd(self.model, self.usage) if self.model in PRICES else None
        return {"text": self.text, "words": self.words, "pages": self.pages, "target_words": self.target_words,
                "voice": self.voice, "attempts": self.attempts, "warnings": self.warnings, "model": self.model,
                "usage": self.usage.as_dict(), "spend_usd": spend}


async def write_script_async(topic: str, seconds: int, use: str, model, *, voice: str | None = None,
                             attempts: int = 2) -> ScriptResult:
    """Topic -> script. Asks again once when the answer breaks the format or the length, quoting what was wrong."""
    if use not in USES:
        raise PrepError(f"use must be one of {', '.join(USES)}, not {use!r}")
    if not topic.strip():
        raise PrepError("the topic is empty")
    if len(topic) > MAX_TOPIC_CHARS:
        raise PrepError(f"the topic is {len(topic)} chars; the limit is {MAX_TOPIC_CHARS}")
    if not MIN_SECONDS <= seconds <= MAX_SECONDS:
        raise PrepError(f"the length must be {MIN_SECONDS} to {MAX_SECONDS} seconds, not {seconds}")
    target = target_words(seconds, use)
    system = build_system(use, voice)
    user = build_user(topic, seconds, use, target)
    total = Usage()
    text, structural, length = "", ["no answer"], []
    for attempt in range(1, attempts + 1):
        feedback = "; ".join(structural + length)
        prompt = user + (f"\n\nYour previous answer was rejected: {feedback}. Fix exactly that and answer again with the "
                         "whole script." if attempt > 1 else "")
        res = await model.generate(system, prompt, MAX_OUTPUT)
        total = Usage(total.input + res.usage.input, total.output + res.usage.output,
                      total.cache_read + res.usage.cache_read, total.cache_write + res.usage.cache_write)
        text = clean_output(res.text)
        structural, length = problems(text, target)
        if not structural and not length:
            break
    n = spoken_words(text)
    if structural:
        raise PrepError(f"script failed after {attempts} attempts: {'; '.join(structural)}")
    warnings: list[str] = []
    if length:
        lo, hi = HARD_TOLERANCE
        if not lo * target <= n <= hi * target:
            raise PrepError(f"script failed after {attempts} attempts: {length[0]}")
        warnings.append(length[0])
    if voice is None:
        warnings.append("no voice profile found: the script is in plain spoken English, not in your voice")
    return ScriptResult(text=text, words=n, pages=len(split_pages(text)), target_words=target, usage=total,
                        model=getattr(model, "model", ""), voice=voice is not None, attempts=attempt, warnings=warnings)


class FakeScriptModel:
    """Offline stand-in for `--fake`: a fictional script of about the requested length. No network, no key."""

    model = "claude-sonnet-5-5"
    SENTENCES = (
        "I build small tools that do one thing well.",
        "Last month I fixed a problem my family had every morning.",
        "It took one evening, and it worked on day one.",
        "I tell people what I tested and what I did not.",
        "That keeps the work honest and the answers short.",
        "If a list and a button solve it, I stop there.",
    )

    async def generate(self, system: str, user: str, max_tokens: int):
        from .model import ModelOutput
        m = re.search(r"which is (\d+) spoken words", user)
        want = int(m.group(1)) if m else 100
        words: list[str] = []
        pages: list[list[str]] = [[]]
        i = 0
        while len(words) < want:
            s = self.SENTENCES[i % len(self.SENTENCES)]
            i += 1
            pages[-1].append(s)
            words += s.split()
            if sum(len(x.split()) for x in pages[-1]) >= 45 and len(words) < want - 10:
                pages.append([])
        text = "\n\n---\n\n".join(" ".join(p) for p in pages if p)
        return ModelOutput(text + "\n", Usage(input=10, output=10), "end_turn")

    async def count_tokens(self, text: str) -> int:
        return len(text) // 4

    async def count_request_tokens(self, system: str, user: str) -> int:
        return (len(system) + len(user)) // 4


def script_main(argv: list[str]) -> int:
    import argparse

    from .keychain import KeychainError, read_api_key, redact

    ap = argparse.ArgumentParser(prog="python -m verse_brain.prep script", description=(
        "Write a teleprompter script from a topic, in the voice of the profile (one Sonnet call, about 2 cents)."))
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--topic", help="what the script is about (the speaker's own words work best)")
    src.add_argument("--topic-file", type=Path, help="read the topic from this file")
    ap.add_argument("--seconds", type=int, default=60, help=f"target length, {MIN_SECONDS} to {MAX_SECONDS} (default 60)")
    ap.add_argument("--use", choices=USES, default="recording")
    ap.add_argument("--voice-profile", type=Path, default=DEFAULT_VOICE_PATH, help=f"default {DEFAULT_VOICE_PATH}")
    ap.add_argument("--no-voice", action="store_true", help="write without the voice profile")
    ap.add_argument("--json", action="store_true", help="print one JSON line {text, words, pages, ...} instead of the text")
    ap.add_argument("--fake", action="store_true", help="offline: a fixed fictional script, no network, no key, no spend")
    a = ap.parse_args(argv)
    key = None
    try:
        topic = a.topic if a.topic is not None else a.topic_file.expanduser().read_text(encoding="utf-8")
        voice = None
        if not a.no_voice:
            path = a.voice_profile.expanduser()
            if not path.is_file() and path != DEFAULT_VOICE_PATH.expanduser():
                raise PrepError(f"voice profile not found: {path}")
            voice = load_voice(path)
        if a.fake:
            model = FakeScriptModel()
        else:
            from .model import PREP_MODEL, AnthropicPrepModel
            key = read_api_key()  # only to scrub error text; the model client reads its own copy
            model = AnthropicPrepModel(key, PREP_MODEL)

        async def run():
            try:
                return await write_script_async(topic, a.seconds, a.use, model, voice=voice)
            finally:
                close = getattr(model, "aclose", None)
                if close is not None:
                    await close()

        result = asyncio.run(run())
    except (KeychainError, PrepError, OSError) as e:
        print(f"error: {redact(str(e), key)}", file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001
        print(f"error: {type(e).__name__}: {redact(str(e), key)[:300]}", file=sys.stderr)
        return 1
    if a.json:
        print(json.dumps(result.as_dict(), ensure_ascii=False))
    else:
        print(result.text, end="")
    spend = result.as_dict()["spend_usd"]
    print(f"script: {result.words} words (target {result.target_words}), {result.pages} page(s), "
          f"voice {'yes' if result.voice else 'no'}" + (f", spend ${spend:.4f}" if spend is not None else ""), file=sys.stderr)
    for w in result.warnings:
        print(f"warning: {w}", file=sys.stderr)
    return 0
