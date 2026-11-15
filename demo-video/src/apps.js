// Generic, plausible app reconstructions. Identified by text title only; no third-party logos or copied UI.
import { h, esc, css, shaprGlyph } from "./stage.js";

export function highlightJS(line) {
  const out = [];
  const re = /(\/\/.*$)|("(?:[^"\\]|\\.)*")|\b(import|from|const|new|export|async|function|await|return)\b|\b(\d+)\b/g;
  let last = 0, m;
  while ((m = re.exec(line))) {
    out.push(esc(line.slice(last, m.index)));
    const cls = m[1] ? "com" : m[2] ? "str" : m[3] ? "kw" : "num";
    out.push(`<span class="${cls}">${esc(m[0])}</span>`);
    last = m.index + m[0].length;
  }
  out.push(esc(line.slice(last)));
  return out.join("");
}
function highlightEnv(line) {
  if (line.startsWith("#")) return `<span class="com">${esc(line)}</span>`;
  const i = line.indexOf("=");
  if (i < 0) return esc(line);
  return `<span class="kw">${esc(line.slice(0, i))}</span>=<span class="str">${esc(line.slice(i + 1))}</span>`;
}

// Code editor: file tree, tabs, numbered lines. `focus(i, k)` dims every other line.
export function codeEditor({ files, active = "db.js" }) {
  const tree = h("div", { class: "ed-tree" },
    h("div", { class: "ed-tree-h" }, "AURORA-API"),
    ...[["src", 0, true], ["db.js", 1], ["server.js", 1], ["meters.js", 1], [".env", 0], ["package.json", 0], ["docker-compose.yml", 0]].map(([n, d, folder]) =>
      h("div", { class: "ed-file" + (n === active ? " on" : ""), style: { paddingLeft: `${20 + d * 18}px` } }, folder ? "▾ " + n : n)));
  const tabs = h("div", { class: "ed-tabs" }, ...[active, ...["db.js", ".env", "server.js"].filter((x) => x !== active)].map((n, i) => h("span", { class: "ed-tab" + (i === 0 ? " on" : "") }, n)));
  const src = active === ".env" ? files.env : files.code;
  const lines = src.replace(/\n$/, "").split("\n");
  const codeEl = h("div", { class: "code ed-code" });
  const lineEls = lines.map((ln, i) => {
    const el = h("span", { class: "line", html: `<span class="ln">${i + 1}</span>${active === ".env" ? highlightEnv(ln) : highlightJS(ln)}` });
    codeEl.append(el);
    return el;
  });
  const main = h("div", { class: "ed-main" }, tabs, codeEl);
  const el = h("div", { class: "editor" }, tree, main);
  return {
    el, lineEls, codeEl,
    focus(idx, k) { lineEls.forEach((l, i) => css(l, { opacity: (idx.includes(i) ? 1 : 1 - 0.55 * k).toFixed(3) })); },
  };
}

export function terminal({ log }) {
  const el = h("div", { class: "term" });
  const lines = log.replace(/\n$/, "").split("\n").map((ln) => {
    let cls = "";
    if (/^Error|^\s+at /.test(ln)) cls = /^Error/.test(ln) ? "err" : "err dimerr";
    else if (/^>|^maya@/.test(ln)) cls = "dim";
    const e = h("span", { class: "line " + cls }, h("span", { class: "tx" }, ln || " "));
    el.append(e);
    return e;
  });
  return { el, lines, focus(idx, k) { lines.forEach((l, i) => css(l, { opacity: (idx.includes(i) ? 1 : 1 - 0.55 * k).toFixed(3) })); } };
}

// Browser chrome: tab strip and address bar; `page` is any element.
export function browser({ tabs = ["New Tab"], active = 0, url = "", page }) {
  const strip = h("div", { class: "br-tabs" });
  const tabEls = tabs.map((t, i) => { const e = h("div", { class: "br-tab" + (i === active ? " on" : "") }, h("span", {}, t)); strip.append(e); return e; });
  const bar = h("div", { class: "br-bar" }, h("span", { class: "br-nav" }, "‹  ›"), h("div", { class: "br-url" }, h("span", { class: "br-lock" }, "⌂"), url));
  const view = h("div", { class: "br-view" }, page);
  const el = h("div", { class: "browser" }, strip, bar, view);
  return {
    el, strip, tabEls, view, bar,
    setTabs(list, act) {
      strip.innerHTML = "";
      this.tabEls = list.map((t, i) => { const e = h("div", { class: "br-tab" + (i === act ? " on" : "") }, h("span", {}, t)); strip.append(e); return e; });
    },
    setUrl(u) { bar.querySelector(".br-url").lastChild.textContent = u; },
  };
}

export function docsPage({ title, paras, highlight = -1, crumbs = "Aurora wiki / Backend" }) {
  const el = h("div", { class: "doc" }, h("div", { class: "doc-crumbs" }, crumbs), h("h1", {}, title));
  const ps = paras.map((p, i) => { const e = h("p", { class: i === highlight ? "hl" : "" }, p); el.append(e); return e; });
  return { el, ps };
}

