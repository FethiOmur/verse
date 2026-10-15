"""Report data (`report.json`) and its deterministic HTML page (`report.html`).

`assemble` merges `sim.json`, `sim_results.json` and the validated grades into one dict; `render_html` turns that dict
into a self-contained page. Neither reads the clock or the environment, so equal input gives equal bytes.
"""

from __future__ import annotations

from datetime import datetime
from html import escape

from ..prep.model import PRICES, Usage, spend_usd
from . import delivery
from .templates.styles import CSS

MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
LENGTH_WORDS = {"short": "shorter than the target", "on_target": "on target", "long": "longer than the target"}


def _fillers(answers: list[dict], lang: str) -> int:
    if lang in delivery.FILLERS:
        return sum(delivery.filler_count(a.get("text", ""), lang) for a in answers)
    return sum(int(a.get("fillers") or 0) for a in answers)


def _question_delivery(answers: list[dict], target_s, lang: str) -> dict:
    secs = delivery.answer_seconds(answers)
    return {"seconds": secs, "words": delivery.word_total(answers), "wpm": delivery.wpm(answers),
            "fillers": _fillers(answers, lang), "longest_pause_s": delivery.longest_pause(answers),
            "target_s": target_s, "length": delivery.length_status(secs, target_s)}


def _usage(usage: dict, model: str) -> dict:
    u = Usage(input=int(usage.get("input_tokens", 0) or 0), output=int(usage.get("output_tokens", 0) or 0),
              cache_read=int(usage.get("cache_read_input_tokens", 0) or 0),
              cache_write=int(usage.get("cache_creation_input_tokens", 0) or 0))
    out = u.as_dict()
    out["cost_usd"] = round(spend_usd(model, u), 6) if model in PRICES else None
    return out


def assemble(sim: dict, results: dict, grades: dict | None, *, error: str | None, usage: dict,
             model: str = "claude-sonnet-5-5") -> dict:
    lang = sim.get("lang", "en")
    planned = {q["id"]: q for q in sim.get("questions", [])}
    evidence = {e["id"]: e for e in sim.get("evidence", [])}
    g_by_q = {q["q_id"]: q for q in (grades or {}).get("questions", [])}

    questions = []
    all_answers: list[dict] = []
    pauses = [0.0]
    for rq in results.get("questions", []):
        qid = rq.get("q_id", "")
        pq = planned.get(qid, {})
        answers = rq.get("answers", [])
        all_answers += answers
        d = _question_delivery(answers, pq.get("target_s"), lang)
        pauses.append(d["longest_pause_s"])
        g = None
        if grades is not None and qid in g_by_q:
            src = g_by_q[qid]
            g = {"strong": src["strong"], "missing": src["missing"], "better_answer": [
                {"sentence": b["sentence"], "evidence_ids": b["evidence_ids"],
                 "sources": [{"id": eid, **s} for eid in b["evidence_ids"] for s in evidence[eid].get("sources", [])]}
                for b in src["better_answer"]]}
        questions.append({
            "q_id": qid, "kind": pq.get("kind", ""), "planned_text": pq.get("text", ""),
            "asked": [{"text": a.get("text", ""), "kind": a.get("kind", "question")} for a in rq.get("asked", [])],
            "answers": [{"text": a.get("text", ""),
                         "seconds": round(max(0.0, float(a.get("t_end", 0)) - float(a.get("t_start", 0))), 1)}
                        for a in answers],
            "skipped": bool(rq.get("skipped")), "coach": list(rq.get("coach", [])),
            "delivery": d, "grade": g})

    answered = sum(1 for q in questions if q["answers"])
    skipped = sum(1 for q in questions if q["skipped"])
    secs = delivery.answer_seconds(all_answers)
    total_delivery = {"seconds": secs, "words": delivery.word_total(all_answers), "wpm": delivery.wpm(all_answers),
                      "fillers": _fillers(all_answers, lang), "longest_pause_s": max(pauses),
                      "questions_answered": answered, "questions_skipped": skipped, "questions_total": len(questions)}

    no_evidence = not sim.get("evidence")
    warnings = list(sim.get("warnings", []))
    if no_evidence:
        warnings.append("Answers could not be checked against your background: this interview was built without an "
                        "experience source, so no suggested answers are shown.")
    not_asked = [q["id"] for q in sim.get("questions", []) if q["id"] not in {x["q_id"] for x in questions}]
    if not_asked:
        warnings.append(f"{len(not_asked)} planned question{'s were' if len(not_asked) != 1 else ' was'} not asked "
                        f"({', '.join(not_asked)}).")
    if grades and grades.get("dropped_sentences"):
        n = grades["dropped_sentences"]
        warnings.append(f"{n} suggested sentence{'s were' if n != 1 else ' was'} removed because they used numbers "
                        "your evidence does not contain.")

    comps = []
    for c in sim.get("competencies", []):
        gc = (grades or {}).get("competencies", {}).get(c["id"])
        if gc:
            comps.append({"id": c["id"], "name": c["name"], "posting_quote": c.get("posting_quote", ""), **gc})

    return {
        "session_id": sim.get("session_id", ""), "company": sim.get("company", ""), "role": sim.get("role", ""),
        "interview_type": sim.get("interview_type", ""), "difficulty": sim.get("difficulty", ""), "lang": lang,
        "mode": results.get("mode", ""), "voice": results.get("voice", ""),
        "started_at": results.get("started_at", ""), "ended_at": results.get("ended_at", ""),
        "graded": grades is not None, "grading_error": None if grades is not None else (error or "unknown error"),
        "overall": (grades or {}).get("overall"), "competencies": comps, "questions": questions,
        "delivery": total_delivery, "practise_next": list((grades or {}).get("practise_next", [])),
        "candidate_question": results.get("candidate_question"), "warnings": warnings, "no_evidence": no_evidence,
        "usage": _usage(usage, model),
    }


