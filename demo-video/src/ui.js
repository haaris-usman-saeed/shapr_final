// Shapr surfaces, reconstructed from the Swift views at 1.3x scale. Flow concepts are separate and violet.
import { h, s, css, px, show, packOrb, keycap, shaprGlyph, tickSVG, lockSVG, micSVG, esc } from "./stage.js";
import { clamp, ease, prog, lerp, spring, rng } from "./motion.js";

const icon = (name, size = 20) => {
  const paths = {
    camera: "M4 8h3l1.6-2.2h6.8L17 8h3v11H4Z M12 10.3a3.6 3.6 0 1 1 0 7.2 3.6 3.6 0 0 1 0-7.2Z",
    pencil: "M4 20l1-4L15.5 5.5a2 2 0 0 1 2.9 0l.1.1a2 2 0 0 1 0 2.9L8 19Z",
    form: "M5 4h14v16H5Z M8 8h8 M8 12h8 M8 16h5",
    branch: "M7 4v16 M7 12c0-4 10-3 10-8 M17 4v0",
    link: "M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1 M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1",
    share: "M12 15V4 M8 8l4-4 4 4 M5 12v8h14v-8",
    plug: "M9 3v5 M15 3v5 M6 8h12v3a6 6 0 0 1-12 0Z M12 17v4",
    sync: "M20 11a8 8 0 0 0-14.5-4.5L4 8 M4 13a8 8 0 0 0 14.5 4.5L20 16 M4 4v4h4 M20 20v-4h-4",
    sparkle: "M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8Z",
    flag: "M6 21V4 M6 4h11l-2 4 2 4H6",
    eye: "M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12Z M12 9a3 3 0 1 1 0 6 3 3 0 0 1 0-6Z",
    cpu: "M7 7h10v10H7Z M10 3v4 M14 3v4 M10 17v4 M14 17v4 M3 10h4 M3 14h4 M17 10h4 M17 14h4",
    split: "M12 3v6 M12 9L6 15v6 M12 9l6 6v6",
    clock: "M12 3.5a8.5 8.5 0 1 1 0 17 8.5 8.5 0 0 1 0-17Z M12 7.5V12l3 2",
  };
  return s("svg", { width: size, height: size, viewBox: "0 0 24 24", fill: "none" },
    s("path", { d: paths[name] || paths.sparkle, stroke: "currentColor", "stroke-width": 1.7, "stroke-linecap": "round", "stroke-linejoin": "round" }));
};
export { icon };

// Corner card (app ToastView). Screenshots lead with the picture.
export function toastCard({ shot = null, title, meta, actions = [], pack = null, leading = null }) {
  const el = h("div", { class: "toast glass" });
  if (shot) el.append(h("div", { class: "t-shot" }, shot));
  const text = h("div", { style: { flex: 1, minWidth: 0 } }, h("div", { class: "t-title" }, title), meta ? h("div", { class: "t-meta" }, meta) : null);
  el.append(h("div", { class: "t-row" }, !shot && (leading || pack) ? (leading || packOrb(pack, 36)) : null, text));
  const btns = actions.map((a) => h("span", { class: "btn small" + (a.primary ? " primary" : "") }, a.label));
  if (btns.length) el.append(h("div", { class: "t-actions" }, ...btns));
  return { el, btns };
}

// Floating panel (app dsPanel + PanelHeader + PanelFooter).
export function panel({ title, sub, iconName = "sparkle", width = 620, body, foot = [], status = null, accent = "clay" }) {
  const el = h("div", { class: "panel glass", style: { width: px(width) } },
    h("div", { class: "p-head" }, h("div", { class: "p-icon" }, icon(iconName, 22)), h("div", {}, h("div", { class: "p-title" }, title), sub ? h("div", { class: "p-sub" }, sub) : null)),
    h("div", { class: "p-body" }, body));
  const btns = foot.map((b) => h("span", { class: "btn" + (b.primary ? (accent === "violet" ? " violet" : " primary") : "") }, b.label, b.keys ? keycap(b.keys, b.primary) : null));
  if (foot.length || status) el.append(h("div", { class: "p-foot" }, h("div", { class: "status" }, status || ""), ...btns));
  return { el, btns, status: el.querySelector(".status") };
}

