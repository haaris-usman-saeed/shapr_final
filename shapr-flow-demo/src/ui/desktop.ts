// The simulated Mac: stage scaling, menu bar, windows, camera and cursor, plus generic app surfaces.
import { animate, set, run, ease, lerp, clamp, get } from "../engine/anim";
import { wait } from "../engine/clock";
import { FILES } from "../demo-data/aurora";

export const h = <K extends keyof HTMLElementTagNameMap>(tag: K, cls = "", html = "", kids: (Node | null)[] = []) => {
  const e = document.createElement(tag); if (cls) e.className = cls; if (html) e.innerHTML = html;
  kids.forEach((k) => k && e.append(k)); return e;
};
export const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

export const SHAPR_MARK = `<svg class="mark" viewBox="0 0 24 24"><path d="M12 3.4 20.6 7.6 12 11.8 3.4 7.6Z" fill="currentColor"/><path d="M4.9 11.1 12 14.6l7.1-3.5L20.6 12 12 16.2 3.4 12Z" fill="currentColor" opacity=".7"/><path d="M4.9 15.5 12 19l7.1-3.5 1.5.9L12 20.6 3.4 16.4Z" fill="currentColor" opacity=".45"/></svg>`;

export const D = {} as {
  stage: HTMLElement; world: HTMLElement; wall: HTMLElement; wins: HTMLElement; menubar: HTMLElement; layer: HTMLElement;
  fx: SVGSVGElement; overlay: HTMLElement; icon: HTMLElement; appName: HTMLElement; clock: HTMLElement; cursor: HTMLElement;
  dark: HTMLElement; scrim: HTMLElement; statement: HTMLElement; caption: HTMLElement; concept: HTMLElement; endcard: HTMLElement; kernel: HTMLElement;
};

export function buildStage(stage: HTMLElement) {
  D.stage = stage;
  D.world = h("div", "abs", "", []); D.world.id = "world"; D.world.style.width = "1920px"; D.world.style.height = "1080px";
  D.wall = h("div"); D.wall.id = "wall";
  D.wins = h("div"); D.wins.id = "wins";
  D.layer = h("div", "abs"); D.layer.id = "layer"; D.layer.style.inset = "0"; D.layer.style.zIndex = "30";
  D.fx = document.createElementNS("http://www.w3.org/2000/svg", "svg"); D.fx.id = "fx"; D.fx.setAttribute("viewBox", "0 0 1920 1080"); D.fx.style.zIndex = "40";
  D.menubar = h("div", "", `<div class="l"><span class="dot"></span><span class="app">Finder</span><span>File</span><span>Edit</span><span>View</span><span>Window</span><span>Help</span></div>
    <div class="r"><div id="shapr-icon" data-s="off">${SHAPR_MARK}<i class="state"></i><i class="pulse"></i><span class="task"></span></div>
    <span class="sys"><svg width="20" height="16" viewBox="0 0 20 16"><path d="M10 14.5l2.2-2.6a3.2 3.2 0 0 0-4.4 0Z M4.9 8.6a7.4 7.4 0 0 1 10.2 0l1.6-1.9a9.9 9.9 0 0 0-13.4 0Z M1.6 4.7a12.5 12.5 0 0 1 16.8 0L20 2.8a15 15 0 0 0-20 0Z" fill="currentColor"/></svg></span>
    <span class="sys"><svg width="30" height="15" viewBox="0 0 30 15"><rect x=".75" y=".75" width="25" height="13.5" rx="4" fill="none" stroke="currentColor" stroke-width="1.2" opacity=".55"/><rect x="3" y="3" width="17" height="9" rx="2" fill="currentColor"/></svg></span>
    <span class="clock" style="font-weight:500;font-variant-numeric:tabular-nums">Tue 10:41</span></div>`);
  D.menubar.id = "menubar";
  D.world.append(D.wall, D.wins, D.menubar, D.layer, D.fx);
  D.overlay = h("div"); D.overlay.id = "overlay";
  D.kernel = h("div"); D.kernel.id = "kernel";
  D.scrim = h("div"); D.scrim.id = "scrim";
  D.dark = h("div"); D.dark.id = "dark";
  D.statement = h("div"); D.statement.id = "statement";
  D.endcard = h("div", "", `<div style="color:var(--accent-2)">${SHAPR_MARK.replace('class="mark"', 'width="150" height="150"')}</div><div class="word">SHAPR<span>Flow</span></div><div class="line">Your work. Understood.</div>`); D.endcard.id = "endcard";
  D.caption = h("div", "", "<span></span>"); D.caption.id = "caption";
  D.concept = h("div", "", "Shapr Flow · concept demonstration · synthetic data"); D.concept.id = "concept";
  D.cursor = h("div", "", `<svg width="34" height="48" viewBox="0 0 17 24"><path d="M1.2 1.2v18.6l4.7-4.4 3 6.9 3.1-1.3-3-6.8h6.5Z" fill="#111" stroke="#fff" stroke-width="1.3" stroke-linejoin="round"/></svg><i class="ring"></i>`); D.cursor.id = "cursor";
  D.overlay.append(D.kernel, D.scrim, D.dark, D.statement, D.endcard, D.caption, D.concept, D.cursor);
  stage.append(D.world, D.overlay);
  D.icon = D.menubar.querySelector("#shapr-icon")!;
  D.appName = D.menubar.querySelector(".app")!;
  D.clock = D.menubar.querySelector(".clock")!;
  set(D.cursor, { o: 0 });
}

