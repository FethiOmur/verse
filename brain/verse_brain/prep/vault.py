"""Vault retrieval: find notes that help prepare a meeting. Read-only by construction, prep time only (never live).

The interface is `Vault.search(query, limit, budget_chars) -> list[VaultRecord]`. Two things implement it:

  - `MarkdownFolderVault`, the built-in: a plain keyword search over the `.md` files of the folder named by `vault_path` in the
    owner profile (owner.py). No index, no network, no write. Without `vault_path` there is no retrieval at all.
  - a vault provider registered by an owner extension (`registry.set_vault_provider`, docs/extensions.md). When one is registered
    it replaces the built-in.

Callers never see the difference: they call `make_vault(path, audience)`, get a `Vault` or None, and catch `VaultError`.

Privacy, enforced here for both: a note or record whose path lies under a forbidden vault folder (`forbidden_vault_folders`) or
under a private project folder (`<projects_folder>/<name>`: `private_project_folders` plus the extensions' private projects) is
never returned. The private project list is read at use time, not at import. The `public` audience is safe by default: the
built-in returns only notes marked `visibility: public` in their frontmatter, and a provider that cannot take an audience gets
no vault at all.
"""

from __future__ import annotations

import hashlib
import inspect
import logging
import math
import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Protocol

from .. import extensions
from ..owner import OWNER

log = logging.getLogger("verse.extensions")

DEFAULT_VAULT: Path | None = OWNER.vault_path
MAX_RECORD_CHARS = 1500
MAX_FILES = 5000                  # the built-in search reads at most this many notes
MAX_FILE_CHARS = 200_000          # ...and at most this much of each


class VaultError(RuntimeError):
    pass


@dataclass(frozen=True)
class VaultRecord:
    record_id: str
    source: str  # vault-relative path, e.g. "Projects/Alpha/Notes.md"
    text: str


class Vault(Protocol):
    def search(self, query: str, limit: int = 3, budget_chars: int = 2500) -> list[VaultRecord]: ...


# ---------------------------------------------------------------- what is never returned
def _norm(name: str) -> str:
    return unicodedata.normalize("NFC", str(name)).strip().casefold()


def _path_parts(source: str) -> list[str]:
    """The normalised parts of a vault path: either slash, `.` dropped, `..` resolved, case and Unicode form ignored.
    URL-style sources (`file://`, `obsidian://…?file=`, percent-encoding) are decoded first so they are checked as paths."""
    src = str(source)
    if "://" in src or "%" in src:
        from urllib.parse import parse_qs, unquote, urlsplit
        u = urlsplit(src)
        q = parse_qs(u.query)
        src = unquote(q["file"][0] if q.get("file") else (u.path if u.scheme else src))
    parts: list[str] = []
    for p in src.replace("\\", "/").split("/"):
        p = _norm(p)
        if p == "..":
            if parts:
                parts.pop()
        elif p not in ("", "."):
            parts.append(p)
    return parts


def blocked_names() -> tuple[set[str], set[str]]:
    """(forbidden vault folders, private project folders), read now. The extensions' private projects are only known once they
    have loaded, so this is called when a search runs, never at import."""
    try:
        extra = extensions.private_projects()
    except RuntimeError as e:                    # the extensions are still loading: fail closed, as the error prep already handles
        raise VaultError(str(e)) from None
    forbidden = {_norm(f) for f in OWNER.forbidden_vault_folders}
    private = {_norm(p) for p in (*OWNER.private_project_folders, *extra)}
    return forbidden, private


def blocked_source(source: str, forbidden: Iterable[str], private: Iterable[str], projects_folder: str | None = None) -> bool:
    """True when `source` lies under a forbidden vault folder, or under a private project folder (a sub-folder of
    `projects_folder`). The sets hold normalised names (`_norm`)."""
    parts = _path_parts(source)
    forbidden, private = set(forbidden), set(private)
    if any(p in forbidden for p in parts):
        return True
    if not private:
        return False
    base = _path_parts(OWNER.projects_folder if projects_folder is None else projects_folder)
    if not base:
        return any(p in private for p in parts)
    n = len(base)
    if any(parts[i:i + n] == base and parts[i + n] in private for i in range(len(parts) - n)):
        return True
    # A provider may report sources without the projects-folder prefix: a private name as a folder still blocks.
    return any(p in private for p in parts[:-1])


