#!/usr/bin/env python3
"""Original music, sound effects and the mix for one film, generated from timeline.json.

Everything is synthesised here (no samples, no third-party audio), so it re-renders with the film.
  python3 scripts/audio/score.py --film hero [--no-narration]
Writes build/audio/<film>/{music,sfx,narration,mix}.wav (48 kHz stereo). The mix is ducked under
narration (about -9 dB) and later normalised to -16 LUFS / -1.5 dBTP by scripts/assemble.mjs.
"""
import json, os, sys, wave, argparse
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SR = 48000
BPM = 104
BEAT = 60 / BPM
rng = np.random.default_rng(7)

def midi(n): return 440 * 2 ** ((n - 69) / 12)
def T(sec): return int(round(sec * SR))

def env_adsr(n, a, d, s, r, sus_len=None):
    a, d, r = max(1, T(a)), max(1, T(d)), max(1, T(r))
    sus = max(0, n - a - d - r)
    e = np.concatenate([np.linspace(0, 1, a), np.linspace(1, s, d), np.full(sus, s), np.linspace(s, 0, r)])
    return e[:n] if len(e) >= n else np.pad(e, (0, n - len(e)))

def lowpass(x, cutoff):
    a = np.exp(-2 * np.pi * cutoff / SR)
    y = np.empty_like(x); acc = 0.0
    b = 1 - a
    for i in range(len(x)):  # small buffers only
        acc = b * x[i] + a * acc; y[i] = acc
    return y

def lp_fast(x, cutoff):
    # two cascaded one-pole lowpasses
    from scipy.signal import lfilter
    a = np.exp(-2 * np.pi * float(cutoff) / SR)
    return lfilter([1 - a], [1, -a], lfilter([1 - a], [1, -a], x))

# ---------- instruments ----------
def keys(f, dur, vel=0.5):
    n = T(dur + 1.2); t = np.arange(n) / SR
    mod = np.sin(2 * np.pi * f * 2 * t) * 1.2 * np.exp(-t * 6)
    x = np.sin(2 * np.pi * f * t + mod) + 0.25 * np.sin(2 * np.pi * f * 2 * t) * np.exp(-t * 3)
    e = np.exp(-t * 2.4) * np.minimum(1, t / 0.004)
    rel = np.clip((dur + 0.3 - t) / 0.3, 0, 1) ** 0.5
    return x * e * np.maximum(rel, 0.0) * vel * 0.32

def pluck(f, dur, vel=0.5, bright=0.5):
    n = T(dur + 0.8); N = max(2, int(SR / f))
    buf = rng.uniform(-1, 1, N) * vel
    buf = lp_fast(buf, 2000 + 6000 * bright)
    blocks = []
    cur = buf.copy()
    for _ in range(n // N + 1):
        blocks.append(cur)
        cur = 0.497 * (cur + np.roll(cur, -1))
    return np.concatenate(blocks)[:n] * 0.5

def pad(fs, dur, vel=0.4, bright=900):
    n = T(dur + 1.5); t = np.arange(n) / SR
    x = np.zeros(n)
    for f in fs:
        for det in (-0.12, 0.0, 0.11):
            ff = f * 2 ** (det / 12)
            x += np.sin(2 * np.pi * ff * t + rng.uniform(0, 6)) + 0.3 * np.sin(2 * np.pi * 2 * ff * t) + 0.12 * np.sin(2 * np.pi * 3 * ff * t)
    x = lp_fast(x / (len(fs) * 3), bright)
    return x * env_adsr(n, 0.9, 0.5, 0.85, 1.4) * vel * 0.55

def bass(f, dur, vel=0.5):
    n = T(dur + 0.3); t = np.arange(n) / SR
    x = np.sin(2 * np.pi * f * t) + 0.18 * np.sin(2 * np.pi * 2 * f * t)
    return x * env_adsr(n, 0.01, 0.15, 0.7, 0.25) * vel * 0.5

def kick(vel=0.5):
    n = T(0.35); t = np.arange(n) / SR
    f = 48 + 70 * np.exp(-t * 30)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 9) * vel * 0.7