/** Fit the 1920x1080 stage into the window. */
export function fit() {
  const s = Math.min(innerWidth / 1920, innerHeight / 1080);
  D.stage.style.transform = `scale(${s})`;
}

// ---------- camera ----------
export const cam = { x: 960, y: 540, s: 1 };
function applyCam() {
  const hw = 960 / cam.s, hh = 540 / cam.s;
  const x = clamp(cam.x, hw, 1920 - hw), y = clamp(cam.y, hh, 1080 - hh);
  D.world.style.transform = `translate(960px,540px) scale(${cam.s.toFixed(4)}) translate(${(-x).toFixed(2)}px,${(-y).toFixed(2)}px)`;
  (cam as any)._x = x; (cam as any)._y = y;
  placeCursor();
}
export function camTo(to: { x: number; y: number; s: number }, dur = 1000, e = ease.move) {
  const a = { ...cam };
  if (dur <= 0) { Object.assign(cam, to); applyCam(); return wait(0); }
  return run(dur, (k) => { cam.x = lerp(a.x, to.x, k); cam.y = lerp(a.y, to.y, k); cam.s = lerp(a.s, to.s, k); applyCam(); }, { ease: e });
}
export function camReset() { Object.assign(cam, { x: 960, y: 540, s: 1 }); applyCam(); }
export const toScreen = (p: { x: number; y: number }) => ({ x: (p.x - (cam as any)._x) * cam.s + 960, y: (p.y - (cam as any)._y) * cam.s + 540 });

/** Element rect in world coordinates. */
export function rectOf(el: Element) {
  const r = el.getBoundingClientRect(), w = D.world.getBoundingClientRect(), s = w.width / 1920;
  return { x: (r.left - w.left) / s, y: (r.top - w.top) / s, w: r.width / s, h: r.height / s };
}
export const center = (el: Element) => { const r = rectOf(el); return { x: r.x + r.w / 2, y: r.y + r.h / 2 }; };

// ---------- cursor (autoplay only; in interactive mode the real pointer is used) ----------
export const cur = { x: 1500, y: 900, press: 0, visible: 0 };
export function placeCursor() {
  const p = toScreen(cur);
  D.cursor.style.transform = `translate(${p.x.toFixed(1)}px, ${p.y.toFixed(1)}px)`;
  const ring = D.cursor.querySelector(".ring") as HTMLElement;
  ring.style.opacity = String(cur.press * 0.9); ring.style.transform = `scale(${0.6 + 0.6 * cur.press})`;
}
export function cursorShow(v = 1, dur = 300) { cur.visible = v; return animate(D.cursor, { o: v }, { dur }); }
export function moveTo(x: number, y: number, dur?: number, bend = 0.12) {
  const a = { x: cur.x, y: cur.y }, dx = x - a.x, dy = y - a.y, dist = Math.hypot(dx, dy) || 1;
  const d = dur ?? clamp(380 + dist * 0.55, 420, 1100);
  const nx = -dy / dist, ny = dx / dist;
  return run(d, (k) => {
    const e = ease.inOut(k);
    const os = Math.sin(Math.PI * clamp((k - 0.72) / 0.28)) * Math.min(12, dist * 0.025);
    const arc = 4 * e * (1 - e) * bend * dist;
    cur.x = a.x + dx * e + nx * arc + (dx / dist) * os; cur.y = a.y + dy * e + ny * arc + (dy / dist) * os;
    placeCursor();
  });
}
export async function press() {
  await wait(140);
  await run(110, (k) => { cur.press = k; placeCursor(); });
  run(320, (k) => { cur.press = 1 - k; placeCursor(); });
}
/** Move to an element and click it: the element's real handler runs, exactly as for a presenter's click. */
export async function clickEl(el: HTMLElement, dx = 0, dy = 0) {
  const c = center(el);
  await moveTo(c.x + dx, c.y + dy);
  el.classList.add("hover");
  await press();
  el.classList.remove("hover");
  el.click();
}
export function setPath(path: { x: number; y: number }) { cur.x = path.x; cur.y = path.y; placeCursor(); }

