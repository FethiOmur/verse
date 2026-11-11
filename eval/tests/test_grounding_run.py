"""Grounding run with a scripted judge (no network): stored verdicts, evidence normalisation, either-judge rule, per-pass counts.

The fake judge answers from a script keyed by (line text, model); every call to a model for a line uses the next entry in
that line's list, so a line can be flagged in pass 1 and clear in pass 2.
"""

import json

import grounding
import grounding_run as GR
import judge as J
import pytest
import run_replay as RR

PACK = ("Lantern cut manual data entry from 11 minutes to 2 minutes per invoice.\n"
        "**Ingrid Solberg** is the VP Engineering. The team said: “we ran on 38,000 invoices a month”.\n"
        "- Notice period is 30 days.\n")

L_MD = "SAY: Ingrid Solberg is the VP Engineering."            # evidence quoted without the markdown asterisks
L_CURLY = "- We ran on 38,000 invoices a month."               # evidence quoted with straight quotes
L_FAKE = "- Lantern is also running at a bank."                # judge says supported, quotes something that is not in the pack
L_BAD = "- The notice period is two weeks."                    # judge flags it
L_OK = "SAY: Notice period is 30 days."
L_SECOND_ONLY = "- Entry went from 11 minutes to 1 minute."   # first judge clears it, second judge flags it


def sup(ev):
    return {"supported": True, "evidence": ev, "unsupported_claim": None}


def uns(claim):
    return {"supported": False, "evidence": None, "unsupported_claim": claim}


SCRIPT = {
    (L_MD, J.MODEL): [sup("Ingrid Solberg is the VP Engineering")] * 2,
    (L_CURLY, J.MODEL): [sup('"we ran on 38,000 invoices a month"')] * 2,
    (L_FAKE, J.MODEL): [sup("Lantern runs at a major bank")] * 2,
    (L_BAD, J.MODEL): [uns("two weeks"), uns("two weeks")],
    (L_OK, J.MODEL): [sup("Notice period is 30 days")] * 2,
    (L_SECOND_ONLY, J.MODEL): [sup("from 11 minutes to 2 minutes")] * 2,
    (L_BAD, J.SECOND_MODEL): [sup("Notice period is 30 days")],                  # Sonnet clears it
    (L_FAKE, J.SECOND_MODEL): [uns("no bank in the notes")],
    (L_SECOND_ONLY, J.SECOND_MODEL): [uns("1 minute is not in the notes")],
    (L_MD, J.SECOND_MODEL): [sup("Ingrid Solberg is the VP Engineering")],
    (L_CURLY, J.SECOND_MODEL): [sup("ran on 38,000")],
    (L_OK, J.SECOND_MODEL): [sup("Notice period is 30 days")],
}


def make_res(lines_by_call):
    rows = []
    for n, (call, line) in enumerate(lines_by_call):
        rows.append({"index": n, "category": "exact", "text": f"Question {n}?", "heard": "", "warmup": False,
                     "suggestion_lines": [{"call": call, "line": line, "turn_id": f"r{n}", "tier": call[0].upper()}]})
    return {"dialogues": [{"id": "dx", "rows": rows}]}


@pytest.fixture
def env(tmp_path, monkeypatch):
    (tmp_path / "pack.md").write_text(PACK, encoding="utf-8")
    seen = {"calls": [], "script": dict(SCRIPT)}
    used = {}

    def fake(pack, items, model=J.MODEL):
        seen["calls"].append((model, [it["line"] for it in items]))
        out = []
        for it in items:
            key = (it["line"], model)
            k = used.get(key, 0)
            used[key] = k + 1
            lst = seen["script"][key]
            out.append({"i": it["i"], **lst[min(k, len(lst) - 1)]})
        return out, 0.001

    monkeypatch.setattr(J, "judge_lines", fake)
    monkeypatch.setattr(RR, "ledger_total", lambda: 0.0)
    monkeypatch.setattr(RR, "ledger_add", lambda *a, **k: None)
    seen["dir"] = tmp_path
    return seen


RES = make_res([("s0001", L_MD), ("s0002", L_CURLY), ("f0003", L_FAKE), ("d0004", L_BAD), ("d0005", L_OK)])


def run(env, res=RES, **kw):
    return GR.run_grounding(res, env["dir"], judge=True, budget_usd=1.0, run="t", passes=kw.pop("passes", 2), **kw)


def by_line(out, line, model=J.MODEL):
    return [v for v in out["verdicts"] if v["line"] == line and v["model"] == model]


# ---- E2: every verdict is stored; evidence is normalised before it is looked up; a missing quote is a flag

def test_norm_matches_the_brain_normaliser_on_markdown_quotes_and_space():
    assert grounding.norm("**Ingrid**  Solberg’s “team” – `ok` now") == "ingrid solberg's \"team\" - ok now"


def test_every_verdict_is_stored_with_line_tier_model_pass_evidence(env):
    out = run(env)
    first = [v for v in out["verdicts"] if v["model"] == J.MODEL]
    assert len(first) == 5 * 2                                    # 5 lines x 2 passes, none overwritten
    v = by_line(out, L_MD)[0]
    assert {"dialogue", "line", "tier", "model", "pass", "supported", "evidence", "evidence_found", "flagged"} <= set(v)
    assert v["tier"] == "S" and v["pass"] == 1 and v["model"] == J.MODEL and v["evidence"].startswith("Ingrid")
    assert {x["pass"] for x in by_line(out, L_BAD)} == {1, 2}
    assert by_line(out, L_BAD, J.SECOND_MODEL)[0]["pass"] == "second"


