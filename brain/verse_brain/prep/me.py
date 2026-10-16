"""The me layer: the owner's permanent profile (docs/specs/2026-10-16-verse-anytime-calls-design.md 2.2, 3).

`python -m verse_brain.prep me build|refresh|show` distils his sources into files outside the repo, in
`~/Library/Application Support/Verse/profile/`:

  me.md            the core, human-readable and editable: ## WHO I AM, EXPERIENCE, PROJECTS, SKILLS, NUMBERS, STORIES,
                   LOOKING FOR, MY NOTES; one line per item with an id like [m412]
  me.meta.json     model, spend, built_at, token count, per-source sha256, the hash of every generated line, deleted ids
  me.sources.json  the source list (he adds and removes sources)
  me.notes.md      free notes he types
  me.facts.jsonl   the NUMBERS lines in the facts.jsonl schema (Swift's fact chips and the grounding check)
  me.library.jsonl, me.library.emb   retrieval chunks of the sources and their EmbeddingGemma vectors (float16)

Build: one Sonnet call (the prep tuple) over the core sources. Every line carries a quote of its source that
`sources.py` finds in the source text; a line that fails is dropped (his own notes are exempt). The same applies to a
number in a line: it has to be in the quote. Refresh: rebuilds only when a source changed, keeps every line he edited
(its hash differs from the generated one) or added, and never brings back a line he deleted.

The vault is read with plain file reads, never through `beyin.py`, and only the folders this module names. Keys come from
the Keychain as everywhere in prep; nothing here prints or logs them.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import math
import re
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from ..runtime.me import write_emb
from .ground import _value_supported
from .keychain import KeychainError, read_api_key, redact
from .model import MAX_OUTPUT_TOKENS, PRICES, PrepError, PrepModel, Usage, spend_usd
from .sources import MAX_QUOTE_CHARS, MIN_QUOTE_CHARS, SourceBook, norm, numbers_supported
from .vault import DEFAULT_VAULT

PROFILE_DIR = Path("~/Library/Application Support/Verse/profile")
SESSIONS_DIR = Path("~/Library/Application Support/Verse/sessions")
DOWNLOADS_PROFILE = Path("~/Downloads/ENGINEERING_PROFILE.md")
PROJECTS_FOLDER = "🏰 300-Projects"
PROJECTS_INDEX = "Projects.md"
SKIP_PROJECT_FOLDERS = ("AgentLogs", "Archive-Private")      # 1.35 MB of agent output; ArchiveApp never leaves the machine
FORBIDDEN_VAULT_FOLDERS = ("400-Private", "700-Health", "800-Journal", "850-Notes", "daily", "receipts", "Inbox")

CAP_TOKENS = 3500
MAX_CORE_CHARS = 80_000          # about 20k tokens of core sources; later sources become library-only
CHUNK_CHARS = 1500
MAX_CHUNKS = 400
MIN_CHUNK_CHARS = 30
MAX_PER_SECTION = {"WHO I AM": 5, "EXPERIENCE": 8, "PROJECTS": 10, "SKILLS": 20, "NUMBERS": 40, "STORIES": 8, "LOOKING FOR": 5}

WHO, EXPERIENCE, PROJECTS, SKILLS, NUMBERS, STORIES, LOOKING, NOTES = (
    "WHO I AM", "EXPERIENCE", "PROJECTS", "SKILLS", "NUMBERS", "STORIES", "LOOKING FOR", "MY NOTES")
SECTIONS = (WHO, EXPERIENCE, PROJECTS, SKILLS, NUMBERS, STORIES, LOOKING, NOTES)
N_FIELDS = {WHO: 1, EXPERIENCE: 4, PROJECTS: 5, SKILLS: 2, NUMBERS: 3, STORIES: 2, LOOKING: 1, NOTES: 1}
KEY_FIELDS = {WHO: (0,), EXPERIENCE: (1, 2), PROJECTS: (0,), SKILLS: (0,), NUMBERS: (1,), STORIES: (0,), LOOKING: (0,), NOTES: (0,)}
TRIM_ORDER = (STORIES, SKILLS, PROJECTS, EXPERIENCE)     # tail first; NUMBERS, WHO I AM and the notes are never trimmed
FACT_KINDS = ("number", "date", "name")

_ID = re.compile(r"^\[(m\d{3})\]\s*(.*)$")
_SRC = re.compile(r"\|\s*SRC:\s*(S\d+)\s*[\"“](.*?)[\"”]\s*$", re.S)


class MeError(PrepError):
    pass


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def one_line(s: str) -> str:
    return " ".join(s.split())


# ---------------------------------------------------------------- paths
@dataclass(frozen=True)
class Paths:
    dir: Path

    @property
    def md(self) -> Path: return self.dir / "me.md"
    @property
    def meta(self) -> Path: return self.dir / "me.meta.json"
    @property
    def sources(self) -> Path: return self.dir / "me.sources.json"
    @property
    def notes(self) -> Path: return self.dir / "me.notes.md"
    @property
    def facts(self) -> Path: return self.dir / "me.facts.jsonl"
    @property
    def library(self) -> Path: return self.dir / "me.library.jsonl"
    @property
    def emb(self) -> Path: return self.dir / "me.library.emb"


# ---------------------------------------------------------------- sources
def forbidden_vault_path(path: Path, vault: Path = DEFAULT_VAULT) -> bool:
    """True for a path inside the vault's private folders. Read nothing from such a path, whoever asks."""
    try:
        rel = path.expanduser().resolve().relative_to(vault.expanduser().resolve())
    except ValueError:
        return False
    parts = {p.casefold() for p in rel.parts}
    return any(f.casefold() in parts for f in FORBIDDEN_VAULT_FOLDERS)


