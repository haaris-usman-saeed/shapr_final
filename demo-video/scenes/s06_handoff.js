// Beat 6 (signature 5): the free plan runs out; the real card offers "Continue in Claude"; the chat
// compresses into a structured handoff that crosses on the capture arc, waits in the message box,
// and is sent only when the user presses send. Then the read-back check.
import { h, css, px, show, packOrb } from "../src/stage.js";
import { ease, prog, keys, life, cursorAt, lerp, clamp, arc, D } from "../src/motion.js";
import { browser, chatPage } from "../src/apps.js";
import { toastCard, icon } from "../src/ui.js";
import { rectOf, surface } from "./_kit.js";

export default async function (ctx) {
  const { stage, story, marks: M } = ctx;
  const A = story.chatA, HO = story.handoff;
  stage.menubar.app.textContent = "Browser";
  stage.menubar.setWord("Aurora");

  const ca = chatPage({ service: A.service, turns: A.turns, limit: A.limit });
  const wa = stage.addWindow({ title: `${A.service} — Browser`, x: 110, y: 110, w: 860, h: 800, body: browser({ tabs: [A.service], url: "chatgpt.com", page: ca.el }).el, z: 1 });
  const cb = chatPage({ service: HO.target, turns: [] });
  const wb = stage.addWindow({ title: `${HO.target} — Browser`, x: 1010, y: 110, w: 820, h: 800, body: browser({ tabs: [A.service, HO.target], active: 1, url: "claude.ai/new", page: cb.el }).el, z: 2 });

  // the real limit card (RelayController.offerContinue)
  const card = toastCard({ title: `${A.service} hit its message limit`, meta: `It says “${A.limit}” Keep going in another AI with this chat and your rules.`,
    leading: h("div", { class: "branch-orb" }, icon("branch", 20)), actions: [{ label: `Continue in ${HO.target}`, primary: true }, { label: "Gemini" }] });
  stage.shapr.append(card.el);
  const cardX = 1920 - 24 - 442, cardY = 52;
  css(card.el, { left: px(cardX), top: px(cardY) });
  const contBtn = rectOf(card.btns[0], stage);

  // the structured handoff card
  const rows = HO.rows.map(([k, v]) => h("div", { class: "ho-row" }, h("span", { class: "ho-k" }, k), h("span", { class: "ho-v" }, v)));
  const ho = h("div", { class: "handoff glass solid" }, h("div", { class: "ho-h" }, packOrb(story.pack, 26), "Handoff from ", A.service, h("span", { class: "ho-meta" }, HO.meta)), ...rows);
  stage.shapr.append(ho);
  const hoW = 640, hoX = 110 + (860 - hoW) / 2, hoY = 330;
  css(ho, { left: px(hoX), top: px(hoY), width: px(hoW) });
  const hoR = rectOf(ho, stage);

  // the preview waiting in the message box
  const preview = h("div", { class: "ho-preview" }, h("div", { class: "hp-l" }, `I'm continuing “Aurora — Backend” from a chat in ${A.service}.`),
    ...HO.rows.map(([k, v]) => h("div", { class: "hp-l" }, h("b", {}, k + ": "), v)), h("div", { class: "hp-l dim" }, "Start your reply with Goal, Rules and Next…"));
  cb.text.append(preview);
  const inputR = rectOf(cb.input, stage);
  const sendR = rectOf(cb.send, stage);
  const pasted = toastCard({ title: `Pasted into ${HO.target}. Check it, then press Return.`, meta: "Shapr didn't send anything.", leading: h("div", { class: "ok-orb" }, "✓"), actions: [{ label: "Stop watching" }] });
  const gotIt = toastCard({ title: `${HO.target} got everything`, meta: "All 3 things you saved (goal, rules and next step) carried over.", leading: h("div", { class: "ok-orb" }, "✓") });
  stage.shapr.append(pasted.el, gotIt.el);
  const sentBubble = h("div", { class: "msg me" }, h("div", { class: "bubble" }, `Handoff · ${HO.rows.length} parts · from ${A.service}`));
  const reply = h("div", { class: "msg ai" }, h("div", { class: "bubble" }, h("b", {}, "Goal:"), " connect the Aurora API to PostgreSQL. ", h("b", {}, "Rules:"), " don't suggest switching databases. ", h("b", {}, "Next:"), " verify DB_HOST and DB_PORT…"));
  cb.thread.append(sentBubble, reply);

  const cur = [
    { t: 0, x: 600, y: 860 },
    { t: 2.4, x: 760, y: 700 },
    { t: M.clickCont - 0.3, x: contBtn.x + contBtn.w / 2, y: contBtn.y + contBtn.h / 2, click: true, clickDelay: 0.45 },
    { t: 5.8, x: 1500, y: 420 },
    { t: 8.6, x: inputR.x + 160, y: inputR.y - 200 },
    { t: 10.2, x: inputR.x + 420, y: inputR.y - 60, bend: 0.04 },
    { t: M.send - 0.3, x: sendR.x + sendR.w / 2, y: sendR.y + sendR.h / 2, click: true, clickDelay: 0.45 },
    { t: 15, x: sendR.x - 120, y: sendR.y - 220 },
  ];

  return (t) => {
    wb.set({ opacity: ease.enter(prog(t, M.cardDone + 0.1, 0.5)), ty: (1 - ease.enter(prog(t, M.cardDone + 0.1, 0.5))) * 14 });
    css(ca.banner, { opacity: ease.enter(prog(t, M.limit, 0.4)).toFixed(3) });
    surface(card.el, t, M.cardIn, M.clickCont + 0.2, cardX, cardY);

    // the transcript compresses: messages slide toward the centre and fade as the card forms
    ca.msgs.forEach((m, i) => {
      const k = ease.move(prog(t, M.compress + i * 0.07, 0.75));
      const r = m.getBoundingClientRect();
      css(m, { transform: `translateY(${(k * (hoR.y + hoR.h / 2 - 560 - i * 20) * 0.35).toFixed(1)}px) scale(${lerp(1, 0.86, k).toFixed(3)})`, opacity: (1 - k).toFixed(3) });
    });
    css(ca.banner, { opacity: (ease.enter(prog(t, M.limit, 0.4)) * (1 - prog(t, M.compress, 0.5))).toFixed(3) });
    const form = ease.enter(prog(t, M.compress + 0.45, 0.6));
    rows.forEach((r, i) => css(r, { opacity: ease.enter(prog(t, M.compress + 0.6 + i * 0.12, 0.4)).toFixed(3), transform: `translateY(${((1 - ease.enter(prog(t, M.compress + 0.6 + i * 0.12, 0.4))) * 10).toFixed(1)}px)` }));

    // flight: the card shrinks and crosses on the same arc as every capture, into the message box
    const fk = ease.move(prog(t, M.fly, M.flyEnd - M.fly));
    const from = { x: hoR.x + hoR.w / 2, y: hoR.y + hoR.h / 2 }, to = { x: inputR.x + inputR.w / 2, y: inputR.y + inputR.h / 2 };
    const p = arc(fk, from, to, 0.18);
    const sc = t < M.fly ? lerp(0.97, 1, form) : lerp(1, 0.42, Math.sin(Math.PI * fk) * 0.9 + fk * 0.1);
    css(ho, { transform: `translate(${(p.x - from.x).toFixed(1)}px, ${(p.y - from.y).toFixed(1)}px) scale(${sc.toFixed(4)})` });
    show(ho, t < M.flyEnd ? form : 1 - prog(t, M.flyEnd, 0.12));

    // the message box expands into a preview and waits
    const ex = ease.enter(prog(t, M.expand, 0.45));
    css(cb.input, { minHeight: px(lerp(64, 330, ex)) });
    css(preview, { opacity: ex.toFixed(3) });
    preview.style.display = t >= M.expand ? "block" : "none";
    const sent = t >= M.send + 0.15;
    if (sent) { preview.style.display = "none"; css(cb.input, { minHeight: "64px" }); }
    cb.send.classList.toggle("ready", t >= M.expand && !sent);
    css(sentBubble, { opacity: sent ? ease.enter(prog(t, M.send + 0.15, 0.3)).toFixed(3) : "0" });
    css(reply, { opacity: ease.enter(prog(t, M.readback - 0.5, 0.5)).toFixed(3) });
    surface(pasted.el, t, M.pastedToast, M.send, cardX, cardY);
    surface(gotIt.el, t, M.readback, 99, cardX, cardY);
    stage.dim(0, 0);

    const cam = keys(t, [
      [0, { x: 560, y: 600, s: 1.35 }],
      [M.cardIn - 0.1, { x: 560, y: 600, s: 1.35 }],
      [M.cardIn + 0.8, { x: 1290, y: 330, s: 1.5 }],
      [M.clickCont + 0.2, { x: 1290, y: 330, s: 1.5 }],
      [M.compress + 0.9, { x: 560, y: 560, s: 1.35 }],
      [M.fly - 0.25, { x: 560, y: 560, s: 1.35 }],
      [M.flyEnd - 0.1, { x: 960, y: 560, s: 1.0 }],
      [M.expand + 0.8, { x: 1420, y: 660, s: 1.4 }],
      [M.send + 0.5, { x: 1420, y: 700, s: 1.4 }],
      [M.readback + 0.2, { x: 1420, y: 660, s: 1.4 }],
      [M.readback + 1.2, { x: 1560, y: 330, s: 1.5 }],
    ]);
    stage.camera(cam, t, 1);
    stage.cursor(cursorAt(t, cur));
  };
}
