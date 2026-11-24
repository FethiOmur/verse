"""Compile the persona into the files an unprepared call loads, and the one-time import of the hand-built general prep.

ONE mechanism (owner decision 4, 24 Nov 2026). The persona is the single source of truth; the general prep folder
(`sessions/general-core`) is read once by `read_general_core` and never written. Its records become seed entries of the persona
(`import_seed` in store.py), owner-confirmed and marked with their origin, and its STYLE GUIDE section becomes `Style guide.md`
in the persona folder. From then on `compile_persona` writes a session-shaped folder with exactly the files Swift's
`GeneralPrep.seed` copies into an adhoc session and the runtime already reads:

  pack.md          prep/pack.py `render_pack` (FACTS, GLOSSARY, ANSWER BANK, SNIPPETS), trimmed by `fit_pack` to its cap, plus
                   one "unsettled" line per open contradiction at the end of FACTS, then the style guide (never trimmed)
  bank.jsonl       the better answers of the after-call review first (review.py; one per question: the owner's edit, then a
                   card he marked GOOD, then his own strong wording, then an improved answer, newer first inside a rank; each
                   names its origin and date in `origin` and `improved_at`), then the seed's answers (owner edits applied) and the
                   learned answers, renumbered b001.. in that order. An older entry for a question a better answer holds
                   (store.py `same_question` over the question and its paraphrases) is left out, and its wordings join the
                   better answer's paraphrases, so the matcher still finds it however the question is asked
  facts.jsonl      the seed's facts and every learned claim with a number, renumbered f001..
  glossary.jsonl   the seed's glossary
  snippets.jsonl   the seed's snippets (bank ids remapped), the SAID BEFORE claims as verbatim quotes with their cite (ref
                   "SAID BEFORE call:<skey> <m:ss> (<date>)", the only ref the live prompt lets a card cite an earlier call by:
                   runtime/prompt.py SAID_BEFORE_REF), and the owner's MY CORRECTIONS lines. A claim the owner edited goes out as
                   "owner correction", never with the cite of words he did not say; an edited answer's or fact's sources say
                   the same
  meta.json        {kind: "persona-core", compiled_at, counts, persona state fingerprint}
  .verse-compiled  marker: only a folder that carries it (or a new or empty one) is ever written

Left out: contested entries (an open contradiction: neither value reaches a call), superseded and deleted ones, and, while a
contradiction is open, every other record (an imported answer, fact, glossary line or snippet, or a learned one) that states one
of its disputed values on its topic (`Disputes`; counted as meta.json `held_back`). The default output
folder is `<sessions root>/persona-core`, next to general-core; the app seeds unprepared calls from it when it exists and from
general-core while it does not.
"""

from __future__ import annotations

import json
import math
import re
from datetime import datetime, timezone
from pathlib import Path

from ..prep.pack import TOKEN_CAP, fit_pack
from ..prep.sources import numbers_in, significant_numbers
from ..prep.voice import MEETING_HEADER, VOICE_HEADING, strip_voice
from ..runtime.me import content_words
from ..runtime.prompt import SAID_BEFORE_REF
from .extract import _words, names_in
from .store import (BETTER_KINDS, RANK, PersonaError, PersonaGuardError, PersonaStore, atomic_write, one_line, same_question,
                    sha)

COMPILED_MARKER = ".verse-compiled"
COMPILED_NAME = "persona-core"
GENERAL_NAME = "general-core"
FILES = ("pack.md", "bank.jsonl", "facts.jsonl", "glossary.jsonl", "snippets.jsonl", "meta.json")
_NUM_TOKEN = re.compile(r"\d[\d.,]*\d[kKmM%]?|\d[kKmM%]?")


def _count_chars(text: str) -> int:
    return math.ceil(len(text) / 3)          # conservative, never calls the API


async def _count(text: str) -> int:
    return _count_chars(text)


# ---------------------------------------------------------------- general-core (read only)
def _jsonl(p: Path) -> list[dict]:
    if not p.is_file():
        return []
    out = []
    for ln in p.read_text(encoding="utf-8", errors="replace").splitlines():
        ln = ln.strip()
        if not ln:
            continue
        try:
            o = json.loads(ln)
        except ValueError:
            continue
        if isinstance(o, dict) and isinstance(o.get("id"), str):
            out.append(o)
    return out


