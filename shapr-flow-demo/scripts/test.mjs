#!/usr/bin/env node
// Browser validation of the built demo (dist/). Writes qa/test-report.json and screenshots in qa/test/.
//   npm run build && node scripts/test.mjs
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DIST = path.join(ROOT, "dist"), OUT = path.join(ROOT, "qa", "test");
fs.mkdirSync(OUT, { recursive: true });
const MIME = { ".html": "text/html", ".json": "application/json", ".mp3": "audio/mpeg" };
const srv = await new Promise((r) => { const s = http.createServer((q, w) => { const p = path.join(DIST, new URL(q.url, "http://x").pathname); if (!fs.existsSync(p) || fs.statSync(p).isDirectory()) { w.writeHead(404); return w.end(); } w.writeHead(200, { "content-type": MIME[path.extname(p)] || "application/octet-stream" }); fs.createReadStream(p).pipe(w); }); s.listen(0, "127.0.0.1", () => r(s)); });
const URLB = `http://127.0.0.1:${srv.address().port}/index.html`;
const browser = await chromium.launch();
const results = []; const errors = [];
async function check(name, fn) {
  try { const detail = await fn(); results.push({ name, pass: true, detail }); console.log("PASS", name, detail ?? ""); }
  catch (e) { results.push({ name, pass: false, detail: String(e.message || e) }); console.log("FAIL", name, e.message); }
}
const assert = (c, m) => { if (!c) throw new Error(m); };

const ctx = await browser.newContext({ viewport: { width: 1600, height: 900 } });
const page = await ctx.newPage();
page.on("pageerror", (e) => errors.push(e.message));
const st = () => page.evaluate(() => window.__state());
const dock = (label) => page.locator("#dock button", { hasText: label }).first().click();
const wait = (ms) => page.waitForTimeout(ms);
const shot = (n) => page.screenshot({ path: path.join(OUT, n + ".png") });

await check("loads with the start screen and no errors", async () => {
  await page.goto(URLB); await page.waitForFunction(() => window.__ready === true);
  assert(await page.locator("#start").isVisible(), "start screen missing");
  await shot("01-start"); return "start screen visible";
});

await check("autoplay progresses and the scene label updates", async () => {
  await page.click("#start [data-p]");
  await wait(3500);
  const t = await page.evaluate(() => document.querySelector("#chrome .sc").textContent);
  const w = await page.evaluate(() => document.querySelector("#chrome .prog i").style.width);
  assert(parseFloat(w) > 0.5, "progress did not move: " + w);
  await shot("02-autoplay"); return `${t} · progress ${w}`;
});

