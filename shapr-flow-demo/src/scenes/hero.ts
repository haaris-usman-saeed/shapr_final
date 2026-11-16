// The autoplay programs. Every scene drives the same UI and the same demo state a presenter uses:
// the cursor "clicks" real elements, whose handlers call store actions.
import { animate, set, run, ease } from "../engine/anim";
import { wait } from "../engine/clock";
import { D, h, esc, rectOf, center, camTo, cam, cur, cursorShow, moveTo, press, clickEl, setPath, winIn, winOut, front, recede, statement, backdrop, keyhint, typeInto, type Win } from "../ui/desktop";
import { W, page, hideAll } from "../ui/world";
import { openPop, closePop, popButton, askPermission, observeFrom, flow, toast, iconPulse, openMemSheet, closeMemSheet, sheetEl } from "../ui/shapr";
import { drawCircle, ltsMenu } from "../ui/circle";
import { lensCard, threadsPin, simulateView, resumeCard, restoreList } from "../ui/assist";
import { kernelView } from "../ui/kernelview";
import { actions, getState } from "../state/store";
import { PROMPT_TEXT, type AppId } from "../demo-data/aurora";
import { sfx } from "../audio/sfx";
import { say } from "../audio/narration";
import PROG from "./programs.json";
const DUR = { ...PROG.hero, ...PROG.trailer } as Record<string, number>;

export interface Scene { id: string; title: string; dur: number; run: () => Promise<void> }

const NS = "http://www.w3.org/2000/svg";
const errEl = () => W.ed.termLine(3).firstElementChild as HTMLElement;
const muted = (k: number, dur = 600) => animate(D.wins, { sat: 1 - 0.75 * k, bright: 1 - 0.08 * k }, { dur });

/** Focus an app; if the session is on and Shapr hasn't asked yet, it asks (same as a presenter's click). */
export async function focusApp(w: Win, pick?: "once" | "session" | "always" | "deny") {
  front(w); D.appName.textContent = w.title.textContent!.split(" — ").pop()!.replace("Safari", "Safari");
  const s = getState();
  if (s.session === "active" && w.app && !s.permissions[w.app as AppId]) {
    const p = askPermission(w.app as AppId);
    if (pick) { await wait(900); await clickEl(p.opt(pick)); }
    return p.done;
  }
}

function boundary(on: Win[], off: Win[]) {
  const svg = document.createElementNS(NS, "svg"); svg.setAttribute("viewBox", "0 0 1920 1080");
  Object.assign(svg.style, { position: "absolute", inset: "0", width: "1920px", height: "1080px", pointerEvents: "none" });
  D.layer.prepend(svg);
  const ic = center(D.icon);
  const lines = on.map((w) => {
    const c = { x: w.x + w.w / 2, y: w.y + 60 };
    const p = document.createElementNS(NS, "path");
    p.setAttribute("d", `M${c.x} ${c.y} C ${c.x} ${c.y - 180}, ${ic.x} ${ic.y + 200}, ${ic.x} ${ic.y + 14}`);
    p.setAttribute("fill", "none"); p.setAttribute("stroke", "rgba(196,90,44,.55)"); p.setAttribute("stroke-width", "2"); p.setAttribute("stroke-dasharray", "4 7");
    svg.append(p); return p;
  });
  const dots = lines.map(() => { const c = document.createElementNS(NS, "circle"); c.setAttribute("r", "6"); c.setAttribute("fill", "#E08A5E"); c.style.filter = "drop-shadow(0 0 6px rgba(224,138,94,.9))"; svg.append(c); return c; });
  set(svg as any, { o: 0 }); animate(svg as any, { o: 1 }, { dur: 600 });
  const pulses = run(3600, (k) => lines.forEach((p, i) => { const L = p.getTotalLength(); const q = ((k * 2.4 + i * 0.37) % 1); const pt = p.getPointAtLength(q * L); dots[i].setAttribute("cx", String(pt.x)); dots[i].setAttribute("cy", String(pt.y)); dots[i].setAttribute("opacity", String(Math.sin(Math.PI * q))); }));
  on.forEach((w) => { w.badge.className = "badge on"; w.badge.innerHTML = "● Observed this session"; animate(w.badge, { o: 1 }, { dur: 400 }); });
  off.forEach((w) => { w.lock.innerHTML = `<svg width="40" height="40" viewBox="0 0 24 24"><rect x="5" y="10.5" width="14" height="10" rx="2.5" fill="currentColor"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5" stroke="currentColor" stroke-width="2.2" fill="none"/></svg>Not observed by Shapr<small>Nothing from Messages enters its memory</small>`; animate(w.lock, { o: 1 }, { dur: 500 }); });
  return { done: pulses, remove: async () => { await animate(svg as any, { o: 0 }, { dur: 400 }); svg.remove(); } };
}