_FRONT = re.compile(r"\A\ufeff?---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\Z)", re.S)


def is_marked_public(body: str) -> bool:
    """True when the note's leading frontmatter says `visibility: public` (and no `visibility` line says anything else)."""
    m = _FRONT.match(body)
    if not m:
        return False
    values = []
    for line in m.group(1).splitlines():
        key, sep, val = line.partition(":")
        if sep and key.strip().casefold() == "visibility":
            values.append(val.strip().strip("'\"").strip().casefold())
    return bool(values) and all(v == "public" for v in values)


# ---------------------------------------------------------------- the built-in provider
_WORD = re.compile(r"\w+", re.UNICODE)
_STOP = frozenset("the and for with that this from have what when where which about into your you are was were not but can will "
                  "how why who our out has had its they them their then than there here also just very more some any all".split())


def _terms(query: str) -> list[str]:
    seen: dict[str, None] = {}
    for w in _WORD.findall(query.casefold()):
        if len(w) >= 3 and w not in _STOP:
            seen.setdefault(w, None)
    return list(seen)


class MarkdownFolderVault:
    """Keyword search over a folder of markdown notes. Deterministic; skips hidden folders, `forbidden_vault_folders` and the
    private project folders. With `public_only` it returns only notes whose frontmatter says `visibility: public`."""

    def __init__(self, folder: Path | str, forbidden: Iterable[str] | None = None, private: Iterable[str] | None = None,
                 public_only: bool = False) -> None:
        self.folder = Path(folder).expanduser()
        self._private_arg = None if private is None else {_norm(p) for p in private}
        self.forbidden = {_norm(f) for f in (OWNER.forbidden_vault_folders if forbidden is None else forbidden)}
        self.public_only = public_only

    def _private(self) -> set[str]:
        """The private project folders, read now (an argument given to the constructor wins)."""
        return blocked_names()[1] if self._private_arg is None else self._private_arg

    def _notes(self, private: set[str] | None = None) -> list[Path]:
        private = self._private() if private is None else private
        out: list[Path] = []
        for p in sorted(self.folder.rglob("*.md")):
            rel = p.relative_to(self.folder).parts
            if any(part.startswith(".") for part in rel[:-1]) or p.name.startswith("."):
                continue
            if blocked_source("/".join(rel), self.forbidden, private):
                continue
            if p.is_file():
                out.append(p)
            if len(out) >= MAX_FILES:
                break
        return out

    def search(self, query: str, limit: int = 3, budget_chars: int = 2500) -> list[VaultRecord]:
        terms = _terms(query)
        if not terms:
            return []
        if not self.folder.is_dir():
            raise VaultError("the vault folder was not found")
        private = self._private()
        scored: list[tuple[float, str, str]] = []          # (score, relative path, snippet)
        for note in self._notes(private):
            try:
                body = note.read_text(encoding="utf-8", errors="replace")[:MAX_FILE_CHARS]
            except OSError:
                continue
            if self.public_only and not is_marked_public(body):
                continue
            rel = note.relative_to(self.folder).as_posix()
            low = body.casefold()
            title = rel.casefold()
            score = 0.0
            for t in terms:
                n = low.count(t)
                if n:
                    score += 1.0 + math.log1p(n)
                if t in title:
                    score += 2.0
            if score > 0:
                scored.append((score, rel, body))
        scored.sort(key=lambda s: (-s[0], s[1]))
        per_record = max(200, min(MAX_RECORD_CHARS, budget_chars // max(1, limit)))
        out: list[VaultRecord] = []
        for _, rel, body in scored[:max(0, limit)]:
            snippet = _best_snippet(body, terms, per_record)
            if snippet:
                out.append(VaultRecord("md-" + hashlib.sha256(f"{rel}\n{snippet}".encode()).hexdigest()[:24], rel, snippet))
        return _without_blocked(out, self.forbidden, private)


def _best_snippet(body: str, terms: list[str], cap: int) -> str:
    """The run of paragraphs that mentions the most query terms, cut to `cap` characters."""
    paras = [p.strip() for p in re.split(r"\n\s*\n", body) if p.strip()]
    if not paras:
        return ""
    hits = [sum(p.casefold().count(t) for t in terms) for p in paras]
    best = max(range(len(paras)), key=lambda i: (hits[i], -i))
    text, i = paras[best], best + 1
    while len(text) < cap and i < len(paras):
        text += "\n\n" + paras[i]
        i += 1
    return text[:cap]


# ---------------------------------------------------------------- extension providers
def _field(rec: Any, *names: str) -> Any:
    for n in names:
        v = rec.get(n) if isinstance(rec, dict) else getattr(rec, n, None)
        if v:
            return v
    return None


def _records(raw: Any) -> list[VaultRecord]:
    try:
        items = list(raw or [])
    except TypeError:
        raise VaultError("the vault provider returned no list of records") from None
    out: list[VaultRecord] = []
    for rec in items:
        text = str(_field(rec, "text") or "").strip()
        src = str(_field(rec, "source") or "")
        if not text or not src:
            continue
        out.append(VaultRecord(str(_field(rec, "id", "record_id") or src), src, text[:MAX_RECORD_CHARS]))
    return out


def _without_blocked(records: list[VaultRecord], forbidden: Iterable[str], private: Iterable[str]) -> list[VaultRecord]:
    """The record path's last gate: whatever produced the records, none under a forbidden or private folder gets through."""
    return [r for r in records if not blocked_source(r.source, forbidden, private)]


class ProviderVault:
    """Wraps an extension's provider: passes only the arguments its `search` accepts, normalises the records and turns every
    failure into `VaultError` (what the prep stages already catch)."""

    def __init__(self, provider: Any) -> None:
        self.provider = provider
        try:
            params = inspect.signature(provider.search).parameters
            wide = any(p.kind is p.VAR_KEYWORD for p in params.values())
            self._kw = {k for k in ("limit", "budget_chars") if wide or k in params}
        except (TypeError, ValueError):
            self._kw = set()

    def search(self, query: str, limit: int = 3, budget_chars: int = 2500) -> list[VaultRecord]:
        q = query.strip()
        if not q:
            return []
        kw = {k: v for k, v in (("limit", limit), ("budget_chars", budget_chars)) if k in self._kw}
        try:
            raw = self.provider.search(q, **kw)
        except VaultError:
            raise
        except Exception as e:  # noqa: BLE001
            raise VaultError(f"the vault provider failed: {type(e).__name__}: {str(e)[:200]}") from None
        forbidden, private = blocked_names()
        return _without_blocked(_records(raw), forbidden, private)[:max(0, limit)]


def make_vault(path: Path | str | None, audience: str = "internal") -> Vault | None:
    """The vault for a prep run: the extension's provider when one is registered, else the built-in search over `path`, else
    None (no vault configured: the feature is off).

    Only "internal" sees every allowed note. Any other audience ("public") is restricted: the built-in returns just the notes
    marked `visibility: public`, and a provider without `bind(vault_path, audience)` cannot be told the audience, so there is
    no vault."""
    public = audience != "internal"
    provider = extensions.registry().vault_provider
    if provider is not None:
        try:
            bind = getattr(provider, "bind", None)
            if public and not callable(bind):
                log.warning("the vault provider cannot enforce the %s audience (no bind); no vault is used", audience)
                return None
            bound = bind(Path(path).expanduser() if path is not None else None, audience) if callable(bind) else provider
            return None if bound is None else ProviderVault(bound)     # bind() -> None: this provider has nothing to search
        except Exception as e:  # noqa: BLE001
            log.warning("the vault provider could not be set up (%s); using the built-in search", type(e).__name__)
    if path is None:
        return None
    return MarkdownFolderVault(path, public_only=public)
