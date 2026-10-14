import os
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

from verse_brain.prep.git_digest import git_digest, read_commits


def _git(repo: Path, *args: str, date: datetime | None = None) -> None:
    env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"}
    if date:
        env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = date.isoformat()
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=T", "-c", "user.email=t@example.com",
                    "-c", "commit.gpgsign=false", *args], check=True, capture_output=True, env=env)


def make_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "demo-repo"
    repo.mkdir()
    _git(repo, "init", "-q")
    now = datetime.now(timezone.utc)
    plan = [
        (5, "Add invoice schema", ["schema.py", "docs/schema.md"]),
        (3, "Retry once on low confidence", ["pipeline.py"]),
        (1, "Route low-confidence fields to operator", ["pipeline.py", "ops/queue.py", "tests/test_queue.py"]),
    ]
    for days, subject, files in plan:
        for f in files:
            p = repo / f
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(f"{subject}\n{days}\n", encoding="utf-8")
        _git(repo, "add", "-A")
        _git(repo, "commit", "-q", "-m", subject, date=now - timedelta(days=days))
    return repo


def test_git_digest(tmp_path):
    repo = make_repo(tmp_path)
    lines = git_digest(repo)
    assert len(lines) == 3
    # chronological: oldest first, and file names are present
    assert "Add invoice schema" in lines[0] and "schema.py" in lines[0] and "docs/schema.md" in lines[0]
    assert "Retry once on low confidence" in lines[1] and "pipeline.py" in lines[1]
    assert "ops/queue.py" in lines[2] and "tests/test_queue.py" in lines[2]
    dates = [ln.split(" ", 1)[0] for ln in lines]
    assert dates == sorted(dates)
    assert all("[demo-repo]" in ln for ln in lines)


def test_commits_carry_hash_refs(tmp_path):
    repo = make_repo(tmp_path)
    commits = read_commits(repo)
    assert [c.subject for c in commits][0] == "Add invoice schema"
    assert all(len(c.hash) >= 7 and c.ref == f"commit:{c.hash}" for c in commits)


def test_git_digest_ignores_commits_older_than_window(tmp_path):
    repo = make_repo(tmp_path)
    assert len(git_digest(repo, since="2.days")) == 1
