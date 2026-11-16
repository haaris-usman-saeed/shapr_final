// The circle gesture and the L/T/S selector. Autoplay draws a hand-made loop; presenters draw their own
// with the mouse (any rough loop over a selectable region works).
import { animate, set, run, ease, lerp, clamp } from "../engine/anim";
import { wait } from "../engine/clock";
import { D, h, rectOf, cur, placeCursor } from "./desktop";
import { actions } from "../state/store";
import { sfx } from "../audio/sfx";

const NS = "http://www.w3.org/2000/svg";
const svg = (tag: string, a: Record<string, string | number> = {}) => { const e = document.createElementNS(NS, tag); for (const k in a) e.setAttribute(k, String(a[k])); return e; };
type R = { x: number; y: number; w: number; h: number };
type P = { x: number; y: number };

// ---------- selectable regions ----------
export interface Selectable { id: string; el: HTMLElement; text: string; ref: string }
export const selectables: Selectable[] = [];
export function selectable(id: string, el: HTMLElement, text: string, ref: string) {
  const i = selectables.findIndex((s) => s.id === id); if (i >= 0) selectables.splice(i, 1);
  selectables.push({ id, el, text, ref });
}

// ---------- geometry ----------
function loopAround(r: R, seed = 3, turns = 1.1): P[] {
  let s = seed; const rnd = () => ((s = (s * 9301 + 49297) % 233280) / 233280);
  const ph = [rnd() * 6, rnd() * 6, rnd() * 6];
  const cx = r.x + r.w / 2, cy = r.y + r.h / 2, rx = r.w / 2 * 1.07 + 26, ry = r.h / 2 * 1.3 + 34;
  const pts: P[] = [], N = 220, a0 = -Math.PI * 0.62;
  for (let i = 0; i <= N; i++) {
    const k = i / N, a = a0 + k * Math.PI * 2 * turns;
    const wob = 1 + 0.035 * Math.sin(3 * a + ph[0]) + 0.025 * Math.sin(5 * a + ph[1]) + 0.02 * Math.sin(2 * a + ph[2]);
    const sp = 1 - 0.05 * k;
    pts.push({ x: cx + Math.cos(a) * rx * wob * sp, y: cy + Math.sin(a) * ry * wob * sp });
  }
  return pts;
}
function rrect(r: R, a0: P, M = 600, pad = 14, rad = 16): P[] {
  const x = r.x - pad, y = r.y - pad, w = r.w + 2 * pad, hh = r.h + 2 * pad;
  const segs: { len: number; at: (u: number) => P }[] = [];
  const L = (x0: number, y0: number, x1: number, y1: number) => segs.push({ len: Math.hypot(x1 - x0, y1 - y0), at: (u) => ({ x: x0 + (x1 - x0) * u, y: y0 + (y1 - y0) * u }) });
  const C = (cx: number, cy: number, s0: number) => segs.push({ len: (Math.PI / 2) * rad, at: (u) => ({ x: cx + Math.cos(s0 + u * Math.PI / 2) * rad, y: cy + Math.sin(s0 + u * Math.PI / 2) * rad }) });
  L(x + rad, y, x + w - rad, y); C(x + w - rad, y + rad, -Math.PI / 2); L(x + w, y + rad, x + w, y + hh - rad); C(x + w - rad, y + hh - rad, 0);
  L(x + w - rad, y + hh, x + rad, y + hh); C(x + rad, y + hh - rad, Math.PI / 2); L(x, y + hh - rad, x, y + rad); C(x + rad, y + rad, Math.PI);
  const total = segs.reduce((a, s) => a + s.len, 0), pts: P[] = [];
  for (let i = 0; i < M; i++) { let d = (i / M) * total; for (const sg of segs) { if (d <= sg.len) { pts.push(sg.at(d / sg.len)); break; } d -= sg.len; } }
  let best = 0, bd = 1e9; pts.forEach((p, i) => { const dd = Math.hypot(p.x - a0.x, p.y - a0.y); if (dd < bd) { bd = dd; best = i; } });
  return pts.slice(best).concat(pts.slice(0, best));
}
function outline(pts: P[], upto: number, w0: number, w1: number) {
  const n = Math.max(2, Math.floor(pts.length * upto)), A: string[] = [], B: string[] = [];
  for (let i = 0; i < n; i++) {
    const p = pts[i], q = pts[Math.min(pts.length - 1, i + 1)], o = pts[Math.max(0, i - 1)];
    let dx = q.x - o.x, dy = q.y - o.y; const d = Math.hypot(dx, dy) || 1; dx /= d; dy /= d;
    const k = i / (pts.length - 1), pr = Math.pow(Math.sin(Math.PI * clamp(k * 1.05)), 0.55) * (0.85 + 0.15 * Math.sin(k * 19));
    const w = (w0 + (w1 - w0) * pr) * (i === n - 1 ? 0.75 : 1) / 2;
    A.push(`${(p.x - dy * w).toFixed(1)} ${(p.y + dx * w).toFixed(1)}`); B.push(`${(p.x + dy * w).toFixed(1)} ${(p.y - dx * w).toFixed(1)}`);
  }
  return `M${A.join(" L")} L${B.reverse().join(" L")} Z`;
}

