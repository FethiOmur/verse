import json, os
from common import build_queries, HERE
items = build_queries()
uniq = []
seen = {}
for it in items:
    if it["text"] not in seen:
        seen[it["text"]] = len(uniq)
        uniq.append(it["text"])
    it["qi"] = seen[it["text"]]
json.dump({"queries": uniq, "items": items}, open(os.path.join(HERE, "results", "queries.json"), "w"))
with open(os.path.join(HERE, "results", "queries.jsonl"), "w") as f:
    for q in uniq:
        f.write(json.dumps(q) + "\n")
print(len(items), "items,", len(uniq), "unique queries")
