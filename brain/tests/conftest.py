"""The runtime tests share session folders under tests/fixtures; the session event log (`events.jsonl`, runtime/events.py) must not
write into the repository. Tests that look at the log set `VERSE_EVENTS=1` themselves.

The owner profile is pinned here, before any `verse_brain` module is imported: the prompts are built once at import from the
profile that exists at that moment (owner.py), so a test run must never see the machine's own owner.json. Every test runs as
"Alex Rivera" with the vault layout of fixtures/owner/pinned.json, on any machine and in CI."""

import os
from pathlib import Path

import pytest

PINNED_OWNER_FILE = Path(__file__).parent / "fixtures" / "owner" / "pinned.json"
os.environ["VERSE_OWNER_FILE"] = str(PINNED_OWNER_FILE)
# The API route (apiroute.py) is pinned the same way: no base URL, so no test (or brain process a test spawns) reads the machine's
# api.json or the fallback Keychain item. Tests of the route set these themselves.
os.environ["VERSE_API_CONFIG_FILE"] = str(Path(__file__).parent / "fixtures" / "api" / "absent.json")
os.environ.pop("VERSE_API_BASE_URL", None)


@pytest.fixture(autouse=True)
def _no_event_log_in_fixtures(monkeypatch):
    monkeypatch.setenv("VERSE_EVENTS", "0")
