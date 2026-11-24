"""The persona's notes and their machine state: deterministic merge, stable ids, owner edits kept, contradictions never overwritten.

Files (the folder is `persona_dir` from the owner profile; Verse never adopts a folder it did not create):

  <persona_dir>/.verse-persona       marker (JSON): which files in this folder Verse created. A non-empty folder without it is refused.
  <persona_dir>/Persona.md           the human-readable persona, edited freely in any markdown editor. Frontmatter (title, created,
                                     modified, type, status, tags) and sections:
                                       HOW I ANSWER                style and preference entries
                                       MY ANSWERS BY TOPIC         answer entries
                                       BETTER ANSWERS              the after-call review's bank answers (review.py): improved
                                                                   answers written from confirmed sources, his own strong
                                                                   wording, cards he marked GOOD (shown only once one exists)
                                       SAID BEFORE                 claim entries
                                       CONTRADICTIONS              one line per pair of entries that disagree
                                       MY CORRECTIONS              free text; Verse never rewrites it
                                       IMPORTED FROM GENERAL PREP  the one-time seed (owner-confirmed, each line names its origin)
  <persona_dir>/Log/<date> <skey>.md one note per session: the verified items with their quotes (append-only)
  <persona_dir>/Review/<date> <skey>.md the after-call review of that session (review.py; rewritten when the session is run again,
                                     the owner's edits of its answer lines read back first)
  <persona_dir>/Style guide.md       the imported style guide (verbatim), owner-editable; compile appends it to the pack
  <state>                            persona.meta.json OUTSIDE the vault: entries, line hashes, deleted ids, session fingerprints,
                                     spend

Entry lines carry an id: `p###` learned, `g###` seed, `c###` contradiction, `i###` better answer. Ids are never reused.

Better answers (`i###`): the owner edits one in Persona.md or in its Review note and his wording wins (ranked above every other
answer to that question). Writing `reject` as its last field, or deleting its line from Persona.md, rejects it: the question is
remembered in the state (`rejected`) and no better answer is generated for it again.

Owner edits (the me.md rule): the hash of every line Verse wrote is kept. A line whose text no longer has that hash is the owner's:
it is kept verbatim from then on and its fields are read back from it. A line whose id disappeared is deleted for good. Lines
without a known id and unknown `## ` sections are kept as they are (and count as confirmed: the owner wrote them).

Merge (code, never the model), per verified item:
  repeat         its evidence (stamp + quote) is already held, or an entry of the same kind says the same (content words
                 overlap >= 0.8, no differing number or name): the evidence is added to that entry
  contradiction  an entry on the same topic (topic content words overlap >= 0.5) whose numbers or names differ, or the entry the
                 model named in `contradicts`: the item becomes its own entry, a `c###` line with both dated quotes is appended,
                 and both entries are `contested`. Neither is removed or overwritten. While the contradiction is open, compile
                 leaves both values out and writes one "unsettled" line instead. The owner settles it by changing the line's last
                 field to `keep 1` / `keep 2` (or `keep [p###]`); the other entry is then `superseded` and stays as history.
  new            a new `p###` entry
A session whose fingerprint is unchanged is skipped (idempotent re-runs). A session run again (forced, changed, or a new review
version) replaces what its earlier run wrote (`retract`): the learned entries and better answers it does not write again leave
the persona, except the ones the owner edited or rejected, and evidence from other sessions stays.

Write guard: every write must resolve inside persona_dir, never be the folder itself or a symlink, and may replace only a file the
marker lists. Writes are atomic (temporary file in the same folder, then rename).
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import logging
import os
import re
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import date as Date
from pathlib import Path
from typing import Iterator

from ..prep.sources import numbers_in, significant_numbers
from ..runtime.me import content_words, jaccard
from .extract import Item, names_in

log = logging.getLogger("verse.persona.store")

MARKER = ".verse-persona"
PERSONA_MD = "Persona.md"
STYLE_MD = "Style guide.md"
LOG_DIR = "Log"
STATE_VERSION = 1

HOW, ANSWERS, SAID, CONTRA, CORRECTIONS, SEED = (
    "HOW I ANSWER", "MY ANSWERS BY TOPIC", "SAID BEFORE", "CONTRADICTIONS", "MY CORRECTIONS", "IMPORTED FROM GENERAL PREP")
BETTER = "BETTER ANSWERS"
SECTIONS = (HOW, ANSWERS, BETTER, SAID, CONTRA, CORRECTIONS, SEED)
OPTIONAL_SECTIONS = (BETTER, SEED)        # rendered only once they hold a line
SECTION_OF_KIND = {"style": HOW, "preference": HOW, "answer": ANSWERS, "claim": SAID, "contradiction": CONTRA,
                   "seed_bank": SEED, "seed_fact": SEED, "seed_glossary": SEED, "seed_snippet": SEED,
                   "improved": BETTER, "adopted": BETTER, "kept": BETTER}
SEED_KINDS = ("seed_bank", "seed_fact", "seed_glossary", "seed_snippet")
LEARNED_KINDS = ("answer", "claim", "style", "preference")
BETTER_KINDS = ("improved", "adopted", "kept")
# Which answer to a question the bank shows: the owner's own edit first, then a card he marked GOOD, then his own strong spoken
# wording, then an improved answer; newer before older inside one rank.
RANK = {"edited": 4, "kept": 3, "adopted": 2, "improved": 1}
QUESTION_OVERLAP = 0.5

REPEAT_OVERLAP = 0.8
TOPIC_OVERLAP = 0.5

PREAMBLE = (
    "# Verse Persona\n\n"
    "Written by Verse from your calls. Edit any line and Verse keeps your wording; delete a line and it does not come back. "
    "Write your own corrections under MY CORRECTIONS: Verse never rewrites that section. To settle a contradiction, change its "
    "last field from `open` to `keep 1` or `keep 2`.\n")
CORRECTIONS_HINT = "<!-- Your corrections, one \"- \" line each. Verse reads them as confirmed and never rewrites this section. -->"


class PersonaError(RuntimeError):
    kind = "error"


class PersonaOff(PersonaError):
    kind = "off"


class PersonaGuardError(PersonaError):
    kind = "guard"


class PersonaBusy(PersonaError):
    kind = "busy"


def sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def one_line(s: object) -> str:
    return " ".join(str(s or "").split())


def _q(s: str) -> str:
    """A quote as it sits between double quotes on one line."""
    return one_line(s).replace('"', "'")


def today() -> str:
    return Date.today().isoformat()


# ---------------------------------------------------------------- the guard
class Guard:
    """Every write of the persona goes through here (see the module doc)."""

    def __init__(self, base: Path) -> None:
        if not base.is_absolute():
            raise PersonaGuardError("persona_dir must be an absolute path")
        self.base = base
        self._files: set[str] | None = None

    @property
    def marker(self) -> Path:
        return self.base / MARKER

    def _load_marker(self) -> set[str]:
        if self._files is None:
            try:
                data = json.loads(self.marker.read_text(encoding="utf-8"))
                files = data.get("files") if isinstance(data, dict) and data.get("verse") == "persona" else None
                if not isinstance(files, list):
                    raise PersonaGuardError("the persona folder's marker is not Verse's")
                self._files = {str(f) for f in files if isinstance(f, str)}
            except (OSError, ValueError):
                raise PersonaGuardError("the persona folder has no readable Verse marker") from None
        return self._files

    def check_folder(self) -> None:
        """Refuse a folder Verse did not create: it must not exist, be empty, or carry the marker."""
        if self.base.is_symlink():
            raise PersonaGuardError("the persona folder is a symbolic link")
        if not self.base.exists():
            return
        if not self.base.is_dir():
            raise PersonaGuardError("persona_dir is not a folder")
        if self.marker.is_file():
            self._load_marker()
            return
        if any(self.base.iterdir()):
            raise PersonaGuardError("persona_dir is not empty and was not created by Verse; nothing is written there")

    def ensure(self) -> None:
        """Create the folder (its parent must exist: a typo never creates a vault) and the marker."""
        self.check_folder()
        if not self.base.exists():
            if not self.base.parent.is_dir():
                raise PersonaGuardError("the parent folder of persona_dir does not exist")
            self.base.mkdir()
        if not self.marker.is_file():
            self._files = set()
            self._write_marker()

    def _write_marker(self) -> None:
        payload = json.dumps({"verse": "persona", "version": 1, "files": sorted(self._files or ())}, indent=1) + "\n"
        tmp = self.base / (MARKER + ".verse-tmp")
        tmp.write_text(payload, encoding="utf-8")
        os.replace(tmp, self.marker)

    def resolve(self, rel: str) -> Path:
        base = self.base.resolve()
        p = (self.base / rel)
        if p.is_symlink():
            raise PersonaGuardError("refusing to write through a symbolic link")
        rp = p.resolve()
        if rp == base or base not in rp.parents:
            raise PersonaGuardError("refusing a write outside persona_dir")
        return rp

    def write(self, rel: str, text: str) -> Path:
        """Atomically write `rel` (relative to persona_dir). Refused outside the folder or over a file Verse did not create."""
        self.ensure()
        p = self.resolve(rel)
        files = self._load_marker()
        rel_key = p.relative_to(self.base.resolve()).as_posix()
        if p.exists() and rel_key not in files:
            raise PersonaGuardError("refusing to overwrite a file Verse did not create")
        p.parent.mkdir(parents=True, exist_ok=True)
        if base_escape(p.parent, self.base):
            raise PersonaGuardError("refusing a write outside persona_dir")
        tmp = p.with_name("." + p.name + ".verse-tmp")
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, p)
        if rel_key not in files:
            files.add(rel_key)
            self._write_marker()
        return p

    def created(self, rel: str) -> bool:
        try:
            return rel in self._load_marker()
        except PersonaGuardError:
            return False


def base_escape(p: Path, base: Path) -> bool:
    rp, rb = p.resolve(), base.resolve()
    return not (rp == rb or rb in rp.parents)


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name("." + path.name + ".verse-tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


# ---------------------------------------------------------------- Persona.md parse / render
_ENTRY = re.compile(r"^\s*-\s*\[([pgci]\d{3,})\]\s?(.*)$")
_FRONT = re.compile(r"\A(---\n.*?\n---\n)", re.S)


@dataclass
class Doc:
    front: str = ""
    preamble: str = ""
    sections: dict[str, list[str]] = field(default_factory=dict)     # known section -> raw lines (no heading)
    extra: list[tuple[str, list[str]]] = field(default_factory=list)  # unknown "## " sections, in order

    def entry_lines(self) -> dict[str, tuple[str, str]]:
        """id -> (section, line) of every entry line (the first one wins when an id repeats)."""
        out: dict[str, tuple[str, str]] = {}
        for sec, lines in self.sections.items():
            for ln in lines:
                m = _ENTRY.match(ln)
                if m and m.group(1) not in out:
                    out[m.group(1)] = (sec, ln.rstrip())
        return out


def parse_doc(text: str) -> Doc:
    d = Doc()
    m = _FRONT.match(text)
    body = text[m.end():] if m else text
    d.front = m.group(1) if m else ""
    cur: str | None = None
    cur_extra: list[str] | None = None
    pre: list[str] = []
    for ln in body.splitlines():
        if ln.startswith("## "):
            title = ln[3:].strip()
            known = next((s for s in SECTIONS if s.casefold() == title.casefold()), None)
            if known is not None:
                cur, cur_extra = known, None
                d.sections.setdefault(known, [])
            else:
                cur, cur_extra = None, []
                d.extra.append((ln, cur_extra))
            continue
        if cur is not None:
            d.sections[cur].append(ln)
        elif cur_extra is not None:
            cur_extra.append(ln)
        else:
            pre.append(ln)
    d.preamble = "\n".join(pre).strip("\n")
    return d


def _trim_blank(lines: list[str]) -> list[str]:
    a, b = 0, len(lines)
    while a < b and not lines[a].strip():
        a += 1
    while b > a and not lines[b - 1].strip():
        b -= 1
    return lines[a:b]


def front_matter(created: str, modified: str) -> str:
    return (f"---\ntitle: Verse Persona\ncreated: {created}\nmodified: {modified}\ntype: persona\nstatus: generated\n"
            "tags:\n  - verse\n  - persona\n---\n")


def _set_modified(front: str, day: str) -> str:
    if re.search(r"^modified:.*$", front, re.M):
        return re.sub(r"^modified:.*$", f"modified: {day}", front, count=1, flags=re.M)
    return front


# ---------------------------------------------------------------- state
def empty_state() -> dict:
    return {"version": STATE_VERSION, "next": {"p": 1, "g": 1, "c": 1, "i": 1}, "entries": {}, "deleted": [], "deleted_quotes": [],
            "lines": {}, "sessions": {}, "seed": None, "spend_usd": 0.0, "reviews": {}, "rejected": [], "note_lines": {}, "retracted": {}}


def _new_id(state: dict, prefix: str) -> str:
    taken = set(state["entries"]) | set(state["deleted"]) | set(state.get("reserved", [])) | set(state.get("retracted", {}))
    n = int(state["next"].get(prefix, 1))
    while f"{prefix}{n:03d}" in taken:
        n += 1
    state["next"][prefix] = n + 1
    return f"{prefix}{n:03d}"


def _fields(line: str) -> list[str]:
    m = _ENTRY.match(line)
    body = m.group(2) if m else line
    return [f.strip() for f in body.split(" | ")]


_KEEP = re.compile(r"\b(?:keep|kept|resolved?)\b[:\s]*(?:kept\s*)?\[?(p\d{3,}|g\d{3,}|[12])\]?", re.I)
_REJECT = re.compile(r"^\s*(?:reject(?:ed)?|rifiut\w*|reddet\w*)\b", re.I)


def is_reject(field_text: str) -> bool:
    """The owner's rejection of a better answer: its last field reads `reject` (or `rejected`)."""
    return bool(_REJECT.match(field_text or ""))


