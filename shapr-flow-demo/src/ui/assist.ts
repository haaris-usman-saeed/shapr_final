// Lens, Threads, Simulate and Resume. Content is computed from the shared demo state (state/kernel.ts),
// so what Shapr says changes with what the user allowed and did.
import { animate, set, run, ease } from "../engine/anim";
import { wait } from "../engine/clock";
import { D, h, esc, rectOf } from "./desktop";
import { actions, getState } from "../state/store";
import * as K from "../state/kernel";
import { sfx } from "../audio/sfx";
import { APPS } from "../demo-data/aurora";
import { toast, iconPulse } from "./shapr";

type R = { x: number; y: number; w: number; h: number };
const NS = "http://www.w3.org/2000/svg";

// ---------- Lens ----------
export function lensCard(anchor: R, hooks: { evidence?: () => void; fixes?: () => void } = {}) {
  const L = K.lens(getState());
  const el = h("div", "card glass", `<div class="t"><b>L</b>&nbsp;Lens</div><h3>${esc(L.headline)}</h3>${L.lines.map((l) => `<p>${esc(l)}</p>`).join("")}
    ${L.limited ? `<div class="lim">${esc(L.limited)}</div>` : ""}<div class="srcs">${L.sources.map((s) => `<span class="src">${esc(s)}</span>`).join("")}</div>
    <div class="acts"><button class="btn primary" data-a="ev">See evidence</button><button class="btn" data-a="fx">Explore fixes</button><button class="btn" data-a="x" style="margin-left:auto">Close</button></div><div class="more"></div>`);
  D.layer.append(el);
  let x = anchor.x + anchor.w + 34, y = anchor.y - 330;
  if (x + 560 > 1900) x = anchor.x - 560 - 34;
  y = Math.max(60, Math.min(y, 1080 - 560));
  el.style.left = x + "px"; el.style.top = y + "px"; el.style.transformOrigin = x > anchor.x ? "0 50%" : "100% 50%";
  set(el, { o: 0, sx: 0.9, x: x > anchor.x ? -16 : 16 });
  animate(el, { o: 1, sx: 1, x: 0 }, { dur: 460, ease: ease.enter });
  [...el.querySelectorAll("p, .srcs .src, .acts")].forEach((c, i) => { set(c as HTMLElement, { o: 0, y: 6 }); animate(c as HTMLElement, { o: 1, y: 0 }, { dur: 360, delay: 180 + i * 90, ease: ease.enter }); });
  sfx("lens");
  const close = async () => { await animate(el, { o: 0, sx: 0.96 }, { dur: 260, ease: ease.exit }); el.remove(); };
  el.querySelector('[data-a="ev"]')!.addEventListener("click", () => { (el.querySelector('[data-a="ev"]') as HTMLElement).classList.remove("primary"); el.querySelectorAll(".src").forEach((s, i) => run(500, (k) => ((s as HTMLElement).style.background = k < 1 ? "rgba(196,90,44,.16)" : "rgba(196,90,44,.12)"), { delay: i * 120 })); hooks.evidence?.(); sfx("tick"); });
  el.querySelector('[data-a="fx"]')!.addEventListener("click", () => {
    const more = el.querySelector(".more") as HTMLElement;
    more.innerHTML = `<p style="margin-top:12px"><b>Options to check</b> (you decide):</p><p>1 · Compare DB_HOST in .env with where Postgres actually runs.</p><p>2 · Confirm Postgres is listening on port 5432.</p>`;
    set(more, { o: 0 }); animate(more, { o: 1 }, { dur: 300 }); hooks.fixes?.();
  });
  el.querySelector('[data-a="x"]')!.addEventListener("click", close);
  return { el, btn: (a: string) => el.querySelector(`[data-a="${a}"]`) as HTMLElement, close };
}