// The real menu-bar menu (AppController.menuNeedsUpdate), abridged to the first block.
export function shaprMenu({ pack = null, others }) {
  const row = (label, k, opts = {}) => h("div", { class: "mn-row" + (opts.dim ? " dim" : "") + (opts.on ? " on" : "") },
    h("span", { class: "mn-check" }, opts.check ? "✓" : ""), opts.orb ? packOrb(opts.orb, 20) : null, h("span", { class: "mn-label" }, label), k ? h("span", { class: "mn-key" }, k) : null);
  const sep = () => h("div", { class: "mn-sep" });
  const el = h("div", { class: "menu glass solid" },
    row(pack ? `Equipped: ${pack.name}` : "Auto-sort is on", null, { dim: true }),
    sep(),
    row("Auto-sort", "0", { check: !pack }),
    ...(pack ? [row(pack.name, "1", { check: true, orb: pack })] : []),
    ...others.slice(0, 3).map((o, i) => row(o.name, String(i + (pack ? 2 : 1)), { orb: o })),
    sep(),
    row("Talk to Shapr: hold, say anything", "⌥V", { dim: true }),
    row("Scoop selection", "⌥C", { dim: true }),
    row("Circle to capture", "⌘⌘", { dim: true }),
    row("Open the wheel", "⌥S", { dim: true }),
    row("Not sure? Hold ⌥V and say “what can I say”", null, { dim: true }));
  return { el, rows: [...el.querySelectorAll(".mn-row")] };
}

// The pack wheel (Wheel.swift): one glass dial, six places, the middle says what you'd get.
export function wheel({ slots, equipped = 0 }) {
  const R = 195, C = 75; // ringRadius 150, centerRadius 58, × 1.3
  const size = R * 2;
  const svg = s("svg", { width: size, height: size, viewBox: `0 0 ${size} ${size}`, class: "wh-svg" });
  const wedge = s("path", { fill: "rgba(31,30,28,0.09)", class: "wh-wedge" });
  svg.append(wedge);
  for (let i = 0; i < 6; i++) {
    const a = ((i * 60 + 30 - 90) * Math.PI) / 180;
    svg.append(s("line", { x1: R + Math.cos(a) * (C + 15), y1: R + Math.sin(a) * (C + 15), x2: R + Math.cos(a) * (R - 15), y2: R + Math.sin(a) * (R - 15), stroke: "rgba(31,30,28,0.10)", "stroke-width": 1 }));
  }
  svg.append(s("circle", { cx: R, cy: R, r: C, fill: "none", stroke: "rgba(31,30,28,0.10)", "stroke-width": 1 }));
  const dial = h("div", { class: "wh-dial glass" }, svg);
  const labelR = (R + C) / 2 + 1;
  const places = slots.map((sl, i) => {
    const a = ((i * 60 - 90) * Math.PI) / 180;
    const el = h("div", { class: "wh-place", style: { left: px(R + Math.cos(a) * labelR - 57), top: px(R + Math.sin(a) * labelR - 24) } },
      sl ? h("div", { class: "wh-dot-wrap" }, h("i", { class: "wh-dot", style: { background: sl.color } }), i === equipped ? h("i", { class: "wh-ring" }) : null) : h("div", { class: "wh-plus" }, "+"),
      h("div", { class: "wh-name" + (i === equipped ? " eq" : "") }, sl ? sl.name : "New pack"));
    return el;
  });
  const midT = h("div", { class: "wh-mid-t" }, "Auto-sort");
  const midD = h("div", { class: "wh-mid-d" }, "On");
  const mid = h("div", { class: "wh-mid", style: { left: px(R - C), top: px(R - C), width: px(C * 2), height: px(C * 2) } }, midT, midD);
  const el = h("div", { class: "wheel", style: { width: px(size), height: px(size) } }, dial, ...places, mid);
  return {
    el, R,
    point(angleDeg, on) {
      const a0 = angleDeg - 26.5, a1 = angleDeg + 26.5, ri = C + 10, ro = R - 10;
      const p = (r, a) => `${R + r * Math.cos((a * Math.PI) / 180)} ${R + r * Math.sin((a * Math.PI) / 180)}`;
      wedge.setAttribute("d", `M${p(ro, a0)} A${ro} ${ro} 0 0 1 ${p(ro, a1)} L${p(ri, a1)} A${ri} ${ri} 0 0 0 ${p(ri, a0)} Z`);
      wedge.setAttribute("opacity", on.toFixed(3));
    },
    setMiddle(t, d) { midT.textContent = t; midD.textContent = d; },
    places,
  };
}