function label(x: number, y: number, kind: string, text: string, cls = "obs") {
  const el = h("div", "label glass", `<span class="k"><span class="tag ${cls}" style="font-size:11px;padding:2px 7px;margin-right:6px">${kind}</span></span>${text}`);
  D.layer.append(el); el.style.left = "0"; el.style.top = "0"; set(el, { x, y: y + 10, o: 0 });
  animate(el, { y, o: 1 }, { dur: 460, ease: ease.enter });
  return el;
}

// =============== HERO ===============
const s1: Scene = { id: "forget", title: "The computer that forgets", dur: DUR["forget"], run: async () => {
  set(D.dark, { o: 1 });
  await wait(500); say("n01", undefined, false);
  await statement(["Your computer sees everything you do."], 900);
  say("n02", undefined, false);
  await statement(["But does it understand any of it?"], 700);
  backdrop("none", 1000);
  W.ed.show("db"); W.ed.termLines(3); winIn(W.vs); D.appName.textContent = "VS Code";
  await wait(900); W.ed.termLines(5); sfx("tick");
  await wait(700);
  W.br.tabs(["postgres connection refused"]); page("search", "google.com/search?q=postgres+connection+refused"); winIn(W.sf); D.appName.textContent = "Safari";
  await wait(800); page("pgdocs", "postgresql.org/docs/16/client-connection.html", ["Search", "PostgreSQL docs"]);
  await wait(700); front(W.vs); D.appName.textContent = "VS Code";
  await wait(500); winIn(W.gpt); D.appName.textContent = "ChatGPT";
  camTo({ x: 640, y: 640, s: 1.35 }, 900);
  await typeInto(W.gptIn, PROMPT_TEXT, 30, 4);
  winIn(W.cl); D.appName.textContent = "Claude";
  camTo({ x: 1390, y: 560, s: 1.35 }, 700);
  await typeInto(W.clIn, PROMPT_TEXT, 44, 9);
  await wait(400);
  muted(1, 700); camTo({ x: 960, y: 540, s: 1.04 }, 900);
  say("n03", undefined, false);
  backdrop("light", 600);
  await statement(["What if you never had to explain", "your work again?"], 1100, { light: true, small: true });
} };

const s2: Scene = { id: "on", title: "Turn Shapr on", dur: DUR["on"], run: async () => {
  backdrop("none", 600); muted(0, 600);
  winOut(W.gpt); winOut(W.cl); recede(W.sf, 0.6); camTo({ x: 960, y: 540, s: 1 }, 800);
  await wait(700);
  set(D.icon, { o: 0, s: 0.6 }); await animate(D.icon, { o: 1, s: 1 }, { dur: 600, ease: ease.spring }); sfx("start");
  setPath({ x: 1100, y: 700 }); cursorShow(1);
  await clickEl(D.icon);
  camTo({ x: 1560, y: 230, s: 1.75 }, 900);
  await wait(900); say("n04");
  await wait(900);
  await clickEl(popButton("start"));
  await wait(2200);
  await clickEl(D.icon);
} };

const s3: Scene = { id: "permission", title: "Your permission", dur: DUR["permission"], run: async () => {
  recede(W.sf, 0); camTo({ x: 960, y: 540, s: 1 }, 700);
  await moveTo(500, 500);
  await press();
  const p1 = focusApp(W.vs);
  camTo({ x: 1400, y: 300, s: 1.55 }, 800);
  await wait(1200); await clickEl(document.querySelector('.perm [data-s="session"]') as HTMLElement); await p1;
  await moveTo(1500, 600, 700); await press();
  const p2 = focusApp(W.sf);
  await wait(900); await clickEl(document.querySelector('.perm [data-s="session"]') as HTMLElement); await p2;
  winIn(W.ms); sfx("tick");
  await wait(500); await moveTo(1550, 820, 700); await press();
  const p3 = focusApp(W.ms);
  await wait(900); await clickEl(document.querySelector('.perm [data-s="deny"]') as HTMLElement); await p3;
  camTo({ x: 960, y: 540, s: 1 }, 1000); cursorShow(0);
  const b = boundary([W.vs, W.sf], [W.ms]);
  await wait(3200);
  backdrop("light", 500);
  await statement(["Your computer.", "Your permission."], 900, { light: true });
  await statement(["Local-first by design."], 500, { light: true, small: true });
  backdrop("none", 500); b.remove();
} };

