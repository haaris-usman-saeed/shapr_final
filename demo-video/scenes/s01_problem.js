// Beat 1: the problem. Windows pile up on the beat, tabs multiply, the same explanation is typed twice.
import { h, css, px, show } from "../src/stage.js";
import { ease, prog, keys, tw, typed, deleted, caretOn, cursorAt, clamp, lerp } from "../src/motion.js";
import { browser, docsPage, previewPDF, chatPage, codeEditor, terminal } from "../src/apps.js";
import { winIn } from "./_kit.js";

export default async function (ctx) {
  const { stage, story, files, marks: M } = ctx;
  stage.menubar.app.textContent = "Browser";
  css(stage.menubar.icon, { opacity: "0" }); // Shapr hasn't been introduced yet

  const docs = docsPage({ title: "Connecting to PostgreSQL", paras: files.docs.split("\n").slice(2).filter(Boolean) });
  const b1 = browser({ tabs: ["Aurora wiki", "pg docs"], url: "wiki.aurora-team.example/backend/postgres", page: docs.el });
  const w1 = stage.addWindow({ title: "Browser", x: 110, y: 96, w: 900, h: 600, body: b1.el });

  const results = h("div", { class: "doc" }, h("div", { class: "doc-crumbs" }, "Search"), h("h1", {}, "econnrefused 127.0.0.1:5432 node"),
    ...["Postgres refuses connection on localhost — forum thread", "node-postgres: Connecting", "Docker networking: localhost inside a container", "ECONNREFUSED after restart?"].map((t) => h("p", {}, t)));
  const tabNames = ["Search", "node-postgres", "Forum thread", "Docker docs", "Stack thread", "pg Pool", "Env vars", "Compose", "Forum", "Issue #212", "Blog", "Answer", "Docs", "Thread", "pg", "Issue", "Search", "Docs", "Video", "Forum", "Docs", "Answer", "Search", "Docs", "pg", "Thread", "Docs", "Issue"];
  const b2 = browser({ tabs: tabNames.slice(0, 2), url: "search.example/?q=econnrefused+127.0.0.1%3A5432", page: results });
  const w2 = stage.addWindow({ title: "Browser", x: 760, y: 140, w: 940, h: 560, body: b2.el });

  const pdf = previewPDF();
  const w3 = stage.addWindow({ title: "aurora-architecture.pdf — Preview", x: 1210, y: 300, w: 600, h: 620, body: pdf.el });

  const chat1 = chatPage({ service: "AI Chat", turns: [["U", "Why would node-postgres say ECONNREFUSED?"], ["A", "It usually means nothing is listening on that host and port…"]] });
  const w4 = stage.addWindow({ title: "AI Chat — Browser", x: 230, y: 360, w: 780, h: 600, body: chat1.el });

  const ed = codeEditor({ files });
  const w5 = stage.addWindow({ title: "db.js — aurora-api — Code", x: 640, y: 430, w: 1000, h: 540, body: ed.el });

  const tm = terminal({ log: files.terminal });
  const w6 = stage.addWindow({ title: "Terminal — aurora-api", x: 1100, y: 640, w: 760, h: 380, dark: true, body: tm.el });

  const chat2 = chatPage({ service: "Another AI", turns: [["A", "Hi! How can I help today?"]] });
  const w7 = stage.addWindow({ title: "Another AI — Browser", x: 960, y: 180, w: 800, h: 560, body: chat2.el });

  const wins = [w1, w2, w3, w4, w5, w6];
  const at = [M.win1, M.win2, M.win3, M.win4, M.win5, M.win6];
  const typedText = story.chatTyped;

  // tab cadence: accelerating, from tabsFrom to tabsTo
  const tabTimes = [];
  { let tt = M.tabsFrom, gap = 0.36; for (let i = 2; i < tabNames.length; i++) { tabTimes.push(tt); tt += gap; gap = Math.max(0.045, gap * 0.82); } }
  let lastTabs = -1;

  const cur = [
    { t: 0, x: 1500, y: 860 },
    { t: 3.9, x: 1280, y: 162 },
    { t: 6.3, x: 1290, y: 166 },
    { t: 6.55, x: 470, y: 905, click: true },
    { t: 9.15, x: 470, y: 905 },
    { t: 9.45, x: 1220, y: 690, click: true },
    { t: 12, x: 1230, y: 700 },
  ];

  return (t) => {
    // windows pile up
    wins.forEach((w, i) => {
      const z = i + 1;
      winIn(w, t, at[i], { z: t >= M.tabsFrom && i === 1 && t < M.type1 ? 20 : t >= M.type1 - 0.2 && i === 3 ? 21 : z });
      // older windows recede a little so the newest is the focus
      const newer = at.filter((a) => a <= t).length - 1;
      w.fade(i < newer && t < M.tabsFrom ? 0.55 : (t >= M.tabsFrom && !(i === 1 && t < M.type1) && !(i === 3 && t >= M.type1 - 0.2 && t < M.type2 - 0.3) ? 0.75 : 0), 0.55);
    });
    winIn(w7, t, M.type2 - 0.45, { z: 30 });
    w7.fade(0);

    // tabs multiply until they're comically narrow
    const n = 2 + tabTimes.filter((x) => x <= t).length;
    if (n !== lastTabs) { b2.setTabs(tabNames.slice(0, n), n - 1); lastTabs = n; }

    // typing, deleting, retyping
    const c1 = t < M.del1 ? typed(t, M.type1, typedText, { cps: 17, seed: 4 }) : typedText.length - deleted(t, M.del1, typedText.length, 48);
    chat1.text.innerHTML = typedText.slice(0, Math.max(0, c1)) + (t >= M.type1 - 0.3 && t < M.type2 - 0.4 && caretOn(t, M.type1 + 1.8) ? '<span class="caret"></span>' : "");
    const c2 = typed(t, M.type2, typedText, { cps: 17, seed: 9 });
    chat2.text.innerHTML = typedText.slice(0, c2) + (t >= M.type2 - 0.2 && caretOn(t, M.type2 + 1.9) ? '<span class="caret"></span>' : "");

    // camera: whole desk, push to the tab strip, then to each chat box, then hold
    const cam = keys(t, [
      [0, { x: 960, y: 560, s: 1.0 }],
      [3.6, { x: 960, y: 560, s: 1.0 }],
      [4.6, { x: 1240, y: 330, s: 1.45 }],
      [6.45, { x: 1240, y: 330, s: 1.45 }],
      [7.35, { x: 620, y: 820, s: 1.55 }],
      [9.05, { x: 620, y: 820, s: 1.55 }],
      [9.85, { x: 1360, y: 610, s: 1.5 }],
      [11.3, { x: 1360, y: 610, s: 1.5 }],
      [13, { x: 1200, y: 600, s: 1.25 }],
    ]);
    stage.camera(cam, t, t > M.freeze ? 1 : 0.4);
    stage.menubar.app.textContent = t < M.type1 ? (t < M.win5 ? "Browser" : t < M.win6 ? "Code" : t < M.tabsFrom ? "Terminal" : "Browser") : "Browser";
    const p = cursorAt(t, cur);
    stage.cursor(p);
  };
}
