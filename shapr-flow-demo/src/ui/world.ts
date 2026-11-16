// The one desktop every scene shares: the same windows, files and pages throughout the Aurora story.
import { set } from "../engine/anim";
import { makeWin, editor, browser, chatApp, messagesApp, type Win } from "./desktop";
import { selectable } from "./circle";

export const W = {} as {
  vs: Win; ed: ReturnType<typeof editor>;
  sf: Win; br: ReturnType<typeof browser>;
  ms: Win; gpt: Win; gptIn: HTMLElement; cl: Win; clIn: HTMLElement;
};

export const PAGES = {
  search: `<div class="crumb">Search</div><h1>postgres connection refused node</h1><div class="search-res">
    <p>Connecting · PostgreSQL documentation<small>postgresql.org/docs/16/…</small></p><p>Docker networking: localhost inside a container<small>docs.docker.com/…</small></p><p>node-postgres: Connecting<small>node-postgres.com/…</small></p></div>`,
  pgdocs: `<div class="crumb">PostgreSQL 16 · Client connection</div><h1>Connecting to the server</h1>
    <p>The client connects to the host and port it is given. <b data-sel="refused">“Connection refused” means nothing is accepting connections at that host and port.</b></p>
    <p>Check that the server is running, and that the host and port match where it is actually listening.</p>`,
  docker: `<div class="crumb">Docker docs · Networking</div><h1>Networking in Compose</h1>
    <p>Each service joins a shared network and is reachable by its service name.</p>
    <p><b data-sel="docker">Inside a container, localhost refers to the container itself, not to other services.</b></p>
    <p>To reach a database service named <b>db</b>, connect to host <b>db</b>.</p>`,
  spec: `<div class="crumb">Aurora · Project spec · v0.4</div><h1>Aurora: campus energy monitoring</h1>
    <p class="req">New requirement (from Jordan): Support real-time team collaboration.</p>
    <p style="margin-top:22px;font-size:15px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--ink-3)">Architecture notes</p>
    <p class="note" data-sel="arch">Decision (week 3): Store user data locally.</p>
    <p>Backend: Node API on :8080 · Database: PostgreSQL 16 · Front end: dashboard.</p>`,
};

export function buildWorld() {
  W.ed = editor("db");
  W.vs = makeWin("db.js — aurora-api — VS Code", 90, 78, 1120, 830, W.ed.root); W.vs.app = "vscode";
  W.br = browser(["PostgreSQL docs"], "postgresql.org/docs/16/runtime-config-connection.html");
  W.sf = makeWin("Safari", 990, 120, 860, 700, W.br.root); W.sf.app = "safari";
  W.ms = makeWin("Messages", 1250, 560, 600, 400, messagesApp()); W.ms.app = "messages";
  const g = chatApp("ChatGPT"); W.gpt = makeWin("ChatGPT", 240, 300, 780, 520, g.root); W.gptIn = g.input;
  const c = chatApp("Claude"); W.cl = makeWin("Claude", 1010, 220, 780, 520, c.root); W.clIn = c.input;
  W.br.page(PAGES.pgdocs);
  selectable("error", W.ed.termLine(3).firstElementChild as HTMLElement, "Error: connect ECONNREFUSED 127.0.0.1:5432", "Terminal · ECONNREFUSED");
  refreshSelectables();
}

/** Register whatever selectable text the browser currently shows. */
export function refreshSelectables() {
  W.br.view.querySelectorAll("[data-sel]").forEach((e) => {
    const id = (e as HTMLElement).dataset.sel!;
    selectable(id, e as HTMLElement, e.textContent || "", id === "docker" ? "Docker docs · Networking" : id === "arch" ? "Aurora spec · Architecture" : "PostgreSQL docs · Connecting");
  });
}

export function page(name: keyof typeof PAGES, url: string, tabs?: string[]) {
  W.br.page(PAGES[name]); W.br.url(url); if (tabs) W.br.tabs(tabs);
  refreshSelectables();
}

export function hideAll() { [W.vs, W.sf, W.ms, W.gpt, W.cl].forEach((w) => set(w.el, { o: 0 })); }