// The capture flight chip (CaptureFeedback.FlyingChip).
export function flyChip({ pack, title, thumb = null }) {
  const el = h("div", { class: "flychip" }, thumb || packOrb(pack, 26), h("span", {}, title));
  el.style.outline = `1.5px solid ${pack.color}99`;
  el.style.outlineOffset = "-1.5px";
  return { el };
}

// Talk to Shapr: a glass pill next to the cursor, a halo that swells with your voice, words as you say them.
export function voicePill() {
  const halo = h("i", { class: "vp-halo" });
  const disc = h("div", { class: "vp-disc" }, halo, h("span", { class: "vp-mic" }, micSVG(22, "#fff")));
  const words = h("div", { class: "vp-words" });
  const el = h("div", { class: "voicepill glass" }, disc, words);
  return { el, halo, words };
}

// ---- The circle (signature moment 1) ----
// A hand-drawn loop around a rect: slightly irregular, pressure-varying width, revealed along its length.
export function makeLoop(rect, seed = 3, turns = 1.1) {
  const r = rng(seed);
  const ph = [r() * 6, r() * 6, r() * 6];
  const cx = rect.x + rect.w / 2, cy = rect.y + rect.h / 2;
  const rx = rect.w / 2 * 1.07 + 26, ry = rect.h / 2 * 1.3 + 36;
  const N = 220, pts = [];
  const a0 = -Math.PI * 0.62; // start upper-left, go clockwise
  for (let i = 0; i <= N; i++) {
    const k = i / N;
    const a = a0 + k * Math.PI * 2 * turns;
    const wob = 1 + 0.035 * Math.sin(3 * a + ph[0]) + 0.025 * Math.sin(5 * a + ph[1]) + 0.02 * Math.sin(2 * a + ph[2]);
    const spiral = 1 - 0.05 * k; // ends inside the start so the loop visibly closes
    pts.push({ x: cx + Math.cos(a) * rx * wob * spiral, y: cy + Math.sin(a) * ry * wob * spiral, a });
  }
  return pts;
}
// The clean rounded rectangle the loop springs into, sampled at the same angles.
export function rectAt(rect, a, pad = 14, rad = 18) {
  const cx = rect.x + rect.w / 2, cy = rect.y + rect.h / 2;
  const hw = rect.w / 2 + pad, hh = rect.h / 2 + pad;
  const dx = Math.cos(a), dy = Math.sin(a);
  // ray-box intersection, then soften the corners
  const tx = hw / Math.max(1e-6, Math.abs(dx)), ty = hh / Math.max(1e-6, Math.abs(dy));
  const tt = Math.min(tx, ty);
  let x = dx * tt, y = dy * tt;
  const ix = hw - rad, iy = hh - rad;
  if (Math.abs(x) > ix && Math.abs(y) > iy) {
    const sx = Math.sign(x) * ix, sy = Math.sign(y) * iy;
    const ang = Math.atan2(y - sy, x - sx);
    x = sx + Math.cos(ang) * rad; y = sy + Math.sin(ang) * rad;
  }
  return { x: cx + x, y: cy + y };
}
// Points evenly spaced along a rounded rect's perimeter, clockwise, starting nearest the ray at angle a0.
export function rrectSamples(rect, a0, M = 400, pad = 14, rad = 18) {
  const x = rect.x - pad, y = rect.y - pad, w = rect.w + 2 * pad, hh = rect.h + 2 * pad;
  const segs = [];
  const line = (x0, y0, x1, y1) => segs.push({ len: Math.hypot(x1 - x0, y1 - y0), at: (u) => ({ x: x0 + (x1 - x0) * u, y: y0 + (y1 - y0) * u }) });
  const corner = (cx, cy, s0) => segs.push({ len: (Math.PI / 2) * rad, at: (u) => ({ x: cx + Math.cos(s0 + u * Math.PI / 2) * rad, y: cy + Math.sin(s0 + u * Math.PI / 2) * rad }) });
  line(x + rad, y, x + w - rad, y); corner(x + w - rad, y + rad, -Math.PI / 2);
  line(x + w, y + rad, x + w, y + hh - rad); corner(x + w - rad, y + hh - rad, 0);
  line(x + w - rad, y + hh, x + rad, y + hh); corner(x + rad, y + hh - rad, Math.PI / 2);
  line(x, y + hh - rad, x, y + rad); corner(x + rad, y + rad, Math.PI);
  const total = segs.reduce((a, s) => a + s.len, 0);
  const pts = [];
  for (let i = 0; i < M; i++) {
    let d = (i / M) * total;
    for (const sg of segs) { if (d <= sg.len) { pts.push(sg.at(d / sg.len)); break; } d -= sg.len; }
  }
  const cx = rect.x + rect.w / 2, cy = rect.y + rect.h / 2;
  let best = 0, bd = 1e9;
  pts.forEach((p, i) => { const da = Math.abs(Math.atan2(Math.sin(Math.atan2(p.y - cy, p.x - cx) - a0), Math.cos(Math.atan2(p.y - cy, p.x - cx) - a0))); if (da < bd) { bd = da; best = i; } });
  return pts.slice(best).concat(pts.slice(0, best));
}
export function rrectPath(rect, pad = 14, rad = 18) {
  const x = rect.x - pad, y = rect.y - pad, w = rect.w + 2 * pad, hh = rect.h + 2 * pad;
  return `M${x + rad} ${y}H${x + w - rad}A${rad} ${rad} 0 0 1 ${x + w} ${y + rad}V${y + hh - rad}A${rad} ${rad} 0 0 1 ${x + w - rad} ${y + hh}H${x + rad}A${rad} ${rad} 0 0 1 ${x} ${y + hh - rad}V${y + rad}A${rad} ${rad} 0 0 1 ${x + rad} ${y}Z`;
}
// Variable-width stroke as a filled outline. `upto` is 0..1 of the length; width follows pressure.
export function strokeOutline(pts, upto, wmin = 3, wmax = 7.5) {
  const n = Math.max(2, Math.floor(pts.length * upto));
  const L = [], Rr = [];
  for (let i = 0; i < n; i++) {
    const p = pts[i], q = pts[Math.min(pts.length - 1, i + 1)], o = pts[Math.max(0, i - 1)];
    let dx = q.x - o.x, dy = q.y - o.y; const d = Math.hypot(dx, dy) || 1; dx /= d; dy /= d;
    const k = i / (pts.length - 1);
    const pressure = Math.pow(Math.sin(Math.PI * clamp(k * 1.05)), 0.55) * (0.85 + 0.15 * Math.sin(k * 19));
    const tip = i === n - 1 ? 0.75 : 1;
    const w = (wmin + (wmax - wmin) * pressure) * tip / 2;
    L.push(`${(p.x - dy * w).toFixed(1)} ${(p.y + dx * w).toFixed(1)}`);
    Rr.push(`${(p.x + dy * w).toFixed(1)} ${(p.y - dx * w).toFixed(1)}`);
  }
  return `M${L.join(" L")} L${Rr.reverse().join(" L")} Z`;
}

