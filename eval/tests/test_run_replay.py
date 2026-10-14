"""The retry decision in run_replay (no verse-run, no network)."""

import run_replay as RR

TL = [{"index": 0, "speaker": "A", "t_start": 20.0, "t_end": 23.0, "silent": False}]


def meta(engine, exit_code=0):
    return {"engine": engine, "timeline": TL, "exit_code": exit_code}


def ready(at):
    return [{"state": "engine_ready", "readyAtSec": at}, {"state": "engine_switch", "switchAtSec": at}]


def test_engine_ready_before_speech_no_retry_and_next_lead_in_follows_load_time():
    p = RR.retry_plan(meta(ready(1.0)), True, 1, 45.0)
    assert not p["retry"] and p["next_lead_in"] == 20.0 and p["ready"] == 1.0          # floor of 20 s
    p = RR.retry_plan(meta(ready(18.0)), True, 1, 45.0)
    assert not p["retry"] and p["next_lead_in"] == 22.0


def test_engine_took_over_after_speech_started_retries_with_longer_lead_in():
    p = RR.retry_plan(meta(ready(41.6)), True, 1, 33.0)
    assert p["retry"] and p["retry_lead_in"] == 46.6 and "after speech had started" in p["why"]


def test_engine_never_ready_retries_with_triple_lead_in_then_gives_up():
    p = RR.retry_plan(meta([]), True, 1, 20.0)
    assert p["retry"] and p["retry_lead_in"] == 60.0
    p = RR.retry_plan(meta([]), True, 2, 60.0)
    assert p["retry"] and p["retry_lead_in"] == 150.0
    assert not RR.retry_plan(meta([]), True, 3, 150.0)["retry"]                           # third attempt is kept


def test_no_retry_when_lead_in_is_fixed_or_the_run_failed():
    assert not RR.retry_plan(meta([]), False, 1, 20.0)["retry"]
    assert not RR.retry_plan(meta([], exit_code=1), True, 1, 20.0)["retry"]
