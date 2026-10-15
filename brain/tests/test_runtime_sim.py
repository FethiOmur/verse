"""Sim runtime (plan S2): the half-duplex interview loop over the fake transport.

The session fixture (tests/fixtures/sim_runtime/session) is hand-written to the Shared contracts (sim.json,
sim_pack.md, posting.txt); `build_report` is stubbed through the `report_builder` hook. The live run
(`test_live_three_question_sim`) is opt-in: VERSE_LIVE=1, and it reads the Keychain key itself.
"""

from __future__ import annotations

import asyncio
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

from verse_brain.runtime.fake import FakeTransport, Script, lines_script
from verse_brain.runtime.protocol import ListEmitter, parse_line
from verse_brain.runtime.settings import HAIKU, SONNET
from verse_brain.runtime.sim import SILENCE_LINE, SimConfig, SimRuntime, sim_fake_responder
from verse_brain.runtime.transport import Offline

BRAIN = Path(__file__).resolve().parents[1]
FIX = Path(__file__).resolve().parent / "fixtures" / "sim_runtime"
SESSION = FIX / "session"

ASK_TEXT = "Thanks for joining today. Let's get started. Tell me a bit about yourself?"


def session_copy(tmp_path: Path, **overrides) -> Path:
    dst = tmp_path / "sim-session"
    shutil.copytree(SESSION, dst)
    if overrides:
        sim = json.loads((dst / "sim.json").read_text(encoding="utf-8"))
        sim.update(overrides)
        (dst / "sim.json").write_text(json.dumps(sim), encoding="utf-8")
    return dst


def task_of(info) -> str:
    return info.tail.split("\n", 1)[0].removeprefix("TASK: ").strip()


def responder(judge="NEXT", coach="- You opened with a clear summary [e1].\n- Name the result next time.",
              ask=ASK_TEXT, answer="Good question. It is a take-home case on a real conversation log.", errors=None):
    """A task-aware fake: `judge` may be a string or a callable(info) -> str; `errors` maps a task to an error."""
    errors = errors or {}

    def r(info):
        task = task_of(info)
        if task in errors:
            return Script(error=errors[task])
        if task == "ASK":
            return lines_script(ask)
        if task == "JUDGE":
            return lines_script(judge(info) if callable(judge) else judge)
        if task == "COACH":
            return lines_script(coach)
        if task == "ANSWER":
            return lines_script(answer)
        return lines_script("unexpected")
    return r


class Rig:
    def __init__(self, tmp_path: Path, resp=None, report=None, session: Path | None = None, **cfg) -> None:
        self.session = session or session_copy(tmp_path)
        self.t = FakeTransport(resp or responder())
        self.em = ListEmitter()
        self.report_calls: list[tuple] = []
        self.results_at_report: dict | None = None

        async def stub(session_dir, transport, *, model=SONNET):
            self.report_calls.append((Path(session_dir), transport, model))
            self.results_at_report = json.loads((Path(session_dir) / "sim_results.json").read_text(encoding="utf-8")) \
                if (Path(session_dir) / "sim_results.json").exists() else None
            out = Path(session_dir) / "report.html"
            out.write_text("<html><body>report</body></html>", encoding="utf-8")
            return out

        cfg.setdefault("silence_s", 30.0)
        self.rt = SimRuntime(self.t, self.em, SimConfig(**cfg), report_builder=report or stub)
        self.rt.start_background = False

    async def start(self, mode="coach", voice="text"):
        await self.rt.handle({"type": "sim_start", "session_dir": str(self.session), "mode": mode, "voice": voice})

    async def wait(self, pred, timeout: float = 3.0, what: str = "condition"):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            got = pred()
            if got:
                return got
            await asyncio.sleep(0.01)
        raise AssertionError(f"timed out waiting for {what}; events: {self.flow()}")

    def listens(self, q_id: str | None = None) -> list[dict]:
        return [e for e in self.em.events if e["type"] == "listen" and (q_id is None or e["q_id"] == q_id)]

    async def wait_listen(self, q_id: str, n: int = 1, timeout: float = 3.0) -> None:
        await self.wait(lambda: len(self.listens(q_id)) >= n, timeout, f"listen {q_id} #{n}")

    async def answer(self, q_id: str, text: str, t0: float = 0.0, dur: float = 10.0) -> None:
        await self.rt.handle({"type": "answer", "q_id": q_id, "text": text, "t_start": t0, "t_end": t0 + dur,
                              "words": len(text.split()), "fillers": 0})

    async def control(self, action: str) -> None:
        await self.rt.handle({"type": "control", "action": action})

    async def finished(self, timeout: float = 5.0) -> None:
        await self.wait(lambda: self.rt.finished.is_set(), timeout, "sim finished")

    def flow(self) -> list[str]:
        out = []
        for e in self.em.events:
            if e["type"] == "say":
                out.append(f"say{'!' if e['final'] else ''}:{e['id']}")
            elif e["type"] == "listen":
                out.append(f"listen:{e['q_id']}")
            elif e["type"] == "sim_progress":
                out.append(f"progress:{e['q_index']}/{e['q_total']}")
            elif e["type"] in ("coach", "sim_report"):
                out.append(e["type"])
        return out

    def results(self) -> dict:
        return json.loads((self.session / "sim_results.json").read_text(encoding="utf-8"))

    def calls(self, task: str) -> list:
        return [c for c in self.t.calls if task_of(c) == task]

    async def close(self) -> None:
        await self.rt.shutdown()


