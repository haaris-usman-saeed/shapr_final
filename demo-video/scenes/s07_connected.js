// Beat 7: three small panels in sequence, cut on action. A linked source updating the pack (Sources.swift),
// Safe Share flagging a private detail (ShareReview.swift), an AI client reading the pack over MCP.
import { h, css, px, show, packOrb, tickSVG } from "../src/stage.js";
import { ease, prog, keys, life, cursorAt, lerp, typed } from "../src/motion.js";
import { aiClient } from "../src/apps.js";
import { icon } from "../src/ui.js";
import { rectOf } from "./_kit.js";

export default async function (ctx) {
  const { stage, story, marks: M } = ctx;
  const P = story.pack, S = story.packSources[0], SH = story.share;
  stage.menubar.setWord("Aurora");

  // A: the pack's sources (LibraryView "Sources" section)
  const spin = h("span", { class: "src-spin" });
  const status = h("span", { class: "src-status" }, spin, h("span", { class: "src-st" }, "Updating…"));
  const srcPanel = h("div", { class: "src-panel glass solid" },
    h("div", { class: "lib-head" }, packOrb(P, 44), h("div", {}, h("div", { class: "lib-name" }, P.name), h("div", { class: "lib-meta" }, "Keep Updated From"))),
    h("div", { class: "src-row" }, h("span", { class: "src-ic" }, icon("sync", 22)), h("div", {}, h("div", { class: "src-t" }, S.title), h("div", { class: "src-k" }, `${S.kind} · README, open issues, recent commits`)), status),
    h("div", { class: "src-new" }, h("span", { class: "chip plain" }, "README.md"), h("span", { class: "chip plain" }, "3 open issues"), h("span", { class: "chip plain" }, "12 commits")));
  stage.shapr.append(srcPanel);

  // B: Share Safely
  const opts = ["Keep", "Replace", "Remove"].map((o) => h("span", { class: "seg" }, o));
  const val = h("span", { class: "sh-val" }, SH.finding);
  const share = h("div", { class: "share glass solid" },
    h("div", { class: "sh-h" }, icon("share", 22), h("div", {}, h("div", { class: "p-title" }, `Share Safely · ${P.name}`), h("div", { class: "p-sub" }, "Checked on this Mac · 1 thing to look at"))),
    h("div", { class: "sh-row" }, h("div", {}, h("div", { class: "sh-kind" }, SH.kind), val), h("div", { class: "segs" }, ...opts)),
    h("div", { class: "sh-note" }, "Choices here change only the shared copy. Your own pack stays exactly as it is."));
  stage.shapr.append(share);
  const replaceR = () => rectOf(opts[1], stage);

  // C: an AI client using the pack over MCP
  const ai = aiClient({ mcp: story.mcp });
  const aw = stage.addWindow({ title: "AI client — connected to Shapr (MCP)", x: 380, y: 300, w: 1160, h: 470, body: ai.el, z: 3 });
  const answer = ai.answer.textContent;

  const PX = 520, PY = 410;
  css(srcPanel, { left: px(PX), top: px(PY) });
  css(share, { left: px(PX), top: px(PY) });
  const rr = replaceR();
  const cur = [
    { t: 0, x: 1100, y: 760 },
    { t: M.b + 0.2, x: 1240, y: 760 },
    { t: 4.85, x: rr.x + rr.w / 2, y: rr.y + rr.h / 2, click: true },
    { t: M.c - 0.05, x: rr.x + 80, y: rr.y + 160 },
    { t: M.c, x: 1300, y: 760 },
    { t: 9, x: 1320, y: 770 },
  ];

  return (t) => {
    const inA = t < M.b, inB = t >= M.b && t < M.c, inC = t >= M.c;
    stage.menubar.app.textContent = inC ? "AI client" : "Shapr";
    // A
    const a = inA ? ease.enter(prog(t, M.a, 0.4)) : 0;
    css(srcPanel, { transform: `translateY(${((1 - a) * 10).toFixed(1)}px)` }); show(srcPanel, a);
    const done = t >= 1.7;
    spin.style.display = done ? "none" : "inline-block";
    css(spin, { transform: `rotate(${(t * 360).toFixed(0)}deg)` });
    status.querySelector(".src-st").textContent = done ? S.status : "Updating…";
    status.classList.toggle("ok", done);
    css(srcPanel.querySelector(".src-new"), { opacity: ease.enter(prog(t, 1.85, 0.4)).toFixed(3) });
    // B
    const b = inB ? ease.enter(prog(t, M.b, 0.4)) : 0;
    css(share, { transform: `translateY(${((1 - b) * 10).toFixed(1)}px)` }); show(share, b);
    const replaced = t >= 5.0;
    opts.forEach((o, i) => o.classList.toggle("on", replaced ? i === 1 : i === 0));
    val.textContent = replaced ? "[email]" : SH.finding;
    val.classList.toggle("replaced", replaced);
    // C
    aw.set({ opacity: inC ? ease.enter(prog(t, M.c, 0.35)) : 0 });
    css(ai.tool, { opacity: ease.enter(prog(t, M.c + 0.7, 0.35)).toFixed(3) });
    ai.answer.textContent = answer.slice(0, typed(t, M.c + 1.1, answer, { cps: 150 }));
    stage.dim(inC ? 0 : 1, 0, 6);
    css(stage.veil, { background: "#F4F0EA", opacity: inC ? "0" : "0.55" });

    const cam = keys(t, [
      [0, { x: 960, y: 520, s: 1.42 }],
      [M.b - 0.01, { x: 960, y: 515, s: 1.45 }],
      [M.b, { x: 960, y: 500, s: 1.42 }],
      [M.c - 0.01, { x: 960, y: 495, s: 1.45 }],
      [M.c, { x: 960, y: 500, s: 1.3 }],
      [12, { x: 960, y: 495, s: 1.34 }],
    ]);
    stage.camera(cam, t, 0.5);
    stage.cursor(cursorAt(t, cur), { visible: inA ? 0 : 1 });
  };
}
