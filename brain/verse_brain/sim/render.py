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

# The page's own words (headings, labels, short captions) follow the app's interface language (`sim_start.ui_lang`, copied into
# `sim_results.json`). The interview itself, the grades and the notices keep the interview language / English. Italian uses
# "tu"; Turkish avoids direct address (spec 2.5). Executor-written: the owner reviews.
UI_LANGS = ("en", "it", "tr")
TEXT: dict[str, dict[str, str]] = {
    "en": {
        "report": "Interview report", "practice": "Practice interview", "mode": "{mode} mode",
        "grading_a": "Grading unavailable", "grading_b": "The transcript and delivery numbers below are complete; run the report again to get scores.",
        "hero": "Overall score across the competencies this posting asks for.",
        "competencies": "Competencies", "posting": "Posting", "judged": "Judged on",
        "practise_next": "Practise next", "delivery": "Delivery",
        "pace": "Pace", "wpm": "wpm", "fillers": "Filler words", "pause": "Longest pause", "answered": "Answered", "s": "s",
        "delivery_note": "Pace is words per minute over your speaking time. A pause is the gap between two answers to the same question; the transcript has no word timings, so pauses inside an answer are not measured. Filler words are counted from the transcript text.",
        "fillers_en_only": "Fillers are counted for English only.",
        "qbyq": "Question by question", "skipped": "Skipped.", "no_answer": "No answer recorded.", "your_answer": "Your answer",
        "follow_up": "Follow-up", "target": "target", "short": "shorter than the target", "on_target": "on target", "long": "longer than the target",
        "filler_one": "filler", "filler_many": "fillers", "longest_pause": "longest pause",
        "strong": "Strong", "missing": "Missing", "nothing": "Nothing noted.", "better": "A better answer, from your own evidence",
        "coach": "Live coach note", "your_q": "Your question to them", "their_reply": "Their reply",
        "footer": "Session {id}. Graded from the transcript only; no audio was stored.",
    },
    "it": {
        "report": "Report del colloquio", "practice": "Colloquio di prova", "mode": "modalità {mode}",
        "grading_a": "Valutazione non disponibile", "grading_b": "La trascrizione e i numeri sull'esposizione qui sotto sono completi; rigenera il report per ottenere i punteggi.",
        "hero": "Punteggio complessivo sulle competenze richieste da questo annuncio.",
        "competencies": "Competenze", "posting": "Annuncio", "judged": "Valutata su",
        "practise_next": "Su cosa esercitarti", "delivery": "Esposizione",
        "pace": "Ritmo", "wpm": "parole/min", "fillers": "Intercalari", "pause": "Pausa più lunga", "answered": "Risposte", "s": "s",
        "delivery_note": "Il ritmo è il numero di parole al minuto nel tempo in cui parli. Una pausa è l'intervallo tra due risposte alla stessa domanda; la trascrizione non ha i tempi delle parole, quindi le pause dentro una risposta non vengono misurate. Gli intercalari sono contati dal testo della trascrizione.",
        "fillers_en_only": "Gli intercalari vengono contati solo per l'inglese.",
        "qbyq": "Domanda per domanda", "skipped": "Saltata.", "no_answer": "Nessuna risposta registrata.", "your_answer": "La tua risposta",
        "follow_up": "Approfondimento", "target": "obiettivo", "short": "più breve dell'obiettivo", "on_target": "in linea con l'obiettivo", "long": "più lunga dell'obiettivo",
        "filler_one": "intercalare", "filler_many": "intercalari", "longest_pause": "pausa più lunga",
        "strong": "Punti di forza", "missing": "Cosa manca", "nothing": "Niente da segnalare.", "better": "Una risposta migliore, dalle tue esperienze",
        "coach": "Nota del coach dal vivo", "your_q": "La tua domanda per loro", "their_reply": "La loro risposta",
        "footer": "Sessione {id}. Valutata solo dalla trascrizione; nessun audio è stato salvato.",
    },
    "tr": {
        "report": "Mülakat raporu", "practice": "Deneme mülakatı", "mode": "{mode} modu",
        "grading_a": "Puanlama kullanılamıyor", "grading_b": "Aşağıdaki transkript ve anlatım sayıları eksiksizdir; puanları görmek için raporu yeniden oluştur.",
        "hero": "Bu ilanın istediği yetkinlikler üzerinden genel puan.",
        "competencies": "Yetkinlikler", "posting": "İlan", "judged": "Değerlendirilen sorular",
        "practise_next": "Sıradaki çalışma konuları", "delivery": "Anlatım",
        "pace": "Hız", "wpm": "sözcük/dk", "fillers": "Dolgu sözcükleri", "pause": "En uzun duraklama", "answered": "Yanıtlanan", "s": "sn",
        "delivery_note": "Hız, konuşma süresi üzerinden dakikadaki sözcük sayısıdır. Duraklama, aynı soruya verilen iki yanıt arasındaki boşluktur; transkriptte sözcük zamanlaması olmadığı için bir yanıtın içindeki duraklamalar ölçülmez. Dolgu sözcükleri transkript metninden sayılır.",
        "fillers_en_only": "Dolgu sözcükleri yalnızca İngilizce için sayılır.",
        "qbyq": "Soru soru", "skipped": "Atlandı.", "no_answer": "Yanıt kaydedilmedi.", "your_answer": "Yanıt",
        "follow_up": "Devam sorusu", "target": "hedef", "short": "hedeften kısa", "on_target": "hedefte", "long": "hedeften uzun",
        "filler_one": "dolgu sözcüğü", "filler_many": "dolgu sözcüğü", "longest_pause": "en uzun duraklama",
        "strong": "Güçlü yönler", "missing": "Eksikler", "nothing": "Not yok.", "better": "Deneyimlere dayalı daha iyi bir yanıt",
        "coach": "Canlı koç notu", "your_q": "Mülakatçıya sorulan soru", "their_reply": "Yanıtları",
        "footer": "Oturum {id}. Yalnızca transkriptten puanlandı; ses kaydedilmedi.",
    },
}