def same_question(a: list[str], b: list[str], overlap: float = QUESTION_OVERLAP) -> bool:
    """Two questions are the same when any wording of one shares at least `overlap` of its content words with any wording of the
    other (Jaccard over runtime/me.py `content_words`)."""
    wa = [w for w in (content_words(x) for x in a if x) if w]
    wb = [w for w in (content_words(x) for x in b if x) if w]
    return any(jaccard(x, y) >= overlap for x in wa for y in wb)


def _clean(s: object) -> str:
    """One line, with the field separator taken out (a `|` inside a text would split its line when read back)."""
    return one_line(s).replace(" | ", " / ").replace("|", "/")


# ---------------------------------------------------------------- the store
@dataclass
class MergeResult:
    new: list[str] = field(default_factory=list)
    repeats: int = 0
    contradictions: list[str] = field(default_factory=list)
    deleted: int = 0                  # items the owner had deleted before (same cite and quote): not brought back
    touched: set[str] = field(default_factory=set)    # entries this merge created or added evidence to


class PersonaStore:
    """The persona folder plus its state file. `load()` reads both and folds the owner's edits into the state; the writers save
    both atomically. Use `with store.locked():` around a read-modify-write."""

    def __init__(self, persona_dir: Path | str | None, state_path: Path | str) -> None:
        if persona_dir is None or not str(persona_dir).strip():
            raise PersonaOff("persona_dir is not set in the owner profile: the persona is off")
        self.dir = Path(persona_dir).expanduser()
        self.guard = Guard(self.dir)
        self.state_path = Path(state_path).expanduser()
        self.state: dict = empty_state()
        self.doc: Doc | None = None
        self._seen: str | None = None             # Persona.md as it was last read or written (`_refold` compares with it)
        self.owner_lines: list[str] = []          # lines without a known id (the owner's), every section
        self.corrections: list[str] = []          # MY CORRECTIONS bullets

    # ---- locking
    @contextmanager
    def locked(self) -> Iterator[None]:
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(self.state_path) + ".lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                raise PersonaBusy("another persona run holds the lock") from None
            yield
        finally:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)

    # ---- reading
    def exists(self) -> bool:
        return (self.dir / MARKER).is_file()

    def load(self) -> None:
        self.guard.check_folder()
        try:
            st = json.loads(self.state_path.read_text(encoding="utf-8"))
            self.state = st if isinstance(st, dict) and st.get("version") == STATE_VERSION else empty_state()
        except (OSError, ValueError):
            self.state = empty_state()
        for k, v in empty_state().items():
            self.state.setdefault(k, v)
        text = self._read_md()
        self._seen = text
        self.doc = parse_doc(text) if text is not None else None
        if self.doc is not None:
            self._sync(self.doc)

    def _read_md(self) -> str | None:
        md = self.dir / PERSONA_MD
        if md.is_file() and self.guard.created(PERSONA_MD):
            return md.read_text(encoding="utf-8", errors="replace")
        return None

    def _refold(self) -> bool:
        """Fold in what the owner changed in Persona.md since it was last read (a long model request runs between `load()` and
        `save()`, and his editor is not locked out): a correction typed, a line edited or deleted meanwhile is read again, so
        the write keeps it. True when the file had changed."""
        text = self._read_md()
        if text == self._seen:
            return False
        self._seen = text
        self.doc = parse_doc(text) if text is not None else None
        if self.doc is not None:
            self._sync(self.doc)
        return True

    def _sync(self, doc: Doc) -> None:
        """Fold the file into the state: edits, deletions, contradiction resolutions, the owner's own lines."""
        ents, lines = self.state["entries"], self.state["lines"]
        found = doc.entry_lines()
        for eid, e in ents.items():
            if eid in found:
                ln = found[eid][1]
                if lines.get(eid) is not None and sha(ln) != lines[eid]:
                    e["edited"] = ln
                elif lines.get(eid) is None and e.get("edited") and sha(ln) != sha(e["edited"]):
                    e["edited"] = ln
                if e["kind"] in BETTER_KINDS and e.get("edited") and is_reject(_fields(e["edited"])[-1]):
                    self._reject(e)
            elif lines.get(eid) is not None:                 # written once, gone now: deleted for good
                e["status"] = "deleted"
                if e["kind"] in BETTER_KINDS:                # a better answer deleted from Persona.md is rejected
                    self._remember_rejection(e)
        gone = self.state.setdefault("deleted_quotes", [])
        for eid in [i for i, e in ents.items() if e.get("status") == "deleted"]:
            for ev in ents[eid].get("evidence", []):          # the same words never come back under a new id either
                q = [ev.get("skey", ""), ev.get("stamp", ""), one_line(ev.get("quote", "")).casefold()]
                if q not in gone:
                    gone.append(q)
            del ents[eid]
            lines.pop(eid, None)
            if eid not in self.state["deleted"]:
                self.state["deleted"].append(eid)
        reserved = self.state.setdefault("reserved", [])
        for eid in found:                      # ids in the file the state does not know (a lost state file): never reused
            if eid not in ents and eid not in reserved and eid not in self.state["deleted"] and not self._stale(eid, found[eid][1]):
                reserved.append(eid)
        self.owner_lines = []
        for sec, raw in doc.sections.items():
            if sec == CORRECTIONS:
                continue
            for ln in raw:
                m = _ENTRY.match(ln)
                if ln.strip() and not ln.lstrip().startswith("<!--") and (
                        m is None or (m.group(1) not in ents and not self._stale(m.group(1), ln))):
                    self.owner_lines.append(ln.rstrip())
        self.corrections = [ln.strip()[2:].strip() for ln in doc.sections.get(CORRECTIONS, [])
                            if ln.strip().startswith(("- ", "* ")) and ln.strip()[2:].strip()]
        self._sync_notes()
        for c in [e for e in ents.values() if e["kind"] == "contradiction" and e.get("state") == "open" and e.get("edited")]:
            m = _KEEP.search(_fields(c["edited"])[-1])
            if m:
                pick = m.group(1).lower()
                keep = c["a"] if pick == "1" else c["b"] if pick == "2" else pick
                if keep in (c["a"], c["b"]):
                    self._resolve(c, keep)
        self._refresh_status()

    def _sync_notes(self) -> None:
        """Fold in the owner's edits of better-answer lines in the Review notes: a line whose text is not what Verse wrote there is
        his. `reject` as its last field rejects the answer; any other change is his wording (it then wins in Persona.md too).
        Each edit is folded once (its new hash is kept), so a later edit in Persona.md is not overridden by the note."""
        ents = self.state["entries"]
        for rel, hashes in self.state.setdefault("note_lines", {}).items():
            p = self.dir / rel
            if not hashes or not p.is_file() or not self.guard.created(rel):
                continue
            found: dict[str, str] = {}
            for ln in p.read_text(encoding="utf-8", errors="replace").splitlines():
                m = _ENTRY.match(ln)
                if m and m.group(1) in hashes and m.group(1) not in found:
                    found[m.group(1)] = ln.rstrip()
            for iid, h in hashes.items():
                ln, e = found.get(iid), ents.get(iid)
                if ln is None or e is None or sha(ln) == h:
                    continue
                hashes[iid] = sha(ln)
                if is_reject(_fields(ln)[-1]):
                    self._reject(e)
                else:
                    e["edited"] = ln.strip()

    def _reject(self, e: dict) -> None:
        if not e.get("rejected"):
            e["rejected"] = {"on": today()}
            self._remember_rejection(e)

    def _remember_rejection(self, e: dict) -> None:
        rej = self.state.setdefault("rejected", [])
        if any(r.get("id") == e["id"] for r in rej):
            return
        f = self.fields(e)
        rej.append({"id": e["id"], "question": one_line(f.get("question", "")), "paraphrases": list(e.get("paraphrases", []))[:4],
                    "topic": one_line(e.get("topic", "")), "on": today()})

    def is_rejected(self, question: str, topic: str = "", paraphrases: list[str] | None = None) -> bool:
        """A better answer to this question was rejected by the owner before: none is generated again."""
        mine = [question, *(paraphrases or [])]
        tw = content_words(topic)
        for r in self.state.get("rejected", []):
            if same_question(mine, [r.get("question", ""), *r.get("paraphrases", [])]):
                return True
            if tw and jaccard(tw, content_words(r.get("topic", ""))) >= TOPIC_OVERLAP and len(tw) > 1:
                return True
        return False

    def _resolve(self, c: dict, keep: str) -> None:
        lose = c["b"] if keep == c["a"] else c["a"]
        c.update(state="resolved", keep=keep, resolved_at=today())
        ents = self.state["entries"]
        if lose in ents:
            ents[lose]["superseded"] = {"by": keep, "on": today(), "contradiction": c["id"]}

    def _refresh_status(self) -> None:
        """contested = in an open contradiction; superseded = lost one; live otherwise."""
        ents = self.state["entries"]
        for c in ents.values():           # one side deleted by the owner: the other one stands
            if c["kind"] == "contradiction" and c.get("state") == "open" and (c["a"] not in ents) != (c["b"] not in ents):
                c.update(state="resolved", keep=c["a"] if c["a"] in ents else c["b"], resolved_at=today())
        open_ids = set()
        for c in ents.values():
            if c["kind"] == "contradiction" and c.get("state") == "open":
                open_ids |= {c["a"], c["b"]}
        for e in ents.values():
            if e["kind"] == "contradiction":
                continue
            if e["kind"] in BETTER_KINDS:
                e["status"] = "rejected" if e.get("rejected") else "superseded" if e.get("superseded") else "live"
                continue
            e["status"] = "superseded" if e.get("superseded") else "contested" if e["id"] in open_ids else "live"

    # ---- effective fields (an edited line wins)
    def fields(self, e: dict) -> dict:
        """topic / text (and the seed's own fields) as they stand now: read back from the owner's line when he edited it."""
        if e["kind"] in BETTER_KINDS:
            return self._better_fields(e)
        out = {"topic": e.get("topic", ""), "text": e.get("text", "")}
        if e["kind"] in SEED_KINDS:
            out.update(e.get("data") and _seed_fields(e) or {})
        ed = e.get("edited")
        if not ed:
            return out
        f = _fields(ed)
        if e["kind"] in LEARNED_KINDS:
            if len(f) >= 2:
                out["topic"], out["text"] = f[0], f[1]
            elif f and f[0]:
                out["text"] = f[0]
        elif e["kind"] == "seed_bank":
            for x in f:
                if x.startswith("Q:"):
                    out["question"] = x[2:].strip()
                elif x.startswith("SAY:"):
                    out["opener"] = x[4:].strip()
        elif e["kind"] == "seed_fact" and f and f[0].startswith("FACT:"):
            out["text"] = f[0][5:].strip()
            if len(f) > 1 and not f[1].startswith("from "):
                out["value"] = f[1]
        elif e["kind"] == "seed_glossary" and f and f[0].startswith("TERM:"):
            out["term"] = f[0][5:].strip()
            if len(f) > 1 and not f[1].startswith("from "):
                out["line"] = f[1]
        elif e["kind"] == "seed_snippet" and f and f[0].startswith("SNIPPET:"):
            out["ref"] = f[0][8:].strip()
            if len(f) > 1 and not f[1].startswith("from "):
                out["text"] = f[1]
        return out

    def _better_fields(self, e: dict) -> dict:
        out = {"topic": e.get("topic", ""), "question": e.get("question", ""), "opener": e.get("opener", ""),
               "points": list(e.get("points", [])), "paraphrases": list(e.get("paraphrases", []))}
        ed = e.get("edited")
        if ed:
            f = _fields(ed)
            tagged = False
            for x in f:
                if x.startswith("Q:"):
                    out["question"], tagged = x[2:].strip(), True
                elif x.startswith("SAY:"):
                    out["opener"], tagged = x[4:].strip(), True
                elif x.startswith("MORE:"):
                    out["points"], tagged = [p.strip() for p in x[5:].split(" / ") if p.strip()], True
            if not tagged and f and f[0]:
                out["opener"], out["points"] = f[0], []
        out["text"] = " ".join(x for x in [out["opener"], *out["points"]] if x)
        return out

    def entries(self, *kinds: str, statuses: tuple[str, ...] = ("live", "contested", "superseded")) -> list[dict]:
        return [e for _, e in sorted(self.state["entries"].items()) if (not kinds or e["kind"] in kinds)
                and (e["kind"] == "contradiction" or e.get("status", "live") in statuses)]

    def live(self, *kinds: str) -> list[dict]:
        return self.entries(*kinds, statuses=("live",))

    def persona_lines(self) -> list[str]:
        """CURRENT PERSONA for the extraction request: one compact line per entry that is not superseded."""
        out = []
        for e in self.entries(*LEARNED_KINDS, "seed_bank", "seed_fact", statuses=("live", "contested")):
            f = self.fields(e)
            mark = " (unsettled)" if e.get("status") == "contested" else ""
            if e["kind"] == "seed_bank":
                out.append(f"[{e['id']}] answer | {f.get('question', '')} | {f.get('opener', '')}")
            elif e["kind"] == "seed_fact":
                out.append(f"[{e['id']}] claim | {f.get('text', '')} | {f.get('value', '')}{mark}")
            else:
                out.append(f"[{e['id']}] {e['kind']} | {f['topic']} | {f['text']}{mark}")
        return out

    def confirmed_texts(self) -> list[str]:
        """What the persona itself holds as confirmed: the seed, his corrections, his own lines and entries he spoke himself."""
        out = list(self.corrections) + list(self.owner_lines)
        for e in self.entries(statuses=("live", "contested")):
            if e["kind"] in SEED_KINDS:
                out.append(" ".join(str(v) for v in self.fields(e).values() if isinstance(v, str)))
                d = e.get("data") or {}
                out += [str(p) for p in d.get("points", []) if isinstance(p, str)] + [str(d.get("deep", ""))]
            elif e["kind"] in LEARNED_KINDS and (e.get("edited") or any(ev.get("evidence") == "own" for ev in e.get("evidence", []))):
                out.append(self.fields(e)["text"])
        for e in self.live(*BETTER_KINDS):           # his own words: an answer he spoke, or one he edited
            if e.get("edited") or e["kind"] == "adopted":
                out.append(self.fields(e)["text"])
        return out

    # ---- merge
    def _all_quotes(self) -> set[tuple[str, str, str]]:
        out = set()
        for e in self.state["entries"].values():
            for ev in e.get("evidence", []):
                out.add((ev.get("skey", ""), ev.get("stamp", ""), one_line(ev.get("quote", "")).casefold()))
        return out

    def merge(self, items: list[Item], session: str, day: str, lang: str = "en") -> MergeResult:
        res = MergeResult()
        held = self._all_quotes()
        gone = {tuple(q) for q in self.state.get("deleted_quotes", [])}
        ents = self.state["entries"]
        for it in items:
            ev = {"skey": it.skey, "stamp": it.stamp, "quote": it.quote, "date": day, "session": session, "evidence": it.evidence,
                  "lang": lang}
            sig = (it.skey, it.stamp, one_line(it.quote).casefold())
            if sig in gone:
                res.deleted += 1
                continue
            holder = next((e for e in ents.values() if sig in held and e["kind"] == it.kind
                           and any((x["skey"], x["stamp"], one_line(x["quote"]).casefold()) == sig for x in e.get("evidence", []))),
                          None)
            if holder is not None:
                res.repeats += 1
                res.touched.add(holder["id"])
                continue
            words = content_words(f"{it.topic} {it.text}")
            twords = content_words(it.topic)
            same = None
            clash: list[dict] = []
            for e in self.entries(*LEARNED_KINDS, "seed_fact", statuses=("live", "contested")):
                f = self.fields(e)
                etext = f.get("text", "") if e["kind"] != "seed_fact" else f"{f.get('text', '')} {f.get('value', '')}"
                etopic = f.get("topic") or f.get("text", "")
                differs = _differs(it.text, etext)
                if (e["kind"] == it.kind and not differs
                        and jaccard(words, content_words(f"{etopic} {etext}")) >= REPEAT_OVERLAP):
                    same = same or e
                    continue
                if it.kind in ("answer", "claim", "preference") and e["kind"] in ("answer", "claim", "preference", "seed_fact"):
                    if (it.contradicts and it.contradicts == e["id"]) or (
                            differs and jaccard(twords, content_words(etopic)) >= TOPIC_OVERLAP):
                        clash.append(e)
            if same is not None and not clash:
                same.setdefault("evidence", []).append(ev)
                if it.question and it.question not in same.setdefault("questions", []):
                    same["questions"].append(it.question)
                held.add(sig)
                res.repeats += 1
                res.touched.add(same["id"])
                continue
            eid = _new_id(self.state, "p")
            ents[eid] = {"id": eid, "kind": it.kind, "topic": it.topic, "text": it.text, "date": day,
                         "questions": [it.question] if it.question else [], "evidence": [ev], "status": "live",
                         "origin": f"call:{it.skey} {it.stamp}"}
            held.add(sig)
            res.new.append(eid)
            res.touched.add(eid)
            for other in clash:
                if self._has_pair(other["id"], eid):
                    continue
                cid = _new_id(self.state, "c")
                ents[cid] = {"id": cid, "kind": "contradiction", "topic": self.fields(other).get("topic") or it.topic,
                             "a": other["id"], "b": eid, "state": "open", "date": day}
                res.contradictions.append(cid)
        self._refresh_status()
        return res

    # ---- a session run again: its earlier contribution is replaced, never duplicated
    def contribution(self, session: str) -> set[str]:
        """The entries an earlier run of `session` wrote: learned entries with evidence from it and its better answers."""
        out = set()
        for e in self.state["entries"].values():
            if e["kind"] in BETTER_KINDS and e.get("session") == session:
                out.add(e["id"])
            elif e["kind"] in LEARNED_KINDS and any(ev.get("session") == session for ev in e.get("evidence", [])):
                out.add(e["id"])
        return out

    def retract(self, session: str, before: set[str], touched: set[str], sigs: set[tuple[str, str, str]]) -> list[str]:
        """After a session ran again: what its earlier run wrote (`before`) and this run did not write again (`touched`, and the
        evidence `sigs` (skey, stamp, quote) it holds now) leaves the persona. The owner's edits and rejections stay, and so does
        evidence from other sessions (an entry loses only this session's stale quotes). A contradiction that loses a side goes
        too, and a better answer the retracted one had superseded comes back. Nothing here counts as an owner deletion: the
        same words may be learned again. Returns the retracted ids."""
        ents, gone = self.state["entries"], []
        for eid in sorted(before):
            e = ents.get(eid)
            if e is None or e.get("edited") or e.get("rejected"):
                continue
            if e["kind"] in BETTER_KINDS:
                if eid not in touched:
                    gone.append(eid)
                continue
            evs = [ev for ev in e.get("evidence", []) if ev.get("session") != session
                   or (ev.get("skey", ""), ev.get("stamp", ""), one_line(ev.get("quote", "")).casefold()) in sigs]
            if evs:
                e["evidence"] = evs
            else:
                gone.append(eid)
        gone_set = set(gone)
        for c in [c for c in ents.values() if c["kind"] == "contradiction" and not c.get("edited")
                  and (c["a"] in gone_set or c["b"] in gone_set)]:
            gone.append(c["id"])
        retracted = self.state.setdefault("retracted", {})
        for eid in gone:
            del ents[eid]
            h = self.state["lines"].pop(eid, None)
            if h:
                retracted[eid] = h                     # its line in Persona.md is Verse's, not the owner's: dropped on save
        for e in ents.values():
            sup = e.get("superseded")
            if sup and sup.get("by") in gone_set and not sup.get("mark") and not sup.get("contradiction"):
                del e["superseded"]
        self._refresh_status()
        return gone

    def _stale(self, eid: str, line: str) -> bool:
        """A line of an entry a re-run retracted, as Verse wrote it (an owner edit of it is his and stays)."""
        h = self.state.get("retracted", {}).get(eid)
        return bool(h) and sha(line.rstrip()) == h

    def _has_pair(self, a: str, b: str) -> bool:
        return any(e["kind"] == "contradiction" and {e["a"], e["b"]} == {a, b} for e in self.state["entries"].values())

    def resolve(self, cid: str, keep: str) -> None:
        """Settle an open contradiction from code (the app's Resolve button): `keep` is "1", "2" or one of its two ids."""
        c = self.state["entries"].get(cid)
        if not c or c["kind"] != "contradiction" or c.get("state") != "open":
            raise PersonaError(f"{cid} is not an open contradiction")
        k = c["a"] if keep == "1" else c["b"] if keep == "2" else keep
        if k not in (c["a"], c["b"]):
            raise PersonaError("keep must be 1, 2 or one of the contradiction's two ids")
        self._resolve(c, k)
        self._refresh_status()

    # ---- rendering
    def _evidence_text(self, ev: dict) -> str:
        return f"{ev.get('date', '')} [{ev.get('skey', '')} {ev.get('stamp', '')}] \"{_q(ev.get('quote', ''))}\""

    def _better_origin(self, e: dict) -> str:
        at = f"[{e.get('skey', '')} {e.get('stamp', '')}]"
        if e["kind"] == "improved":
            src = ", ".join(s.get("id", "") for s in e.get("sources", []) if s.get("id"))
            return f"improved after {e.get('date', '')} {at}" + (f" from {src}" if src else "")
        if e["kind"] == "adopted":
            return f"his words {e.get('date', '')} {at}"
        return f"kept card {e.get('card', '')} (GOOD mark) {e.get('date', '')} {at}"

    def render_line(self, e: dict) -> str:
        k = e["kind"]
        if k in BETTER_KINDS:
            ln = f"- [{e['id']}] Q: {_clean(e.get('question'))} | SAY: {_clean(e.get('opener'))}"
            if e.get("points"):
                ln += " | MORE: " + " / ".join(_clean(p) for p in e["points"])
            ln += " | " + self._better_origin(e)
            if e.get("superseded"):
                ln += f" | superseded {e['superseded'].get('on', '')}"
            if e.get("rejected"):
                ln += " | rejected"
            return ln.rstrip()
        if k in LEARNED_KINDS:
            evs = e.get("evidence") or [{}]
            ln = f"- [{e['id']}] {one_line(e['topic'])} | {one_line(e['text'])} | {self._evidence_text(evs[0])}"
            if len(evs) > 1:
                ln += f" | seen {len(evs)} times"
            if e.get("status") == "contested":
                ln += " | unsettled"
            if e.get("superseded"):
                ln += f" | superseded {e['superseded'].get('on', '')}"
            return ln
        if k == "contradiction":
            ents = self.state["entries"]

            def side(i: str) -> str:
                o = ents.get(i)
                if not o:
                    return f"[{i}] (deleted)"
                evs = o.get("evidence")
                if evs:
                    return f"{self._evidence_text(evs[0])} [{i}]"
                f = self.fields(o)
                return f"{o.get('origin', '')} \"{_q(f.get('text', '') + ' ' + f.get('value', ''))}\" [{i}]"

            tail = "open" if e.get("state") == "open" else f"resolved: kept [{e.get('keep')}] on {e.get('resolved_at', '')}"
            return f"- [{e['id']}] {one_line(e['topic'])} | {side(e['a'])} | {side(e['b'])} | {tail}"
        d = e.get("data") or {}
        origin = e.get("origin", "")
        if e.get("superseded"):
            origin += f" | superseded {e['superseded'].get('on', '')}"
        if k == "seed_bank":
            return f"- [{e['id']}] Q: {one_line(d.get('question'))} | SAY: {one_line(d.get('opener'))} | from {origin}"
        if k == "seed_fact":
            return f"- [{e['id']}] FACT: {one_line(d.get('text'))} | {one_line(d.get('value'))} | from {origin}"
        if k == "seed_glossary":
            return f"- [{e['id']}] TERM: {one_line(d.get('term'))} | {one_line(d.get('line'))} | from {origin}"
        return f"- [{e['id']}] SNIPPET: {one_line(d.get('ref'))} | {one_line(d.get('text'))} | from {origin}"

    def render(self) -> str:
        doc = self.doc or Doc()
        ents = self.state["entries"]
        lines_state = self.state["lines"]
        out_sections: dict[str, list[str]] = {}
        for sec in SECTIONS:
            if sec == CORRECTIONS:
                body = _trim_blank(doc.sections.get(CORRECTIONS, [])) if self.doc is not None else [CORRECTIONS_HINT]
                out_sections[sec] = body
                continue
            body = []
            for eid, e in sorted(ents.items()):
                if SECTION_OF_KIND.get(e["kind"]) != sec:
                    continue
                ln = e["edited"] if e.get("edited") else self.render_line(e)
                body.append(ln)
                lines_state[eid] = sha(ln)
            for ln in doc.sections.get(sec, []):                     # the owner's own lines, kept in their order
                m = _ENTRY.match(ln)
                if ln.strip() and (m is None or (m.group(1) not in ents and not self._stale(m.group(1), ln))):
                    body.append(ln.rstrip())
            out_sections[sec] = body
        parts = [doc.preamble if self.doc is not None else PREAMBLE.rstrip("\n"), ""]
        for sec in SECTIONS:
            if sec in OPTIONAL_SECTIONS and not out_sections[sec] and not doc.sections.get(sec):
                continue
            parts.append(f"## {sec}")
            parts += out_sections[sec] or []
            parts.append("")
        for head, raw in doc.extra:
            parts.append(head)
            parts += _trim_blank(raw)
            parts.append("")
        body = "\n".join(parts).rstrip("\n") + "\n"
        day = today()
        if self.doc is None or not doc.front:
            front = front_matter(day, day)
        else:
            old = self.dir / PERSONA_MD
            prev = old.read_text(encoding="utf-8", errors="replace") if old.is_file() else ""
            prev_body = prev[len(doc.front):] if prev.startswith(doc.front) else prev
            front = doc.front if _norm_body(prev_body) == _norm_body(body) else _set_modified(doc.front, day)
        return front + body

    # ---- writing
    def save(self, *, persona: bool = True) -> None:
        """Write Persona.md (through the guard) and the state file, both atomically. Right before rendering, the file is read
        again and the owner's changes since `load()` are folded in (`_refold`); a change that lands while rendering is caught by
        a second look, up to three rounds."""
        if persona:
            self.guard.ensure()
            for _ in range(3):
                self._refold()
                text = self.render()
                if self._read_md() == self._seen:
                    break
            self.guard.write(PERSONA_MD, text)
            self.doc = parse_doc(text)
            self._seen = text
        atomic_write(self.state_path, json.dumps(self.state, ensure_ascii=False, indent=1, sort_keys=True) + "\n")

    def write_log(self, day: str, skey: str, session: str, items: list[Item], dropped: dict[str, int], stamp_now: str) -> None:
        """Append this run to `Log/<date> <skey>.md` (created with a header on its first run)."""
        rel = f"{LOG_DIR}/{day} {skey}.md"
        p = self.dir / rel
        prev = p.read_text(encoding="utf-8") if p.is_file() and self.guard.created(rel) else ""
        if not prev:
            prev = (f"---\ntitle: Verse persona log {day} {skey}\ncreated: {day}\ntype: persona-log\ntags:\n  - verse\n"
                    f"  - persona\n---\n# {day} {skey}\n\nSession key `{skey}`. Verified items only; every quote is the owner's "
                    "own words from that call.\n")
        lines = [f"\n## Run {stamp_now}", ""]
        for it in items:
            lines.append(f"- {it.kind} | {one_line(it.topic)} | {one_line(it.text)} | {it.cite} \"{_q(it.quote)}\""
                         + (" (read from the card)" if it.evidence == "read" else ""))
        if not items:
            lines.append("- (no verified items)")
        dropped_txt = ", ".join(f"{k} {v}" for k, v in dropped.items() if v)
        lines.append("")
        lines.append(f"Dropped by verification: {dropped_txt or 'none'}.")
        self.guard.write(rel, prev.rstrip("\n") + "\n" + "\n".join(lines) + "\n")

    # ---- better answers (review.py decides; this keeps them)
    def add_better(self, kind: str, *, question: str, paraphrases: list[str], topic: str, opener: str, points: list[str],
                   sources: list[dict], lang: str, session: str, skey: str, stamp: str, day: str, card: str = "",
                   reasons: list[str] | None = None) -> str | None:
        """Add (or, for the same session, stamp, card and kind, refresh) a better answer. It supersedes the older better answers
        to the same question whose rank is not higher and that the owner did not edit. None when that answer was rejected."""
        assert kind in BETTER_KINDS, kind
        ents = self.state["entries"]
        key = [session, stamp, card, kind]
        fields = {"question": one_line(question), "paraphrases": [one_line(p) for p in paraphrases if one_line(p)],
                  "topic": one_line(topic), "opener": one_line(opener), "points": [one_line(p) for p in points if one_line(p)],
                  "sources": sources, "lang": lang, "reasons": list(reasons or [])}
        old = next((e for e in ents.values() if e["kind"] in BETTER_KINDS and e.get("key") == key), None)
        if old is not None:
            if old.get("rejected"):
                return None
            if not old.get("edited"):
                old.update(fields)
            return old["id"]
        iid = _new_id(self.state, "i")
        ents[iid] = {"id": iid, "kind": kind, "key": key, "session": session, "skey": skey, "stamp": stamp, "date": day,
                     "card": card, "status": "live", "origin": f"review:{skey} {stamp}", **fields}
        mine = [fields["question"], *fields["paraphrases"]]
        for e in ents.values():
            if (e["id"] == iid or e["kind"] not in BETTER_KINDS or e.get("edited") or e.get("rejected") or e.get("superseded")
                    or RANK[e["kind"]] > RANK[kind]):
                continue
            f = self.fields(e)
            if same_question(mine, [f["question"], *f["paraphrases"]]):
                e["superseded"] = {"by": iid, "on": day}
        self._refresh_status()
        return iid

    def demote(self, origin: str, question: str, day: str, by: str = "", card: str = "") -> str | None:
        """A card the owner marked BAD came from this bank answer: it leaves the bank (kept as history, `superseded`). The
        compiled record names its source in `origin` (`persona:<id>`, or the seed's own origin); a session seeded from the
        general prep has no origin, and its question finds the seed entry. Returns the demoted entry's id."""
        ents = self.state["entries"]
        target = None
        m = re.search(r"persona:([pgi]\d{3,})", origin or "")
        if m:
            target = ents.get(m.group(1))
        if target is None and origin:
            target = next((e for e in ents.values() if e["kind"] == "seed_bank" and e.get("origin") == origin), None)
        if target is None and question:
            q = one_line(question).casefold()
            target = next((e for e in self.entries("seed_bank", "answer", *BETTER_KINDS, statuses=("live", "contested"))
                           if one_line(self.fields(e).get("question") or (e.get("questions") or [""])[0]).casefold() == q), None)
        if target is None or target["id"] == by or target.get("superseded") or target["kind"] == "contradiction":
            return None
        target["superseded"] = {"by": by, "on": day, "mark": card or "bad"}
        self._refresh_status()
        return target["id"]

    def write_note(self, rel: str, text: str, answer_lines: dict[str, str]) -> None:
        """Write a Review note (through the guard) and remember the hash of each better-answer line in it (`_sync_notes`)."""
        self.guard.write(rel, text)
        self.state.setdefault("note_lines", {})[rel] = {iid: sha(ln.rstrip()) for iid, ln in answer_lines.items()}

    def write_style(self, text: str, origin: str) -> None:
        day = today()
        self.guard.write(STYLE_MD, f"---\ntitle: Verse style guide\ncreated: {day}\ntype: persona-style\norigin: {origin}\n"
                                   f"tags:\n  - verse\n  - persona\n---\n{text.strip()}\n")

    def style_text(self) -> str:
        """The style guide as the owner keeps it (frontmatter removed); "" when there is none."""
        p = self.dir / STYLE_MD
        if not (p.is_file() and self.guard.created(STYLE_MD)):
            return ""
        t = p.read_text(encoding="utf-8", errors="replace")
        m = _FRONT.match(t)
        return (t[m.end():] if m else t).strip()

    # ---- seed import
    def import_seed(self, records: dict[str, list[dict]], style: str, origin_name: str) -> dict[str, int]:
        """Add the seed entries (owner-confirmed, origin recorded). Once only: a second import is refused."""
        if self.state.get("seed"):
            raise PersonaError("the seed was already imported")
        counts = {}
        for kind, src in (("seed_bank", "bank"), ("seed_fact", "facts"), ("seed_glossary", "glossary"), ("seed_snippet", "snippets")):
            n = 0
            for rec in sorted(records.get(src, []), key=lambda r: str(r.get("id", ""))):
                eid = _new_id(self.state, "g")
                self.state["entries"][eid] = {"id": eid, "kind": kind, "data": rec, "status": "live",
                                              "origin": f"{origin_name} {src} {rec.get('id', '')}".strip(), "date": today()}
                n += 1
            counts[src] = n
        if style.strip():
            self.write_style(style, f"{origin_name} pack.md")
        counts["style"] = 1 if style.strip() else 0
        self.state["seed"] = {"from": origin_name, "imported_at": today(), "counts": counts}
        self._refresh_status()
        return counts


def _seed_fields(e: dict) -> dict:
    d = e.get("data") or {}
    return {k: one_line(d.get(k)) for k in ("question", "opener", "text", "value", "term", "line", "ref") if d.get(k) is not None}


def _differs(a: str, b: str) -> bool:
    """Two texts state different numbers or different names (both sides must have some)."""
    na, nb = significant_numbers(a), numbers_in(b)
    if na and significant_numbers(b) and not na <= nb:
        return True
    ma, mb = names_in(a), names_in(b)
    return bool(ma and mb and not (ma & mb))


def _norm_body(s: str) -> str:
    return s.strip()
