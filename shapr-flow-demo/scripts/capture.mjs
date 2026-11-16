#!/usr/bin/env node
// Frame-accurate capture of an autoplay program from the built app (dist/).
//   node scripts/capture.mjs --program hero --stills 3.5,12,40 [--out qa/stills]
//   node scripts/capture.mjs --program hero --out exports/shapr_flow_hero.mp4 [--workers 4] [--scale 1]
// Each worker loads the app with ?capture=1, fast-forwards (deterministically) to its chunk, then steps
// the shared clock frame by frame. Audio is mixed afterwards from the logged cues (scripts/audio.py).
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { spawn, execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DIST = path.join(ROOT, "dist");
const a = process.argv.slice(2);
const opt = (k, d) => { const i = a.indexOf("--" + k); return i < 0 ? d : a[i + 1]; };
const PROGRAM = opt("program", "hero"), FPS = Number(opt("fps", 30)), WORKERS = Number(opt("workers", 4)), SCALE = Number(opt("scale", 1));
const MIME = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json", ".mp3": "audio/mpeg", ".woff2": "font/woff2" };

function serve() {
  return new Promise((res) => {
    const s = http.createServer((q, r) => {
      const p = path.join(DIST, decodeURIComponent(new URL(q.url, "http://x").pathname));
      if (!p.startsWith(DIST) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { r.writeHead(404); return r.end(); }
      r.writeHead(200, { "content-type": MIME[path.extname(p)] || "application/octet-stream" }); fs.createReadStream(p).pipe(r);
    });
    s.listen(0, "127.0.0.1", () => res(s));
  });
}

async function open(browser, port) {
  const ctx = await browser.newContext({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: SCALE });
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.error("[page]", e.message));
  page.on("console", (m) => { if (m.type() === "error" || m.type() === "warning") console.error("[console]", m.text()); });
  await page.goto(`http://127.0.0.1:${port}/index.html?capture=1`);
  await page.waitForFunction(() => window.__ready === true);
  const info = await page.evaluate((p) => window.__capture.start(p), PROGRAM);
  return { page, ctx, info };
}

const shot = (page, type = "jpeg") => page.screenshot(type === "png" ? { type: "png" } : { type: "jpeg", quality: 92 });
const at = (page, ms) => page.evaluate((t) => window.__capture.at(t), ms);

async function main() {
  const srv = await serve(); const port = srv.address().port;
  const browser = await chromium.launch({ args: ["--font-render-hinting=none", "--force-color-profile=srgb", "--hide-scrollbars", "--autoplay-policy=no-user-gesture-required"] });
  try {
    const stills = opt("stills", null);
    if (stills) {
      const out = path.join(ROOT, opt("out", "qa/stills")); fs.mkdirSync(out, { recursive: true });
      const { page, ctx } = await open(browser, port);
      for (const t of stills.split(",").map(Number).sort((x, y) => x - y)) {
        await at(page, t * 1000);
        const f = path.join(out, `${PROGRAM}-${t.toFixed(1).padStart(5, "0")}.png`); fs.writeFileSync(f, await shot(page, "png")); console.log(f);
      }
      await ctx.close(); return;
    }
    // full export
    const { info, ctx: c0 } = await open(browser, port); await c0.close();
    const total = info.total, frames = Math.ceil((total / 1000) * FPS);
    console.log(`${PROGRAM}: ${(total / 1000).toFixed(1)} s, ${frames} frames, ${WORKERS} workers`);
    const tmp = path.join(ROOT, "build", PROGRAM); fs.mkdirSync(tmp, { recursive: true });
    const per = Math.ceil(frames / WORKERS); const t0 = Date.now();
    let cues = null;
    const parts = await Promise.all(Array.from({ length: WORKERS }, async (_, w) => {
      const f0 = w * per, f1 = Math.min(frames, f0 + per);
      const part = path.join(tmp, `part${w}.mp4`);
      const { page, ctx } = await open(browser, port);
      await at(page, (f0 * 1000) / FPS);
      const ff = spawn("ffmpeg", ["-y", "-loglevel", "error", "-f", "image2pipe", "-framerate", String(FPS), "-c:v", "mjpeg", "-i", "-",
        "-vf", `scale=1920:1080:flags=lanczos,format=yuv420p,noise=c0s=4:c0f=t+u`, "-c:v", "libx264", "-preset", "medium", "-crf", "17", "-pix_fmt", "yuv420p", "-r", String(FPS), part], { stdio: ["pipe", "inherit", "inherit"] });
      const done = new Promise((r, j) => ff.on("close", (c) => (c === 0 ? r() : j(new Error("ffmpeg " + c)))));
      for (let f = f0; f < f1; f++) {
        await at(page, (f * 1000) / FPS);
        const buf = await shot(page);
        if (!ff.stdin.write(buf)) await new Promise((r) => ff.stdin.once("drain", r));
        if (w === 0 && f % 300 === 0) console.log(`  frame ${f}/${per} (${((Date.now() - t0) / 1000).toFixed(0)} s)`);
      }
      ff.stdin.end(); await done;
      if (w === WORKERS - 1) cues = await page.evaluate(() => window.__cues);
      await ctx.close();
      return part;
    }));
    // cues for the audio mix come from a complete deterministic run
    if (!cues || !cues.length || cues[cues.length - 1].t < total - 15000) {
      const { page, ctx } = await open(browser, port); await at(page, total); cues = await page.evaluate(() => window.__cues); await ctx.close();
    }
    fs.writeFileSync(path.join(tmp, "cues.json"), JSON.stringify({ total, fps: FPS, starts: info.starts, scenes: info.scenes, cues }, null, 1));
    const list = path.join(tmp, "list.txt"); fs.writeFileSync(list, parts.map((p) => `file '${p}'`).join("\n"));
    const video = path.join(tmp, "video.mp4");
    execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", list, "-c", "copy", video]);
    console.log(`video ${video} in ${((Date.now() - t0) / 1000).toFixed(0)} s; cues ${cues.length}`);
  } finally { await browser.close(); srv.close(); }
}
main().catch((e) => { console.error(e); process.exit(1); });