// ---------- Threads ----------
export function threadsPin(text: string, ref: string) {
  actions.pin(text, ref);
  sfx("save"); iconPulse();
  const s = getState();
  toast("Saved to the Aurora thread", s.task.next ? `Next: ${s.task.next.text}` : "Task memory updated", "T", 2800);
}
export function taskUpdated(line: string) { iconPulse(); return toast("Task memory updated", line, "↻", 2400); }

// ---------- Simulate ----------
export async function simulateView(anchor: R) {
  const S = K.simulate(getState());
  const root = h("div", "abs"); root.style.inset = "0"; D.layer.append(root);
  const svg = document.createElementNS(NS, "svg"); svg.setAttribute("viewBox", "0 0 1920 1080"); Object.assign(svg.style, { position: "absolute", inset: "0", width: "1920px", height: "1080px" });
  root.append(svg);
  // the selected decision lifts out of the document
  const sel = h("div", "chip glass", `<span class="tag obs">Selected decision</span>${esc(S.selected)}`);
  root.append(sel); sel.style.left = "0"; sel.style.top = "0";
  const sx = 960 - 260, sy = 150;
  set(sel, { x: anchor.x, y: anchor.y, o: 0 });
  animate(sel, { o: 1 }, { dur: 200 });
  await animate(sel, { x: sx, y: sy }, { dur: 700, ease: ease.move });
  const req = h("div", "chip glass", `<span class="tag inf">New requirement</span>${esc(S.requirement)}`);
  root.append(req); req.style.left = "0"; req.style.top = "0"; set(req, { x: sx - 30, y: sy + 70, o: 0 });
  animate(req, { o: 1, y: sy + 78 }, { dur: 420, ease: ease.enter });
  await wait(700);
  sfx("branch");
  const cards = S.paths.map((p, i) => {
    const c = h("div", "sim glass", `<div class="t">Path ${p.id}</div><h3>${esc(p.title)}</h3><div class="k">Advantages</div><ul class="pro">${p.pros.map((x) => `<li>${esc(x)}</li>`).join("")}</ul>
      <div class="k">Tradeoff</div><ul class="con">${p.cons.map((x) => `<li>${esc(x)}</li>`).join("")}</ul><button class="btn${i ? "" : " primary"}" data-p="${p.id}">Explore this path</button>`);
    root.append(c); c.style.left = "0"; c.style.top = "0";
    return c;
  });
  const pos = [{ x: 960 - 680, y: 300 }, { x: 960 + 40, y: 300 }];
  const paths = pos.map(() => { const p = document.createElementNS(NS, "path"); p.setAttribute("fill", "none"); p.setAttribute("stroke", "#C45A2C"); p.setAttribute("stroke-width", "2.5"); p.setAttribute("stroke-linecap", "round"); svg.append(p); return p; });
  cards.forEach((c, i) => {
    set(c, { x: 960 - 320, y: 280, o: 0, s: 0.9 });
    animate(c, { x: pos[i].x, y: pos[i].y, o: 1, s: 1 }, { dur: 900, ease: ease.spring, delay: i * 60 });
    [...c.querySelectorAll(".k, li, .btn")].forEach((e, j) => { set(e as HTMLElement, { o: 0 }); animate(e as HTMLElement, { o: 1 }, { dur: 300, delay: 700 + j * 110 }); });
  });
  run(900, (k) => paths.forEach((p, i) => {
    const x0 = 960, y0 = sy + 124, x1 = pos[i].x + 320, y1 = pos[i].y;
    const xm = x0 + (x1 - x0) * k, ym = y0 + (y1 - y0) * k;
    p.setAttribute("d", `M${x0} ${y0} C ${x0} ${y0 + 60 * k}, ${xm} ${ym - 60 * k}, ${xm} ${ym}`);
  }), { ease: ease.move, delay: 80 });
  const foot = h("div", "simfoot glass", `<div><span class="k">Evidence</span>${S.evidence.map(esc).join(" · ")}</div><div><span class="k">Open questions</span>${S.questions.map((q) => `<span class="q">${esc(q)}</span>`).join("")}</div><div style="margin-left:auto;color:var(--ink-3);font-size:15px;align-self:center">Scenario exploration · not a prediction</div>`);
  root.append(foot); foot.style.left = "290px"; foot.style.top = "860px"; set(foot, { o: 0 }); animate(foot, { o: 1 }, { dur: 400, delay: 1500 });
  cards.forEach((c) => c.querySelector("button")!.addEventListener("click", () => {
    const id = (c.querySelector("button") as HTMLElement).dataset.p as "A" | "B";
    actions.choose(id); sfx("save");
    cards.forEach((o) => { o.classList.toggle("chosen", o === c); animate(o, { o: o === c ? 1 : 0.55, s: o === c ? 1.02 : 0.98 }, { dur: 400 }); });
    (c.querySelector("button") as HTMLElement).textContent = "Exploring this path";
  }));
  return { root, cards, btn: (i: number) => cards[i].querySelector("button") as HTMLElement, close: async () => { await animate(root, { o: 0 }, { dur: 380, ease: ease.exit }); root.remove(); } };
}