def style_section(pack: str) -> str:
    """The trailing style guide of a pack (from its STYLE GUIDE heading to the end), or ""."""
    stripped = strip_voice(pack)
    if stripped == pack:
        return ""
    return pack[len(stripped.rstrip("\n")):].strip("\n")


def read_general_core(folder: Path) -> tuple[dict[str, list[dict]], str]:
    """(records by file, style guide section) of the general prep folder. Reads only; never writes there."""
    folder = Path(folder).expanduser()
    if not (folder / "pack.md").is_file():
        raise PersonaError("the general prep folder has no pack.md")
    recs = {k: _jsonl(folder / f"{k}.jsonl") for k in ("bank", "facts", "glossary", "snippets")}
    style = style_section((folder / "pack.md").read_text(encoding="utf-8", errors="replace"))
    return recs, style


def import_general_core(store: PersonaStore, folder: Path) -> dict[str, int]:
    """The one-time import: general-core's records become owner-confirmed seed entries. Call inside `store.locked()` after
    `store.load()`; saves the persona."""
    recs, style = read_general_core(folder)
    counts = store.import_seed(recs, style, Path(folder).name)
    store.save()
    return counts


# ---------------------------------------------------------------- compile
def _ref(ev: dict) -> str:
    return f"call:{ev.get('skey', '')} {ev.get('stamp', '')} ({ev.get('date', '')})"


OWNER_CORRECTION = "owner correction"


def _sources(e: dict, text: str = "") -> list[dict]:
    """Where a learned entry's words come from: its verbatim quotes with their call cites, or, once the owner edited the line,
    his correction (the edited words were never said at that stamp, so they never carry its cite)."""
    if e.get("edited"):
        return [{"kind": "owner", "ref": OWNER_CORRECTION, "quote": one_line(text)}]
    return [{"kind": "persona", "ref": _ref(ev), "quote": one_line(ev.get("quote", ""))} for ev in e.get("evidence", [])[:3]]


class Disputes:
    """The values in dispute while contradictions are open. A side's numbers and names that the other side does not share are
    disputed; a compiled record that states one of them and shares a topic word with the contradiction is held back, so the
    imported answers, facts and snippets on that topic do not carry the old value next to the "unsettled" line."""

    def __init__(self, store: PersonaStore) -> None:
        self.items: list[tuple[set[float], set[str], set[str]]] = []
        ents = store.state["entries"]
        for c in store.entries("contradiction"):
            if c.get("state") != "open":
                continue
            texts, topics = [], content_words(str(c.get("topic", "")))
            for i in (c.get("a"), c.get("b")):
                o = ents.get(i)
                if not o:
                    continue
                f = store.fields(o)
                texts.append(" ".join(x for x in (f.get("text", ""), f.get("value", "")) if x))
                topics |= content_words(f.get("topic") or f.get("text", ""))
            if len(texts) != 2:
                continue
            nums = [significant_numbers(t) for t in texts]
            names = [names_in(t) for t in texts]
            self.items.append((nums[0] ^ nums[1], names[0] ^ names[1], topics))

    def holds(self, text: str) -> bool:
        if not self.items:
            return False
        nums, words, cw = numbers_in(text), _words(text), content_words(text)
        return any((any(abs(n - d) < 1e-9 for n in nums for d in dn) or (words & dw)) and (cw & topics)
                   for dn, dw, topics in self.items)


def _record_text(rec: dict) -> str:
    parts: list[str] = []
    for k in ("question", "opener", "deep", "text", "value", "term", "line"):
        if isinstance(rec.get(k), str):
            parts.append(rec[k])
    parts += [str(p) for p in rec.get("points") or [] if isinstance(p, str)]
    for v in (rec.get("paraphrases") or {}).values():
        parts += [str(p) for p in v or [] if isinstance(p, str)]
    return " ".join(parts)


def _phrases(rec: dict) -> list[str]:
    out = [str(rec.get("question", ""))]
    for v in (rec.get("paraphrases") or {}).values():
        out += [str(p) for p in v or [] if isinstance(p, str)]
    return [p for p in out if p.strip()]