def run(coro):
    return asyncio.run(coro)


async def full_run(rig: Rig, mode="coach", answers=None):
    """Answer every `listen` in order (the judge decides how many per question), ask one candidate question, and
    wait for the end."""
    answers = answers or {}
    await rig.start(mode)
    handled = 0
    while True:
        await rig.wait(lambda: len(rig.listens()) > handled or rig.rt.finished.is_set(), what="next listen")
        if len(rig.listens()) <= handled:
            break
        q = rig.listens()[handled]["q_id"]
        handled += 1
        if q == "candidate":
            await rig.answer("candidate", "What does the case study look like?")
        else:
            await rig.answer(q, answers.get(q, f"I built Lantern and it cut entry time from 11 to 2 minutes ({q})."))
    await rig.finished()


# ---------------------------------------------------------------------------------------------------------- order

def test_sim_say_listen_order(tmp_path):
    rig = Rig(tmp_path)

    async def go():
        await rig.start("realistic")
        await rig.wait_listen("q1")
        # nothing is said after listen until the answer arrives
        await asyncio.sleep(0.1)
        assert rig.flow()[-1] == "listen:q1"
        await rig.answer("q1", "I led Lantern, an invoice pipeline that cut entry from 11 to 2 minutes.")
        await rig.wait_listen("q2")
        await rig.answer("q2", "I shipped Lantern and measured it with a golden set of 300 invoices.")
        await rig.wait_listen("q3")
        await rig.answer("q3", "I want to work on assistants that talk to real shoppers.")
        await rig.wait_listen("candidate")
        await rig.answer("candidate", "What does the case study look like?")
        await rig.finished()
        await rig.close()

    run(go())
    f = rig.flow()
    # progress, then the question line (three sentences, `final` only on the last), then listen
    assert f[:5] == ["progress:1/3", "say:s1", "say:s1", "say!:s1", "listen:q1"], f
    assert f.index("progress:2/3") > f.index("listen:q1")
    assert f.index("progress:3/3") > f.index("listen:q2")
    # q3 -> candidate question line -> listen candidate -> reply -> close -> report
    i = f.index("listen:candidate")
    assert f[i - 1].startswith("say!:") and f[-1] == "sim_report", f
    assert f[i + 1:-1] and all(x.startswith("say") for x in f[i + 1:-1]), f
    says = [e for e in rig.em.of("say") if e["id"] == "s1"]
    assert " ".join(e["text"] for e in says) == ASK_TEXT
    # every say line ends with exactly one final sentence
    ids = []
    for e in rig.em.of("say"):
        if e["id"] not in ids:
            ids.append(e["id"])
    for sid in ids:
        fin = [e["final"] for e in rig.em.of("say") if e["id"] == sid]
        assert fin[-1] is True and not any(fin[:-1]), (sid, fin)
    assert rig.results()["questions"][0]["asked"][0] == {"id": "s1", "text": ASK_TEXT, "kind": "question"}


def test_say_streams_before_the_call_ends(tmp_path):
    """The first sentence reaches Swift while the model is still writing the rest of the line."""
    def resp(info):
        if task_of(info) == "ASK":
            return Script(chunks=[(0.0, "Thanks for joining today."), (0.0, " Let's"), (0.4, " start."),
                                  (0.0, " Tell me about yourself?")])
        return responder()(info)

    rig = Rig(tmp_path, resp)

    async def go():
        await rig.start("realistic")
        await rig.wait(lambda: rig.em.of("say"), what="first say")
        first = rig.em.of("say")[0]
        assert first["text"] == "Thanks for joining today." and first["final"] is False
        assert not rig.listens()      # the line is still being written
        await rig.wait_listen("q1")
        await rig.close()

    run(go())


