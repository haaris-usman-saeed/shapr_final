// Page runtime. URL: index.html?film=hero&entry=3   (or ?scene=<module>&from=0&dur=5 for ad-hoc)
// Exposes window.__ready (Promise) and window.__frame(n) for the render harness.
import { Stage, Statement, Captions, ConceptPill, css, show } from "./stage.js";
import { FPS } from "./motion.js";
import { captionCues } from "./cues.js";

const q = new URLSearchParams(location.search);

async function text(p) { const r = await fetch(p); if (!r.ok) throw new Error(`fetch ${p}: ${r.status}`); return r.text(); }
async function json(p) { return JSON.parse(await text(p)); }

async function boot() {
  const story = await json("assets/demo-data/story.json");
  const files = {};
  for (const [k, p] of Object.entries(story.files)) files[k] = await text("assets/demo-data/" + p);
  const timeline = await json("timeline.json");
  let durs = {};
  try { durs = (await json("assets/audio/narration/manifest.json")).durations || {}; } catch { /* estimates */ }

  let entry;
  if (q.get("film")) entry = timeline.films[q.get("film")].entries[Number(q.get("entry"))];
  else entry = { scene: q.get("scene"), from: Number(q.get("from") || 0), dur: Number(q.get("dur") || 5) };
  // An entry may borrow its scene's marks/statements from the hero entry of the same scene.
  const base = timeline.scenes[entry.scene] || {};
  const marks = { ...(base.marks || {}), ...(entry.marks || {}) };
  const from = entry.from || 0;
  const shift = (list) => (list || []).map((x) => ({ ...x, at: x.at - from }));
  const statements = shift(entry.statements ?? base.statements);
  const narration = shift(entry.narration ?? base.narration);
  const cues = entry.captions === false ? [] : captionCues(narration, durs);
  const concept = (entry.concept ?? base.concept ?? []).map(([a, b]) => [a - from, b - from]);

  const root = document.getElementById("root");
  const stage = new Stage(root, { story, wallpaper: base.wallpaper || "day" });
  const mod = await import(`../scenes/${entry.scene}.js`);
  const ctx = { stage, story, files, marks, entry, base, FPS, statementsOn: statements.length > 0 };
  const update = await mod.default(ctx);
  const st = new Statement(stage);
  const cap = new Captions(stage, { big: q.get("captions") === "big" });
  const pill = new ConceptPill(stage);
  const noCaptions = q.get("captions") === "off";

  await document.fonts.ready;
  for (const f of ["400 20px Inter", "700 20px Inter", "400 20px 'JetBrains Mono'", "700 20px 'JetBrains Mono'", "400 20px 'Instrument Serif'", "600 20px Fraunces"]) await document.fonts.load(f);
  const missing = [...document.fonts].filter((f) => f.status === "error").map((f) => f.family);
  if (missing.length) throw new Error("font failed: " + missing.join(","));

  window.__info = { dur: entry.dur, fps: FPS, scene: entry.scene };
  window.__frame = (n) => {
    const tl = n / FPS;          // local time within this entry
    const t = tl + from;         // scene time
    update(t, tl);
    const sb = st.update(tl, statements, { dark: false });
    if (sb > 0) css(stage.cursorEl, { opacity: String((parseFloat(stage.cursorEl.style.opacity) || 0) * (1 - Math.min(1, sb * 1.6))) });
    cap.update(tl, noCaptions ? [] : cues, sb);
    pill.update(concept.some(([a, b]) => tl >= a && tl < b));
  };
  window.__frame(0);
}

window.__ready = boot().then(() => true, (e) => { console.error(e); window.__error = String(e.stack || e); return false; });
