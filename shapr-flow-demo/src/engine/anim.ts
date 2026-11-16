// Tweens evaluated against the shared clock. Every motion in the demo goes through here.
import { clock } from "./clock";

export type Ease = (x: number) => number;

function bezier(x1: number, y1: number, x2: number, y2: number): Ease {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
  const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  const sx = (t: number) => ((ax * t + bx) * t + cx) * t, sy = (t: number) => ((ay * t + by) * t + cy) * t;
  const dx = (t: number) => (3 * ax * t + 2 * bx) * t + cx;
  return (x) => {
    if (x <= 0) return 0; if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) { const e = sx(t) - x, d = dx(t); if (Math.abs(e) < 1e-6 || Math.abs(d) < 1e-6) break; t -= e / d; }
    let lo = 0, hi = 1;
    for (let i = 0; i < 24 && Math.abs(sx(t) - x) > 1e-6; i++) { if (sx(t) < x) lo = t; else hi = t; t = (lo + hi) / 2; }
    return sy(t);
  };
}

export const ease = {
  move: bezier(0.2, 0, 0, 1),
  enter: bezier(0.16, 1, 0.3, 1),
  exit: bezier(0.4, 0, 1, 1),
  inOut: bezier(0.45, 0, 0.55, 1),
  soft: bezier(0.3, 0.05, 0.2, 1),
  linear: (x: number) => Math.min(1, Math.max(0, x)),
  /** Damped spring, overshoot about 4%. */
  spring: (x: number) => {
    if (x <= 0) return 0; if (x >= 1) return 1;
    const v = 1 - Math.exp(-6.2 * x) * Math.cos(9.5 * x);
    const s = x > 0.85 ? (x - 0.85) / 0.15 : 0;
    return v + (1 - v) * s * s;
  },
};

export const clamp = (v: number, a = 0, b = 1) => Math.min(b, Math.max(a, v));
export const lerp = (a: number, b: number, k: number) => a + (b - a) * k;

// ---------- element properties ----------
export type Props = { x?: number; y?: number; s?: number; sx?: number; sy?: number; r?: number; o?: number; blur?: number; bright?: number; sat?: number };
type Box = HTMLElement & { __p?: Required<Props>; __dirty?: boolean };
const DEF: Required<Props> = { x: 0, y: 0, s: 1, sx: 1, sy: 1, r: 0, o: 1, blur: 0, bright: 1, sat: 1 };

function box(el: Box) { if (!el.__p) el.__p = { ...DEF }; return el.__p; }

function apply(el: Box) {
  const p = el.__p!;
  const tf = `translate3d(${p.x.toFixed(2)}px, ${p.y.toFixed(2)}px, 0) scale(${(p.s * p.sx).toFixed(4)}, ${(p.s * p.sy).toFixed(4)})` + (p.r ? ` rotate(${p.r.toFixed(2)}deg)` : "");
  el.style.transform = tf;
  el.style.opacity = String(Math.round(p.o * 1000) / 1000);
  el.style.visibility = p.o <= 0.001 ? "hidden" : "";
  const f: string[] = [];
  if (p.blur > 0.01) f.push(`blur(${p.blur.toFixed(2)}px)`);
  if (Math.abs(p.bright - 1) > 0.001) f.push(`brightness(${p.bright.toFixed(3)})`);
  if (Math.abs(p.sat - 1) > 0.001) f.push(`saturate(${p.sat.toFixed(3)})`);
  el.style.filter = f.join(" ");
}

type Tween = { el?: Box; key?: keyof Props; from: number; to: number; start: number; dur: number; ease: Ease; fn?: (k: number) => void; done?: () => void };
let tweens: Tween[] = [];

export function set(el: HTMLElement, props: Props) {
  const p = box(el as Box);
  for (const k in props) {
    (p as any)[k] = (props as any)[k];
    tweens = tweens.filter((t) => !(t.el === el && t.key === k));
  }
  apply(el as Box);
}
export function get(el: HTMLElement, key: keyof Props) { return box(el as Box)[key]; }

/** Animate element properties. Returns a promise that resolves when the tween ends (on the clock). */
export function animate(el: HTMLElement, props: Props, opts: { dur?: number; ease?: Ease; delay?: number } = {}) {
  const dur = opts.dur ?? 400, start = clock.now() + (opts.delay ?? 0), e = opts.ease ?? ease.move;
  const p = box(el as Box);
  for (const k in props) {
    const key = k as keyof Props;
    const cur = valueAt(el as Box, key, start) ?? p[key];
    tweens = tweens.filter((t) => !(t.el === el && t.key === key));
    tweens.push({ el: el as Box, key, from: cur, to: (props as any)[k], start, dur, ease: e });
  }
  return clock.wait((opts.delay ?? 0) + dur);
}

function valueAt(el: Box, key: keyof Props, T: number): number | null {
  const t = tweens.find((x) => x.el === el && x.key === key);
  if (!t) return null;
  if (T <= t.start) return t.from;
  return lerp(t.from, t.to, t.ease(clamp((T - t.start) / t.dur)));
}

/** Run a callback with progress 0..1 over a duration (for paths, drawing, counters). */
export function run(dur: number, fn: (k: number) => void, opts: { ease?: Ease; delay?: number } = {}) {
  const start = clock.now() + (opts.delay ?? 0);
  tweens.push({ from: 0, to: 1, start, dur, ease: opts.ease ?? ease.linear, fn });
  return clock.wait((opts.delay ?? 0) + dur);
}

/** Apply all tweens at the current clock time. */
export function frame() {
  const T = clock.time;
  const dirty = new Set<Box>();
  const keep: Tween[] = [];
  for (const t of tweens) {
    if (T < t.start) { keep.push(t); continue; }
    const k = clamp((T - t.start) / Math.max(1, t.dur));
    const v = lerp(t.from, t.to, t.ease(k));
    if (t.fn) t.fn(t.ease(k));
    else if (t.el && t.key) { box(t.el)[t.key] = v; dirty.add(t.el); }
    if (k < 1) keep.push(t);
  }
  tweens = keep;
  dirty.forEach(apply);
}

export function clearTweens() { tweens = []; }
export const busy = () => tweens.length > 0;
