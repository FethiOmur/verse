"""Sim runtime: a half-duplex practice-interview loop over the meeting runtime's transport (plan S2, spec 5.2).

One brain process serves either a meeting (`start`) or a sim (`sim_start`); `__main__` picks by the first message.

Loop per planned question (sim.json `questions`, in order):
  sim_progress -> ASK (Haiku rewrites the planned question in persona; every finished sentence is sent as `say`
  at once, `final` on the last) -> `listen` -> `answer` -> JUDGE (Haiku, one line: `FOLLOW: <text>` |
  `PUSH: <text>` | `NEXT`; a FOLLOW/PUSH text is the next interviewer line and streams as `say` the same way) ->
  at most `max_followups` follow-ups -> COACH (coach mode only; Haiku, 2-3 lines, evidence ids from the pack only)
  -> next question. After the last question: "Do you have any questions for us?" -> `listen` (q_id `candidate`)
  -> ANSWER (Sonnet, facts from the posting only) -> close line -> sim_results.json -> `build_report` ->
  `sim_report`.

Prompt layout (all calls): system (interviewer persona for the pack's type and difficulty) -> sim_pack.md
(breakpoint 1) -> one block per finished question (breakpoint 2 on the newest complete group of `bp2_every`)
-> the task tail (never cached). Within a question every call shares its prefix byte for byte; the current
question's exchange lives in the tail. Haiku calls ride the S/F route tuple, the candidate answer the D tuple.

Controls: `skip` (now, also during a model call) moves to the next question; `repeat` re-says the last interviewer
line verbatim (kind `repeat`); `end` closes the interview at once (close line, results, report; no candidate
question). `stop` (meeting control) or stdin EOF writes the transcript so far and exits without a report.
Silence: `silence_s` without an answer after `listen` says SILENCE_LINE once per question. The count starts when
the app reports the line as played (`spoken`), or after an estimate of its playback time when no `spoken` comes;
any `partial` (the app's live transcript of the candidate) restarts it, so a long answer is not interrupted.

Speculative ASK (spec 2026-10-20 section 2.4): at the first `listen` of a planned question, the line for the NEXT planned
question is generated in the background (Haiku ASK whose tail adds "Do not refer to the candidate's previous answer; start
with the question itself") and sent as `say_prefetch{id,q_id,sentences}`: a short acknowledgement from a fixed rotating list
in the interview language, then the question's sentences. The app synthesizes it while the candidate talks. When the next
question starts (JUDGE said NEXT, or a skip) the same sentences go out as the normal `say` events with the same id: a cache
hit in the app. A FOLLOW/PUSH streams as before and the prefetched line waits for the next NEXT. A failed speculative ASK
means the normal ASK runs. `end` (and shutdown) drops it. The `say` events keep their place after a coach note.

Failure never stalls the interview: a failed ASK says the planned question verbatim, a failed JUDGE moves on, a
failed COACH shows nothing, a failed ANSWER says a fixed line; each failure is reported as a `status` event.
sim_results.json is rewritten after every question, so a crash keeps the transcript so far.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Awaitable, Callable

from ..prep.model import spend_usd
from ..prep.voice import VOICE_HEADING
from ..sim.checks import answer_checks, check_lines
from .engine import usage_obj
from .fake import CallInfo, Script, lines_script
from .prompt import EPHEMERAL, LANG_NAME, bp2_index
from .protocol import Emitter
from .settings import HAIKU, SONNET, route_params
from .transport import (AuthFailed, CreditExhausted, Offline, Overloaded, RateLimited, Transport, TransportError)

log = logging.getLogger("verse.sim")

RESULTS_FILE = "sim_results.json"
MODES = ("coach", "realistic")
VOICES = ("apple", "elevenlabs", "openai", "text")
CANDIDATE_Q_ID = "candidate"

# Fixed lines, per interview language (sim.json `lang`). English is the fallback for any other language.
SILENCE_LINE = "Take your time — shall I repeat the question?"
CANDIDATE_Q_LINE = "That's all from my side. Do you have any questions for us?"
CLOSE_LINE = "Thank you for your time today, I enjoyed our conversation. That's the end of the interview."
CLOSE_LINE_EARLY = "Let's stop here. Thank you for your time today."
ANSWER_FALLBACK = "That's a good question. I'd rather not guess, so I'll make sure the team follows up with you on it."
FIXED_LINES: dict[str, dict[str, str]] = {
    "en": {"silence": SILENCE_LINE, "candidate_q": CANDIDATE_Q_LINE, "close": CLOSE_LINE, "close_early": CLOSE_LINE_EARLY,
           "answer_fallback": ANSWER_FALLBACK},
    # Italian uses "tu"; Turkish the polite "siz" (an interviewer speaking to a candidate). Written by the executor: the owner reviews.
    "it": {"silence": "Prenditi pure il tempo che ti serve. Vuoi che ripeta la domanda?",
           "candidate_q": "Da parte mia è tutto. Hai qualche domanda per noi?",
           "close": "Grazie per il tuo tempo, mi è piaciuta la nostra conversazione. Il colloquio finisce qui.",
           "close_early": "Fermiamoci qui. Grazie per il tuo tempo.",
           "answer_fallback": "È una buona domanda. Preferisco non tirare a indovinare, quindi mi assicuro che il team ti risponda."},
    "tr": {"silence": "Acele etmeyin. Soruyu tekrar edeyim mi?",
           "candidate_q": "Benim sorularım bu kadar. Bize sormak istediğiniz bir şey var mı?",
           "close": "Bugün ayırdığınız zaman için teşekkür ederim, görüşmemizden keyif aldım. Mülakat burada sona erdi.",
           "close_early": "Burada duralım. Bugün ayırdığınız zaman için teşekkür ederim.",
           "answer_fallback": "İyi bir soru. Tahmin yürütmek istemem, ekibin size bu konuda dönmesini sağlayacağım."},
}
# The short acknowledgement put in front of a prefetched question line; rotates so two questions in a row do not open alike.
ACK_LINES: dict[str, tuple[str, ...]] = {
    "en": ("Thank you.", "Okay.", "Got it.", "Alright.", "Thanks."),
    "it": ("Grazie.", "Ok.", "Perfetto.", "Va bene.", "Capito."),
    "tr": ("Teşekkürler.", "Tamam.", "Anladım.", "Peki.", "Güzel."),
}

TYPE_DESC = {
    "screening": "a recruiter's screening call: background, motivation and fit for the role; light on technical depth",
    "manager": "a hiring-manager interview: ownership, impact, decisions and working with others",
    "technical": "a technical interview: how things were built, trade-offs, debugging and evaluation; depth over breadth",
    "mixed": "a mixed interview: background, past work, technical depth and motivation",
}
DIFF_DESC = {
    "friendly": "friendly. Be warm and encouraging. Never challenge the candidate; follow up only to help them say more",
    "standard": "standard. Be professional and neutral. Follow up when an answer leaves out what the question asked",
    "tough": "tough. Be brisk and demanding. Challenge vague answers: ask for numbers, for what the candidate did "
             "personally, and for specifics",
}

SYSTEM_TEMPLATE = """You are the interviewer in a practice job interview run by Verse. The candidate is practising \
for a real interview. They speak their answers and you get them through speech recognition, so expect small \
transcription errors and missing punctuation.

