// Beat 4: three captures, each with the capture flight; they land in the pack "Aurora — Backend";
// the wheel equips it.
import { h, css, px, show, packOrb } from "../src/stage.js";
import { ease, prog, keys, life, cursorAt, lerp, clamp, arc, D } from "../src/motion.js";
import { browser, docsPage, previewPDF } from "../src/apps.js";
import { toastCard, wheel } from "../src/ui.js";
import { makeFlight, keyHint, selectionBox, rectOf, surface } from "./_kit.js";
import { circleFX, unionRect } from "./_circle.js";

export function libraryWindow(story, files) {
  const P = story.pack;
  const side = h("div", { class: "lib-side" }, h("div", { class: "lib-sh" }, "Packs"),
    ...[P, ...story.otherPacks].map((p, i) => h("div", { class: "lib-pk" + (i === 0 ? " on" : "") }, packOrb(p, 24), h("span", {}, p.name))));
  const card = (kind, title, body, source) => h("div", { class: "lib-card" }, h("div", { class: "lc-kind" }, kind), body, h("div", { class: "lc-title" }, title), h("div", { class: "lc-src" }, source));
  const cards = [
    card("Screenshot", "Error: connect ECONNREFUSED 127.0.0.1:5432", h("div", { class: "lc-shot" }, "Error: connect ECONNREFUSED 127.0.0.1:5432"), "Terminal · 10:44"),
    card("Text", "“ECONNREFUSED means nothing is listening at that host and port.”", null, story.captures[0].source),
    card("Screenshot", "Architecture diagram", h("div", { class: "lc-arch" }, h("i"), h("i"), h("i")), story.captures[1].source),
    card("Link", "node-postgres: Connecting", null, story.captures[2].source),
  ];
  const head = h("div", { class: "lib-head" }, packOrb(P, 44), h("div", {}, h("div", { class: "lib-name" }, P.name), h("div", { class: "lib-meta" }, "4 captures · Auto-sorted")));
  const grid = h("div", { class: "lib-grid" }, ...cards);
  const el = h("div", { class: "library" }, side, h("div", { class: "lib-main" }, head, grid));
  return { el, cards, head };
}