const s4: Scene = { id: "understand", title: "Shapr starts understanding", dur: DUR["understand"], run: async () => {
  [W.vs, W.sf].forEach((w) => animate(w.badge, { o: 0 }, { dur: 300 }));
  say("n05");
  front(W.vs); D.appName.textContent = "VS Code"; W.ed.show("db");
  observeFrom("openVscode", W.vs.title);
  await wait(900); W.ed.show("env"); observeFrom("viewConfig", W.ed.code);
  await wait(1100); front(W.sf); D.appName.textContent = "Safari"; page("search", "google.com/search?q=postgres+connection+refused", ["Search"]);
  observeFrom("searchDocs", W.br.view);
  await wait(1000); page("pgdocs", "postgresql.org/docs/16/client-connection.html", ["Search", "PostgreSQL docs"]); observeFrom("readDocs", W.br.view);
  await wait(1000); actions.observe("message"); // blocked: nothing flows, nothing is stored
  run(600, (k) => (W.ms.el.style.transform = `translateX(${Math.sin(k * Math.PI * 6) * 3 * (1 - k)}px)`));
  await wait(900); front(W.vs); D.appName.textContent = "VS Code"; W.ed.show("db");
  run(500, (k) => (errEl().style.textShadow = `0 0 ${12 * Math.sin(Math.PI * k)}px rgba(240,128,111,.8)`));
  observeFrom("error1", errEl());
  await wait(1300);
  // reveal: what Shapr connected, and how
  [W.vs, W.sf, W.ms].forEach((w) => recede(w, 0.75));
  const L = [
    label(170, 160, "Observed", "<b>VS Code</b> · db.js and .env in aurora-api"),
    label(1080, 210, "Observed", "<b>Safari</b> · PostgreSQL connection docs"),
    label(250, 690, "Observed", "<b>Terminal</b> · ECONNREFUSED 127.0.0.1:5432"),
  ];
  await wait(1700);
  const obj = h("div", "taskobj glass", `<div class="t">Aurora</div><div class="h">Database troubleshooting</div>
    <div class="label" style="position:static;padding:0;font-size:17px;line-height:1.7"><div>Active project · <b>Aurora</b></div><div>Relevant apps · <b>VS Code · Safari</b></div><div>Recent issue · <b>Connection refused</b></div></div>
    <div style="margin:14px 0 12px;display:flex;align-items:center;gap:10px;font-size:19px;font-weight:650">Likely task: Fix database connection <span class="tag inf" data-tag>Inferred</span></div>
    <div class="acts"><button class="btn primary" data-c>Confirm</button><button class="btn">Edit</button></div>`);
  D.layer.append(obj); obj.style.left = "700px"; obj.style.top = "340px";
  set(obj, { o: 0, s: 0.85 });
  L.forEach((l, i) => animate(l, { x: 760 + i * 10, y: 380 + i * 30, o: 0, s: 0.8 }, { dur: 800, delay: i * 90, ease: ease.move }));
  await wait(500); animate(obj, { o: 1, s: 1 }, { dur: 700, ease: ease.spring }); sfx("merge");
  camTo({ x: 960, y: 540, s: 1.3 }, 900);
  await wait(1500);
  const c = obj.querySelector("[data-c]") as HTMLElement;
  c.addEventListener("click", () => { actions.confirmTask(); sfx("grant"); const t = obj.querySelector("[data-tag]")!; t.className = "tag conf"; t.textContent = "Confirmed"; });
  cursorShow(1); await clickEl(c);
  await wait(1200);
  backdrop("light", 500);
  await statement(["Shapr doesn't just collect what you see.", "It connects what you're doing."], 1000, { light: true, small: true });
  backdrop("none", 400);
  L.forEach((l) => l.remove());
  camTo({ x: 960, y: 540, s: 1 }, 800);
  const ic = center(D.icon);
  await animate(obj, { x: ic.x - 960, y: ic.y - 380, s: 0.1, o: 0 }, { dur: 800, ease: ease.move });
  obj.remove(); iconPulse(); sfx("tick");
  [W.vs, W.sf, W.ms].forEach((w) => recede(w, 0));
} };

