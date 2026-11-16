// SYNTHETIC DEMONSTRATION DATA. Fictional project, people and files. Every observation the demo can
// produce is listed here with its known meaning; nothing is inferred from real screen content.

export type AppId = "vscode" | "safari" | "messages" | "chatgpt" | "claude";

export const APPS: Record<AppId, { name: string; glyph: string; tint: string }> = {
  vscode: { name: "VS Code", glyph: "{ }", tint: "#3B6FB6" },
  safari: { name: "Safari", glyph: "◎", tint: "#3A8FB0" },
  messages: { name: "Messages", glyph: "✉", tint: "#3E9A63" },
  chatgpt: { name: "ChatGPT", glyph: "AI", tint: "#5E6B80" },
  claude: { name: "Claude", glyph: "AI", tint: "#8A6A52" },
};

export type Kind = "open" | "read" | "search" | "error" | "attempt" | "note" | "message" | "edit" | "spec";
export type Effect = { goal?: string; tried?: string; blocker?: string; next?: string; fact?: string };

export interface ObsDef {
  id: string;
  app: AppId;
  kind: Kind;
  /** Same key = same information (used to detect repetition). */
  key: string;
  label: string;          // what the memory kernel shows as a fragment
  ref: string;            // source reference kept with anything derived from it
  noise?: boolean;        // not relevant to the active task
  effect?: Effect;        // what it contributes to task working memory, if retained
}

export const OBS: Record<string, ObsDef> = {
  openVscode: { id: "openVscode", app: "vscode", kind: "open", key: "open:aurora-api", label: "VS Code opened aurora-api", ref: "VS Code · aurora-api", noise: true },
  viewConfig: { id: "viewConfig", app: "vscode", kind: "open", key: "file:db.js", label: "Database configuration viewed", ref: "db.js · .env", effect: { fact: "API reads DB_HOST and DB_PORT from .env" } },
  searchDocs: { id: "searchDocs", app: "safari", kind: "search", key: "search:econnrefused", label: "Searched “postgres connection refused”", ref: "Safari · search", effect: {} },
  readDocs: { id: "readDocs", app: "safari", kind: "read", key: "doc:pg-connect", label: "Documentation read", ref: "PostgreSQL docs · Connecting", effect: { fact: "Refused means nothing is listening at that host and port" } },
  error1: { id: "error1", app: "vscode", kind: "error", key: "err:ECONNREFUSED", label: "Error appeared", ref: "Terminal · ECONNREFUSED 127.0.0.1:5432", effect: { goal: "Fix PostgreSQL connection", blocker: "Connection refused (127.0.0.1:5432)" } },
  creds: { id: "creds", app: "vscode", kind: "attempt", key: "try:credentials", label: "Credentials checked", ref: ".env · DB_USER", effect: { tried: "Checked credentials" } },
  restart: { id: "restart", app: "vscode", kind: "attempt", key: "try:restart", label: "Server restarted", ref: "Terminal · npm run dev", effect: { tried: "Restarted service" } },
  error2: { id: "error2", app: "vscode", kind: "error", key: "err:ECONNREFUSED", label: "Same error appeared again", ref: "Terminal · ECONNREFUSED 127.0.0.1:5432" },
  readDocs2: { id: "readDocs2", app: "safari", kind: "read", key: "doc:pg-connect", label: "Documentation revisited", ref: "PostgreSQL docs · Connecting" },
  dockerNote: { id: "dockerNote", app: "safari", kind: "read", key: "doc:docker-localhost", label: "Read: localhost inside a container", ref: "Docker docs · Networking", effect: { next: "Inspect environment configuration (DB_HOST)" } },
  message: { id: "message", app: "messages", kind: "message", key: "msg:sam", label: "New message", ref: "Messages" },
  dining: { id: "dining", app: "safari", kind: "read", key: "web:dining", label: "Opened campus dining menu", ref: "Safari · dining", noise: true },
  spec: { id: "spec", app: "safari", kind: "spec", key: "doc:spec", label: "Project spec: real-time collaboration", ref: "Aurora spec · Requirements", effect: { fact: "New requirement: real-time team collaboration" } },
  archNote: { id: "archNote", app: "safari", kind: "spec", key: "doc:arch", label: "Architecture note: store data locally", ref: "Aurora spec · Architecture", effect: { fact: "Decision (week 3): store user data locally" } },
};

/** The order a working afternoon produces them in (autoplay uses this; interactive mode can fire any). */
export const AFTERNOON = ["openVscode", "viewConfig", "searchDocs", "readDocs", "error1", "creds", "restart", "error2", "readDocs2", "message"];

export const FILES = {
  db: `import pg from "pg";

// Connection settings come from .env
const pool = new pg.Pool({
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT),
  user: process.env.DB_USER,
  database: process.env.DB_NAME,
});

export async function connect() {
  const client = await pool.connect();
  return client;
}`,
  env: `# Aurora API — local development
DB_HOST=127.0.0.1
DB_PORT=5432
DB_USER=aurora
DB_NAME=aurora_energy`,
  compose: `services:
  api:
    build: .
    env_file: .env
  db:
    image: postgres:16
    ports: ["5432:5432"]`,
  terminal: [
    ["dim", "aurora-api % npm run dev"],
    ["dim", "> node src/server.js"],
    ["", "Aurora API listening on :8080"],
    ["err", "Error: connect ECONNREFUSED 127.0.0.1:5432"],
    ["err2", "    at TCPConnectWrap.afterConnect (node:net:1607:16)"],
  ] as [string, string][],
};

export const PROMPT_TEXT = "I'm working on a Node.js app using PostgreSQL. Here's what I've already tried…";
