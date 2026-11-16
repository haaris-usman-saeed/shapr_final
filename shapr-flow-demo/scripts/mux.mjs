#!/usr/bin/env node
// Mux the captured picture with the mixed audio, normalised to -16 LUFS / -1.5 dBTP.
//   node scripts/mux.mjs hero exports/shapr_flow_hero.mp4
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const [program, out] = process.argv.slice(2);
const dir = path.join(ROOT, "build", program), mix = path.join(dir, "mix.wav"), video = path.join(dir, "video.mp4");
const m = spawnSync("ffmpeg", ["-hide_banner", "-i", mix, "-af", "loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"], { encoding: "utf8" }).stderr;
const j = JSON.parse(m.slice(m.lastIndexOf("{")));
const norm = path.join(dir, "norm.wav");
execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-i", mix, "-af", `loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=${j.input_i}:measured_TP=${j.input_tp}:measured_LRA=${j.input_lra}:measured_thresh=${j.input_thresh}:offset=${j.target_offset}:linear=true,aresample=48000`, "-ar", "48000", norm]);
fs.mkdirSync(path.dirname(path.join(ROOT, out)), { recursive: true });
execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-i", video, "-i", norm, "-c:v", "copy", "-c:a", "aac", "-b:a", "256k", "-shortest", "-movflags", "+faststart", path.join(ROOT, out)]);
console.log("→", out);