// ---------- the drawn circle ----------
export interface Circle { rect: R; done: () => Promise<void>; clear: () => Promise<void>; g: SVGGElement }
function layer() {
  const g = svg("g") as SVGGElement;
  const veil = svg("path", { fill: "#0E0D0C", "fill-rule": "evenodd", opacity: 0 });
  const under = svg("path", { fill: "rgba(255,255,255,.85)", opacity: 0 });
  const stroke = svg("path", { fill: "#C45A2C", style: "filter: drop-shadow(0 0 5px rgba(224,138,94,.7)) drop-shadow(0 0 2px rgba(224,138,94,.6))" });
  const pen = svg("g"); pen.append(svg("circle", { r: 9, fill: "#fff" }), svg("circle", { r: 6.5, fill: "#C45A2C" }));
  g.append(veil, under, stroke, pen); D.fx.append(g);
  return { g, veil, under, stroke, pen };
}

/** Autoplay: the cursor draws a loop around `target`, which springs into a rounded rectangle. */
export async function drawCircle(target: HTMLElement, opts: { seed?: number; dur?: number } = {}): Promise<Circle> {
  const r = rectOf(target), pad = 6;
  const rect = { x: r.x - pad, y: r.y - pad, w: r.w + 2 * pad, h: r.h + 2 * pad };
  const L = layer(), turns = 1.1, loop = loopAround(rect, opts.seed ?? 5, turns), N = loop.length;
  const RS = rrect(rect, loop[0]); const tgt = loop.map((_, i) => RS[Math.round((i / (N - 1)) * turns * RS.length) % RS.length]);
  L.veil.setAttribute("d", `M-500 -500H2500V1600H-500Z`);
  animate(L.veil as any, {}, {});
  run(200, (k) => L.veil.setAttribute("opacity", String(0.08 * k)));
  sfx("draw");
  const dur = opts.dur ?? 900;
  await run(dur, (k) => {
    const d = 1 - (1 - k) * (1 - k) * (1 - 0.25 * k);
    L.stroke.setAttribute("d", outline(loop, Math.max(0.02, d), 3.2, 8));
    const p = loop[Math.min(N - 1, Math.floor(d * (N - 1)))];
    L.pen.setAttribute("transform", `translate(${p.x} ${p.y})`);
    cur.x = p.x; cur.y = p.y; placeCursor();
  });
  sfx("close");
  L.pen.setAttribute("opacity", "0");
  await run(360, (k) => {
    const sp = ease.spring(k);
    const pts = loop.map((p, i) => ({ x: lerp(p.x, tgt[i].x, sp), y: lerp(p.y, tgt[i].y, sp) }));
    const w0 = lerp(3.2, 4.2, sp), w1 = lerp(8, 4.2, sp);
    L.stroke.setAttribute("d", outline(pts, 1, w0, w1));
    L.under.setAttribute("d", outline(pts, 1, w0 + 3, w1 + 3)); L.under.setAttribute("opacity", String(0.9 * sp));
    const hole = pts.slice(0, Math.round(N / turns)).map((p) => `${p.x.toFixed(1)} ${p.y.toFixed(1)}`).join(" L");
    L.veil.setAttribute("d", `M-500 -500H2500V1600H-500Z M${hole}Z`); L.veil.setAttribute("opacity", String(lerp(0.08, 0.26, k)));
  });
  target.style.filter = "brightness(1.25)";
  return {
    rect, g: L.g, done: () => wait(0),
    clear: async () => { target.style.filter = ""; await run(260, (k) => (L.g.style.opacity = String(1 - k))); L.g.remove(); },
  };
}