// ---------- windows ----------
export interface Win { el: HTMLElement; body: HTMLElement; title: HTMLElement; veil: HTMLElement; badge: HTMLElement; lock: HTMLElement; x: number; y: number; w: number; h: number; app?: string }
let zTop = 10;
export function makeWin(title: string, x: number, y: number, w: number, hh: number, body: HTMLElement, dark = false): Win {
  const el = h("div", "win" + (dark ? " dark" : ""));
  const bar = h("div", "bar", `<div class="lights"><i></i><i></i><i></i></div><div class="title">${esc(title)}</div>`);
  const b = h("div", "body"); b.append(body);
  const veil = h("div", "veil"), badge = h("div", "badge"), lock = h("div", "lock");
  el.append(bar, b, veil, badge, lock);
  Object.assign(el.style, { left: x + "px", top: y + "px", width: w + "px", height: hh + "px" });
  D.wins.append(el);
  set(el, { o: 0 });
  return { el, body: b, title: bar.querySelector(".title")!, veil, badge, lock, x, y, w, h: hh };
}
export function front(w: Win) { w.el.style.zIndex = String(++zTop); D.wins.querySelectorAll(".win").forEach((e) => e.classList.toggle("inactive", e !== w.el)); }
export function winIn(w: Win, dur = 420) { set(w.el, { o: 0, s: 0.965, y: 14 }); front(w); return animate(w.el, { o: 1, s: 1, y: 0 }, { dur, ease: ease.enter }); }
export function winOut(w: Win, dur = 320) { return animate(w.el, { o: 0, s: 0.97, y: 10 }, { dur, ease: ease.exit }); }
export function recede(w: Win, k: number, dur = 400) { return animate(w.veil, { o: k * 0.55 }, { dur }); }

// ---------- overlays ----------
let capTimer = 0;
export async function statement(lines: string[], hold: number, opts: { light?: boolean; caps?: boolean; small?: boolean; keepDark?: boolean } = {}) {
  const st = D.statement;
  st.className = (opts.light ? "light " : "") + (opts.caps ? "caps " : "") + (opts.small ? "small" : "");
  st.innerHTML = lines.map((l) => `<div class="ln"><span>${esc(l)}</span></div>`).join("");
  const spans = [...st.querySelectorAll(".ln > span")] as HTMLElement[];
  spans.forEach((s) => set(s, { o: 0, y: 28 }));
  set(st, { o: 1 });
  const cv = cur.visible; animate(D.cursor, { o: 0 }, { dur: 200 });
  for (let i = 0; i < spans.length; i++) { animate(spans[i], { o: 1, y: 0 }, { dur: 620, ease: ease.enter }); await wait(i < spans.length - 1 ? 900 : 0); }
  await wait(620 + hold);
  await animate(st, { o: 0, y: -10 }, { dur: 380, ease: ease.exit });
  set(st, { y: 0 });
  if (cv) animate(D.cursor, { o: 1 }, { dur: 200 });
}
export function backdrop(kind: "dark" | "light" | "none", dur = 600) {
  const p = [animate(D.dark, { o: kind === "dark" ? 1 : 0 }, { dur }), animate(D.scrim, { o: kind === "light" ? 1 : 0 }, { dur })];
  D.concept.classList.toggle("dk", kind === "dark");
  return Promise.all(p);
}
export function caption(text: string | null, dur = 2600) {
  const span = D.caption.firstChild as HTMLElement;
  if (!text) { animate(D.caption, { o: 0 }, { dur: 200 }); return; }
  span.textContent = text;
  set(D.caption, { o: 0 }); animate(D.caption, { o: 1 }, { dur: 200 });
  const id = ++capTimer;
  wait(dur).then(() => { if (id === capTimer) animate(D.caption, { o: 0 }, { dur: 220 }); });
}
export function keyhint(keys: string[], label: string, x = 960, y = 880, hold = 1100) {
  const el = h("div", "keyhint", keys.map((k) => `<span class="key">${k}</span>`).join("") + `<small>${label}</small>`);
  D.overlay.append(el);
  el.style.left = "0"; el.style.top = "0";
  set(el, { x: x - 110, y, o: 0 });
  animate(el, { o: 1, y: y - 8 }, { dur: 260, ease: ease.enter });
  wait(hold).then(async () => { await animate(el, { o: 0 }, { dur: 220 }); el.remove(); });
}

