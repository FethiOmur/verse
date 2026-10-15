"""Voice profile: how the user really talks, distilled once from a source document and carried by every pack.

`voice.md` lives outside the repo (default ~/Library/Application Support/Verse/profile/voice.md): it is personal data.
The distillation step reads a source document (an engineering profile, a CV, a few emails; the user's own words) and
asks the prep model (Sonnet) for a compact block of at most `WORD_CAP` words, so it fits the cache prefix:

  ### Tone
  ### Sentence length and level
  ### Openers and phrasings
  ### Words to avoid
  ### How projects and numbers are framed
  ### Sample answers          (3 to 5 short answers, style only)

The pipeline (`pack.py`, `sim_pack.py`) appends the block as the last section of the frozen pack when a profile is
given. Rules about facts stay in the runtime prompts; the voice block carries only the personal style. Same profile
text gives a byte-identical section: nothing per-run (path, time, hash) is ever rendered into it.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path

from .model import MAX_OUTPUT_TOKENS, PRICES, PrepError, PrepModel, Usage, spend_usd

DEFAULT_VOICE_PATH = Path("~/Library/Application Support/Verse/profile/voice.md")
WORD_CAP = 600
MAX_SOURCE_CHARS = 120_000
MIN_SAMPLES, MAX_SAMPLES = 3, 5

SECTIONS = (
    "Tone",
    "Sentence length and level",
    "Openers and phrasings",
    "Words to avoid",
    "How projects and numbers are framed",
    "Sample answers",
)
SAMPLES = SECTIONS[-1]

# Headings the pipeline writes into packs. The runtime looks for VOICE_HEADING to know a pack carries a voice.
VOICE_HEADING = "## VOICE"
MEETING_HEADER = (
    f"{VOICE_HEADING} (how the user talks. Wording only: every SAY line and point is phrased like this. It is not a "
    "source: never cite it, never take facts, numbers or names from it, and it never changes the line format or the "
    "length limits; sample answers show style only)")
SIM_HEADER = (
    f"{VOICE_HEADING} (how the candidate talks. Only the COACH task uses it, to phrase the \"better sentence\"; the "
    "interviewer never imitates it. It is not a source: never cite it and never take facts, numbers or names from it, "
    "only the evidence above counts; sample answers show style only)")

SYSTEM = """You are the voice-profile stage of Verse, a live meeting and interview assistant. Verse writes short lines \
that the user then says out loud. Those lines must sound like the user, not like an AI and not like a report. From a \
source document written by or about the user you distil a compact speaking-style profile.

The source may be a written profile (for example a guide for coding agents) rather than a transcript of speech. Read \
it for how the person phrases things, what they believe, what they dislike, how they describe projects and numbers, \
and the communication style they ask for. Infer the spoken style from that. Where the source says nothing about a \
point, use plain spoken English at B1-B2 level, never fancier. Do not invent biography, employers, numbers or \
quotes: every claim in the sample answers must come from the source.

Reply with markdown only, exactly these six sections in this order, each starting with its "### " heading, and \
nothing before the first heading or after the last item:

### Tone
2 to 4 bullets: register (formal or relaxed), warmth, directness, humour, how the person handles disagreement or \
uncertainty.

### Sentence length and level
2 to 3 bullets: typical spoken sentence length in words, CEFR level (state it: B1-B2 English), how many ideas per \
sentence, contractions, whether to use fillers.

### Openers and phrasings
4 to 8 bullets: short phrases the person would really say to open an answer, to change direction, to admit a gap, to \
close. Quote each in "double quotes".

### Words to avoid
1 to 3 bullets: words, phrases and habits the person dislikes or that would sound fake in their mouth (corporate \
phrases, hype, praising the question, claims like "100% reliable", em dashes, and so on). Use only what the source \
supports or what follows from the stated tone.

### How projects and numbers are framed
2 to 4 bullets: how the person talks about a project (outcome first? problem, then choice, then result?), how they \
state numbers (exact, with what was measured, with what is uncertain), how they credit tools and teammates.

### Sample answers
3 to 5 bullets. Each is a complete spoken answer of 25 to 45 words to a different typical interview or meeting \
question, in the person's style, first person, built only from facts in the source. Start each with the question in \
square brackets, for example "- [Tell me about a project you are proud of] I built ...". No invented numbers.

Hard limits: at most 600 words in total (headings included), spoken English at B1-B2, no emojis, no markdown other \
than the headings and "- " bullets."""

FAKE_PROFILE = """### Tone
- Relaxed, direct and friendly. Says what he thinks, kindly.
- Admits gaps plainly instead of bluffing.

### Sentence length and level
- Short spoken sentences, 8 to 14 words. B1-B2 English, easy words, contractions.
- One idea per sentence.

