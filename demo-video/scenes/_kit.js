// Helpers shared by scenes: standard windows, the capture flight, key hints, card motion.
import { h, css, px, show, packOrb, keycap, Win } from "../src/stage.js";
import { ease, prog, life, lerp, clamp, arc, spring, D } from "../src/motion.js";
import { codeEditor, terminal, browser, docsPage } from "../src/apps.js";
import { flyChip } from "../src/ui.js";

// Position an absolutely placed element in world coordinates with optional scale/opacity.
export function place(el, x, y, { scale = 1, opacity = 1, origin = null, rot = 0 } = {}) {
  const p = { left: px(x), top: px(y), transform: scale !== 1 || rot ? `scale(${scale.toFixed(4)}) rotate(${rot.toFixed(2)}deg)` : "none" };
  if (origin) p.transformOrigin = origin;
  css(el, p);
  show(el, opacity);
}

// A surface entering (scale from 0.96, rise 10px) and exiting 30% faster.
export function surface(el, t, t0, t1, x, y, { din = D.panel, rise = 10, from = 0.96 } = {}) {
  const a = life(t, t0, t1, din, din * 0.7);
  const k = ease.enter(prog(t, t0, din));
  const sc = lerp(from, 1, k);
  const ty = (1 - k) * rise;
  css(el, { left: px(x), top: px(y + ty), transform: `scale(${sc.toFixed(4)})` });
  show(el, a);
  return a;
}

// Window entrance: scale 0.965 → 1, rise 14px, opacity, 360 ms.
export function winIn(win, t, t0, extra = {}) {
  const k = ease.enter(prog(t, t0, 0.36));
  win.set({ opacity: t < t0 ? 0 : k, scale: lerp(0.965, 1, k), ty: (1 - k) * 14, ...extra });
}

// The editor + terminal pair used by several scenes.
export function devWindows(stage, files, { editor = { x: 150, y: 100, w: 1060, h: 560 }, term = { x: 840, y: 520, w: 960, h: 420 } } = {}) {
  const ed = codeEditor({ files });
  const edw = stage.addWindow({ title: "db.js — aurora-api — Code", ...editor, h: editor.h, kind: "code", body: ed.el, z: 2 });
  const tm = terminal({ log: files.terminal });
  const tmw = stage.addWindow({ title: "Terminal — aurora-api", ...term, h: term.h, dark: true, kind: "term", body: tm.el, z: 3 });
  return { ed, edw, tm, tmw };
}

// Rect of a child element in world coordinates (layout must be final; no transforms on ancestors).
export function rectOf(el, stage) {
  const r = el.getBoundingClientRect();
  const w = stage.world.getBoundingClientRect();
  const s = w.width / 1920;
  return { x: (r.left - w.left) / s, y: (r.top - w.top) / s, w: r.width / s, h: r.height / s };
}

// The recurring "saved" gesture: a chip lifts (shadow grows), arcs to the menu-bar icon while shrinking.
export function makeFlight(stage, pack, title, thumb = null) {
  const c = flyChip({ pack, title, thumb });
  stage.shapr.append(c.el);
  return {
    el: c.el,
    update(t, t0, from, dur = D.flight, to = stage.menubar.center()) {
      if (t < t0 || t > t0 + dur + 0.05) { show(c.el, 0); return false; }
      const k = clamp((t - t0) / dur);
      const lift = ease.enter(prog(t, t0, 0.18));
      const travel = ease.move(prog(t, t0 + 0.12, dur - 0.12));
      const p = arc(travel, from, to, 0.22);
      const sc = lerp(1, 0.28, ease.inOut(travel)) * (1 + 0.06 * lift * (1 - travel));
      const w = c.el.offsetWidth, hh = c.el.offsetHeight;
      css(c.el, { transform: `translate(${(p.x - w / 2).toFixed(1)}px, ${(p.y - hh / 2 - 8 * lift * (1 - travel)).toFixed(1)}px) scale(${sc.toFixed(4)})`,
        boxShadow: `0 ${(2 + 14 * lift * (1 - travel)).toFixed(1)}px ${(6 + 30 * lift * (1 - travel)).toFixed(1)}px rgba(31,30,28,${(0.18 + 0.12 * lift * (1 - travel)).toFixed(3)})` });
      show(c.el, Math.min(lift * 1.4, 1 - prog(t, t0 + dur - 0.1, 0.12)));
      return k >= 1;
    },
  };
}

// A dark pill that shows which keys were pressed (so the viewer learns the real shortcut).
export function keyHint(stage, keys, label = "") {
  const el = h("div", { class: "keyhint" }, ...keys.map((k) => h("span", { class: "kh-key" }, k)), label ? h("span", { class: "kh-label" }, label) : null);
  stage.screen.append(el);
  return {
    el,
    update(t, t0, t1, x, y) {
      const a = life(t, t0, t1, 0.22, 0.2);
      const presses = keys.map((_, i) => { const d = t - (t0 + i * 0.16); return d > 0 && d < 0.14 ? 1 : 0; });
      el.querySelectorAll(".kh-key").forEach((k, i) => css(k, { transform: presses[i] ? "translateY(2px)" : "none", background: presses[i] ? "#3A3835" : "#2A2826" }));
      y = Math.min(y, 790); // always clear of the caption zone
      css(el, { left: px(x), top: px(y), transform: `translate(-50%, 0) translateY(${((1 - ease.enter(prog(t, t0, 0.3))) * 8).toFixed(1)}px)` });
      show(el, a);
    },
  };
}

// Text selection highlight in the pack colour (CaptureFeedback.highlight: 16% fill, 85% border).
export function selectionBox(stage, color = "#B5562D") {
  const el = h("div", { class: "selbox" });
  el.style.background = color + "29"; el.style.borderColor = color + "D9";
  stage.shapr.append(el);
  return {
    el,
    update(rect, a, sweep = 1) {
      css(el, { left: px(rect.x - 5), top: px(rect.y - 4), width: px((rect.w + 10) * sweep), height: px(rect.h + 8) });
      show(el, a);
    },
  };
}

export { packOrb, keycap };
