// The stage: a 1920x1080 desktop under a virtual camera, plus screen-space overlays
// (cursor, captions, statements, concept pill). Scenes are pure functions of time.
import { clamp, ease, lerp, prog, tw, life, drift, D } from "./motion.js";

export const W = 1920, H = 1080;

export function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === "style" && typeof v === "object") Object.assign(el.style, v);
    else if (k === "class") el.className = v;
    else if (k === "html") el.innerHTML = v;
    else el.setAttribute(k, v);
  }
  for (const kid of kids.flat()) if (kid != null && kid !== false) el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  return el;
}
export const svgNS = "http://www.w3.org/2000/svg";
export function s(tag, attrs = {}, ...kids) {
  const el = document.createElementNS(svgNS, tag);
  for (const [k, v] of Object.entries(attrs)) if (v != null) el.setAttribute(k, v);
  for (const kid of kids.flat()) if (kid) el.append(kid);
  return el;
}
export const esc = (t) => String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// Set style properties only when they change (keeps per-frame work small).
export function css(el, props) {
  const c = el.__css || (el.__css = {});
  for (const k in props) {
    const v = props[k];
    if (c[k] !== v) { c[k] = v; el.style[k] = v; }
  }
}
export const px = (n) => `${Math.round(n * 100) / 100}px`;
export function show(el, a, extra = {}) {
  css(el, { opacity: String(Math.round(clamp(a) * 1000) / 1000), visibility: a <= 0.001 ? "hidden" : "visible", ...extra });
}

// Shapr's menu-bar glyph: an original three-layer stack (stands in for SF Symbol square.stack.3d.up.fill).
export function shaprGlyph(size = 20, color = "currentColor") {
  return s("svg", { width: size, height: size, viewBox: "0 0 24 24", fill: "none" },
    s("path", { d: "M12 3.2 21 7.6 12 12 3 7.6Z", fill: color }),
    s("path", { d: "M4.6 11.2 12 14.8l7.4-3.6L21 12l-9 4.4L3 12Z", fill: color, opacity: "0.72" }),
    s("path", { d: "M4.6 15.6 12 19.2l7.4-3.6L21 16.4l-9 4.4L3 16.4Z", fill: color, opacity: "0.48" }));
}

export function packOrb(pack, size = 24) {
  return h("div", { class: "orb", style: { width: px(size), height: px(size), background: pack.color, fontSize: px(size * (pack.initials.length > 1 ? 0.36 : 0.44)) } }, pack.initials);
}

export function keycap(k, onAccent = false) { return h("span", { class: "keycap" + (onAccent ? " on-accent" : "") }, k); }

export class Stage {
  constructor(root, { story, wallpaper = "day" } = {}) {
    this.story = story;
    this.frame = h("div", { class: "frame" });
    this.world = h("div", { class: "world" });
    this.desk = h("div", { class: "desk" });
    this.wall = h("div", { class: "wall " + wallpaper });
    this.apps = h("div", { class: "apps" });
    this.veil = h("div", { class: "veil" });
    this.desk.append(this.wall, this.apps);
    this.menubar = this.buildMenubar();
    this.shapr = h("div", { class: "shapr-layer" });
    this.fx = h("div", { class: "fx-layer" });
    this.world.append(this.desk, this.veil, this.menubar.el, this.shapr, this.fx);
    this.screen = h("div", { class: "screen" });
    this.cursorEl = h("div", { class: "cursor" }, cursorSVG(), h("div", { class: "press" }));
    this.screen.append(this.cursorEl);
    this.frame.append(this.world, this.screen);
    root.append(this.frame);
    this.cam = { x: W / 2, y: H / 2, s: 1 };
  }

  buildMenubar() {
    const icon = h("div", { class: "mb-shapr" }, h("span", { class: "glyph" }, shaprGlyph(21)), h("span", { class: "tick" }, tickSVG(19)), h("span", { class: "word" }, ""));
    const app = h("span", { class: "mb-app" }, "Code");
    const clock = h("span", { class: "mb-clock" }, "Tue 10:42");
    const el = h("div", { class: "menubar" },
      h("div", { class: "mb-left" }, h("span", { class: "mb-dot" }), app, ...["File", "Edit", "View", "Window", "Help"].map((m) => h("span", { class: "mb-item" }, m))),
      h("div", { class: "mb-right" }, icon, h("span", { class: "mb-sys" }, wifiSVG()), h("span", { class: "mb-sys" }, batterySVG()), clock));
    const self = this;
    let cached = null;
    return { el, icon, app, clock, setWord: (w) => { icon.querySelector(".word").textContent = w; cached = null; },
      center: () => {
        if (!cached) {
          const r = icon.querySelector(".glyph").getBoundingClientRect(), wr = self.world.getBoundingClientRect(), sc = wr.width / 1920;
          cached = { x: (r.left + r.width / 2 - wr.left) / sc, y: (r.top + r.height / 2 - wr.top) / sc };
        }
        return cached;
      } };
  }

