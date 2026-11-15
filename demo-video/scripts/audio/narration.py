#!/usr/bin/env python3
"""Narration for every film in timeline.json.

For each narration cue id: if assets/audio/narration/human/<id>.wav exists (a human read), it is used.
Otherwise the line is synthesised with Kokoro (open-weight TTS, run locally) and saved as
assets/audio/narration/<id>.wav. Durations go to assets/audio/narration/manifest.json, which the
captions and the mixer read, so picture, captions and audio share one timing.

  python3 scripts/audio/narration.py [--voice af_heart] [--speed 0.96] [--force]
Model files: $KOKORO_DIR (default .cache/tts) must hold kokoro.onnx and voices.bin
(from github.com/thewh1teagle/kokoro-onnx releases, model-files-v1.0).
"""
import json, os, sys, wave, argparse
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "assets/audio/narration")
SR = 48000

# How the voice should say a word (the product is "Shapr", pronounced "shaper").
SAY = {"Shapr": "Shaper", "Shapr's": "Shaper's", "MCP": "M C P"}

def say(text):
    for k, v in SAY.items():
        text = text.replace(k, v)
    return text

def resample(x, sr_in, sr_out):
    if sr_in == sr_out: return x
    n = int(round(len(x) * sr_out / sr_in))
    return np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x).astype(np.float32)

def read_wav(p):
    with wave.open(p) as w:
        sr, ch, n = w.getframerate(), w.getnchannels(), w.getnframes()
        a = np.frombuffer(w.readframes(n), dtype=np.int16).astype(np.float32) / 32768
        if ch > 1: a = a.reshape(-1, ch).mean(1)
    return resample(a, sr, SR)

def write_wav(p, a):
    a = np.clip(a, -1, 1)
    with wave.open(p, "w") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((a * 32767).astype(np.int16).tobytes())

def trim(a, thr=0.004):
    idx = np.where(np.abs(a) > thr)[0]
    if not len(idx): return a
    s, e = max(0, idx[0] - int(0.02 * SR)), min(len(a), idx[-1] + int(0.08 * SR))
    return a[s:e]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--voice", default="af_heart"); ap.add_argument("--speed", type=float, default=0.96)
    ap.add_argument("--force", action="store_true")
    o = ap.parse_args()
    tl = json.load(open(os.path.join(ROOT, "timeline.json")))
    cues = {}
    for sc in tl["scenes"].values():
        for n in sc.get("narration", []): cues[n["id"]] = n["text"]
    for f in tl["films"].values():
        for e in f["entries"]:
            for n in e.get("narration", []) or []: cues[n["id"]] = n["text"]
    os.makedirs(OUT, exist_ok=True)
    man_p = os.path.join(OUT, "manifest.json")
    man = json.load(open(man_p)) if os.path.exists(man_p) else {"durations": {}, "texts": {}, "source": {}}
    kok = None
    for cid, text in sorted(cues.items()):
        human = os.path.join(OUT, "human", cid + ".wav")
        dst = os.path.join(OUT, cid + ".wav")
        if os.path.exists(human):
            a = trim(read_wav(human)); write_wav(dst, a); src = "human"
        elif o.force or not os.path.exists(dst) or man["texts"].get(cid) != text:
            if kok is None:
                from kokoro_onnx import Kokoro
                d = os.environ.get("KOKORO_DIR", os.path.join(ROOT, ".cache/tts"))
                kok = Kokoro(os.path.join(d, "kokoro.onnx"), os.path.join(d, "voices.bin"))
            a, sr = kok.create(say(text), voice=o.voice, speed=o.speed, lang="en-us")
            a = trim(resample(np.asarray(a, dtype=np.float32), sr, SR)); write_wav(dst, a); src = f"kokoro:{o.voice}@{o.speed}"
        else:
            a = read_wav(dst); src = man["source"].get(cid, "?")
        man["durations"][cid] = round(len(a) / SR, 3); man["texts"][cid] = text; man["source"][cid] = src
        print(f"{cid:6s} {man['durations'][cid]:5.2f}s  {src}  {text}")
    json.dump(man, open(man_p, "w"), indent=1)

if __name__ == "__main__":
    main()