BETTER_ORIGIN = {"improved": "improved after", "adopted": "his words", "kept": "kept card (GOOD mark)",
                 "edited": "owner correction"}


def better_records(store: PersonaStore, disputes: "Disputes") -> tuple[list[dict], int]:
    """One bank record per question from the better answers, best first (see the module doc); (records, held back)."""
    cands = []
    for e in store.live(*BETTER_KINDS):
        rank = "edited" if e.get("edited") else e["kind"]
        cands.append((RANK[rank], str(e.get("date", "")), e["id"], rank, e))
    cands.sort(key=lambda c: (c[0], c[1], c[2]), reverse=True)
    out: list[dict] = []
    held = 0
    for _, day, iid, rank, e in cands:
        f = store.fields(e)
        lang = e.get("lang") or "en"
        rec = {"id": "", "lang": lang, "question": f["question"], "paraphrases": {lang: [p for p in f["paraphrases"] if p]},
               "opener": f["opener"], "points": f["points"] or [f["opener"]], "deep": f["text"],
               "origin": f"{BETTER_ORIGIN[rank]} {day} (persona:{iid})", "improved_at": day, "rank": rank}
        if rank == "edited":
            rec["sources"] = [{"kind": "owner", "ref": OWNER_CORRECTION, "quote": one_line(f["text"])}]
        elif rank == "improved":
            rec["sources"] = [{"kind": "confirmed", "ref": s.get("id", ""), "quote": one_line(s.get("text", ""))[:200]}
                              for s in e.get("sources", [])]
        elif rank == "adopted":
            rec["sources"] = [{"kind": "persona", "ref": f"call:{e.get('skey', '')} {e.get('stamp', '')} ({day})",
                               "quote": one_line(f["text"])}]
        else:
            rec["sources"] = [{"kind": "card", "ref": f"card {e.get('card', '')} marked GOOD ({day})", "quote": one_line(f["text"])}]
        if any(same_question(_phrases(rec), _phrases(w)) for w in out):
            continue                                  # a better-ranked answer already holds this question
        if disputes.holds(_record_text(rec)):
            held += 1
            continue
        out.append(rec)
    return out, held


def _absorb(winner: dict, loser: dict) -> None:
    """The outranked entry's wordings become the better answer's paraphrases (deduplicated, by language)."""
    para = winner.setdefault("paraphrases", {})
    have = {p.casefold() for p in _phrases(winner)}
    lang = loser.get("lang") or winner.get("lang") or "en"
    for p in [str(loser.get("question", ""))] + [x for x in (loser.get("paraphrases") or {}).get(lang, []) if isinstance(x, str)]:
        if p.strip() and p.casefold() not in have:
            para.setdefault(lang, []).append(p)
            have.add(p.casefold())
    for k, v in (loser.get("paraphrases") or {}).items():
        if k == lang:
            continue
        for p in v or []:
            if isinstance(p, str) and p.strip() and p.casefold() not in have:
                para.setdefault(k, []).append(p)
                have.add(p.casefold())