// ---------- app surfaces ----------
export function hl(code: string) {
  return code.split("\n").map((ln) => {
    let s = esc(ln);
    if (/^\s*#/.test(ln) || /^\s*\/\//.test(ln)) return `<span class="cm">${s}</span>`;
    s = s.replace(/("[^"]*")/g, '<span class="st">$1</span>')
      .replace(/\b(import|from|const|new|export|async|function|await|return)\b/g, '<span class="kw">$1</span>')
      .replace(/^([A-Z_]+)=/, '<span class="k">$1</span>=')
      .replace(/^(\s*)([a-z_]+):/, '$1<span class="k">$2</span>:');
    return s;
  });
}
export function editor(file: "db" | "env" | "compose" = "db") {
  const names = { db: "db.js", env: ".env", compose: "docker-compose.yml" } as const;
  const root = h("div", "ed");
  const tree = h("div", "tree", `<div class="h">AURORA-API</div><div>▾ src</div><div data-f="db" style="padding-left:36px">db.js</div><div style="padding-left:36px">server.js</div><div data-f="env">.env</div><div data-f="compose">docker-compose.yml</div><div>package.json</div>`);
  const main = h("div", "main");
  const tabs = h("div", "tabs");
  const code = h("div", "code");
  const term = h("div", "termp", `<div class="th">TERMINAL</div>`);
  FILES.terminal.forEach(([c, t]) => term.append(h("span", "l " + c, `<span>${esc(t)}</span>`)));
  main.append(tabs, code, term);
  root.append(tree, main);
  const api = {
    root, code, term, file,
    show(f: "db" | "env" | "compose") {
      api.file = f;
      tabs.innerHTML = (["db", "env", "compose"] as const).map((x) => `<div class="tab${x === f ? " on" : ""}">${names[x]}</div>`).join("");
      tree.querySelectorAll("[data-f]").forEach((e) => e.classList.toggle("on", (e as HTMLElement).dataset.f === f));
      code.innerHTML = hl(FILES[f]).map((l, i) => `<span class="line"><span class="ln">${i + 1}</span>${l}<i class="hl"></i></span>`).join("");
    },
    line(i: number) { return code.querySelectorAll(".line")[i] as HTMLElement; },
    termLine(i: number) { return term.querySelectorAll(".l")[i] as HTMLElement; },
    termLines(n: number) { term.querySelectorAll(".l").forEach((e, i) => ((e as HTMLElement).style.visibility = i < n ? "" : "hidden")); },
  };
  api.show(file);
  return api;
}

export function browser(tabs: string[], url: string) {
  const root = h("div", "br");
  const tabsEl = h("div", "tabs"), urlEl = h("div", "url", "<div></div>"), view = h("div", "view");
  root.append(tabsEl, urlEl, view);
  const api = {
    root, view,
    tabs(list: string[], on = list.length - 1) { tabsEl.innerHTML = list.map((t, i) => `<div class="tab${i === on ? " on" : ""}">${esc(t)}</div>`).join(""); },
    url(u: string) { (urlEl.firstChild as HTMLElement).textContent = u; },
    page(html: string) { view.innerHTML = `<div class="doc">${html}</div>`; return view.firstChild as HTMLElement; },
  };
  api.tabs(tabs); api.url(url);
  return api;
}

export function chatApp(name: string) {
  const root = h("div", "chat", `<div class="thread"><div class="ai">${esc(name)} — new chat</div></div><div class="input"></div>`);
  return { root, input: root.querySelector(".input") as HTMLElement };
}

export function messagesApp() {
  return h("div", "msgs", `<div class="list">
    <div class="row on"><i class="av" style="background:#9BB39C">S</i><div><b>Sam</b>dinner later?</div></div>
    <div class="row"><i class="av">J</i><div><b>Jordan</b>demo Friday 👀</div></div>
    <div class="row"><i class="av" style="background:#C7A98A">M</i><div><b>Mom</b>call me when free</div></div></div>
    <div class="conv"><div class="b">are you still on that bug</div><div class="b">dinner later?</div><div class="b me">after this, promise</div></div>`);
}

/** Type text into an element with a human cadence. */
export function typeInto(el: HTMLElement, text: string, cps = 18, seed = 3) {
  let r = seed; const rnd = () => ((r = (r * 9301 + 49297) % 233280) / 233280);
  const times: number[] = []; let t = 0;
  for (const ch of text) { t += (1000 / cps) * (0.6 + rnd() * 0.8) + (ch === " " ? 60 : 0) + (/[.,…]/.test(ch) ? 120 : 0); times.push(t); }
  return run(t, (k) => {
    const now = k * t; let n = 0; while (n < times.length && times[n] <= now) n++;
    el.innerHTML = esc(text.slice(0, n)) + '<span class="caret"></span>';
  });
}
