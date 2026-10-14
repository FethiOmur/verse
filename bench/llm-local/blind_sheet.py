"""Builds the blind scoring sheet (labels X/Y shuffled per question, key written to a separate file that is not
read until the scores are saved) and the automatic number-grounding check."""
import json, os, random, re, sys
import prompts as pr
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")

def numbers(s):
    return sorted(set(re.findall(r"\d[\d,\.]*\d|\d", s)))

def norm_num(n): return n.replace(",", "").rstrip(".")

def ungrounded(text, question):
    src = pr.PACK + " " + question + " " + " ".join(t.text for t in pr.TURNS)
    src_nums = {norm_num(n) for n in numbers(src)}
    out = []
    for n in numbers(text):
        if norm_num(n) in src_nums: continue
        out.append(n)
    return out

if __name__ == "__main__":
    g = {r["qid"]: r["text"] for r in json.load(open(os.path.join(R, "llm_quality_fp32.json")))["runs"]}
    h = {r["qid"]: r["text"] for r in json.load(open(os.path.join(R, "haiku_answers.json")))}
    rng = random.Random(20261014)
    key, sheet = {}, []
    for qid, q, kind in pr.QUESTIONS:
        order = ["gemma", "haiku"]; rng.shuffle(order)
        key[qid] = {"X": order[0], "Y": order[1]}
        ans = {"gemma": g[qid], "haiku": h[qid]}
        sheet.append(f"=== {qid} [{kind}] Q: {q}\n--- X:\n{ans[order[0]]}\n--- Y:\n{ans[order[1]]}\n")
    open(os.path.join(R, "blind_sheet.txt"), "w").write("\n".join(sheet))
    json.dump(key, open(os.path.join(R, "blind_key.json"), "w"), indent=1)
    print("sheet written; key in blind_key.json (do not read before scoring)")
