// Shapr's own surfaces. Everything here renders from the shared demo state and changes it only through
// store actions, so a presenter's click and an autoplay click do exactly the same thing.
import { animate, set, run, ease } from "../engine/anim";
import { wait, clock } from "../engine/clock";
import { D, h, esc, rectOf, center, SHAPR_MARK } from "./desktop";
import { actions, getState, subscribe } from "../state/store";
import { APPS, type AppId } from "../demo-data/aurora";
import { POLICY, type DemoState, type Scope } from "../state/kernel";
import { sfx } from "../audio/sfx";

const gl = (app: AppId, cls = "gl") => `<span class="${cls}" style="background:${APPS[app].tint}">${APPS[app].glyph}</span>`;
const scopeLabel: Record<Scope, string> = { once: "Allowed once", session: "This session", always: "Always", deny: "Not allowed" };

// ---------- menu-bar status ----------
export function bindStatus() {
  subscribe((s) => {
    D.icon.dataset.s = s.session;
    const t = D.icon.querySelector(".task") as HTMLElement;
    t.textContent = s.session === "ended" && s.task.status !== "none" ? `${s.project} · checkpoint saved` : s.session !== "off" && s.task.status !== "none" ? `${s.project} · ${s.task.title}` : s.session === "paused" ? "Paused" : "";
  });
}
export function iconPulse() {
  const p = D.icon.querySelector(".pulse") as HTMLElement;
  set(p, { o: 0.9, s: 0.5 }); animate(p, { o: 0, s: 1.4 }, { dur: 700, ease: ease.move });
  const m = D.icon.querySelector(".mark") as unknown as HTMLElement;
  run(420, (k) => { m.style.transform = `scale(${1 + 0.18 * Math.sin(Math.PI * k)})`; });
}

// ---------- the popover ----------
export const pop = h("div", "pop glass"); pop.id = "pop";
let popOpen = false;
export const memOpen = { v: false };
/** Lets the presenter flow intercept a menu-bar click (for example to show the Resume card). */
export const iconHook = { fn: null as null | (() => boolean) };
export function resetShaprUI() { popOpen = false; memOpen.v = false; sheet.remove(); }
export function buildPop() {
  D.layer.append(pop);
  set(pop, { o: 0 });
  subscribe((s, why) => { if (popOpen) renderPop(s); });
  D.icon.addEventListener("click", () => { if (iconHook.fn && iconHook.fn()) return; popOpen ? closePop() : openPop(); });
}
function renderPop(s: DemoState) {
  pop.dataset.s = s.session;
  const status = { off: "Off", active: "Session active", paused: "Observation paused", ended: "Session ended" }[s.session];
  const apps = (Object.keys(APPS) as AppId[]).filter((a) => s.permissions[a]);
  let body = "";
  if (s.session === "off" || s.session === "ended") {
    body = `<div class="lede">${s.session === "ended" ? "Your progress was saved as a checkpoint. Temporary activity was let go." : "Start a session and Shapr follows your work, only in the apps you allow."}</div>
      <button class="btn primary big" data-a="start">${s.session === "ended" ? "Start new session" : "Start session"}</button>`;
  } else {
    body = `<div class="apps">${apps.length ? apps.map((a) => `<div class="app">${gl(a)}<span>${APPS[a].name}</span><span class="sc${s.permissions[a] === "deny" ? " no" : ""}">${scopeLabel[s.permissions[a]!]}</span></div>`).join("") : `<div class="lede" style="margin:8px 0">Open an app and Shapr will ask before it observes anything.</div>`}</div>`;
    if (s.task.status !== "none") body += `<div class="task"><div class="k">${s.task.status === "confirmed" ? "Current task" : "Likely task"}</div><div class="v">${esc(s.task.title)}</div></div>`;
    body += `<div class="row"><button class="btn" data-a="pause">${s.session === "paused" ? "Resume observing" : "Pause"}</button><button class="btn" data-a="mem">Review memory</button><button class="btn" data-a="end">End session</button></div>`;
  }
  pop.innerHTML = `<div class="hd"><span style="color:var(--accent);display:flex">${SHAPR_MARK}</span><span class="brand">SHAPR<span>Flow</span></span><span class="st"><i></i>${status}</span></div>${body}
    <div class="foot"><svg width="14" height="14" viewBox="0 0 24 24"><rect x="5" y="10.5" width="14" height="10" rx="2.5" fill="currentColor"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5" stroke="currentColor" stroke-width="2.2" fill="none"/></svg>Designed to process on this Mac</div>`;
  pop.querySelectorAll("[data-a]").forEach((b) => b.addEventListener("click", (e) => { e.stopPropagation(); popAction((b as HTMLElement).dataset.a!); }));
}
function popAction(a: string) {
  if (a === "start") { actions.startSession(); sfx("start"); iconPulse(); }
  if (a === "pause") { actions.pause(); sfx("tick"); }
  if (a === "end") { actions.endSession(); sfx("save"); closePop().then(() => toast("Checkpoint saved", "Aurora · task memory kept, temporary activity let go")); }
  if (a === "mem") { closePop(); openMemSheet(); }
}
export const popButton = (a: string) => pop.querySelector(`[data-a="${a}"]`) as HTMLElement;
export function openPop() {
  if (popOpen) return wait(0);
  popOpen = true; renderPop(getState());
  const r = rectOf(D.icon);
  pop.style.left = Math.min(r.x + r.w - 380, 1920 - 440) + "px"; pop.style.top = "46px";
  D.icon.classList.add("open"); sfx("open");
  set(pop, { o: 0, s: 0.96, y: -8 });
  return animate(pop, { o: 1, s: 1, y: 0 }, { dur: 380, ease: ease.enter });
}
export function closePop() {
  if (!popOpen) return wait(0);
  popOpen = false; D.icon.classList.remove("open");
  return animate(pop, { o: 0, s: 0.97, y: -6 }, { dur: 240, ease: ease.exit });
}

