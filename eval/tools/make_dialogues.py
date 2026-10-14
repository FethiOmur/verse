"""Writes eval/dialogues/d01..d12.json from the scripts below, measuring the nominal timeline with `say`.

Run once (audio goes to a temp dir and is deleted): python tools/make_dialogues.py
The questions come from the sample session's bank (exact), bench/embed/blind_set.json (blind paraphrases) and a few
off-bank questions on the same topics. Participants: Ingrid (interviewer 1), Tomas (interviewer 2); Alex never speaks
on the remote channel (his answers are silence).
"""

from __future__ import annotations

import json
import os
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import audio  # noqa: E402
import labels  # noqa: E402

REPO = HERE.parent.parent
SESSION = Path(os.path.expanduser("~/Library/Application Support/Verse/sessions/sample-interview"))
BLIND = json.loads((REPO / "bench/embed/blind_set.json").read_text())["paraphrases"]
BANK = {}
for ln in (SESSION / "bank.jsonl").read_text().splitlines():
    if ln.strip():
        r = json.loads(ln)
        BANK[r["id"]] = r["question"]

OWNER = "Alex"
I, T = "Ingrid", "Tomas"

# Entries: ("exact", bank_id) | ("para", bank_id, index) | ("off", text) | ("st", speaker, text) | ("frag", speaker, text)
#          ("oth", speaker, text) a question to the other interviewer | ("rep", speaker, text) that person's short reply
# A plain tuple's speaker comes first when it is not the dialogue's default interviewer: ("exact", "b001", T).
SCRIPTS = {
    "d01": dict(voices={I: "Samantha"}, entries=[
        ("st", I, "Hi Alex, thanks for making the time today."),
        ("exact", "b001"), ("para", "b002", 0),
        ("st", I, "Okay, that's helpful."),
        ("off", "What was the hardest part of building Lantern?"),
        ("exact", "b015"), ("frag", I, "Right, okay."),
        ("para", "b004", 1)]),
    "d02": dict(voices={I: "Karen"}, entries=[
        ("exact", "b003"), ("para", "b011", 1),
        ("st", I, "We have a company offsite planned in Lisbon next spring."),
        ("off", "Which programming languages do you use day to day?"),
        ("exact", "b005"), ("para", "b012", 0), ("frag", I, "And then the")]),
    "d03": dict(voices={I: "Kathy"}, entries=[
        ("st", I, "Thanks for joining us today, Alex."),
        ("para", "b001", 0), ("exact", "b008"),
        ("off", "How big is the team you currently work in?"),
        ("para", "b009", 0), ("exact", "b014")]),
    "d04": dict(voices={I: "Moira"}, entries=[
        ("exact", "b010"), ("para", "b013", 0),
        ("off", "How would you measure success for the dispatcher pilot?"),
        ("st", I, "Our AI team has six people at the moment."),
        ("para", "b016", 1), ("off", "Why are you leaving your current company?")]),
    "d05": dict(voices={I: "Tessa"}, entries=[
        ("para", "b017", 0), ("exact", "b007"),
        ("off", "How did you decide when to retry a failed extraction?"),
        ("para", "b019", 1), ("st", I, "Good, thank you."),
        ("exact", "b022"), ("para", "b020", 0)]),
    "d06": dict(voices={I: "Tara"}, entries=[
        ("exact", "b006"), ("para", "b005", 0),
        ("off", "Do you speak any other languages besides English?"),
        ("exact", "b018"), ("frag", I, "Um, so, and the"),
        ("para", "b015", 0), ("off", "What did the courier pilot teach you about live traffic?")]),
    "d07": dict(voices={I: "Samantha", T: "Mara"}, entries=[
        ("st", I, "Welcome Alex. Tomas and I will take turns with the questions today."),
        ("exact", "b001"), ("para", "b003", 0, T),
        ("oth", I, "Tomas, can you share the roadmap slide with everyone?"), ("rep", T, "Sure, sharing it now."),
        ("off", "Alex, how did you handle invoices in different languages?", T),
        ("oth", T, "Ingrid, do you want to cover the team structure now?"), ("rep", I, "Yes, in a moment."),
        ("exact", "b016", I)]),
    "d08": dict(voices={I: "Karen", T: "Rishi"}, entries=[
        ("exact", "b009", T),
        ("oth", T, "Ingrid, did you want to ask about the dispatcher?"), ("rep", I, "Yes, thanks Tomas."),
        ("para", "b013", 1, I),
        ("off", "How would you test the dispatcher before it touches live routes?", T),
        ("oth", I, "Tomas, could you mute your microphone while I talk?"), ("frag", T, "Sorry, done."),
        ("para", "b008", 0, I)]),
    "d09": dict(voices={I: "Kathy", T: "Mara"}, entries=[
        ("st", I, "Tomas, please go ahead with your first question."),
        ("exact", "b019", T), ("para", "b010", 0, T),
        ("oth", T, "Ingrid, anything you want to add here?"), ("rep", I, "Not right now."),
        ("off", "What would you change about Compass if you joined?", I),
        ("oth", I, "Tomas, can you pull up the evaluation notes?"), ("rep", T, "One second, I have them."),
        ("exact", "b012", T)]),
    "d10": dict(voices={I: "Moira", T: "Rishi"}, entries=[
        ("exact", "b002", I),
        ("oth", T, "Ingrid, should I take the technical round now?"), ("frag", I, "Yes, please."),
        ("off", "What is the difference between a process and a thread?", T),
        ("para", "b006", 0, T),
        ("oth", I, "Tomas, would you stop sharing your screen?"),
        ("para", "b007", 1, I),
        ("st", I, "We are running about ten minutes behind schedule.")]),
    "d11": dict(voices={I: "Tessa", T: "Mara"}, entries=[
        ("para", "b018", 0, T),
        ("st", I, "Alex, take your time with this one."),
        ("off", "Where do you see yourself in five years?", I),
        ("oth", I, "Tomas, are you still on the line?"), ("rep", T, "Yes, I'm here."),
        ("exact", "b004", T), ("para", "b020", 1, T),
        ("oth", I, "Tomas, did you want to follow up on that?"),
        ("exact", "b014", I)]),
    "d12": dict(voices={I: "Tara", T: "Rishi"}, entries=[
        ("para", "b005", 1, I), ("exact", "b011", T),
        ("off", "Have you used Terraform or any infrastructure as code tools?", T),
        ("oth", I, "Tomas, can you share the interview notes with me?"), ("rep", T, "Sending them now."),
        ("para", "b015", 2, I), ("para", "b012", 1, T),
        ("oth", T, "Ingrid, shall we move on to the next topic?"),
        ("exact", "b013", I)]),
    # Short questions (2-3 words): a speculative call needs 4 new words, so none can fire before the turn ends and the
    # fresh F call has to carry them. Scored separately (suite "short"); it exists to measure the "no hit, fresh Haiku" path.
    "d13": dict(suite="short", voices={I: "Samantha"}, entries=[
        ("short", "b002", "Why this company?"), ("short", "b005", "What's your weakness?"),
        ("short", "b003", "Describe Lantern."), ("short", "b015", "Notice period?"), ("short", "b002", "Why Halden?"),
        ("off", "Tell us more.")]),
}