def _tx(r: dict) -> dict[str, str]:
    """The page's words for `r["ui_lang"]` (English for anything else)."""
    return TEXT.get(r.get("ui_lang") or "en", TEXT["en"])


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
        "ui_lang": results.get("ui_lang") if results.get("ui_lang") in UI_LANGS else "en",
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


def _question(q: dict, t: dict[str, str]) -> str:
    asked = [a for a in q["asked"] if a["kind"] in ("question", "repeat")] or q["asked"][:1]
    title = asked[0]["text"] if asked else q["planned_text"]
    follow = [a["text"] for a in q["asked"] if a["kind"] in ("follow_up", "push")]
    d = q["delivery"]
    out = ['<article class="q">', f'<div class="q-tag"><b>{_e(q["q_id"].upper())}</b>'
           + (f" · {_e(q['kind'])}" if q["kind"] else "") + "</div>", f"<h3>{_e(title)}</h3>"]
    if q["skipped"] or not q["answers"]:
        out.append(f'<p class="skipped">{_e(t["skipped"] if q["skipped"] else t["no_answer"])}</p>')
    else:
        out.append(f'<div class="said"><div class="label">{_e(t["your_answer"])}</div>')
        out += [f'<p class="answer">{_e(a["text"])}</p>' for a in q["answers"]]
        out.append("</div>")
        if follow:
            out.append(f'<p class="follow">{_e(t["follow_up"])}: {_e(" / ".join(follow))}</p>')
        u = t["s"]
        bits = [f'{_num(d["seconds"])} {u}' + (f' ({t["target"]} {d["target_s"][0]}-{d["target_s"][1]} {u}, {t[d["length"]]})'
                                                if d["length"] else ""),
                f'{_num(d["wpm"])} {t["wpm"]}', f'{d["fillers"]} {t["filler_one"] if d["fillers"] == 1 else t["filler_many"]}']
        if d["longest_pause_s"]:
            bits.append(f'{t["longest_pause"]} {_num(d["longest_pause_s"])} {u}')
        out.append('<p class="deliv">' + "".join(f"<span>{_e(b)}</span>" for b in bits) + "</p>")
    g = q["grade"]
    if g and not (q["skipped"] or not q["answers"]):
        def col(title_, items):
            body = "".join(f"<li>{_e(i)}</li>" for i in items) or f'<li class="note">{_e(t["nothing"])}</li>'
            return f'<div><div class="label">{title_}</div><ul>{body}</ul></div>'
        out.append('<div class="cols">' + col(t["strong"], g["strong"]) + col(t["missing"], g["missing"]) + "</div>")
        if g["better_answer"]:
            out.append(f'<div class="better"><div class="label">{_e(t["better"])}</div>')
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
        out.append(f'<p class="coach">{_e(t["coach"])}: {_e(" ".join(q["coach"]))}</p>')
    out.append("</article>")
    return "".join(out)