def shaker(vel=0.3):
    n = T(0.09); t = np.arange(n) / SR
    x = rng.uniform(-1, 1, n); x = x - lp_fast(x, 5000)
    return x * np.exp(-t * 45) * np.minimum(1, t / 0.008) * vel * 0.35

def rim(vel=0.3):
    n = T(0.12); t = np.arange(n) / SR
    x = np.sin(2 * np.pi * 1650 * t) * np.exp(-t * 60) + rng.uniform(-1, 1, n) * np.exp(-t * 90) * 0.4
    return x * vel * 0.3

def bell(f, dur=2.5, vel=0.4):
    n = T(dur); t = np.arange(n) / SR
    x = np.sin(2 * np.pi * f * t + 0.8 * np.sin(2 * np.pi * f * 3.5 * t) * np.exp(-t * 3)) * np.exp(-t * 1.6)
    return x * np.minimum(1, t / 0.003) * vel * 0.35

def add(buf, x, at, pan=0.0, gain=1.0):
    i = T(at)
    if i >= buf.shape[0] or i + len(x) <= 0: return
    if i < 0: x = x[-i:]; i = 0
    x = x[: buf.shape[0] - i]
    l, r = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
    buf[i:i + len(x), 0] += x * l * gain * 1.41
    buf[i:i + len(x), 1] += x * r * gain * 1.41

# ---------- harmony ----------
F = 65  # F4 reference
PROG_TODAY = [[53, 57, 60, 64, 67], [57, 60, 64, 67], [50, 57, 60, 65, 69], [46, 53, 57, 62, 65]]  # Fmaj9, Am7, Dm9, Bbmaj7
BASS_TODAY = [41, 45, 38, 46]
PROG_FLOW = [[50, 57, 60, 64, 65], [46, 53, 57, 60, 64], [43, 50, 53, 57, 62], [45, 52, 55, 61, 64]]  # Dm(add9), Bbmaj7#11, Gm9, A7
BASS_FLOW = [38, 46, 43, 45]
ARP_TODAY = [[72, 69, 67, 64], [72, 69, 67, 64], [74, 72, 69, 65], [74, 70, 69, 65]]
ARP_FLOW = [[74, 69, 64, 69], [76, 69, 65, 70], [74, 70, 65, 67], [73, 69, 64, 67]]

