"""`build_report`: sim_results.json (+ sim.json, sim_pack.md) -> grades.json, report.json, report.html."""

from __future__ import annotations

import json
import logging
from pathlib import Path

from ..runtime.settings import SONNET
from . import grade, render

log = logging.getLogger("verse.sim.report")


def _write(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def _dump(obj) -> str:
    return json.dumps(obj, indent=2, ensure_ascii=False, sort_keys=False) + "\n"


async def build_report(session_dir: Path, transport, *, model: str = SONNET) -> Path:
    """Grade the session with one Sonnet call and write `grades.json`, `report.json` and `report.html` into
    `session_dir`. Returns the `report.html` path. A grading failure still writes a page with the transcript and the
    delivery numbers (no scores). Raises FileNotFoundError when `sim.json` or `sim_results.json` is missing."""
    session_dir = Path(session_dir)
    sim = json.loads((session_dir / "sim.json").read_text(encoding="utf-8"))
    results = json.loads((session_dir / "sim_results.json").read_text(encoding="utf-8"))
    pack_path = session_dir / "sim_pack.md"
    pack = pack_path.read_text(encoding="utf-8") if pack_path.exists() else json.dumps(sim, indent=2, ensure_ascii=False)

    outcome = await grade.grade_session(sim, results, pack, transport, model)
    if outcome.grades is None:
        log.warning("grading failed: %s", outcome.error)
    else:
        _write(session_dir / "grades.json", _dump(outcome.grades))
    report = render.assemble(sim, results, outcome.grades, error=outcome.error, usage=outcome.usage, model=model)
    _write(session_dir / "report.json", _dump(report))
    out = session_dir / "report.html"
    _write(out, render.render_html(report))
    return out
