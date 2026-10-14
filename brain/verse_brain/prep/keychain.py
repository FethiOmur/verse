"""API key access. The key comes only from the macOS Keychain and is never printed, logged or written."""

from __future__ import annotations

import getpass
import os
import subprocess

KEYCHAIN_SERVICE = "verse-anthropic"


class KeychainError(RuntimeError):
    """Keychain item missing or unreadable. The message never contains key material."""


def read_api_key() -> str:
    user = os.environ.get("USER") or getpass.getuser()
    try:
        r = subprocess.run(
            ["security", "find-generic-password", "-a", user, "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except Exception as e:  # noqa: BLE001
        raise KeychainError(f"Keychain read failed: {type(e).__name__}") from None
    key = r.stdout.strip()
    if r.returncode != 0 or not key:
        raise KeychainError(f"Keychain item service={KEYCHAIN_SERVICE} account={user} missing (exit {r.returncode})")
    return key


def redact(text: str, key: str | None) -> str:
    """Remove the key value from any text before it is shown or stored."""
    if key and len(key) >= 8:
        text = text.replace(key, "[redacted-key]")
    return text