  // Shapr icon reaction: one short pulse; `tickA` swaps the glyph for a tick briefly.
  menubarPulse(t, at) {
    const k = prog(t, at, 0.42);
    const sc = k > 0 && k < 1 ? 1 + 0.22 * Math.sin(Math.PI * k) : 1;
    const tick = t >= at && t < at + 0.9 ? 1 : 0;
    css(this.menubar.icon.querySelector(".glyph"), { transform: `scale(${sc.toFixed(3)})`, opacity: tick ? "0" : "1" });
    css(this.menubar.icon.querySelector(".tick"), { opacity: String(tick), transform: `scale(${sc.toFixed(3)})` });
  }

  // Camera: centre (x, y) in world coordinates, scale s. `driftOn` adds the slow hold drift.
  camera({ x, y, s: sc }, t = 0, driftAmt = 1) {
    const d = drift(t);
    sc = sc * (1 + (d.ds - 1) * driftAmt);
    x += d.dx * driftAmt / sc; y += d.dy * driftAmt / sc;
    // keep the view inside the desktop
    const hw = W / 2 / sc, hh = H / 2 / sc;
    x = clamp(x, hw, W - hw); y = clamp(y, hh, H - hh);
    this.cam = { x, y, s: sc };
    css(this.world, { transform: `translate(${W / 2}px, ${H / 2}px) scale(${sc.toFixed(4)}) translate(${(-x).toFixed(2)}px, ${(-y).toFixed(2)}px)` });
  }
  toScreen(p) { return { x: (p.x - this.cam.x) * this.cam.s + W / 2, y: (p.y - this.cam.y) * this.cam.s + H / 2 }; }

  // Dim + blur the desktop when a Shapr surface is open (0..1).
  dim(k, amount = 0.4, blur = 8) {
    css(this.desk, { filter: k > 0.002 && blur > 0 ? `blur(${(k * blur).toFixed(2)}px)` : "none" });
    css(this.veil, { opacity: (k * amount).toFixed(3) });
  }

  cursor(p, { visible = 1, kind = "arrow" } = {}) {
    if (!p) { css(this.cursorEl, { opacity: "0" }); return; }
    const q = this.toScreen(p);
    css(this.cursorEl, { opacity: String(visible), transform: `translate(${q.x.toFixed(1)}px, ${q.y.toFixed(1)}px)` });
    const ring = this.cursorEl.querySelector(".press");
    css(ring, { opacity: (p.press * 0.9).toFixed(3), transform: `translate(-50%,-50%) scale(${(0.6 + 0.6 * p.press).toFixed(3)})` });
    css(this.cursorEl.querySelector("svg"), { transform: `scale(${(1 - 0.08 * p.press).toFixed(3)})` });
  }

  addWindow(spec) {
    const w = new Win(spec);
    this.apps.append(w.el);
    return w;
  }
}

export class Win {
  constructor({ title, x, y, w, h: hh, dark = false, kind = "", tabs = null, body = null, z = 1 }) {
    this.x = x; this.y = y; this.w = w; this.h = hh;
    this.el = h("div", { class: `win ${kind} ${dark ? "dark" : ""}`, style: { zIndex: z } });
    this.titleEl = h("div", { class: "win-title" }, title);
    this.bar = h("div", { class: "win-bar" }, h("div", { class: "lights" }, h("i"), h("i"), h("i")), this.titleEl);
    this.body = h("div", { class: "win-body" });
    if (body) this.body.append(body);
    this.wveil = h("div", { class: "wveil" });
    this.el.append(this.bar, this.body, this.wveil);
    this.set({});
  }
  // De-emphasise the whole window (0..1) so the eye goes elsewhere.
  fade(k, max = 0.5) { css(this.wveil, { opacity: (clamp(k) * max).toFixed(3) }); this.el.classList.toggle("inactive", k > 0.5); }
  set({ x = this.x, y = this.y, w = this.w, h: hh = this.h, opacity = 1, scale = 1, z, ty = 0, filter }) {
    this.x = x; this.y = y; this.w = w; this.h = hh;
    const p = { left: px(x), top: px(y), width: px(w), height: px(hh), transform: scale !== 1 || ty ? `translateY(${ty.toFixed(1)}px) scale(${scale.toFixed(4)})` : "none" };
    if (z != null) p.zIndex = String(z);
    if (filter != null) p.filter = filter;
    css(this.el, p);
    show(this.el, opacity);
  }
}

// ---- screen-space overlays ----

