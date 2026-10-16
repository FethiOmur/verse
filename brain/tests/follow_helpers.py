"""Fakes for the follow-my-answer tests: a concept embedder (no model, deterministic) and small drivers."""

from __future__ import annotations

import hashlib
import math

from verse_brain.runtime.embed import PREFIX
from verse_brain.runtime.follow import is_content, stem, tokenize

# Every stem of a group points at one concept axis. Texts that share a concept are close, texts that do not are as far as
# unrelated sentences are for the real model (cosine 0.78, `BASE`).
CONCEPTS = {
    "invoice": "lantern invoice extract field supplier pipeline llm structure read pull parse document",
    "entry": "manual data entry minute typing type 11 2 time hand",
    "courier": "courier route optimis empty van pilot 14 plan planned routing trips",
    "solo": "solo own alone myself mostly single handedly",
    "runner": "marathon race trail runner trailhead mobile store testflight half",
    "truck": "truck uncle drove kid turkey",
    "compass": "compass dispatch traffic replan live seconds 90 haulage",
    "accuracy": "accuracy accurate 96.4 totals percent heldout evaluation 400",
    "safety": "schema retry escalate human operator person confidence safeguards",
}
BASE = 0.78
_STEM_TO_CONCEPT = {stem(w): name for name, ws in CONCEPTS.items() for w in ws.split()}
_NAMES = list(CONCEPTS)
HASH_DIMS = 48


class ConceptEmbedder:
    def __init__(self) -> None:
        self.calls: list[str] = []

    def embed(self, text: str) -> list[float]:
        body = text[len(PREFIX):] if text.startswith(PREFIX) else text
        self.calls.append(body)
        concept = [0.0] * len(_NAMES)
        hashed = [0.0] * HASH_DIMS
        for t in tokenize(body):
            if not is_content(t):
                continue
            s = stem(t)
            c = _STEM_TO_CONCEPT.get(s)
            if c is not None:
                concept[_NAMES.index(c)] += 1.0
            else:
                hashed[int(hashlib.md5(s.encode()).hexdigest(), 16) % HASH_DIMS] += 0.5
        rest = concept + hashed
        n = math.sqrt(sum(x * x for x in rest)) or 1.0
        return [math.sqrt(BASE)] + [math.sqrt(1 - BASE) * x / n for x in rest]


CARD = {
    "say": "Sure, I'll give you the short version.",
    "points": ["I built it mostly solo.",
               "Lantern cut manual data entry from 11 minutes to 2 minutes per invoice.",
               "I also built a small route optimiser for a courier pilot that reduced empty runs by 14 percent."],
}
PACK = ["Compass re-plans delivery routes every 90 seconds using live traffic and driver status.",
        "Accuracy on the held-out set was 96.4 percent for totals.",
        "Fields below 0.8 confidence go to a human operator; that was about 7 percent of invoices.",
        "The company builds route-planning software for mid-size European haulage firms."]
PACK_FOR_DETECTOR = PACK + CARD["points"] + [CARD["say"]]
