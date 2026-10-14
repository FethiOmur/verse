"""Vault retrieval through `beyin.py context`. Read-only by construction.

Rules (spec 5.2): retrieval happens only at prep, never live; the command always carries `--no-sync`, which
(verified with --help and by a before/after mtime check) reads the existing index without writing to the vault
or the runtime state. Only the `context` subcommand is ever run.
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

DEFAULT_VAULT = Path("~/Documents/knowledge-vault").expanduser()
DEFAULT_PYTHON = "/opt/homebrew/opt/python@3.14/bin/python3.14"
MAX_RECORD_CHARS = 1500


class VaultError(RuntimeError):
    pass


@dataclass(frozen=True)
class VaultRecord:
    record_id: str
    source: str  # vault-relative path, e.g. "300-Projects/X/Y.md"
    text: str


class Vault(Protocol):
    def search(self, query: str, limit: int = 3, budget_chars: int = 2500) -> list[VaultRecord]: ...


class BeyinVault:
    def __init__(self, vault_path: Path = DEFAULT_VAULT, python: str | None = None, audience: str = "internal",
                 timeout: float = 60.0) -> None:
        self.vault_path = Path(vault_path).expanduser()
        self.python = python or os.environ.get("VERSE_BEYIN_PYTHON") or DEFAULT_PYTHON
        self.audience = audience
        self.timeout = timeout
        self.script = self.vault_path / "beyin.py"

    def command(self, query: str, limit: int, budget_chars: int) -> list[str]:
        cmd = [
            self.python, str(self.script), "--vault", str(self.vault_path),
            "context", query, "--no-sync", "--audience", self.audience,
            "--limit", str(limit), "--budget-chars", str(budget_chars),
        ]
        assert "--no-sync" in cmd  # never run without the read-only flag
        return cmd

    def search(self, query: str, limit: int = 3, budget_chars: int = 2500) -> list[VaultRecord]:
        if not self.script.exists():
            raise VaultError(f"beyin.py not found at {self.script}")
        q = query.strip()
        if not q:
            return []
        try:
            r = subprocess.run(self.command(q, limit, budget_chars), capture_output=True, text=True,
                               timeout=self.timeout)
        except Exception as e:  # noqa: BLE001
            raise VaultError(f"beyin.py failed: {type(e).__name__}") from None
        if r.returncode != 0:
            raise VaultError(f"beyin.py exit {r.returncode}: {r.stderr.strip()[:200]}")
        return parse_context(r.stdout)


def parse_context(stdout: str) -> list[VaultRecord]:
    try:
        data = json.loads(stdout)
    except json.JSONDecodeError:
        raise VaultError("beyin.py returned non-JSON output") from None
    if data.get("abstained"):
        return []
    out: list[VaultRecord] = []
    for rec in data.get("records") or []:
        text = (rec.get("text") or "").strip()
        src = rec.get("source") or ""
        if not text or not src:
            continue
        out.append(VaultRecord(record_id=str(rec.get("id") or src), source=src, text=text[:MAX_RECORD_CHARS]))
    return out