def test_prompt_layout_cache_stable(tmp_path):
    """system -> sim_pack.md (breakpoint 1) -> one block per finished question (breakpoint 2 every 2) -> tail."""
    rig = Rig(tmp_path, responder(judge="NEXT"))
    run(full_run(rig, mode="realistic"))
    run(rig.close())
    pack = (rig.session / "sim_pack.md").read_text(encoding="utf-8")
    haiku = [c for c in rig.t.calls if c.model == HAIKU]
    assert haiku and all(c.route == "S" for c in haiku)
    systems = {json.dumps(c.request["system"]) for c in haiku}
    assert len(systems) == 1
    first_blocks = {json.dumps(c.request["messages"][0]["content"][0], sort_keys=True) for c in haiku}
    assert len(first_blocks) == 1
    b0 = haiku[0].request["messages"][0]["content"][0]
    assert pack in b0["text"] and b0["cache_control"] == {"type": "ephemeral"}
    for c in rig.t.calls:
        content = c.request["messages"][0]["content"]
        assert "cache_control" not in content[-1]
        assert content[-1]["text"].startswith("TASK: ")
    # during q3 the transcript holds q1 and q2: breakpoint 2 on the q2 block (2 finished questions)
    q3_ask = [c for c in rig.calls("ASK") if "[q3]" in c.tail][0]
    content = q3_ask.request["messages"][0]["content"]
    assert len(content) == 4
    assert [i for i, b in enumerate(content) if "cache_control" in b] == [0, 2]
    assert "[q1]" in content[1]["text"] and "[q2]" in content[2]["text"]
    q2_ask = [c for c in rig.calls("ASK") if "[q2]" in c.tail][0]
    c2 = q2_ask.request["messages"][0]["content"]
    assert len(c2) == 3 and [i for i, b in enumerate(c2) if "cache_control" in b] == [0]
    # append-only: q2's transcript block reappears unchanged in q3's request
    assert c2[1]["text"] == content[1]["text"]
    # pre-warm at sim_start: same Haiku prefix, max_tokens 0
    warm = [w for w in rig.t.creates if w["request"]["model"] == HAIKU]
    assert warm and warm[0]["request"]["max_tokens"] == 0
    assert warm[0]["request"]["system"] == haiku[0].request["system"]
    assert warm[0]["request"]["messages"][0]["content"][0] == b0


# ---------------------------------------------------------------------------------------------------------- judge

def test_followups_capped_at_two(tmp_path):
    rig = Rig(tmp_path, responder(judge="FOLLOW: Can you say more about that? What was your part?"))

    async def go():
        await rig.start("realistic")
        for n in range(1, 4):
            await rig.wait_listen("q1", n)
            await rig.answer("q1", f"Answer number {n} about Lantern.")
        await rig.wait_listen("q2")
        await rig.close()

    run(go())
    judges_q1 = [c for c in rig.calls("JUDGE") if "Question q1" in c.tail]
    assert len(judges_q1) == 2
    q1 = rig.results()["questions"][0]
    assert [a["kind"] for a in q1["asked"]] == ["question", "follow_up", "follow_up"]
    assert q1["asked"][1]["text"] == "Can you say more about that? What was your part?"
    assert len(q1["answers"]) == 3
    # the follow-up text is spoken by sentence like any other line
    fu = [e for e in rig.em.of("say") if e["id"] == q1["asked"][1]["id"]]
    assert [e["text"] for e in fu] == ["Can you say more about that?", "What was your part?"]


def test_judge_next_and_malformed_move_on(tmp_path):
    rig = Rig(tmp_path, responder(judge=lambda i: "NEXT" if "Question q1" in i.tail else "Sure, that sounds great."))

    async def go():
        await rig.start("realistic")
        await rig.wait_listen("q1")
        await rig.answer("q1", "I led Lantern.")
        await rig.wait_listen("q2")
        await rig.answer("q2", "We shipped it.")
        await rig.wait_listen("q3")      # a line without FOLLOW/PUSH/NEXT is read as NEXT and never spoken
        await rig.close()

    run(go())
    assert all("Sure, that sounds great" not in e["text"] for e in rig.em.of("say"))


