// Feature tour: chapter, opening and closing cards on the dark stage.
// entry: { kicker, title, sub, flow?: true }
import { h, css, show } from "../src/stage.js";
import { ease, prog, lerp } from "../src/motion.js";

export default async function (ctx) {
  const { stage, entry } = ctx;
  const kicker = h("div", { class: "kicker", style: { color: entry.flow ? "#A99BF0" : "#E9A07E" } }, entry.kicker || "");
  const title = h("div", { class: "big" + (entry.long ? " long" : "") }, entry.title);
  const sub = h("div", { class: "chap-sub" }, entry.sub || "");
  const glow = h("div", { class: "card-glow" });
  const inner = h("div", { class: "card-inner" }, kicker, title, sub);
  const card = h("div", { class: "card-dark" }, glow, inner);
  stage.screen.append(card);
  stage.camera({ x: 960, y: 540, s: 1 }, 0, 0); // gives the world its own stacking context, so the menu bar stays under the card
  stage.cursor(null);
  return (t) => {
    show(card, 1);
    const end = entry.dur;
    const out = 1 - ease.exit(prog(t, end - 0.35, 0.35));
    const a = ease.enter(prog(t, 0.1, 0.6));
    css(kicker, { opacity: (ease.enter(prog(t, 0.0, 0.5)) * out).toFixed(3) });
    css(title, { opacity: (a * out).toFixed(3), transform: `translateY(${((1 - a) * 24).toFixed(1)}px)` });
    // a slow push and a drifting glow so a held card is never a dead frame
    const k = prog(t, 0, end);
    css(inner, { transform: `scale(${(1 + 0.05 * k).toFixed(4)}) translateY(${(-10 * k).toFixed(1)}px)` });
    css(glow, { transform: `translate(${(-160 + 320 * k).toFixed(1)}px, ${(40 * Math.sin(k * 3)).toFixed(1)}px)`, opacity: (0.9 * out).toFixed(3) });
    css(sub, { opacity: (ease.enter(prog(t, 0.5, 0.5)) * out).toFixed(3) });
    stage.cursor(null);
  };
}