def render_html(r: dict) -> str:
    t = _tx(r)
    title = f'{t["report"]}: {r["company"]}' if r["company"] else t["report"]
    meta = [x for x in (r["role"], r["interview_type"], r["difficulty"], _date(r["started_at"]),
                        _minutes(r["started_at"], r["ended_at"]),
                        t["mode"].format(mode=r["mode"]) if r["mode"] else "") if x]
    d = r["delivery"]
    p = ["<!doctype html>", f'<html lang="{_e(r["lang"] or "en")}"><head><meta charset="utf-8">',
         '<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark">',
         f"<title>{_e(title)}</title><style>{CSS}</style></head><body><main>",
         f'<header><h1>{_e(r["company"] or t["practice"])}</h1>'
         f'<p class="meta">{_e(" · ".join(meta))}</p></header>']
    if not r["graded"]:
        p.append(f'<p class="notice">{_e(t["grading_a"])} ({_e(r["grading_error"])}). {_e(t["grading_b"])}</p>')
    p += [f'<p class="notice">{_e(w)}</p>' for w in r["warnings"]]
    if r["graded"]:
        hero = (f'<div class="hero"><div class="big">{r["overall"]}<small>/5</small></div>'
                f"<p>{_e(t['hero'])}</p></div>"
                if r["overall"] else "")
        p.append(hero)
        if r["competencies"]:
            p.append(f"<section><h2>{_e(t['competencies'])}</h2>")
            for c in r["competencies"]:
                qs = ", ".join(x.upper() for x in c["q_ids"])
                p.append(f'<div class="comp"><div class="comp-head"><strong>{_e(c["name"])}</strong>'
                         f'<span class="score">{c["score"]}/5</span></div>{_bar(c["score"])}'
                         + (f'<p>{_e(c["rubric_line"])}</p>' if c["rubric_line"] else "")
                         + (f'<p class="quote">{_e(t["posting"])}: “{_e(c["posting_quote"])}”</p>' if c["posting_quote"] else "")
                         + (f'<p class="quote">{_e(t["judged"])} {_e(qs)}</p>' if qs else "") + "</div>")
            p.append("</section>")
        if r["practise_next"]:
            p.append(f"<section><h2>{_e(t['practise_next'])}</h2><ol class=\"practise\">"
                     + "".join(f"<li>{_e(x)}</li>" for x in r["practise_next"]) + "</ol></section>")
    note = t["delivery_note"] + (" " + t["fillers_en_only"] if (r["lang"] or "en") != "en" else "")
    p.append(f"<section><h2>{_e(t['delivery'])}</h2><dl class=\"stats\">"
             + _stat(t["pace"], _num(d["wpm"]), t["wpm"]) + _stat(t["fillers"], str(d["fillers"]))
             + _stat(t["pause"], _num(d["longest_pause_s"]), t["s"])
             + _stat(t["answered"], f'{d["questions_answered"]}/{d["questions_total"]}')
             + f'</dl><p class="note">{_e(note)}</p></section>')
    p.append(f"<section><h2>{_e(t['qbyq'])}</h2>" + "".join(_question(q, t) for q in r["questions"]) + "</section>")
    cq = r.get("candidate_question")
    if cq and cq.get("text"):
        p.append(f'<section><h2>{_e(t["your_q"])}</h2><p class="answer">' + _e(cq["text"]) + "</p>"
                 + (f'<p class="follow">{_e(t["their_reply"])}: {_e(cq["reply"])}</p>' if cq.get("reply") else "") + "</section>")
    p.append(f'<footer>{_e(t["footer"].format(id=r["session_id"]))}</footer>')
    p.append("</main></body></html>")
    return "\n".join(p) + "\n"
