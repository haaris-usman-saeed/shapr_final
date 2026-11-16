#!/usr/bin/env python3
"""Audio for SHAPR FLOW. Everything original and generated here.

  python3 scripts/audio.py                 # narration mp3s + music for hero and trailer -> public/audio/
  python3 scripts/audio.py --mix hero      # mix for the exported video from build/hero/cues.json -> build/hero/mix.wav

Narration: Kokoro (open-weight TTS, run locally; set KOKORO_DIR to the folder with kokoro.onnx and voices.bin).
If Kokoro is unavailable the demo still works: captions carry every line. A human read can replace any line:
put <id>.wav in public/audio/human/ and re-run.
"""
import json, os, re, sys, wave, subprocess, argparse
import numpy as np
from scipy.signal import lfilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PUB = os.path.join(ROOT, "public", "audio")
SR = 48000
rng = np.random.default_rng(11)
T = lambda s: int(round(s * SR))
midi = lambda n: 440 * 2 ** ((n - 69) / 12)

def lp(x, fc):
    a = np.exp(-2 * np.pi * fc / SR)
    return lfilter([1 - a], [1, -a], lfilter([1 - a], [1, -a], x))

def lines():
    src = open(os.path.join(ROOT, "src", "audio", "narration.ts")).read()
    return dict(re.findall(r'(n\d\d): "([^"]+)"', src))

def write_wav(p, a, ch=1):
    a = np.clip(a, -1, 1)
    with wave.open(p, "w") as w:
        w.setnchannels(ch); w.setsampwidth(2); w.setframerate(SR); w.writeframes((a * 32767).astype(np.int16).tobytes())

def read_wav(p):
    with wave.open(p) as w:
        sr, ch, n = w.getframerate(), w.getnchannels(), w.getnframes()
        a = np.frombuffer(w.readframes(n), dtype=np.int16).astype(np.float32) / 32768
    if ch > 1: a = a.reshape(-1, ch).mean(1)
    if sr != SR: a = np.interp(np.linspace(0, len(a) - 1, int(len(a) * SR / sr)), np.arange(len(a)), a).astype(np.float32)
    return a

def narration():
    os.makedirs(PUB, exist_ok=True)
    L = lines(); durs = {}
    kok = None
    for i, (lid, text) in enumerate(sorted(L.items())):
        wav = os.path.join(ROOT, "build", "lines", lid + ".wav"); os.makedirs(os.path.dirname(wav), exist_ok=True)
        human = os.path.join(PUB, "human", lid + ".wav")
        if os.path.exists(human): a = read_wav(human)
        else:
            if kok is None:
                from kokoro_onnx import Kokoro
                d = os.environ.get("KOKORO_DIR", os.path.join(ROOT, "..", "demo-video", ".cache", "tts"))
                kok = Kokoro(os.path.join(d, "kokoro.onnx"), os.path.join(d, "voices.bin"))
            a, sr = kok.create(text.replace("Shapr", "Shaper"), voice="af_heart", speed=0.95, lang="en-us")
            a = np.interp(np.linspace(0, len(a) - 1, int(len(a) * SR / sr)), np.arange(len(a)), a).astype(np.float32)
        idx = np.where(np.abs(a) > 0.004)[0]; a = a[max(0, idx[0] - 900): idx[-1] + 3000]
        write_wav(wav, a * 0.95)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", wav, "-ar", "48000", "-b:a", "160k", os.path.join(PUB, lid + ".mp3")], check=True)
        durs[lid] = int(len(a) / SR * 1000)
        print(f"{lid} {durs[lid]/1000:.2f}s  {text}")
    json.dump(durs, open(os.path.join(PUB, "lines.json"), "w"))

# ---------------- music ----------------
def keys(f, dur, vel=0.5):
    n = T(dur + 1.0); t = np.arange(n) / SR
    x = np.sin(2 * np.pi * f * t + 1.1 * np.sin(2 * np.pi * f * 2 * t) * np.exp(-t * 6)) + 0.2 * np.sin(2 * np.pi * f * 2 * t) * np.exp(-t * 3)
    return x * np.exp(-t * 2.2) * np.minimum(1, t / 0.004) * vel * 0.3
