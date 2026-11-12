#!/usr/bin/env python3
"""Builds the Italian replay session (for eval/dialogues_it/) from the English sample session.

    python tools/make_it_session.py --src <sample-interview folder> --out <new folder>

Every bank entry becomes an Italian entry as prep writes it for an Italian meeting: `lang: it`, the Italian question, and
paraphrases in both meeting languages ({"it": [...], "en": [the English ones]}). Questions and Italian paraphrases come from
bench/embed/ml/it.json (`bank`). Opener, points and deep text stay as they are (criterion 2 only looks at bank hits). The other
session files are copied unchanged; `meta.json` lists ["it", "en"] as the languages. The source folder is only read.
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

HERE = Path(__file__).resolve().parent
IT = HERE.parent.parent / "bench" / "embed" / "ml" / "it.json"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    src, out = Path(a.src).expanduser(), Path(a.out).expanduser()
    if out.exists():
        raise SystemExit(f"{out} exists; choose a new folder")
    it = json.loads(IT.read_text(encoding="utf-8"))["bank"]
    shutil.copytree(src, out, ignore=shutil.ignore_patterns("transcript.jsonl", "summary.md", "spend.json", "events.jsonl"))
    rows = []
    for line in (src / "bank.jsonl").read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        t = it[r["id"]]
        r.update(lang="it", question=t["question"], paraphrases={"it": t["paraphrases"], "en": r["paraphrases"].get("en", [])})
        rows.append(json.dumps(r, ensure_ascii=False))
    (out / "bank.jsonl").write_text("\n".join(rows) + "\n", encoding="utf-8")
    mf = out / "meta.json"
    if mf.exists():
        m = json.loads(mf.read_text())
        m["languages"] = ["it", "en"]
        mf.write_text(json.dumps(m, indent=1, ensure_ascii=False) + "\n")
    print(f"{out}: {len(rows)} Italian bank entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
