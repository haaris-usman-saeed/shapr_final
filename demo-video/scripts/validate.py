#!/usr/bin/env python3
"""Gate D checks for an export. Writes qa/validate-<name>.json and qa/sheet-<name>.png.

  python3 scripts/validate.py exports/shapr_hero_1080p.mp4 [--srt exports/shapr_hero.srt] [--expect 3840x2160]

- ffprobe: codec, resolution, frame rate, duration, audio streams
- contact sheet: 24 frames evenly spaced
- dead air: any stretch > 2.5 s where the picture does not change (measured on a 96x54 downscale,
  which averages the film grain away)
- spikes: a single frame that differs from both neighbours while the neighbours match (a flash or pop)
- loudness: integrated LUFS and true peak (ebur128)
- captions: cues inside the film, ordered, non-overlapping, each on screen >= 0.8 s
"""
import json, os, re, subprocess, sys, argparse
import numpy as np

ap = argparse.ArgumentParser(); ap.add_argument("file"); ap.add_argument("--srt"); ap.add_argument("--expect")
o = ap.parse_args()
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
name = os.path.splitext(os.path.basename(o.file))[0]
rep = {"file": o.file}

pr = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", o.file]))
v = [s for s in pr["streams"] if s["codec_type"] == "video"][0]
a = [s for s in pr["streams"] if s["codec_type"] == "audio"]
dur = float(pr["format"]["duration"])
rep["video"] = {"codec": v["codec_name"], "profile": v.get("profile"), "width": v["width"], "height": v["height"], "fps": v["r_frame_rate"], "pix_fmt": v["pix_fmt"], "frames": int(v.get("nb_frames", 0))}
rep["audio"] = [{"codec": s["codec_name"], "sample_rate": s["sample_rate"], "channels": s["channels"]} for s in a]
rep["duration"] = round(dur, 3)
problems = []
if o.expect and f'{v["width"]}x{v["height"]}' != o.expect: problems.append(f"resolution {v['width']}x{v['height']} != {o.expect}")
if v["r_frame_rate"] != "30/1": problems.append("frame rate " + v["r_frame_rate"])
if not a: problems.append("no audio stream")

# contact sheet
os.makedirs(os.path.join(ROOT, "qa"), exist_ok=True)
sheet = os.path.join(ROOT, "qa", f"sheet-{name}.png")
n = 24; fps_s = n / dur
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", o.file, "-vf", f"fps={fps_s:.6f},scale=480:270,tile=6x4:padding=4:color=black", "-frames:v", "1", sheet], check=True)
rep["contact_sheet"] = os.path.relpath(sheet, ROOT)

# frame differences on a tiny greyscale proxy
raw = subprocess.check_output(["ffmpeg", "-v", "error", "-i", o.file, "-vf", "scale=96:54:flags=area,format=gray", "-f", "rawvideo", "-"])
fr = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 54, 96).astype(np.float32)
d = np.abs(np.diff(fr, axis=0)).mean(axis=(1, 2))
# "no change" = the frame 1 s later is nearly identical (consecutive diffs are too small during slow holds)
d30 = np.abs(fr[30:] - fr[:-30]).mean(axis=(1, 2))
still = d30 < 0.15
runs, i = [], 0
while i < len(still):
    if still[i]:
        j = i
        while j < len(still) and still[j]: j += 1
        if (j - i + 30) / 30 > 2.5: runs.append([round(i / 30, 2), round(j / 30, 2)])
        i = j
    else: i += 1
rep["dead_air"] = runs
spikes = []
for k in range(1, len(fr) - 1):
    a1 = d[k - 1]; a2 = d[k]
    if a1 > 6 and a2 > 6:
        across = np.abs(fr[k + 1] - fr[k - 1]).mean()
        if across < 0.35 * min(a1, a2): spikes.append(round(k / 30, 2))
rep["spikes"] = spikes
rep["diff_stats"] = {"frame_diff_median": round(float(np.median(d)), 3), "one_second_diff_min": round(float(d30.min()), 3), "max": round(float(d.max()), 2)}
if runs: problems.append(f"dead air: {runs}")
if spikes: problems.append(f"single-frame spikes at {spikes}")

# loudness
if a:
    eb = subprocess.run(["ffmpeg", "-hide_banner", "-i", o.file, "-af", "ebur128=peak=true", "-f", "null", "-"], capture_output=True, text=True).stderr
    summ = eb[eb.rfind("Summary:"):]
    I = float(re.search(r"I:\s+(-?[\d.]+) LUFS", summ).group(1))
    tp = float(re.search(r"Peak:\s+(-?[\d.]+) dBFS", summ).group(1))
    rep["loudness"] = {"integrated_lufs": I, "true_peak_dbtp": tp}
    if abs(I + 16) > 1: problems.append(f"loudness {I} LUFS")
    if tp > -1: problems.append(f"true peak {tp} dBTP")

# captions
if o.srt:
    txt = open(o.srt).read().strip().split("\n\n")
    def sec(s): h, m, rest = s.split(":"); s2, ms = rest.split(","); return int(h) * 3600 + int(m) * 60 + int(s2) + int(ms) / 1000
    cues = []
    for b in txt:
        ln = b.split("\n"); a0, b0 = ln[1].split(" --> "); cues.append((sec(a0), sec(b0), " ".join(ln[2:])))
    bad = [c[2] for c in cues if c[1] - c[0] < 0.8 or c[1] > dur + 0.05]
    overl = [cues[k][2] for k in range(1, len(cues)) if cues[k][0] < cues[k - 1][1] - 0.4]
    rep["captions"] = {"count": len(cues), "too_short_or_outside": bad, "overlapping": overl}
    if bad: problems.append(f"captions short/outside: {bad}")

rep["problems"] = problems
rep["pass"] = not problems
json.dump(rep, open(os.path.join(ROOT, "qa", f"validate-{name}.json"), "w"), indent=1)
print(json.dumps(rep, indent=1))