def test_push_rules_by_difficulty(tmp_path):
    def judge(info):
        return "PUSH: Can you put a number on that?"

    cases = []
    for diff in ("friendly", "standard", "tough"):
        sess = session_copy(tmp_path / diff, difficulty=diff)
        rig = Rig(tmp_path, responder(judge=judge), session=sess)

        async def go(rig=rig):
            await rig.start("realistic")
            await rig.wait_listen("q1")
            await rig.answer("q1", "We built a pipeline and the team liked it.")   # vague: no number, no "I"
            await rig.wait_listen("q1", 2)
            await rig.answer("q1", "I cut entry time from 11 to 2 minutes.")       # specific
            await rig.wait(lambda: len(rig.calls("JUDGE")) >= 2)
            await rig.close()

        run(go())
        cases.append((diff, rig))
    for diff, rig in cases:
        j1, j2 = rig.calls("JUDGE")[:2]
        kinds = [a["kind"] for a in rig.results()["questions"][0]["asked"]]
        if diff == "tough":
            assert "PUSH:" in j1.tail and "PUSH:" not in j2.tail, diff
            assert kinds[1] == "push", (diff, kinds)
        else:
            assert "PUSH:" not in j1.tail and "PUSH:" not in j2.tail, diff
            assert kinds[1] == "follow_up", (diff, kinds)    # a PUSH that was not offered counts as a follow-up


# ---------------------------------------------------------------------------------------------------------- coach

def test_coach_only_in_coach_mode(tmp_path):
    coach_rig = Rig(tmp_path / "c", session=session_copy(tmp_path / "c"))
    real_rig = Rig(tmp_path / "r", session=session_copy(tmp_path / "r"))
    run(full_run(coach_rig, mode="coach"))
    run(coach_rig.close())
    run(full_run(real_rig, mode="realistic"))
    run(real_rig.close())

    assert len(coach_rig.em.of("coach")) == 3
    assert [e["q_id"] for e in coach_rig.em.of("coach")] == ["q1", "q2", "q3"]
    f = coach_rig.flow()
    # each note comes after its question's last answer and before the next question starts
    assert f.index("coach") < f.index("progress:2/3")
    assert all(q["coach"] for q in coach_rig.results()["questions"])

    assert real_rig.em.of("coach") == [] and real_rig.calls("COACH") == []
    assert all(q["coach"] == [] for q in real_rig.results()["questions"])


def test_coach_prompt_carries_the_voice_block(tmp_path):
    """V1: a sim pack with a VOICE section reaches the COACH request (cached prefix) and the tail points at it;
    without one the tail is what it was."""
    from verse_brain.prep.voice import SIM_HEADER, with_voice
    voice = (Path(__file__).parent / "fixtures" / "voice" / "profile_fictional.md").read_text(encoding="utf-8")
    plain_session = session_copy(tmp_path / "plain")
    voiced_session = session_copy(tmp_path / "voiced")
    pack = (voiced_session / "sim_pack.md").read_text(encoding="utf-8")
    (voiced_session / "sim_pack.md").write_text(with_voice(pack, voice, "sim"), encoding="utf-8")
    rigs = {name: Rig(tmp_path / name, session=sess) for name, sess in (("plain", plain_session), ("voiced", voiced_session))}
    for name, rig in rigs.items():
        run(full_run(rig, mode="coach"))
        run(rig.close())

    plain, voiced = rigs["plain"].calls("COACH"), rigs["voiced"].calls("COACH")
    assert plain and len(plain) == len(voiced) == 3
    for info in voiced:
        prefix = info.request["messages"][0]["content"][0]["text"]  # the cached pack block
        assert SIM_HEADER in prefix and voice.strip() in prefix
        assert "VOICE section of the SIM PACK" in info.tail
        assert info.request["messages"][0]["content"][0]["cache_control"] == {"type": "ephemeral"}
    for info in plain:
        assert "VOICE" not in info.tail and "VOICE" not in info.request["messages"][0]["content"][0]["text"]
    # other tasks keep their tails: the voice note is a coach-only instruction
    assert all("VOICE" not in c.tail for c in rigs["voiced"].calls("ASK") + rigs["voiced"].calls("JUDGE"))


def test_coach_uses_only_pack_evidence(tmp_path):
    coach = ("- You opened with a clear one-line summary [e1].\n"
             "- You could cite the 40% speed-up [e99].\n"
             "- Better: \"Lantern cut entry from 11 to 2 minutes per invoice.\" [e2]\n"
             "- Mention that quality rose by 75 percent, 30 points.")
    rig = Rig(tmp_path, responder(coach=coach))

    async def go():
        await rig.start("coach")
        await rig.wait_listen("q1")
        await rig.answer("q1", "I led Lantern, an invoice pipeline.")
        await rig.wait(lambda: rig.em.of("coach"))
        await rig.close()

    run(go())
    lines = rig.em.of("coach")[0]["lines"]
    assert lines == ["You opened with a clear one-line summary [e1].",
                     "Better: \"Lantern cut entry from 11 to 2 minutes per invoice.\" [e2]"], lines
    tail = rig.calls("COACH")[0].tail
    assert "e1" in tail and "[e2]" in tail      # the planned evidence ids are offered; the pack holds their text


