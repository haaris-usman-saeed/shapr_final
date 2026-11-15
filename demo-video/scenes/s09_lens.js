// Beat 9 (Shapr Flow, concept): circle the error again, pick Lens; a small card unfolds beside the
// code with what you already know, each line with its source.
import { h, css, px, show } from "../src/stage.js";
import { ease, prog, keys, life, cursorAt, lerp } from "../src/motion.js";
import { toastCard, lensCard, icon } from "../src/ui.js";
import { devWindows, rectOf, surface, keyHint } from "./_kit.js";
import { circleFX, unionRect } from "./_circle.js";
import { errorShot } from "./s03_circle.js";

export default async function (ctx) {
  const { stage, story, files, marks: M } = ctx;
  const P = story.pack;
  stage.menubar.app.textContent = "Terminal";
  stage.menubar.setWord("Aurora");
  const { edw, tm, tmw } = devWindows(stage, files, { editor: { x: 110, y: 92, w: 1040, h: 560 }, term: { x: 330, y: 500, w: 1060, h: 450 } });
  edw.fade(0.6, 0.5);
  const errEl = tm.lines[6].querySelector(".tx");
  const sel = unionRect(stage, [errEl], 6);
  const fx = circleFX(stage, sel, { seed: 21 });

  // the concept action surface: the shipping actions plus Lens
  const card = toastCard({ shot: errorShot(files, 0.74), title: "Error: connect ECONNREFUSED 127.0.0.1:5432", meta: "Add it, ask about it, or see what you already know.",
    actions: [{ label: `Add to ${P.name}` }, { label: "Ask about it" }, { label: "Lens", primary: true }] });
  card.btns[2].classList.remove("primary"); card.btns[2].classList.add("violet");
  stage.shapr.append(card.el);
  const cX = sel.x + sel.w + 40, cY = sel.y - 230;
  css(card.el, { left: px(cX), top: px(cY) });
  const lensBtn = rectOf(card.btns[2], stage);

  const lens = lensCard({ items: story.flow.lens });
  stage.shapr.append(lens.el);
  const lX = sel.x + sel.w + 40, lY = sel.y - 300;
  const hint = keyHint(stage, ["⌘", "⌘"], "circle");

  const cur = [
    { t: 0, x: 900, y: 940 },
    { t: M.drawStart - 0.05, x: fx.loop[0].x, y: fx.loop[0].y },
  ];
  const after = [
    { t: M.drawEnd, ...(() => { const p = fx.head(M.drawEnd, M.drawStart, M.drawEnd); return { x: p.x, y: p.y }; })() },
    { t: M.pickLens - 0.25, x: lensBtn.x + lensBtn.w / 2, y: lensBtn.y + lensBtn.h / 2, click: true, clickDelay: 0.4 },
    { t: 9, x: lensBtn.x - 120, y: lensBtn.y + 330 },
  ];

  return (t) => {
    fx.update(t, { trigger: M.trigger, d0: M.drawStart, d1: M.drawEnd, out: M.lensIn + 0.1 });
    surface(card.el, t, M.menuIn, M.pickLens + 0.15, cX, cY);
    // Lens unfolds from the left edge, beside the code
    const la = life(t, M.lensIn, 99, 0.45);
    const lk = ease.enter(prog(t, M.lensIn, 0.45));
    css(lens.el, { left: px(lX), top: px(lY), transform: `scaleX(${lerp(0.9, 1, lk).toFixed(4)})`, clipPath: `inset(0 ${((1 - lk) * 100).toFixed(1)}% 0 0 round 24px)` });
    show(lens.el, la);
    lens.rows.forEach((r, i) => css(r, { opacity: ease.enter(prog(t, M.lensIn + 0.3 + i * 0.12, 0.4)).toFixed(3) }));
    const chipAt = [M.chip1, M.chip2, M.chip3];
    lens.chips.forEach((c, i) => {
      const k = ease.enter(prog(t, chipAt[i], 0.35));
      css(c, { opacity: k.toFixed(3), transform: `translateY(${((1 - k) * 8).toFixed(1)}px) scale(${lerp(0.92, 1, k).toFixed(3)})` });
    });
    css(errEl, { filter: t > M.drawEnd && t < M.lensIn + 6 ? "brightness(1.3)" : "none" });

    const cam = keys(t, [
      [0, { x: 900, y: 700, s: 1.25 }],
      [M.trigger, { x: sel.x + sel.w / 2, y: sel.y, s: 1.6 }],
      [M.menuIn, { x: sel.x + sel.w / 2 + 160, y: sel.y - 40, s: 1.45 }],
      [M.lensIn, { x: sel.x + sel.w / 2 + 180, y: sel.y - 60, s: 1.4 }],
      [M.lensIn + 1.2, { x: lX + 140, y: lY + 260, s: 1.42 }],
    ]);
    stage.camera(cam, t, 1);
    let p;
    if (t >= M.drawStart && t <= M.drawEnd) { const hp = fx.head(t, M.drawStart, M.drawEnd); p = { x: hp.x, y: hp.y, press: 0 }; }
    else p = cursorAt(t, t < M.drawStart ? cur : after);
    stage.cursor(p);
    hint.update(t, M.trigger - 0.1, M.drawStart + 0.5, 960, 860);
  };
}
