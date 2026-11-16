// Original, synthesised sound design (WebAudio). No samples. Every cue is logged with its clock time so
// the video exporter can mix the same sounds offline (scripts/audio.py renders the same recipes).
import { clock } from "../engine/clock";

export const audio = { muted: false, captions: true, ctx: null as AudioContext | null, capture: false };
export const cueLog: { t: number; kind: "sfx" | "line" | "music"; id: string }[] = [];
(window as any).__cues = cueLog;

function ctx() {
  if (audio.capture || audio.muted) return null;
  if (!audio.ctx) { try { audio.ctx = new AudioContext(); } catch { return null; } }
  if (audio.ctx.state === "suspended") audio.ctx.resume();
  return audio.ctx;
}

type Note = { f: number; t?: number; d?: number; g?: number; type?: OscillatorType };
function tones(notes: Note[], master = 0.12) {
  const c = ctx(); if (!c) return;
  const out = c.createGain(); out.gain.value = master; out.connect(c.destination);
  for (const n of notes) {
    const o = c.createOscillator(), g = c.createGain(), t0 = c.currentTime + (n.t ?? 0), d = n.d ?? 0.6;
    o.type = n.type ?? "sine"; o.frequency.value = n.f;
    g.gain.setValueAtTime(0, t0); g.gain.linearRampToValueAtTime(n.g ?? 1, t0 + 0.008); g.gain.exponentialRampToValueAtTime(0.0008, t0 + d);
    o.connect(g); g.connect(out); o.start(t0); o.stop(t0 + d + 0.05);
  }
}
function noise(dur: number, from: number, to: number, master = 0.08) {
  const c = ctx(); if (!c) return;
  const b = c.createBuffer(1, Math.floor(c.sampleRate * dur), c.sampleRate), d = b.getChannelData(0);
  for (let i = 0; i < d.length; i++) d[i] = (Math.random() * 2 - 1) * Math.sin((Math.PI * i) / d.length);
  const s = c.createBufferSource(); s.buffer = b;
  const f = c.createBiquadFilter(); f.type = "bandpass"; f.Q.value = 3; f.frequency.setValueAtTime(from, c.currentTime); f.frequency.exponentialRampToValueAtTime(to, c.currentTime + dur);
  const g = c.createGain(); g.gain.value = master;
  s.connect(f); f.connect(g); g.connect(c.destination); s.start();
}

const N = (m: number) => 440 * 2 ** ((m - 69) / 12);
export const RECIPES: Record<string, () => void> = {
  start: () => tones([{ f: N(72), d: 0.9 }, { f: N(79), t: 0.09, d: 1.1 }, { f: N(84), t: 0.18, d: 1.4, g: 0.6 }], 0.1),
  open: () => tones([{ f: N(81), d: 0.25, g: 0.6 }, { f: N(88), t: 0.03, d: 0.2, g: 0.3 }], 0.06),
  grant: () => tones([{ f: N(76), d: 0.5 }, { f: N(83), t: 0.07, d: 0.7 }], 0.09),
  deny: () => tones([{ f: N(57), d: 0.35, type: "triangle" }], 0.08),
  tick: () => tones([{ f: N(88), d: 0.12, g: 0.7 }], 0.05),
  draw: () => noise(0.95, 600, 2600, 0.06),
  close: () => tones([{ f: N(79), d: 0.9 }, { f: N(86), d: 1.0, g: 0.6 }, { f: N(91), d: 1.1, g: 0.4 }], 0.08),
  lens: () => { tones([{ f: N(84), d: 0.6 }, { f: N(88), t: 0.05, d: 0.7, g: 0.7 }], 0.07); noise(0.4, 3000, 6000, 0.03); },
  save: () => tones([{ f: N(74), d: 0.5 }, { f: N(81), t: 0.08, d: 0.8 }], 0.09),
  merge: () => tones([{ f: N(69), d: 0.5, g: 0.6 }, { f: N(76), d: 0.6, g: 0.6 }], 0.06),
  expire: () => tones([{ f: N(64), d: 0.3, g: 0.5, type: "triangle" }], 0.04),
  settle: () => tones([{ f: N(65), d: 1.6 }, { f: N(72), d: 1.6, g: 0.7 }, { f: N(76), d: 1.8, g: 0.6 }, { f: N(81), t: 0.12, d: 1.8, g: 0.4 }], 0.08),
  resume: () => tones([{ f: N(65), d: 1.2 }, { f: N(69), t: 0.1, d: 1.2 }, { f: N(72), t: 0.2, d: 1.4 }, { f: N(77), t: 0.3, d: 1.8, g: 0.6 }], 0.09),
  branch: () => tones([{ f: N(74), d: 0.9 }, { f: N(71), t: 0.12, d: 0.9 }, { f: N(78), t: 0.12, d: 0.9 }], 0.08),
  logo: () => tones([{ f: N(69), d: 2.6 }, { f: N(72), t: 0.36, d: 2.6 }, { f: N(77), t: 0.72, d: 3.4 }, { f: N(53), t: 0.72, d: 3.4, g: 0.5 }], 0.1),
  whoosh: () => noise(0.7, 300, 1200, 0.05),
};

export function sfx(id: keyof typeof RECIPES | string) {
  cueLog.push({ t: clock.now(), kind: "sfx", id });
  RECIPES[id]?.();
}