const s5: Scene = { id: "memory", title: "The Memory Kernel", dur: DUR["memory"], run: async () => {
  cursorShow(0);
  // more work happens: attempts, the same error again, the docs again
  front(W.vs); W.ed.show("env"); observeFrom("creds", W.ed.code);
  await wait(600); observeFrom("restart", W.ed.term);
  await wait(600); observeFrom("error2", errEl());
  await wait(600); front(W.sf); observeFrom("readDocs2", W.br.view);
  await wait(900);
  say("n06", undefined, false);
  const kv = await kernelView();
  await wait(600);
  set(D.dark, { o: 0 });
  const closing = kv.close(true);
  await wait(900); iconPulse();
  await backdrop("dark", 500);
  await closing;
  await statement(["Not everything you did.", "Everything you need to continue."], 1500, { caps: true, small: true });
  await backdrop("none", 700);
} };

let circle: Awaited<ReturnType<typeof drawCircle>> | null = null;
let menu: ReturnType<typeof ltsMenu> | null = null;
let picked: Promise<"L" | "T" | "S"> | null = null;
async function circleAndMenu(target: HTMLElement, opts: { dur?: number } = {}) {
  const c = await drawCircle(target, opts);
  circle = c;
  await wait(250);
  picked = new Promise((r) => { menu = ltsMenu(c.rect, (m) => r(m)); });
  return c;
}

const s6: Scene = { id: "circle", title: "Circle anything", dur: DUR["circle"], run: async () => {
  front(W.vs); W.ed.show("db"); D.appName.textContent = "VS Code";
  const r = rectOf(errEl());
  camTo({ x: r.x + r.w / 2 + 120, y: r.y, s: 1.85 }, 1000);
  setPath({ x: r.x - 60, y: r.y - 120 }); cursorShow(1);
  await moveTo(r.x - 30, r.y - 34, 800);
  keyhint(["⌘", "⌘"], "circle", 860, 880);
  say("n07");
  await wait(500);
  await circleAndMenu(errEl());
  await wait(1700);
  backdrop("light", 400);
  await statement(["Make it useful."], 600, { light: true, small: true });
  backdrop("none", 400);
} };

const s7: Scene = { id: "lens", title: "Lens", dur: DUR["lens"], run: async () => {
  await clickEl(menu!.opt("L"));
  await picked;
  const card = lensCard(circle!.rect, {
    evidence: () => {
      W.ed.show("env");
      const ln = W.ed.line(1).querySelector(".hl") as HTMLElement; animate(ln, { o: 1 }, { dur: 400 });
      run(900, (k) => (errEl().style.textShadow = `0 0 ${10 * Math.sin(Math.PI * k)}px rgba(240,128,111,.9)`));
    },
  });
  camTo({ x: 920, y: 600, s: 1.3 }, 900);
  await wait(800); say("n08");
  await wait(2600);
  await clickEl(card.btn("ev"));
  await wait(3200);
  await clickEl(card.btn("x"));
  circle!.clear(); circle = null;
  W.ed.show("db");
  camTo({ x: 960, y: 540, s: 1 }, 800);
  backdrop("light", 400);
  await statement(["Don't ask from scratch.", "Ask from where you are."], 900, { light: true, small: true });
  backdrop("none", 400);
} };

const s8: Scene = { id: "threads", title: "Threads", dur: DUR["threads"], run: async () => {
  front(W.sf); D.appName.textContent = "Safari";
  page("docker", "docs.docker.com/compose/networking", ["PostgreSQL docs", "Docker · Networking"]);
  observeFrom("dockerNote", W.br.view);
  const t = W.br.view.querySelector('[data-sel="docker"]') as HTMLElement;
  const r = rectOf(t);
  camTo({ x: r.x + r.w / 2, y: r.y + 60, s: 1.45 }, 900);
  await moveTo(r.x - 20, r.y - 30, 700);
  await circleAndMenu(t, { dur: 700 });
  await wait(600);
  await clickEl(menu!.opt("T"));
  await picked;
  threadsPin(t.textContent || "", "Docker docs · Networking");
  circle!.clear(); circle = null;
  say("n09");
  await wait(2600);
  camTo({ x: 1500, y: 260, s: 1.6 }, 900);
  await clickEl(D.icon);
  await wait(900);
  await clickEl(popButton("end"));
  await wait(2200);
  camTo({ x: 960, y: 540, s: 1 }, 800);
  backdrop("light", 400);
  await statement(["Your work keeps moving.", "Its context stays connected."], 700, { light: true, small: true });
} };