# ---------------------------------------------------------------------------------------------------------- controls

def test_skip_repeat_end(tmp_path):
    rig = Rig(tmp_path)

    async def go():
        await rig.start("coach")
        await rig.wait_listen("q1")
        await rig.control("repeat")
        await rig.wait_listen("q1", 2)
        await rig.control("skip")
        await rig.wait_listen("q2")
        await rig.control("end")
        await rig.finished()
        await rig.close()

    run(go())
    r = rig.results()
    q1, q2 = r["questions"]
    assert [a["kind"] for a in q1["asked"]] == ["question", "repeat"]
    assert q1["asked"][1]["text"] == q1["asked"][0]["text"] and q1["asked"][1]["id"] != q1["asked"][0]["id"]
    assert q1["skipped"] is True and q1["answers"] == [] and q1["coach"] == []
    assert q2["skipped"] is False and q2["answers"] == []
    assert [q["q_id"] for q in r["questions"]] == ["q1", "q2"]          # q3 never asked
    assert rig.listens("q3") == [] and rig.listens("candidate") == []  # end skips the candidate question
    assert rig.calls("COACH") == []
    assert len(rig.report_calls) == 1 and rig.flow()[-1] == "sim_report"
    assert r["candidate_question"] == {"text": "", "reply": ""}


def test_skip_during_judge_moves_on(tmp_path):
    def resp(info):
        if task_of(info) == "JUDGE":
            return lines_script("FOLLOW: And what happened next?", first_byte_delay=1.0)
        return responder()(info)

    rig = Rig(tmp_path, resp)

    async def go():
        await rig.start("realistic")
        await rig.wait_listen("q1")
        await rig.answer("q1", "I led Lantern.")
        await rig.wait(lambda: rig.calls("JUDGE"))
        await rig.control("skip")
        await rig.wait_listen("q2", timeout=0.8)
        await rig.close()

    run(go())
    q1 = rig.results()["questions"][0]
    assert q1["skipped"] is True and len(q1["answers"]) == 1
    assert all("what happened next" not in e["text"] for e in rig.em.of("say"))


def test_skip_during_coach_is_not_a_skipped_question(tmp_path):
    def resp(info):
        if task_of(info) == "COACH":
            return lines_script("- Good answer [e1].", first_byte_delay=1.0)
        return responder()(info)

    rig = Rig(tmp_path, resp)

    async def go():
        await rig.start("coach")
        await rig.wait_listen("q1")
        await rig.answer("q1", "I led Lantern.")
        await rig.wait(lambda: rig.calls("COACH"))
        await rig.control("skip")
        await rig.wait_listen("q2", timeout=0.8)
        await rig.close()

    run(go())
    q1 = rig.results()["questions"][0]
    assert q1["skipped"] is False and q1["coach"] == [] and len(q1["answers"]) == 1


def test_silence_prompt_once(tmp_path):
    rig = Rig(tmp_path, silence_s=0.15, playback_wps=1000.0)

    async def go():
        await rig.start("realistic")
        await rig.wait_listen("q1")
        await rig.wait(lambda: any(e["text"] == SILENCE_LINE for e in rig.em.of("say")), 1.0, "silence prompt")
        await rig.wait_listen("q1", 2)        # listening again after the prompt
        await asyncio.sleep(0.6)
        await rig.answer("q1", "Sorry, I led Lantern.")
        await rig.wait_listen("q2")
        await rig.close()

    run(go())
    prompts = [e for e in rig.em.of("say") if e["text"] == SILENCE_LINE]
    assert len(prompts) == 1 and prompts[0]["final"] is True
    q1 = rig.results()["questions"][0]
    assert all(a["text"] != SILENCE_LINE for a in q1["asked"])   # not an interview question


def test_silence_timer_waits_for_playback_and_speech(tmp_path):
    """The 20 s count starts when the line has played (`spoken`), and speech (`partial`) restarts it."""
    rig = Rig(tmp_path, silence_s=0.2, playback_wps=0.5)   # estimated playback of the question: ~30 s

    async def go():
        await rig.start("realistic")
        await rig.wait_listen("q1")
        await asyncio.sleep(0.4)
        assert not any(e["text"] == SILENCE_LINE for e in rig.em.of("say"))
        line_id = rig.em.of("say")[-1]["id"]
        await rig.rt.handle({"type": "spoken", "id": line_id})
        for _ in range(5):                    # the candidate is talking: partials keep the prompt away
            await asyncio.sleep(0.1)
            await rig.rt.handle({"type": "partial", "turn_id": "m1", "speaker": "me", "text": "so I", "cue": False})
        assert not any(e["text"] == SILENCE_LINE for e in rig.em.of("say"))
        await rig.wait(lambda: any(e["text"] == SILENCE_LINE for e in rig.em.of("say")), 1.0, "silence prompt")
        await rig.close()

    run(go())


