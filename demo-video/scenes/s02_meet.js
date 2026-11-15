// Beat 2: the clutter clears in one motion; the Shapr icon arrives; the real menu opens.
import { h, css, px, show } from "../src/stage.js";
import { ease, prog, keys, life, cursorAt, lerp, clamp, D } from "../src/motion.js";
import { browser, docsPage, previewPDF, chatPage, codeEditor, terminal } from "../src/apps.js";
import { shaprMenu } from "../src/ui.js";

export default async function (ctx) {
  const { stage, story, files, marks: M } = ctx;
  stage.menubar.app.textContent = "Finder";

  // the same clutter, frozen where beat 1 left it
  const specs = [
    ["Browser", 110, 96, 900, 600, browser({ tabs: ["Aurora wiki"], url: "wiki.aurora-team.example", page: docsPage({ title: "Connecting to PostgreSQL", paras: files.docs.split("\n").slice(2, 5) }).el }).el],
    ["Browser", 760, 140, 940, 560, browser({ tabs: Array(24).fill("Docs"), active: 23, url: "search.example", page: h("div") }).el],
    ["aurora-architecture.pdf — Preview", 1210, 300, 600, 620, previewPDF().el],
    ["AI Chat — Browser", 230, 360, 780, 600, chatPage({ service: "AI Chat", turns: [] }).el],
    ["db.js — aurora-api — Code", 640, 430, 1000, 540, codeEditor({ files }).el],
    ["Terminal — aurora-api", 1100, 640, 760, 380, terminal({ log: files.terminal }).el, true],
    ["Another AI — Browser", 960, 180, 800, 560, chatPage({ service: "Another AI", turns: [] }).el],
  ];
  const wins = specs.map(([title, x, y, w, hh, body, dark], i) => stage.addWindow({ title, x, y, w, h: hh, body, dark, z: i + 1 }));
  wins.forEach((w, i) => { w.cx = w.x + w.w / 2; w.cy = w.y + w.h / 2; });

  const menu = shaprMenu({ pack: null, others: story.otherPacks.slice(1) });
  stage.shapr.append(menu.el);
  const icon = stage.menubar.icon;
  const ic = stage.menubar.center();
  const menuX = Math.min(ic.x - 14, 1920 - 14 - 520), menuY = 40;

  const cur = [
    { t: 0, x: 1230, y: 700 },
    { t: 3.9, x: 1250, y: 520 },
    { t: 4.85, x: ic.x + 2, y: 18, click: true, bend: -0.18 },
    { t: 9.0, x: ic.x + 6, y: 22 },
    { t: 10.3, x: 1250, y: 470 },
  ];

  return (t) => {
    // one motion: each window drops back and fades, staggered 45 ms, toward its own corner
    wins.forEach((w, i) => {
      const t0 = M.clear + i * 0.045;
      const k = ease.exit(prog(t, t0, 0.62));
      const dx = (w.cx - 960) * 0.10 * k, dy = (w.cy - 560) * 0.10 * k + 30 * k;
      w.set({ opacity: 1 - k, scale: 1 - 0.07 * k, ty: dy });
      css(w.el, { marginLeft: px(dx) });
      w.fade(i < wins.length - 1 ? 0.75 : 0, 0.55);
    });

    // the Shapr icon arrives on the downbeat
    const ia = ease.enter(prog(t, M.iconIn, 0.5));
    css(icon, { opacity: ia.toFixed(3), transform: `translateY(${((1 - ia) * -6).toFixed(1)}px)` });
    const iconPulse = prog(t, M.iconIn + 0.15, 0.5);
    css(icon.querySelector(".glyph"), { transform: `scale(${(1 + 0.18 * Math.sin(Math.PI * iconPulse)).toFixed(3)})` });
    icon.classList.toggle("open", t >= M.click + 0.15 && t < M.menuOut);

    // the real menu, abridged: rows arrive with a short stagger
    const ma = life(t, M.menuIn, M.menuOut, 0.32, 0.22);
    const mk = ease.enter(prog(t, M.menuIn, 0.32));
    css(menu.el, { left: px(menuX), top: px(menuY), transform: `translateY(${((1 - mk) * -8).toFixed(1)}px) scale(${lerp(0.97, 1, mk).toFixed(4)})` });
    show(menu.el, ma);
    menu.rows.forEach((r, i) => css(r, { opacity: ease.enter(prog(t, M.menuIn + 0.06 + i * 0.045, 0.3)).toFixed(3) }));
    stage.dim(life(t, M.menuIn, M.menuOut, 0.4, 0.3), 0.14);

    const cam = keys(t, [
      [0, { x: 1100, y: 600, s: 1.18 }],
      [0.8, { x: 960, y: 540, s: 1.0 }],
      [4.6, { x: 960, y: 540, s: 1.0 }],
      [5.9, { x: menuX + 220, y: 330, s: 1.55 }],
      [10.9, { x: menuX + 220, y: 330, s: 1.55 }],
      [12.2, { x: 1100, y: 420, s: 1.2 }],
    ]);
    stage.camera(cam, t, 1);
    stage.cursor(cursorAt(t, cur));
  };
}