// ---------- Resume ----------
export function resumeCard(onContinue: () => void) {
  const R = K.resumeCard(getState());
  const el = h("div", "pop glass resume", `<h2>${esc(R.title)}</h2><div class="q">${esc(R.question)}</div>${R.lines.map((l) => `<div class="ln">${esc(l)}</div>`).join("")}
    <div style="font-size:14.5px;color:var(--ink-3);margin-top:10px">Continues with yesterday's app choices: ${R.apps.map((a) => APPS[a].name).join(" · ") || "none"}</div>
    <button class="btn primary" data-a="go">Continue where I left off</button>`);
  D.layer.append(el);
  const r = rectOf(D.icon);
  el.style.left = Math.min(r.x - 300, 1920 - 640) + "px"; el.style.top = "48px";
  set(el, { o: 0, s: 0.96, y: -8 }); animate(el, { o: 1, s: 1, y: 0 }, { dur: 460, ease: ease.enter });
  [...el.querySelectorAll(".ln")].forEach((l, i) => { set(l as HTMLElement, { o: 0, y: 8 }); animate(l as HTMLElement, { o: 1, y: 0 }, { dur: 380, delay: 220 + i * 140, ease: ease.enter }); });
  sfx("open");
  el.querySelector('[data-a="go"]')!.addEventListener("click", async () => {
    actions.resume(); sfx("resume");
    await animate(el, { o: 0, s: 0.97 }, { dur: 280, ease: ease.exit }); el.remove();
    onContinue();
  });
  return { el, btn: el.querySelector('[data-a="go"]') as HTMLElement };
}

export function restoreList(x: number, y: number, items: string[]) {
  const el = h("div", "restore glass", `<div style="font-size:13px;font-weight:750;letter-spacing:.08em;text-transform:uppercase;color:var(--ink-3);margin-bottom:4px">Restored from yesterday's checkpoint</div>${items.map((t) => `<div class="r"><i>✓</i>${esc(t)}</div>`).join("")}
    <div style="display:flex;gap:8px;margin-top:10px"><button class="btn" data-a="ai">Share context with coding assistant</button></div>`);
  D.layer.append(el); el.style.left = x + "px"; el.style.top = y + "px";
  set(el, { o: 0, y: 8 }); animate(el, { o: 1, y: 0 }, { dur: 420, ease: ease.enter });
  [...el.querySelectorAll(".r")].forEach((r, i) => { set(r as HTMLElement, { o: 0, x: -8 }); animate(r as HTMLElement, { o: 1, x: 0 }, { dur: 320, delay: 200 + i * 160, ease: ease.enter }); });
  const ai = el.querySelector('[data-a="ai"]') as HTMLElement;
  ai.addEventListener("click", () => { ai.textContent = "Context ready · review before sending"; ai.classList.add("primary"); sfx("tick"); });
  return { el, ai, close: async () => { await animate(el, { o: 0 }, { dur: 260 }); el.remove(); } };
}
