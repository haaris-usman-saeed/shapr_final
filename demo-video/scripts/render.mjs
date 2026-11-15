#!/usr/bin/env node
// Frame-by-frame renderer. Every frame: set frame n, wait for paint, capture, pipe into FFmpeg.
//   node scripts/render.mjs still   --film hero --entry 2 --t 1.0,2.5 [--proxy] [--out qa/frames]
//   node scripts/render.mjs segment --film hero --entry 2 [--proxy] [--workers 4] [--force]
//   node scripts/render.mjs film    --film hero [--proxy] [--workers 4] [--only 2,3]
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { chromium } = require("playwright"); // the pre-installed Playwright (resolved via NODE_PATH)

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const cmd = args[0];
const opt = (k, d) => { const i = args.indexOf("--" + k); return i < 0 ? d : (args[i + 1] && !args[i + 1].startsWith("--") ? args[i + 1] : true); };
const PROXY = !!opt("proxy", false);
const HD = !!opt("hd", false); // native 1080p (no 4K master)
const WORKERS = Number(opt("workers", 4));
const CAPTIONS = opt("captions", "on"); // on | off | big
const FPS = 30;

const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".json": "application/json", ".woff2": "font/woff2", ".woff": "font/woff", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg" };
export function serve() {
  return new Promise((res) => {
    const srv = http.createServer((req, rsp) => {
      const p = path.join(ROOT, decodeURIComponent(new URL(req.url, "http://x").pathname));
      if (!p.startsWith(ROOT) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { rsp.writeHead(404); return rsp.end(); }
      rsp.writeHead(200, { "content-type": MIME[path.extname(p)] || "text/plain" });
      fs.createReadStream(p).pipe(rsp);
    });
    srv.listen(0, "127.0.0.1", () => res(srv));
  });
}

const timeline = () => JSON.parse(fs.readFileSync(path.join(ROOT, "timeline.json"), "utf8"));

async function openPage(browser, port, film, entry) {
  const ctx = await browser.newContext({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: PROXY ? 0.5 : HD ? 1 : 2 });
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.error("[page]", e.message));
  page.on("console", (m) => { if (m.type() === "error") console.error("[console]", m.text()); });
  await page.goto(`http://127.0.0.1:${port}/index.html?film=${film}&entry=${entry}&captions=${CAPTIONS}`);
  const ok = await page.evaluate(() => window.__ready);
  if (!ok) throw new Error(await page.evaluate(() => window.__error));
  const cdp = await ctx.newCDPSession(page);
  return { page, cdp, ctx };
}

async function grab(p, n, type = "jpeg") {
  await p.page.evaluate((n) => new Promise((r) => { window.__frame(n); requestAnimationFrame(() => requestAnimationFrame(r)); }), n);
  // page.screenshot honours deviceScaleFactor (raw CDP capture returns CSS-pixel size)
  return p.page.screenshot(type === "png" ? { type: "png" } : { type: "jpeg", quality: 93 });
}

function ffmpegSink(out, { grain = PROXY } = {}) {
  // Master segments stay clean (grain would defeat compression); grain is added at export.
  const vf = ["format=yuv420p"];
  if (grain) vf.push(PROXY ? "noise=c0s=5:c0f=t+u" : "noise=c0s=7:c0f=t+u");
  const ff = spawn("ffmpeg", ["-y", "-loglevel", "error", "-f", "image2pipe", "-framerate", String(FPS), "-c:v", "mjpeg", "-i", "-",
    "-vf", vf.join(","), "-c:v", "libx264", "-preset", PROXY ? "veryfast" : "fast", "-crf", PROXY ? "20" : "14", "-pix_fmt", "yuv420p",
    "-g", String(FPS), "-r", String(FPS), out], { stdio: ["pipe", "inherit", "inherit"] });
  const done = new Promise((res, rej) => ff.on("close", (c) => (c === 0 ? res() : rej(new Error("ffmpeg exit " + c)))));
  return { write: (buf) => new Promise((r) => (ff.stdin.write(buf) ? r() : ff.stdin.once("drain", r))), end: async () => { ff.stdin.end(); await done; } };
}