def pad(fs, dur, vel=0.3, fc=1000):
    n = T(dur + 1.5); t = np.arange(n) / SR; x = np.zeros(n)
    for f in fs:
        for d in (-0.1, 0, 0.09):
            ff = f * 2 ** (d / 12); x += np.sin(2 * np.pi * ff * t + rng.uniform(0, 6)) + 0.25 * np.sin(4 * np.pi * ff * t)
    x = lp(x / (3 * len(fs)), fc)
    a, r = T(1.0), T(1.4); e = np.ones(n); e[:a] = np.linspace(0, 1, a); e[-r:] *= np.linspace(1, 0, r)
    return x * e * vel * 0.5
def sub(f, dur, vel=0.4):
    n = T(dur + 0.3); t = np.arange(n) / SR
    e = np.minimum(1, t / 0.02) * np.minimum(1, (dur + 0.3 - t) / 0.3)
    return np.sin(2 * np.pi * f * t) * e * vel * 0.45
def tick(vel=0.2):
    n = T(0.08); t = np.arange(n) / SR; x = rng.uniform(-1, 1, n); x = x - lp(x, 5000)
    return x * np.exp(-t * 50) * vel * 0.3
def bell(f, dur=3, vel=0.4):
    n = T(dur); t = np.arange(n) / SR
    return np.sin(2 * np.pi * f * t + 0.7 * np.sin(2 * np.pi * f * 3.5 * t) * np.exp(-t * 3)) * np.exp(-t * 1.5) * vel * 0.35

def add(buf, x, at, pan=0.0, g=1.0):
    i = T(at)
    if i >= len(buf): return
    x = x[: len(buf) - i]
    buf[i:i + len(x), 0] += x * g * (1 - max(0, pan)); buf[i:i + len(x), 1] += x * g * (1 + min(0, pan))

BPM = 92; BEAT = 60 / BPM
PROG_A = [[53, 57, 60, 64, 67], [50, 57, 60, 65, 69], [46, 53, 57, 62, 65], [48, 55, 60, 64, 67]]   # Fmaj9 Dm9 Bbmaj9 C(add9)
PROG_B = [[50, 57, 62, 64, 69], [46, 53, 60, 62, 67], [43, 50, 57, 62, 65], [45, 52, 57, 61, 64]]   # curious variation
ARP_A = [72, 69, 67, 64]; ARP_B = [74, 69, 65, 72]
ENERGY = {"forget": "tension", "on": "reveal", "permission": "calm", "understand": "theme", "memory": "kernel", "circle": "drop", "lens": "theme",
          "threads": "theme", "resume": "resume", "simulate": "curious", "control": "calm", "future": "finale",
          "t-forget": "tension", "t-permission": "calm", "t-memory": "kernel", "t-lens": "theme", "t-resume": "resume", "t-end": "end"}

