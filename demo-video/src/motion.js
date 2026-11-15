// The motion system. Every scene animates through these functions and nothing else.
// Time is always seconds since the start of the scene; nothing reads the wall clock.

export const FPS = 30;

function bezier(x1, y1, x2, y2) {
  const cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx;
  const cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  const sx = (t) => ((ax * t + bx) * t + cx) * t;
  const sy = (t) => ((ay * t + by) * t + cy) * t;
  const dx = (t) => (3 * ax * t + 2 * bx) * t + cx;
  return (x) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let t = x;
    for (let i = 0; i < 8; i++) {
      const e = sx(t) - x, d = dx(t);
      if (Math.abs(e) < 1e-6) break;
      if (Math.abs(d) < 1e-6) break;
      t -= e / d;
    }
    let lo = 0, hi = 1;
    for (let i = 0; i < 20 && Math.abs(sx(t) - x) > 1e-6; i++) {
      if (sx(t) < x) lo = t; else hi = t;
      t = (lo + hi) / 2;
    }
    return sy(t);
  };
}

export const ease = {
  move: bezier(0.2, 0, 0, 1),      // position, scale, camera
  enter: bezier(0.16, 1, 0.3, 1),  // things arriving
  exit: bezier(0.4, 0, 1, 1),      // things leaving (run ~30% faster)
  inOut: bezier(0.45, 0, 0.55, 1), // cursor travel
  linear: (x) => Math.min(1, Math.max(0, x)), // progress bars only
};

// A damped spring from 0 to 1 with a small overshoot (< 6%). Used only for the circle closing
// and a capture landing.
export function spring(x, overshoot = 0.045) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  const zeta = Math.sqrt(Math.log(overshoot) ** 2 / (Math.PI ** 2 + Math.log(overshoot) ** 2));
  const wd = Math.PI / 0.42; // first peak at 42% of the duration
  const wn = wd / Math.sqrt(1 - zeta * zeta);
  const t = x;
  const v = 1 - Math.exp(-zeta * wn * t) * (Math.cos(wd * t) + (zeta * wn / wd) * Math.sin(wd * t));
  // fade the residual to exactly 1 at x = 1
  const settle = x > 0.85 ? (x - 0.85) / 0.15 : 0;
  return v + (1 - v) * settle * settle;
}

export const D = {
  micro: 0.16, panel: 0.4, panelExit: 0.28, camera: 1.0, stagger: 0.055, textIn: 0.5, flight: 0.7,
};

export const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
export const lerp = (a, b, k) => a + (b - a) * k;
export const prog = (t, t0, dur) => clamp((t - t0) / dur);

// Tween one value: from `a` to `b` between t0 and t0+dur.
export function tw(t, t0, dur, a, b, e = ease.move) {
  return lerp(a, b, e(prog(t, t0, dur)));
}

// Visible 0..1 for something that enters at t0 and exits at t1 (exit 30% faster).
export function life(t, t0, t1, din = D.panel, dout = din * 0.7) {
  if (t < t0) return 0;
  if (t1 != null && t >= t1) return 1 - ease.exit(prog(t, t1, dout));
  return ease.enter(prog(t, t0, din));
}

// Piecewise keyframes: [[time, value, easeIntoThisKey?], ...]. Values may be numbers or objects of numbers.
export function keys(t, k) {
  if (t <= k[0][0]) return k[0][1];
  for (let i = 1; i < k.length; i++) {
    if (t <= k[i][0]) {
      const [t0, v0] = k[i - 1];
      const [t1, v1, e = ease.move] = k[i];
      const p = e((t - t0) / (t1 - t0));
      if (typeof v0 === "number") return lerp(v0, v1, p);
      const o = {};
      for (const key in v0) o[key] = lerp(v0[key], v1[key], p);
      return o;
    }
  }
  return k[k.length - 1][1];
}

// Minimum time a text must hold after it has finished animating in.
export const readHold = (text) => Math.max(1.2, 0.5 + 0.3 * text.trim().split(/\s+/).length);

