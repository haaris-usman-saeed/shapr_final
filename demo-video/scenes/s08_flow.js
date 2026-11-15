// Beat 8 (Shapr Flow, concept): chapter card, then a user-started session. Shapr asks about each app;
// Messages is blocked and Shapr itself greys it out. (macOS has no per-app Screen Recording grant:
// this is Shapr enforcing the user's choice.)
import { h, css, px, show, lockSVG, tickSVG } from "../src/stage.js";
import { ease, prog, keys, life, cursorAt, lerp } from "../src/motion.js";
import { codeEditor, browser, docsPage, messagesApp } from "../src/apps.js";
import { permissionPrompt, sessionPanel } from "../src/ui.js";
import { rectOf, surface } from "./_kit.js";

export default async function (ctx) {
  const { stage, story, files, marks: M } = ctx;
  const F = story.flow, P = story.pack;
  stage.menubar.setWord("Aurora");

  const ed = codeEditor({ files });
  const cw = stage.addWindow({ title: "db.js — aurora-api — Code", x: 100, y: 96, w: 860, h: 560, body: ed.el, z: 1 });
  const docs = docsPage({ title: "Connecting to PostgreSQL", paras: files.docs.split("\n").slice(2, 4) });
  const bw = stage.addWindow({ title: "Browser", x: 1000, y: 96, w: 820, h: 480, body: browser({ tabs: ["Aurora wiki"], url: "wiki.aurora-team.example", page: docs.el }).el, z: 1 });
  const mw = stage.addWindow({ title: "Messages", x: 560, y: 620, w: 820, h: 420, body: messagesApp().el, z: 2 });
  const lock = h("div", { class: "lockveil" }, lockSVG(44), h("div", {}, "Shapr can't see Messages"), h("div", { class: "lv-sub" }, "Blocked for this session"));
  mw.el.append(lock);

  const sess = sessionPanel({ pack: P, apps: F.apps });
  stage.shapr.append(sess.el);
  const ic = stage.menubar.center();
  const sX = 1920 - 24 - 470, sY = 46;
  css(sess.el, { left: px(sX), top: px(sY) });
  sess.rows.forEach((r) => css(r, { opacity: "0" }));
  const local = sess.el.querySelector(".ss-local");

  const prompts = ["Code", "Browser", "Messages"].map((app) => { const p = permissionPrompt({ app }); stage.shapr.append(p.el); return p; });
  const wins = [cw, bw, mw];
  const pPos = wins.map((w) => ({ x: w.x + w.w / 2 - 260, y: w.y + w.h / 2 - 70 }));
  prompts.forEach((p, i) => css(p.el, { left: px(pPos[i].x), top: px(pPos[i].y) }));
  const btn = (i, k) => rectOf(prompts[i].btns[k], stage);
  const b1 = btn(0, 1), b2 = btn(1, 1), b3 = btn(2, 0);
  const c = (r) => ({ x: r.x + r.w / 2, y: r.y + r.h / 2 });

  // chapter card
  const chap = h("div", { class: "card-dark" }, h("div", { class: "kicker", style: { color: "#A99BF0" } }, "Next"), h("div", { class: "big" }, "Shapr Flow"),
    h("div", { class: "chap-sub" }, "What we're designing next · a concept"));
  stage.screen.append(chap);

  const cur = [
    { t: 0, x: 1200, y: 700 },
    { t: M.chapterOut + 0.3, x: 1200, y: 700 },
    { t: M.sessionClick - 0.15, x: ic.x + 2, y: 18, click: true },
    { t: M.p1 + 0.5, x: 700, y: 520 },
    { t: M.a1 - 0.25, ...c(b1), click: true },
    { t: M.a2 - 0.25, ...c(b2), click: true },
    { t: M.b3 - 0.25, ...c(b3), click: true },
    { t: 13, x: c(b3).x + 60, y: c(b3).y + 120 },
  ];

  return (t) => {
    const ca = 1 - ease.exit(prog(t, M.chapterOut - 0.35, 0.35));
    show(chap, ca);
    const kk = ease.enter(prog(t, 0.15, 0.6));
    css(chap.querySelector(".big"), { opacity: kk.toFixed(3), transform: `translateY(${((1 - kk) * 24).toFixed(1)}px)` });
    css(chap.querySelector(".kicker"), { opacity: ease.enter(prog(t, 0.05, 0.5)).toFixed(3) });
    css(chap.querySelector(".chap-sub"), { opacity: ease.enter(prog(t, 0.6, 0.5)).toFixed(3) });

    surface(sess.el, t, M.sessionIn, 99, sX, sY, { rise: -8 });
    stage.menubar.icon.classList.toggle("open", t >= M.sessionClick && t < M.sessionIn + 0.6);
    css(local, { opacity: ease.enter(prog(t, M.sessionIn + 0.3, 0.4)).toFixed(3) });
    const decided = [M.a1, M.a2, M.b3];
    sess.rows.forEach((r, i) => css(r, { opacity: ease.enter(prog(t, decided[i] + 0.15, 0.3)).toFixed(3) }));
    const pin = [M.p1, M.p2, M.p3];
    prompts.forEach((p, i) => {
      surface(p.el, t, pin[i], decided[i] + 0.15, pPos[i].x, pPos[i].y);
      // the app being asked about comes forward; the others recede
      wins[i].fade(t >= pin[i] - 0.2 && t < decided[i] + 0.3 ? 0 : t >= M.sessionIn ? 0.6 : 0, 0.5);
    });
    const lk = ease.enter(prog(t, M.lock, 0.5));
    css(lock, { opacity: lk.toFixed(3) });
    css(mw.body, { filter: lk > 0 ? `grayscale(${lk.toFixed(2)}) blur(${(lk * 5).toFixed(1)}px)` : "none" });
    if (t > M.lock) mw.fade(0);
    stage.menubar.app.textContent = t < M.p2 ? "Code" : t < M.p3 ? "Browser" : "Messages";

    const cam = keys(t, [
      [0, { x: 960, y: 540, s: 1.0 }],
      [M.chapterOut, { x: 1200, y: 360, s: 1.3 }],
      [M.sessionIn + 0.6, { x: 1300, y: 330, s: 1.35 }],
      [M.p1 - 0.1, { x: 1100, y: 400, s: 1.1 }],
      [M.p1 + 0.6, { x: 560, y: 400, s: 1.35 }],
      [M.p2 - 0.1, { x: 560, y: 400, s: 1.35 }],
      [M.p2 + 0.6, { x: 1400, y: 360, s: 1.35 }],
      [M.p3 - 0.1, { x: 1400, y: 360, s: 1.35 }],
      [M.p3 + 0.6, { x: 970, y: 760, s: 1.35 }],
      [M.lock + 0.8, { x: 970, y: 760, s: 1.35 }],
      [M.lock + 2.0, { x: 1150, y: 520, s: 1.05 }],
    ]);
    stage.camera(cam, t, 1);
    stage.cursor(cursorAt(t, cur), { visible: t > M.chapterOut ? 1 : 0 });
  };
}
