"""CLI: python -m verse_brain.prep --prep-note PATH --repo PATH [--repo PATH...] --lang en[,it,tr] --out DIR

A note over ~20000 chars (or a bank over 40 questions on a note over 8000 chars) is split at its `---` rules and `#`/`##`
headings into sections of 12-18k chars; the note header goes into every section call, each section gets a share of
--max-questions, the results are merged and one pack.md is built. --budget-usd caps the total of all section calls (no new
section starts when its projected cost would pass it); meta.json "sections" has the usage and cost of every section.
Notes up to 250000 chars are accepted. See prep/sections.py and prep/pipeline.py.

--live runs the bundled sample prep note with the real model (budget < $0.50) and prints a summary.
--from-event EVENT.json builds the prep note from a calendar event (F5); add --fake for an offline run (no network, no key).

Voice profile (V1): answers should sound like the user. The profile lives outside the repo (personal data):
  python -m verse_brain.prep voice --source FILE [--voice-profile PATH] [--fake]
distils FILE (an engineering profile, CV, notes: the user's own words) with Sonnet into ~/Library/Application
Support/Verse/profile/voice.md (at most 650 words). Every later prep run (meeting or --sim) appends it to the pack when the
file exists; --voice-profile PATH points at another file, --no-voice builds the pack without one. To put it into packs
that already exist (old pack kept as <pack>.bak-before-voice-v1):
  python -m verse_brain.prep voice --apply SESSION_DIR [--apply SESSION_DIR...] [--voice-profile PATH]

The me layer (anytime calls, A1): The owner's permanent profile, built from his sources and carried by every session.
  python -m verse_brain.prep me build|refresh|show [--fake] [--budget-usd 0.5]
writes ~/Library/Application Support/Verse/profile/{me.md, me.meta.json, me.sources.json, me.facts.jsonl, me.library.jsonl,
me.library.emb}; stdout is the profile dir, the token count and the cost go to stderr. `refresh` rebuilds only when a source
changed and keeps his edits. See prep/me.py.

Teleprompter script (T3): python -m verse_brain.prep script --topic T --seconds 60 --use recording|talk [--json] [--fake]
writes a script (pages split by a line `---`, optional [cues]) in the voice of the profile; see prep/script.py.

Interview simulation (S1):
  python -m verse_brain.prep --sim --posting-file P [--posting-url U] [--cv FILE] [--note FILE] [--vault PATH|--no-vault]
      [--repo PATH]... --type mixed --difficulty standard --length 30 --lang en [--company C] [--role R] [--fake]
builds sessions/sim-<YYYYMMDD-HHMM>-<company>/ {posting.txt, sim.json, sim_pack.md}. Stdout is the session folder path, one
line; the summary goes to stderr. --fake is deterministic and offline (no key, no network, no vault).

Mock interview from a prepared meeting (spec 2026-10-20, F4b):
  python -m verse_brain.prep --sim --from-session SESSION_DIR [--me ME.md] --type mixed --difficulty standard --length 30
      [--lang en] [--company C] [--role R] --out DIR [--fake]
builds sessions/sim-<YYYYMMDD-HHMM>-<source session>/ {source_pack.md, sim.json, sim_pack.md} from the meeting's pack.md and
bank.jsonl. The questions are decided by code (the opener, then the bank entries in order); one Sonnet call writes the
competencies, evidence, rubric and follow-ups. The language is meta.json languages[0] unless --lang is given. --me adds the
profile as a second evidence source. Stdout and stderr as above.

Interviewer persona (opt-in, both --sim forms): who asks, what they probe, and the answer length the feedback measures against.
  [--interviewer-name N] [--interviewer-role R] [--focus "ownership and AI use, trade-offs, evals"] [--focus ...]
  [--answer-target 30-60] [--persona-file persona.json]
The flags override the JSON file ({"name","role","focus":[...],"answer_target_s":[30,60]}, see prep/sim_persona.py). The persona is
stored in sim.json; the sim interviewer follows it, and the report and the live coach notes add a check per answer (length against
the target, clarity, over-eager phrasing, numbers and names the sources do not support). Without it nothing changes.

Prep from a conversation (P2): python -m verse_brain.prep conversation --thread FILE [--posting-file F] [--posting-url U]
  [--company-url U] [--note F] [--fake]
reads a pasted LinkedIn/email thread, researches the company with the Anthropic web_search tool (at most 8 searches, a URL on
every fact, "unverified" otherwise), writes a prep note and runs the meeting prep. Stdout is the session folder
(conv-<YYYYMMDD-HHMM>-<company>, with thread.md, research.md, prep_note.md); stderr has the summary and the cost. See
prep/conversation.py.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import tempfile
from pathlib import Path

from .event import EventError, FakeEventModel, event_to_prep_note, load_event
from .keychain import KeychainError, read_api_key, redact
from .model import PRICES, PrepError, Usage, spend_usd
from .pipeline import build
from .sim import DIFFICULTIES, INTERVIEW_TYPES, FakeSimModel, build_sim, build_sim_from_session
from .sim_persona import build_persona
from .vault import DEFAULT_VAULT, make_vault
from .voice import (DEFAULT_VOICE_PATH, FakeVoiceModel, distill_async, load_voice, strip_voice, with_voice, write_profile)

SAMPLE = Path(__file__).resolve().parents[2] / "tests" / "fixtures" / "prep" / "prep_note.md"
DEFAULT_OUT = Path("~/Library/Application Support/Verse/sessions")


def _voice_profile_arg(ap: argparse.ArgumentParser) -> None:
    ap.add_argument("--voice-profile", type=Path, default=DEFAULT_VOICE_PATH,
                    help=f"voice profile file (default {DEFAULT_VOICE_PATH})")


def _resolve_voice(a: argparse.Namespace) -> Path | None:
    """The profile path to hand to the pipeline: None with --no-voice or when the default file is not there. An explicit
    --voice-profile that does not exist is an error (a typo must not silently build a pack without a voice)."""
    if a.no_voice:
        return None
    p = a.voice_profile.expanduser()
    if p.is_file():
        return p
    if p != DEFAULT_VOICE_PATH.expanduser():
        raise PrepError(f"voice profile not found: {p}")
    return None


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if args and args[0] == "voice":
        return _voice_main(args[1:])
    if args and args[0] == "me":
        from .me import me_main
        return me_main(args[1:])
    if args and args[0] == "script":
        from .script import script_main
        return script_main(args[1:])
    if args and args[0] == "conversation":
        from .conversation import conversation_main
        return conversation_main(args[1:], DEFAULT_OUT)
    return _main(args)


def _main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="python -m verse_brain.prep", description=__doc__)
    ap.add_argument("--prep-note", type=Path)
    ap.add_argument("--repo", type=Path, action="append", default=[])
    ap.add_argument("--lang", default=None,
                    help="comma-separated: en,it,tr (first = language of canonical questions; default en; with --from-session "
                         "the session's meta.json language)")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help="sessions root; a <session-id> folder is created in it")
    ap.add_argument("--max-questions", type=int, default=80)
    ap.add_argument("--vault", type=Path, default=DEFAULT_VAULT)
    ap.add_argument("--no-vault", action="store_true", help="skip vault retrieval")
    ap.add_argument("--vault-audience", choices=["internal", "public"], default="internal")
    ap.add_argument("--budget-usd", type=float, default=1.0,
                    help="hard cap on the total spend of all section calls: it sizes max_tokens, and no new section starts "
                         "when its projected cost would pass it (a long note needs about $0.5 per 15k chars section)")
    ap.add_argument("--from-event", type=Path, metavar="EVENT.json",
                    help="build the prep note from a calendar event JSON (id, title, start, end, attendees, notes, url, provider)")
    ap.add_argument("--fake", action="store_true",
                    help="with --from-event or --sim: deterministic offline model, no network, no key, no spend")
    ap.add_argument("--sim", action="store_true", help="build an interview-simulation pack (see the module doc)")
    ap.add_argument("--from-session", type=Path, metavar="SESSION_DIR",
                    help="--sim: build the mock interview from this prepared meeting session instead of a job posting")
    ap.add_argument("--me", type=Path, metavar="ME.md", help="--sim --from-session: the profile (me.md), a second evidence source")
    ap.add_argument("--posting-file", type=Path, help="--sim: the job posting text the user confirmed")
    ap.add_argument("--posting-url", help="--sim: where the posting came from (stored in sim.json)")
    ap.add_argument("--cv", type=Path, help="--sim: CV as .pdf, .txt or .md")
    ap.add_argument("--note", type=Path, help="--sim: a short about-me note (.txt/.md)")
    ap.add_argument("--type", dest="interview_type", choices=INTERVIEW_TYPES, default="mixed", help="--sim: interview type")
    ap.add_argument("--difficulty", choices=DIFFICULTIES, default="standard", help="--sim: interviewer difficulty")
    ap.add_argument("--length", type=int, default=30, help="--sim: minutes (15 -> 5 questions, 30 -> 8, 45 -> 11)")
    ap.add_argument("--company", help="--sim: override the company name read from the posting")
    ap.add_argument("--role", help="--sim: override the role title read from the posting")
    ap.add_argument("--interviewer-name", help="--sim: the interviewer's name (persona)")
    ap.add_argument("--interviewer-role", help="--sim: the interviewer's role, for example 'Head of Engineering' (persona)")
    ap.add_argument("--focus", action="append", default=[], metavar="AREAS",
                    help="--sim: what the interviewer probes; repeatable or comma-separated (persona)")
    ap.add_argument("--answer-target", metavar="LO-HI", help="--sim: answer length in seconds the feedback measures against (default 30-60 with a persona)")
    ap.add_argument("--persona-file", type=Path, help="--sim: JSON file with the persona (flags override it)")
    _voice_profile_arg(ap)
    ap.add_argument("--no-voice", action="store_true", help="build the pack without the voice profile")
    ap.add_argument("--live", action="store_true",
                    help="smoke run: sample prep note (unless --prep-note), real model, budget 0.45 USD, 24 questions")
    a = ap.parse_args(argv)

    if a.live:
        a.prep_note = a.prep_note or SAMPLE
        a.budget_usd = min(a.budget_usd, 0.45)
        a.max_questions = min(a.max_questions, 24)
    persona_flags = (a.interviewer_name, a.interviewer_role, a.focus, a.answer_target, a.persona_file)
    if any(persona_flags) and not a.sim:
        ap.error("the persona flags need --sim")
    if a.sim:
        if a.prep_note is not None or a.from_event is not None or a.live:
            ap.error("--sim cannot be combined with --prep-note, --from-event or --live")
        if a.from_session is not None:
            if a.posting_file is not None:
                ap.error("--from-session and --posting-file are mutually exclusive")
            bad = [f for f, v in (("--posting-url", a.posting_url), ("--cv", a.cv), ("--note", a.note), ("--repo", a.repo)) if v]
            if bad:
                ap.error(f"{', '.join(bad)} cannot be combined with --from-session")
        elif a.posting_file is None:
            ap.error("--sim needs --posting-file (or --from-session)")
        elif a.me is not None:
            ap.error("--me needs --from-session")
        return _run_sim(a)
    if a.from_event is not None and a.prep_note is not None:
        ap.error("--from-event and --prep-note are mutually exclusive")
    if a.fake and a.from_event is None:
        ap.error("--fake needs --from-event (or --sim)")
    if a.prep_note is None and a.from_event is None:
        ap.error("--prep-note is required (or use --from-event or --live)")
    langs = [c for c in (a.lang or "en").split(",") if c]
    vault = None if (a.no_vault or a.fake) else make_vault(a.vault, audience=a.vault_audience)
    key = None
    try:
        voice_path = _resolve_voice(a)
    except PrepError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    note_dir: tempfile.TemporaryDirectory | None = None
    try:
        if a.from_event is not None:
            note_dir = tempfile.TemporaryDirectory(prefix="verse-event-")
            a.prep_note = Path(note_dir.name) / "event-prep-note.md"
            a.prep_note.write_text(event_to_prep_note(load_event(a.from_event)), encoding="utf-8")
        if a.fake:
            session = build(a.prep_note, a.repo, langs, a.out, a.max_questions, model=FakeEventModel(), vault=None,
                            budget_usd=a.budget_usd, voice_path=voice_path)
        else:
            key = read_api_key()  # only to scrub error text; the model client reads its own copy
            session = build(a.prep_note, a.repo, langs, a.out, a.max_questions, vault=vault, budget_usd=a.budget_usd,
                            voice_path=voice_path)
    except (KeychainError, PrepError, EventError, OSError) as e:
        print(f"error: {redact(str(e), key)}", file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001
        print(f"error: {type(e).__name__}: {redact(str(e), key)[:300]}", file=sys.stderr)
        return 1
    finally:
        if note_dir is not None:
            note_dir.cleanup()
    meta = json.loads((session / "meta.json").read_text(encoding="utf-8"))
    st = meta["stats"]
    print(f"session: {session}")
    if "voice_sha256" in st:
        print(f"voice profile: {voice_path}")
    print(f"bank entries: {st['bank_entries']} | facts {st['facts']} | glossary {st['glossary_terms']} | snippets {st['snippets']}")
    if st.get("conflicts"):
        print(f"CONFLICTS: {st['conflicts']} figure(s) differ between sources; {st.get('conflict_bank_entries', 0)} bank "
              f"entries use them (see review.md, top section)")
    print(f"dropped unsourced points: {meta['dropped_unsourced_points']} "
          f"(unsupported quote {st.get('points_dropped_unsupported_quote', 0)}, "
          f"unsupported number {st.get('points_dropped_unsupported_number', 0)})")
    print(f"pack tokens: {st['pack_tokens']} / cap {st['pack_cap']} (trimmed {st['pack_trimmed']})")
    u = meta["prep_usage"]
    print(f"usage: in {u['input']} out {u['output']} cache_read {u['cache_read']} cache_write {u['cache_write']}")
    print(f"spend: ${meta['prep_spend_usd']:.4f} of ${meta.get('budget_usd', a.budget_usd):.2f} budget")
    secs = meta.get("sections", [])
    if len(secs) > 1:
        print(f"sections: {st.get('sections_run', 0)} run of {len(secs)}")
        for r in secs:
            print(f"  section {r['index']}: lines L{r['lines'][0]}-L{r['lines'][1]} | {r['chars']} chars | quota {r['quota']} | "
                  f"{r['status']} | bank {r['bank']} facts {r['facts']} terms {r['terms']} | out {r['usage']['output']} | "
                  f"${r['spend_usd']:.4f}")
    for w in meta["warnings"]:
        print(f"warning: {w}")
    return 0


def _run_sim(a: argparse.Namespace) -> int:
    lang = next((c for c in (a.lang or "").split(",") if c.strip()), "").strip()
    from_session = a.from_session is not None
    if not from_session:
        lang = lang or "en"
    vault = None if (a.no_vault or a.fake or from_session) else make_vault(a.vault, audience=a.vault_audience)
    key = None
    try:
        voice_path = _resolve_voice(a)
        persona = build_persona(file=a.persona_file, name=a.interviewer_name, role=a.interviewer_role,
                                focus=",".join(a.focus), answer_target=a.answer_target)
        if a.fake:
            model = FakeSimModel()
        else:
            key = read_api_key()  # only to scrub error text; the model client reads its own copy
            model = None
        if from_session:
            session = build_sim_from_session(
                a.from_session, out=a.out, model=model, me=a.me, interview_type=a.interview_type, difficulty=a.difficulty,
                length_min=a.length, lang=lang or None, company=a.company, role=a.role, voice_path=voice_path,
                persona=persona)
        else:
            session = build_sim(
                a.posting_file, out=a.out, model=model, posting_url=a.posting_url, cv=a.cv, note=a.note, repos=a.repo,
                vault=vault, interview_type=a.interview_type, difficulty=a.difficulty, length_min=a.length, lang=lang,
                company=a.company, role=a.role, voice_path=voice_path, persona=persona)
    except (KeychainError, PrepError, OSError) as e:
        print(f"error: {redact(str(e), key)}", file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001
        print(f"error: {type(e).__name__}: {redact(str(e), key)[:300]}", file=sys.stderr)
        return 1
    sim = json.loads((session / "sim.json").read_text(encoding="utf-8"))
    u = sim["prep_usage"]
    spend = ""
    if sim.get("voice_sha256"):
        print(f"voice profile: {voice_path}", file=sys.stderr)
    if sim["prep_model"] in PRICES:
        spend = f" | spend: ${spend_usd(sim['prep_model'], Usage(**u)):.4f}"
    err = lambda s: print(s, file=sys.stderr)  # noqa: E731
    err(f"{sim['company']} | {sim['role']} | {sim['interview_type']}/{sim['difficulty']} | {sim['length_min']} min")
    err(f"competencies {len(sim['competencies'])} | evidence {len(sim['evidence'])} | questions {len(sim['questions'])}")
    err(f"usage: in {u['input']} out {u['output']} cache_read {u['cache_read']} cache_write {u['cache_write']}{spend}")
    for w in sim["warnings"]:
        err(f"warning: {w}")
    print(session)
    return 0


def _voice_main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="python -m verse_brain.prep voice", description=(
        "Distil a voice profile from a source document, and/or put the profile into existing packs."))
    ap.add_argument("--source", type=Path, help="the document to distil (the user's own words: profile, CV, notes)")
    _voice_profile_arg(ap)
    ap.add_argument("--apply", type=Path, action="append", default=[], metavar="SESSION_DIR",
                    help="rewrite the voice section of this session's pack.md / sim_pack.md (repeatable)")
    ap.add_argument("--fake", action="store_true", help="offline: a fixed fictional profile, no network, no key, no spend")
    ap.add_argument("--budget-usd", type=float, default=1.0, help="hard cap used to size max_tokens")
    a = ap.parse_args(argv)
    if a.source is None and not a.apply:
        ap.error("give --source FILE to distil a profile, --apply SESSION_DIR to use one, or both")
    target = a.voice_profile.expanduser()
    key = None
    try:
        if a.source is not None:
            src = a.source.expanduser()
            if not src.is_file():
                raise PrepError(f"source not found: {src}")
            try:
                source_text = src.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as e:
                raise PrepError(f"cannot read the source {src}: {e}") from e
            if a.fake:
                model = FakeVoiceModel()
            else:
                from .model import PREP_MODEL, AnthropicPrepModel
                key = read_api_key()  # only to scrub error text; the model client reads its own copy
                model = AnthropicPrepModel(key, PREP_MODEL, progress=True)
            async def run():
                try:
                    return await distill_async(source_text, model, budget_usd=a.budget_usd)
                finally:
                    close = getattr(model, "aclose", None)
                    if close is not None:
                        await close()
            text, usage, kept = asyncio.run(run())
            write_profile(target, text, source=src, usage=usage, model=model.model, samples=kept)
            spend = f" | spend: ${spend_usd(model.model, usage):.4f}" if model.model in PRICES else ""
            print(f"voice profile: {target} ({len(text.split())} words, {kept} sample answers)")
            print(f"usage: in {usage.input} out {usage.output}{spend}")
        for d in a.apply:
            print(_apply_voice(Path(d).expanduser(), target))
    except (KeychainError, PrepError, OSError) as e:
        print(f"error: {redact(str(e), key)}", file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001
        print(f"error: {type(e).__name__}: {redact(str(e), key)[:300]}", file=sys.stderr)
        return 1
    return 0


def _apply_voice(session: Path, profile: Path) -> str:
    """Replace the trailing voice section of the session's pack(s) with the profile's. The old file is kept as
    <name>.bak-before-voice-v1 (numbered when taken); nothing is deleted."""
    voice = load_voice(profile)
    if voice is None:
        raise PrepError(f"no voice profile at {profile}: run `voice --source FILE` first")
    done: list[str] = []
    for name, kind in (("pack.md", "meeting"), ("sim_pack.md", "sim")):
        f = session / name
        if not f.is_file():
            continue
        old = f.read_text(encoding="utf-8")
        new = with_voice(strip_voice(old), voice, kind)
        if new == old:
            done.append(f"{f}: already up to date")
            continue
        k, bak = 1, f.with_name(name + ".bak-before-voice-v1")
        while bak.exists():
            k += 1
            bak = f.with_name(f"{name}.bak-before-voice-v1-{k}")
        bak.write_text(old, encoding="utf-8")
        f.write_text(new, encoding="utf-8")
        done.append(f"{f}: voice section written ({len(voice.split())} words); previous kept as {bak.name}")
    if not done:
        raise PrepError(f"{session} has no pack.md or sim_pack.md")
    return "\n".join(done)


if __name__ == "__main__":
    raise SystemExit(main())