# ---------------------------------------------------------------- HTML

def _e(s) -> str:
    return escape(str(s), quote=True)


def _date(iso: str) -> str:
    try:
        d = datetime.fromisoformat(iso)
    except ValueError:
        return ""
    return f"{d.day} {MONTHS[d.month - 1]} {d.year}"


def _minutes(a: str, b: str) -> str:
    try:
        secs = (datetime.fromisoformat(b) - datetime.fromisoformat(a)).total_seconds()
    except ValueError:
        return ""
    return f"{max(1, round(secs / 60))} min" if secs > 0 else ""


def _num(x: float) -> str:
    return f"{x:.1f}".rstrip("0").rstrip(".") if x != int(x) else str(int(x))


def _bar(score: int) -> str:
    return '<div class="bar" aria-hidden="true">' + "".join(f'<i class="on"></i>' if i < score else "<i></i>" for i in range(5)) + "</div>"


def _stat(label: str, value: str, unit: str = "") -> str:
    u = f"<small>{_e(unit)}</small>" if unit else ""
    return f'<div class="stat"><dt>{_e(label)}</dt><dd>{_e(value)}{u}</dd></div>'


def _question(q: dict) -> str:
    asked = [a for a in q["asked"] if a["kind"] in ("question", "repeat")] or q["asked"][:1]
    title = asked[0]["text"] if asked else q["planned_text"]
    follow = [a["text"] for a in q["asked"] if a["kind"] in ("follow_up", "push")]
    d = q["delivery"]
    out = ['<article class="q">', f'<div class="q-tag"><b>{_e(q["q_id"].upper())}</b>'
           + (f" · {_e(q['kind'])}" if q["kind"] else "") + "</div>", f"<h3>{_e(title)}</h3>"]
    if q["skipped"] or not q["answers"]:
        out.append(f'<p class="skipped">{"Skipped." if q["skipped"] else "No answer recorded."}</p>')
    else:
        out.append('<div class="said"><div class="label">Your answer</div>')
        out += [f'<p class="answer">{_e(a["text"])}</p>' for a in q["answers"]]
        out.append("</div>")
        if follow:
            out.append(f'<p class="follow">Follow-up: {_e(" / ".join(follow))}</p>')
        bits = [f'{_num(d["seconds"])} s' + (f' (target {d["target_s"][0]}-{d["target_s"][1]} s, {LENGTH_WORDS[d["length"]]})'
                                              if d["length"] else ""),
                f'{_num(d["wpm"])} wpm', f'{d["fillers"]} filler{"" if d["fillers"] == 1 else "s"}']
        if d["longest_pause_s"]:
            bits.append(f'longest pause {_num(d["longest_pause_s"])} s')
        out.append('<p class="deliv">' + "".join(f"<span>{_e(b)}</span>" for b in bits) + "</p>")
    g = q["grade"]
    if g and not (q["skipped"] or not q["answers"]):
        def col(title_, items):
            body = "".join(f"<li>{_e(i)}</li>" for i in items) or '<li class="note">Nothing noted.</li>'
            return f'<div><div class="label">{title_}</div><ul>{body}</ul></div>'
        out.append('<div class="cols">' + col("Strong", g["strong"]) + col("Missing", g["missing"]) + "</div>")
        if g["better_answer"]:
            out.append('<div class="better"><div class="label">A better answer, from your own evidence</div>')
            out += [f'<p>{_e(b["sentence"])}</p>' for b in g["better_answer"]]
            seen, src = set(), []
            for b in g["better_answer"]:
                for s in b["sources"]:
                    key = (s["id"], s.get("ref"), s.get("quote"))
                    if key not in seen:
                        seen.add(key)
                        quote = f' “{_e(s["quote"])}”' if s.get("quote") else ""
                        src.append(f'<div><b>{_e(s["id"])}</b> {_e(s.get("kind", ""))}: {_e(s.get("ref", ""))}{quote}</div>')
            if src:
                out.append('<div class="src">' + "".join(src) + "</div>")
            out.append("</div>")
    if q["coach"]:
        out.append(f'<p class="coach">Live coach note: {_e(" ".join(q["coach"]))}</p>')
    out.append("</article>")
    return "".join(out)