const s9: Scene = { id: "resume", title: "Resume", dur: DUR["resume"], run: async () => {
  cursorShow(0);
  backdrop("dark", 1200); say("n10", undefined, false);
  await statement(["You stopped working."], 900);
  hideAll(); D.wall.className = "morning"; D.clock.textContent = "Wed 9:04"; D.appName.textContent = "Finder";
  [W.vs, W.sf, W.ms].forEach((w) => { recede(w, 0); w.badge.style.opacity = "0"; w.lock.style.opacity = "0"; });
  W.gptIn.textContent = ""; W.clIn.textContent = "";
  await statement(["Your progress didn't disappear."], 900);
  await backdrop("none", 1600);
  setPath({ x: 1100, y: 640 }); cursorShow(1);
  camTo({ x: 1500, y: 300, s: 1.5 }, 900);
  await moveTo(center(D.icon).x, center(D.icon).y);
  await press();
  let go!: () => void; const restored = new Promise<void>((r) => (go = r));
  const rc = resumeCard(go);
  await wait(3400);
  await clickEl(rc.btn);
  await restored;
  camTo({ x: 960, y: 540, s: 1 }, 1000);
  // the work comes back: files and pages Shapr has references to (not unsaved editor state)
  W.ed.show("env"); (W.ed.line(1).querySelector(".hl") as HTMLElement).style.opacity = "1";
  page("docker", "docs.docker.com/compose/networking", ["PostgreSQL docs", "Docker · Networking"]);
  const back = [W.vs, W.sf];
  back.forEach((w, i) => { set(w.el, { o: 0, x: i ? 220 : -220, y: 40, s: 0.92 }); front(w); animate(w.el, { o: 1, x: 0, y: 0, s: 1 }, { dur: 700, delay: i * 140, ease: ease.move }); });
  await wait(900);
  const rl = restoreList(1240, 560, [".env · docker-compose.yml in VS Code", "PostgreSQL docs · Docker networking", "Your saved finding: localhost inside a container", "Task memory: goal, attempts, next step"]);
  await wait(1800);
  await clickEl(rl.ai);
  await wait(1400);
  backdrop("light", 400);
  await statement(["Pick up exactly", "where you left off."], 700, { light: true });
  backdrop("none", 400); rl.close();
} };

const s10: Scene = { id: "simulate", title: "Simulate", dur: DUR["simulate"], run: async () => {
  front(W.sf); D.appName.textContent = "Safari";
  page("spec", "docs.aurora-team.example/spec", ["Docker · Networking", "Aurora spec"]);
  observeFrom("spec", W.br.view);
  await wait(500); observeFrom("archNote", W.br.view);
  const t = W.br.view.querySelector('[data-sel="arch"]') as HTMLElement;
  const r = rectOf(t);
  camTo({ x: r.x + r.w / 2, y: r.y, s: 1.4 }, 900);
  await moveTo(r.x - 20, r.y - 30, 700);
  await circleAndMenu(t, { dur: 750 });
  await wait(500);
  await clickEl(menu!.opt("S"));
  await picked;
  circle!.clear(); circle = null;
  recede(W.sf, 1.6); recede(W.vs, 1.6);
  camTo({ x: 960, y: 540, s: 1 }, 900);
  const sv = await simulateView(r);
  say("n11");
  await wait(3800);
  await clickEl(sv.btn(0));
  await wait(1800);
  backdrop("light", 400);
  await statement(["Don't just ask what to do.", "Explore what could happen."], 800, { light: true, small: true });
  backdrop("none", 400);
  await sv.close();
  recede(W.sf, 0); recede(W.vs, 0);
} };

const s11: Scene = { id: "control", title: "You stay in control", dur: DUR["control"], run: async () => {
  camTo({ x: 1500, y: 300, s: 1.55 }, 800);
  await clickEl(D.icon);
  await wait(700);
  await clickEl(popButton("pause"));
  await wait(1300);
  say("n12");
  await clickEl(popButton("mem"));
  await wait(2000);
  await clickEl(sheetEl.querySelector("[data-del]") as HTMLElement);
  await wait(1800);
  await clickEl(sheetEl.querySelector("[data-x]") as HTMLElement);
  camTo({ x: 960, y: 540, s: 1 }, 700);
  backdrop("light", 400);
  await statement(["Your work belongs to you.", "So does your context."], 700, { light: true, small: true });
  backdrop("none", 400);
} };

