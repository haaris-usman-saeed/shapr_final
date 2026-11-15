#!/usr/bin/env python3
"""Builds qa/report.md from qa/validate-*.json (Gate D) plus the review log in qa/gates.md."""
import glob, json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
rows = []
for p in sorted(glob.glob(os.path.join(ROOT, "qa", "validate-*.json"))):
    r = json.load(open(p))
    if "/proxy/" in r["file"]: continue
    v = r["video"]; a = r["audio"][0] if r["audio"] else {}
    L = r.get("loudness", {})
    c = r.get("captions", {})
    m, s = divmod(r["duration"], 60)
    rows.append(f"| `{os.path.basename(r['file'])}` | {int(m)}:{s:05.2f} | {v['width']}×{v['height']} | {v['fps']} | {v['codec']} {v.get('profile','')} {v['pix_fmt']} | {a.get('codec','–')} {a.get('sample_rate','')} Hz {a.get('channels','')}ch | {L.get('integrated_lufs','–')} LUFS / {L.get('true_peak_dbtp','–')} dBTP | {len(r['dead_air'])} | {len(r['spikes'])} | {c.get('count','–')} | {'PASS' if r['pass'] else 'FAIL: ' + '; '.join(r['problems'])} |")
gates = open(os.path.join(ROOT, "qa", "gates.md")).read()
known = open(os.path.join(ROOT, "qa", "known-issues.md")).read() if os.path.exists(os.path.join(ROOT, "qa", "known-issues.md")) else ""
md = f"""# QA report

## Gate D: exports

Measured by `scripts/validate.py` (ffprobe, frame differences on a 96×54 downscale, ebur128, SRT checks).
"Dead air" = any stretch over 2.5 s where the frame 1 s later is nearly identical. "Spikes" = a single frame that
differs from both neighbours while the neighbours match. Contact sheets: `qa/sheet-<export>.png`.

| File | Duration | Resolution | fps | Video | Audio | Loudness | Dead air | Spikes | Captions | Result |
|---|---|---|---|---|---|---|---|---|---|---|
""" + "\n".join(rows) + "\n\n" + gates.replace("# Review log (gates A–C)", "## Gates A–C: visual review") + "\n" + known
open(os.path.join(ROOT, "qa", "report.md"), "w").write(md)
print("qa/report.md written,", len(rows), "exports")