def render_html(r: dict) -> str:
    title = f'Interview report: {r["company"]}' if r["company"] else "Interview report"
    meta = [x for x in (r["role"], r["interview_type"], r["difficulty"], _date(r["started_at"]),
                        _minutes(r["started_at"], r["ended_at"]), f'{r["mode"]} mode' if r["mode"] else "") if x]
    d = r["delivery"]
    p = ["<!doctype html>", f'<html lang="{_e(r["lang"] or "en")}"><head><meta charset="utf-8">',
         '<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark">',
         f"<title>{_e(title)}</title><style>{CSS}</style></head><body><main>",
         f'<header><h1>{_e(r["company"] or "Practice interview")}</h1>'
         f'<p class="meta">{_e(" · ".join(meta))}</p></header>']
    if not r["graded"]:
        p.append(f'<p class="notice">Grading unavailable ({_e(r["grading_error"])}). The transcript and delivery numbers '
                 "below are complete; run the report again to get scores.</p>")
    p += [f'<p class="notice">{_e(w)}</p>' for w in r["warnings"]]
    if r["graded"]:
        hero = (f'<div class="hero"><div class="big">{r["overall"]}<small>/5</small></div>'
                "<p>Overall score across the competencies this posting asks for.</p></div>"
                if r["overall"] else "")
        p.append(hero)
        if r["competencies"]:
            p.append("<section><h2>Competencies</h2>")
            for c in r["competencies"]:
                qs = ", ".join(x.upper() for x in c["q_ids"])
                p.append(f'<div class="comp"><div class="comp-head"><strong>{_e(c["name"])}</strong>'
                         f'<span class="score">{c["score"]}/5</span></div>{_bar(c["score"])}'
                         + (f'<p>{_e(c["rubric_line"])}</p>' if c["rubric_line"] else "")
                         + (f'<p class="quote">Posting: “{_e(c["posting_quote"])}”</p>' if c["posting_quote"] else "")
                         + (f'<p class="quote">Judged on {_e(qs)}</p>' if qs else "") + "</div>")
            p.append("</section>")
        if r["practise_next"]:
            p.append("<section><h2>Practise next</h2><ol class=\"practise\">"
                     + "".join(f"<li>{_e(x)}</li>" for x in r["practise_next"]) + "</ol></section>")
    p.append("<section><h2>Delivery</h2><dl class=\"stats\">"
             + _stat("Pace", _num(d["wpm"]), "wpm") + _stat("Filler words", str(d["fillers"]))
             + _stat("Longest pause", _num(d["longest_pause_s"]), "s")
             + _stat("Answered", f'{d["questions_answered"]}/{d["questions_total"]}')
             + '</dl><p class="note">Pace is words per minute over your speaking time. A pause is the gap between two '
             "answers to the same question; the transcript has no word timings, so pauses inside an answer are not "
             "measured. Filler words are counted from the transcript text.</p></section>")
    p.append("<section><h2>Question by question</h2>" + "".join(_question(q) for q in r["questions"]) + "</section>")
    cq = r.get("candidate_question")
    if cq and cq.get("text"):
        p.append('<section><h2>Your question to them</h2><p class="answer">' + _e(cq["text"]) + "</p>"
                 + (f'<p class="follow">Their reply: {_e(cq["reply"])}</p>' if cq.get("reply") else "") + "</section>")
    p.append(f'<footer>Session {_e(r["session_id"])}. Graded from the transcript only; no audio was stored.</footer>')
    p.append("</main></body></html>")
    return "\n".join(p) + "\n"