def build(store: PersonaStore) -> dict:
    """The compiled records (pure: reads the loaded store, writes nothing). A record that states a value in dispute
    (`Disputes`) is left out while the contradiction is open; `held_back` counts them."""
    disputes = Disputes(store)
    winners, held = better_records(store, disputes)
    cands: list[tuple[str, dict]] = []               # (the seed's own bank id or "", record)
    for e in store.live("seed_bank"):
        d = dict(e.get("data") or {})
        f = store.fields(e)
        d["question"], d["opener"] = f.get("question", d.get("question", "")), f.get("opener", d.get("opener", ""))
        if disputes.holds(_record_text(d)):
            held += 1
            continue
        old = str(d.get("id", ""))
        d["origin"] = e.get("origin", "")
        d.setdefault("lang", "en")
        d.setdefault("points", [])
        cands.append((old, d))
    for e in store.live("answer"):
        f = store.fields(e)
        evs = e.get("evidence") or [{}]
        lang = evs[0].get("lang") or "en"
        question = (e.get("questions") or [f["topic"]])[0]
        paras = [q for q in [*(e.get("questions") or [])[1:], f["topic"]] if q and q != question]
        rec = {"id": "", "lang": lang, "question": question, "paraphrases": {lang: paras},
               "opener": f["text"], "points": [f["text"]], "deep": f["text"], "sources": _sources(e, f["text"]),
               "origin": f"persona:{e['id']}"}
        if disputes.holds(_record_text(rec)):
            held += 1
            continue
        cands.append(("", rec))
    bank: list[dict] = list(winners)
    owner_of: dict[int, int] = {}                     # candidate index -> the winner that took its question
    outranked = 0
    for ci, (_, rec) in enumerate(cands):
        wi = next((i for i, w in enumerate(winners) if same_question(_phrases(rec), _phrases(w))), None)
        if wi is not None:
            _absorb(winners[wi], rec)
            owner_of[ci] = wi
            outranked += 1
        else:
            bank.append(rec)
    for i, rec in enumerate(bank, start=1):
        rec["id"] = f"b{i:03d}"
    remap: dict[str, str] = {}
    for ci, (old, rec) in enumerate(cands):
        if old:
            remap[old] = winners[owner_of[ci]]["id"] if ci in owner_of else rec["id"]
    facts: list[dict] = []
    for e in store.live("seed_fact"):
        d = dict(e.get("data") or {})
        f = store.fields(e)
        d["text"], d["value"] = f.get("text", d.get("text", "")), f.get("value", d.get("value", ""))
        if disputes.holds(_record_text(d)):
            held += 1
            continue
        d["id"] = f"f{len(facts) + 1:03d}"
        d["origin"] = e.get("origin", "")
        facts.append(d)
    for e in store.live("claim"):
        f = store.fields(e)
        if not significant_numbers(f["text"]):
            continue
        value = ", ".join(dict.fromkeys(m.group() for m in _NUM_TOKEN.finditer(f["text"])))
        text = f"{f['topic']}: {f['text']}"
        if disputes.holds(text):
            held += 1
            continue
        facts.append({"id": f"f{len(facts) + 1:03d}", "kind": "number", "text": text, "value": value,
                      "sources": _sources(e, text), "origin": f"persona:{e['id']}"})
    glossary: list[dict] = []
    for e in store.live("seed_glossary"):
        d = dict(e.get("data") or {})
        f = store.fields(e)
        d["term"], d["line"] = f.get("term", d.get("term", "")), f.get("line", d.get("line", ""))
        if disputes.holds(_record_text(d)):
            held += 1
            continue
        d["id"] = f"g{len(glossary) + 1:03d}"
        glossary.append(d)
    snippets: list[dict] = []
    for e in store.live("seed_snippet"):
        d = dict(e.get("data") or {})
        f = store.fields(e)
        d["ref"], d["text"] = f.get("ref", d.get("ref", "")), f.get("text", d.get("text", ""))
        if disputes.holds(_record_text(d)):
            held += 1
            continue
        d["bank_ids"] = [remap[b] for b in d.get("bank_ids", []) if b in remap]
        d["id"] = f"s{len(snippets) + 1:03d}"
        snippets.append(d)
    for e in store.live("claim"):
        f = store.fields(e)
        evs = e.get("evidence") or []
        if evs and not e.get("edited"):          # his words, verbatim, with the call and stamp they were said at
            ref, text = SAID_BEFORE_REF + _ref(evs[0]).removeprefix("call:"), f"\"{one_line(evs[0]['quote'])}\" ({f['topic']})"
        else:                                    # an edited claim is his correction: never cited as said in a call
            ref, text = OWNER_CORRECTION, f"{f['topic']}: {f['text']}"
        if disputes.holds(text):
            held += 1
            continue
        snippets.append({"id": f"s{len(snippets) + 1:03d}", "ref": ref, "text": text, "bank_ids": []})
    for c in store.corrections:
        snippets.append({"id": f"s{len(snippets) + 1:03d}", "ref": "owner correction", "text": one_line(c), "bank_ids": []})
    unsettled = [one_line(c["topic"]) for c in store.entries("contradiction") if c.get("state") == "open"]
    style_lines = [store.fields(e)["text"] for e in store.live("style", "preference")]
    return {"bank": bank, "facts": facts, "glossary": glossary, "snippets": snippets, "unsettled": unsettled,
            "style": store.style_text(), "style_lines": style_lines, "held_back": held, "better": len(winners),
            "outranked": outranked}