export default async function (ctx) {
  const { stage, story, files, marks: M } = ctx;
  const P = story.pack;
  stage.menubar.app.textContent = "Browser";
  const paras = files.docs.split("\n").slice(2).filter(Boolean);
  const docs = docsPage({ title: "Connecting to PostgreSQL", paras: [...paras.slice(0, 2), paras.slice(2).join(" ")] });
  const related = h("p", { class: "doc-link" }, "Related: ", h("u", {}, "node-postgres: Connecting"));
  docs.el.append(related);
  const bw = stage.addWindow({ title: "Browser", x: 100, y: 92, w: 980, h: 640, body: browser({ tabs: ["Aurora wiki", "node-postgres"], url: "wiki.aurora-team.example/backend/postgres", page: docs.el }).el, z: 2 });
  const pdf = previewPDF();
  const pw = stage.addWindow({ title: "aurora-architecture.pdf — Preview", x: 1130, y: 150, w: 690, h: 720, body: pdf.el, z: 1 });

  const r1 = unionRect(stage, [docs.ps[1]], 0);
  const linkRect = unionRect(stage, [related.querySelector("u")], 0);
  const archRect = unionRect(stage, [pdf.page.querySelector(".arch")], 4);
  const sel1 = selectionBox(stage, P.color);
  const sel3 = selectionBox(stage, P.color);
  const circ = circleFX(stage, archRect, { seed: 11 });
  const f1 = makeFlight(stage, P, "ECONNREFUSED means nothing is listening…");
  const f2 = makeFlight(stage, P, "Architecture diagram", h("div", { class: "mini-arch" }));
  const f3 = makeFlight(stage, P, "node-postgres: Connecting");
  const k1 = keyHint(stage, ["⌥", "C"], "scoop"), k2 = keyHint(stage, ["⌘", "⌘"], "circle"), k3 = keyHint(stage, ["⌥", "C"], "scoop");
  const k4 = keyHint(stage, ["⌥", "S"], "hold for the wheel");

  // library: the captures land in the pack
  const lib = libraryWindow(story, files);
  const lw = stage.addWindow({ title: `${P.name} — Shapr`, x: 300, y: 120, w: 1320, h: 780, body: lib.el, z: 9 });
  stage.shapr.append(lw.el); // a Shapr window: sits above the dimmed desktop
  const cardRects = lib.cards.map((c) => rectOf(c, stage));

  // wheel
  const slots = [{ name: P.name, color: P.color }, ...story.otherPacks.map((p) => ({ name: p.name, color: p.color })), null];
  const wh = wheel({ slots, equipped: -1 });
  stage.shapr.append(wh.el);
  const wc = { x: 960, y: 560 };
  css(wh.el, { left: px(wc.x - wh.R), top: px(wc.y - wh.R) });
  const eq = toastCard({ title: `Equipped ${P.name}`, meta: "Every capture goes here until you switch back to Auto.", pack: P });
  stage.shapr.append(eq.el);
  const eqX = 1920 - 24 - 442, eqY = 52;

  const cur = [
    { t: 0, x: r1.x - 30, y: r1.y + 60 },
    { t: 0.45, x: r1.x - 2, y: r1.y + 8 },
    { t: 0.95, x: r1.x + r1.w, y: r1.y + r1.h - 8, bend: 0.02 },
    { t: 2.75, x: archRect.x - 20, y: archRect.y - 30 },
    { t: 4.6, x: archRect.x + archRect.w * 0.6, y: archRect.y + archRect.h + 50 },
    { t: 5.1, x: linkRect.x - 2, y: linkRect.y + 8 },
    { t: 5.45, x: linkRect.x + linkRect.w, y: linkRect.y + linkRect.h - 6, bend: 0.02 },
    { t: 10.6, x: 940, y: 600 },
    { t: 11.2, x: 960, y: 560 },
    { t: 12.5, x: 965, y: 410 },
    { t: 14, x: 975, y: 420 },
  ];

  return (t, tl) => {
    // capture 1: text selection + ⌥C
    sel1.update(r1, life(t, M.c1, M.c1 + 1.0, 0.15, 0.3), ease.move(prog(t, M.c1, 0.5)));
    f1.update(t, M.c1 + 0.7, { x: r1.x + r1.w * 0.4, y: r1.y + r1.h / 2 });
    // capture 2: a quick circle around the diagram
    circ.update(t, { trigger: M.c2, d0: M.c2 + 0.15, d1: M.c2 + 0.9, out: M.c2 + 1.15 });
    f2.update(t, M.c2 + 1.1, { x: archRect.x + archRect.w / 2, y: archRect.y + archRect.h / 2 });
    // capture 3: the link
    sel3.update(linkRect, life(t, M.c3, M.c3 + 0.9, 0.15, 0.3), ease.move(prog(t, M.c3, 0.35)));
    f3.update(t, M.c3 + 0.7, { x: linkRect.x + linkRect.w / 2, y: linkRect.y + linkRect.h / 2 });
    for (const at of [M.c1 + 1.4, M.c2 + 1.8, M.c3 + 1.4]) if (t >= at && t < at + 1) stage.menubarPulse(t, at);

    // the pack: captures arc down from the menu-bar icon into their cards
    const la = life(t, M.converge, M.wheel - 0.3, 0.42, 0.3);
    lw.set({ opacity: la, scale: lerp(0.97, 1, ease.enter(prog(t, M.converge, 0.42))) });
    const ic = stage.menubar.center();
    lib.cards.forEach((c, i) => {
      const t0 = M.converge + 0.35 + i * 0.22;
      const k = ease.move(prog(t, t0, 0.6));
      const r = cardRects[i];
      const p = arc(k, { x: ic.x - (r.x + r.w / 2), y: ic.y - (r.y + r.h / 2) }, { x: 0, y: 0 }, 0.12);
      css(c, { transform: `translate(${(p.x * (1 - k) * 0 + (1 - k) * (ic.x - r.x - r.w / 2)).toFixed(1)}px, ${((1 - k) * (ic.y - r.y - r.h / 2)).toFixed(1)}px) scale(${lerp(0.3, 1, k).toFixed(3)})`, opacity: ease.enter(prog(t, t0, 0.25)).toFixed(3) });
    });
    stage.dim(la, 0.0, 0);
    css(stage.veil, { background: "#F4F0EA", opacity: (0.5 * Math.max(la, life(t, M.wheel, M.pick + 0.3, 0.3, 0.3))).toFixed(3) });

    // wheel: hold ⌥S, point at the pack, let go
    const wa = life(t, M.wheel, M.pick, 0.2, 0.18);
    const wk = ease.enter(prog(t, M.wheel, 0.2));
    css(wh.el, { transform: `scale(${lerp(0.97, 1, wk).toFixed(4)})` });
    show(wh.el, wa);
    const pointing = ease.move(prog(t, 11.9, 0.35));
    wh.point(-90, pointing);
    wh.setMiddle(pointing > 0.5 ? P.name : "Auto-sort", pointing > 0.5 ? "4 captures" : "Let go to cancel");
    wh.places.forEach((pl, i) => css(pl.querySelector(".wh-name"), { color: i === 0 && pointing > 0.5 ? "var(--ink)" : "" }));
    surface(eq.el, t, M.pick + 0.15, 99, eqX, eqY);
    if (t >= M.pick + 0.1) stage.menubar.setWord("Aurora"); else stage.menubar.setWord("");

    k1.update(t, M.c1 + 0.45, M.c1 + 1.3, 960, 900);
    k2.update(t, M.c2 - 0.1, M.c2 + 0.9, 960, 900);
    k3.update(t, M.c3 + 0.4, M.c3 + 1.2, 960, 900);
    k4.update(t, M.wheel - 0.2, M.pick, 960, 900);

    const cam = keys(t, [
      [0, { x: 640, y: 380, s: 1.45 }],
      [2.2, { x: 640, y: 380, s: 1.45 }],
      [3.0, { x: 1400, y: 470, s: 1.45 }],
      [4.6, { x: 1400, y: 470, s: 1.45 }],
      [5.3, { x: 640, y: 560, s: 1.45 }],
      [M.converge, { x: 640, y: 560, s: 1.45 }],
      [M.converge + 0.9, { x: 960, y: 520, s: 1.22 }],
      [M.wheel - 0.2, { x: 960, y: 520, s: 1.22 }],
      [M.wheel + 0.5, { x: 960, y: 560, s: 1.75 }],
      [M.pick + 0.4, { x: 960, y: 560, s: 1.75 }],
      [M.pick + 1.2, { x: 1300, y: 330, s: 1.5 }],
    ]);
    stage.camera(cam, t, 1);
    stage.cursor(cursorAt(t, cur));
  };
}
