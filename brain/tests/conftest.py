"""The runtime tests share session folders under tests/fixtures; the session event log (`events.jsonl`, runtime/events.py) must not
write into the repository. Tests that look at the log set `VERSE_EVENTS=1` themselves."""

import pytest


@pytest.fixture(autouse=True)
def _no_event_log_in_fixtures(monkeypatch):
    monkeypatch.setenv("VERSE_EVENTS", "0")