def voice_block(style: str, learned: list[str]) -> str:
    """The pack's style guide: the imported one as the owner keeps it, then the style and preference entries learned from calls."""
    style = style.strip()
    if learned:
        extra = "Learned from my calls:\n" + "\n".join(f"- {one_line(x)}" for x in learned)
        style = (style + "\n\n" + extra) if style else f"{MEETING_HEADER}\n{extra}"
    if style and not style.startswith(VOICE_HEADING):
        style = f"{MEETING_HEADER}\n{style}"
    return style


def insert_unsettled(pack: str, topics: list[str]) -> str:
    """One line per open contradiction at the end of the FACTS section: the topic and no value."""
    if not topics:
        return pack
    lines = [f"[u{i:03d}] unsettled | {t} | do not state a figure or a name for this" for i, t in enumerate(topics, start=1)]
    marker = "\n\n## GLOSSARY"
    k = pack.find(marker)
    if k < 0:
        return pack.rstrip("\n") + "\n" + "\n".join(lines) + "\n"
    return pack[:k] + "\n" + "\n".join(lines) + pack[k:]


async def compile_async(store: PersonaStore, out: Path, now: datetime | None = None) -> dict:
    """Compile the loaded persona into `out`. Refused when the persona is empty or `out` is a folder Verse did not compile."""
    out = Path(out).expanduser()
    check_out(out)
    rec = build(store)
    if not (rec["bank"] or rec["facts"] or rec["snippets"]):
        raise PersonaError("the persona is empty: nothing to compile (unprepared calls keep using the general prep)")
    voice = voice_block(rec["style"], rec["style_lines"])
    reserve = (_count_chars(voice) + 2 if voice else 0) + sum(_count_chars(t) + 12 for t in rec["unsettled"])
    pack, tokens, trimmed = await fit_pack(rec["facts"], rec["glossary"], rec["bank"], rec["snippets"], _count,
                                           max(1000, TOKEN_CAP - reserve))
    pack = insert_unsettled(pack, rec["unsettled"])
    if voice:
        pack = pack.rstrip("\n") + "\n\n" + voice + "\n"
    now = now or datetime.now(timezone.utc)
    jl = lambda rows: "".join(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n" for r in rows)  # noqa: E731
    counts = {k: len(rec[k]) for k in ("bank", "facts", "glossary", "snippets", "unsettled")}
    meta = {"kind": "persona-core", "mode": "unprepared", "source": "persona", "compiled_at": now.isoformat(timespec="seconds"),
            "persona_fp": sha(json.dumps(store.state.get("entries", {}), sort_keys=True, ensure_ascii=False)),
            "counts": counts, "held_back": rec["held_back"], "pack_tokens_est": _count_chars(pack), "pack_trimmed": trimmed,
            "better": rec["better"], "outranked": rec["outranked"]}
    out.mkdir(parents=True, exist_ok=True)
    marker = out / COMPILED_MARKER
    if not marker.exists():
        atomic_write(marker, json.dumps({"verse": "persona-core", "version": 1}) + "\n")
    for name, text in (("pack.md", pack), ("bank.jsonl", jl(rec["bank"])), ("facts.jsonl", jl(rec["facts"])),
                       ("glossary.jsonl", jl(rec["glossary"])), ("snippets.jsonl", jl(rec["snippets"])),
                       ("meta.json", json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True) + "\n")):
        atomic_write(out / name, text)
    return {"out": str(out), **counts, "pack_tokens_est": meta["pack_tokens_est"]}


def check_out(out: Path) -> None:
    if out.name == GENERAL_NAME:
        raise PersonaGuardError("the general prep folder is never written")
    if out.is_symlink():
        raise PersonaGuardError("the compile folder is a symbolic link")
    if out.exists():
        if not out.is_dir():
            raise PersonaGuardError("the compile target is not a folder")
        if not (out / COMPILED_MARKER).is_file() and any(out.iterdir()):
            raise PersonaGuardError("the compile folder is not empty and was not written by Verse")
