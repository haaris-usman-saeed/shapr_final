// Feature tour: one scene module, several variants (entry.variant), each a single Shapr surface shown
// in situation. Labels come from the Swift views named in each variant's comment.
import { h, s, css, px, show, packOrb, keycap, lockSVG, tickSVG } from "../src/stage.js";
import { ease, prog, keys, life, cursorAt, lerp, typed, arc } from "../src/motion.js";
import { codeEditor, browser, docsPage, formPage } from "../src/apps.js";
import { toastCard, panel, icon, sessionPanel, voicePill } from "../src/ui.js";
import { devWindows, rectOf, surface, makeFlight, keyHint, selectionBox } from "./_kit.js";
import { unionRect } from "./_circle.js";
import { libraryWindow } from "./s04_packs.js";

const TX = 1920 - 24 - 442, TY = 52; // corner cards

export default async function (ctx) {
  const { stage, story, files, entry } = ctx;
  const P = story.pack, v = entry.variant;
  stage.menubar.setWord("Aurora");
  const B = { cam: [[0, { x: 960, y: 540, s: 1.2 }]], cur: [{ t: 0, x: 1200, y: 760 }], tick: () => {}, veil: 0 };

  if (v === "files") {
    // FileSuggestions.showPrompt + AppController.file (duplicate)
    stage.menubar.app.textContent = "Code";
    const ed = codeEditor({ files });
    const ew = stage.addWindow({ title: "docker-compose.yml — aurora-api — Code", x: 110, y: 110, w: 1080, h: 640, body: ed.el });
    ed.codeEl.innerHTML = ["services:", "  api:", "    build: .", "    env_file: .env", "    ports: [\"8080:8080\"]", "  db:", "    image: postgres:16", "    ports: [\"5432:5432\"]"].map((l, i) => `<span class="line"><span class="ln">${i + 1}</span>${l}</span>`).join("");
    const sug = toastCard({ title: "docker-compose.yml", meta: `Add to ${P.name} · You opened it in Code · “Not here” stops asking about aurora-api`, pack: P, actions: [{ label: "Add", primary: true }, { label: "Other" }, { label: "Not here" }] });
    const dup = toastCard({ title: "ECONNREFUSED means nothing is listening at that host and port.", meta: `${P.name} · You saved this 20 minutes ago, so it wasn't added again.`, pack: P, actions: [{ label: "Show" }, { label: "Add anyway" }] });
    stage.shapr.append(sug.el, dup.el);
    css(sug.el, { left: px(TX), top: px(TY) });
    const add = rectOf(sug.btns[0], stage);
    const fl = makeFlight(stage, P, "docker-compose.yml");
    B.cur = [{ t: 0, x: 900, y: 700 }, { t: 3.6, x: add.x + add.w / 2, y: add.y + add.h / 2, click: true, clickDelay: 0.4 }, { t: 6, x: 1300, y: 600 }];
    B.cam = [[0, { x: 1300, y: 400, s: 1.35 }], [8.0, { x: 1300, y: 400, s: 1.35 }]];
    B.tick = (t) => {
      surface(sug.el, t, 1.0, 4.15); fl.update(t, 4.1, { x: add.x, y: add.y });
      if (t > 4.8) stage.menubarPulse(t, 4.8);
      surface(dup.el, t, 8.2, 99, TX, TY);
    };
  }

  if (v === "map") {
    // GraphView: a dot per capture, a ring per shared topic, lines between them
    const W = 1320, H = 780;
    const nodes = [["Error screenshot", 330, 330], ["Connection docs", 520, 230], [".env", 600, 450], ["db.js", 420, 520], ["Architecture diagram", 860, 300], ["node-postgres link", 700, 140], ["docker-compose.yml", 820, 560], ["Checkpoint · Oct 28", 1040, 420]];
    const rings = [["postgres", 470, 330, 210], ["config", 700, 500, 190], ["architecture", 930, 370, 170]];
    const edges = [[0, 1], [0, 2], [1, 2], [2, 3], [1, 5], [4, 6], [2, 6], [7, 0], [7, 2], [4, 7]];
    const svg = s("svg", { width: W, height: H - 120, viewBox: `0 0 ${W} ${H - 120}` });
    const ringEls = rings.map(([n, x, y, r]) => { const g = s("g", {}, s("circle", { cx: x, cy: y, r, fill: "rgba(25,127,147,0.05)", stroke: "rgba(25,127,147,0.35)", "stroke-width": 1.5, "stroke-dasharray": "5 6" })); const tx = s("text", { x, y: y - r - 10, "text-anchor": "middle", "font-size": 18, fill: "#5A5852", "font-family": "Inter", "font-weight": 600 }); tx.textContent = n; g.append(tx); svg.append(g); return g; });
    const edgeEls = edges.map(([a, b]) => { const l = s("line", { x1: nodes[a][1], y1: nodes[a][2], x2: nodes[b][1], y2: nodes[b][2], stroke: "rgba(31,30,28,0.22)", "stroke-width": 1.5 }); svg.append(l); return l; });
    const nodeEls = nodes.map(([n, x, y]) => { const g = s("g", {}, s("circle", { cx: x, cy: y, r: 11, fill: P.color })); const tx = s("text", { x: x + 18, y: y + 6, "font-size": 19, fill: "#1F1E1C", "font-family": "Inter", "font-weight": 550 }); tx.textContent = n; g.append(tx); svg.append(g); return g; });
    const body = h("div", { class: "map" }, h("div", { class: "lib-head" }, packOrb(P, 44), h("div", {}, h("div", { class: "lib-name" }, P.name), h("div", { class: "lib-meta" }, "Map · worked out on this Mac from the words in the captures"))), svg);
    const w = stage.addWindow({ title: `${P.name} — Shapr`, x: 300, y: 130, w: W, h: H, body });
    B.cam = [[0, { x: 960, y: 520, s: 1.12 }], [12, { x: 960, y: 520, s: 1.2 }]];
    B.cur = [{ t: 0, x: 1400, y: 900 }, { t: 5.5, x: 300 + 600 + 10, y: 130 + 44 + 120 + 450 + 6 }, { t: 12, x: 300 + 600 + 14, y: 130 + 44 + 120 + 450 + 10 }];
    B.tick = (t) => {
      ringEls.forEach((g, i) => g.setAttribute("opacity", ease.enter(prog(t, 0.6 + i * 0.2, 0.6)).toFixed(3)));
      nodeEls.forEach((g, i) => g.setAttribute("opacity", ease.enter(prog(t, 0.3 + i * 0.12, 0.4)).toFixed(3)));
      const hov = t > 6.0 ? 1 : 0; // hovering .env lights what it's joined to
      edgeEls.forEach((l, i) => { const on = edges[i].includes(2); l.setAttribute("opacity", (ease.enter(prog(t, 1.4 + i * 0.06, 0.5)) * (hov && !on ? 0.3 : 1)).toFixed(3)); l.setAttribute("stroke", hov && on ? P.color : "rgba(31,30,28,0.22)"); l.setAttribute("stroke-width", hov && on ? 3 : 1.5); });
      nodeEls.forEach((g, i) => { if (hov) g.setAttribute("opacity", edges.some((e) => e.includes(2) && e.includes(i)) || i === 2 ? "1" : "0.35"); });
    };
  }

  if (v === "ask") {
    // AskPanel: one big question field with the pack in it; the answer; the notes it came from
    devWindows(stage, files, { editor: { x: 110, y: 92, w: 1040, h: 560 }, term: { x: 760, y: 470, w: 1060, h: 450 } }).tmw.set({ opacity: 0 });
    const shot = !!entry.shot;
    const q = shot ? "What does this error mean?" : "What have I already tried?";
    const field = h("div", { class: "ask-field" }, shot ? h("span", { class: "chip plain shot-chip" }, h("i", { class: "mini-shot" }), "Screenshot") : null, h("span", { class: "chip" }, packOrb(P, 22), P.name), h("span", { class: "ask-q" }), h("span", { class: "ask-caret" }));
    const ans = h("div", { class: "ask-ans" });
    const answer = shot ? "Nothing is accepting connections at 127.0.0.1 on port 5432 [1]. Your docs say to check that Postgres is running, and that DB_HOST and DB_PORT point to where it actually runs [2]." : "You checked the credentials [1], restarted the service [2] and read the connection docs [3]. The error is still ECONNREFUSED on 127.0.0.1:5432; your saved next step is to verify DB_HOST and DB_PORT in .env [1].";
    const notes = shot ? [["1", "Screenshot · Terminal", "Error: connect ECONNREFUSED 127.0.0.1:5432"], ["2", "wiki.aurora-team.example", "Check that Postgres is running, and that DB_HOST…"]] : [["1", "Checkpoint · Aurora — Backend", "Already tried: credentials, restart"], ["2", "Terminal screenshot", "Error: connect ECONNREFUSED 127.0.0.1:5432"], ["3", "wiki.aurora-team.example", "ECONNREFUSED means nothing is listening…"]];
    const list = h("div", { class: "ask-notes" }, h("div", { class: "section-label" }, "From your notes"), ...notes.map(([n, a, b]) => h("div", { class: "ask-note" }, h("span", { class: "an-n" }, n), h("div", {}, h("b", {}, a), h("span", {}, b)))));
    const p = panel({ title: "Ask", sub: null, iconName: "sparkle", width: 860, body: h("div", {}, field, ans, list), foot: [{ label: "Copy", keys: "⇧⌘C" }, { label: "Ask", keys: "↩", primary: true }], status: "" });
    p.el.querySelector(".p-head").remove();
    stage.shapr.append(p.el);
    const X = 530, Y = 170;
    B.cam = [[0, { x: 960, y: 470, s: 1.2 }]];
    B.cur = [{ t: 0, x: 1500, y: 900 }];
    B.veil = 0.5;
    B.tick = (t) => {
      surface(p.el, t, 0.5, 99, X, Y);
      field.querySelector(".ask-q").textContent = q.slice(0, typed(t, 1.1, q, { cps: 16 }));
      css(field.querySelector(".ask-caret"), { opacity: t < 3.6 && Math.floor(t / 0.53) % 2 === 0 ? "1" : "0" });
      p.status.textContent = t < 3.6 ? `Answers from ${P.name}, on this Mac` : t < 4.4 ? `Looking through ${P.name}…` : t < 5.0 ? "Writing the answer…" : shot ? "On-device model · screenshot + 2 notes" : "On-device model · 3 notes";
      ans.innerHTML = answer.slice(0, typed(t, 5.0, answer, { cps: 60 })).replace(/\[(\d)\]/g, '<span class="cite">$1</span>');
      css(list, { opacity: ease.enter(prog(t, 8.3, 0.5)).toFixed(3) });
    };
  }

  if (v === "use") {
    // UsePanel: what you're looking at, the parts of the pack Shapr picked (untick any), a ready brief
    devWindows(stage, files, { editor: { x: 110, y: 92, w: 1040, h: 560 }, term: { x: 760, y: 470, w: 1060, h: 450 } }).tmw.set({ opacity: 0 });
    const pick = [["connection-docs.md", "ECONNREFUSED means nothing is listening at that host and port.", true], [".env", "DB_HOST=127.0.0.1 · DB_PORT=5432", true], ["Architecture diagram", "Front end → Backend API → PostgreSQL", true]];
    const rows = pick.map(([a, b], i) => h("div", { class: "use-row" }, h("span", { class: "fp-tick" }, "✓"), h("span", { class: "an-n" }, String(i + 1)), h("div", {}, h("b", {}, a), h("span", {}, b))));
    const body = h("div", {}, h("div", { class: "section-label" }, "What you're looking at"), h("div", { class: "use-look" }, "Error: connect ECONNREFUSED 127.0.0.1:5432"),
      h("div", { class: "section-label" }, "From your pack"), ...rows,
      h("div", { class: "use-tabs" }, h("span", { class: "seg on" }, "For your AI"), h("span", { class: "seg" }, "Shapr's answer")),
      h("div", { class: "use-brief" }, "Everything the AI needs, ready to paste: what you're looking at, the parts of your pack that matter, and your saved progress. No API key needed."));
    const p = panel({ title: `Use ${P.name} with this`, sub: "Debugging brief", iconName: "sparkle", width: 780, body, foot: [{ label: "Cancel", keys: "esc" }, { label: "Copy", keys: "⇧⌘C" }, { label: "Insert", keys: "⌘↩", primary: true }] });
    stage.shapr.append(p.el); css(p.el, { left: "570px", top: "70px" });
    const r3 = rectOf(rows[2].querySelector(".fp-tick"), stage);
    const k = keyHint(stage, ["⌥", "⇧", "U"], "use with my pack");
    B.cam = [[0, { x: 960, y: 500, s: 1.15 }]];
    B.cur = [{ t: 0, x: 1500, y: 900 }, { t: 5.4, x: r3.x + r3.w / 2, y: r3.y + r3.h / 2, click: true, clickDelay: 0.4 }, { t: 12, x: r3.x + 200, y: r3.y + 260 }];
    B.veil = 0.5;
    B.tick = (t) => {
      surface(p.el, t, 0.5, 99, 570, 70); k.update(t, 0.1, 1.2, 960, 900);
      rows.forEach((r, i) => css(r, { opacity: (ease.enter(prog(t, 1.2 + i * 0.25, 0.35)) * (i === 2 && t > 5.9 ? 0.45 : 1)).toFixed(3) }));
      rows[2].querySelector(".fp-tick").classList.toggle("off", t > 5.9);
      rows[2].querySelector(".fp-tick").textContent = t > 5.9 ? "" : "✓";
    };
  }

  if (v === "style") {
    // Drop: facts from one pack, voice from a style pack; Routing says which pack it picked and why
    stage.menubar.app.textContent = "Mail";
    const why = h("div", { class: "route" }, packOrb(P, 26), h("span", {}, "Picked ", h("b", {}, P.name), " because the email is from someone at aurora-team.example"), h("span", { class: "btn small" }, "Use Energy Research"));
    const chips = h("div", { class: "src-chips" }, h("span", { class: "chip" }, packOrb(P, 22), "Facts: " + P.name), h("span", { class: "chip" }, h("span", { class: "style-orb" }, "MW"), "Style: My emails"));
    const txt = h("div", { class: "draft-text", style: { minHeight: "220px" } });
    const draftText = story.email.draft.join("\n\n");
    const p = panel({ title: "Draft for Mail", sub: `Reply to ${story.email.from}`, iconName: "pencil", width: 760, body: h("div", {}, why, chips, txt), foot: [{ label: "Cancel", keys: "esc" }, { label: "Insert", keys: "⌘↩", primary: true }], status: "Facts only from Aurora — Backend; your voice from My emails" });
    stage.shapr.append(p.el);
    const mail = h("div", { class: "doc" }, h("h1", {}, story.email.subject), h("p", {}, story.email.body));
    stage.addWindow({ title: "Mail", x: 90, y: 90, w: 1000, h: 820, body: mail });
    B.cam = [[0, { x: 1100, y: 470, s: 1.2 }]];
    B.veil = 0.4;
    B.tick = (t) => { surface(p.el, t, 0.5, 99, 980, 120); css(why, { opacity: ease.enter(prog(t, 0.9, 0.4)).toFixed(3) }); css(chips, { opacity: ease.enter(prog(t, 1.4, 0.4)).toFixed(3) }); txt.textContent = draftText.slice(0, typed(t, 2.2, draftText, { cps: 90 })); };
  }

  if (v === "say") {
    // VoiceNotes pill + AppController .help toast ("Hold ⌥V and say things like")
    devWindows(stage, files, { editor: { x: 110, y: 92, w: 1040, h: 560 }, term: { x: 760, y: 470, w: 1060, h: 450 } }).tmw.set({ opacity: 0 });
    const vp = voicePill(); stage.shapr.append(vp.el);
    const ex = ["“Add this”", "“What does this mean?”", "“Draft a reply saying I'll send it Friday”", "“Fill this form”", "“Switch to Aurora — Backend, then add this”", "“Continue in Claude”", "“Show me the map of Aurora — Backend”", "“Undo that”"];
    const help = h("div", { class: "toast glass say-help" }, h("div", { class: "t-row" }, h("div", { class: "branch-orb" }, icon("sparkle", 20)), h("div", {}, h("div", { class: "t-title" }, "Hold ⌥V and say things like"))), h("div", { class: "say-list" }, ...ex.map((e) => h("div", { class: "say-ex" }, e))), h("div", { class: "t-meta" }, "…or ask anything, or just talk to save a note."));
    stage.shapr.append(help);
    const k = keyHint(stage, ["⌥", "V"], "hold and talk");
    B.cam = [[0, { x: 1150, y: 420, s: 1.35 }]];
    B.cur = [{ t: 0, x: 900, y: 520 }, { t: 12, x: 910, y: 525 }];
    B.veil = 0.45;
    B.tick = (t) => {
      const words = "What can I say".split(" ");
      show(vp.el, life(t, 0.6, 2.9, 0.22, 0.2)); css(vp.el, { left: "944px", top: "540px" });
      const n = words.filter((_, i) => t >= 1.0 + i * 0.3).length;
      vp.words.textContent = n ? words.slice(0, n).join(" ") : "Listening…";
      css(vp.halo, { transform: `scale(${(1 + 0.3 * Math.abs(Math.sin(t * 11))).toFixed(3)})` });
      surface(help, t, 3.1, 99, 1040, 120);
      help.querySelectorAll(".say-ex").forEach((e, i) => css(e, { opacity: ease.enter(prog(t, 3.4 + i * 0.12, 0.35)).toFixed(3) }));
      k.update(t, 0.4, 2.9, 960, 900);
    };
  }

  if (v === "vault") {
    // FormFill: "From your Vault", masked, Touch ID at fill; consent boxes never ticked
    const form = { title: "Campus Computing Portal", subtitle: "Register your project server", fields: [{ label: "Project title", value: "Aurora" }, { label: "Team name", value: "Team Aurora" }, { label: "Portal password", value: "" }] };
    const fp = formPage({ form });
    const agree = h("div", { class: "ff-agree" }, h("span", { class: "box" }), "I agree to the computing policy");
    fp.el.insertBefore(agree, fp.submit);
    const fw = stage.addWindow({ title: "Browser", x: 90, y: 80, w: 1100, h: 860, body: browser({ tabs: [form.title], url: "portal.campus.example/register", page: fp.el }).el });
    const rows = [["Project title", "Aurora"], ["Team name", "Team Aurora"]].map(([a, b]) => h("div", { class: "ff-prop" }, h("div", { class: "fp-l" }, h("span", { class: "fp-tick" }, "✓"), a), h("div", { class: "fp-v" }, b)));
    const vault = h("div", { class: "ff-prop" }, h("div", { class: "fp-l" }, h("span", { class: "fp-tick" }, "✓"), "Portal password"), h("div", { class: "fp-v" }, "••••••••"));
    const consent = h("div", { class: "ff-prop" }, h("div", { class: "fp-l" }, h("span", { class: "fp-tick off" }, ""), "I agree to the computing policy"), h("div", { class: "fp-v dim" }, "Left for you: Shapr never ticks consent boxes"));
    const fpn = panel({ title: "Fill form in Browser", sub: `From ${P.name} and Vault`, iconName: "form", width: 680, body: h("div", {}, h("div", { class: "section-label" }, "From your packs"), ...rows, h("div", { class: "section-label vault-l" }, lockSVG(15), " From your Vault ", h("span", { class: "vault-sub" }, "Unlocks with Touch ID when you fill")), vault, consent), foot: [{ label: "Cancel", keys: "esc" }, { label: "Fill", keys: "⌘↩", primary: true }], status: "Shapr never presses Submit" });
    stage.shapr.append(fpn.el);
    B.cam = [[0, { x: 1180, y: 470, s: 1.3 }]];
    B.cur = [{ t: 0, x: 900, y: 760 }];
    B.tick = (t) => { surface(fpn.el, t, 0.5, 99, 1200, 150); [...rows, vault, consent].forEach((r, i) => css(r, { opacity: ease.enter(prog(t, 0.9 + i * 0.25, 0.35)).toFixed(3) })); stage.dim(life(t, 0.5, 99, 0.4), 0.12, 0); };
  }

  if (v === "checkpoint") {
    // CheckpointViews "Save progress"
    devWindows(stage, files, { editor: { x: 110, y: 92, w: 1040, h: 560 }, term: { x: 760, y: 470, w: 1060, h: 450 } }).tmw.set({ opacity: 0 });
    const kf = (k, val) => h("div", { class: "cp-f" }, h("div", { class: "cp-k" }, k), h("div", { class: "cp-v" }, val));
    const sec = (k, items) => h("div", { class: "cp-s" }, h("div", { class: "cp-k" }, k, h("span", { class: "cp-n" }, String(items.length))), ...items.map((x) => h("div", { class: "cp-i" }, x)));
    const body = h("div", {}, kf("Goal", story.goal), kf("Next step", story.nextStep), sec("Your rules, word for word", ["“Don't suggest switching databases.”"]), sec("Already tried", story.tried), sec("Open questions", ["Is Postgres running where .env says it is?"]));
    const p = panel({ title: "Save progress", sub: `${P.name} · drafted from the pack, edit anything`, iconName: "flag", width: 760, body, foot: [{ label: "Cancel", keys: "esc" }, { label: "Rewrite", keys: "⌘R" }, { label: "Save checkpoint", keys: "⌘↩", primary: true }] });
    stage.shapr.append(p.el);
    const k = keyHint(stage, ["⌥", "⇧", "P"], "save progress");
    const save = rectOf(p.btns[2], stage);
    css(p.el, { left: "580px", top: "80px" });
    const sv = rectOf(p.btns[2], stage);
    B.cam = [[0, { x: 960, y: 500, s: 1.15 }]];
    B.cur = [{ t: 0, x: 1500, y: 900 }, { t: 9.6, x: sv.x + sv.w / 2, y: sv.y + sv.h / 2, click: true, clickDelay: 0.4 }];
    B.veil = 0.5;
    B.tick = (t) => { surface(p.el, t, 0.5, 10.3, 580, 80); p.el.querySelectorAll(".cp-f,.cp-s").forEach((e, i) => css(e, { opacity: ease.enter(prog(t, 0.9 + i * 0.3, 0.4)).toFixed(3) })); k.update(t, 0.1, 1.2, 960, 900); };
  }

  if (v === "continue") {
    // CheckpointViews "Continue in …" with the stale warning
    stage.menubar.app.textContent = "Terminal";
    devWindows(stage, files, { editor: { x: 110, y: 92, w: 1040, h: 560 }, term: { x: 760, y: 470, w: 1060, h: 450 } }).tmw.set({ opacity: 0 });
    const stale = h("div", { class: "cp-stale" }, h("div", {}, "Since you saved this: 1 new capture · .env changed"), h("div", { class: "cp-sa" }, h("span", { class: "btn small primary" }, "Update progress first"), h("span", { class: "btn small" }, "Continue anyway")));
    const facts = h("div", { class: "rs-lines" }, ...[["Working toward", story.goal], ["Already decided", "Keep PostgreSQL"], ["Next", story.nextStep]].map(([a, b]) => h("div", { class: "rs-line" }, h("span", { class: "rs-k" }, a), h("span", { class: "rs-v" }, b))));
    const paste = h("div", { class: "cp-paste" }, h("div", { class: "section-label" }, "What will be pasted ", h("span", { class: "dim" }, "· formatted for code tools")), h("pre", {}, `Continue “Aurora — Backend”.\nGoal: ${story.goal}\nTried: credentials, restart, docs\nError: ECONNREFUSED 127.0.0.1:5432\nNext: ${story.nextStep}`));
    const p = panel({ title: "Continue in Terminal", sub: `${P.name} · v2 of 2`, iconName: "branch", width: 780, body: h("div", {}, stale, facts, paste), foot: [{ label: "Cancel", keys: "esc" }, { label: "Copy", keys: "⇧⌘C" }, { label: "Insert", keys: "⌘↩", primary: true }] });
    stage.shapr.append(p.el);
    css(p.el, { left: "570px", top: "80px" });
    const k = keyHint(stage, ["⌥", "⇧", "R"], "resume here");
    B.cam = [[0, { x: 960, y: 500, s: 1.15 }]];
    B.cur = [{ t: 0, x: 1500, y: 900 }];
    B.veil = 0.5;
    B.tick = (t) => { surface(p.el, t, 0.5, 99, 570, 80); css(stale, { opacity: ease.enter(prog(t, 1.0, 0.4)).toFixed(3) }); css(facts, { opacity: ease.enter(prog(t, 1.4, 0.4)).toFixed(3) }); css(paste, { opacity: ease.enter(prog(t, 1.8, 0.4)).toFixed(3) }); k.update(t, 0.1, 1.2, 960, 900); };
  }

  if (v === "live") {
    // LibraryView live link rows (server side verified by server/test.mjs)
    const lib = libraryWindow(story, files);
    const row = h("div", { class: "live-row" }, icon("link", 20), h("b", {}, "Live link · 3 joined"), h("span", { class: "dim" }, "New captures are shared as you add them"), h("span", { class: "btn small" }, "Copy link"), h("span", { class: "btn small" }, "Stop sharing"));
    const row2 = h("div", { class: "live-row" }, icon("sync", 20), h("b", {}, "Energy Research"), h("span", { class: "dim" }, "Joined · synced 2 min ago"), h("span", { class: "btn small" }, "Sync now"));
    lib.head.after(row, row2);
    const w = stage.addWindow({ title: `${P.name} — Shapr`, x: 300, y: 120, w: 1320, h: 800, body: lib.el });
    B.cam = [[0, { x: 960, y: 420, s: 1.3 }]];
    B.tick = (t) => { css(row, { opacity: ease.enter(prog(t, 0.6, 0.4)).toFixed(3) }); css(row2, { opacity: ease.enter(prog(t, 1.4, 0.4)).toFixed(3) }); };
  }

  if (v === "poster") {
    // A still for print: the library on a clean desktop, plus the "Added to" corner card. No cursor.
    const lib = libraryWindow(story, files);
    stage.addWindow({ title: `${P.name} — Shapr`, x: 230, y: 130, w: 1320, h: 820, body: lib.el });
    const card = toastCard({ title: "“ECONNREFUSED means nothing is listening at that host and port.”", meta: `Added to ${P.name} · wiki.aurora-team.example · Browser · just now`, pack: P, actions: [{ label: "Undo" }, { label: "Move" }] });
    stage.shapr.append(card.el);
    css(card.el, { left: px(TX), top: px(TY) });
    stage.menubar.app.textContent = "Shapr";
    B.cam = [[0, { x: 960, y: 540, s: 1.0 }]];
    B.cur = [];
    B.still = true;
  }

  if (v === "flowctl") {
    // Concept: session controls
    devWindows(stage, files, { editor: { x: 110, y: 92, w: 1040, h: 560 }, term: { x: 760, y: 470, w: 1060, h: 450 } }).tmw.set({ opacity: 0 });
    const sp = sessionPanel({ pack: P, apps: story.flow.apps });
    const ctl = h("div", { class: "ss-ctl" }, h("span", { class: "btn small" }, "Pause"), h("span", { class: "btn small" }, "Revoke an app"), h("span", { class: "btn small del" }, "Delete this session's memory"));
    const exp = h("div", { class: "ss-exp" }, icon("clock", 18), "Temporary details expire after 7 days unless you keep them");
    sp.el.append(exp, ctl);
    stage.shapr.append(sp.el);
    const paused = h("div", { class: "ss-paused" }, "Paused · Shapr isn't following along");
    sp.el.querySelector(".ss-h").after(paused);
    const pb = () => rectOf(ctl.children[0], stage);
    css(sp.el, { left: "1380px", top: "46px", width: "520px" });
    const b0 = pb();
    B.cam = [[0, { x: 1450, y: 330, s: 1.45 }]];
    B.cur = [{ t: 0, x: 1300, y: 700 }, { t: 6.4, x: b0.x + b0.w / 2, y: b0.y + b0.h / 2, click: true, clickDelay: 0.4 }, { t: 12, x: b0.x + 60, y: b0.y + 140 }];
    B.veil = 0.45;
    B.tick = (t) => {
      surface(sp.el, t, 0.4, 99, 1380, 46, { rise: -8 });
      css(exp, { opacity: ease.enter(prog(t, 1.4, 0.4)).toFixed(3) }); css(ctl, { opacity: ease.enter(prog(t, 2.0, 0.4)).toFixed(3) });
      paused.style.display = t > 7.0 ? "block" : "none";
      sp.el.querySelector(".ss-live").style.background = t > 7.0 ? "var(--ink-3)" : "";
    };
  }

  return (t) => {
    B.tick(t);
    if (B.veil) { stage.dim(1, 0, 8); css(stage.veil, { background: "#F4F0EA", opacity: String(B.veil) }); }
    stage.camera(keys(t, B.cam.length > 1 ? B.cam : [...B.cam, [99, B.cam[0][1]]]), t, B.still ? 0 : 1);
    stage.cursor(B.cur.length ? cursorAt(t, B.cur) : null);
  };
}
