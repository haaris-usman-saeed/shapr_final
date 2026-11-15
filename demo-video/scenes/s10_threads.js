// Beat 10 (Shapr Flow, concept): memory condensation. Eight events on a timeline; duplicates merge,
// noise drifts off, four survivors travel into one compact card. Less is kept, on purpose.
import { h, css, px, show } from "../src/stage.js";
import { ease, prog, keys, life, lerp, clamp, arc, spring } from "../src/motion.js";
import { eventChip, threadCard } from "../src/ui.js";
import { devWindows } from "./_kit.js";

export default async function (ctx) {
  const { stage, story, files, marks: M } = ctx;
  const F = story.flow;
  stage.menubar.app.textContent = "Code";
  const { tmw } = devWindows(stage, files, { editor: { x: 110, y: 92, w: 1040, h: 560 }, term: { x: 760, y: 470, w: 1060, h: 450 } });
  tmw.set({ opacity: 0 }); // keep the background light: one focal point

  // timeline band
  const band = h("div", { class: "tl-band" }, h("div", { class: "tl-line" }),
    ...["10:42", "10:50", "11:00", "11:10", "11:20"].map((tx, i) => h("div", { class: "tl-tick", style: { left: px(i * 375) } }, h("i"), h("span", {}, tx))));
  const label = h("div", { class: "tl-label" }, h("span", { class: "tl-dot" }), "Working session · Aurora — Backend");
  stage.shapr.append(band, label);

  const chips = F.events.map((e) => { const el = eventChip(e.text); stage.shapr.append(el); return { el, ...e }; });
  const card = threadCard({ rows: F.thread });
  stage.shapr.append(card.el);
  const cardX = 960 - 260, cardY = 330;
  css(card.el, { left: px(cardX), top: px(cardY) });
  const slotRects = card.slots.map((s) => { const r = s.getBoundingClientRect(), w = stage.world.getBoundingClientRect(), sc = w.width / 1920; return { x: (r.left - w.left) / sc, y: (r.top - w.top) / sc, w: r.width / sc, h: r.height / sc }; });
  const chipW = chips.map((c) => c.el.offsetWidth);

  // loose row along the timeline
  const home = chips.map((c, i) => ({ x: 150 + i * 196, y: i % 2 ? 560 : 452 }));
  const survivors = chips.map((c, i) => i).filter((i) => chips[i].keep);
  const slotOf = {}; survivors.forEach((i, k) => (slotOf[i] = k));

  return (t) => {
    stage.dim(1, 0.0, 9);
    css(stage.veil, { background: "#F4F0EA" });
    css(stage.veil, { opacity: "0.62" });
    const bandA = life(t, 0.1, M.travel + 0.4, 0.5, 0.4);
    css(band, { opacity: bandA.toFixed(3) });
    css(label, { opacity: life(t, 0.2, M.travel + 0.4, 0.5, 0.4).toFixed(3) });

    chips.forEach((c, i) => {
      const t0 = M.chipsIn + i * 0.3;
      const a = ease.enter(prog(t, t0, 0.4));
      let x = home[i].x, y = home[i].y + (1 - a) * 14, op = a, sc = lerp(0.94, 1, a);
      if (c.dupOf != null) {
        // slide into the original and merge
        const k = ease.move(prog(t, M.merge, 0.7));
        x = lerp(x, home[c.dupOf].x, k); y = lerp(y, home[c.dupOf].y, k);
        op *= 1 - prog(t, M.merge + 0.5, 0.25);
      } else if (!c.keep) {
        // fade down and drift off
        const k = ease.exit(prog(t, M.drop, 0.9));
        y += 70 * k; op *= 1 - 0.75 * ease.move(prog(t, M.drop, 0.35)) - 0.25 * k;
      } else {
        // survivors: a merge pulse on originals, then travel into the card's slots
        const pulse = c.text && chips.some((d) => d.dupOf === i) ? Math.sin(Math.PI * prog(t, M.merge + 0.5, 0.35)) : 0;
        sc *= 1 + 0.06 * pulse;
        const k = slotOf[i];
        const tt = M.travel + k * 0.07;
        const tk = ease.move(prog(t, tt, 0.9));
        if (t >= tt) {
          const r = slotRects[k];
          const p = arc(tk, home[i], { x: r.x, y: r.y + 4 }, 0.06);
          x = p.x; y = p.y;
          sc *= lerp(1, 0.86, tk);
          op *= 1 - prog(t, tt + 0.75, 0.25);
        }
      }
      css(c.el, { transform: `translate(${x.toFixed(1)}px, ${y.toFixed(1)}px) scale(${sc.toFixed(4)})`, transformOrigin: "0 50%" });
      c.el.classList.toggle("kept", !!c.keep && t > M.drop + 0.4);
      show(c.el, t < t0 ? 0 : op);
    });

    // the card: arrives as the chips do, then its lines resolve in order
    const ca = ease.enter(prog(t, M.travel + 0.35, 0.5));
    css(card.el, { transform: `scale(${lerp(0.97, 1, ca).toFixed(4)})` });
    show(card.el, ca);
    card.slots.forEach((s, k) => {
      const a = ease.enter(prog(t, M.resolve + k * 0.16, 0.45));
      css(s.querySelector(".th-v"), { opacity: a.toFixed(3), transform: `translateY(${((1 - a) * 10).toFixed(1)}px)` });
      css(s.querySelector(".th-k"), { opacity: ease.enter(prog(t, M.travel + 0.6 + k * 0.06, 0.35)).toFixed(3) });
    });

    const cam = keys(t, [
      [0, { x: 960, y: 520, s: 1.0 }],
      [M.travel, { x: 960, y: 520, s: 1.0 }],
      [M.travel + 1.4, { x: 960, y: 535, s: 1.15 }],
    ]);
    stage.camera(cam, t, 1);
    stage.cursor(null);
  };
}