# ---------------------------------------------------------------------------------------------------------- results / report

def _check_results_schema(r: dict, q_ids: list[str]) -> None:
    assert set(r) == {"session_id", "mode", "voice", "started_at", "ended_at", "questions", "candidate_question",
                      "usage_usd"}, set(r)
    assert isinstance(r["session_id"], str) and r["session_id"]
    assert r["mode"] in ("coach", "realistic") and r["voice"] in ("apple", "elevenlabs", "openai", "text")
    from datetime import datetime
    for k in ("started_at", "ended_at"):
        datetime.fromisoformat(r[k])
    assert isinstance(r["usage_usd"], float) and r["usage_usd"] >= 0
    assert set(r["candidate_question"]) == {"text", "reply"}
    assert all(isinstance(v, str) for v in r["candidate_question"].values())
    assert [q["q_id"] for q in r["questions"]] == q_ids
    seen_ids = set()
    for q in r["questions"]:
        assert set(q) == {"q_id", "asked", "answers", "coach", "skipped"}, set(q)
        assert isinstance(q["skipped"], bool)
        assert all(isinstance(c, str) for c in q["coach"])
        for a in q["asked"]:
            assert set(a) == {"id", "text", "kind"} and a["kind"] in ("question", "follow_up", "push", "repeat")
            assert isinstance(a["text"], str) and a["text"] and a["id"] not in seen_ids
            seen_ids.add(a["id"])
        for a in q["answers"]:
            assert set(a) == {"text", "t_start", "t_end", "words", "fillers"}
            assert isinstance(a["text"], str)
            assert all(isinstance(a[k], float) for k in ("t_start", "t_end"))
            assert all(isinstance(a[k], int) and not isinstance(a[k], bool) for k in ("words", "fillers"))


def test_results_schema(tmp_path):
    def judge(info):
        return "FOLLOW: What was the measured result?" if "Question q2" in info.tail and \
            "Follow-ups asked so far for this question: 0" in info.tail else "NEXT"

    rig = Rig(tmp_path, responder(judge=judge))
    run(full_run(rig, mode="coach"))
    run(rig.close())
    r = rig.results()
    _check_results_schema(r, ["q1", "q2", "q3"])
    assert r["session_id"] == "sim-20261014-1200-northwind-labs" and r["mode"] == "coach" and r["voice"] == "text"
    assert r["candidate_question"]["text"] == "What does the case study look like?"
    assert r["candidate_question"]["reply"].startswith("Good question.")
    assert [a["kind"] for a in r["questions"][1]["asked"]] == ["question", "follow_up"]
    assert r["usage_usd"] > 0


def test_candidate_question_uses_sonnet_and_posting(tmp_path):
    rig = Rig(tmp_path)
    run(full_run(rig, mode="realistic"))
    run(rig.close())
    ans = rig.calls("ANSWER")
    assert len(ans) == 1 and ans[0].route == "D" and ans[0].model == SONNET
    posting = (rig.session / "posting.txt").read_text(encoding="utf-8").strip()
    assert posting.splitlines()[0] in ans[0].tail and "What does the case study look like?" in ans[0].tail
    reply = [e for e in rig.em.of("say") if e["text"].startswith("Good question.")]
    assert reply


def test_answer_waits_for_inflight_sonnet_prewarm(tmp_path):
    """The Sonnet cache is written when the closing question is asked; an answer that arrives while that pre-warm is
    still in flight waits for it (bounded) instead of writing the same cache a second time."""
    class SlowSonnetWarm(FakeTransport):
        def __init__(self, resp):
            super().__init__(resp)
            self.sonnet_warm_done: float | None = None

        async def create(self, route, request, lane):
            if request["model"] == SONNET:
                await asyncio.sleep(0.3)
                out = await super().create(route, request, lane)
                self.sonnet_warm_done = time.monotonic()
                return out
            return await super().create(route, request, lane)

    rig = Rig(tmp_path)
    rig.t = rig.rt.transport = SlowSonnetWarm(responder())

    async def go():
        await rig.start("realistic")
        for q in ("q1", "q2", "q3"):
            await rig.wait_listen(q)
            await rig.answer(q, "I led Lantern.")
        await rig.wait_listen("candidate")
        await rig.answer("candidate", "What does the case study look like?")
        await rig.finished()
        await rig.close()

    run(go())
    ans = rig.calls("ANSWER")[0]
    assert rig.t.sonnet_warm_done is not None and ans.t_open >= rig.t.sonnet_warm_done