// Deterministic pseudo-random numbers.
export function rng(seed) {
  let s = seed >>> 0 || 1;
  return () => {
    s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0;
    return s / 4294967296;
  };
}

// A slow drift so no held frame is ever completely static (about 1.5%).
export function drift(t, seed = 1) {
  return {
    dx: Math.sin(t * 0.21 + seed) * 6 + Math.sin(t * 0.13 + seed * 2) * 4,
    dy: Math.cos(t * 0.17 + seed) * 4,
    ds: 1 + 0.008 * Math.sin(t * 0.11 + seed),
  };
}

// Typing with a human cadence: pauses at word boundaries, a quicker run inside words.
// Returns the number of characters visible at time t.
export function typed(t, t0, text, { cps = 15, seed = 7 } = {}) {
  if (t < t0) return 0;
  const r = rng(seed);
  let at = t0;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    let d = (1 / cps) * (0.6 + r() * 0.8);
    if (ch === " ") d += 0.05 + r() * 0.06;
    if (",.…?!".includes(ch)) d += 0.12;
    at += d;
    if (t < at) return i;
  }
  return text.length;
}
export function typedDuration(text, opts) {
  let lo = 0, hi = 60;
  for (let i = 0; i < 30; i++) { const m = (lo + hi) / 2; if (typed(m, 0, text, opts) >= text.length) hi = m; else lo = m; }
  return hi;
}
// Deleting is faster than typing.
export function deleted(t, t0, n, cps = 45) {
  if (t < t0) return 0;
  return Math.min(n, Math.floor((t - t0) * cps));
}

// Caret blink (square wave, 1.06 s period), solid while typing.
export const caretOn = (t, typingUntil = -1) => t < typingUntil + 0.4 || Math.floor((t - typingUntil) / 0.53) % 2 === 0;

// Cursor: waypoints [{t, x, y, click?}] in world coordinates. The cursor travels on a gentle curve with
// ease-in-out, overshoots slightly and settles, and pauses ~150 ms before a click.
export function cursorAt(t, wps) {
  if (!wps.length) return null;
  if (t <= wps[0].t) return { x: wps[0].x, y: wps[0].y, press: 0 };
  let press = 0;
  for (const w of wps) {
    if (w.click) {
      const ct = w.t + (w.clickDelay ?? 0.15);
      const dt = t - ct;
      if (dt >= 0 && dt < 0.45) press = Math.max(press, dt < 0.1 ? dt / 0.1 : 1 - (dt - 0.1) / 0.35);
    }
  }
  for (let i = 1; i < wps.length; i++) {
    const a = wps[i - 1], b = wps[i];
    const start = a.t + (a.click ? (a.clickDelay ?? 0.15) + 0.12 : 0) + (a.hold ?? 0);
    if (t < start) return { x: a.x, y: a.y, press };
    if (t <= b.t) {
      const k = (t - start) / Math.max(0.001, b.t - start);
      const dx = b.x - a.x, dy = b.y - a.y, dist = Math.hypot(dx, dy) || 1;
      const bend = (b.bend ?? (i % 2 ? 0.12 : -0.1)) * dist;
      const nx = -dy / dist, ny = dx / dist;
      const e = ease.inOut(k);
      // overshoot along the direction of travel, settling by the end
      const os = Math.sin(Math.PI * clamp((k - 0.7) / 0.3)) * Math.min(14, dist * 0.03);
      const arc = 4 * e * (1 - e) * bend;
      return { x: a.x + dx * e + nx * arc + (dx / dist) * os, y: a.y + dy * e + ny * arc + (dy / dist) * os, press };
    }
  }
  const z = wps[wps.length - 1];
  return { x: z.x, y: z.y, press };
}

// Quadratic arc used by every "something is saved" flight (the film's recurring gesture).
export function arc(k, from, to, lift = 0.35) {
  const mx = (from.x + to.x) / 2, my = Math.min(from.y, to.y) - Math.abs(to.x - from.x) * lift;
  const u = 1 - k;
  return { x: u * u * from.x + 2 * u * k * mx + k * k * to.x, y: u * u * from.y + 2 * u * k * my + k * k * to.y };
}