def test_evidence_with_markdown_or_curly_quotes_is_found_after_normalising(env):
    out = run(env)
    for line in (L_MD, L_CURLY, L_OK):
        assert all(v["evidence_found"] is True and v["flagged"] is False for v in by_line(out, line)), line


def test_supported_but_evidence_not_in_pack_is_flagged_and_gets_a_second_opinion(env):
    out = run(env)
    v = by_line(out, L_FAKE)[0]
    assert v["supported"] is True and v["evidence_found"] is False and v["flagged"] is True
    assert any(m == J.SECOND_MODEL and L_FAKE in ls for m, ls in env["calls"])
    assert not any(m == J.SECOND_MODEL and L_MD in ls for m, ls in env["calls"])     # clean lines are not sent on
    assert L_FAKE in [x["line"] for x in out["violations"]]
    assert out["evidence_not_in_pack"] == 2                       # counted per verdict, as before: 1 line x 2 passes


# ---- E1: either judge flags -> violation; agreement and tier are reported

def test_second_opinion_cannot_clear_a_line_the_first_judge_flagged(env):
    out = run(env)
    lines = [x["line"] for x in out["violations"]]
    assert L_BAD in lines and L_FAKE in lines                     # Sonnet cleared L_BAD, it still counts
    assert L_OK not in lines and L_MD not in lines and L_CURLY not in lines
    bad = next(x for x in out["violations"] if x["line"] == L_BAD)
    assert bad["tier"] == "D" and bad["flagged_by"] == "first" and bad["second_opinion"]["supported"] is True


def test_agreement_is_reported_apart_from_the_violation_count(env):
    out = run(env)
    ag = out["judge_agreement"]
    assert ag == {"read_by_both": 2, "both_flagged": 1, "first_only": 1, "second_only": 0, "both_clear": 0}
    assert out["violation_rule"] == "either judge"
    assert len(out["violations"]) == 2 and out["cleared_by_second_opinion"] == 1


def test_second_judge_on_every_line_can_add_violations_the_first_missed(env):
    res = make_res([("s0001", L_MD), ("f0003", L_FAKE), ("d0004", L_BAD), ("s0006", L_SECOND_ONLY), ("d0005", L_OK), ("s0007", L_CURLY)])
    out = run(env, res, second_on_all=True)
    lines = {x["line"]: x["flagged_by"] for x in out["violations"]}
    assert lines == {L_BAD: "first", L_FAKE: "both", L_SECOND_ONLY: "second"}
    assert out["judge_agreement"] == {"read_by_both": 6, "both_flagged": 1, "first_only": 1, "second_only": 1, "both_clear": 3}


def test_tier_is_logged_and_own_model_judging_is_visible(env):
    out = run(env)
    v = by_line(out, L_BAD)[0]
    assert v["tier"] == "D" and v["own_model"] is False           # Haiku judges first, Sonnet wrote the D line
    assert by_line(out, L_BAD, J.SECOND_MODEL)[0]["own_model"] is True    # ... and Sonnet is the second judge of its own line
    assert by_line(out, L_FAKE)[0]["tier"] == "F" and by_line(out, L_FAKE)[0]["own_model"] is True   # Haiku wrote F, Haiku judges first
    assert by_line(out, L_FAKE, J.SECOND_MODEL)[0]["own_model"] is False
    assert out["by_tier"]["D"]["lines"] == 2 and out["by_tier"]["D"]["flagged"] == 1


# ---- E5: passes are kept; frequency, range and union instead of one number

def test_per_pass_verdicts_flag_frequency_range_and_union(env):
    env["script"][(L_SECOND_ONLY, J.MODEL)] = [uns("x"), sup("from 11 minutes to 2 minutes")]    # flagged in pass 1 only
    res = make_res([("s0001", L_MD), ("d0004", L_BAD), ("s0006", L_SECOND_ONLY)])
    out = run(env, res)
    ps = out["pass_summary"]
    assert ps["per_pass_flagged"] == [2, 1]
    assert ps["violations_range"] == [1, 2] and ps["violations_union"] == 2
    freq = {f["line"]: (f["flagged_in"], f["of"]) for f in ps["flag_frequency"]}
    assert freq == {L_BAD: (2, 2), L_SECOND_ONLY: (1, 2)}
    assert len(out["verdicts"]) == 3 * 2 + 2                    # both passes kept, plus the two second opinions


def test_union_can_exceed_every_single_pass(env):
    env["script"][(L_SECOND_ONLY, J.MODEL)] = [uns("x"), sup("from 11 minutes to 2 minutes")]
    env["script"][(L_BAD, J.MODEL)] = [sup("Notice period is 30 days"), uns("two weeks")]
    res = make_res([("d0004", L_BAD), ("s0006", L_SECOND_ONLY)])
    ps = run(env, res)["pass_summary"]
    assert ps["per_pass_flagged"] == [1, 1] and ps["violations_range"] == [1, 1] and ps["violations_union"] == 2


def test_old_judge_with_no_tier_in_the_item_falls_back_to_the_call_id_prefix(env):
    res = make_res([("d0004", L_BAD)])
    for r in res["dialogues"][0]["rows"]:
        for sl in r["suggestion_lines"]:
            del sl["tier"]
    out = run(env, res)
    assert by_line(out, L_BAD)[0]["tier"] == "D"
