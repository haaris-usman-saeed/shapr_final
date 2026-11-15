// Beat 11 (Shapr Flow, concept): Simulate. An earlier note meets a new requirement; the note divides into
// two alternatives, each with an advantage, a tradeoff, a source and an open assumption (left unresolved).
// Scenario analysis, not prediction.
import { h, s, css, px, show } from "../src/stage.js";
import { ease, prog, keys, life, lerp, spring } from "../src/motion.js";
import { simCard, noteCard } from "../src/ui.js";
import { devWindows } from "./_kit.js";

export default async function (ctx) {
  const { stage, story, files, marks: M } = ctx;
  const SIM = story.flow.simulate;
  stage.menubar.setWord("Aurora");
  const { tmw } = devWindows(stage, files, { editor: { x: 110, y: 92, w: 1040, h: 560 }, term: { x: 760, y: 470, w: 1060, h: 450 } });
  tmw.set({ opacity: 0 });

  const req = noteCard(SIM.requirement, "New requirement · Jordan's email");
  const note = noteCard(SIM.note, "Earlier note · architecture-notes.md");
  const cards = SIM.options.map((o) => simCard(o));
  const svg = s("svg", { width: 1920, height: 1080, viewBox: "0 0 1920 1080", style: "position:absolute;left:0;top:0" });
  const lines = [0, 1].map(() => s("path", { fill: "none", stroke: "#6B5BD2", "stroke-width": 2, "stroke-dasharray": "6 6", opacity: 0 }));
  svg.append(...lines);
  stage.shapr.append(svg, req, note, ...cards.map((c) => c.el));
  const W = 660, gap = 70;
  const reqX = 960 - 300, reqY = 120;
  css(req, { left: px(reqX), top: px(reqY), width: "600px" });
  const noteX = 960 - 300, noteY = 430;
  css(note, { width: "600px" });
  const homes = [{ x: 960 - gap / 2 - W, y: 380 }, { x: 960 + gap / 2, y: 380 }];
  cards.forEach((c) => css(c.el, { width: px(W) }));
  const tension = h("div", { class: "sim-tension" }, "Conflicts with");
  stage.shapr.append(tension);

  return (t) => {
    stage.dim(1, 0, 9);
    css(stage.veil, { background: "#F4F0EA", opacity: "0.62" });
    // note, then the requirement that collides with it
    const na = ease.enter(prog(t, M.noteIn, 0.45));
    const split = ease.move(prog(t, M.split, 0.8));
    css(note, { left: px(noteX), top: px(noteY + (1 - na) * 12), transform: `scale(${lerp(1, 0.9, split).toFixed(4)})` });
    show(note, na * (1 - ease.exit(prog(t, M.split, 0.25))));
    const ra = ease.enter(prog(t, M.reqIn, 0.45));
    css(req, { transform: `translateY(${((1 - ra) * -12).toFixed(1)}px)` });
    show(req, ra);
    const ta = life(t, M.reqIn + 0.5, M.split, 0.4, 0.25);
    css(tension, { left: px(960 - 80), top: px(330) }); show(tension, ta);

    // the note divides into two cards that slide apart
    cards.forEach((c, i) => {
      const sp = spring(prog(t, M.split, 0.8), 0.03);
      const x = lerp(noteX + (600 - W) / 2, homes[i].x, sp);
      const y = lerp(noteY, homes[i].y, ease.move(prog(t, M.split, 0.6)));
      css(c.el, { left: px(x), top: px(y) });
      show(c.el, ease.enter(prog(t, M.split, 0.3)));
      c.rows.forEach((r, k) => {
        const a = ease.enter(prog(t, M.rows + k * 0.6 + i * 0.1, 0.4));
        css(r, { opacity: a.toFixed(3), transform: `translateY(${((1 - a) * 8).toFixed(1)}px)` });
      });
      // thin line back to the requirement
      const la = ease.enter(prog(t, M.split + 0.6, 0.5));
      const x0 = reqX + 300, y0 = reqY + 110, x1 = x + W / 2, y1 = y;
      lines[i].setAttribute("d", `M${x0} ${y0} C ${x0} ${y0 + 90}, ${x1} ${y1 - 110}, ${x1} ${y1}`);
      lines[i].setAttribute("opacity", (la * 0.6).toFixed(3));
    });

    const cam = keys(t, [
      [0, { x: 960, y: 420, s: 1.25 }],
      [M.split, { x: 960, y: 420, s: 1.25 }],
      [M.split + 1.2, { x: 960, y: 520, s: 1.0 }],
      [M.rows + 3.5, { x: 960, y: 540, s: 1.03 }],
    ]);
    stage.camera(cam, t, 1);
    stage.cursor(null);
  };
}