### Openers and phrasings
- "Sure, the clearest example is ..."
- "Honestly, I haven't done that exact thing, but here's how I'd do it."
- "What I like is ..."
- "In short: ..."

### Words to avoid
- "Great question", "leverage", "synergy", hype words, and claims like "100% reliable".

### How projects and numbers are framed
- Outcome first, then what he chose and why, then the number and how it was measured.
- Says what is still uncertain.

### Sample answers
- [Tell me about a project you are proud of] I built a small weather app for my family. It was simple, and it worked on day one. People used it every morning, and that made me happy.
- [How do you work with a team?] I keep things short and clear. I say what I plan to do, then I do it, then I tell people how it went.
- [What is your biggest weakness?] I sometimes rebuild things that already work. I'm getting better at asking first: does the user really feel the problem?
"""


# ---------------------------------------------------------------- parsing
_HEADING = re.compile(r"^###\s+(.+?)\s*$")


@dataclass
class VoiceProfile:
    sections: dict[str, list[str]]  # heading -> bullet texts (one line each)

    def render(self, samples: int | None = None) -> str:
        out: list[str] = []
        for name in SECTIONS:
            items = self.sections[name]
            if name == SAMPLES and samples is not None:
                items = items[:samples]
            out.append(f"### {name}")
            out += [f"- {b}" for b in items]
            out.append("")
        return "\n".join(out).rstrip("\n") + "\n"

    def words(self, samples: int | None = None) -> int:
        return len(self.render(samples).split())


def _clean(s: str) -> str:
    return " ".join(s.split())


def parse_profile(raw: str) -> VoiceProfile:
    """Parse the model's markdown. Tolerates a code fence and text before the first heading; rejects a missing
    section, a section without bullets, and a sample count outside 3 to 5."""
    text = raw.strip()
    text = re.sub(r"^```[a-zA-Z]*\s*\n", "", text)
    text = re.sub(r"\n```\s*$", "", text)
    sections: dict[str, list[str]] = {}
    cur: str | None = None
    for ln in text.splitlines():
        m = _HEADING.match(ln.strip())
        if m:
            name = next((s for s in SECTIONS if s.casefold() == m.group(1).strip().casefold()), None)
            if name is None:
                raise PrepError(f"voice profile: unknown section {m.group(1)!r}")
            if name in sections:
                raise PrepError(f"voice profile: section {name!r} appears twice")
            sections[name] = []
            cur = name
            continue
        s = ln.strip()
        if cur is None or not s:
            continue
        if s.startswith(("- ", "* ")):
            sections[cur].append(_clean(s[2:]))
        elif sections[cur]:
            sections[cur][-1] = _clean(sections[cur][-1] + " " + s)  # a wrapped bullet
        # prose without a bullet before the first bullet is dropped
    missing = [s for s in SECTIONS if s not in sections]
    if missing:
        raise PrepError(f"voice profile: missing section(s): {', '.join(missing)}")
    empty = [s for s in SECTIONS if not sections[s]]
    if empty:
        raise PrepError(f"voice profile: empty section(s): {', '.join(empty)}")
    n = len(sections[SAMPLES])
    if n < MIN_SAMPLES:
        raise PrepError(f"voice profile: {n} sample answer(s); at least {MIN_SAMPLES} are required")
    return VoiceProfile(sections)


def fit_profile(p: VoiceProfile, cap: int = WORD_CAP) -> tuple[str, int]:
    """Render at most `cap` words: drop sample answers from the tail down to MIN_SAMPLES (and to MAX_SAMPLES first).
    Returns (text, samples_kept). Raises PrepError when even the minimum does not fit: a trimmed middle section would
    cut a rule in half, so the caller asks the model again instead."""
    n = min(len(p.sections[SAMPLES]), MAX_SAMPLES)
    while n >= MIN_SAMPLES:
        if p.words(n) <= cap:
            return p.render(n), n
        n -= 1
    raise PrepError(f"voice profile is {p.words(MIN_SAMPLES)} words with the minimum {MIN_SAMPLES} samples; the cap is {cap}")


# ---------------------------------------------------------------- files and sections
def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def load_voice(path: Path | str | None) -> str | None:
    """The profile text, normalised (stripped, one trailing newline), or None when `path` is None, missing or empty.
    A path that exists but cannot be read is an error, not a silent skip: a pack must not quietly lose its voice."""
    if path is None:
        return None
    p = Path(path).expanduser()
    if not p.is_file():
        return None
    try:
        raw = p.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        raise PrepError(f"cannot read the voice profile {p}: {e}") from e
    text = raw.strip()
    return text + "\n" if text else None


def render_voice_section(voice: str, kind: str = "meeting") -> str:
    """The pack section: header line + profile body. Pure function of (voice, kind)."""
    header = {"meeting": MEETING_HEADER, "sim": SIM_HEADER}[kind]
    return header + "\n" + voice.strip() + "\n"


def with_voice(pack: str, voice: str | None, kind: str = "meeting") -> str:
    """Append the voice section to a rendered pack; `voice=None` returns the pack unchanged (byte for byte)."""
    if voice is None:
        return pack
    return pack.rstrip("\n") + "\n\n" + render_voice_section(voice, kind)


_SECTION_START = re.compile(r"^## ", re.M)


def strip_voice(pack: str) -> str:
    """Remove a trailing voice section from a rendered pack: this module's `## VOICE` one and the hand-appended
    `## THE OWNER'S VOICE` one of the first Mara session. Only a section that runs to the end of the pack is removed."""
    for marker in (f"\n{VOICE_HEADING}", "\n## THE OWNER'S VOICE"):
        i = pack.find(marker)
        if i == -1:
            continue
        tail = pack[i + 1:]
        if not _SECTION_START.search(tail, 3):  # no later "## " section: it runs to the end
            return pack[:i].rstrip("\n") + "\n"
    return pack


# ---------------------------------------------------------------- distillation
def render_user(source: str) -> str:
    return f"<source>\n{source.strip()}\n</source>\n\nWrite the voice profile now."


async def distill_async(source: str, model: PrepModel, *, budget_usd: float = 1.0, attempts: int = 2) -> tuple[str, Usage, int]:
    """Source text -> (profile text within WORD_CAP, summed usage, samples kept). Asks again once when the answer
    does not parse or does not fit the cap, quoting the problem."""
    if not source.strip():
        raise PrepError("the voice source is empty")
    if len(source) > MAX_SOURCE_CHARS:
        raise PrepError(f"the voice source is {len(source)} chars; the limit is {MAX_SOURCE_CHARS}")
    user = render_user(source)
    in_tokens = await model.count_request_tokens(SYSTEM, user)
    pin, pout = PRICES[model.model]
    max_tokens = min(MAX_OUTPUT_TOKENS, int((budget_usd - in_tokens * pin / 1e6) / (pout / 1e6)))
    if max_tokens < 4000:
        raise PrepError(f"budget ${budget_usd:.2f} leaves only {max_tokens} output tokens; raise it or shrink the source")
    total = Usage()
    problem = ""
    for _ in range(attempts):
        res = await model.generate(SYSTEM, user + (f"\n\nYour previous answer was rejected: {problem}" if problem else ""), max_tokens)
        total = Usage(total.input + res.usage.input, total.output + res.usage.output,
                      total.cache_read + res.usage.cache_read, total.cache_write + res.usage.cache_write)
        try:
            text, kept = fit_profile(parse_profile(res.text))
            return text, total, kept
        except PrepError as e:
            problem = f"{e}. Keep to the six sections and {WORD_CAP} words."
    raise PrepError(f"voice distillation failed after {attempts} attempts: {problem}")


class FakeVoiceModel:
    """Offline stand-in for `--fake`: returns a fixed fictional profile. No network, no key."""

    model = "claude-sonnet-5-5"

    async def generate(self, system: str, user: str, max_tokens: int):
        from .model import ModelOutput
        return ModelOutput(FAKE_PROFILE, Usage(input=10, output=10), "end_turn")

    async def count_tokens(self, text: str) -> int:
        return len(text) // 4

    async def count_request_tokens(self, system: str, user: str) -> int:
        return (len(system) + len(user)) // 4


def write_profile(path: Path | str, text: str, *, source: Path | None, usage: Usage, model: str, samples: int) -> Path:
    """Write `voice.md` (profile text only) and a `voice.meta.json` next to it (source path and hash, usage, spend).
    The profile file is replaced atomically; an existing one moves to `voice.md.bak` (`.bak2`, ... when taken) first,
    never deleted."""
    p = Path(path).expanduser()
    p.parent.mkdir(parents=True, exist_ok=True)
    if p.exists():
        k, bak = 1, p.with_name(p.name + ".bak")
        while bak.exists():
            k += 1
            bak = p.with_name(f"{p.name}.bak{k}")
        p.rename(bak)
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(p)
    meta = {
        "source": str(source) if source else None, "source_sha256": sha256_text(source.read_text(encoding="utf-8")) if source else None,
        "profile_sha256": sha256_text(text), "words": len(text.split()), "samples": samples, "model": model,
        "usage": usage.as_dict(), "spend_usd": round(spend_usd(model, usage), 6) if model in PRICES else None,
    }
    p.with_name("voice.meta.json").write_text(json.dumps(meta, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return p