def test_report_called_at_end(tmp_path):
    rig = Rig(tmp_path)
    run(full_run(rig, mode="realistic"))
    run(rig.close())
    assert len(rig.report_calls) == 1
    sd, transport, _model = rig.report_calls[0]
    assert sd == rig.session and transport is rig.t
    # sim_results.json is complete on disk before the builder runs
    assert rig.results_at_report is not None and len(rig.results_at_report["questions"]) == 3
    assert rig.results_at_report["candidate_question"]["text"]
    rep = rig.em.of("sim_report")
    assert rep == [{"type": "sim_report", "path": str(rig.session / "report.html")}]
    assert rig.em.events.index(rep[0]) > max(i for i, e in enumerate(rig.em.events) if e["type"] == "say")


def test_report_failure_is_reported_not_fatal(tmp_path):
    async def boom(session_dir, transport, *, model=SONNET):
        raise RuntimeError("grader exploded")

    rig = Rig(tmp_path, report=boom)
    run(full_run(rig, mode="realistic"))
    run(rig.close())
    assert rig.em.of("sim_report") == []
    assert any(e["state"] == "error" and "report" in e["message"] for e in rig.em.of("status"))
    assert rig.results()["questions"]


def test_model_errors_fall_back(tmp_path):
    """No model, no stall: the planned question is said verbatim, a failed judge moves on, a failed coach is silent."""
    rig = Rig(tmp_path, responder(errors={"ASK": Offline("down"), "JUDGE": Offline("down"), "COACH": Offline("down")}))

    async def go():
        await rig.start("coach")
        await rig.wait_listen("q1")
        await rig.answer("q1", "I led Lantern.")
        await rig.wait_listen("q2")
        await rig.close()

    run(go())
    planned = json.loads((rig.session / "sim.json").read_text())["questions"][0]["text"]
    assert rig.results()["questions"][0]["asked"][0]["text"] == planned
    assert rig.em.of("coach") == []
    assert any(e["state"] == "offline" for e in rig.em.of("status"))


def test_partial_results_on_shutdown(tmp_path):
    rig = Rig(tmp_path)

    async def go():
        await rig.start("realistic")
        await rig.wait_listen("q1")
        await rig.answer("q1", "I led Lantern.")
        await rig.wait_listen("q2")
        await rig.close()

    run(go())
    r = rig.results()
    _check_results_schema(r, ["q1", "q2"])
    assert r["questions"][0]["answers"][0]["text"] == "I led Lantern."
    assert rig.report_calls == []


# ---------------------------------------------------------------------------------------------------------- dispatch

def test_parse_line_accepts_sim_messages():
    for m in ({"type": "sim_start", "session_dir": "/x", "mode": "coach", "voice": "text"},
              {"type": "answer", "q_id": "q1", "text": "hi", "t_start": 0.0, "t_end": 1.0, "words": 1, "fillers": 0},
              {"type": "spoken", "id": "s1"}, {"type": "control", "action": "skip"}):
        assert parse_line(json.dumps(m)) == m