// ---- Shapr Flow (concept) surfaces: violet ----
export function permissionPrompt({ app }) {
  const el = h("div", { class: "perm glass" },
    h("div", { class: "perm-h" }, h("span", { class: "perm-ic" }, icon("eye", 22)), h("div", {}, h("div", { class: "perm-t" }, `Let Shapr follow along in ${app}?`), h("div", { class: "perm-s" }, "Only while this session is on. You can change it any time."))),
    h("div", { class: "perm-a" }, h("span", { class: "btn" }, "Not this app"), h("span", { class: "btn violet" }, "Allow")));
  return { el, btns: [...el.querySelectorAll(".btn")] };
}

export function sessionPanel({ pack, apps }) {
  const rows = apps.map((a) => h("div", { class: "ss-row" }, h("span", { class: "ss-app" }, a.name), h("span", { class: "ss-state " + a.state.toLowerCase() }, a.state === "Blocked" ? lockSVG(15) : tickSVG(16), a.state)));
  const el = h("div", { class: "session glass" },
    h("div", { class: "ss-h" }, h("span", { class: "ss-live" }), h("div", {}, h("div", { class: "ss-t" }, "Working session"), h("div", { class: "ss-s" }, pack.name, " · started 10:42"))),
    h("div", { class: "ss-list" }, ...rows),
    h("div", { class: "ss-local" }, icon("cpu", 18), "Designed to process on this Mac"));
  return { el, rows };
}