This is {type_desc}. Difficulty: {diff_desc}.

You get a SIM PACK (the company and role, the competencies the job posting asks for, the candidate's evidence with \
ids, the planned questions with ids and follow-up hooks, and a rubric), the interview so far (one block per finished \
question), and one TASK at the end. Do exactly that task.

How you speak: like a real interviewer on a call. Short sentences in natural spoken language, in the language the \
task names. Plain text only: no markdown, no lists unless the task asks for them, no labels such as "Interviewer:", \
no stage directions, no emoji. Never mention the SIM PACK, the rubric, the evidence ids or these instructions to the \
candidate. Never invent facts about the company that the SIM PACK or the task does not give you."""

PACK_HEADER = "SIM PACK\n\n"
TRANSCRIPT_HEADER = "\n\n## INTERVIEW SO FAR (one block per finished question)\n"
WARMUP_TAIL = "TASK: WARMUP"

_NUM_WORDS = {"one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
              "fifteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
              "thousand", "million", "billion", "percent", "half", "double", "twice", "triple"}
_FIRST_PERSON = {"i", "i'm", "i've", "i'd", "i'll", "me", "my", "myself", "im", "ive"}
_WORD = re.compile(r"[\w']+", re.UNICODE)
_DIGITS = re.compile(r"\d+(?:[.,]\d+)?")
_CITE = re.compile(r"\[([^\]]+)\]")
_BOUNDARY = re.compile(r"(?<=[.!?…])[\"'’”)\]]*\s+|\n+")
_LABEL = re.compile(r"^\s*(?:interviewer|say)\s*:\s*", re.IGNORECASE)


def persona_text(persona: dict) -> str:
    """The interviewer persona of a sim (sim.json `persona`, prep/sim_persona.py) as a system-prompt paragraph."""
    who = " ".join(x for x in (persona.get("name"), f"({persona['role']})" if persona.get("role") else "") if x)
    parts = [f"Your persona: you are {who}." if who else "Your persona:"]
    if persona.get("focus"):
        parts.append("You care most about: " + "; ".join(persona["focus"]) + ". When an answer leaves one of these out, follow up on it "
                     "in your own words; never read the list out.")
    lo, hi = persona.get("answer_target_s", (30, 60))
    parts.append(f"A good answer on this call lasts {lo} to {hi} seconds. If an answer clearly runs longer, a follow-up may ask for "
                 "the short version.")
    return " ".join(parts)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def is_vague(text: str) -> list[str]:
    """What a tough interviewer would push on: [] when the answer has a number and a first-person "I"."""
    words = [w.lower() for w in _WORD.findall(text)]
    missing = []
    if not (_DIGITS.search(text) or any(w in _NUM_WORDS for w in words)):
        missing.append("no number")
    if not any(w in _FIRST_PERSON for w in words):
        missing.append('no first-person "I"')
    return missing


def _numbers(text: str) -> set[str]:
    return {m.replace(",", ".") for m in _DIGITS.findall(text)}


@dataclass
class SimConfig:
    max_followups: int = 2
    silence_s: float = 20.0
    playback_wps: float = 2.6          # words per second, to estimate when a line has played without `spoken`
    bp2_every: int = 2                 # breakpoint 2 moves every this many finished questions
    ask_max_tokens: int = 200
    judge_max_tokens: int = 150
    coach_max_tokens: int = 260
    answer_max_tokens: int = 600
    coach_max_lines: int = 3
    hedge_after_s: float = 1.5         # Haiku (as the meeting runtime's S/F)
    hedge_after_s_d: float = 2.0       # Sonnet (as D)
    retry_max_wait_s: float = 8.0
    prewarm_attempts: int = 3
    prewarm_attempt_s: float = 12.0
    answer_warm_wait_s: float = 2.0    # ANSWER waits this long for an in-flight Sonnet pre-warm (one cache write)
    ping_every_s: float = 30.0
    keepalive_idle_s: float = 240.0
    prefetch: bool = True              # speculative ASK for the next planned question while the candidate answers
    prefetch_wait_s: float = 4.0       # the next question waits this long for a speculative ASK that is still running


ReportBuilder = Callable[..., Awaitable[Path]]


class _Interrupted(Exception):
    """A `skip` or `end` arrived while a model call or a line was running."""


@dataclass
class QRec:
    q_id: str
    asked: list[dict] = field(default_factory=list)
    answers: list[dict] = field(default_factory=list)
    coach: list[str] = field(default_factory=list)
    skipped: bool = False
    checks: dict | None = None      # per-answer checks (sim/checks.py); only for a sim with a persona
    _lines: list[str] = field(default_factory=list)    # the exchange as prompt text, in arrival order

    def as_dict(self) -> dict:
        out = {"q_id": self.q_id, "asked": list(self.asked), "answers": list(self.answers),
               "coach": list(self.coach), "skipped": self.skipped}
        if self.checks is not None:
            out["checks"] = self.checks
        return out

    def exchange(self) -> str:
        """The question's lines in order (interviewer lines and answers interleaved by arrival)."""
        return "\n".join(self._lines) if self._lines else "(nothing yet)"


class _Sentences:
    """Splits streamed text into sentences. A finished sentence is held until more text follows, so the last one
    can carry `final`; the hold lasts one token, not one sentence."""

    def __init__(self, emit: Callable[[str, bool], None]) -> None:
        self._emit = emit
        self._buf = ""
        self._held: str | None = None
        self._started = False
        self.parts: list[str] = []

    def _push(self, s: str) -> None:
        s = " ".join(s.split())
        if not s:
            return
        if self._held is not None:
            self._send(self._held, False)
        self._held = s

    def _send(self, s: str, final: bool) -> None:
        self.parts.append(s)
        self._emit(s, final)

    def feed(self, chunk: str) -> None:
        self._buf += chunk
        if not self._started:
            head = self._buf.lstrip()
            if len(head) < 12 and "\n" not in head:
                return            # a short head may still turn out to be a label ("Interviewer: ")
            self._buf = _LABEL.sub("", head, count=1)
            self._started = True
        while True:
            m = _BOUNDARY.search(self._buf)
            if not m:
                break
            self._push(self._buf[:m.start()] + self._buf[m.start():m.end()].strip())
            self._buf = self._buf[m.end():]
        if self._held is not None and self._buf.strip():
            self._send(self._held, False)
            self._held = None

    def close(self) -> str:
        if not self._started:
            self._buf = _LABEL.sub("", self._buf.lstrip(), count=1)
        tail = self._buf
        self._buf = ""
        if tail.strip():
            self._push(tail)
        if self._held is not None:
            self._send(self._held, True)
            self._held = None
        return " ".join(self.parts)


class SimRuntime:
    def __init__(self, transport: Transport, emitter: Emitter, config: SimConfig | None = None, *,
                 report_builder: ReportBuilder | None = None) -> None:
        self.transport = transport
        self.emitter = emitter
        self.config = config or SimConfig()
        self.report_builder = report_builder
        self.start_background = True
        self.stopped = asyncio.Event()
        self.finished = asyncio.Event()      # the interview is over and the report step has run
        self.tasks: set[asyncio.Task] = set()
        # session
        self.session_dir: Path | None = None
        self.sim: dict = {}
        self.pack = ""
        self.posting = ""
        self.system = ""
        self.lang = "en"
        self.ui_lang = "en"
        self.difficulty = "standard"
        self.mode = "realistic"
        self.voice = "text"
        self.from_session = False
        self.persona: dict | None = None
        self.started_at = ""
        self.evidence: dict[str, str] = {}
        # state
        self.records: list[QRec] = []
        self.blocks: list[str] = []          # one transcript block per finished question (append-only)
        self.cur: QRec | None = None
        self.candidate = {"text": "", "reply": ""}
        self.spend = 0.0
        self.last_call_mono = {HAIKU: 0.0, SONNET: 0.0}
        self._run_task: asyncio.Task | None = None
        self._line_seq = 0
        self._inbox: asyncio.Queue = asyncio.Queue()
        self._interrupt = asyncio.Event()
        self._action: str | None = None      # pending skip | end
        self._listening: str | None = None
        self._ending = False
        self._complete = False
        self._halted: str | None = None
        self._offline = False
        # silence prompt
        self._silence_task: asyncio.Task | None = None
        self._silence_done: set[str] = set()
        self._await_spoken: str | None = None
        self._spoken: set[str] = set()
        # speculative ASK
        self._questions: list[dict] = []
        self._pf: dict | None = None         # {"q_id", "line_id", "sentences": list[str] | None, "task"}
        self._ack_i = 0

    # ------------------------------------------------------------------ helpers
    def _spawn(self, coro) -> asyncio.Task:
        t = asyncio.get_running_loop().create_task(coro)
        self.tasks.add(t)
        t.add_done_callback(self.tasks.discard)
        return t

    def _status(self, state: str, message: str = "", **extra) -> None:
        self.emitter.status(state, message, **extra)

    def _metric(self, q_id: str, stage: str, **extra) -> None:
        self.emitter.metric(q_id, stage, **extra)

    def _next_line_id(self) -> str:
        self._line_seq += 1
        return f"s{self._line_seq}"

    def _fixed(self, key: str) -> str:
        """A fixed line in the interview language (English when that language has none)."""
        return FIXED_LINES.get(self.lang, FIXED_LINES["en"]).get(key) or FIXED_LINES["en"][key]

    # ------------------------------------------------------------------ dispatch
    async def handle(self, msg: dict) -> None:
        t = msg.get("type")
        if t == "sim_start":
            if self._run_task is None:
                self._run_task = self._spawn(self._run(msg))
            else:
                log.warning("second sim_start ignored")
        elif t == "answer":
            self._on_answer(msg)
        elif t == "control":
            a = msg.get("action")
            if a in ("skip", "end"):
                if self._action != "end":
                    self._action = a
                if a == "end":
                    self._drop_prefetch()
                self._interrupt.set()
            elif a == "repeat":
                self._inbox.put_nowait(("repeat", None))
            elif a == "stop":
                await self.stop()
        elif t == "spoken":
            self._on_spoken(str(msg.get("id", "")))
        elif t == "partial":
            # the app's live transcript of the candidate: they are talking, so the silence count restarts
            if self._listening is not None:
                self._arm_silence(self._listening, self.config.silence_s)
        # meeting messages (`start`, `turn`, `bank_hit`) have no meaning in a sim and are ignored

    def _on_answer(self, msg: dict) -> None:
        q_id = str(msg.get("q_id", ""))
        ans = {"text": str(msg.get("text", "")), "t_start": _float(msg.get("t_start")),
               "t_end": _float(msg.get("t_end")), "words": _int(msg.get("words")), "fillers": _int(msg.get("fillers"))}
        if self._listening is not None and q_id == self._listening:
            self._inbox.put_nowait(("answer", ans))
        elif self.cur is not None and q_id == self.cur.q_id:
            # the candidate kept talking after the app closed the answer: keep it in the transcript, no new turn
            self.cur.answers.append(ans)
            self.cur._lines.append(f"Candidate: {_clean(ans['text'])}")
            self._metric(q_id, "answer_while_busy")
        else:
            self._metric(q_id, "answer_ignored", listening=self._listening)

    def _take_action(self) -> str | None:
        a, self._action = self._action, None
        self._interrupt.clear()
        return a

    # ------------------------------------------------------------------ session
    def _load(self, msg: dict) -> None:
        p = Path(str(msg["session_dir"])).expanduser()
        self.session_dir = p
        self.sim = json.loads((p / "sim.json").read_text(encoding="utf-8"))
        self.pack = (p / "sim_pack.md").read_text(encoding="utf-8")
        text_path = ((self.sim.get("posting") or {}).get("text_path")) or "posting.txt"
        try:
            self.posting = (p / text_path).read_text(encoding="utf-8").strip()
        except OSError:
            self.posting = ""
        self.lang = str(self.sim.get("lang") or "en")
        # The app's interface language: only the report page's own words follow it (`sim_results.json` carries it to the renderer).
        ui = str(msg.get("ui_lang") or "en")
        self.ui_lang = ui if ui in ("en", "it", "tr") else "en"
        self.from_session = self.sim.get("source") == "session"
        self.mode = msg.get("mode") if msg.get("mode") in MODES else "realistic"
        self.voice = msg.get("voice") if msg.get("voice") in VOICES else "text"
        self.evidence = {str(e.get("id")): str(e.get("text", "")) for e in self.sim.get("evidence") or [] if e.get("id")}
        itype = self.sim.get("interview_type") if self.sim.get("interview_type") in TYPE_DESC else "mixed"
        diff = self.sim.get("difficulty") if self.sim.get("difficulty") in DIFF_DESC else "standard"
        self.difficulty = diff
        self.system = SYSTEM_TEMPLATE.format(type_desc=TYPE_DESC[itype], diff_desc=DIFF_DESC[diff])
        if self.from_session:       # a mock built from a prepared meeting: the competencies come from its pack, not a posting
            self.system = self.system.replace("the competencies the job posting asks for", "the competencies the prep pack points to")
        persona = self.sim.get("persona")
        self.persona = persona if isinstance(persona, dict) and persona.get("answer_target_s") else None
        if self.persona:            # opt-in: a sim without a persona keeps its system prompt byte for byte
            self.system += "\n\n" + persona_text(self.persona)

    def _request(self, route: str, max_tokens: int, tail: str) -> dict:
        req = route_params(route, max_tokens=max_tokens)
        req["system"] = [{"type": "text", "text": self.system}]
        content: list[dict] = [{"type": "text", "text": PACK_HEADER + self.pack + TRANSCRIPT_HEADER,
                                "cache_control": dict(EPHEMERAL)}]
        bp2 = bp2_index(len(self.blocks), self.config.bp2_every)
        for i, b in enumerate(self.blocks):
            blk = {"type": "text", "text": b}
            if i == bp2:
                blk["cache_control"] = dict(EPHEMERAL)
            content.append(blk)
        content.append({"type": "text", "text": tail})
        req["messages"] = [{"role": "user", "content": content}]
        return req

    # ------------------------------------------------------------------ warm transport
    async def _warm(self, model: str, kind: str, lane: int = 0) -> None:
        route = "S" if model == HAIKU else "D"
        req = self._request(route, 0, WARMUP_TAIL)
        self.last_call_mono[model] = time.monotonic()
        t0 = time.time()
        usage, _headers, stop = await self.transport.create(route, req, lane)
        cost = spend_usd(model, usage_obj(usage))
        self.spend += cost
        self.emitter.metric("", kind, model=model, usage=usage, stop_reason=stop,
                            ms=round((time.time() - t0) * 1000, 1), cost_usd=round(cost, 6))

    async def _prewarm(self) -> None:
        """Haiku (every question) is warmed with the sim prefix at once; Sonnet (only the candidate answer, at the
        end) gets its connections opened by pings now and its cache written when the closing question is asked."""
        self._status("warming", f"pre-warming {HAIKU} for the interview")
        last: Exception | None = None
        try:
            for attempt in range(self.config.prewarm_attempts):
                warm_lane, ping_lane = attempt % 2, (attempt + 1) % 2
                try:
                    await asyncio.wait_for(asyncio.gather(
                        self._warm(HAIKU, "prewarm", warm_lane), self._ping(HAIKU, ping_lane),
                        self._ping(SONNET, 0), self._ping(SONNET, 1)), timeout=self.config.prewarm_attempt_s)
                    last = None
                    break
                except (Offline, asyncio.TimeoutError) as e:
                    last = e
                    if attempt + 1 < self.config.prewarm_attempts:
                        self._status("warming", f"pre-warm attempt {attempt + 1} stalled ({type(e).__name__}); "
                                                f"retrying on lane {(attempt + 1) % 2}")
            if last is not None:
                raise Offline(f"{type(last).__name__} after {self.config.prewarm_attempts} attempts")
        except Offline as e:
            self._offline = True
            self._status("offline", f"pre-warm failed: {e}")
        except TransportError as e:
            self._on_error("prewarm", e)
        else:
            self._status("ready", f"warm; spend so far ${self.spend:.4f}")

    async def _ping(self, model: str, lane: int) -> None:
        await self.transport.ping(model, lane)

    async def _background(self) -> None:
        """Keep the HTTP/2 connections and the Haiku cache warm through long answers and coach pauses."""
        cfg = self.config
        while not self.stopped.is_set() and not self.finished.is_set():
            await asyncio.sleep(cfg.ping_every_s)
            if self._halted:
                continue
            try:
                await asyncio.gather(*(self._ping(m, lane) for m in (HAIKU, SONNET) for lane in (0, 1)))
                if self._offline:
                    self._offline = False
                    self._status("ready", "back online")
                if time.monotonic() - self.last_call_mono[HAIKU] >= cfg.keepalive_idle_s:
                    await self._warm(HAIKU, "keepalive")
            except Offline:
                if not self._offline:
                    self._offline = True
                    self._status("offline", "ping failed")
            except TransportError as e:
                log.warning("sim keep-alive failed: %s", e)

    # ------------------------------------------------------------------ model calls
    def _on_error(self, task: str, e: TransportError) -> None:
        log.warning("sim %s call failed: %s", task, e)
        if isinstance(e, CreditExhausted):
            if self._halted is None:
                self._halted = "credit_exhausted"
                self._status("credit_exhausted", "Max API credit used up")
        elif isinstance(e, AuthFailed):
            if self._halted is None:
                self._halted = "auth"
                self._status("error", f"API key rejected ({e})")
        elif isinstance(e, Offline):
            if not self._offline:
                self._offline = True
                self._status("offline", f"{task}: network error")
        elif isinstance(e, RateLimited):
            self._status("rate_limited", f"{task}: 429 from the API")
        else:
            self._status("error", f"{task}: {e.kind}: {e}")

    async def _call(self, task: str, q_id: str, route: str, max_tokens: int, tail: str,
                    on_text: Callable[[str], None]) -> str | None:
        """One streamed call with hedging (lane 1 after `hedge_after_s` without a first byte) and one retry on
        429/529 before any text. Returns the stop reason, or raises TransportError."""
        if self._halted:
            raise TransportError(f"halted: {self._halted}")
        req = self._request(route, max_tokens, tail)
        model = req["model"]
        self.last_call_mono[model] = time.monotonic()
        usage: dict = {}
        stop: list[str | None] = [None]
        seen_text = [False]
        t0 = time.monotonic()
        t_first: list[float] = []

        def text(chunk: str) -> None:
            if not seen_text[0]:
                seen_text[0] = True
                t_first.append(time.monotonic())
            on_text(chunk)

        retries = 1
        try:
            while True:
                try:
                    await self._hedged(route, req, usage, stop, text)
                    break
                except (RateLimited, Overloaded) as e:
                    wait = e.retry_after if isinstance(e, RateLimited) and e.retry_after is not None else 0.5
                    if retries <= 0 or seen_text[0] or wait > self.config.retry_max_wait_s:
                        raise
                    retries -= 1
                    await asyncio.sleep(wait)
        finally:
            cost = spend_usd(model, usage_obj(usage)) if usage else 0.0
            self.spend += cost
            self._metric(q_id, "sim_call", task=task, model=model, stop_reason=stop[0], usage=usage,
                         first_text_ms=round((t_first[0] - t0) * 1000, 1) if t_first else None,
                         ms=round((time.monotonic() - t0) * 1000, 1), cost_usd=round(cost, 6))
        return stop[0]

    async def _hedged(self, route: str, req: dict, usage: dict, stop: list, on_text: Callable[[str], None]) -> None:
        winner: list[int] = []
        first = asyncio.Event()
        tasks: dict[int, asyncio.Task] = {}

        async def attempt(lane: int) -> None:
            stream = await self.transport.open_stream(route, req, lane)
            try:
                async for ev in stream:
                    if not winner:
                        winner.append(lane)
                        first.set()
                        for other, t in tasks.items():
                            if other != lane and not t.done():
                                t.cancel()
                    elif winner[0] != lane:
                        return
                    if ev.kind == "start":
                        usage.update(ev.usage)
                    elif ev.kind == "text":
                        on_text(ev.text)
                    elif ev.kind == "stop":
                        usage.update(ev.usage)
                        stop[0] = ev.stop_reason
            finally:
                await stream.aclose()

        loop = asyncio.get_running_loop()
        hedge_after = self.config.hedge_after_s_d if route == "D" else self.config.hedge_after_s
        tasks[0] = loop.create_task(attempt(0))
        try:
            waiter = loop.create_task(first.wait())
            try:
                await asyncio.wait({waiter, tasks[0]}, timeout=hedge_after, return_when=asyncio.FIRST_COMPLETED)
            finally:
                waiter.cancel()
            if not first.is_set() and not tasks[0].done():
                tasks[1] = loop.create_task(attempt(1))
            results = await asyncio.gather(*tasks.values(), return_exceptions=True)
        finally:
            for t in tasks.values():
                if not t.done():
                    t.cancel()
        by_lane = dict(zip(tasks.keys(), results))
        if winner:
            r = by_lane[winner[0]]
            if isinstance(r, BaseException) and not isinstance(r, asyncio.CancelledError):
                raise r
            return
        errs = [r for r in results if isinstance(r, TransportError)]
        if errs:
            raise errs[0]
        others = [r for r in results if isinstance(r, BaseException) and not isinstance(r, asyncio.CancelledError)]
        if others:
            raise TransportError(type(others[0]).__name__)

    async def _interruptible(self, coro):
        """Run `coro`; a `skip`/`end` arriving meanwhile cancels it and raises _Interrupted."""
        if self._action is not None:
            coro.close()
            raise _Interrupted()
        task = asyncio.get_running_loop().create_task(coro)
        intr = asyncio.get_running_loop().create_task(self._interrupt.wait())
        try:
            done, _ = await asyncio.wait({task, intr}, return_when=asyncio.FIRST_COMPLETED)
        finally:
            intr.cancel()
        if task in done:
            return task.result()
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        raise _Interrupted()

    # ------------------------------------------------------------------ lines
    def _say_events(self, line_id: str) -> Callable[[str, bool], None]:
        def emit(sentence: str, final: bool) -> None:
            self.emitter.emit({"type": "say", "id": line_id, "text": sentence, "final": final})
        return emit

    def _say_fixed(self, text: str) -> str:
        """Say a known line (no model call), sentence by sentence. Returns its line id."""
        line_id = self._next_line_id()
        s = _Sentences(self._say_events(line_id))
        s.feed(text)
        s.close()
        self._await_spoken = line_id
        return line_id

    def _record_line(self, rec: QRec, line_id: str, text: str, kind: str) -> None:
        rec.asked.append({"id": line_id, "text": text, "kind": kind})
        rec._lines.append(f"Interviewer: {text}")

    async def _say_model(self, task: str, q_id: str, route: str, max_tokens: int, tail: str,
                         fallback: str | None) -> tuple[str | None, str]:
        """Stream a model line as `say` sentences. On failure before any sentence, say `fallback` (if given).
        Returns (line_id or None, text)."""
        line_id = self._next_line_id()
        s = _Sentences(self._say_events(line_id))
        try:
            await self._call(task, q_id, route, max_tokens, tail, s.feed)
        except TransportError as e:
            self._on_error(task, e)
        text = s.close()
        if not text:
            if fallback is None:
                return None, ""
            s = _Sentences(self._say_events(line_id))
            s.feed(fallback)
            text = s.close()
        self._await_spoken = line_id
        return line_id, text

    # ------------------------------------------------------------------ listen + silence
    def _estimate_playback(self, line_id: str | None, text: str) -> float:
        if line_id is None or line_id in self._spoken:
            return 0.0
        return len(text.split()) / max(self.config.playback_wps, 0.01)

    def _arm_silence(self, q_id: str, delay: float) -> None:
        if self._silence_task is not None and not self._silence_task.done():
            self._silence_task.cancel()
        self._silence_task = None
        if q_id in self._silence_done:
            return
        self._silence_task = self._spawn(self._silence_after(q_id, delay))

    async def _silence_after(self, q_id: str, delay: float) -> None:
        await asyncio.sleep(delay)
        if self._listening != q_id or q_id in self._silence_done:
            return
        self._silence_done.add(q_id)
        self._metric(q_id, "silence_prompt", after_s=round(delay, 2))
        self._say_fixed(self._fixed("silence"))
        self._await_spoken = None          # the count does not restart: one prompt per question
        self.emitter.emit({"type": "listen", "q_id": q_id})

    def _on_spoken(self, line_id: str) -> None:
        self._spoken.add(line_id)
        if self._listening is not None and line_id == self._await_spoken:
            self._arm_silence(self._listening, self.config.silence_s)

    async def _listen(self, q_id: str, last_id: str | None, last_text: str) -> tuple[str, dict | None]:
        """Emit `listen` and wait for ("answer", msg) | ("repeat", None) | ("skip"|"end", None)."""
        a = self._take_action() if self._action else None
        if a:
            return a, None
        self._listening = q_id
        self.emitter.emit({"type": "listen", "q_id": q_id})
        self._arm_silence(q_id, self.config.silence_s + self._estimate_playback(last_id, last_text))
        loop = asyncio.get_running_loop()
        try:
            while True:
                get = loop.create_task(self._inbox.get())
                intr = loop.create_task(self._interrupt.wait())
                try:
                    done, _ = await asyncio.wait({get, intr}, return_when=asyncio.FIRST_COMPLETED)
                finally:
                    intr.cancel()
                    if not get.done():
                        get.cancel()
                if get in done and not get.cancelled():
                    kind, payload = get.result()
                    return kind, payload
                a = self._take_action()
                if a:
                    return a, None
        finally:
            self._listening = None
            if self._silence_task is not None and not self._silence_task.done():
                self._silence_task.cancel()

    def _drain_inbox(self) -> None:
        """A new question starts clean: a `repeat` pressed during the previous question's coach note or judge
        belongs to that question. (A `repeat` that arrives while this question's line is being said stays queued
        and its listen picks it up.)"""
        while not self._inbox.empty():
            self._inbox.get_nowait()

    # ------------------------------------------------------------------ tasks (tails)
    def _lang(self) -> str:
        return LANG_NAME.get(self.lang, self.lang)

    def _q_head(self, q: dict) -> str:
        return f"QUESTION [{q.get('id')}] ({q.get('kind', 'question')}): {_clean(str(q.get('text', '')))}"

    def ask_tail(self, q: dict, index: int, total: int, speculative: bool = False) -> str:
        lines = ["TASK: ASK", f"Language: {self._lang()}", f"This is question {index} of {total}.", self._q_head(q)]
        if speculative:
            # written while the candidate is still answering the previous question: it must not depend on that answer
            lines.append("Do not refer to the candidate's previous answer; start with the question itself. The system puts a "
                         "short acknowledgement in front of your line, so do not write one: no \"Thanks\", no bridge.")
        elif index == 1:
            company = self.sim.get("company") or "the company"
            role = self.sim.get("role") or "this role"
            lines.append(f"This is the start of the interview: greet the candidate in one short sentence and say you "
                         f"are interviewing them for the {role} role at {company}, then ask the question.")
            if self.persona and self.persona.get("name"):
                lines.append(f"Introduce yourself by the name {self.persona['name']} in that greeting.")
        else:
            lines.append("You may open with a brief bridge of a few words (for example \"Thanks.\" or \"Let's move "
                         "on.\"), but never judge or summarise the previous answer.")
        lines.append("Say this planned question to the candidate in your own words, as your next spoken line: 1 to 3 "
                     "short sentences, at most 50 words in total. Keep its meaning and scope, ask only this one "
                     "question, do not answer it and do not hint at what a good answer contains.")
        return "\n".join(lines)

    def judge_tail(self, q: dict, rec: QRec, followups: int, push_ok: bool, vague: list[str]) -> str:
        hooks = q.get("follow_ups") or []
        ev = ", ".join(q.get("evidence_ids") or []) or "none planned"
        lines = ["TASK: JUDGE", f"Language: {self._lang()}", f"Question {q.get('id')} ({q.get('kind', 'question')}): "
                 f"{_clean(str(q.get('text', '')))}",
                 "Follow-up hooks:" + ("".join(f"\n- {_clean(str(h))}" for h in hooks) if hooks else " none"),
                 f"Evidence a strong answer would use: {ev} (in the SIM PACK; the candidate cannot see it)",
                 f"Follow-ups asked so far for this question: {followups} of {self.config.max_followups}",
                 "THIS QUESTION SO FAR:", rec.exchange()]
        if push_ok:
            lines.append(f"ANSWER CHECK: the last answer is vague ({', '.join(vague)}).")
        lines.append("Decide the interviewer's next move. Write exactly one line and nothing else, one of:")
        lines.append("FOLLOW: <one follow-up question in spoken style, at most 30 words>")
        if push_ok:
            lines.append("PUSH: <a short, direct challenge asking for the number, what the candidate did personally, "
                         "or the specifics, at most 20 words>")
        lines.append("NEXT")
        rules = ["Write FOLLOW when the answer left out something the question or a follow-up hook asks for and a real "
                 "interviewer would ask about it."]
        if push_ok:
            rules.append("Write PUSH when the answer stays vague where the question needs specifics.")
        rules.append("Write NEXT when the answer is complete enough for this interview, the candidate said they have "
                     "nothing to add, or another follow-up would repeat one already asked.")
        rules.append("If the candidate asked to hear the question again or asked what you mean, write FOLLOW: with the "
                     "question said again in simpler words.")
        rules.append("Never answer for the candidate and never give feedback.")
        lines.append(" ".join(rules))
        return "\n".join(lines)

    def coach_tail(self, q: dict, rec: QRec) -> str:
        ids = [i for i in (q.get("evidence_ids") or []) if i in self.evidence]
        ev = ", ".join(f"[{i}]" for i in ids) if ids else \
            "none planned (use any evidence item in the SIM PACK that fits, or none)"
        return "\n".join([
            "TASK: COACH", f"Language: {self._lang()}",
            f"Question {q.get('id')} ({q.get('kind', 'question')}): {_clean(str(q.get('text', '')))}",
            f"Competencies: {', '.join(q.get('competency_ids') or []) or 'none'}",
            f"Evidence the candidate could have used: {ev}",
            "THIS QUESTION:", rec.exchange(),
            f"Step out of the interviewer role for this task. Write 2 or {self.config.coach_max_lines} coaching lines "
            "for the candidate, each starting with \"- \", at most 25 words each, addressed to the candidate as "
            "\"you\": what worked, what was missing, and one better sentence they could have said. Build the better "
            "sentence only from the candidate's evidence in the SIM PACK and their own answer, and cite each "
            "evidence item you use in square brackets with its id, for example [e2]. Use only ids that exist in the "
            "SIM PACK. Use a number only when it appears in a cited evidence item or in the candidate's answer. "
            "Nothing else: no heading, no preamble." + self._voice_note()])

    def _voice_note(self) -> str:
        """The pack's STYLE GUIDE section (prep/voice.py) describes how the candidate talks. The coach's "better sentence"
        follows it; the generic style rules stay here. Empty for a pack without one."""
        if not any(ln.startswith(VOICE_HEADING) for ln in self.pack.splitlines()):
            return ""
        return (" Write the better sentence the way the candidate talks, in the style of the STYLE GUIDE section of the "
                "SIM PACK (tone, level, phrasing); it changes the wording only, not the evidence, the numbers or the length "
                "limit, and is never cited.")

    def answer_tail(self, question: str) -> str:
        posting = self.posting or "(not available)"
        what = "PREP PACK of the meeting" if self.from_session else "JOB POSTING"
        return "\n".join([
            "TASK: ANSWER", f"Language: {self._lang()}",
            f"{what} (the only source for facts about the company, the team, the role and the process):",
            '"""', posting, '"""',
            f"The candidate asked: {_clean(question)}",
            "Reply as the interviewer in 2 to 4 short spoken sentences, at most 70 words, then stop. Use only facts "
            f"from the {'prep pack' if self.from_session else 'job posting'} above; when it does not cover the question, say so plainly and say the team will "
            "follow up. Do not invent names, numbers, salaries or dates. If the candidate has no question, reply with "
            "one short friendly sentence."])

    # ------------------------------------------------------------------ coach validation
    def check_coach(self, raw: str, rec: QRec) -> list[str]:
        """Keep up to `coach_max_lines` lines whose citations are all pack evidence ids and whose numbers appear in a
        cited evidence item or in the candidate's answers for this question."""
        answers = " ".join(a["text"] for a in rec.answers)
        out: list[str] = []
        for ln in raw.splitlines():
            s = ln.strip().lstrip("-•*").strip()
            if not s:
                continue
            ids = [x.strip() for m in _CITE.findall(s) for x in m.split(",") if x.strip()]
            if any(i not in self.evidence for i in ids):
                self._metric(rec.q_id, "coach_line_dropped", reason="unknown_evidence", ids=ids)
                continue
            allowed = _numbers(answers)
            for i in ids:
                allowed |= _numbers(self.evidence[i])
            nums = _numbers(_CITE.sub("", s))
            if nums - allowed:
                self._metric(rec.q_id, "coach_line_dropped", reason="ungrounded_number",
                             numbers=sorted(nums - allowed))
                continue
            out.append(s)
            if len(out) >= self.config.coach_max_lines:
                break
        return out

    # ------------------------------------------------------------------ the interview
    async def _run(self, msg: dict) -> None:
        try:
            self._load(msg)
        except (OSError, KeyError, ValueError, TypeError) as e:
            self._status("error", f"cannot read sim session folder: {type(e).__name__}")
            self.finished.set()
            return
        self.started_at = now_iso()
        questions = [q for q in self.sim.get("questions") or [] if isinstance(q, dict) and q.get("id")]
        if not questions:
            self._status("error", "the sim pack has no questions")
            self.finished.set()
            return
        self._questions = questions
        await self._prewarm()
        if self.start_background:
            self._spawn(self._background())
        try:
            for i, q in enumerate(questions, 1):
                if self._ending:
                    break
                await self._question(q, i, len(questions))
                self._write_results()
            if not self._ending:
                await self._candidate_phase()
            self._take_action()
            self._say_fixed(self._fixed("close_early" if self._ending else "close"))
            self._complete = True
            self._write_results()
            await self._report()
        finally:
            self._drop_prefetch()
            self.finished.set()

    async def _question(self, q: dict, index: int, total: int) -> None:
        cfg = self.config
        rec = self.cur = QRec(str(q["id"]))
        self.records.append(rec)
        self._drain_inbox()
        self.emitter.emit({"type": "sim_progress", "q_index": index, "q_total": total})
        planned = _clean(str(q.get("text", "")))
        coaching = False
        try:
            line_id, text = await self._interruptible(self._open_line(q, index, total, planned))
            self._record_line(rec, line_id, text, "question")
            followups = 0
            first_listen = True
            while True:
                if first_listen:
                    first_listen = False
                    self._start_prefetch(index, total)     # runs while the candidate answers; `listen` goes out first
                kind, payload = await self._listen(rec.q_id, line_id, text)
                if kind == "skip":
                    rec.skipped = True
                    break
                if kind == "end":
                    self._ending = True
                    break
                if kind == "repeat":
                    last = rec.asked[-1]["text"]
                    line_id, text = self._say_fixed(last), last
                    self._record_line(rec, line_id, last, "repeat")
                    continue
                rec.answers.append(payload)
                rec._lines.append(f"Candidate: {_clean(payload['text'])}")
                if followups >= cfg.max_followups:
                    break
                move = await self._interruptible(self._judge(q, rec, followups))
                if move is None:
                    break
                line_id, text, kind = move
                self._record_line(rec, line_id, text, kind)
                followups += 1
            if self.persona and not rec.skipped and not self._ending and rec.answers:
                rec.checks = answer_checks(rec.answers, q.get("target_s") or self.persona["answer_target_s"],
                                           evidence=self.sim.get("evidence") or [], source_text=self.posting, lang=self.lang)
            if self.mode == "coach" and not rec.skipped and not self._ending and rec.answers:
                coaching = True
                await self._interruptible(self._coach(q, rec))
        except _Interrupted:
            a = self._take_action()
            if a == "end":
                self._ending = True
            elif not coaching:      # a skip during the coach note only drops the note; the question was answered
                rec.skipped = True
        finally:
            self.blocks.append(self._block(q, rec))
            self.cur = None

    # ------------------------------------------------------------------ speculative ASK
    async def _open_line(self, q: dict, index: int, total: int, planned: str) -> tuple[str, str]:
        """Say the question: the prefetched line when there is one for it, else the normal ASK. Returns (line_id, text)."""
        pf, self._pf = self._pf, None
        if pf is not None and pf["q_id"] == str(q["id"]):
            pf["claimed"] = True        # a call still running is awaited below; its line is then said, not announced
            task = pf["task"]
            if pf["sentences"] is None and task is not None and not task.done():
                await asyncio.wait({task}, timeout=self.config.prefetch_wait_s)
                if not task.done():
                    pf["dropped"] = True
                    task.cancel()
                    self._metric(pf["q_id"], "prefetch_timeout")
            if pf["sentences"]:
                sentences = pf["sentences"]
                emit = self._say_events(pf["line_id"])
                for k, sentence in enumerate(sentences):
                    emit(sentence, k == len(sentences) - 1)
                self._await_spoken = pf["line_id"]
                self._metric(pf["q_id"], "prefetch_used", line_id=pf["line_id"])
                return pf["line_id"], " ".join(sentences)
        elif pf is not None:
            self._abandon(pf)
        return await self._say_model("ASK", str(q["id"]), "S", self.config.ask_max_tokens,
                                     self.ask_tail(q, index, total), planned)

    def _start_prefetch(self, index: int, total: int) -> None:
        """At the first `listen` of planned question `index` (1-based): start the next planned question's line."""
        if (not self.config.prefetch or index >= total or self._pf is not None or self._ending or self._action is not None
                or index >= len(self._questions)):
            return
        nq = self._questions[index]
        pf = {"q_id": str(nq["id"]), "line_id": self._next_line_id(), "sentences": None, "task": None}
        self._pf = pf
        pf["task"] = self._spawn(self._prefetch_run(pf, nq, index + 1, total))

    async def _prefetch_run(self, pf: dict, nq: dict, index: int, total: int) -> None:
        acks = ACK_LINES.get(self.lang, ACK_LINES["en"])
        ack = acks[self._ack_i % len(acks)]
        self._ack_i += 1
        sent = _Sentences(lambda _s, _final: None)
        try:
            await self._call("ASK_PREFETCH", pf["q_id"], "S", self.config.ask_max_tokens,
                             self.ask_tail(nq, index, total, speculative=True), sent.feed)
        except TransportError as e:
            log.warning("speculative ASK failed: %s", e)
            self._metric(pf["q_id"], "prefetch_failed", error=type(e).__name__)
            return
        if not sent.close():
            self._metric(pf["q_id"], "prefetch_failed", error="empty")
            return
        if pf.get("dropped") or self._ending or self._action == "end" or self.stopped.is_set():
            return
        pf["sentences"] = [ack, *sent.parts]
        if pf.get("claimed"):
            return                  # the question is already waiting for this line: it is said at once, no announcement
        self.emitter.emit({"type": "say_prefetch", "id": pf["line_id"], "q_id": pf["q_id"], "sentences": list(pf["sentences"])})
        self._metric(pf["q_id"], "prefetch_ready", line_id=pf["line_id"])

    @staticmethod
    def _abandon(pf: dict) -> None:
        pf["dropped"] = True
        if pf["task"] is not None and not pf["task"].done():
            pf["task"].cancel()

    def _drop_prefetch(self) -> None:
        pf, self._pf = self._pf, None
        if pf is not None:
            self._abandon(pf)

    def _block(self, q: dict, rec: QRec) -> str:
        body = rec.exchange() if rec._lines else "(not asked)"
        if rec.skipped:
            body += "\nCandidate: (skipped this question)"
        return f"[{rec.q_id}] {_clean(str(q.get('text', '')))}\n{body}"

    async def _judge(self, q: dict, rec: QRec, followups: int) -> tuple[str, str, str] | None:
        """One JUDGE call. Returns (line_id, text, kind) for a FOLLOW/PUSH that was said, None for NEXT."""
        last = rec.answers[-1]["text"] if rec.answers else ""
        vague = is_vague(last)
        push_ok = self.difficulty == "tough" and bool(vague)
        line_id = self._next_line_id()
        sent = _Sentences(self._say_events(line_id))
        head = {"buf": "", "move": None, "done": False}

        def on_text(chunk: str) -> None:
            if head["done"]:
                return
            if head["move"] is None:
                head["buf"] += chunk
                b = head["buf"].lstrip()
                for tag in ("FOLLOW:", "PUSH:", "NEXT"):
                    if b.upper().startswith(tag):
                        head["move"] = tag.rstrip(":")
                        rest = b[len(tag):]
                        break
                else:
                    if len(b) >= 8 or "\n" in b:
                        head["move"] = "?"
                    return
                if head["move"] in ("NEXT", "?"):
                    head["done"] = True
                    return
                chunk = rest
            if "\n" in chunk:
                chunk = chunk.split("\n", 1)[0]
                head["done"] = True
            if chunk:
                sent.feed(chunk)

        try:
            await self._call("JUDGE", rec.q_id, "S", self.config.judge_max_tokens,
                             self.judge_tail(q, rec, followups, push_ok, vague), on_text)
        except TransportError as e:
            self._on_error("JUDGE", e)
        text = sent.close()
        move = head["move"]
        self._metric(rec.q_id, "judge", move=move, push_ok=push_ok, vague=vague)
        if move not in ("FOLLOW", "PUSH") or not text:
            return None
        self._await_spoken = line_id
        kind = "push" if move == "PUSH" and push_ok else "follow_up"
        return line_id, text, kind

    async def _coach(self, q: dict, rec: QRec) -> None:
        buf: list[str] = []
        failed = False
        try:
            await self._call("COACH", rec.q_id, "S", self.config.coach_max_tokens, self.coach_tail(q, rec), buf.append)
        except TransportError as e:
            self._on_error("COACH", e)
            failed = True
        lines = [] if failed else self.check_coach("".join(buf), rec)
        if lines:
            rec.coach = lines
        shown = lines + (check_lines(rec.checks) if rec.checks else [])     # the persona's checks ride the same coach note
        if shown:
            self.emitter.emit({"type": "coach", "q_id": rec.q_id, "lines": shown})

    async def _candidate_phase(self) -> None:
        cfg = self.config
        self._drain_inbox()
        warm = self._spawn(self._warm_sonnet())   # writes the Sonnet cache while the candidate speaks
        cq = self._fixed("candidate_q")
        line_id = self._say_fixed(cq)
        last_id, last_text = line_id, cq
        try:
            while True:
                kind, payload = await self._listen(CANDIDATE_Q_ID, last_id, last_text)
                if kind == "repeat":
                    last_id = self._say_fixed(cq)
                    continue
                if kind in ("skip", "end"):
                    return
                break
            self.candidate["text"] = payload["text"]
            if not warm.done():
                await asyncio.wait({warm}, timeout=cfg.answer_warm_wait_s)
            _lid, reply = await self._interruptible(self._say_model(
                "ANSWER", CANDIDATE_Q_ID, "D", cfg.answer_max_tokens, self.answer_tail(payload["text"]),
                self._fixed("answer_fallback")))
            self.candidate["reply"] = reply
        except _Interrupted:
            self._take_action()

    async def _warm_sonnet(self) -> None:
        try:
            await asyncio.wait_for(self._warm(SONNET, "prewarm"), timeout=self.config.prewarm_attempt_s)
        except (TransportError, asyncio.TimeoutError) as e:
            log.warning("sonnet pre-warm failed: %s", type(e).__name__)

    # ------------------------------------------------------------------ results / report
    def results(self) -> dict:
        out = {"session_id": str(self.sim.get("session_id") or (self.session_dir.name if self.session_dir else "")),
               "mode": self.mode, "voice": self.voice, "started_at": self.started_at or now_iso(),
               "ended_at": now_iso(), "questions": [r.as_dict() for r in self.records],
               "candidate_question": dict(self.candidate), "usage_usd": float(round(self.spend, 6))}
        if self.ui_lang != "en":
            out["ui_lang"] = self.ui_lang      # the report renderer picks its headings by it; absent means English
        return out

    def _write_results(self) -> Path | None:
        if self.session_dir is None or not self.started_at:
            return None
        path = self.session_dir / RESULTS_FILE
        tmp = path.with_name("." + RESULTS_FILE + ".tmp")
        try:
            tmp.write_text(json.dumps(self.results(), ensure_ascii=False, indent=1), encoding="utf-8")
            os.replace(tmp, path)
        except OSError as e:
            self._status("error", f"cannot write {RESULTS_FILE}: {type(e).__name__}")
            return None
        return path

    async def _report(self) -> None:
        builder = self.report_builder
        if builder is None:
            try:
                from ..sim.report import build_report as builder   # S5's contract
            except ImportError as e:
                self._status("error", f"report builder unavailable ({type(e).__name__}: verse_brain.sim.report)")
                return
        try:
            path = await builder(self.session_dir, self.transport, model=SONNET)
        except Exception as e:  # noqa: BLE001 - the interview is over; a report problem must not lose it
            log.exception("report failed")
            self._status("error", f"report failed: {type(e).__name__}")
            return
        self.emitter.emit({"type": "sim_report", "path": str(path)})

    # ------------------------------------------------------------------ stop / shutdown
    async def stop(self) -> None:
        await self.shutdown()

    async def shutdown(self) -> None:
        if self.stopped.is_set():
            return
        self.stopped.set()
        if self._run_task is not None and not self._run_task.done():
            self._run_task.cancel()
        for t in list(self.tasks):
            if not t.done():
                t.cancel()
        await asyncio.gather(*list(self.tasks), return_exceptions=True)
        if not self._complete:
            self._write_results()       # the transcript so far; no report
        await self.transport.aclose()


def _clean(s: str) -> str:
    return " ".join(s.split())


def _float(v) -> float:
    try:
        return float(v) if not isinstance(v, bool) else 0.0
    except (TypeError, ValueError):
        return 0.0


def _int(v) -> int:
    try:
        return int(v) if not isinstance(v, bool) else 0
    except (TypeError, ValueError):
        return 0


# ---------------------------------------------------------------------- `--fake` transport responses for a sim
_FAKE_Q = re.compile(r"^QUESTION \[[^\]]*\] \([^)]*\): (.*)$", re.MULTILINE)


def sim_fake_responder(info: CallInfo) -> Script:
    """Canned sim output for `--fake` runs (no network): plausible lines per task, never meeting-format lines.
    Non-sim requests get the meeting runtime's canned answers."""
    tail = info.tail
    if tail.startswith("TASK: ASK"):
        m = _FAKE_Q.search(tail)
        return lines_script(("Thanks. " + m.group(1)) if m else "Thanks. Tell me about your last project.")
    if tail.startswith("TASK: JUDGE"):
        return lines_script("NEXT")
    if tail.startswith("TASK: COACH"):
        return lines_script("- You answered the question directly.\n- Add one concrete result next time.")
    if tail.startswith("TASK: ANSWER"):
        return lines_script("Good question. The posting gives the outline; the team can tell you more.")
    from .fake import default_responder
    return default_responder(info)
