"""Label files validate against the schema; broken ones do not."""

import copy
import json
from pathlib import Path

import pytest

import labels

FILES = sorted(labels.DIALOGUES_DIR.glob("*.json"))


def test_twelve_dialogues_present():
    assert len(FILES) == 12


@pytest.mark.parametrize("path", FILES, ids=[p.stem for p in FILES])
def test_label_file_valid(path):
    assert labels.validate(json.loads(path.read_text())) == []


def test_mix_of_material():
    ds = labels.load_all()
    cats = {c for d in ds for u in d["utterances"] for c in [u["category"]]}
    assert {"exact", "paraphrase", "offbank", "other", "statement", "fragment"} <= cats
    assert sum(1 for d in ds if d["speakers"] == 2) == 6 and sum(1 for d in ds if d["speakers"] == 3) == 6
    for d in ds:
        assert 55 <= d["duration_s"] - 0 <= 130, (d["id"], d["duration_s"])
        # the three-speaker dialogues address the other interviewer and Alex by name
        if d["speakers"] == 3:
            assert any(u["addressee"] == "other" for u in d["utterances"]), d["id"]


@pytest.fixture
def good():
    return json.loads((labels.DIALOGUES_DIR / "d01.json").read_text())


def test_rejects_missing_key(good):
    d = copy.deepcopy(good)
    del d["utterances"][0]["addressee"]
    assert any("missing 'addressee'" in e for e in labels.validate(d))


def test_rejects_bad_category_and_question_without_addressee(good):
    d = copy.deepcopy(good)
    d["utterances"][0]["category"] = "banana"
    assert any("bad category" in e for e in labels.validate(d))
    d = copy.deepcopy(good)
    q = next(u for u in d["utterances"] if u["is_question"])
    q["addressee"] = None
    assert any("needs an addressee" in e for e in labels.validate(d))


def test_rejects_exact_without_bank_id_and_overlapping_times(good):
    d = copy.deepcopy(good)
    ex = next(u for u in d["utterances"] if u["category"] == "exact")
    ex["bank_id"] = None
    assert any("needs a bank_id" in e for e in labels.validate(d))
    d = copy.deepcopy(good)
    d["utterances"][2]["t_start"] = 0.0
    assert any("starts before the previous utterance ended" in e for e in labels.validate(d))


def test_rejects_non_english_and_spoken_owner(good):
    d = copy.deepcopy(good)
    d["lang"] = "it"
    assert any("English only" in e for e in labels.validate(d))
    d = copy.deepcopy(good)
    fe = next(u for u in d["utterances"] if u["speaker"] == "Alex")
    del fe["silent_s"]
    assert any("owner's utterances are silent" in e for e in labels.validate(d))