await check("Space pauses and resumes; arrow keys move between scenes", async () => {
  await page.keyboard.press("Space"); const w1 = await page.evaluate(() => document.querySelector("#chrome .prog i").style.width);
  await wait(800); const w2 = await page.evaluate(() => document.querySelector("#chrome .prog i").style.width);
  assert(w1 === w2, "did not pause"); await page.keyboard.press("Space");
  await page.keyboard.press("ArrowRight"); await wait(1500);
  const label = await page.evaluate(() => document.querySelector("#chrome .sc").textContent);
  assert(/^2\//.test(label), "next scene not reached: " + label);
  await page.keyboard.press("ArrowRight"); await page.keyboard.press("ArrowRight"); await wait(1200);
  const l3 = await page.evaluate(() => document.querySelector("#chrome .sc").textContent);
  return `paused at ${w1}; then ${label} → ${l3}`;
});

await check("interactive: start a session from the menu-bar popover", async () => {
  await page.evaluate(() => window.__explore()); await wait(500);
  await page.click("#shapr-icon"); await wait(500);
  await page.click('#pop [data-a="start"]'); await wait(400);
  const s = await st(); assert(s.session === "active", "session " + s.session);
  await shot("03-session"); return "session active";
});

await check("permission prompt: allow VS Code for this session, deny Safari", async () => {
  await page.keyboard.press("Escape");
  await dock("Focus VS Code"); await wait(600);
  await page.click('.perm [data-s="session"]'); await wait(900);
  await dock("Focus Safari"); await wait(600);
  await shot("04-permission");
  await page.click('.perm [data-s="deny"]'); await wait(900);
  const s = await st(); assert(s.permissions.vscode === "session" && s.permissions.safari === "deny", JSON.stringify(s.permissions));
  return JSON.stringify(s.permissions);
});

await check("privacy gate: events from a denied app never enter memory", async () => {
  await dock("Open related documentation"); await wait(300);
  await dock("Receive a message"); await wait(300);
  const s = await st();
  const last = s.decisions.slice(-2).map((d) => d.outcome);
  assert(last.every((o) => o === "blocked"), "not blocked: " + last);
  assert(!s.immediate.some((m) => m.obs.app === "safari" || m.obs.app === "messages"), "blocked content stored");
  assert(!s.task.facts.some((f) => f.refs[0].startsWith("PostgreSQL")), "docs fact stored");
  return `outcomes ${last.join(", ")}; blockedCount ${s.blockedCount}`;
});

await check("memory kernel: errors infer a task, repeats are merged, attempts are kept", async () => {
  for (const l of ["Open db.js and .env", "Encounter database error", "Attempt a fix: check credentials", "Attempt a fix: restart server", "Same error again"]) { await dock(l); await wait(250); }
  const s = await st();
  assert(s.task.status === "inferred", "task " + s.task.status);
  assert(s.task.tried.length === 2, "tried " + s.task.tried.length);
  assert(s.decisions.some((d) => d.outcome === "duplicate"), "no duplicate detected");
  assert(s.task.next && s.task.next.refs.length, "no next step with sources");
  await shot("05-memory"); return `task "${s.task.title}" (${s.task.status}); tried ${s.task.tried.map((t) => t.text).join(" / ")}; next "${s.task.next.text}"`;
});

await check("free-hand circle over the terminal error opens L/T/S", async () => {
  const r = await page.evaluate(() => { const e = [...document.querySelectorAll(".termp .l")][3]; const b = e.getBoundingClientRect(); return { x: b.left, y: b.top, w: Math.min(b.width, 520), h: b.height }; });
  const cx = r.x + r.w / 2, cy = r.y + r.h / 2, rx = r.w / 2 + 30, ry = r.h / 2 + 26;
  await page.mouse.move(cx + rx, cy); await page.mouse.down();
  for (let i = 0; i <= 40; i++) { const a = (i / 40) * Math.PI * 2.1; await page.mouse.move(cx + Math.cos(a) * rx, cy + Math.sin(a) * ry); }
  await page.mouse.up(); await wait(1200);
  assert(await page.locator(".lts").count() > 0, "L/T/S menu did not appear");
  await shot("06-lts"); return "menu shown";
});

await check("Lens reflects permissions (Safari denied → says so, no docs source)", async () => {
  await page.keyboard.press("l"); await wait(1200);
  const text = await page.locator(".card").last().innerText();
  assert(/Safari isn't allowed/.test(text), "limit not stated");
  assert(!/PostgreSQL docs/.test(text), "docs source used despite denial");
  assert(/checked credentials/.test(text), "earlier attempt missing");
  await shot("07-lens-denied"); return text.split("\n").slice(0, 3).join(" | ");
});

await check("same flow with Safari allowed → Lens cites the documentation", async () => {
  await page.evaluate(() => window.__explore()); await wait(400);
  await dock("Start session"); await dock("Focus VS Code"); await wait(500); await page.click('.perm [data-s="session"]'); await wait(800);
  await dock("Focus Safari"); await wait(500); await page.click('.perm [data-s="session"]'); await wait(800);
  for (const l of ["Open db.js and .env", "Open related documentation", "Encounter database error", "Attempt a fix: check credentials", "Attempt a fix: restart server"]) { await dock(l); await wait(250); }
  await dock("Circle the terminal error"); await wait(1800);
  await page.keyboard.press("l"); await wait(1200);
  const text = await page.locator(".card").last().innerText();
  assert(/PostgreSQL docs/.test(text), "docs source missing");
  await shot("08-lens-allowed"); return "sources: " + (text.match(/Current terminal error.*$/m) || [""])[0];
});

await check("Threads: pin a finding updates task memory", async () => {
  await page.keyboard.press("Escape"); await wait(400);
  await dock("Read Docker networking docs"); await wait(500);
  const r = await page.evaluate(() => { const e = document.querySelector('[data-sel="docker"]'); const b = e.getBoundingClientRect(); return { x: b.left, y: b.top, w: b.width, h: b.height }; });
  const cx = r.x + r.w / 2, cy = r.y + r.h / 2, rx = r.w / 2 + 30, ry = r.h / 2 + 26;
  await page.mouse.move(cx - rx, cy); await page.mouse.down();
  for (let i = 0; i <= 40; i++) { const a = Math.PI + (i / 40) * Math.PI * 2.1; await page.mouse.move(cx + Math.cos(a) * rx, cy + Math.sin(a) * ry); }
  await page.mouse.up(); await wait(1200);
  await page.keyboard.press("t"); await wait(900);
  const s = await st(); assert(s.longTerm.some((l) => l.kind === "pinned"), "nothing pinned");
  return `pinned; next "${s.task.next.text}" (${s.task.next.status})`;
});

await check("Simulate: two paths with evidence; choosing one is recorded", async () => {
  await dock("Circle the architecture note"); await wait(1800);
  await page.keyboard.press("s"); await wait(3200);
  assert(await page.locator(".sim").count() === 2, "two paths not shown");
  const foot = await page.locator(".simfoot").innerText(); assert(/not a prediction/i.test(foot), "honesty note missing");
  await shot("09-simulate");
  await page.locator('.sim [data-p="A"]').click(); await wait(500);
  const s = await st(); assert(s.simulateChoice === "A", "choice " + s.simulateChoice);
  return foot.replace(/\n/g, " ");
});

await check("Pause stops observation; review and delete memory", async () => {
  await page.keyboard.press("Escape"); await wait(400);
  await dock("Pause / resume observing");
  await dock("Attempt a fix: restart server"); await wait(200);
  let s = await st(); assert(s.decisions[s.decisions.length - 1].outcome === "ignored", "paused event not ignored");
  await dock("Review memory"); await wait(600); await shot("10-memory-sheet");
  await page.click(".memsheet [data-del]"); await wait(400);
  s = await st(); assert(s.immediate.length === 0 && s.deletedSessions === 1, "not deleted");
  await page.click(".memsheet [data-x]");
  return "paused event ignored; session memory deleted";
});

await check("End the day → Resume restores the task", async () => {
  await dock("Pause / resume observing");
  // the previous test deleted the session's memory: do some work again so there is a task to save
  for (const l of ["Open db.js and .env", "Encounter database error", "Attempt a fix: check credentials", "Attempt a fix: restart server"]) { await dock(l); await wait(250); }
  await dock("End the day"); await wait(4200);
  let s = await st(); assert(s.session === "ended", "not ended");
  await page.click("#shapr-icon"); await wait(1200);
  await shot("11-resume-card");
  const card = await page.locator(".resume").innerText();
  assert(/Welcome back/.test(card) && /Continue Aurora/.test(card), "resume card content");
  await page.click('.resume [data-a="go"]'); await wait(1500);
  s = await st(); assert(s.session === "active" && s.day === 2 && s.task.status !== "none", "not resumed");
  await shot("12-resumed");
  return card.split("\n").slice(0, 4).join(" | ");
});

await check("Reset returns to the initial state", async () => {
  await page.keyboard.press("r"); await wait(600);
  const s = await st(); assert(s.session === "off" && s.decisions.length === 0 && Object.keys(s.permissions).length === 0, "not reset");
  return "initial state";
});

await check("Shapr surfaces stay inside the stage at full size", async () => {
  await page.setViewportSize({ width: 1920, height: 1080 }); await wait(300);
  await page.click("#shapr-icon"); await wait(600);
  const ok = await page.evaluate(() => [...document.querySelectorAll("#pop, .perm, .card, .lts, .memsheet, .resume, .sim")].filter((e) => getComputedStyle(e).visibility !== "hidden" && +getComputedStyle(e).opacity > 0.05).every((e) => { const r = e.getBoundingClientRect(); return r.left >= -1 && r.top >= -1 && r.right <= innerWidth + 1 && r.bottom <= innerHeight + 1; }));
  assert(ok, "a surface is clipped"); return "inside";
});

await check("no page errors", async () => { assert(errors.length === 0, errors.join(" | ")); return "0 errors"; });

fs.writeFileSync(path.join(ROOT, "qa", "test-report.json"), JSON.stringify({ when: new Date().toISOString(), results }, null, 1));
console.log(`\n${results.filter((r) => r.pass).length}/${results.length} passed`);
await browser.close(); srv.close();
process.exit(results.every((r) => r.pass) ? 0 : 1);
