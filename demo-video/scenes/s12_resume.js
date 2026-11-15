// Beat 12: lid-closed darkness, a morning desktop, "Welcome back." (Flow concept), the work slides back,
// then the end card: the mark draws on, SHAPR, "Your work. Understood."
import { h, s, css, px, show, shaprGlyph } from "../src/stage.js";
import { ease, prog, keys, life, cursorAt, lerp, clamp } from "../src/motion.js";
import { resumeCard } from "../src/ui.js";
import { devWindows, surface } from "./_kit.js";
import { browser, docsPage } from "../src/apps.js";

export default async function (ctx) {
  const { stage, story, files, marks: M } = ctx;
  const R = story.flow.resume;
  stage.menubar.app.textContent = "Finder";
  stage.menubar.clock.textContent = "Wed 9:12";

  // the session's windows, which slide back into place on Continue
  const docs = docsPage({ title: "Connecting to PostgreSQL", paras: files.docs.split("\n").slice(2).filter(Boolean), highlight: 3 });
  const bw = stage.addWindow({ title: "Browser", x: 980, y: 96, w: 860, h: 520, body: browser({ tabs: ["Aurora wiki"], url: "wiki.aurora-team.example/backend/postgres", page: docs.el }).el, z: 1 });
  const { edw, tmw } = devWindows(stage, files, { editor: { x: 110, y: 120, w: 980, h: 560 }, term: { x: 640, y: 560, w: 1000, h: 420 } });
  const wins = [[edw, -260, 40], [tmw, 0, 320], [bw, 300, -40]];
  wins.forEach(([w]) => { w.home = { x: w.x, y: w.y }; });

  const card = resumeCard(R);
  stage.shapr.append(card.el);
  const ic = stage.menubar.center();
  const cardX = Math.min(ic.x - 60, 1920 - 24 - 600), cardY = 44;
  const btn = () => { const r = card.btn.getBoundingClientRect(), w = stage.world.getBoundingClientRect(), sc = w.width / 1920; return { x: (r.left - w.left) / sc + r.width / sc / 2, y: (r.top - w.top) / sc + r.height / sc / 2 }; };
  css(card.el, { left: px(cardX), top: px(cardY) });
  const b = btn();

  // lid closed: darkness with the faintest reflection
  const lid = h("div", { class: "lid" });
  stage.screen.append(lid);

  // end card
  const glyph = s("svg", { width: 132, height: 132, viewBox: "0 0 24 24", fill: "none", class: "end-glyph" },
    ...["M12 3.2 21 7.6 12 12 3 7.6Z", "M4.6 11.2 12 14.8l7.4-3.6L21 12l-9 4.4L3 12Z", "M4.6 15.6 12 19.2l7.4-3.6L21 16.4l-9 4.4L3 16.4Z"].map((d, i) =>
      s("path", { d, stroke: "#E9A07E", "stroke-width": 0.35, fill: "#C4623F", "fill-opacity": 0, "stroke-linejoin": "round", pathLength: 100, "stroke-dasharray": 100, "stroke-dashoffset": 100, "data-i": i })));
  const word = h("div", { class: "word" }, "SHAPR");
  const line = h("div", { class: "line" }, "Your work. Understood.");
  const small = h("div", { class: "small" }, "An intelligent companion for your computer.");
  const end = h("div", { class: "card-dark" }, h("div", { class: "endmark" }, glyph, word, line, small));
  stage.screen.append(end);

  const cur = [
    { t: 0, x: 1100, y: 700 },
    { t: M.cardIn + 0.4, x: 1100, y: 700 },
    { t: M.click - 0.3, x: b.x + 10, y: b.y + 6, click: true, clickDelay: 0.45 },
    { t: 10, x: b.x - 40, y: b.y + 200 },
  ];

  return (t) => {
    // darkness → morning
    const wake = ease.move(prog(t, M.wake, 1.1));
    css(lid, { opacity: (1 - wake).toFixed(3) });

    // resume card (concept) from the menu bar
    const ca = surface(card.el, t, M.cardIn, M.click + 0.35, cardX, cardY, { rise: -8 });
    card.lines.forEach((l, i) => css(l, { opacity: ease.enter(prog(t, M.cardIn + 0.25 + i * 0.06, 0.4)).toFixed(3) }));
    stage.dim(life(t, M.cardIn, M.click + 0.3, 0.45, 0.3), 0.0, 6);
    css(stage.veil, { background: "#F4F0EA", opacity: (0.35 * life(t, M.cardIn, M.click + 0.3, 0.45, 0.3)).toFixed(3) });

    // windows slide back into their earlier positions, staggered (600 ms in total)
    wins.forEach(([w, dx, dy], i) => {
      const t0 = M.windows + i * 0.09;
      const k = ease.move(prog(t, t0, 0.6));
      w.set({ x: w.home.x + dx * (1 - k), y: w.home.y + dy * (1 - k), opacity: ease.enter(prog(t, t0, 0.35)), scale: lerp(0.94, 1, k) });
    });

    const cam = keys(t, [
      [0, { x: 960, y: 540, s: 1.0 }],
      [M.cardIn - 0.2, { x: 960, y: 540, s: 1.0 }],
      [M.cardIn + 0.9, { x: cardX + 300, y: 300, s: 1.45 }],
      [M.click + 0.2, { x: cardX + 300, y: 300, s: 1.45 }],
      [M.click + 1.4, { x: 960, y: 540, s: 1.0 }],
    ]);
    stage.camera(cam, t, 1);
    stage.cursor(cursorAt(t, cur), { visible: t > M.wake + 0.5 && t < M.endCard ? 1 : 0 });

    // end card
    const ea = ease.move(prog(t, M.endCard, 0.25));
    show(end, ea);
    glyph.querySelectorAll("path").forEach((p, i) => {
      const d = ease.move(prog(t, M.endCard + 0.15 + i * 0.12, 0.8));
      p.setAttribute("stroke-dashoffset", (100 * (1 - d)).toFixed(2));
      p.setAttribute("fill-opacity", (ease.enter(prog(t, M.endCard + 0.7 + i * 0.1, 0.5)) * [1, 0.72, 0.48][i]).toFixed(3));
    });
    const wa = ease.enter(prog(t, M.word, 0.7));
    css(word, { opacity: wa.toFixed(3), letterSpacing: `${lerp(0.34, 0.16, wa).toFixed(3)}em`, transform: `translateY(${((1 - wa) * 14).toFixed(1)}px)` });
    const la = ease.enter(prog(t, M.line, 0.6));
    css(line, { opacity: la.toFixed(3), transform: `translateY(${((1 - la) * 24).toFixed(1)}px)` });
    const sa = ease.enter(prog(t, M.small, 0.6));
    css(small, { opacity: sa.toFixed(3), transform: `translateY(${((1 - sa) * 12).toFixed(1)}px)` });
    // the final hold drifts very slightly so the frame is never dead
    css(end.firstChild, { transform: `scale(${(1 + 0.012 * prog(t, M.endCard, 8)).toFixed(4)})` });
  };
}
