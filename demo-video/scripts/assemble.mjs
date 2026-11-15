#!/usr/bin/env node
// Join a film's rendered segments, add the normalised mix, and export.
//   node scripts/assemble.mjs --film hero --proxy            → exports/proxy/shapr_hero_proxy.mp4
//   node scripts/assemble.mjs --film hero --name shapr_hero  → exports/shapr_hero_4k.mp4 + shapr_hero_1080p.mp4
//   flags: --captions big|off (use that segment set), --no-4k, --silent (no narration mix)
import fs from "node:fs";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf("--" + k); return i < 0 ? d : (args[i + 1] && !args[i + 1].startsWith("--") ? args[i + 1] : true); };
const film = opt("film", "hero");
const PROXY = !!opt("proxy", false);
const HD = !!opt("hd", false);
const CAP = opt("captions", "on");
const name = opt("name", `shapr_${film}`);
const ff = (a) => execFileSync("ffmpeg", ["-y", "-hide_banner", "-loglevel", "error", ...a], { stdio: "inherit" });

const tl = JSON.parse(fs.readFileSync(path.join(ROOT, "timeline.json"), "utf8"));
const entries = tl.films[film].entries;
const segDir = path.join(ROOT, "build", PROXY ? "proxy" : HD ? "hd" : "master", film + (CAP !== "on" ? "-" + CAP : ""));
const segs = entries.map((e, i) => path.join(segDir, `${String(i).padStart(2, "0")}_${e.scene}.mp4`));
for (const s of segs) if (!fs.existsSync(s)) { console.error("missing segment " + s + " (run render.mjs film first)"); process.exit(1); }
const tmp = path.join(ROOT, "build/tmp"); fs.mkdirSync(tmp, { recursive: true });
const list = path.join(tmp, `${film}-list.txt`);
fs.writeFileSync(list, segs.map((s) => `file '${s}'`).join("\n"));
const video = path.join(tmp, `${film}${PROXY ? "-proxy" : ""}-${CAP}-video.mp4`);
ff(["-f", "concat", "-safe", "0", "-i", list, "-c", "copy", video]);

// audio: two-pass loudness normalisation to -16 LUFS, -1.5 dBTP
const mix = path.join(ROOT, "build/audio", film, opt("silent", false) ? "music_sfx.wav" : "mix.wav");
if (opt("silent", false)) ff(["-i", path.join(ROOT, "build/audio", film, "music.wav"), "-i", path.join(ROOT, "build/audio", film, "sfx.wav"), "-filter_complex", "amix=inputs=2:normalize=0", mix]);
const probe = spawnSync("ffmpeg", ["-hide_banner", "-i", mix, "-af", "loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"], { encoding: "utf8" }).stderr;
const m = JSON.parse(probe.slice(probe.lastIndexOf("{")));
const norm = path.join(tmp, `${film}-norm.wav`);
ff(["-i", mix, "-af", `loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=${m.input_i}:measured_TP=${m.input_tp}:measured_LRA=${m.input_lra}:measured_thresh=${m.input_thresh}:offset=${m.target_offset}:linear=true,aresample=48000`, "-ar", "48000", norm]);

const outDir = path.join(ROOT, PROXY ? "exports/proxy" : "exports");
fs.mkdirSync(outDir, { recursive: true });
const mux = (v, out, extra = []) => ff(["-i", v, "-i", norm, ...extra, "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-shortest", "-movflags", "+faststart", "-metadata", `title=Shapr — ${tl.films[film].title || film}`, out]);
if (PROXY) {
  mux(video, path.join(outDir, `${name}_proxy.mp4`), ["-c:v", "copy"]);
  console.log("proxy → " + path.join(outDir, `${name}_proxy.mp4`));
} else {
  if (!opt("no-4k", false) && !HD) { mux(video, path.join(outDir, `${name}_4k.mp4`), ["-vf", "format=yuv420p,noise=c0s=3:c0f=t+u", "-c:v", "libx264", "-preset", "medium", "-crf", "19", "-profile:v", "high", "-pix_fmt", "yuv420p", "-r", "30", "-maxrate", "60M", "-bufsize", "120M"]); console.log("4k → " + `${name}_4k.mp4`); }
  // 1080p: downscaled from the 4K master, with its own fine grain so gradients don't band
  const hdName = opt("exact", false) ? `${name}.mp4` : `${name}_1080p.mp4`;
  mux(video, path.join(outDir, hdName), ["-vf", "scale=1920:1080:flags=lanczos,format=yuv420p,noise=c0s=4:c0f=t+u", "-c:v", "libx264", "-preset", "slow", "-crf", "17", "-profile:v", "high", "-pix_fmt", "yuv420p", "-r", "30"]);
  console.log("1080p → " + hdName);
}