// A PDF in Preview: one page with the Aurora architecture diagram.
export function previewPDF() {
  const box = (label, sub) => h("div", { class: "arch-box" }, h("b", {}, label), h("span", {}, sub));
  const page = h("div", { class: "pdf-page" },
    h("div", { class: "pdf-h" }, "Aurora — Architecture"),
    h("div", { class: "pdf-sub" }, "v0.4 · campus energy platform"),
    h("div", { class: "arch" }, box("Front end", "dashboard"), h("i", { class: "arr" }), box("Backend API", "Node · :8080"), h("i", { class: "arr" }), box("PostgreSQL", "aurora_energy · :5432")),
    h("div", { class: "pdf-lines" }, ...Array.from({ length: 7 }, (_, i) => h("i", { style: { width: `${[92, 86, 95, 70, 88, 64, 80][i]}%` } }))));
  return { el: h("div", { class: "preview" }, page), page };
}

// A generic AI chat page (identified by its title text only).
export function chatPage({ service, turns, limit = null }) {
  const thread = h("div", { class: "chat-thread" });
  const msgs = turns.map(([who, text]) => { const e = h("div", { class: "msg " + (who === "U" ? "me" : "ai") }, h("div", { class: "bubble" }, text)); thread.append(e); return e; });
  const banner = limit ? h("div", { class: "chat-limit" }, limit) : null;
  const input = h("div", { class: "chat-input" }, h("div", { class: "ci-text" }), h("div", { class: "ci-send" }, "↑"));
  const el = h("div", { class: "chat" }, h("div", { class: "chat-h" }, service), thread, banner, input);
  return { el, thread, msgs, input, text: input.querySelector(".ci-text"), banner, send: input.querySelector(".ci-send") };
}

export function mailApp({ email }) {
  const list = h("div", { class: "mail-list" },
    ...[[email.from, email.subject, true], ["Campus IT", "Wi-Fi maintenance Friday", false], ["Prof. Okafor", "Office hours moved", false], ["Showcase Team", "Submission reminder", false]].map(([f, s, on]) =>
      h("div", { class: "mail-item" + (on ? " on" : "") }, h("b", {}, f), h("span", {}, s))));
  const reply = h("div", { class: "mail-reply" }, h("div", { class: "mr-h" }, `Re: ${email.subject}`), h("div", { class: "mr-body" }));
  const msg = h("div", { class: "mail-msg" },
    h("div", { class: "mm-subj" }, email.subject),
    h("div", { class: "mm-from" }, h("b", {}, email.from), ` <${email.address}>`),
    h("div", { class: "mm-body" }, "Hi Maya,", h("br"), email.body, h("br"), "Jordan"),
    reply);
  return { el: h("div", { class: "mail" }, list, msg), reply, replyBody: reply.querySelector(".mr-body") };
}

export function formPage({ form }) {
  const fields = form.fields.map((f) => {
    const val = h("div", { class: "ff-val" });
    const row = h("div", { class: "ff-row" + (f.label === "Description" || f.label === "Technical approach" ? " tall" : "") }, h("label", {}, f.label), val);
    return { row, val, f };
  });
  const submit = h("div", { class: "ff-submit" }, "Submit project");
  const el = h("div", { class: "fpage" }, h("div", { class: "fp-h" }, form.title), h("div", { class: "fp-sub" }, form.subtitle), ...fields.map((x) => x.row), submit);
  return { el, fields, submit };
}

export function messagesApp() {
  const rows = [["Sam", "lol did you see the dining hall menu"], ["Study Group", "Quiz moved to Thursday"], ["Mom", "Call me when you can ❤"], ["Jordan", "Friday works!"]];
  return { el: h("div", { class: "msgs" }, h("div", { class: "msgs-list" }, ...rows.map(([n, t], i) => h("div", { class: "msgs-row" + (i === 0 ? " on" : "") }, h("i", { class: "av" }, n[0]), h("div", {}, h("b", {}, n), h("span", {}, t))))),
    h("div", { class: "msgs-conv" }, h("div", { class: "bub them" }, "lol did you see the dining hall menu"), h("div", { class: "bub them" }, "tacos again"), h("div", { class: "bub me" }, "haha after this bug"))) };
}

// An "AI client" connected over MCP (generic, text-identified).
export function aiClient({ mcp }) {
  const el = h("div", { class: "aic" },
    h("div", { class: "aic-msg me" }, "What did I try on the Aurora database bug?"),
    h("div", { class: "aic-tool" }, h("span", { class: "aic-dot" }), h("span", {}, "Shapr · ", h("b", {}, mcp.tool)), h("span", { class: "aic-arg" }, mcp.arg), h("span", { class: "aic-res" }, mcp.result)),
    h("div", { class: "aic-msg ai" }, "From your Shapr pack: you checked the credentials, restarted the service and read the connection docs. Next step you saved: verify DB_HOST and DB_PORT in .env."));
  return { el, tool: el.querySelector(".aic-tool"), answer: el.querySelector(".aic-msg.ai") };
}
