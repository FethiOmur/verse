"""Owner-only extensions: the one door through which code that is not in this repository can add to the brain.

The core is generic. A person who needs more (a private retrieval script, extra profile sources, house rules in a prompt) keeps
that code in a folder of their own and points `extensions_path` in the owner profile (owner.py) at it. This module loads
`<extensions_path>/brain/*.py`, calls `register(registry)` in each, and hands the result to the places that ask for it.
docs/extensions.md is the reference.

Guarantees:
  - Code is loaded only from the folder the owner profile names. Never from the repository, the working directory or
    `sys.path`, and no path is added to `sys.path`.
  - Nothing here raises. A missing folder, a module that fails to import, a module without `register`, a `register` that raises
    or sets something invalid: one warning on the `verse.extensions` logger, and the core behaviour stays. A module that fails
    contributes nothing, not even the part it registered before it failed.
  - The result is read once per process (prompts are cache prefixes and must not change inside a run).
"""

from __future__ import annotations

import importlib.util
import logging
import sys
from pathlib import Path
from typing import Any, Iterable, Mapping

from .owner import OWNER

log = logging.getLogger("verse.extensions")

# The prompts that accept an addendum (`add_prompt_addendum(name, text)`).
PROMPT_NAMES = ("prep", "profile", "voice", "script", "live_fast", "live_deep", "ask")
MODULE_PREFIX = "verse_ext_"


class Registry:
    """What `register(registry)` receives, and what the core reads afterwards."""

    def __init__(self, config: Mapping[str, Any] | None = None) -> None:
        self.config: Mapping[str, Any] = dict(config or {})          # the owner profile file, key by key
        self.vault_provider: Any | None = None
        self.profile_sources: list[Path] = []
        self.prompt_addenda: dict[str, list[str]] = {}
        self.private_projects: list[str] = []

    # ---- the four hook points
    def set_vault_provider(self, provider: Any) -> None:
        """Replace the built-in vault retrieval. `provider.search(query, limit=3, budget_chars=2500)` returns records: dicts (or
        objects) with `id`, `source` (a vault-relative path) and `text`. A provider may also define `bind(vault_path, audience)`
        that returns the object to search with; `audience` is "internal" or "public"."""
        if not callable(getattr(provider, "search", None)):
            raise TypeError("a vault provider needs a search(query) method")
        if self.vault_provider is not None:
            raise ValueError("a vault provider is already set")
        self.vault_provider = provider

    def add_profile_source(self, path: str | Path) -> None:
        """One more file for the me-profile build (listed in the first-build sources when it exists)."""
        self.profile_sources.append(Path(path).expanduser())

    def add_prompt_addendum(self, prompt: str, text: str) -> None:
        """A text block appended to the named system prompt (one of PROMPT_NAMES). `{owner}`, `{Owner}` and `{OWNER}` work."""
        if prompt not in PROMPT_NAMES:
            raise ValueError(f"unknown prompt {prompt!r}; known: {', '.join(PROMPT_NAMES)}")
        if not isinstance(text, str):
            raise TypeError("an addendum is a string")
        if text.strip():
            self.prompt_addenda.setdefault(prompt, []).append(text.strip())

    def add_private_project(self, name: str) -> None:
        """A project folder name that is never read into the profile and never leaves the machine."""
        if not isinstance(name, str):
            raise TypeError("a project name is a string")
        if name.strip():
            self.private_projects.append(name.strip())

    def _merge(self, other: "Registry", origin: str) -> None:
        if other.vault_provider is not None:
            if self.vault_provider is None:
                self.vault_provider = other.vault_provider
            else:
                log.warning("extension %s: a vault provider is already set; keeping the first", origin)
        self.profile_sources += other.profile_sources
        self.private_projects += [p for p in other.private_projects if p not in self.private_projects]
        for name, blocks in other.prompt_addenda.items():
            self.prompt_addenda.setdefault(name, []).extend(blocks)


def _load_module(file: Path):
    name = MODULE_PREFIX + file.stem
    spec = importlib.util.spec_from_file_location(name, file)
    if spec is None or spec.loader is None:
        raise ImportError("not a loadable Python file")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    try:
        spec.loader.exec_module(mod)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return mod


def load_extensions(path: Path | str | None, config: Mapping[str, Any] | None = None) -> Registry:
    """Load `<path>/brain/*.py`. Returns the registry; never raises."""
    reg = Registry(config)
    if path is None:
        return reg
    try:
        root = Path(path).expanduser()
        if not root.is_dir():
            log.warning("extensions folder not found: %s (continuing without extensions)", root)
            return reg
        brain = root / "brain"
        files = sorted(p for p in brain.glob("*.py") if p.is_file() and not p.name.startswith("_")) if brain.is_dir() else []
    except Exception as e:  # noqa: BLE001
        log.warning("extensions folder unreadable: %s (continuing without extensions)", type(e).__name__)
        return reg
    for f in files:
        scratch = Registry(config)
        try:
            mod = _load_module(f)
            register = getattr(mod, "register", None)
            if not callable(register):
                raise AttributeError("no register(registry) function")
            register(scratch)
        except (Exception, SystemExit) as e:  # noqa: BLE001
            log.warning("extension %s skipped: %s: %s", f.name, type(e).__name__, str(e)[:200])
            continue
        reg._merge(scratch, f.name)
    return reg


_registry: Registry | None = None
_loading = False


def registry() -> Registry:
    """The registry of this process, loaded on first use from the owner profile's `extensions_path`."""
    global _registry, _loading
    if _registry is not None:
        return _registry
    if _loading:                 # an extension imported a module that asks for the registry while it is loading
        return Registry(OWNER.raw)
    _loading = True
    try:
        _registry = load_extensions(OWNER.extensions_path, OWNER.raw)
    finally:
        _loading = False
    return _registry


def set_registry(reg: Registry | None) -> None:
    """Replace (or, with None, drop) the process registry. For tests and tools."""
    global _registry
    _registry = reg


def with_addenda(prompt: str, text: str) -> str:
    """`text` with the extensions' blocks for the named prompt appended; `text` itself when there are none."""
    blocks = registry().prompt_addenda.get(prompt)
    if not blocks:
        return text
    return text.rstrip("\n") + "\n\n" + OWNER.fill("\n\n".join(blocks))


def private_projects() -> tuple[str, ...]:
    return tuple(registry().private_projects)


def profile_sources() -> Iterable[Path]:
    return tuple(registry().profile_sources)
