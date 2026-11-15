#!/usr/bin/env node
// SRT and VTT for a film, from the same cues the page burns in (src/cues.js + the narration manifest).
//   node scripts/captions.mjs --film hero [--out exports/shapr_hero]
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { captionCues } from "../src/cues.js";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf("--" + k); return i < 0 ? d : args[i + 1]; };

export function filmCues(film) {
  const tl = JSON.parse(fs.readFileSync(path.join(ROOT, "timeline.json"), "utf8"));
  let durs = {};
  try { durs = JSON.parse(fs.readFileSync(path.join(ROOT, "assets/audio/narration/manifest.json"), "utf8")).durations; } catch {}
  const out = [];
  let t0 = 0;
  for (const e of tl.films[film].entries) {
    const base = tl.scenes[e.scene] || {};
    const from = e.from || 0;
    if (e.captions !== false) {
      const narr = (e.narration ?? base.narration ?? []).map((n) => ({ ...n, at: n.at - from })).filter((n) => n.at >= 0 && n.at < e.dur);
      for (const c of captionCues(narr, durs)) out.push({ start: t0 + c.at, end: t0 + Math.min(e.dur, c.at + c.dur), text: c.text });
    }
    t0 += e.dur;
  }
  return { cues: out, total: t0 };
}

const ts = (s, sep) => {
  const ms = Math.round(s * 1000), h = Math.floor(ms / 3600000), m = Math.floor(ms / 60000) % 60, ss = Math.floor(ms / 1000) % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${String(ss).padStart(2, "0")}${sep}${String(ms % 1000).padStart(3, "0")}`;
};

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const film = opt("film", "hero");
  const base = path.join(ROOT, opt("out", `exports/shapr_${film}`));
  fs.mkdirSync(path.dirname(base), { recursive: true });
  const { cues } = filmCues(film);
  fs.writeFileSync(base + ".srt", cues.map((c, i) => `${i + 1}\n${ts(c.start, ",")} --> ${ts(c.end, ",")}\n${c.text}\n`).join("\n"));
  fs.writeFileSync(base + ".vtt", "WEBVTT\n\n" + cues.map((c) => `${ts(c.start, ".")} --> ${ts(c.end, ".")}\n${c.text}\n`).join("\n"));
  console.log(`${cues.length} cues → ${base}.srt / .vtt`);
}
