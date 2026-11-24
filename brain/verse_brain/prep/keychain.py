"""API key access. Keys come only from the macOS Keychain and are never printed, logged or written.

Two items, same account (the current user): `verse-anthropic` is the Anthropic API key (the item the app's Settings screen
fills; always required, and never sent to an API base URL), `verse-anthropic-proxy` an optional key for an API proxy, read
only when an API base URL is set (apiroute.py). Every key read in this process is remembered (in memory only) so `redact` scrubs
all of them from error text, whichever one a caller passes.
"""

from __future__ import annotations

import getpass
import os
import subprocess

KEYCHAIN_SERVICE = "verse-anthropic"
PROXY_KEYCHAIN_SERVICE = "verse-anthropic-proxy"

_LOADED: set[str] = set()   # keys read in this process, for `redact`


class KeychainError(RuntimeError):
    """Keychain item missing or unreadable. The message never contains key material."""


def _read(service: str) -> str:
    user = os.environ.get("USER") or getpass.getuser()
    try:
        r = subprocess.run(
            ["security", "find-generic-password", "-a", user, "-s", service, "-w"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except Exception as e:  # noqa: BLE001
        raise KeychainError(f"Keychain read failed: {type(e).__name__}") from None
    key = r.stdout.strip()
    if r.returncode != 0 or not key:
        raise KeychainError(f"Keychain item service={service} account={user} missing (exit {r.returncode})")
    if len(key) >= 8:
        _LOADED.add(key)
    return key


def read_api_key() -> str:
    return _read(KEYCHAIN_SERVICE)


def read_proxy_key() -> str | None:
    """The API proxy's key, or None when the item is missing or unreadable (a proxy may not need one)."""
    try:
        return _read(PROXY_KEYCHAIN_SERVICE)
    except KeychainError:
        return None


def redact(text: str, key: str | None = None) -> str:
    """Remove `key` and every key read in this process from any text before it is shown or stored."""
    for k in sorted({key, *_LOADED} - {None}, key=len, reverse=True):
        if k and len(k) >= 8:
            text = text.replace(k, "[redacted-key]")
    return text
