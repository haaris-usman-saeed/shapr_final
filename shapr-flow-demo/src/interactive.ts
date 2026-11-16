// Interactive mode: the presenter drives the same world and the same demo state as autoplay.
// Real clicks on the simulated desktop work (menu-bar icon, permission prompts, windows, circling);
// the dock adds believable activity events and time travel.
import { animate, set } from "./engine/anim";
import { wait } from "./engine/clock";
import { D, h, winIn, front, recede, backdrop, statement, rectOf, type Win } from "./ui/desktop";
import { W, page, hideAll } from "./ui/world";
import { observeFrom, toast, openMemSheet, iconHook, openPop, closePop, closeMemSheet, memOpen } from "./ui/shapr";
import { drawCircle, enableFreeDraw, ltsMenu, selectables, type Selectable } from "./ui/circle";
import { lensCard, threadsPin, simulateView, resumeCard, restoreList } from "./ui/assist";
import { kernelView } from "./ui/kernelview";
import { actions, getState, subscribe } from "./state/store";
import { focusApp } from "./scenes/hero";
import { APPS, type AppId } from "./demo-data/aurora";

const closers: (() => unknown)[] = [];
export function escapeTop() {
  const c = closers.pop(); if (c) { c(); return true; }
  if (memOpen.v) { closeMemSheet(); return true; }
  if (D.icon.classList.contains("open")) { closePop(); return true; }
  return false;
}

async function assist(sel: Selectable, c: Awaited<ReturnType<typeof drawCircle>>) {
  actions.select({ id: sel.id, text: sel.text });
  const menu = ltsMenu(c.rect, async (m) => {
    if (m === "L") {
      const card = lensCard(c.rect, { evidence: () => { W.ed.show("env"); animate(W.ed.line(1).querySelector(".hl") as HTMLElement, { o: 1 }, { dur: 400 }); } });
      closers.push(async () => { await card.close(); c.clear(); });
    } else if (m === "T") { threadsPin(sel.text, sel.ref); c.clear(); }
    else { c.clear(); recede(W.sf, 1.6); recede(W.vs, 1.6); const sv = await simulateView(c.rect); closers.push(async () => { await sv.close(); recede(W.sf, 0); recede(W.vs, 0); }); }
  });
  closers.push(() => { menu.close(); c.clear(); });
}

export function enterInteractive() {
  // a working desktop: the presenter starts here
  set(D.icon, { o: 1 });
  W.ed.show("db"); W.ed.termLines(2);
  page("pgdocs", "postgresql.org/docs/16/client-connection.html", ["PostgreSQL docs"]);
  for (const w of [W.vs, W.sf, W.ms]) { set(w.el, { o: 1 }); }
  front(W.vs);
  // clicking a window focuses its app (and Shapr asks, if the session is on and it hasn't yet)
  for (const w of [W.vs, W.sf, W.ms, W.gpt]) w.el.addEventListener("pointerdown", () => { focusApp(w); D.appName.textContent = APPS[w.app as AppId]?.name || "Finder"; });
  enableFreeDraw((sel, c) => assist(sel, c));
  // after "next morning", the menu-bar icon offers to resume
  iconHook.fn = () => {
    const s = getState();
    if (s.session === "ended" && s.day === 1 && morning) { showResume(); return true; }
    return false;
  };
  buildDock();
}

let morning = false;
function showResume() {
  const rc = resumeCard(async () => {
    W.ed.show("env");
    [W.vs, W.sf].forEach((w, i) => { recede(w, 0); set(w.el, { o: 0, x: i ? 200 : -200, s: 0.92 }); front(w); animate(w.el, { o: 1, x: 0, s: 1 }, { dur: 700, delay: i * 140 }); });
    const rl = restoreList(1280, 600, [".env and docker-compose.yml in VS Code", "PostgreSQL docs · Docker networking", ...getState().longTerm.filter((l) => l.kind === "pinned").map((l) => "Saved finding: " + l.text.slice(0, 40) + "…"), "Task memory: goal, attempts, next step"]);
    closers.push(() => rl.close());
  });
  closers.push(() => rc.el.remove());
}