def default_sources(vault: Path = DEFAULT_VAULT, downloads_profile: Path = DOWNLOADS_PROFILE,
                    sessions: Path = SESSIONS_DIR) -> list[dict]:
    """The sources of a first build (spec 2.2). Only paths that exist are listed."""
    out: list[dict] = []

    def add(kind: str, path: Path, label: str) -> None:
        out.append({"id": f"s{len(out) + 1}", "kind": kind, "path": str(path), "label": label, "enabled": True})

    prof = downloads_profile.expanduser()
    if prof.is_file():
        add("file", prof, prof.name)
    proj = vault.expanduser() / PROJECTS_FOLDER
    if proj.is_dir():
        idx = proj / PROJECTS_INDEX
        if idx.is_file():
            add("vault", idx, f"{PROJECTS_FOLDER}/{PROJECTS_INDEX}")
        for d in sorted(p for p in proj.iterdir() if p.is_dir() and p.name not in SKIP_PROJECT_FOLDERS):
            for note in sorted(d.glob("*.md")):
                if note.is_file() and not forbidden_vault_path(note, vault):
                    add("vault", note, f"{PROJECTS_FOLDER}/{d.name}/{note.name}")
    add("sessions", sessions.expanduser(), "facts of earlier meeting preps")
    return out


def load_sources(paths: Paths) -> list[dict]:
    if paths.sources.is_file():
        try:
            data = json.loads(paths.sources.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as e:
            raise MeError(f"cannot read {paths.sources}: {type(e).__name__}") from None
        if isinstance(data, list):
            return [s for s in data if isinstance(s, dict) and s.get("path")]
    return default_sources()


def save_sources(paths: Paths, sources: list[dict]) -> None:
    paths.dir.mkdir(parents=True, exist_ok=True)
    paths.sources.write_text(json.dumps(sources, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


@dataclass
class Doc:
    handle: str          # S1, S2, ... in the model's prompt
    id: str              # the source's id in me.sources.json
    kind: str            # file | vault | sessions | notes
    ref: str             # what a line's src says: vault:300-Projects/X.md | file:NAME.md | session:NAME
    label: str
    text: str
    core: bool = True    # False: library only (too big for the distillation call)


def _read_text(p: Path) -> str:
    if p.suffix.lower() == ".pdf":
        from .sim import read_cv      # the existing pypdf reader
        return read_cv(p)
    try:
        return p.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        raise MeError(f"cannot read the source {p}: {type(e).__name__}") from None


def session_facts_text(sessions: Path) -> str:
    """Facts of every non-sample session, one block per session. Bank answers are not read: they are meeting-specific."""
    blocks: list[str] = []
    root = sessions.expanduser()
    if not root.is_dir():
        return ""
    for d in sorted(p for p in root.iterdir() if p.is_dir()):
        if d.name.startswith("sample"):
            continue
        meta = {}
        try:
            meta = json.loads((d / "meta.json").read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            pass
        if "tests/fixtures" in str(meta.get("prep_note", "")):
            continue
        f = d / "facts.jsonl"
        if not f.is_file():
            continue
        lines = []
        for ln in f.read_text(encoding="utf-8").splitlines():
            try:
                rec = json.loads(ln)
            except json.JSONDecodeError:
                continue
            if isinstance(rec, dict) and rec.get("text"):
                lines.append(f"- {rec.get('kind', 'fact')}: {one_line(str(rec['text']))} (value: {rec.get('value', '')})")
        if lines:
            blocks.append(f"# session {d.name}\n" + "\n".join(lines))
    return "\n\n".join(blocks)


def read_sources(paths: Paths, sources: list[dict], vault: Path = DEFAULT_VAULT) -> tuple[list[Doc], list[str]]:
    """The enabled sources as documents (handles S1.. in list order). Returns (docs, warnings). A source that is missing
    is skipped with a warning; one inside a private vault folder is refused."""
    docs: list[Doc] = []
    warnings: list[str] = []
    for s in sources:
        if not s.get("enabled", True):
            continue
        kind, p = str(s.get("kind", "file")), Path(str(s["path"])).expanduser()
        label = str(s.get("label") or p.name)
        if kind == "sessions":
            text, ref = session_facts_text(p), "session:facts"
        else:
            if forbidden_vault_path(p, vault):
                warnings.append(f"refused {label}: it is inside a private vault folder")
                continue
            if not p.is_file():
                warnings.append(f"source missing: {label}")
                continue
            text = _read_text(p)
            if kind == "vault":
                try:
                    rel = p.resolve().relative_to(vault.expanduser().resolve())
                    ref = "vault:" + str(rel).split("🏰 ", 1)[-1]
                except ValueError:
                    ref = f"vault:{p.name}"
            elif kind == "notes":
                ref = "owner"
            else:
                ref = f"file:{p.name}"
        if not text.strip():
            continue
        docs.append(Doc(f"S{len(docs) + 1}", str(s.get("id", f"s{len(docs) + 1}")), kind, ref, label, text))
    notes = paths.notes
    if notes.is_file() and not any(d.kind == "notes" for d in docs):
        text = notes.read_text(encoding="utf-8")
        if text.strip():
            docs.append(Doc(f"S{len(docs) + 1}", "notes", "notes", "owner", "me.notes.md", text))
    used = 0
    for d in docs:            # sources over the budget stay library-only: the call must stay about 15-20k tokens
        used += len(d.text)
        if used > MAX_CORE_CHARS and d.kind != "notes":
            d.core = False
            warnings.append(f"{d.label} is library-only: the core sources are over {MAX_CORE_CHARS} chars")
    return docs, warnings


def source_hashes(docs: list[Doc]) -> dict[str, str]:
    return {d.id: sha256_text(d.text) for d in docs}


# ---------------------------------------------------------------- lines
@dataclass
class MLine:
    id: str | None
    section: str
    text: str                      # the whole line as written in me.md, with its [id]
    fields: list[str] = field(default_factory=list)
    src: str = ""
    quote: dict | None = None      # {"kind","ref","quote"} of a generated line

    @property
    def key(self) -> str:
        return line_key(self.section, self.fields, self.text)

    @property
    def sha(self) -> str:
        return sha256_text(one_line(self.text))


def line_key(section: str, fields: list[str], text: str) -> str:
    idx = KEY_FIELDS[section]
    if len(fields) > max(idx):
        return norm(" | ".join(fields[i] for i in idx))
    return norm(_ID.sub(lambda m: m.group(2), text))


def make_line(section: str, id_: str, fields: list[str], src: str, quote: dict | None = None) -> MLine:
    fields = [one_line(f).replace("|", "/") for f in fields]
    return MLine(id_, section, f"[{id_}] " + " | ".join([*fields, src]), fields, src, quote)


def parse_body(section: str, id_: str | None, body: str, raw: str) -> MLine:
    parts = [p.strip() for p in body.split(" | ")]
    n = N_FIELDS[section]
    if len(parts) == n + 1:
        return MLine(id_, section, raw, parts[:n], parts[n])
    return MLine(id_, section, raw, parts[:-1] if len(parts) > 1 else parts, parts[-1] if len(parts) > 1 else "")


def parse_md(text: str) -> dict[str, list[MLine]]:
    """me.md -> lines per section. A line without an id (typed by hand) is kept as it is."""
    out: dict[str, list[MLine]] = {s: [] for s in SECTIONS}
    cur: str | None = None
    for ln in text.splitlines():
        s = ln.strip()
        if s.startswith("## "):
            name = next((x for x in SECTIONS if x.casefold() == s[3:].strip().casefold()), None)
            cur = name
            continue
        if cur is None or not s:
            continue
        m = _ID.match(s)
        out[cur].append(parse_body(cur, m.group(1) if m else None, m.group(2) if m else s, s))
    return out


def id_number(i: str | None) -> int:
    return int(i[1:]) if i else 10 ** 6


def render_md(sections: dict[str, list[MLine]]) -> str:
    out: list[str] = []
    for name in SECTIONS:
        out.append(f"## {name}")
        lines = sorted((l for l in sections.get(name, []) if l.id), key=lambda l: id_number(l.id))
        lines += [l for l in sections.get(name, []) if not l.id]
        out += [l.text for l in lines]
        out.append("")
    return "\n".join(out)


def section_base(section: str) -> int:
    return SECTIONS.index(section) * 100


def alloc_id(section: str, used: set[str]) -> str | None:
    base = section_base(section)
    for n in range(base + 1, base + 100):
        i = f"m{n:03d}"
        if i not in used:
            return i
    return None


def count_lines(sections: dict[str, list[MLine]]) -> dict[str, int]:
    return {s: len(sections.get(s, [])) for s in SECTIONS}


# ---------------------------------------------------------------- the model call
SYSTEM = """You are the profile stage of Verse, a live call assistant. Verse shows Alex short lines to say out loud, \
and it must always know who he is. From the source documents you get (his engineering profile, project notes, facts \
from earlier meeting preps, his own notes) you write his permanent profile.

Reply with these eight sections, in this order, each starting with its "## " heading, and nothing before the first \
heading or after the last line:

## WHO I AM
[m001] <one plain sentence about who he is and what he does> | SRC: S1 "<quote>"
## EXPERIENCE
[m101] <years, for example 2019-2022> | <role> | <organisation> | <one line about what he did> | SRC: ...
## PROJECTS
[m201] <name> | <what it is> | <his role> | <stack> | <numbers, or -> | SRC: ...
## SKILLS
[m301] <skill> | <evidence: where he used it> | SRC: ...
## NUMBERS
[m401] <kind: number, date or name> | <one sentence that states the fact> | <the value> | SRC: ...
## STORIES
[m501] <short title> | <situation, action and result in at most 60 words> | SRC: ...
## LOOKING FOR
[m601] <what he is looking for: role, location, availability> | SRC: ...
## MY NOTES
(leave this section empty: his notes are added by the program)

Rules:
- Every line ends with SRC: S<k> "<quote>". The quote is copied exactly, character for character, from document S<k> \
(10 to 160 characters, in the document's own language). It has to contain every number, date and name the line states. \
A line without a quote that can be found in its document is thrown away.
- Write the lines in English, also when the source is in another language. Facts only: no "I" and no "he", no \
opinions of yours, no advice.
- Only facts about Alex himself: his work, his projects, his numbers. Facts in the session documents that are about \
another company or person are not his: leave them out.
- Never invent anything. A number is written as the source gives it. The value in NUMBERS is the bare value: digits \
only for a number (38000), YYYY-MM-DD for a date, the name itself for a name.
- LOOKING FOR holds only what the sources state about what he wants next; write no line if they say nothing.
- Keep to these maximum item counts: WHO I AM 5, EXPERIENCE 8, PROJECTS 10, SKILLS 20, NUMBERS 40, STORIES 8, \
LOOKING FOR 5. The whole answer stays under 3,000 tokens: pick what a person on a call is most likely to be asked.
- Ids are m001 and up in WHO I AM, m101 in EXPERIENCE, m201 in PROJECTS, m301 in SKILLS, m401 in NUMBERS, m501 in \
STORIES, m601 in LOOKING FOR. When a PREVIOUS PROFILE is given, keep the id of every line that is still true (you may \
improve its wording), and give new items ids that are free: not used there and not in RESERVED IDS.
- No markdown other than the headings, no blank lines inside a section, no emojis."""


def render_user(docs: list[Doc], previous: str = "", reserved: list[str] | None = None) -> str:
    parts = []
    for d in docs:
        if d.core:
            parts.append(f'<source id="{d.handle}" ref="{d.ref}">\n{d.text.strip()}\n</source>')
    if previous.strip():
        parts.append(f"<previous_profile>\n{previous.strip()}\n</previous_profile>")
    if reserved:
        parts.append("RESERVED IDS (taken or deleted, never use them): " + " ".join(sorted(reserved)))
    parts.append("Write the profile now.")
    return "\n\n".join(parts)


@dataclass
class RawLine:
    section: str
    id: str
    body: str
    handle: str
    quote: str


def parse_output(raw: str) -> tuple[list[RawLine], int]:
    """The model's text -> its lines; also the count of lines that could not be read (no id, no SRC, wrong section)."""
    text = raw.strip()
    text = re.sub(r"^```[a-zA-Z]*\s*\n", "", text)
    text = re.sub(r"\n```\s*$", "", text)
    out: list[RawLine] = []
    bad = 0
    cur: str | None = None
    for ln in text.splitlines():
        s = ln.strip()
        if s.startswith("## "):
            cur = next((x for x in SECTIONS if x.casefold() == s[3:].strip().casefold()), None)
            continue
        if not s or cur is None or cur == NOTES or s.startswith("("):
            continue
        m = _ID.match(s)
        if not m:
            bad += 1
            continue
        sm = _SRC.search(m.group(2))
        if not sm:
            bad += 1
            continue
        i = m.group(1)
        if int(i[1:]) // 100 != SECTIONS.index(cur):
            bad += 1
            continue
        out.append(RawLine(cur, i, m.group(2)[:sm.start()].strip(), sm.group(1), sm.group(2).strip()))
    return out, bad


def _line_no(doc: str, quote: str) -> int | None:
    pieces = [norm(p) for p in re.split(r"…|\.\.\.", quote) if len(norm(p)) >= 4]
    if not pieces:
        return None
    for i, ln in enumerate(doc.splitlines(), start=1):
        if all(p in norm(ln) for p in pieces):
            return i
    return None


def verify_line(raw: RawLine, docs: dict[str, Doc], book: SourceBook) -> tuple[MLine | None, str]:
    """-> (line, "") or (None, reason). The quote has to be in the document, the line's own numbers in the quote."""
    d = docs.get(raw.handle)
    if d is None:
        return None, "unknown_source"
    quote = raw.quote.strip()
    if len(norm(quote)) < MIN_QUOTE_CHARS:
        return None, "quote_too_short"
    quote = quote[:MAX_QUOTE_CHARS]
    if not book.supports(d.text, quote):
        return None, "quote_not_in_source"
    parts = [p.strip() for p in raw.body.split(" | ")]
    if len(parts) != N_FIELDS[raw.section] or not all(parts[:1]):
        return None, "malformed"
    if raw.section == NUMBERS:
        kind, text, value = parts
        if kind not in FACT_KINDS or not text or not value:
            return None, "malformed"
        # a date is checked by its value (month names are not parsed), a number also by the numbers of its sentence
        if kind == "number" and not numbers_supported(text, [quote]):
            return None, "number_not_in_quote"
        if not _value_supported(kind, value, [quote]):
            return None, "value_not_in_quote"
    elif not numbers_supported(raw.body, [quote]):
        return None, "number_not_in_quote"
    ln = _line_no(d.text, quote)
    ref = d.ref + (f"#L{ln}" if ln and d.kind in ("file", "vault", "notes") and d.ref != "owner" else "")
    line = make_line(raw.section, raw.id, parts, ref, {"kind": d.kind, "ref": ref, "quote": quote})
    return line, ""


async def generate(model: PrepModel, docs: list[Doc], previous: str, reserved: list[str], *, budget_usd: float,
                   attempts: int = 2) -> tuple[list[RawLine], Usage, dict]:
    """One distillation call (a second only when nothing usable came back). -> (raw lines, summed usage, stats)."""
    user = render_user(docs, previous, reserved)
    in_tokens = await model.count_request_tokens(SYSTEM, user)
    pin, pout = PRICES[model.model]
    max_tokens = min(MAX_OUTPUT_TOKENS, int((budget_usd - in_tokens * pin / 1e6) / (pout / 1e6)))
    if max_tokens < 8000:
        raise MeError(f"budget ${budget_usd:.2f} leaves only {max_tokens} output tokens; raise --budget-usd or shrink the sources")
    total, problem = Usage(), ""
    for _ in range(attempts):
        res = await model.generate(SYSTEM, user + (f"\n\nYour previous answer was rejected: {problem}" if problem else ""), max_tokens)
        total = Usage(total.input + res.usage.input, total.output + res.usage.output,
                      total.cache_read + res.usage.cache_read, total.cache_write + res.usage.cache_write)
        lines, bad = parse_output(res.text)
        if lines:
            return lines, total, {"unreadable": bad, "input_tokens": in_tokens}
        problem = "no line could be read. Use the formats of the instructions, with SRC: S<k> \"<quote>\" at the end."
    raise MeError(f"the profile model returned nothing usable after {attempts} attempts: {problem}")


class FakeMeModel:
    """Offline stand-in for `--fake`: reads the documents out of the prompt and quotes their first lines. No network."""

    model = "claude-sonnet-5-5"

    async def generate(self, system: str, user: str, max_tokens: int):
        from .model import ModelOutput
        docs = re.findall(r'<source id="(S\d+)" ref="[^"]*">\n(.*?)\n</source>', user, re.S)
        who, proj = [], []
        for h, body in docs:
            lines = [l.strip(" -#*") for l in body.splitlines() if 30 <= len(l.strip(" -#*")) <= 150]
            for l in lines[:3 if h == "S1" else 1]:
                (who if h == "S1" else proj).append((h, l))
        out = ["## WHO I AM"] + [f'[m{i + 1:03d}] {l} | SRC: {h} "{l}"' for i, (h, l) in enumerate(who[:3])]
        out += ["## PROJECTS"] + [f'[m{201 + i}] {l[:40]} | {l} | owner | - | - | SRC: {h} "{l}"' for i, (h, l) in enumerate(proj[:4])]
        return ModelOutput("\n".join(out) + "\n", Usage(input=100, output=100), "end_turn")

    async def count_tokens(self, text: str) -> int:
        return len(text) // 4

    async def count_request_tokens(self, system: str, user: str) -> int:
        return (len(system) + len(user)) // 4


# ---------------------------------------------------------------- merge with what is on disk
def notes_lines(text: str) -> list[str]:
    out = []
    for ln in text.splitlines():
        s = ln.strip()
        s = re.sub(r"^([-*+]|\d+[.)])\s+", "", s)
        if s and not s.startswith("#"):
            out.append(one_line(s))
    return out


@dataclass
class Merged:
    sections: dict[str, list[MLine]]
    protected: set[str]            # ids the trim must not touch (kept lines)
    deleted: dict[str, str] = field(default_factory=dict)      # id -> key of every generated line he deleted
    kept: int = 0
    skipped_deleted: int = 0
    skipped_kept: int = 0
    dropped: dict = field(default_factory=dict)


def merge(prev_md: str | None, meta: dict, generated: list[MLine], notes: list[str]) -> Merged:
    """Generated lines + what he has done to the file since the last build:
    - an edited line (its hash differs from the generated one), a line he added, and every note are kept verbatim;
    - a generated line that is still as generated is replaced by the new generation;
    - a line he deleted stays deleted (by id, and by content under a new id)."""
    prev = parse_md(prev_md) if prev_md else {s: [] for s in SECTIONS}
    gen_meta: dict = meta.get("lines", {})
    notes_seen = set(meta.get("notes_seen", []))
    deleted: dict[str, str] = {d["id"]: d["key"] for d in meta.get("deleted", [])}      # id -> key
    present_ids = {l.id for ls in prev.values() for l in ls if l.id}
    for i, g in gen_meta.items():
        if i not in present_ids and prev_md is not None:
            deleted[i] = g.get("key", "")
    kept: dict[str, list[MLine]] = {s: [] for s in SECTIONS}
    for s, ls in prev.items():
        for l in ls:
            g = gen_meta.get(l.id) if l.id else None
            if s == NOTES or g is None or g.get("sha") != l.sha:
                kept[s].append(l)
    kept_ids = {l.id for ls in kept.values() for l in ls if l.id}
    kept_keys = {(s, l.key) for s, ls in kept.items() for l in ls}
    deleted_keys = {k for k in deleted.values() if k}
    used = set(kept_ids) | set(deleted) | set(meta.get("notes_issued", []))   # an id once given to a note is never reused
    m = Merged({s: list(ls) for s, ls in kept.items()}, set(kept_ids), {i: k for i, k in deleted.items() if i not in kept_ids})
    m.kept = sum(len(v) for v in kept.values())
    accepted: set[tuple[str, str]] = set()
    # notes: new lines of me.notes.md that were never added (a deleted or edited note is not added again)
    for n in notes:
        k = norm(n)
        if k in notes_seen or (NOTES, k) in kept_keys:
            continue
        i = alloc_id(NOTES, used)
        if i is None:
            break
        used.add(i)
        line = make_line(NOTES, i, [n], "owner")
        m.sections[NOTES].append(line)
        m.protected.add(i)
    for g in generated:
        if (g.section, g.key) in accepted:
            continue
        if (g.section, g.key) in kept_keys or g.id in kept_ids:
            m.skipped_kept += 1
            continue
        if g.key in deleted_keys or (g.id in deleted and not deleted[g.id]):
            m.skipped_deleted += 1
            continue
        i = g.id
        if i in used:
            i = alloc_id(g.section, used)
            if i is None:
                m.dropped["no_free_id"] = m.dropped.get("no_free_id", 0) + 1
                continue
            g = make_line(g.section, i, g.fields, g.src, g.quote)
        used.add(i)
        accepted.add((g.section, g.key))
        m.sections[g.section].append(g)
    return m


# ---------------------------------------------------------------- size
async def trim_to_cap(m: Merged, count: Callable[[str], "asyncio.Future[int]"], cap: int = CAP_TOKENS) -> tuple[str, int, dict]:
    """Render and cut to `cap` tokens: STORIES tail, then SKILLS, PROJECTS, EXPERIENCE (generated lines only). WHO I AM,
    NUMBERS, LOOKING FOR, the notes and every line he edited or added stay; if they alone are over, the build fails."""
    cut = {s: 0 for s in TRIM_ORDER}
    text = render_md(m.sections)
    tokens = await count(text)
    for _ in range(60):
        if tokens <= cap:
            return text, tokens, cut
        def free(l: MLine) -> bool:
            return l.id is not None and l.id not in m.protected

        sec = next((s for s in TRIM_ORDER if any(free(l) for l in m.sections[s])), None)
        if sec is None:
            break
        removable = sorted((l for l in m.sections[sec] if free(l)), key=lambda l: id_number(l.id))
        avg = max(1.0, sum(len(l.text) for l in removable) / len(removable) * tokens / max(1, len(text)))
        k = min(len(removable), max(1, math.ceil((tokens - cap) / avg)))
        for l in removable[len(removable) - k:]:
            m.sections[sec].remove(l)
        cut[sec] += k
        text = render_md(m.sections)
        tokens = await count(text)
    raise MeError(f"the profile is {tokens} tokens; the cap is {cap}. WHO I AM, NUMBERS, LOOKING FOR, the notes and the "
                  f"lines you edited alone are over it: shorten them (the Me page, or me.md)")


# ---------------------------------------------------------------- facts and library
def facts_records(sections: dict[str, list[MLine]]) -> list[dict]:
    out = []
    for l in sorted(sections.get(NUMBERS, []), key=lambda l: id_number(l.id)):
        if not l.id or len(l.fields) != 3 or l.fields[0] not in FACT_KINDS:
            continue
        kind, text, value = l.fields
        src = l.quote or {"kind": "owner", "ref": "me.md", "quote": text}
        out.append({"id": l.id, "kind": kind, "text": text, "value": value, "sources": [src]})
    return out


_HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
_SENT = re.compile(r"(?<=[.!?])\s+")


def _split_long(text: str, limit: int) -> list[str]:
    if len(text) <= limit:
        return [text]
    out, cur = [], ""
    for para in re.split(r"\n\s*\n", text):
        pieces = [para] if len(para) <= limit else _SENT.split(para)
        for p in pieces:
            while len(p) > limit:                   # a sentence longer than a chunk: cut it
                if cur:
                    out.append(cur)
                    cur = ""
                out.append(p[:limit])
                p = p[limit:]
            if len(cur) + len(p) + 2 > limit and cur:
                out.append(cur)
                cur = ""
            cur = (cur + "\n\n" + p) if cur else p
    if cur:
        out.append(cur)
    return out


def chunk_doc(d: Doc) -> list[dict]:
    """A document split by heading into chunks of at most CHUNK_CHARS (a long section is split on paragraphs, then
    sentences). Each keeps its heading as a first line."""
    secs: list[tuple[str, list[str]]] = [("", [])]
    for ln in d.text.splitlines():
        m = _HEADING.match(ln)
        if m:
            secs.append((m.group(2).strip(), [ln]))
        else:
            secs[-1][1].append(ln)
    out = []
    for heading, lines in secs:
        body = "\n".join(lines).strip()
        if len(body) < MIN_CHUNK_CHARS or (heading and len(body) - len(heading) < MIN_CHUNK_CHARS // 2):
            continue
        for part in _split_long(body, CHUNK_CHARS):
            h = hashlib.sha1(f"{d.ref}\x00{heading}\x00{part}".encode("utf-8")).hexdigest()
            out.append({"id": "c" + h[:6], "ref": d.ref, "source": d.label, "heading": heading, "text": part})
    return out


def build_library(docs: list[Doc]) -> tuple[list[dict], bool]:
    """Chunks of every enabled document except session facts (those belong to one meeting each). -> (chunks, truncated)."""
    chunks, seen = [], set()
    for d in docs:
        if d.kind == "sessions":
            continue
        for c in chunk_doc(d):
            if c["id"] in seen:
                continue
            seen.add(c["id"])
            chunks.append(c)
    return chunks[:MAX_CHUNKS], len(chunks) > MAX_CHUNKS


class HashEmbedder:
    """Offline stand-in (`--fake`): hashed bag of words, 64 dimensions. Not a model; it only exercises the file path."""

    dim = 64

    def embed(self, text: str) -> list[float]:
        v = [0.0] * self.dim
        for w in re.findall(r"\w+", text.lower()):
            v[int(hashlib.sha1(w.encode()).hexdigest(), 16) % self.dim] += 1.0
        return v

    def close(self) -> None:
        pass


# ---------------------------------------------------------------- the whole build
@dataclass
class BuildResult:
    dir: Path
    tokens: int
    usage: Usage
    spend_usd: float
    counts: dict
    trimmed: dict
    dropped: dict
    warnings: list[str]
    unchanged: bool = False
    chunks: int = 0
    embedded: bool = False


def _atomic(p: Path, text: str) -> None:
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(p)


def _backup(p: Path) -> Path | None:
    """Move an existing file aside (never delete): me.md.bak, .bak2, ..."""
    if not p.is_file():
        return None
    k, bak = 1, p.with_name(p.name + ".bak")
    while bak.exists():
        k += 1
        bak = p.with_name(f"{p.name}.bak{k}")
    bak.write_text(p.read_text(encoding="utf-8"), encoding="utf-8")
    return bak


def stale_sources(paths: Paths, docs: list[Doc]) -> list[str]:
    try:
        meta = json.loads(paths.meta.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return [d.label for d in docs]
    old = meta.get("sources", {})
    new = source_hashes(docs)
    out = [d.label for d in docs if old.get(d.id) != new[d.id]]
    out += [f"(removed) {i}" for i in old if i not in new]
    return out


async def build_profile(profile_dir: Path, *, model: PrepModel, refresh: bool = False, budget_usd: float = 0.5,
                        embedder_factory: Callable[[], object] | None = None, embed_model_path: str | None = None,
                        vault: Path = DEFAULT_VAULT, now: Callable[[], datetime] | None = None,
                        log: Callable[[str], None] = lambda s: None) -> BuildResult:
    paths = Paths(profile_dir.expanduser())
    paths.dir.mkdir(parents=True, exist_ok=True)
    sources = load_sources(paths)
    if not paths.sources.is_file():
        save_sources(paths, sources)
    docs, warnings = read_sources(paths, sources, vault)
    if not any(d.core for d in docs):
        raise MeError("no readable source: add one to me.sources.json or the Me page")
    prev_md = paths.md.read_text(encoding="utf-8") if paths.md.is_file() else None
    meta: dict = {}
    if paths.meta.is_file():
        try:
            meta = json.loads(paths.meta.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            meta = {}
    if refresh and prev_md is not None and not stale_sources(paths, docs):
        return BuildResult(paths.dir, int(meta.get("tokens", 0)), Usage(), 0.0, meta.get("counts", {}), {}, {}, warnings,
                           unchanged=True)
    if not refresh:     # a full build: what he edited is moved to me.md.bak, his notes and deletions are not carried over
        meta = {}
        if prev_md is not None:
            warnings.append(f"me.md existed: moved to {_backup(paths.md).name}; `refresh` would have kept your edits")  # type: ignore[union-attr]
            prev_md = None

    by_handle = {d.handle: d for d in docs}
    book = SourceBook(prep_lines=[])
    previous = ""
    reserved: list[str] = []
    if refresh and prev_md is not None:
        gen_ids = set(meta.get("lines", {}))
        pm = parse_md(prev_md)
        previous = "\n".join(f"## {s}\n" + "\n".join(l.text for l in pm[s] if l.id in gen_ids)
                             for s in SECTIONS if s != NOTES and any(l.id in gen_ids for l in pm[s]))
        reserved = [l.id for ls in pm.values() for l in ls if l.id and l.id not in gen_ids] + [d["id"] for d in meta.get("deleted", [])]
    raws, usage, stats = await generate(model, docs, previous, reserved, budget_usd=budget_usd)
    dropped: dict[str, int] = {}
    if stats.get("unreadable"):
        dropped["unreadable"] = stats["unreadable"]
    generated: list[MLine] = []
    per_section: dict[str, int] = {}
    for r in raws:
        if per_section.get(r.section, 0) >= MAX_PER_SECTION.get(r.section, 0):
            dropped["over_section_cap"] = dropped.get("over_section_cap", 0) + 1
            continue
        line, why = verify_line(r, by_handle, book)
        if line is None:
            dropped[why] = dropped.get(why, 0) + 1
            continue
        per_section[r.section] = per_section.get(r.section, 0) + 1
        generated.append(line)
    if not generated:
        raise MeError("no line of the model's profile could be verified against the sources; nothing was written")
    notes = notes_lines(paths.notes.read_text(encoding="utf-8")) if paths.notes.is_file() else []
    merged = merge(prev_md, meta, generated, notes)

    async def count(t: str) -> int:
        return await model.count_tokens(t)

    old_quotes = meta.get("quotes", {})
    for l in merged.sections[NUMBERS]:           # a kept NUMBERS line keeps the quote it was generated with
        if l.quote is None and l.id in old_quotes:
            l.quote = old_quotes[l.id]
    md, tokens, trimmed = await trim_to_cap(merged, count, CAP_TOKENS)
    present = {l.id for ls in merged.sections.values() for l in ls if l.id}
    lines_meta = {l.id: {"sha": l.sha, "key": l.key} for ls in merged.sections.values() for l in ls
                  if l.id and l.id not in merged.protected}
    for i, g in meta.get("lines", {}).items():           # an edited line keeps the hash of what was generated
        if i in merged.protected and i in present:
            lines_meta[i] = g
    # lines the trim removed are neither deleted by him nor in the file next time: they are not recorded at all
    deleted = [{"id": i, "key": k} for i, k in sorted(merged.deleted.items()) if i not in present]
    notes_seen = sorted(set(meta.get("notes_seen", [])) | {norm(n) for n in notes if norm(n)})
    notes_issued = sorted(set(meta.get("notes_issued", [])) | {l.id for l in merged.sections[NOTES] if l.id})
    quotes = {l.id: l.quote for ls in merged.sections.values() for l in ls if l.id and l.quote}
    spend = spend_usd(model.model, usage) if model.model in PRICES else 0.0

    # library and embeddings
    chunks, truncated = build_library(docs)
    embedded = False
    if chunks and embedder_factory is not None:
        try:
            emb = embedder_factory()
            from ..runtime.embed import PREFIX, unit
            vecs = [unit(emb.embed(PREFIX + c["text"])) for c in chunks]      # type: ignore[attr-defined]
            from ..runtime.me import model_sha
            sha = model_sha(embed_model_path) if embed_model_path else "fake"
            if sha is None:
                raise MeError("embedding model file not found")
            write_emb(paths.emb, [c["id"] for c in chunks], vecs, sha)
            embedded = True
            getattr(emb, "close", lambda: None)()
        except Exception as e:  # noqa: BLE001 - the library still works: the brain embeds the chunks itself at start
            warnings.append(f"chunk vectors not written ({type(e).__name__}: {str(e)[:120]}); the brain embeds them at start")
            if paths.emb.is_file():
                paths.emb.unlink()
    elif paths.emb.is_file():
        paths.emb.unlink()          # chunks changed and no new vectors: a stale file would be ignored anyway
    _atomic(paths.library, "".join(json.dumps(c, ensure_ascii=False) + "\n" for c in chunks))

    _atomic(paths.md, md)
    _atomic(paths.facts, "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in facts_records(merged.sections)))
    prev_total = float(meta.get("spend_usd_total", 0.0))
    built = (now or (lambda: datetime.now(timezone.utc)))().isoformat(timespec="seconds")
    counts = count_lines(merged.sections)
    new_meta = {
        "model": model.model, "built_at": built, "tokens": tokens, "cap_tokens": CAP_TOKENS, "usage": usage.as_dict(),
        "spend_usd": round(spend, 6), "spend_usd_total": round(prev_total + spend, 6), "sources": source_hashes(docs),
        "lines": lines_meta, "deleted": deleted, "notes_seen": notes_seen, "notes_issued": notes_issued, "quotes": quotes, "counts": counts,
        "trimmed": trimmed, "dropped": dropped, "kept": merged.kept, "skipped_deleted": merged.skipped_deleted,
        "library": {"chunks": len(chunks), "truncated": truncated, "embedded": embedded},
        "demoted": [d.label for d in docs if not d.core], "refresh": refresh,
    }
    _atomic(paths.meta, json.dumps(new_meta, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
    return BuildResult(paths.dir, tokens, usage, spend, counts, trimmed, dropped, warnings, chunks=len(chunks), embedded=embedded)


def show(profile_dir: Path, vault: Path = DEFAULT_VAULT) -> str:
    paths = Paths(profile_dir.expanduser())
    if not paths.md.is_file():
        return f"profile: {paths.dir}\nno me.md yet: run `python -m verse_brain.prep me build`"
    meta = {}
    try:
        meta = json.loads(paths.meta.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pass
    sections = parse_md(paths.md.read_text(encoding="utf-8"))
    docs, _ = read_sources(paths, load_sources(paths), vault)
    stale = stale_sources(paths, docs)
    out = [f"profile: {paths.dir}",
           f"built: {meta.get('built_at', '?')} | model {meta.get('model', '?')} | tokens {meta.get('tokens', '?')} / cap {CAP_TOKENS} "
           f"| spend ${meta.get('spend_usd_total', 0):.4f} total",
           "sections: " + " | ".join(f"{s} {len(sections[s])}" for s in SECTIONS), "sources:"]
    out += [f"  {d.handle} {d.kind:8} {d.label}" + (" (changed)" if d.label in stale else "") + ("" if d.core else " (library only)") for d in docs]
    out.append("stale sources: " + (", ".join(stale) if stale else "none"))
    return "\n".join(out)


# ---------------------------------------------------------------- CLI
def me_main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="python -m verse_brain.prep me", description=(
        "the owner's permanent profile (the me layer): build it from his sources, refresh it, or show its state."))
    ap.add_argument("action", choices=["build", "refresh", "show"])
    ap.add_argument("--fake", action="store_true", help="offline: a fake model and a hashing embedder; no network, no key, no spend")
    ap.add_argument("--budget-usd", type=float, default=0.5, help="hard cap used to size max_tokens")
    ap.add_argument("--profile-dir", type=Path, default=PROFILE_DIR, help=f"default {PROFILE_DIR}")
    ap.add_argument("--no-embed", action="store_true", help="do not embed the library chunks now (the brain does it at start)")
    a = ap.parse_args(argv)
    pdir = a.profile_dir.expanduser()
    if a.action == "show":
        print(show(pdir))
        return 0
    key = None
    try:
        if a.fake:
            model, factory, embed_path = FakeMeModel(), (None if a.no_embed else HashEmbedder), None
        else:
            from ..runtime.settings import Config
            from .model import PREP_MODEL, AnthropicPrepModel
            key = read_api_key()      # only to scrub error text; the model client reads its own copy
            model = AnthropicPrepModel(key, PREP_MODEL, progress=True)
            cfg = Config()
            embed_path = str(Path(cfg.embed_model).expanduser())
            factory = None
            if not a.no_embed:
                from ..runtime.embed import LiteRtEmbedder
                factory = lambda: LiteRtEmbedder(embed_path, cfg.embed_backend)  # noqa: E731

        async def run() -> BuildResult:
            try:
                return await build_profile(pdir, model=model, refresh=a.action == "refresh", budget_usd=a.budget_usd,
                                           embedder_factory=factory, embed_model_path=embed_path)
            finally:
                close = getattr(model, "aclose", None)
                if close is not None:
                    await close()

        r = asyncio.run(run())
    except (KeychainError, PrepError, OSError) as e:
        print(f"error: {redact(str(e), key)}", file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001
        print(f"error: {type(e).__name__}: {redact(str(e), key)[:300]}", file=sys.stderr)
        return 1
    err = lambda s: print(s, file=sys.stderr)  # noqa: E731
    if r.unchanged:
        err("no source changed since the last build: nothing to do, nothing spent")
    else:
        err(f"me.md: {r.tokens} tokens / cap {CAP_TOKENS} | spend ${r.spend_usd:.4f} "
            f"(in {r.usage.input} out {r.usage.output} cache_read {r.usage.cache_read})")
        err("sections: " + " | ".join(f"{s} {n}" for s, n in r.counts.items()))
        err(f"library: {r.chunks} chunks" + (", vectors written" if r.embedded else ", no vectors"))
        if r.trimmed and any(r.trimmed.values()):
            err("trimmed: " + ", ".join(f"{s} -{n}" for s, n in r.trimmed.items() if n))
        if r.dropped:
            err("dropped lines: " + ", ".join(f"{k} {v}" for k, v in sorted(r.dropped.items())))
    for w in r.warnings:
        err(f"warning: {w}")
    print(r.dir)
    return 0
