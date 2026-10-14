"""Shared pieces of the F3 bench: bank loading, the blind query set (full text + word prefixes), and a Python
re-implementation of the production char 3-5-gram TF-IDF matcher (app/Sources/VerseTurns/Bank.swift).
The Python port is checked against the real Swift code (swiftref/) in analyze.py."""
from __future__ import annotations
import json, math, os, unicodedata
from collections import Counter

SESSION = os.path.expanduser("~/Library/Application Support/Verse/sessions/sample-interview")
HERE = os.path.dirname(os.path.abspath(__file__))
LANG = "en"


def load_bank():
    entries = []
    with open(os.path.join(SESSION, "bank.jsonl"), encoding="utf-8") as f:
        for line in f:
            d = json.loads(line)
            entries.append(d)
    entries.sort(key=lambda d: d["id"])
    return entries


def phrases(entry):
    out = [entry["question"]]
    p = entry.get("paraphrases", {}).get(LANG) or []
    if p:
        out += p
    else:
        for k in sorted(entry.get("paraphrases", {})):
            out += entry["paraphrases"][k]
    return out


def bank_docs():
    """-> (entry_ids, doc_text list, doc_entry index list)."""
    entries = load_bank()
    ids = [e["id"] for e in entries]
    docs, doc_entry = [], []
    for i, e in enumerate(entries):
        for p in phrases(e):
            docs.append(p)
            doc_entry.append(i)
    return ids, docs, doc_entry


def words(s):
    return s.split()


def build_queries():
    """Unique query texts with metadata. kind: para | dist_tune | dist_held; every word prefix k=1..n is included."""
    blind = json.load(open(os.path.join(HERE, "blind_set.json"), encoding="utf-8"))
    items = []  # dict(group, kind, target, src, k, n, text)
    for eid in sorted(blind["paraphrases"]):
        for j, s in enumerate(blind["paraphrases"][eid]):
            w = words(s)
            for k in range(1, len(w) + 1):
                items.append(dict(kind="para", target=eid, src=f"{eid}.{j}", k=k, n=len(w), text=" ".join(w[:k])))
    for kind, key in (("dist_tune", "distractors_tune"), ("dist_held", "distractors_heldout")):
        for j, s in enumerate(blind[key]):
            w = words(s)
            for k in range(1, len(w) + 1):
                items.append(dict(kind=kind, target=None, src=f"{kind}.{j}", k=k, n=len(w), text=" ".join(w[:k])))
    return items


def prefix_k(n, frac):
    return max(1, math.ceil(n * frac))


# ---- Python port of BankMatcher (character 3-5-gram TF-IDF, cosine, best phrase per entry) ----
def _normalize(s: str):
    out = [" "]
    last_space = True
    for ch in s.lower():
        cat = unicodedata.category(ch)
        if cat.startswith("L") or cat.startswith("M") or cat == "Nd":   # CharacterSet.letters ~ L* + M*; decimalDigits ~ Nd
            out.append(ch)
            last_space = False
        elif not last_space:
            out.append(" ")
            last_space = True
    if not last_space:
        out.append(" ")
    elif len(out) == 1:
        return []
    return out


def _ngram_counts(s: str):
    a = _normalize(s)
    c = Counter()
    for n in (3, 4, 5):
        if len(a) >= n:
            for i in range(len(a) - n + 1):
                c[(n, "".join(a[i:i + n]))] += 1
    return c


class NgramMatcher:
    def __init__(self, entry_ids, docs, doc_entry):
        self.entry_ids = entry_ids
        self.doc_entry = doc_entry
        counts = [_ngram_counts(d) for d in docs]
        keep = [i for i, c in enumerate(counts) if c]
        n = max(len(keep), 1)
        df = Counter()
        for i in keep:
            for k in counts[i]:
                df[k] += 1
        self.idf = {k: math.log((n + 1) / (c + 1)) + 1 for k, c in df.items()}
        self.unknown_idf = math.log(n + 1) + 1
        self.post = {}
        self.docvec = [None] * len(docs)
        for i in keep:
            vec = {k: (1 + math.log(tf)) * self.idf[k] for k, tf in counts[i].items()}
            norm = math.sqrt(sum(w * w for w in vec.values()))
            inv = 1 / norm if norm > 0 else 0
            vec = {k: w * inv for k, w in vec.items()}
            self.docvec[i] = vec
            for k, w in vec.items():
                self.post.setdefault(k, []).append((i, w))
        self.ndocs = len(docs)

    def doc_scores(self, text):
        q = _ngram_counts(text)
        if not q:
            return [0.0] * self.ndocs
        qv = {k: (1 + math.log(tf)) * self.idf.get(k, self.unknown_idf) for k, tf in q.items()}
        norm = math.sqrt(sum(w * w for w in qv.values()))
        out = [0.0] * self.ndocs
        if norm <= 0:
            return out
        for k, w in qv.items():
            pl = self.post.get(k)
            if pl:
                qw = w / norm
                for di, pw in pl:
                    out[di] += qw * pw
        return out

    def entry_scores(self, text):
        ds = self.doc_scores(text)
        es = [0.0] * len(self.entry_ids)
        for d, s in enumerate(ds):
            e = self.doc_entry[d]
            if s > es[e]:
                es[e] = s
        return es