const s12: Scene = { id: "future", title: "Finally connected", dur: DUR["future"], run: async () => {
  cursorShow(0);
  if (getState().session === "paused") actions.pause();
  // the work moves across apps; one task holds it together
  const seq: Win[] = [W.vs, W.sf, W.gpt, W.vs];
  for (const w of seq) { if (w === W.gpt) winIn(w); else front(w); await wait(650); }
  const svg = document.createElementNS(NS, "svg"); svg.setAttribute("viewBox", "0 0 1920 1080"); Object.assign(svg.style, { position: "absolute", inset: "0", width: "1920px", height: "1080px" });
  D.layer.append(svg);
  const nodes = [["Active work", 560, 520], ["Context", 1380, 380], ["Working memory", 1520, 120], ["Assistance", 640, 760]] as const;
  const ic = center(D.icon);
  const paths = nodes.map(([, x, y]) => { const p = document.createElementNS(NS, "path"); p.setAttribute("d", `M${x} ${y} Q ${(x + ic.x) / 2} ${Math.min(y, ic.y) - 80}, ${ic.x} ${ic.y + 16}`); p.setAttribute("fill", "none"); p.setAttribute("stroke", "rgba(196,90,44,.6)"); p.setAttribute("stroke-width", "2"); svg.append(p); return p; });
  const labs = nodes.map(([n, x, y]) => label(x - 70, y - 22, "", `<b>${n}</b>`, ""));
  paths.forEach((p) => { const L = p.getTotalLength(); p.style.strokeDasharray = `${L}`; p.style.strokeDashoffset = `${L}`; });
  await run(1200, (k) => paths.forEach((p) => (p.style.strokeDashoffset = String(p.getTotalLength() * (1 - k)))), { ease: ease.move });
  iconPulse(); sfx("merge");
  await wait(1600);
  animate(svg as any, { o: 0 }, { dur: 700 }); labs.forEach((l) => animate(l, { o: 0 }, { dur: 500 }));
  winOut(W.gpt); winOut(W.ms);
  await wait(900);
  svg.remove(); labs.forEach((l) => l.remove());
  await backdrop("dark", 1000);
  say("n13", undefined, false);
  await statement(["Your computer."], 300, { caps: true });
  await statement(["Your context."], 300, { caps: true });
  await statement(["Finally connected."], 500, { caps: true });
  sfx("logo");
  set(D.endcard, { o: 0, s: 0.97 }); animate(D.endcard, { o: 1, s: 1 }, { dur: 1200, ease: ease.enter });
  const parts = [...D.endcard.children] as HTMLElement[];
  parts.forEach((p, i) => { set(p, { o: 0, y: 16 }); animate(p, { o: 1, y: 0 }, { dur: 800, delay: 200 + i * 450, ease: ease.enter }); });
  run(6000, (k) => (D.endcard.style.transform = `scale(${1 + 0.02 * k})`), { delay: 1200 });
  await wait(5200);
} };

export const HERO: Scene[] = [s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12];