// Statement: large display type that rises behind a mask, line by line. The desktop recedes behind it.
export class Statement {
  constructor(stage) {
    this.stage = stage;
    this.scrim = h("div", { class: "st-scrim" });
    this.box = h("div", { class: "statement" });
    stage.screen.append(this.scrim, this.box);
    this.current = null;
  }
  update(t, items, { dark = false } = {}) {
    const it = items.find((s) => t >= s.at - 0.05 && t < s.at + s.dur + 0.5);
    if (!it) { show(this.scrim, 0); show(this.box, 0); css(this.stage.world, { filter: "none" }); return 0; }
    if (this.current !== it) {
      this.current = it;
      this.box.innerHTML = "";
      this.lines = it.text.split("\n").map((ln) => {
        const inner = h("span", { class: "st-line-in" }, ln);
        const line = h("span", { class: "st-line" }, inner);
        this.box.append(line);
        return inner;
      });
      this.box.classList.toggle("on-dark", !!(dark || it.dark));
      this.box.classList.toggle("small", !!it.small);
      this.scrim.classList.toggle("dark", !!(dark || it.dark));
    }
    const end = it.at + it.dur;
    const bg = life(t, it.at - 0.1, end, 0.6, 0.42);
    show(this.scrim, bg);
    if (!it.noBlur) css(this.stage.world, { filter: bg > 0.01 ? `blur(${(bg * 14).toFixed(2)}px)` : "none" });
    this.lines.forEach((el, i) => {
      const t0 = it.at + 0.12 + i * 0.12;
      const a = life(t, t0, end - 0.05, D.textIn, 0.32);
      const y = (1 - ease.enter(prog(t, t0, D.textIn))) * 24 + (t > end - 0.05 ? -ease.exit(prog(t, end - 0.05, 0.32)) * 12 : 0);
      css(el, { opacity: a.toFixed(3), transform: `translateY(${y.toFixed(2)}px)` });
    });
    show(this.box, 1);
    return bg;
  }
}

// Captions: one or two lines in the bottom safe area, driven by the timeline's narration cues.
export class Captions {
  constructor(stage, { big = false } = {}) {
    this.el = h("div", { class: "caption" + (big ? " big" : "") }, h("span"));
    stage.screen.append(this.el);
    this.text = null;
  }
  update(t, cues, hidden = 0) {
    const c = cues.find((q) => t >= q.at && t < q.at + q.dur);
    if (!c) { show(this.el, 0); return; }
    if (this.text !== c.text) { this.text = c.text; this.el.firstChild.textContent = c.text; }
    const a = Math.min(clamp((t - c.at) / 0.18), clamp((c.at + c.dur - t) / 0.14)) * (1 - hidden);
    show(this.el, a);
  }
}

export class ConceptPill {
  constructor(stage) {
    this.el = h("div", { class: "concept-pill" }, h("i"), "Shapr Flow · concept");
    stage.screen.append(this.el);
  }
  update(on) { show(this.el, on ? 1 : 0); }
}

// ---- small inline icons (original drawings) ----
export function cursorSVG() {
  return s("svg", { width: 34, height: 48, viewBox: "0 0 17 24", class: "arrow" },
    s("path", { d: "M1.2 1.2v18.6l4.7-4.4 3 6.9 3.1-1.3-3-6.8h6.5Z", fill: "#111", stroke: "#fff", "stroke-width": "1.3", "stroke-linejoin": "round" }));
}
export function tickSVG(size = 18, color = "currentColor") {
  return s("svg", { width: size, height: size, viewBox: "0 0 24 24" },
    s("circle", { cx: 12, cy: 12, r: 10, fill: color }),
    s("path", { d: "M7.5 12.4l3 3 6-6.3", fill: "none", stroke: "#fff", "stroke-width": "2.2", "stroke-linecap": "round", "stroke-linejoin": "round" }));
}
function wifiSVG() {
  return s("svg", { width: 20, height: 16, viewBox: "0 0 20 16" },
    s("path", { d: "M10 14.5l2.2-2.6a3.2 3.2 0 0 0-4.4 0Z M4.9 8.6a7.4 7.4 0 0 1 10.2 0l1.6-1.9a9.9 9.9 0 0 0-13.4 0Z M1.6 4.7a12.5 12.5 0 0 1 16.8 0L20 2.8a15 15 0 0 0-20 0Z", fill: "currentColor" }));
}
function batterySVG() {
  return s("svg", { width: 30, height: 15, viewBox: "0 0 30 15" },
    s("rect", { x: 0.75, y: 0.75, width: 25, height: 13.5, rx: 4, fill: "none", stroke: "currentColor", "stroke-width": 1.2, opacity: 0.55 }),
    s("rect", { x: 3, y: 3, width: 17, height: 9, rx: 2, fill: "currentColor" }),
    s("rect", { x: 27.2, y: 5, width: 2, height: 5, rx: 1, fill: "currentColor", opacity: 0.55 }));
}
export function lockSVG(size = 18, color = "currentColor") {
  return s("svg", { width: size, height: size, viewBox: "0 0 24 24", fill: "none" },
    s("rect", { x: 5, y: 10.5, width: 14, height: 10, rx: 2.5, fill: color }),
    s("path", { d: "M8 10.5V8a4 4 0 0 1 8 0v2.5", stroke: color, "stroke-width": 2.2 }));
}
export function micSVG(size = 18, color = "currentColor") {
  return s("svg", { width: size, height: size, viewBox: "0 0 24 24", fill: "none" },
    s("rect", { x: 8.5, y: 3, width: 7, height: 12, rx: 3.5, fill: color }),
    s("path", { d: "M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3", stroke: color, "stroke-width": 1.8, "stroke-linecap": "round" }));
}