def section(buf, kind, t0, dur, drops, frm=0.0):
    beats = int(round(dur / BEAT))
    def dropped(tt): return any(a <= tt - t0 < b for a, b in drops)
    # scene-relative sections (tension, resolve) are written in scene time; an excerpt starting at
    # `frm` keeps only what falls inside it.
    if kind in ("tension", "resolve") and frm:
        tmp = np.zeros((T(dur + frm + 6), 2))
        section(tmp, kind, 0.0, dur + frm, [], 0.0)
        seg = tmp[T(frm):T(frm + dur + 1.5)]
        seg = seg * np.minimum(1, np.arange(len(seg)) / T(0.25))[:, None]
        add(buf, seg[:, 0], t0, -1, 0.7071); add(buf, seg[:, 1], t0, 1, 0.7071)
        return
    if kind == "intro":
        add(buf, pad([midi(n) for n in [50, 57, 62, 65]], dur, 0.22, 800), t0)
        return
    if kind == "tension":
        freeze = 11.35
        for b in range(beats):
            tt = t0 + b * BEAT
            if tt - t0 < freeze:
                v = 0.25 + 0.4 * (tt - t0) / freeze
                add(buf, pluck(midi(50), 0.3, v, 0.3), tt, -0.2)
                if tt - t0 > 4.0: add(buf, pluck(midi(57), 0.2, v * 0.6, 0.4), tt + BEAT / 2, 0.25)
                if tt - t0 > 7.0:
                    add(buf, shaker(v), tt + BEAT / 4, 0.3); add(buf, shaker(v * 0.7), tt + 3 * BEAT / 4, -0.3)
                if b % 4 == 0: add(buf, kick(0.35 + 0.3 * (tt - t0) / freeze), tt)
        add(buf, pad([midi(50), midi(55), midi(57), midi(64)], freeze - 0.4, 0.22, 700), t0)
        # near silence after the freeze: a low drone and a single bell per statement
        add(buf, pad([midi(38), midi(45)], dur - freeze + 0.5, 0.16, 400), t0 + freeze)
        add(buf, bell(midi(81), 2.5, 0.18), t0 + 11.6); add(buf, bell(midi(79), 2.5, 0.16), t0 + 13.75)
        return
    if kind == "reveal":
        drop = 2 * BEAT
        add(buf, pad([midi(n) for n in PROG_TODAY[0]], dur - drop, 0.32, 1100), t0 + drop)
        add(buf, bass(midi(41), 4 * BEAT, 0.45), t0 + drop)
        motif = [(6, 72), (6.5, 69), (7, 76), (8, 77)]
        for bb, n in motif: add(buf, keys(midi(n), 0.6, 0.42), t0 + bb * BEAT, 0.15)
        for b in range(10, beats):
            tt = t0 + b * BEAT; ch = (b // 4) % 4
            add(buf, keys(midi(ARP_TODAY[ch][b % 4]), 0.4, 0.22), tt, 0.25 if b % 2 else -0.25)
            if b % 4 == 0: add(buf, bass(midi(BASS_TODAY[ch]), 3.5 * BEAT, 0.35), tt)
        return
    if kind in ("theme", "flow"):
        flow = kind == "flow"
        prog, bassl, arp = (PROG_FLOW, BASS_FLOW, ARP_FLOW) if flow else (PROG_TODAY, BASS_TODAY, ARP_TODAY)
        bar0 = int(round(t0 / BEAT)) // 4
        for b in range(beats):
            tt = t0 + b * BEAT
            gb = int(round(tt / BEAT)); ch = (gb // 4) % 4
            if gb % 4 == 0 or b == 0:
                add(buf, pad([midi(n) for n in prog[ch]], 4 * BEAT, 0.26 if flow else 0.24, 1300 if flow else 1000), tt)
                add(buf, bass(midi(bassl[ch]), 3.6 * BEAT, 0.38), tt)
            if dropped(tt): continue
            for half in (0, 1):
                n = arp[ch][(2 * (gb % 2) + half) % 4]
                inst = pluck(midi(n), 0.35, 0.38, 0.6) if flow else keys(midi(n), 0.35, 0.2)
                add(buf, inst, tt + half * BEAT / 2, 0.3 if half else -0.3)
            if not flow and gb % 2 == 0: add(buf, kick(0.32), tt)
            add(buf, shaker(0.22), tt + BEAT / 2, 0.35)
            if gb % 4 == 3: add(buf, rim(0.25 if flow else 0.2), tt, -0.2)
        return
    if kind == "resolve":
        wake = 1.45; endc = 10.4
        add(buf, pad([midi(n) for n in [53, 57, 60, 64, 67]], endc - wake, 0.26, 1000), t0 + wake)
        for i, n in enumerate([72, 69, 67, 69, 72, 74, 72, 69]):
            add(buf, keys(midi(n), 0.9, 0.2), t0 + wake + 0.8 + i * 2 * BEAT, 0.2 if i % 2 else -0.2)
        add(buf, bass(midi(41), endc - wake - 0.5, 0.3), t0 + wake)
        # end card: the three-note signature, then the home chord
        for i, n in enumerate([69, 72, 77]): add(buf, bell(midi(n), 4.0, 0.42), t0 + endc + 0.15 + i * 0.36, [-0.2, 0.2, 0][i])
        add(buf, pad([midi(n) for n in [41, 53, 57, 60, 64]], dur - endc + 1, 0.3, 900), t0 + endc + 0.9)
        return

# ---------- sound effects (short, soft, tonal) ----------
def sfx(name):
    t = lambda d: np.arange(T(d)) / SR
    if name == "win":
        x = t(0.18); return np.sin(2 * np.pi * (520 + 300 * x / 0.18) * x) * np.exp(-x * 26) * 0.18
    if name == "err":
        x = t(0.3); return (np.sin(2 * np.pi * 220 * x) + 0.5 * np.sin(2 * np.pi * 233 * x)) * np.exp(-x * 12) * 0.16
    if name in ("statement",):
        x = t(0.9); n = rng.uniform(-1, 1, len(x)); return lp_fast(n, 900) * np.sin(np.pi * x / 0.9) ** 2 * 0.22
    if name == "clear":
        x = t(0.7); n = rng.uniform(-1, 1, len(x)); return (lp_fast(n, 1400) * (1 - x / 0.7) + lp_fast(n, 300) * (x / 0.7)) * np.exp(-x * 4) * 0.6
    if name in ("click",):
        x = t(0.05); return np.sin(2 * np.pi * 1800 * x) * np.exp(-x * 160) * 0.22
    if name in ("panel", "lens"):
        x = t(0.35); f = 660 if name == "panel" else 740
        return (np.sin(2 * np.pi * f * x) + 0.4 * np.sin(2 * np.pi * f * 1.5 * x)) * np.exp(-x * 14) * np.minimum(1, x / 0.01) * 0.14
    if name == "trigger":
        x = t(0.3); return (np.sin(2 * np.pi * 880 * x) * (x < 0.06) + np.sin(2 * np.pi * 880 * x) * (x > 0.14)) * np.exp(-(x % 0.14) * 50) * 0.12
    if name == "draw":
        x = t(0.95); n = rng.uniform(-1, 1, len(x))
        tone = np.sin(2 * np.pi * np.cumsum(300 + 500 * (x / 0.95) ** 1.5) / SR) * 0.35
        return (lp_fast(n, 2500) * 0.6 + tone) * np.sin(np.pi * np.minimum(1, x / 0.95)) * 0.22
    if name == "close":
        x = t(0.8); return sum(np.sin(2 * np.pi * f * x) * np.exp(-x * d) for f, d in [(784, 5), (1175, 7), (1568, 9)]) * np.minimum(1, x / 0.004) * 0.12
    if name == "lift":
        x = t(0.3); n = rng.uniform(-1, 1, len(x)); return lp_fast(n, 3000) * np.sin(np.pi * x / 0.3) ** 2 * 0.12
    if name in ("land", "insert", "ok", "grant"):
        x = t(0.45); f = {"land": 988, "insert": 880, "ok": 1047, "grant": 932}[name]
        return (np.sin(2 * np.pi * f * x) + 0.5 * np.sin(2 * np.pi * f * 2 * x) * np.exp(-x * 20)) * np.exp(-x * 10) * np.minimum(1, x / 0.003) * 0.17
    if name == "tick":
        x = t(0.12); return np.sin(2 * np.pi * 1320 * x) * np.exp(-x * 45) * 0.1
    if name == "voice":
        x = t(0.4); return np.sin(2 * np.pi * (440 + 220 * x / 0.4) * x) * np.exp(-x * 7) * 0.12
    if name == "merge":
        x = t(0.6); return (np.sin(2 * np.pi * 523 * x) + np.sin(2 * np.pi * 659 * x)) * np.exp(-x * 6) * np.minimum(1, x / 0.05) * 0.1
    if name == "drop":
        x = t(0.5); return np.sin(2 * np.pi * (500 - 260 * x / 0.5) * x) * np.exp(-x * 7) * 0.09
    if name == "split":
        x = t(0.6); return (np.sin(2 * np.pi * 587 * x) * (1 - x / 0.6) + np.sin(2 * np.pi * 880 * x) * (x / 0.6)) * np.exp(-x * 4) * 0.12
    if name == "handoff":
        x = t(0.7); return sum(np.sin(2 * np.pi * f * x) * np.exp(-x * 6) * (x > d) for f, d in [(659, 0), (880, 0.09), (1175, 0.18)]) * 0.11
    if name == "lock":
        x = t(0.3); return np.sin(2 * np.pi * 330 * x) * np.exp(-x * 18) * 0.16
    if name == "chapter":
        x = t(1.6); n = rng.uniform(-1, 1, len(x)); return lp_fast(n, 600) * np.sin(np.pi * x / 1.6) ** 2 * 0.25 + np.sin(2 * np.pi * 147 * x) * np.exp(-x * 2) * 0.15
    if name == "wake":
        x = t(1.4); return pad([midi(65), midi(72)], 0.6, 0.5, 1200)[: len(x)] * 0.5
    if name == "resume":
        x = t(0.8); return sum(np.sin(2 * np.pi * f * x) * np.exp(-x * 5) * (x > d) for f, d in [(698, 0), (880, 0.07), (1047, 0.14)]) * 0.12
    if name == "logo_small":
        return bell(midi(84), 1.6, 0.35)
    if name == "logo":
        x = t(1.6); n = rng.uniform(-1, 1, len(x)); return lp_fast(n, 500) * np.exp(-x * 3) * 0.15
    if name == "wheel":
        x = t(0.25); return np.sin(2 * np.pi * 784 * x) * np.exp(-x * 20) * 0.12
    raise KeyError(name)

def write(p, a):
    a = np.clip(a, -1, 1)
    with wave.open(p, "w") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((a * 32767).astype(np.int16).tobytes())

def read_mono(p):
    with wave.open(p) as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--film", default="hero"); ap.add_argument("--no-narration", action="store_true")
    o = ap.parse_args()
    tl = json.load(open(os.path.join(ROOT, "timeline.json")))
    film = tl["films"][o.film]
    total = sum(e["dur"] for e in film["entries"])
    N = T(total + 0.5)
    music, fx, narr = (np.zeros((N, 2)) for _ in range(3))
    t0 = 0.0
    log = []
    for e in film["entries"]:
        sc = tl["scenes"].get(e["scene"], {})
        frm = e.get("from", 0)
        kind = e.get("music")
        if kind: section(music, kind, t0, e["dur"], [(a - frm, b - frm) for a, b in (e.get("musicDrop") or sc.get("musicDrop") or [])], frm)
        cues = e.get("sfx", sc.get("sfx", []))
        for c in cues:
            at = c["at"] - frm
            if 0 <= at < e["dur"]: add(fx, sfx(c["name"]), t0 + at, 0.0)
        if not o.no_narration and e.get("captions", True) is not False:
            for n in (e.get("narration") if e.get("narration") is not None else sc.get("narration", [])):
                at = n["at"] - frm
                p = os.path.join(ROOT, "assets/audio/narration", n["id"] + ".wav")
                if 0 <= at < e["dur"] and os.path.exists(p):
                    add(narr, read_mono(p), t0 + at, 0.0, 0.5); log.append((round(t0 + at, 2), n["id"]))
        t0 += e["dur"]
    # duck music ~9 dB under narration
    lvl = np.abs(narr[:, 0]); lvl = lp_fast(lvl, 3)
    gate = np.clip(lvl / 0.01, 0, 1)
    gate = lp_fast(gate, 2.5)
    duck = 1 - gate * (1 - 10 ** (-9 / 20))
    music *= duck[:, None]
    # soft fades at head and tail
    fade = np.ones(N); fade[: T(0.05)] = np.linspace(0, 1, T(0.05)); fade[-T(1.2):] *= np.linspace(1, 0, T(1.2))
    out = os.path.join(ROOT, "build/audio", o.film); os.makedirs(out, exist_ok=True)
    music *= 0.7
    for name, a in [("music", music), ("sfx", fx), ("narration", narr)]: write(os.path.join(out, name + ".wav"), a * fade[:, None])
    mix = (music + fx + narr) * fade[:, None]
    write(os.path.join(out, "mix.wav"), mix * 0.8)
    print(f"{o.film}: {total:.2f}s, narration cues {len(log)}, peak {np.abs(mix).max():.2f}")

if __name__ == "__main__":
    main()