// =============== 60-SECOND TRAILER (recomposed, not cut down) ===============
const t1: Scene = { id: "t-forget", title: "Fragmented work", dur: DUR["t-forget"], run: async () => {
  W.ed.show("db"); W.ed.termLines(5); winIn(W.vs); D.appName.textContent = "VS Code";
  await wait(500); page("pgdocs", "postgresql.org/docs/16/client-connection.html", ["PostgreSQL docs"]); winIn(W.sf);
  await wait(500); winIn(W.gpt); camTo({ x: 640, y: 640, s: 1.3 }, 700);
  await typeInto(W.gptIn, PROMPT_TEXT, 46, 4);
  winIn(W.cl); camTo({ x: 1390, y: 560, s: 1.3 }, 600);
  await typeInto(W.clIn, PROMPT_TEXT, 60, 9);
  muted(1, 500); camTo({ x: 960, y: 540, s: 1 }, 600); backdrop("light", 400);
  say("n03", undefined, false);
  await statement(["What if you never had to explain", "your work again?"], 500, { light: true, small: true });
} };
const t2: Scene = { id: "t-permission", title: "Your permission", dur: DUR["t-permission"], run: async () => {
  backdrop("none", 400); muted(0, 400); winOut(W.gpt); winOut(W.cl);
  set(D.icon, { o: 0 }); animate(D.icon, { o: 1 }, { dur: 400 }); sfx("start");
  setPath({ x: 1200, y: 600 }); cursorShow(1);
  camTo({ x: 1500, y: 300, s: 1.6 }, 700);
  await clickEl(D.icon); await wait(500); await clickEl(popButton("start")); await wait(700); await clickEl(D.icon);
  const a = focusApp(W.vs, "session"); await a;
  const b = focusApp(W.sf, "session"); await b;
  winIn(W.ms); const c = focusApp(W.ms, "deny"); await c;
  camTo({ x: 960, y: 540, s: 1 }, 700); cursorShow(0);
  const bd = boundary([W.vs, W.sf], [W.ms]);
  await wait(1600); bd.remove();
} };
const t3: Scene = { id: "t-memory", title: "Memory", dur: DUR["t-memory"], run: async () => {
  [W.vs, W.sf].forEach((w) => animate(w.badge, { o: 0 }, { dur: 300 }));
  for (const id of ["openVscode", "viewConfig", "readDocs", "error1", "creds", "restart", "error2", "readDocs2", "message"]) { observeFrom(id, id.includes("Docs") ? W.br.view : W.ed.code); await wait(160); }
  actions.confirmTask();
  const kv = await kernelView({ fast: true });
  const closing = kv.close(true); await wait(800); await backdrop("dark", 400); await closing;
  await statement(["Not everything you did.", "Everything you need to continue."], 700, { caps: true, small: true });
  backdrop("none", 500);
} };
const t4: Scene = { id: "t-lens", title: "Lens", dur: DUR["t-lens"], run: async () => {
  front(W.vs); W.ed.show("db");
  const r = rectOf(errEl()); camTo({ x: r.x + r.w / 2 + 200, y: r.y - 40, s: 1.5 }, 700);
  setPath({ x: r.x - 40, y: r.y - 60 }); cursorShow(1);
  await circleAndMenu(errEl(), { dur: 700 });
  await wait(300); await clickEl(menu!.opt("L")); await picked;
  say("n08");
  const card = lensCard(circle!.rect);
  await wait(4600);
  card.close(); circle!.clear(); circle = null;
} };
const t5: Scene = { id: "t-resume", title: "Resume", dur: DUR["t-resume"], run: async () => {
  actions.endSession(); cursorShow(0);
  backdrop("dark", 700); say("n10", undefined, false);
  await statement(["Stop now.", "Continue tomorrow."], 500);
  hideAll(); D.wall.className = "morning"; D.clock.textContent = "Wed 9:04";
  await backdrop("none", 900);
  camTo({ x: 1500, y: 300, s: 1.5 }, 600);
  let go!: () => void; const restored = new Promise<void>((r) => (go = r));
  const rc = resumeCard(go);
  setPath({ x: 1400, y: 640 }); cursorShow(1);
  await wait(2200); await clickEl(rc.btn); await restored;
  camTo({ x: 960, y: 540, s: 1 }, 800);
  [W.vs, W.sf].forEach((w, i) => { recede(w, 0); set(w.el, { o: 0, x: i ? 200 : -200, s: 0.92 }); front(w); animate(w.el, { o: 1, x: 0, s: 1 }, { dur: 700, delay: i * 140, ease: ease.move }); });
  await wait(900);
  camTo({ x: 820, y: 560, s: 1.12 }, 2600, ease.inOut); // a slow push so the held frame keeps breathing
  await wait(800);
} };
const t6: Scene = { id: "t-end", title: "Shapr Flow", dur: DUR["t-end"], run: async () => {
  cursorShow(0); await backdrop("dark", 700); sfx("logo");
  animate(D.endcard, { o: 1 }, { dur: 900, ease: ease.enter });
  [...D.endcard.children].forEach((p, i) => { set(p as HTMLElement, { o: 0, y: 14 }); animate(p as HTMLElement, { o: 1, y: 0 }, { dur: 700, delay: 150 + i * 350, ease: ease.enter }); });
  await wait(4600);
} };
export const TRAILER: Scene[] = [t1, t2, t3, t4, t5, t6];
export const PROGRAMS: Record<string, Scene[]> = { hero: HERO, trailer: TRAILER };