/** Interactive: draw with the real pointer; a rough loop over a selectable region selects it. */
export function enableFreeDraw(onSelect: (s: Selectable, c: Circle) => void) {
  let pts: P[] = []; let L: ReturnType<typeof layer> | null = null; let drawing = false;
  const toWorld = (e: PointerEvent) => { const w = D.world.getBoundingClientRect(), s = w.width / 1920; return { x: (e.clientX - w.left) / s, y: (e.clientY - w.top) / s }; };
  D.stage.addEventListener("pointerdown", (e) => {
    if (!(e.target as HTMLElement).closest(".code, .termp, .doc")) return;
    if ((e.target as HTMLElement).closest(".glass")) return;
    drawing = true; pts = [toWorld(e)]; L?.g.remove(); L = layer(); L.veil.setAttribute("d", "M-500 -500H2500V1600H-500Z"); L.veil.setAttribute("opacity", "0.06");
    sfx("draw"); e.preventDefault();
  });
  addEventListener("pointermove", (e) => {
    if (!drawing || !L) return; pts.push(toWorld(e as PointerEvent));
    L.stroke.setAttribute("d", outline(pts, 1, 3, 6)); const p = pts[pts.length - 1]; L.pen.setAttribute("transform", `translate(${p.x} ${p.y})`);
  });
  addEventListener("pointerup", () => {
    if (!drawing || !L) return; drawing = false;
    const xs = pts.map((p) => p.x), ys = pts.map((p) => p.y);
    const box = { x: Math.min(...xs), y: Math.min(...ys), w: Math.max(...xs) - Math.min(...xs), h: Math.max(...ys) - Math.min(...ys) };
    const hit = selectables.map((s) => { const r = rectOf(s.el); const ix = Math.max(0, Math.min(box.x + box.w, r.x + r.w) - Math.max(box.x, r.x)), iy = Math.max(0, Math.min(box.y + box.h, r.y + r.h) - Math.max(box.y, r.y)); return { s, a: (ix * iy) / Math.max(1, r.w * r.h) }; })
      .filter((x) => x.a > 0.25).sort((a, b) => b.a - a.a)[0];
    const g = L; L = null;
    if (!hit || box.w < 30 || box.h < 16) { run(240, (k) => (g.g.style.opacity = String(1 - k))).then(() => g.g.remove()); return; }
    g.g.remove();
    const c = { rect: rectOf(hit.s.el), g: g.g, done: () => wait(0), clear: async () => {} } as Circle;
    // replace the freehand stroke with the same clean lock as autoplay
    drawCircle(hit.s.el, { dur: 1 }).then((cc) => onSelect(hit.s, cc));
  });
}

// ---------- L / T / S ----------
export function ltsMenu(rect: R, onPick: (m: "L" | "T" | "S") => void) {
  const el = h("div", "lts glass", [["L", "Lens", "Understand this"], ["T", "Threads", "Remember this"], ["S", "Simulate", "Explore options"]]
    .map(([k, n, d]) => `<div class="o" data-m="${k}"><span class="L">${k}</span><div><b>${n}</b><span>${d}</span></div></div>`).join(""));
  D.layer.append(el);
  const x = Math.max(40, Math.min(rect.x - 10, 1920 - 680)), y = rect.y + rect.h + 22;
  el.style.left = "0"; el.style.top = "0";
  set(el, { x: x - 6, y: y - 10, o: 0, s: 0.94 }); el.style.transformOrigin = "0 0";
  animate(el, { x, y, o: 1, s: 1 }, { dur: 380, ease: ease.enter });
  [...el.querySelectorAll(".o")].forEach((o, i) => { set(o as HTMLElement, { o: 0, y: 6 }); animate(o as HTMLElement, { o: 1, y: 0 }, { dur: 320, delay: 80 + i * 55, ease: ease.enter }); });
  sfx("open");
  let picked = false;
  const pick = async (m: "L" | "T" | "S") => {
    if (picked) return; picked = true;
    el.querySelector(`[data-m="${m}"]`)!.classList.add("sel");
    actions.mode(m);
    await wait(260);
    animate(el, { o: 0, y: y + 6 }, { dur: 240, ease: ease.exit }).then(() => el.remove());
    onPick(m);
  };
  el.querySelectorAll(".o").forEach((o) => o.addEventListener("click", () => pick((o as HTMLElement).dataset.m as any)));
  const key = (e: KeyboardEvent) => { const k = e.key.toUpperCase(); if (["L", "T", "S"].includes(k)) { e.stopPropagation(); pick(k as any); removeEventListener("keydown", key, true); } };
  addEventListener("keydown", key, true);
  return { el, opt: (m: string) => el.querySelector(`[data-m="${m}"]`) as HTMLElement, close: () => { picked = true; removeEventListener("keydown", key, true); animate(el, { o: 0 }, { dur: 200 }).then(() => el.remove()); } };
}