type Ev = { label: string; app: AppId; win: () => Win; prep?: () => void; obs: string; from: () => HTMLElement };
const EVENTS: Ev[] = [
  { label: "Open db.js and .env", app: "vscode", win: () => W.vs, prep: () => W.ed.show("env"), obs: "viewConfig", from: () => W.ed.code },
  { label: "Search the docs", app: "safari", win: () => W.sf, prep: () => page("search", "google.com/search?q=postgres+connection+refused", ["Search"]), obs: "searchDocs", from: () => W.br.view },
  { label: "Open related documentation", app: "safari", win: () => W.sf, prep: () => page("pgdocs", "postgresql.org/docs/16/client-connection.html", ["Search", "PostgreSQL docs"]), obs: "readDocs", from: () => W.br.view },
  { label: "Encounter database error", app: "vscode", win: () => W.vs, prep: () => { W.ed.show("db"); W.ed.termLines(5); }, obs: "error1", from: () => W.ed.termLine(3) },
  { label: "Attempt a fix: check credentials", app: "vscode", win: () => W.vs, prep: () => W.ed.show("env"), obs: "creds", from: () => W.ed.code },
  { label: "Attempt a fix: restart server", app: "vscode", win: () => W.vs, obs: "restart", from: () => W.ed.term },
  { label: "Same error again", app: "vscode", win: () => W.vs, prep: () => W.ed.termLines(5), obs: "error2", from: () => W.ed.termLine(3) },
  { label: "Read Docker networking docs", app: "safari", win: () => W.sf, prep: () => page("docker", "docs.docker.com/compose/networking", ["PostgreSQL docs", "Docker · Networking"]), obs: "dockerNote", from: () => W.br.view },
  { label: "Unrelated tab (dining menu)", app: "safari", win: () => W.sf, obs: "dining", from: () => W.br.view },
  { label: "Receive a message", app: "messages", win: () => W.ms, obs: "message", from: () => W.ms.el },
  { label: "Open the project spec", app: "safari", win: () => W.sf, prep: () => page("spec", "docs.aurora-team.example/spec", ["Aurora spec"]), obs: "archNote", from: () => W.br.view },
];

function buildDock() {
  const dock = h("div"); dock.id = "dock"; document.body.append(dock);
  const hide = h("button", "", "Hide presenter panel  (D)"); hide.onclick = () => (dock.style.display = "none");
  addEventListener("keydown", (e) => { if (e.key === "d" || e.key === "D") dock.style.display = dock.style.display === "none" ? "block" : "none"; });
  dock.append(hide);
  const st = h("div", "st");
  const btn = (t: string, fn: () => unknown) => { const b = h("button", "", t); b.onclick = (e) => { e.stopPropagation(); fn(); }; return b; };
  const sec = (t: string) => h("h4", "", t);
  dock.append(
    sec("Session"),
    btn("Open Shapr (menu bar)", () => openPop()),
    btn("Start session", () => { actions.startSession(); toast("Session started", "Open an app and Shapr will ask first"); }),
    btn("Pause / resume observing", () => actions.pause()),
    sec("Apps (Shapr asks per app)"),
    ...(["vscode", "safari", "messages"] as AppId[]).map((a) => btn(`Focus ${APPS[a].name}`, () => focusApp(a === "vscode" ? W.vs : a === "safari" ? W.sf : W.ms))),
    sec("Activity (synthetic events)"),
    ...EVENTS.map((e) => btn(e.label, async () => { e.prep?.(); front(e.win()); const d = observeFrom(e.obs, e.from()); if (d.outcome === "blocked") toast(`${APPS[e.app].name} isn't allowed`, "Nothing from it was observed", "✕"); else if (d.outcome === "ignored") toast("Not observed", d.reason, "–"); else if (d.outcome === "duplicate") toast("Repeat detected", d.reason, "×2"); else if (d.outcome === "noise") toast("Not related to the task", "Kept briefly, then expires", "·"); })),
    sec("Assist"),
    btn("Circle the terminal error", async () => { front(W.vs); W.ed.show("db"); W.ed.termLines(5); const s = selectables.find((x) => x.id === "error")!; const c = await drawCircle(s.el, { dur: 700 }); assist(s, c); }),
    btn("Circle the architecture note", async () => { front(W.sf); page("spec", "docs.aurora-team.example/spec", ["Aurora spec"]); await wait(50); const s = selectables.find((x) => x.id === "arch")!; const c = await drawCircle(s.el, { dur: 700 }); assist(s, c); }),
    btn("Confirm the inferred task", () => actions.confirmTask()),
    sec("Memory"),
    btn("Review memory (three layers)", () => openMemSheet()),
    btn("Show memory consolidation", async () => { const kv = await kernelView({ fast: true }); closers.push(() => kv.close(false)); await wait(2500); }),
    sec("Time"),
    btn("End the day → next morning", async () => {
      if (getState().session === "active" || getState().session === "paused") actions.endSession();
      await backdrop("dark", 800); await statement(["Next morning."], 300);
      hideAll(); D.wall.className = "morning"; D.clock.textContent = "Wed 9:04"; morning = true;
      await backdrop("none", 1000); toast("Click the Shapr icon to continue", "", "☀");
    }),
    sec("Demo"),
    btn("Close the top card (Esc)", () => escapeTop()),
    btn("Reset", () => (window as any).__reset?.()),
    sec("Demo state"), st,
  );
  subscribe((s) => {
    const perm = (Object.keys(APPS) as AppId[]).filter((a) => s.permissions[a]).map((a) => `${APPS[a].name}: ${s.permissions[a]}`).join("\n") || "none";
    st.textContent = `session: ${s.session} · day ${s.day}\napps:\n${perm}\ntask: ${s.task.status}${s.task.title ? " · " + s.task.title : ""}\nimmediate: ${s.immediate.length} · tried: ${s.task.tried.length} · long-term: ${s.longTerm.length}\nblocked events: ${s.blockedCount}\nlast: ${s.decisions.length ? s.decisions[s.decisions.length - 1].outcome + " (" + s.decisions[s.decisions.length - 1].obsId + ")" : "–"}`;
  });
  (window as any).__dock = dock;
  dock.style.display = "block";
}