export function lensCard({ items }) {
  const rows = items.map((it) => h("div", { class: "lens-row" }, h("div", { class: "lens-l" }, it.label), h("div", { class: "lens-t" }, it.text), h("span", { class: "lens-chip" }, it.chip)));
  const el = h("div", { class: "lens glass" }, h("div", { class: "lens-h" }, icon("sparkle", 18), "Lens"), ...rows);
  return { el, rows, chips: rows.map((r) => r.querySelector(".lens-chip")) };
}

export function eventChip(text) { return h("div", { class: "evchip" }, text); }

export function threadCard({ rows }) {
  const slots = rows.map(([k, v]) => h("div", { class: "th-row" }, h("div", { class: "th-k" }, k), h("div", { class: "th-v" }, v)));
  const el = h("div", { class: "thread glass solid" }, h("div", { class: "th-h" }, h("span", { class: "th-dot" }), "Thread · Aurora — Backend"), ...slots);
  return { el, slots };
}

export function simCard({ title, rows }) {
  const rs = rows.map(([k, v]) => h("div", { class: "sim-row" + (k === "Open assumption" ? " open" : "") }, h("div", { class: "sim-k" }, k), h("div", { class: "sim-v" }, v)));
  const el = h("div", { class: "sim glass solid" }, h("div", { class: "sim-t" }, title), ...rs);
  return { el, rows: rs };
}

export function noteCard(text, kind = "Note") {
  return h("div", { class: "note glass solid" }, h("div", { class: "note-k" }, kind), h("div", { class: "note-v" }, text));
}

export function resumeCard({ title, question, lines, button }) {
  const el = h("div", { class: "resume glass" },
    h("div", { class: "rs-t" }, title), h("div", { class: "rs-q" }, question),
    h("div", { class: "rs-lines" }, ...lines.map(([k, v]) => h("div", { class: "rs-line" }, h("span", { class: "rs-k" }, k), h("span", { class: "rs-v" }, v)))),
    h("div", { class: "rs-a" }, h("span", { class: "btn" }, "Later"), h("span", { class: "btn violet" }, button)));
  return { el, btn: el.querySelector(".btn.violet"), lines: [...el.querySelectorAll(".rs-line")] };
}