function entryHash(film, idx) {
  const tl = timeline();
  const e = tl.films[film].entries[idx];
  const h = crypto.createHash("sha1");
  h.update(JSON.stringify({ e, base: tl.scenes[e.scene], PROXY, HD, CAPTIONS, v: 3 }));
  const files = [`scenes/${e.scene}.js`, "src/stage.js", "src/ui.js", "src/apps.js", "src/motion.js", "src/main.js", "src/cues.js", "src/stage.css", "src/ui.css", "src/apps.css", "tokens.css", "assets/demo-data/story.json", "assets/audio/narration/manifest.json"];
  for (const f of files) { const p = path.join(ROOT, f); if (fs.existsSync(p)) h.update(fs.readFileSync(p)); }
  // scene helpers a scene imports
  for (const f of fs.readdirSync(path.join(ROOT, "scenes")).filter((x) => x.startsWith("_"))) h.update(fs.readFileSync(path.join(ROOT, "scenes", f)));
  return h.digest("hex").slice(0, 12);
}

export async function renderSegment(browser, port, film, idx, { force = false } = {}) {
  const tl = timeline();
  const e = tl.films[film].entries[idx];
  const dir = path.join(ROOT, "build", PROXY ? "proxy" : HD ? "hd" : "master", film + (CAPTIONS !== "on" ? "-" + CAPTIONS : ""));
  fs.mkdirSync(dir, { recursive: true });
  const name = `${String(idx).padStart(2, "0")}_${e.scene}`;
  const out = path.join(dir, `${name}.mp4`);
  const stamp = path.join(dir, `${name}.hash`);
  const hash = entryHash(film, idx);
  if (!force && fs.existsSync(out) && fs.existsSync(stamp) && fs.readFileSync(stamp, "utf8") === hash) { console.log(`  cached ${name}`); return out; }
  const total = Math.round(e.dur * FPS);
  const n = Math.max(1, Math.min(WORKERS, Math.ceil(total / 45)));
  const per = Math.ceil(total / n);
  const t0 = Date.now();
  const parts = await Promise.all(Array.from({ length: n }, async (_, w) => {
    const a = w * per, b = Math.min(total, a + per);
    if (a >= b) return null;
    const part = path.join(dir, `${name}.part${w}.mp4`);
    const p = await openPage(browser, port, film, idx);
    const sink = ffmpegSink(part);
    for (let f = a; f < b; f++) await sink.write(await grab(p, f));
    await sink.end();
    await p.ctx.close();
    return part;
  }));
  const list = path.join(dir, `${name}.txt`);
  fs.writeFileSync(list, parts.filter(Boolean).map((p) => `file '${p}'`).join("\n"));
  await run("ffmpeg", ["-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", list, "-c", "copy", out]);
  parts.filter(Boolean).forEach((p) => fs.unlinkSync(p)); fs.unlinkSync(list);
  fs.writeFileSync(stamp, hash);
  console.log(`  rendered ${name}: ${total} frames in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  return out;
}

export function run(bin, a) {
  return new Promise((res, rej) => { const p = spawn(bin, a, { stdio: "inherit" }); p.on("close", (c) => (c === 0 ? res() : rej(new Error(`${bin} exit ${c}`)))); });
}

async function main() {
  const srv = await serve();
  const port = srv.address().port;
  const browser = await chromium.launch({ args: ["--font-render-hinting=none", "--disable-lcd-text", "--force-color-profile=srgb", "--hide-scrollbars"] });
  try {
    const film = opt("film", "hero");
    if (cmd === "still") {
      const idx = Number(opt("entry", 0));
      const out = path.join(ROOT, opt("out", "qa/frames"));
      fs.mkdirSync(out, { recursive: true });
      const p = await openPage(browser, port, film, idx);
      const scene = timeline().films[film].entries[idx].scene;
      for (const t of String(opt("t", "0")).split(",").map(Number)) {
        const file = path.join(out, `${film}-${String(idx).padStart(2, "0")}-${scene}-${t.toFixed(2)}${PROXY ? "-proxy" : ""}.png`);
        fs.writeFileSync(file, await grab(p, Math.round(t * FPS), "png"));
        console.log(file);
      }
    } else if (cmd === "segment") {
      await renderSegment(browser, port, film, Number(opt("entry", 0)), { force: !!opt("force", false) });
    } else if (cmd === "film") {
      const entries = timeline().films[film].entries;
      const only = opt("only", null);
      const idxs = only ? String(only).split(",").map(Number) : entries.map((_, i) => i);
      for (const i of idxs) await renderSegment(browser, port, film, i, { force: !!opt("force", false) });
    } else {
      console.log("usage: render.mjs still|segment|film --film hero [--entry N] [--t a,b] [--proxy]");
    }
  } finally {
    await browser.close();
    srv.close();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main().catch((e) => { console.error(e); process.exit(1); });
