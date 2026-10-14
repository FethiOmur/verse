"""Builds the markdown tables for RESULTS_stt_local.md from results/*.json.
Run: .venv/bin/python -I report.py   (reads results/*.json, prints markdown)."""
import glob, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
runs = {}  # (engine_label, tag) -> report
for p in sorted(glob.glob(os.path.join(HERE, "results", "*.json"))):
    d = json.load(open(p))
    if not isinstance(d, dict) or "engine" not in d or "smoke" in d["tag"]:
        continue
    label = d["engine"] + ("@0.2s" if "int0.2" in d["tag"] else "")
    runs[(label, d["tag"].replace("-int0.2", ""))] = d

def ms(x):
    return "-" if x is None else f"{x*1000:.0f}"

def pair(s):
    return f"{ms(s.get('p50'))} / {ms(s.get('p90'))}"

LABEL = {"apple": "Apple SpeechTranscriber + fastResults (control)", "nemotron": "Nemotron Speech Streaming 0.6B en, 560 ms CoreML",
         "moonshine": "Moonshine Medium Streaming (update 0.5 s, default)", "moonshine@0.2s": "Moonshine Medium Streaming (update 0.2 s)"}
VOICE = {"en": "Albert", "en-samantha": "Samantha"}

def row(eng, tag, full=True):
    d = runs.get((eng, tag))
    out = []
    if not d:
        return out
    for r in d["runs"]:
        if r["status"] != "ok":
            out.append(f"| {LABEL[eng]} | {r['lang']} | FAILED: {r.get('error')} |")
            continue
        s = r["summary"]
        q = s.get("qMarkRel", {})
        rtf = "n/a" if r.get("rtf") is None else f"{r['rtf']:.2f}"
        load = r.get("loadSec")
        if full:
            out.append(f"| {LABEL[eng]} | {VOICE[r['lang']]} | {pair(s['lastWordLagLoose'])} | {pair(s['finalLag'])} | "
                       f"{s['wer']*100:.1f}% | {rtf} | {r['cpuPct']:.0f}% | {r['peakRssMB']:.0f} | {('n/a (window leakage, see notes)' if (r['lang']=='en' and eng=='nemotron') else ms(q.get('p50')) + ' (n=' + str(q.get('n',0)) + ')')} |")
        else:
            out.append(f"| {LABEL[eng]} | {tag} | {VOICE[r['lang']]} | {pair(s['lastWordLagLoose'])} | {pair(s['finalLag'])} | {s['wer']*100:.1f}% | {rtf} | {r['cpuPct']:.0f}% | {r['peakRssMB']:.0f} |")
    return out

MAIN = [("apple", "rerun1"), ("nemotron", "rerun1"), ("moonshine", "rerun2"), ("moonshine@0.2s", "rerun1")]
print("## Main table (lighter-load runs)\n")
print("| engine | voice | last-word lag p50 / p90 (ms) | final lag p50 / p90 (ms) | WER | RTF | CPU % | peak RSS (MB) | `?` first seen after end p50 (ms) |\n|---|---|---|---|---|---|---|---|---|")
for e, t in MAIN:
    print("\n".join(row(e, t)))

print("\n## Every run (first run vs warm; heavy-load vs lighter-load)\n")
print("| engine | run | voice | last-word lag p50 / p90 (ms) | final lag p50 / p90 (ms) | WER | RTF | CPU % | peak RSS (MB) |\n|---|---|---|---|---|---|---|---|---|")
for e in ["apple", "nemotron", "moonshine", "moonshine@0.2s"]:
    for t in ["run1", "run2", "rerun1", "rerun2"]:
        print("\n".join(row(e, t, full=False)))

print("\n## Load times (s)\n")
print("| engine | run | load/prepare (s) |\n|---|---|---|")
for e in ["apple", "nemotron", "moonshine", "moonshine@0.2s"]:
    for t in ["run1", "run2", "rerun1", "rerun2"]:
        d = runs.get((e, t))
        if d:
            v = [r.get("loadSec") for r in d["runs"] if r.get("loadSec") is not None]
            print(f"| {LABEL[e]} | {t} | {v[0]:.2f} |" if v else f"| {LABEL[e]} | {t} | - |")

print("\n## Extra per run\n")
for (eng, tag), d in sorted(runs.items()):
    for r in d["runs"]:
        if r["status"] == "ok":
            s = r["summary"]
            print(f"- {eng} {tag} {VOICE[r['lang']]}: feeder late p50/max {r['feederLateP50Ms']:.1f}/{r['feederLateMaxMs']:.0f} ms, volatile coverage {s['volatileCoverage']*100:.0f}%, "
                  f"`?` in final {s['qMarkInFinalShare']*100:.0f}%, `?` visible at/before end {s['qMarkRelBeforeEndShare']*100:.0f}%, finals only at flush {s['finalsAfterFeedEnd']}, extra {r['extra']}")