// ---------- permission prompt ----------
export function askPermission(app: AppId): { el: HTMLElement; opt: (s: Scope) => HTMLElement; done: Promise<Scope> } {
  const el = h("div", "pop glass perm", `<div class="hd">${gl(app)}<div><h3>Allow Shapr to observe ${APPS[app].name}?</h3><p>Use activity from this app to understand your work.</p></div></div>
    <div class="opts">${(["once", "session", "always", "deny"] as Scope[]).map((s) => `<div class="opt${s === "deny" ? " deny" : ""}" data-s="${s}"><i></i>${{ once: "Allow once", session: "Allow this session", always: "Always allow", deny: "Don't allow" }[s]}</div>`).join("")}</div>
    <div class="fine">Shapr enforces this choice itself, per app. Nothing from apps you don't allow enters its memory.</div>`);
  D.layer.append(el);
  const r = rectOf(D.icon);
  el.style.left = Math.min(r.x - 120, 1920 - 500) + "px"; el.style.top = "48px";
  set(el, { o: 0, s: 0.96, y: -8 });
  animate(el, { o: 1, s: 1, y: 0 }, { dur: 400, ease: ease.enter });
  sfx("open");
  let resolve!: (s: Scope) => void;
  const done = new Promise<Scope>((r2) => (resolve = r2));
  el.querySelectorAll(".opt").forEach((o) => o.addEventListener("click", async () => {
    const s = (o as HTMLElement).dataset.s as Scope;
    o.classList.add("sel");
    actions.permit(app, s); sfx(s === "deny" ? "deny" : "grant");
    await wait(380);
    await animate(el, { o: 0, s: 0.97, y: -6 }, { dur: 260, ease: ease.exit });
    el.remove(); resolve(s);
  }));
  return { el, opt: (s) => el.querySelector(`[data-s="${s}"]`) as HTMLElement, done };
}

// ---------- observation: a light pulse travels from the source to Shapr (only if retained) ----------
export function observeFrom(id: string, from: HTMLElement | null) {
  const d = actions.observe(id);
  if (d.outcome === "blocked" || d.outcome === "ignored") return d;
  if (from) flow(from);
  return d;
}
export function flow(from: HTMLElement, color = "var(--accent)") {
  const a = center(from), b = center(D.icon);
  const dot = h("div", "", ""); Object.assign(dot.style, { position: "absolute", left: "0", top: "0", width: "12px", height: "12px", margin: "-6px", borderRadius: "50%", background: color, boxShadow: "0 0 14px 3px rgba(196,90,44,.45)", zIndex: "35" });
  D.layer.append(dot);
  const mx = (a.x + b.x) / 2, my = Math.min(a.y, b.y) - 120;
  run(820, (k) => {
    const u = 1 - k; const x = u * u * a.x + 2 * u * k * mx + k * k * b.x, y = u * u * a.y + 2 * u * k * my + k * k * b.y;
    dot.style.transform = `translate(${x}px,${y}px) scale(${1 - 0.5 * k})`; dot.style.opacity = String(k < 0.1 ? k * 10 : 1);
  }, { ease: ease.inOut }).then(() => { dot.remove(); iconPulse(); sfx("tick"); });
}

