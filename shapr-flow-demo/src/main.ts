import "./styles/main.css";
import { clock } from "./engine/clock";
import { frame, clearTweens, set } from "./engine/anim";
import { D, buildStage, fit, camReset, cur, placeCursor, h, camTick, drift } from "./ui/desktop";
import { buildWorld } from "./ui/world";
import { bindStatus, buildPop, resetShaprUI, iconHook } from "./ui/shapr";
import { actions, clearListeners } from "./state/store";
import { director } from "./scenes/director";
import { audio } from "./audio/sfx";
import { musicAt, stopMusic, loadDurations } from "./audio/narration";
import { enterInteractive, escapeTop } from "./interactive";

const q = new URLSearchParams(location.search);
const CAPTURE = q.get("capture") === "1";
audio.capture = CAPTURE;
audio.captions = q.get("captions") !== "0";
audio.muted = q.get("muted") === "1";
const stage = document.getElementById("stage")!;
let mode: "play" | "explore" | "idle" = "idle";

/** Rebuild the whole world from scratch: same starting point for autoplay, interactive and export. */
function resetWorld() {
  clock.reset(); clearTweens(); clearListeners(); resetShaprUI(); stopMusic();
  iconHook.fn = null;
  document.getElementById("dock")?.remove();
  stage.innerHTML = "";
  buildStage(stage); buildWorld(); bindStatus(); buildPop();
  actions.reset(); camReset();
  cur.x = 1500; cur.y = 900; placeCursor();
  fit();
  clock.hook = () => frame();
  (window as any).__ended = false;
}

function startProgram(program: string) {
  mode = "play";
  resetWorld();
  drift.on = true;
  director.load(program);
  set(D.icon, { o: 0 });
  director.run();
}

async function playFrom(program: string, sceneIndex: number) {
  startProgram(program);
  if (sceneIndex > 0) await director.seek(director.starts[sceneIndex]);
}

function explore() {
  mode = "explore";
  resetWorld();
  drift.on = false; // the presenter's pointer needs a still desktop
  camReset();
  enterInteractive();
  chromeEl.classList.add("show");
}

// ---------- presenter chrome ----------
const chromeEl = h("div"); chromeEl.id = "chrome";
const label = h("span", "sc", "");
const prog = h("div", "prog", "<i></i>");
const mk = (t: string, fn: () => void, title = "") => { const b = h("button", "", t); b.title = title; b.onclick = (e) => { e.stopPropagation(); fn(); }; return b; };
const playBtn = mk("Pause", () => togglePause(), "Space");
const soundBtn = mk("Sound on", () => toggleMute(), "M");
const capBtn = mk("Captions on", () => { audio.captions = !audio.captions; capBtn.textContent = audio.captions ? "Captions on" : "Captions off"; });
chromeEl.append(mk("◀︎", () => step(-1), "Left arrow"), playBtn, mk("▶︎", () => step(1), "Right arrow"), label, prog,
  mk("Restart", () => playFrom(director.program || "hero", 0), "R"), mk("Explore", () => explore()), mk("Trailer", () => playFrom("trailer", 0)), soundBtn, capBtn, mk("Full screen", () => fullscreen(), "F"));

function togglePause() { clock.paused = !clock.paused; playBtn.textContent = clock.paused ? "Play" : "Pause"; }
function toggleMute() { audio.muted = !audio.muted; soundBtn.textContent = audio.muted ? "Sound off" : "Sound on"; if (audio.muted) stopMusic(); }
function step(d: number) { if (mode !== "play") return; const i = Math.max(0, Math.min(director.scenes.length - 1, director.sceneAt(clock.time) + d)); playFrom(director.program, i); }
function fullscreen() { if (document.fullscreenElement) document.exitFullscreen(); else document.documentElement.requestFullscreen?.(); }

addEventListener("keydown", (e) => {
  if (CAPTURE) return;
  if (e.key === " ") { e.preventDefault(); if (mode === "play") togglePause(); }
  else if (e.key === "ArrowRight") step(1);
  else if (e.key === "ArrowLeft") step(-1);
  else if (e.key === "r" || e.key === "R") { if (mode === "explore") explore(); else playFrom(director.program || "hero", 0); }
  else if (e.key === "f" || e.key === "F") fullscreen();
  else if (e.key === "m" || e.key === "M") toggleMute();
  else if (e.key === "Escape") { if (!escapeTop() && document.fullscreenElement) document.exitFullscreen(); }
  chromeEl.classList.add("show"); setTimeout(() => mode === "play" && chromeEl.classList.remove("show"), 2500);
});
addEventListener("resize", fit);

// ---------- live loop ----------
let lastTick = 0;
async function loop(now: number) {
  if (!clock.manual) {
    await clock.liveStep(now);
    frame(); camTick(clock.time);
    if (clock.time - lastTick > 500) { lastTick = clock.time; actions.tick(); }
    if (mode === "play") {
      const i = director.sceneAt(clock.time);
      label.textContent = `${i + 1}/${director.scenes.length} · ${director.scenes[i]?.title || ""}`;
      (prog.firstChild as HTMLElement).style.width = `${(100 * clock.time) / director.total}%`;
      musicAt(director.program, clock.time / 1000, !clock.paused && !(window as any).__ended);
    } else if (mode === "explore") { label.textContent = "Interactive · D toggles the presenter panel"; (prog.firstChild as HTMLElement).style.width = "0"; }
  }
  requestAnimationFrame(loop);
}

// ---------- capture hooks (scripts/capture.mjs) ----------
(window as any).__capture = {
  async start(program: string) { clock.manual = true; startProgram(program); return { total: director.total, starts: director.starts, scenes: director.scenes.map((s) => s.id) }; },
  async at(ms: number) { await clock.advanceTo(ms); frame(); camTick(clock.time); actions.tick(); return true; },
};
(window as any).__reset = () => (mode === "explore" ? explore() : playFrom(director.program || "hero", 0));
(window as any).__state = () => import("./state/store").then((m) => m.getState());
(window as any).__explore = explore;
(window as any).__play = playFrom;

// ---------- boot ----------
async function boot() {
  await document.fonts.ready;
  resetWorld();
  if (CAPTURE) { (window as any).__ready = true; requestAnimationFrame(loop); return; }
  document.body.append(chromeEl);
  await loadDurations();
  const want = q.get("mode");
  if (want === "explore") { explore(); }
  else if (want === "play") { playFrom(q.get("program") || "hero", Number(q.get("scene") || 0)); }
  else {
    set(D.icon, { o: 0 });
    const st = h("div", "", `<div class="w">SHAPR<span>Flow</span></div><div class="b"><button data-p>Play cinematic demo</button><button class="s" data-t>60-second trailer</button><button class="s" data-e>Explore interactively</button></div><small>Space play/pause · ← → scenes · R restart · F full screen · M mute · Esc close</small>`);
    st.id = "start"; document.body.append(st);
    st.querySelector("[data-p]")!.addEventListener("click", () => { st.remove(); playFrom("hero", 0); });
    st.querySelector("[data-t]")!.addEventListener("click", () => { st.remove(); playFrom("trailer", 0); });
    st.querySelector("[data-e]")!.addEventListener("click", () => { st.remove(); explore(); });
  }
  (window as any).__ready = true;
  requestAnimationFrame(loop);
}
boot();