def expand(did: str, spec: dict) -> list[dict]:
    default_speaker = I
    out: list[dict] = []
    for e in spec["entries"]:
        kind = e[0]
        if kind == "exact":
            spk = e[2] if len(e) > 2 else default_speaker
            out.append(dict(speaker=spk, text=BANK[e[1]], category="exact", is_question=True, addressee="me", bank_id=e[1]))
        elif kind == "para":
            spk = e[3] if len(e) > 3 else default_speaker
            out.append(dict(speaker=spk, text=BLIND[e[1]][e[2]], category="paraphrase", is_question=True, addressee="me", bank_id=e[1]))
        elif kind == "short":
            out.append(dict(speaker=default_speaker, text=e[2], category="paraphrase", is_question=True, addressee="me", bank_id=e[1]))
        elif kind == "off":
            spk = e[2] if len(e) > 2 else default_speaker
            out.append(dict(speaker=spk, text=e[1], category="offbank", is_question=True, addressee="me", bank_id=None))
        elif kind == "st":
            out.append(dict(speaker=e[1], text=e[2], category="statement", is_question=False, addressee=None, bank_id=None))
        elif kind == "frag":
            out.append(dict(speaker=e[1], text=e[2], category="fragment", is_question=False, addressee=None, bank_id=None))
        elif kind == "oth":
            out.append(dict(speaker=e[1], text=e[2], category="other", is_question=True, addressee="other", bank_id=None))
        elif kind == "rep":
            out.append(dict(speaker=e[1], text=e[2], category="reply", is_question=False, addressee=None, bank_id=None))
        else:
            raise ValueError(kind)
    return out


def with_answers(utts: list[dict], rnd: random.Random) -> list[dict]:
    """Inserts the owner's silent answer after every question addressed to him, and sets the gaps."""
    seq: list[dict] = []
    for u in utts:
        seq.append(dict(u))
        if u["is_question"] and u["addressee"] == "me":
            seq.append(dict(speaker=OWNER, text="(answers; silence on the remote channel)", category="answer", is_question=False,
                            addressee=None, bank_id=None, silent_s=round(rnd.uniform(5.0, 8.5), 1)))
    for i, u in enumerate(seq):
        u["gap_before"] = 0.0 if i == 0 else round(rnd.uniform(0.9, 1.4), 2)
    return seq


def main() -> None:
    labels.DIALOGUES_DIR.mkdir(exist_ok=True)
    only = set(sys.argv[1:])
    for n, (did, spec) in enumerate(SCRIPTS.items(), start=1):
        if only and did not in only:
            continue
        rnd = random.Random(1000 + n)
        participants = [I] if len(spec["voices"]) == 1 else [I, T]
        seq = with_answers(expand(did, spec), rnd)
        wd = audio.make_workdir()
        try:
            rend = audio.render(seq, {**spec["voices"]}, wd, write_wav=False)
        finally:
            gone = audio.remove_workdir(wd)
        assert gone
        utts = []
        for u, tl in zip(seq, rend.timeline):
            row = dict(speaker=u["speaker"], text=u["text"], category=u["category"], is_question=u["is_question"],
                       addressee=u["addressee"], bank_id=u["bank_id"], t_start=tl["t_start"], t_end=tl["t_end"],
                       gap_before=u["gap_before"])
            if "silent_s" in u:
                row["silent_s"] = u["silent_s"]
            utts.append(row)
        d = dict(id=did, suite=spec.get("suite", "main"), lang="en", owner=OWNER, participants=participants, voices=spec["voices"],
                 name_variants={"Tomas": ["Thomas"]},   # how the recognizer spells the name (passed to --others)
                 session="sample-interview", speakers=1 + len(participants), duration_s=round(rend.duration, 1), utterances=utts)
        errs = labels.validate(d)
        assert not errs, (did, errs)
        (labels.DIALOGUES_DIR / f"{did}.json").write_text(json.dumps(d, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
        nq = sum(1 for u in utts if u["is_question"] and u["addressee"] == "me")
        no = sum(1 for u in utts if u["is_question"] and u["addressee"] == "other")
        print(f"{did}: {len(participants) + 1} speakers, {rend.duration:.0f} s, {nq} questions to Alex, {no} to the other interviewer", flush=True)


if __name__ == "__main__":
    main()
