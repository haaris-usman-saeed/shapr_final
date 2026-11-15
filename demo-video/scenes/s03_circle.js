// Beat 3: "See something important? Just circle it." Signature moment 1, then the real corner card
// (AppController.offerShot) and the capture flight into the menu bar.
import { h, css, px, show, packOrb } from "../src/stage.js";
import { ease, prog, keys, life, cursorAt, lerp, clamp, D } from "../src/motion.js";
import { toastCard } from "../src/ui.js";
import { devWindows, makeFlight, keyHint, rectOf } from "./_kit.js";
import { circleFX, unionRect } from "./_circle.js";

export function errorShot(files, scale = 1) {
  const lines = files.terminal.split("\n").filter((l) => /^Error/.test(l));
  return h("div", { class: "shot-term", style: { transform: `scale(${scale})` } }, ...lines.map((l, i) => h("div", { class: i ? "st2" : "st1" }, l.trim())));
}

export default async function (ctx) {
  const { stage, story, files, marks: M } = ctx;
  stage.menubar.app.textContent = "Terminal";
  const { ed, edw, tm, tmw } = devWindows(stage, files, { editor: { x: 110, y: 92, w: 1040, h: 560 }, term: { x: 760, y: 470, w: 1060, h: 450 } });
  edw.fade(0.55, 0.5);

  const errEls = [tm.lines[6].querySelector(".tx")];
  const sel = unionRect(stage, errEls, 6);
  const fx = circleFX(stage, sel, { seed: 5 });
  const ck = { trigger: M.trigger, d0: M.drawStart, d1: M.drawEnd, out: M.cardIn + 0.55 };

  // the real corner card, top right (ToastView: 340 x 1.3 wide)
  const pack = story.pack;
  const cardX = 1920 - 24 - 442, cardY = 34 + 18;
  const card = toastCard({ shot: errorShot(files, 0.74), title: "Error: connect ECONNREFUSED 127.0.0.1:5432", meta: "Add it, or ask your packs about it. Or hold ⌥V and ask.",
    actions: [{ label: "Add to a pack", primary: true }, { label: "Ask about it" }] });
  stage.shapr.append(card.el);
  css(card.el, { left: px(cardX), top: px(cardY) });
  const shotSlot = rectOf(card.el.querySelector(".t-shot"), stage);
  const cardRect = rectOf(card.el, stage);
  const addBtn = rectOf(card.btns[0], stage);

  // the screenshot lifting off the selection into the card
  const thumb = h("div", { class: "thumb-fly" }, errorShot(files, 1));
  stage.shapr.append(thumb);

  // after the click: flight, then the "New pack" card
  const flight = makeFlight(stage, pack, "ECONNREFUSED 127.0.0.1:5432", h("div", { class: "mini-shot" }));
  const newPack = toastCard({ shot: errorShot(files, 0.74), title: "Error: connect ECONNREFUSED 127.0.0.1:5432", meta: `New pack ${pack.name} · Terminal · just now`,
    actions: [{ label: "Undo" }, { label: "Rename" }, { label: "Move" }] });
  stage.shapr.append(newPack.el);
  const hint = keyHint(stage, ["⌘", "⌘"], "double-tap");

  const start = { x: sel.x - 26, y: sel.y - 30 };
  return (t) => {
    // the circle
    const va = fx.update(t, ck);
    // selected content brightens once locked
    const bright = ease.move(prog(t, M.drawEnd, 0.3)) * (1 - prog(t, M.clickAdd, 0.4));
    errEls.forEach((e) => css(e, { filter: bright > 0 ? `brightness(${(1 + 0.35 * bright).toFixed(3)})` : "none" }));

    // thumbnail: lifts at cardIn, travels into the card's image slot
    const tk = ease.move(prog(t, M.cardIn, 0.55));
    const lift = ease.enter(prog(t, M.cardIn, 0.16));
    if (t >= M.cardIn && t < M.cardIn + 0.62) {
      const x = lerp(sel.x, shotSlot.x, tk), y = lerp(sel.y, shotSlot.y, tk) - 10 * lift * (1 - tk);
      const w = lerp(sel.w, shotSlot.w, tk), hh = lerp(sel.h, shotSlot.h, tk);
      css(thumb, { left: px(x), top: px(y), width: px(w), height: px(hh), boxShadow: `0 ${(4 + 18 * lift * (1 - tk)).toFixed(1)}px ${(10 + 30 * lift * (1 - tk)).toFixed(1)}px rgba(0,0,0,${(0.25 * lift).toFixed(3)})` });
      show(thumb, 1);
    } else show(thumb, 0);

    // card unfolds from its image: clip from the slot to the full card
    const ca = life(t, M.cardIn + 0.4, M.clickAdd + 0.2, 0.42, 0.25);
    const ck2 = ease.enter(prog(t, M.cardIn + 0.4, 0.42));
    const inset = (a, b) => lerp(a, 0, ck2).toFixed(1);
    css(card.el, { clipPath: `inset(${inset(shotSlot.y - cardRect.y)}px ${inset(cardRect.x + cardRect.w - shotSlot.x - shotSlot.w)}px ${inset(cardRect.y + cardRect.h - shotSlot.y - shotSlot.h)}px ${inset(shotSlot.x - cardRect.x)}px round 28px)` });
    show(card.el, t < M.cardIn + 0.4 ? 0 : (t < M.clickAdd + 0.2 ? 1 : ca));

    // flight from the card to the menu bar, then the icon reacts and the "New pack" card arrives
    flight.update(t, M.clickAdd + 0.2, { x: shotSlot.x + shotSlot.w / 2, y: shotSlot.y + shotSlot.h / 2 }, 0.7);
    stage.menubarPulse(t, M.flyEnd);
    const na = life(t, M.newPackIn, 99, D.panel);
    const nk = ease.enter(prog(t, M.newPackIn, D.panel));
    css(newPack.el, { left: px(cardX), top: px(cardY), transform: `scale(${lerp(0.96, 1, nk).toFixed(4)})` });
    show(newPack.el, na);
    stage.dim(life(t, M.cardIn + 0.3, 99, 0.5) * (1 - 0.5 * prog(t, M.clickAdd, 0.5)), 0.1, 0);

    // camera: push in to ~2x for the circle, pull back to see the card
    const cx = sel.x + sel.w / 2, cy = sel.y + sel.h / 2;
    const cam = keys(t, [
      [0, { x: 960, y: 540, s: 1.0 }],
      [M.push, { x: 960, y: 540, s: 1.0 }],
      [M.push + 1.5, { x: cx, y: cy, s: 2.0 }],
      [M.pull, { x: cx, y: cy, s: 2.0 }],
      [M.pull + 1.15, { x: 1660, y: 300, s: 1.55 }],
    ]);
    stage.camera(cam, t, t < M.trigger || t > M.pull + 1.1 ? 1 : 0.25);

    // cursor: to the start of the loop, follows the stroke head, then to "Add to a pack"
    let p;
    if (t >= M.drawStart && t <= M.drawEnd) { const hp = fx.head(t, M.drawStart, M.drawEnd); p = { x: hp.x, y: hp.y, press: 0 }; }
    else {
      const end = fx.head(M.drawEnd, M.drawStart, M.drawEnd);
      p = cursorAt(t, t < M.drawStart ? [{ t: 0, x: 980, y: 900 }, { t: M.push + 1.2, x: start.x, y: start.y }, { t: M.drawStart, x: start.x, y: start.y }]
        : [{ t: M.drawEnd, x: end.x, y: end.y }, { t: M.drawEnd + 0.6, x: end.x + 14, y: end.y + 10 }, { t: M.clickAdd - 0.25, x: addBtn.x + addBtn.w * 0.55, y: addBtn.y + addBtn.h * 0.6, click: true, clickDelay: 0.4, bend: 0.1 }, { t: 12, x: addBtn.x + 40, y: addBtn.y + 120 }]);
    }
    stage.cursor(p);
    const sc = stage.toScreen({ x: start.x, y: start.y });
    hint.update(t, M.trigger - 0.15, M.drawStart + 0.6, 960, 860);
  };
}