// ---------- toast near the menu bar ----------
let lastToast: HTMLElement | null = null;
export function toast(title: string, sub = "", icon = "✓", hold = 2400) {
  if (lastToast) { const old = lastToast; animate(old, { o: 0 }, { dur: 150 }).then(() => old.remove()); }
  const el = h("div", "toast glass", `<span class="ic">${icon}</span><div>${esc(title)}${sub ? `<small>${esc(sub)}</small>` : ""}</div>`);
  D.layer.append(el); lastToast = el;
  const r = rectOf(D.icon);
  el.style.left = "0"; el.style.top = "0";
  const x = popOpen || memOpen.v ? Math.min(r.x - 760, 1920 - 1100) : Math.min(r.x - 160, 1920 - 520);
  set(el, { x, y: 40, o: 0 });
  animate(el, { y: 52, o: 1 }, { dur: 360, ease: ease.enter });
  wait(hold).then(async () => { await animate(el, { o: 0, y: 44 }, { dur: 260, ease: ease.exit }); el.remove(); });
  return el;
}

// ---------- memory review (three layers, live) ----------
const sheet = h("div", "memsheet glass");
export function openMemSheet() {
  memOpen.v = true;
  if (!sheet.parentElement) { D.layer.append(sheet); subscribe((s) => memOpen.v && renderSheet(s)); }
  renderSheet(getState());
  const r = rectOf(D.icon);
  sheet.style.left = Math.min(r.x - 300, 1920 - 560) + "px"; sheet.style.top = "48px";
  set(sheet, { o: 0, s: 0.97, y: -8 }); sfx("open");
  return animate(sheet, { o: 1, s: 1, y: 0 }, { dur: 380, ease: ease.enter });
}
export function closeMemSheet() { memOpen.v = false; return animate(sheet, { o: 0, y: -6 }, { dur: 240, ease: ease.exit }); }
export function renderSheet(s: DemoState) {
  const now = clock.now();
  const imm = s.immediate.map((m) => `<div class="it"><span>${esc(m.obs.label)}${m.count > 1 ? ` ×${m.count}` : ""}</span><small>expires in ${Math.max(0, Math.ceil((m.expiresAt - now) / 1000))}s</small></div>`).join("") || `<div class="empty">Nothing right now: recent activity has expired.</div>`;
  const t = s.task;
  const work = t.status === "none" ? `<div class="empty">No task yet.</div>` : [
    t.goal && ["Goal", t.goal], ...t.tried.map((x) => ["Tried", x]), t.blocker && ["Blocker", t.blocker], t.next && ["Next", t.next],
  ].filter(Boolean).map((x: any) => `<div class="it"><span><b>${x[0]}</b> · ${esc(x[1].text)}</span><small>${esc(x[1].refs[0] || "")}</small></div>`).join("");
  const lt = s.longTerm.map((l) => `<div class="it"><span>${esc(l.text)}</span><small>${l.kind}</small></div>`).join("") || `<div class="empty">No checkpoints yet.</div>`;
  sheet.innerHTML = `<div style="display:flex;align-items:center;gap:10px;font-weight:700;font-size:17px"><span style="color:var(--accent);display:flex">${SHAPR_MARK}</span>Memory · ${esc(s.project)}<button class="btn" data-x style="margin-left:auto;height:32px;font-size:14px">Done</button></div>
    <div class="sec"><div class="k"><span>Immediate</span><span>expires automatically · max ${POLICY.immediateBudget}</span></div>${imm}</div>
    <div class="sec"><div class="k"><span>Working</span><span>${t.status === "confirmed" ? "confirmed task" : t.status === "inferred" ? "inferred task" : ""}</span></div>${work}</div>
    <div class="sec"><div class="k"><span>Long-term</span><span>checkpoints and pinned</span></div>${lt}</div>
    ${s.deletedSessions ? `<div class="sec" style="color:var(--live);font-weight:650;font-size:16px">✓ Session memory deleted · temporary activity removed from this Mac</div>` : ""}
    <div class="sec" style="display:flex;gap:8px"><button class="btn" data-del>Delete this session</button><span style="font-size:13.5px;color:var(--ink-3);align-self:center">Not observed: ${s.blockedCount} event${s.blockedCount === 1 ? "" : "s"} from apps you blocked (content never stored)</span></div>`;
  (sheet.querySelector("[data-x]") as HTMLElement).onclick = () => closeMemSheet();
  (sheet.querySelector("[data-del]") as HTMLElement).onclick = () => { actions.deleteSession(); sfx("deny"); };
}
export const sheetEl = sheet;
