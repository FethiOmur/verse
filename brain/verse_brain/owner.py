"""The owner profile: the one place where values that belong to one person's machine live.

The repository carries no personal name, home path, vault layout or private project name. Everything of that kind is read
from a local, untracked JSON file:

    ~/Library/Application Support/Verse/owner.json      (override the location with VERSE_OWNER_FILE)

The Swift app reads the same file (`OwnerProfile` in the VerseAudio target), so the app and the brain agree.

Keys (all optional; a missing file or key falls back to a generic default and switches the feature that needs it off):

    display_name              how prompts and transcripts name the user ("Alex"). Default: "the user".
    vault_path                a notes vault read at prep time (retrieval and the profile's vault sources). Default: none.
    vault_script              the retrieval script inside the vault directory. Default: none (retrieval off).
    vault_python              the interpreter that runs the script. Default: "python3".
    profile_source            one file (CV, profile) that seeds the profile's sources. Default: none.
    projects_folder           folder of the vault whose notes seed the profile's PROJECTS. Default: "Projects".
    projects_index            index note inside that folder. Default: "Projects.md".
    private_project_folders   sub-folders of projects_folder that are never read (listed private repos). Default: none.
    forbidden_vault_folders   vault folders that are never read, whoever asks. Default: none.
    api_key_note              one sentence the Settings page shows above the Keychain note. Default: none.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path

OWNER_FILE_ENV = "VERSE_OWNER_FILE"
DEFAULT_OWNER_FILE = "~/Library/Application Support/Verse/owner.json"
GENERIC_NAME = "the user"
GENERIC_SOURCE_TAG = "owner"
GENERIC_NOTES_HEADING = "MY NOTES"
DEFAULT_PROJECTS_FOLDER = "Projects"
DEFAULT_PROJECTS_INDEX = "Projects.md"
DEFAULT_VAULT_PYTHON = "python3"


def owner_file() -> Path:
    return Path(os.environ.get(OWNER_FILE_ENV) or DEFAULT_OWNER_FILE).expanduser()


def _str(v: object) -> str | None:
    s = " ".join(str(v).split()) if isinstance(v, str) else ""
    return s or None


def _path(v: object) -> Path | None:
    s = _str(v)
    return Path(s).expanduser() if s else None


def _strs(v: object) -> tuple[str, ...]:
    return tuple(s for s in (_str(x) for x in v) if s) if isinstance(v, list) else ()


def _cap(s: str) -> str:
    return s[:1].upper() + s[1:]


@dataclass(frozen=True)
class Owner:
    display_name: str = GENERIC_NAME
    named: bool = False                       # the profile gave a display name
    vault_path: Path | None = None
    vault_script: str | None = None
    vault_python: str | None = None
    profile_source: Path | None = None
    projects_folder: str = DEFAULT_PROJECTS_FOLDER
    projects_index: str = DEFAULT_PROJECTS_INDEX
    private_project_folders: tuple[str, ...] = ()
    forbidden_vault_folders: tuple[str, ...] = ()
    api_key_note: str | None = None

    @property
    def source_tag(self) -> str:
        """The `src` tag of a line the user wrote himself (me.md, `| <tag>` at the end of the line)."""
        if not self.named:
            return GENERIC_SOURCE_TAG
        return re.sub(r"[^a-z0-9]+", "-", self.display_name.casefold()).strip("-") or GENERIC_SOURCE_TAG

    @property
    def notes_heading(self) -> str:
        """The me.md section that holds the user's own notes."""
        return f"{self.display_name.upper()}'S NOTES" if self.named else GENERIC_NOTES_HEADING

    @property
    def voice_heading(self) -> str:
        return f"## {self.display_name.upper()}'S VOICE" if self.named else "## MY VOICE"

    def fill(self, text: str) -> str:
        """Replace `{owner}` (as is), `{Owner}` (first letter up), `{OWNER}` (upper case) and `{NOTES_HEADING}` in a prompt
        template."""
        return (text.replace("{owner}", self.display_name).replace("{Owner}", _cap(self.display_name))
                .replace("{OWNER}", self.display_name.upper()).replace("{NOTES_HEADING}", self.notes_heading))


def load_owner(path: Path | str | None = None) -> Owner:
    """Read the profile. A missing, unreadable or malformed file gives the generic owner; nothing here raises."""
    p = Path(path).expanduser() if path else owner_file()
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return Owner()
    if not isinstance(data, dict):
        return Owner()
    name = _str(data.get("display_name"))
    return Owner(
        display_name=name or GENERIC_NAME,
        named=name is not None,
        vault_path=_path(data.get("vault_path")),
        vault_script=_str(data.get("vault_script")),
        vault_python=_str(data.get("vault_python")),
        profile_source=_path(data.get("profile_source")),
        projects_folder=_str(data.get("projects_folder")) or DEFAULT_PROJECTS_FOLDER,
        projects_index=_str(data.get("projects_index")) or DEFAULT_PROJECTS_INDEX,
        private_project_folders=_strs(data.get("private_project_folders")),
        forbidden_vault_folders=_strs(data.get("forbidden_vault_folders")),
        api_key_note=_str(data.get("api_key_note")),
    )


OWNER = load_owner()      # read once, at import: prompts are cache prefixes and must not change inside a run