def music(program):
    progs = json.load(open(os.path.join(ROOT, "src", "scenes", "programs.json")))[program]
    total = sum(progs.values()) / 1000
    buf = np.zeros((T(total + 2), 2)); t0 = 0.0
    for sid, ms in progs.items():
        d = ms / 1000; kind = ENERGY[sid]; beats = int(d / BEAT)
        prog, arp = (PROG_B, ARP_B) if kind in ("curious", "kernel") else (PROG_A, ARP_A)
        if kind == "tension":
            for b in range(beats):
                tt = t0 + b * BEAT
                if tt - t0 < d - 3.2: add(buf, keys(midi(50 + (7 if b % 4 == 3 else 0)), 0.3, 0.22 + 0.3 * (tt - t0) / d), tt, -0.2)
            add(buf, pad([midi(50), midi(57), midi(64)], d - 1, 0.18, 600), t0)
        elif kind == "end":
            for i, n in enumerate([69, 72, 77]): add(buf, bell(midi(n), 4, 0.4), t0 + 0.3 + i * 0.36, [-0.3, 0.3, 0][i])
            add(buf, pad([midi(n) for n in [41, 53, 57, 60, 64]], d, 0.26, 900), t0 + 1.0)
        elif kind == "resume":
            add(buf, pad([midi(38), midi(45)], 4.5, 0.12, 400), t0)  # night
            add(buf, pad([midi(n) for n in PROG_A[0]], d - 4.5, 0.26, 1100), t0 + 4.5)
            for i in range(int((d - 6) / (2 * BEAT))): add(buf, keys(midi([72, 69, 67, 72, 74, 72][i % 6]), 0.9, 0.18), t0 + 6 + i * 2 * BEAT, 0.2 if i % 2 else -0.2)
            add(buf, bell(midi(81), 3, 0.25), t0 + 4.6)
        else:
            for b in range(beats):
                tt = t0 + b * BEAT; gb = int(round(tt / BEAT)); ch = (gb // 4) % 4
                if gb % 4 == 0 or b == 0:
                    add(buf, pad([midi(n) for n in prog[ch]], 4 * BEAT, 0.24 if kind != "calm" else 0.2, 1100 if kind == "curious" else 950), tt)
                    if kind not in ("calm", "drop"): add(buf, sub(midi(prog[ch][0] - 12), 3.6 * BEAT, 0.35), tt)
                if kind in ("drop",) and b < 8: continue
                if kind in ("theme", "kernel", "curious", "finale", "reveal") and (kind != "reveal" or b >= 6):
                    for half in (0, 1):
                        add(buf, keys(midi(arp[(2 * (gb % 2) + half) % 4]), 0.35, 0.16 if kind != "finale" else 0.2), tt + half * BEAT / 2, 0.3 if half else -0.3)
                if kind in ("theme", "kernel", "finale"): add(buf, tick(0.2), tt + BEAT / 2, 0.3)
            if kind == "reveal": add(buf, bell(midi(84), 2.5, 0.3), t0 + 0.2)
            if kind == "finale":  # end card signature at the end of the finale
                for i, n in enumerate([69, 72, 77]): add(buf, bell(midi(n), 4, 0.42), t0 + d - 6.2 + i * 0.36, [-0.3, 0.3, 0][i])
        t0 += d
    n = len(buf); fade = np.ones(n); fade[-T(1.5):] = np.linspace(1, 0, T(1.5)); buf *= fade[:, None]
    buf *= 0.5 / max(1e-6, np.abs(buf).max())
    wav = os.path.join(ROOT, "build", f"music_{program}.wav"); os.makedirs(os.path.dirname(wav), exist_ok=True)
    write_wav(wav, buf.reshape(-1), 2) if False else write_stereo(wav, buf)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", wav, "-b:a", "192k", os.path.join(PUB, f"music_{program}.mp3")], check=True)
    print(f"music_{program}: {total:.1f}s")
    return buf

def write_stereo(p, a):
    a = np.clip(a, -1, 1)
    with wave.open(p, "w") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes((a * 32767).astype(np.int16).tobytes())

# the same sound recipes as src/audio/sfx.ts
def sfx(name):
    N = midi
    def tones(notes, master):
        L = max((n.get("t", 0) + n.get("d", 0.6)) for n in notes) + 0.1; out = np.zeros(T(L))
        for n in notes:
            t = np.arange(T(n.get("d", 0.6))) / SR; d = n.get("d", 0.6)
            env = np.minimum(1, t / 0.008) * np.exp(np.log(0.0008) * t / d)
            w = np.sin(2 * np.pi * n["f"] * t) if n.get("type") != "triangle" else 2 / np.pi * np.arcsin(np.sin(2 * np.pi * n["f"] * t))
            i = T(n.get("t", 0)); out[i:i + len(t)] += w * env * n.get("g", 1)
        return out * master
    def noise(d, f0, f1, m):
        n = T(d); x = rng.uniform(-1, 1, n) * np.sin(np.pi * np.arange(n) / n)
        return (lp(x, f1) - lp(x, f0) * 0.6) * m * 2
    R = {
        "start": lambda: tones([{"f": N(72), "d": .9}, {"f": N(79), "t": .09, "d": 1.1}, {"f": N(84), "t": .18, "d": 1.4, "g": .6}], .1),
        "open": lambda: tones([{"f": N(81), "d": .25, "g": .6}, {"f": N(88), "t": .03, "d": .2, "g": .3}], .06),
        "grant": lambda: tones([{"f": N(76), "d": .5}, {"f": N(83), "t": .07, "d": .7}], .09),
        "deny": lambda: tones([{"f": N(57), "d": .35, "type": "triangle"}], .08),
        "tick": lambda: tones([{"f": N(88), "d": .12, "g": .7}], .05),
        "draw": lambda: noise(.95, 600, 2600, .06),
        "close": lambda: tones([{"f": N(79), "d": .9}, {"f": N(86), "d": 1.0, "g": .6}, {"f": N(91), "d": 1.1, "g": .4}], .08),
        "lens": lambda: tones([{"f": N(84), "d": .6}, {"f": N(88), "t": .05, "d": .7, "g": .7}], .07),
        "save": lambda: tones([{"f": N(74), "d": .5}, {"f": N(81), "t": .08, "d": .8}], .09),
        "merge": lambda: tones([{"f": N(69), "d": .5, "g": .6}, {"f": N(76), "d": .6, "g": .6}], .06),
        "expire": lambda: tones([{"f": N(64), "d": .3, "g": .5, "type": "triangle"}], .04),
        "settle": lambda: tones([{"f": N(65), "d": 1.6}, {"f": N(72), "d": 1.6, "g": .7}, {"f": N(76), "d": 1.8, "g": .6}, {"f": N(81), "t": .12, "d": 1.8, "g": .4}], .08),
        "resume": lambda: tones([{"f": N(65), "d": 1.2}, {"f": N(69), "t": .1, "d": 1.2}, {"f": N(72), "t": .2, "d": 1.4}, {"f": N(77), "t": .3, "d": 1.8, "g": .6}], .09),
        "branch": lambda: tones([{"f": N(74), "d": .9}, {"f": N(71), "t": .12, "d": .9}, {"f": N(78), "t": .12, "d": .9}], .08),
        "logo": lambda: tones([{"f": N(69), "d": 2.6}, {"f": N(72), "t": .36, "d": 2.6}, {"f": N(77), "t": .72, "d": 3.4}, {"f": N(53), "t": .72, "d": 3.4, "g": .5}], .1),
        "whoosh": lambda: noise(.7, 300, 1200, .05),
    }
    return R[name]() if name in R else np.zeros(1)

def mix(program):
    info = json.load(open(os.path.join(ROOT, "build", program, "cues.json")))
    total = info["total"] / 1000
    mus = os.path.join(ROOT, "build", f"music_{program}.wav")
    if not os.path.exists(mus): music(program)
    with wave.open(mus) as w: m = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32).reshape(-1, 2) / 32768
    N_ = T(total + 1); out = np.zeros((N_, 2)); voice = np.zeros(N_)
    out[: min(N_, len(m))] += m[:N_] * 0.55
    for c in info["cues"]:
        at = c["t"] / 1000
        if c["kind"] == "sfx": x = sfx(c["id"]); add(out, x, at, 0, 1.2)
        elif c["kind"] == "line":
            p = os.path.join(ROOT, "build", "lines", c["id"] + ".wav")
            if os.path.exists(p): x = read_wav(p); i = T(at); voice[i:i + len(x)] += x[: max(0, N_ - i)]
    # duck music ~9 dB under the voice
    g = lp(np.clip(np.abs(voice) / 0.01, 0, 1), 3); g = lp(g, 2)
    out *= (1 - g * (1 - 10 ** (-9 / 20)))[:, None]
    out[:, 0] += voice; out[:, 1] += voice
    out[: T(0.05)] *= np.linspace(0, 1, T(0.05))[:, None]
    dst = os.path.join(ROOT, "build", program, "mix.wav"); write_stereo(dst, out * 0.6)
    print("mix", dst)

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--mix"); o = ap.parse_args()
    if o.mix: mix(o.mix)
    else:
        narration(); music("hero"); music("trailer")
