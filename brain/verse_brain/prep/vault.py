"""Vault retrieval through the vault's own retrieval script (`<vault>/<script> context`). Read-only by construction.

The vault, the script name and the interpreter come from the owner profile (`owner.py`). Without a configured vault
there is no retrieval: `DEFAULT_VAULT` is None and callers skip the vault.

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

from ..owner import DEFAULT_VAULT_PYTHON, OWNER

DEFAULT_VAULT: Path | None = OWNER.vault_path
DEFAULT_PYTHON = OWNER.vault_python or DEFAULT_VAULT_PYTHON
VAULT_PYTHON_ENV = "VERSE_VAULT_PYTHON"
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


class ScriptVault:
    def __init__(self, vault_path: Path | str | None = DEFAULT_VAULT, python: str | None = None, audience: str = "internal",
                 timeout: float = 60.0, script_name: str | None = None) -> None:
        if vault_path is None:
            raise VaultError("no vault is configured (vault_path in the owner profile)")
        self.vault_path = Path(vault_path).expanduser()
        self.python = python or os.environ.get(VAULT_PYTHON_ENV) or DEFAULT_PYTHON
        self.audience = audience
        self.timeout = timeout
        self.script_name = script_name or OWNER.vault_script
        self.script = self.vault_path / self.script_name if self.script_name else self.vault_path

    def command(self, query: str, limit: int, budget_chars: int) -> list[str]:
        cmd = [
            self.python, str(self.script), "--vault", str(self.vault_path),
            "context", query, "--no-sync", "--audience", self.audience,
            "--limit", str(limit), "--budget-chars", str(budget_chars),
        ]
        assert "--no-sync" in cmd  # never run without the read-only flag
        return cmd

    def search(self, query: str, limit: int = 3, budget_chars: int = 2500) -> list[VaultRecord]:
        if not self.script_name:
            raise VaultError("no vault script is configured (vault_script in the owner profile)")
        if not self.script.exists():
            raise VaultError(f"the vault script not found at {self.script}")
        q = query.strip()
        if not q:
            return []
        try:
            r = subprocess.run(self.command(q, limit, budget_chars), capture_output=True, text=True,
                               timeout=self.timeout)
        except Exception as e:  # noqa: BLE001
            raise VaultError(f"the vault script failed: {type(e).__name__}") from None
        if r.returncode != 0:
            raise VaultError(f"the vault script exit {r.returncode}: {r.stderr.strip()[:200]}")
        return parse_context(r.stdout)


def make_vault(path: Path | str | None, audience: str = "internal") -> ScriptVault | None:
    """The vault for a prep run, or None when no vault and retrieval script are configured (the feature is off)."""
    if path is None or not OWNER.vault_script:
        return None
    return ScriptVault(path, audience=audience)


def parse_context(stdout: str) -> list[VaultRecord]:
    try:
        data = json.loads(stdout)
    except json.JSONDecodeError:
        raise VaultError("the vault script returned non-JSON output") from None
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
