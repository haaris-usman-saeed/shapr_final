// The circle gesture (signature moment 1), shared by beat 3 and the Lens beat.
// CaptureOverlay.swift: a light veil while circling (8%); once locked, outside the loop dims to 32%;
// the locked loop is a white under-stroke with the accent stroke and a soft glow.
import { s, css, show } from "../src/stage.js";
import { ease, prog, clamp, lerp, spring } from "../src/motion.js";
import { makeLoop, rrectSamples, strokeOutline } from "../src/ui.js";

export function circleFX(stage, rect, { color = "#B5562D", glow = "rgba(196,98,63,0.6)", seed = 3 } = {}) {
  const svg = s("svg", { width: 1920, height: 1080, viewBox: "0 0 1920 1080", style: "position:absolute;left:0;top:0;overflow:visible" });
  const veil = s("path", { fill: "#121110", "fill-rule": "evenodd" });
  const under = s("path", { fill: "rgba(255,255,255,0.85)" });
  const g = s("g", { style: `filter: drop-shadow(0 0 5px ${glow}) drop-shadow(0 0 2px ${glow})` });
  const stroke = s("path", { fill: color });
  g.append(stroke);
  const pen = s("g", {}, s("circle", { r: 9, fill: "#fff", style: "filter: drop-shadow(0 1px 3px rgba(0,0,0,0.3))" }), s("circle", { r: 6.5, fill: color }));
  svg.append(veil, under, g, pen);
  stage.fx.append(svg);
  const turns = 1.1;
  const loop = makeLoop(rect, seed, turns);
  const N = loop.length;
  const RS = rrectSamples(rect, loop[0].a, 600, 14, 16);
  const target = loop.map((_, i) => RS[Math.round((i / (N - 1)) * turns * RS.length) % RS.length]);

  // shape at time t: drawing [d0, d1], spring lock [d1, d1 + 0.35]
  function shape(t, d0, d1) {
    const k = prog(t, d0, d1 - d0);
    const draw = 1 - (1 - k) * (1 - k) * (1 - 0.25 * k); // a hand: steady, then easing into the close
    const lockK = spring(prog(t, d1, 0.35), 0.05);
    const pts = loop.map((p, i) => {
      if (lockK <= 0) return p;
      const r = target[i];
      return { x: lerp(p.x, r.x, lockK), y: lerp(p.y, r.y, lockK), a: p.a };
    });
    return { pts, draw, lockK };
  }

  return {
    loop, svg,
    // head position for the cursor while drawing
    head(t, d0, d1) { const { pts, draw } = shape(t, d0, d1); return pts[Math.min(N - 1, Math.max(0, Math.floor(draw * (N - 1))))]; },
    update(t, { trigger, d0, d1, out }) {
      if (t < trigger || t > out + 0.4) { show(svg, 0); return 0; }
      show(svg, 1 - ease.exit(prog(t, out, 0.3)));
      const { pts, draw, lockK } = shape(t, d0, d1);
      const locked = t >= d1;
      // veil: 8% while circling, 32% outside the loop once locked
      const va = locked ? lerp(0.08, 0.32, ease.move(prog(t, d1, 0.3))) : 0.08 * ease.enter(prog(t, trigger, 0.2));
      const hole = locked ? "M" + pts.slice(0, Math.round(N / 1.1)).map((p) => `${p.x.toFixed(1)} ${p.y.toFixed(1)}`).join(" L") + " Z" : "";
      veil.setAttribute("d", `M-400 -400 H2400 V1500 H-400 Z ${hole}`);
      veil.setAttribute("opacity", va.toFixed(3));
      if (t < d0) { stroke.setAttribute("d", ""); under.setAttribute("d", ""); pen.setAttribute("opacity", "0"); return va; }
      const w0 = lerp(3.2, 4.2, lockK), w1 = lerp(8, 4.2, lockK);
      stroke.setAttribute("d", strokeOutline(pts, locked ? 1 : Math.max(0.02, draw), w0, w1));
      under.setAttribute("d", locked ? strokeOutline(pts, 1, w0 + 3, w1 + 3) : "");
      under.setAttribute("opacity", (lockK * 0.9).toFixed(3));
      const hp = pts[Math.min(N - 1, Math.floor(draw * (N - 1)))];
      pen.setAttribute("transform", `translate(${hp.x.toFixed(1)} ${hp.y.toFixed(1)})`);
      pen.setAttribute("opacity", locked ? (1 - prog(t, d1, 0.15)).toFixed(3) : "1");
      return va;
    },
  };
}

// The rect around a set of text spans, in world coordinates.
export function unionRect(stage, els, pad = 0) {
  const w = stage.world.getBoundingClientRect(), sc = w.width / 1920;
  let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
  for (const el of els) {
    const r = el.getBoundingClientRect();
    x0 = Math.min(x0, r.left); y0 = Math.min(y0, r.top); x1 = Math.max(x1, r.right); y1 = Math.max(y1, r.bottom);
  }
  return { x: (x0 - w.left) / sc - pad, y: (y0 - w.top) / sc - pad, w: (x1 - x0) / sc + 2 * pad, h: (y1 - y0) / sc + 2 * pad };
}
