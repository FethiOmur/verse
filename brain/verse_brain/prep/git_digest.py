"""Git digest: the last commits of a repo as compact, date-ordered lines with file names."""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

_HEADER = re.compile(r"^(?P<hash>[0-9a-f]{7,40})\t(?P<date>\d{4}-\d{2}-\d{2})\t(?P<subject>.*)$")
MAX_FILES_PER_COMMIT = 8
MAX_COMMITS = 60


class GitError(RuntimeError):
    pass


@dataclass(frozen=True)
class Commit:
    repo: str
    hash: str
    date: str  # YYYY-MM-DD
    subject: str
    files: tuple[str, ...]

    @property
    def ref(self) -> str:
        return f"commit:{self.hash}"

    def line_text(self) -> str:
        """Everything a quote may come from: subject and file names."""
        return self.subject + " " + " ".join(self.files)

    def line(self) -> str:
        shown = list(self.files[:MAX_FILES_PER_COMMIT])
        extra = len(self.files) - len(shown)
        files = ", ".join(shown) + (f", +{extra} more" if extra > 0 else "")
        return f"{self.date} {self.hash} [{self.repo}] {self.subject}" + (f" ({files})" if files else "")


def read_commits(repo: Path, since: str = "14.days") -> list[Commit]:
    """Commits in chronological order (oldest first; ties keep git's order, reversed)."""
    cmd = [
        "git", "-c", "core.quotepath=off", "-C", str(repo), "log", f"--since={since}", "--name-only",
        "--pretty=format:%h%x09%ad%x09%s", "--date=short",
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except Exception as e:  # noqa: BLE001
        raise GitError(f"git failed for {repo.name}: {type(e).__name__}") from None
    if r.returncode != 0:
        raise GitError(f"git log failed for {repo.name} (exit {r.returncode}): {r.stderr.strip()[:200]}")
    commits: list[Commit] = []
    cur: dict | None = None
    for raw in r.stdout.splitlines():
        m = _HEADER.match(raw)
        if m:
            if cur:
                commits.append(_finish(repo.name, cur))
            cur = {"hash": m["hash"], "date": m["date"], "subject": m["subject"].strip(), "files": []}
        elif raw.strip() and cur is not None:
            cur["files"].append(raw.strip())
    if cur:
        commits.append(_finish(repo.name, cur))
    commits.reverse()  # git prints newest first
    commits.sort(key=lambda c: c.date)  # stable: equal dates keep the reversed (chronological) git order
    return commits[-MAX_COMMITS:]


def _finish(repo: str, cur: dict) -> Commit:
    return Commit(repo=repo, hash=cur["hash"], date=cur["date"], subject=cur["subject"], files=tuple(cur["files"]))


def git_digest(repo: Path, since: str = "14.days") -> list[str]:
    return [c.line() for c in read_commits(repo, since)]