def _spawn_fake():
    env = dict(os.environ)
    env.pop("PYTHONUNBUFFERED", None)
    return subprocess.Popen([sys.executable, "-m", "verse_brain.runtime", "--fake"], cwd=BRAIN, env=env,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


class _Pipe:
    def __init__(self, p):
        self.p = p
        self.q: queue.Queue = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()
        self.events: list[dict] = []

    def _read(self):
        for line in self.p.stdout:
            self.q.put(json.loads(line))
        self.q.put(None)

    def send(self, msg):
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()

    def until(self, pred, timeout=10.0):
        end = time.time() + timeout
        while time.time() < end:
            try:
                ev = self.q.get(timeout=max(0.0, end - time.time()))
            except queue.Empty:
                break
            if ev is None:
                break
            self.events.append(ev)
            if pred(ev):
                return ev
        raise AssertionError(f"not seen; got {[e['type'] for e in self.events]}")


def test_meeting_mode_unchanged(tmp_path):
    """One process serves the mode its first message names: `start` is the meeting runtime as before (the existing
    test_runtime_*.py suites cover its behaviour), `sim_start` the interview, over the same JSON lines."""
    from test_runtime_helpers import session_copy as meeting_copy

    p = _spawn_fake()
    try:
        io = _Pipe(p)
        io.send({"type": "start", "session_dir": str(meeting_copy(tmp_path / "m")), "lang": "en"})
        io.until(lambda e: e.get("type") == "status" and e.get("state") == "ready")
        io.send({"type": "turn", "turn_id": "q1", "speaker": "remote", "text": "what did the pilot achieve?",
                 "addressee": "me", "t_audio_end": time.time()})
        io.until(lambda e: e.get("type") == "delta" and e.get("tier") == "D")
        io.send({"type": "sim_start", "session_dir": str(SESSION), "mode": "coach", "voice": "text"})  # ignored
        io.send({"type": "control", "action": "stop"})
        assert p.wait(timeout=10) == 0
        assert not any(e["type"] in ("say", "listen", "sim_progress") for e in io.events)
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)

    sess = session_copy(tmp_path / "s")
    p = _spawn_fake()
    try:
        io = _Pipe(p)
        io.send({"type": "sim_start", "session_dir": str(sess), "mode": "coach", "voice": "text"})
        io.until(lambda e: e.get("type") == "listen" and e["q_id"] == "q1")
        io.send({"type": "turn", "turn_id": "x", "speaker": "remote", "text": "meeting turn", "addressee": "me"})  # ignored
        io.send({"type": "answer", "q_id": "q1", "text": "I led Lantern.", "t_start": 0.0, "t_end": 4.0, "words": 3,
                 "fillers": 0})
        io.until(lambda e: e.get("type") == "listen" and e["q_id"] == "q2")
        io.send({"type": "control", "action": "end"})
        io.until(lambda e: e.get("type") in ("sim_report",) or (e.get("type") == "status" and "report" in e.get("message", "")))
        p.stdin.close()
        assert p.wait(timeout=10) == 0
        assert not any(e["type"] == "delta" for e in io.events)
        r = json.loads((sess / "sim_results.json").read_text(encoding="utf-8"))
        assert [q["q_id"] for q in r["questions"]] == ["q1", "q2"]
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)


def test_fake_responder_speaks_planned_question():
    """`--fake` (no network) gives sim calls plausible canned text rather than meeting-format lines."""
    t = FakeTransport(sim_fake_responder)
    req = {"model": HAIKU, "messages": [{"role": "user", "content": [
        {"type": "text", "text": "TASK: ASK\nLanguage: English\nQUESTION [q1] (opener): Tell me about yourself.\n..."}]}]}

    async def go():
        s = await t.open_stream("S", req, 0)
        return "".join([ev.text async for ev in s if ev.kind == "text"])

    out = run(go())
    assert "Tell me about yourself." in out and "SAY:" not in out and "BANK:" not in out


# ---------------------------------------------------------------------------------------------------------- live (opt-in)

@pytest.mark.skipif(os.environ.get("VERSE_LIVE") != "1", reason="live run: set VERSE_LIVE=1 (reads the Keychain key)")
def test_live_three_question_sim(tmp_path):
    """Drives the real process (real transport) over JSON lines with the scripted answers in answers.json."""
    out_dir = Path(os.environ.get("VERSE_LIVE_OUT") or tmp_path)
    sess = out_dir / "sim-live-session"
    if sess.exists():
        shutil.rmtree(sess)
    shutil.copytree(SESSION, sess)
    script = json.loads((FIX / "answers.json").read_text(encoding="utf-8"))
    used = {k: 0 for k in script}
    p = subprocess.Popen([sys.executable, "-m", "verse_brain.runtime", "--log-level", "WARNING"], cwd=BRAIN,
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        io = _Pipe(p)
        io.send({"type": "sim_start", "session_dir": str(sess), "mode": "coach", "voice": "text"})
        t_audio = 0.0
        while True:
            ev = io.until(lambda e: e.get("type") in ("listen", "sim_report")
                          or (e.get("type") == "status" and "report" in e.get("message", "")), timeout=120)
            if ev["type"] != "listen":
                break
            q = ev["q_id"]
            if q == "candidate":
                text = script["candidate"]
            else:
                lst = script.get(q, [])
                text = lst[used[q]] if used.get(q, 0) < len(lst) else script["fallback"]
                used[q] = used.get(q, 0) + 1
            dur = max(2.0, len(text.split()) / 2.5)
            io.send({"type": "answer", "q_id": q, "text": text, "t_start": t_audio, "t_end": t_audio + dur,
                     "words": len(text.split()), "fillers": 0})
            t_audio += dur + 3.0
        p.stdin.close()
        assert p.wait(timeout=30) == 0
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)
    (out_dir / "live_events.jsonl").write_text("\n".join(json.dumps(e) for e in io.events) + "\n", encoding="utf-8")
    r = json.loads((sess / "sim_results.json").read_text(encoding="utf-8"))
    _check_results_schema(r, ["q1", "q2", "q3"])
    assert all(q["answers"] for q in r["questions"])
    assert r["candidate_question"]["reply"]
