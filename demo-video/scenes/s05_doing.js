// Beat 5: three fast beats, cut on action. A reply drafted from the pack and reviewed before Insert;
// a form filled with proposed values (never submitted); a voice command that saves a selection.
import { h, css, px, show, packOrb } from "../src/stage.js";
import { ease, prog, keys, life, cursorAt, lerp, clamp, typed, D } from "../src/motion.js";
import { mailApp, browser, formPage, codeEditor } from "../src/apps.js";
import { panel, toastCard, voicePill } from "../src/ui.js";
import { makeFlight, keyHint, selectionBox, rectOf, surface } from "./_kit.js";
import { unionRect } from "./_circle.js";

export default async function (ctx) {
  const { stage, story, files, marks: M } = ctx;
  const P = story.pack, E = story.email, F = story.form;
  const cutB = M.formIn - 0.35, cutC = M.voiceDown - 0.45;

  // A: Mail + Draft panel
  const mail = mailApp({ email: E });
  const mw = stage.addWindow({ title: "Mail", x: 90, y: 80, w: 1220, h: 900, body: mail.el, z: 1 });
  const draftText = E.draft.join("\n\n");
  const draftBody = h("div", {}, h("div", { class: "draft-text" }), h("div", { class: "section-label", style: { marginTop: "16px" } }, `Based on ${E.basedOn} captures`),
    h("div", { class: "src-chips" }, ...["Error screenshot", "Connection docs", "Already tried", "Next step"].map((x, i) => h("span", { class: "chip plain" }, `[${i + 1}] ${x}`))));
  const dp = panel({ title: "Draft for Mail", sub: `Reply to ${E.from} · from ${P.name}`, iconName: "pencil", width: 640, body: draftBody,
    foot: [{ label: "Cancel", keys: "esc" }, { label: "Copy", keys: "⇧⌘C" }, { label: "Insert", keys: "⌘↩", primary: true }] });
  stage.shapr.append(dp.el);
  const dpX = 1240, dpY = 150;
  css(dp.el, { left: px(dpX), top: px(dpY) });
  const insertBtn = rectOf(dp.btns[2], stage);
  const dtext = dp.el.querySelector(".draft-text");
  const kA = keyHint(stage, ["⌥", "⇧", "D"], "draft here");

  // B: form + Fill panel
  const fp = formPage({ form: F });
  const fw = stage.addWindow({ title: "Browser", x: 90, y: 80, w: 1100, h: 900, body: browser({ tabs: [F.title], url: F.url, page: fp.el }).el, z: 2 });
  const rows = F.fields.map((f) => h("div", { class: "ff-prop" }, h("div", { class: "fp-l" }, h("span", { class: "fp-tick" }, "✓"), f.label), h("div", { class: "fp-v" }, f.value)));
  const fpanel = panel({ title: "Fill form in Browser", sub: `From ${P.name} and About Me`, iconName: "form", width: 640, body: h("div", {}, h("div", { class: "section-label" }, "From your packs"), ...rows),
    foot: [{ label: "Cancel", keys: "esc" }, { label: "Fill", keys: "⌘↩", primary: true }], status: "Shapr never presses Submit" });
  stage.shapr.append(fpanel.el);
  const fpX = 1230, fpY = 150;
  css(fpanel.el, { left: px(fpX), top: px(fpY) });
  const fillBtn = rectOf(fpanel.btns[1], stage);
  const filled = toastCard({ title: `Filled ${F.fields.length} of ${F.fields.length} fields`, meta: "Check them, then submit when you're ready.", leading: h("div", { class: "ok-orb" }, "✓") });
  stage.shapr.append(filled.el);
  const submitR = unionRect(stage, [fp.submit], 0);

  // C: editor with .env selected, hold ⌥V
  const ed = codeEditor({ files, active: ".env" });
  const ew = stage.addWindow({ title: ".env — aurora-api — Code", x: 160, y: 150, w: 1200, h: 620, body: ed.el, z: 3 });
  const envSel = unionRect(stage, ed.lineEls.slice(1, 3).map((l) => l), 0);
  envSel.w = 420;
  const selC = selectionBox(stage, "#3A72D8");
  const vp = voicePill();
  stage.shapr.append(vp.el);
  const fC = makeFlight(stage, P, "DB_HOST=127.0.0.1 · DB_PORT=5432");
  const added = toastCard({ title: "DB_HOST=127.0.0.1 · DB_PORT=5432", meta: `Added to ${P.name} · .env · Code · just now`, pack: P, actions: [{ label: "Undo" }, { label: "Move" }] });
  stage.shapr.append(added.el);
  const kC = keyHint(stage, ["⌥", "V"], "hold and talk");

  const cur = [
    { t: 0, x: 700, y: 760 },
    { t: 0.4, x: 700, y: 760 },
    { t: M.insert - 0.3, x: insertBtn.x + insertBtn.w / 2, y: insertBtn.y + insertBtn.h / 2, click: true, clickDelay: 0.45 },
    { t: cutB, x: 820, y: 900 },
    { t: cutB + 0.01, x: 760, y: 820 },
    { t: M.fill - 0.3, x: fillBtn.x + fillBtn.w / 2, y: fillBtn.y + fillBtn.h / 2, click: true, clickDelay: 0.45 },
    { t: 12.4, x: fillBtn.x - 60, y: fillBtn.y + 140 },
    { t: cutC + 0.01, x: envSel.x + envSel.w + 30, y: envSel.y + envSel.h + 10 },
    { t: 17, x: envSel.x + envSel.w + 40, y: envSel.y + envSel.h + 20 },
  ];

  return (t) => {
    const inA = t < cutB, inB = t >= cutB && t < cutC, inC = t >= cutC;
    mw.set({ opacity: inA ? 1 : 0 }); fw.set({ opacity: inB ? 1 : 0 }); ew.set({ opacity: inC ? 1 : 0 });
    stage.menubar.app.textContent = inA ? "Mail" : inB ? "Browser" : "Code";

    // A
    surface(dp.el, t, M.draftIn, M.insert + 0.2, dpX, dpY);
    const n = typed(t, M.draftIn + 0.45, draftText, { cps: 95, seed: 2 });
    dtext.textContent = draftText.slice(0, n);
    css(dp.el.querySelector(".section-label"), { opacity: ease.enter(prog(t, M.draftIn + 2.4, 0.4)).toFixed(3) });
    css(dp.el.querySelector(".src-chips"), { opacity: ease.enter(prog(t, M.draftIn + 2.55, 0.4)).toFixed(3) });
    const ins = ease.enter(prog(t, M.insert + 0.3, 0.4));
    mail.replyBody.textContent = t >= M.insert + 0.3 ? draftText : "";
    css(mail.replyBody, { opacity: ins.toFixed(3) });
    kA.update(t, M.draftIn - 0.3, M.draftIn + 0.8, 960, 900);

    // B
    surface(fpanel.el, t, M.formIn, M.fill + 0.2, fpX, fpY);
    rows.forEach((r, i) => css(r, { opacity: ease.enter(prog(t, M.formIn + 0.35 + i * 0.07, 0.35)).toFixed(3) }));
    fp.fields.forEach((f, i) => {
      const at = M.fill + 0.3 + i * 0.12;
      f.val.textContent = t >= at ? f.f.value : "";
      f.val.classList.toggle("filled", t >= at);
      css(f.val, { opacity: t >= at ? ease.enter(prog(t, at, 0.25)).toFixed(3) : "1" });
    });
    surface(filled.el, t, M.fill + 1.0, cutC, 1920 - 24 - 442, 52);
    if (inB) stage.dim(life(t, M.formIn, M.fill + 0.2, 0.4, 0.3), 0.12, 0);

    // C
    selC.update(envSel, inC ? ease.enter(prog(t, cutC + 0.05, 0.2)) * (1 - prog(t, M.voiceUp + 0.1, 0.3)) : 0, 1);
    const p = cursorAt(t, cur);
    const va = life(t, M.voiceDown, M.voiceUp, 0.22, 0.2);
    css(vp.el, { left: px(p.x + 34), top: px(p.y + 18), transform: `scale(${lerp(0.94, 1, ease.enter(prog(t, M.voiceDown, 0.22))).toFixed(3)})` });
    show(vp.el, va);
    const words = story.voice.split(" ");
    const shown = words.filter((_, i) => t >= M.voiceDown + 0.45 + i * 0.32).length;
    vp.words.textContent = shown ? words.slice(0, shown).join(" ") : "Listening…";
    css(vp.words, { color: shown ? "var(--ink)" : "var(--ink-3)" });
    const lvl = t > M.voiceDown + 0.4 && t < M.voiceDown + 0.45 + words.length * 0.32 ? 0.5 + 0.5 * Math.abs(Math.sin(t * 13) * Math.sin(t * 5.3)) : 0.1;
    css(vp.halo, { transform: `scale(${(1 + 0.35 * lvl).toFixed(3)})`, opacity: (0.4 + 0.6 * lvl).toFixed(3) });
    fC.update(t, M.voiceUp + 0.05, { x: envSel.x + envSel.w / 2, y: envSel.y + envSel.h / 2 });
    if (t >= M.voiceUp + 0.7) stage.menubarPulse(t, M.voiceUp + 0.75);
    surface(added.el, t, M.voiceUp + 0.9, 99, 1920 - 24 - 442, 52);
    kC.update(t, M.voiceDown - 0.25, M.voiceUp, 960, 900);

    const cam = keys(t, [
      [0, { x: 1205, y: 500, s: 1.35 }],
      [cutB - 0.01, { x: 1190, y: 500, s: 1.35 }],
      [cutB, { x: 1180, y: 455, s: 1.3 }],
      [cutC - 0.01, { x: 1170, y: 455, s: 1.3 }],
      [cutC, { x: 700, y: 330, s: 1.6 }],
      [M.voiceUp + 0.2, { x: 700, y: 330, s: 1.6 }],
      [M.voiceUp + 1.2, { x: 1250, y: 300, s: 1.45 }],
    ]);
    stage.camera(cam, t, 1);
    stage.cursor(p);
  };
}
