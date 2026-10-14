"""Filesystem and secret checks for the replay. Nothing here prints a secret: the key is compared in-process and
only counts and pass/fail leave this module."""

from __future__ import annotations

import getpass
import os
import re
import subprocess
import threading
import time
from pathlib import Path

AUDIO_EXT = {".wav", ".wave", ".aif", ".aiff", ".aifc", ".caf", ".m4a", ".mp3", ".mp4", ".flac", ".pcm", ".ogg", ".opus", ".aac", ".amr", ".raw"}
AUDIO_MAGIC = (b"RIFF", b"FORM", b"ID3", b"caff", b"fLaC", b"OggS")
KEY_PATTERNS = [re.compile(rb"sk-ant-[A-Za-z0-9_\-]{8,}"), re.compile(rb"hf_[A-Za-z0-9]{20,}"),
                re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----")]


def keychain_key() -> str | None:
    """The API key from the Keychain (service verse-anthropic), or None. Never print the return value."""
    user = os.environ.get("USER") or getpass.getuser()
    try:
        r = subprocess.run(["security", "find-generic-password", "-a", user, "-s", "verse-anthropic", "-w"],
                           capture_output=True, text=True, timeout=30)
    except Exception:  # noqa: BLE001
        return None
    k = r.stdout.strip()
    return k if r.returncode == 0 and k else None


def scan_for_secrets(paths: list[Path], key: str | None) -> dict:
    """Looks for the exact Keychain key and for key-shaped strings in every file under `paths`. Returns counts only."""
    files = 0
    exact = 0
    shaped = 0
    kb = key.encode() if key and len(key) >= 8 else None
    for root in paths:
        items = [root] if root.is_file() else [p for p in sorted(root.rglob("*")) if p.is_file()]
        for p in items:
            try:
                data = p.read_bytes()
            except OSError:
                continue
            files += 1
            if kb and kb in data:
                exact += 1
            if any(pat.search(data) for pat in KEY_PATTERNS):
                shaped += 1
    return {"files_scanned": files, "exact_key_hits": exact, "key_shaped_hits": shaped,
            "key_available": kb is not None, "pass": exact == 0 and shaped == 0 and kb is not None}


def is_audio_file(p: Path) -> bool:
    if p.suffix.lower() in AUDIO_EXT:
        return True
    try:
        with open(p, "rb") as f:
            head = f.read(4)
    except OSError:
        return False
    return head in AUDIO_MAGIC


class AudioWatch:
    """Polls some folders while a session runs and records every audio file that appears (by extension or magic bytes)."""

    def __init__(self, folders: list[Path], interval: float = 0.25) -> None:
        self.folders = folders
        self.interval = interval
        self.found: set[str] = set()
        self.polls = 0
        self._stop = threading.Event()
        self._t = threading.Thread(target=self._run, daemon=True)
        self._baseline: dict[str, float] = {}

    def _scan(self) -> dict[str, float]:
        seen: dict[str, float] = {}
        for f in self.folders:
            if not f.exists():
                continue
            for p in f.rglob("*"):
                try:
                    if p.is_file() and "/models/" not in str(p):
                        seen[str(p)] = p.stat().st_mtime
                except OSError:
                    pass
        return seen

    def _run(self) -> None:
        while not self._stop.is_set():
            now = self._scan()
            self.polls += 1
            for path, mt in now.items():
                if path in self.found:
                    continue
                if path not in self._baseline or self._baseline[path] != mt:
                    if is_audio_file(Path(path)):
                        self.found.add(path)
            self._stop.wait(self.interval)

    def start(self) -> None:
        self._baseline = self._scan()
        self._t.start()

    def stop(self) -> dict:
        self._stop.set()
        self._t.join(timeout=5)
        # one last look, in case the file appeared in the final interval
        for path, mt in self._scan().items():
            if (path not in self._baseline or self._baseline[path] != mt) and is_audio_file(Path(path)):
                self.found.add(path)
        return {"folders": [str(f) for f in self.folders], "polls": self.polls, "audio_files_found": sorted(self.found),
                "pass": not self.found}


def loadavg() -> list[float]:
    return [round(x, 2) for x in os.getloadavg()]
