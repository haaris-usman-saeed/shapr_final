// Shapr share server: live shared packs, the public pack page, and app downloads/updates.
// Plain JavaScript on the standard Fetch API, so the same code runs on Cloudflare Workers
// (worker.js, storage in R2) and on your Mac for development (dev.mjs, storage on disk).
//
// There are no accounts. Creating a shared pack returns an unguessable id (for the link) and a
// secret write token that only the sharer's Mac keeps (in its Keychain). Anyone with the link can
// read the pack; only the token can change or delete it. The server stores only a hash of the token.

const MAX_MANIFEST_BYTES = 2_000_000;
const MAX_FILE_BYTES = 25_000_000;
const MAX_CAPTURES = 2000;
const ID_RE = /^[A-Za-z0-9]{12}$/;
const FILE_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/;

const SAFE_TYPES = {
  png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp", heic: "image/heic",
  pdf: "application/pdf", txt: "text/plain; charset=utf-8", md: "text/markdown; charset=utf-8",
  csv: "text/csv; charset=utf-8", json: "application/json", zip: "application/zip", dmg: "application/x-apple-diskimage",
};
const INLINE_TYPES = new Set(["png", "jpg", "jpeg", "gif", "webp", "heic", "pdf"]);

/**
 * @param {Request} request
 * @param {{get(key:string):Promise<{body:ArrayBuffer|string, type?:string}|null>, put(key:string, body:any, type?:string):Promise<void>, delete(key:string):Promise<void>, list(prefix:string):Promise<string[]>}} store
 * @param {{adminToken?: string}} config
 */
export async function handle(request, store, config = {}) {
  try {
    return await route(request, store, config);
  } catch (e) {
    if (e instanceof HttpError) return json({ error: e.message }, e.status);
    return json({ error: "Something went wrong." }, 500);
  }
}

class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

async function route(request, store, config) {
  const url = new URL(request.url);
  const parts = url.pathname.split("/").filter(Boolean);
  const method = request.method;

  // Public pages
  if (method === "GET" && parts.length === 0) return landingPage(url, store);
  if (method === "GET" && parts[0] === "download" && parts.length === 1) return download(url, store);
  if (method === "GET" && parts[0] === "p" && parts.length === 2) return packPage(url, parts[1], store);

  if (parts[0] !== "api") throw new HttpError(404, "Not found.");

  // App updates: GET is public, writing needs the admin token (used by scripts/release.sh).
  if (parts[1] === "app") {
    if (parts[2] === "latest" && parts.length === 3) {
      if (method === "GET") {
        const latest = await store.get("app/latest.json");
        if (!latest) throw new HttpError(404, "No release yet.");
        return new Response(text(latest.body), { headers: { "content-type": "application/json", "cache-control": "no-cache" } });
      }
      if (method === "PUT") {
        requireAdmin(request, config);
        const body = await readJSON(request, 100_000);
        if (!body.version || !body.build || !body.file || !body.sha256) throw new HttpError(400, "version, build, file and sha256 are required.");
        await store.put("app/latest.json", JSON.stringify(body), "application/json");
        return json({ ok: true });
      }
    }
    if (parts[2] === "files" && parts.length === 4) {
      const name = checkFileName(parts[3]);
      if (method === "GET") return serveFile(store, `app/files/${name}`, name, true);
      if (method === "PUT") {
        requireAdmin(request, config);
        await store.put(`app/files/${name}`, await readBytes(request, 300_000_000), typeFor(name));
        return json({ ok: true });
      }
    }
    throw new HttpError(404, "Not found.");
  }

  if (parts[1] !== "packs") throw new HttpError(404, "Not found.");

  // POST /api/packs → a new shared pack
  if (parts.length === 2 && method === "POST") {
    const manifest = cleanManifest(await readJSON(request, MAX_MANIFEST_BYTES));
    const id = randomId(12);
    const token = randomToken();
    const now = new Date().toISOString();
    await store.put(`packs/${id}/meta.json`, JSON.stringify({ tokenHash: await sha256(token), created: now, joins: 0 }), "application/json");
    await store.put(`packs/${id}/manifest.json`, JSON.stringify({ ...manifest, format: 1, id, version: 1, updated: now }), "application/json");
    return json({ id, token, version: 1, url: `${url.origin}/p/${id}` }, 201);
  }

  const id = parts[2];
  if (!ID_RE.test(id || "")) throw new HttpError(404, "No such pack.");

  // /api/packs/:id
  if (parts.length === 3) {
    if (method === "GET") {
      const m = await store.get(`packs/${id}/manifest.json`);
      if (!m) throw new HttpError(404, "This pack isn't shared anymore.");
      const manifest = JSON.parse(text(m.body));
      const etag = `"v${manifest.version}"`;
      if (request.headers.get("if-none-match") === etag) return new Response(null, { status: 304, headers: { etag } });
      return new Response(JSON.stringify(manifest), { headers: { "content-type": "application/json", etag, "cache-control": "no-cache" } });
    }
    if (method === "PUT") {
      const meta = await authorize(request, store, id);
      const prev = JSON.parse(text((await store.get(`packs/${id}/manifest.json`)).body));
      const manifest = cleanManifest(await readJSON(request, MAX_MANIFEST_BYTES));
      const version = prev.version + 1;
      await store.put(`packs/${id}/manifest.json`, JSON.stringify({ ...manifest, format: 1, id, version, updated: new Date().toISOString() }), "application/json");
      // Drop files no capture points at anymore.
      const wanted = new Set(manifest.captures.flatMap((c) => [c.image, c.file].filter(Boolean)));
      for (const key of await store.list(`packs/${id}/files/`)) {
        if (!wanted.has(key.slice(`packs/${id}/files/`.length))) await store.delete(key);
      }
      return json({ version, joins: meta.joins || 0 });
    }
    if (method === "DELETE") {
      await authorize(request, store, id);
      for (const key of await store.list(`packs/${id}/`)) await store.delete(key);
      return json({ ok: true });
    }
  }

  // /api/packs/:id/files/:name
  if (parts.length === 5 && parts[3] === "files") {
    const name = checkFileName(parts[4]);
    if (method === "GET") return serveFile(store, `packs/${id}/files/${name}`, name, false);
    if (method === "PUT") {
      await authorize(request, store, id);
      await store.put(`packs/${id}/files/${name}`, await readBytes(request, MAX_FILE_BYTES), typeFor(name));
      return json({ ok: true });
    }
  }

  // POST /api/packs/:id/join → counts people who joined (anonymous)
  if (parts.length === 4 && parts[3] === "join" && method === "POST") {
    const raw = await store.get(`packs/${id}/meta.json`);
    if (!raw) throw new HttpError(404, "This pack isn't shared anymore.");
    const meta = JSON.parse(text(raw.body));
    meta.joins = (meta.joins || 0) + 1;
    await store.put(`packs/${id}/meta.json`, JSON.stringify(meta), "application/json");
    return json({ joins: meta.joins });
  }

  // GET /api/packs/:id/stats (sharer only)
  if (parts.length === 4 && parts[3] === "stats" && method === "GET") {
    const meta = await authorize(request, store, id);
    return json({ joins: meta.joins || 0 });
  }

  throw new HttpError(404, "Not found.");
}

// ---------- validation ----------

function str(v, max) {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "string") throw new HttpError(400, "Expected text.");
  return v.slice(0, max);
}

function cleanManifest(m) {
  if (!m || typeof m !== "object") throw new HttpError(400, "Expected a pack.");
  const name = str(m.name, 120);
  if (!name) throw new HttpError(400, "A pack needs a name.");
  if (!Array.isArray(m.captures) || m.captures.length > MAX_CAPTURES) throw new HttpError(400, "Too many captures.");
  const captures = m.captures.map((c) => {
    if (!c || typeof c.id !== "string" || !/^[A-Za-z0-9-]{1,64}$/.test(c.id)) throw new HttpError(400, "Each capture needs an id.");
    const out = {
      id: c.id,
      text: str(c.text, 200_000) ?? "",
      title: str(c.title, 300),
      captured: str(c.captured, 40),
      app: str(c.app, 80),
      url: safeLink(str(c.url, 2000)),
      image: c.image ? checkFileName(c.image) : undefined,
      file: c.file ? checkFileName(c.file) : undefined,
      fileName: str(c.fileName, 200),
    };
    return Object.fromEntries(Object.entries(out).filter(([, v]) => v !== undefined));
  });
  return { name, emoji: str(m.emoji, 16), sharedBy: str(m.sharedBy, 80), captures };
}

function safeLink(u) {
  if (!u) return undefined;
  try {
    const p = new URL(u);
    return p.protocol === "http:" || p.protocol === "https:" ? p.toString() : undefined;
  } catch { return undefined; }
}

function checkFileName(name) {
  const n = decodeURIComponent(String(name));
  if (!FILE_RE.test(n) || n.includes("..")) throw new HttpError(400, "Bad file name.");
  return n;
}

function typeFor(name) {
  const ext = name.split(".").pop().toLowerCase();
  return SAFE_TYPES[ext] || "application/octet-stream";
}

async function readJSON(request, max) {
  const t = await request.text();
  if (t.length > max) throw new HttpError(413, "Too big.");
  try { return JSON.parse(t); } catch { throw new HttpError(400, "Expected JSON."); }
}

async function readBytes(request, max) {
  const b = await request.arrayBuffer();
  if (b.byteLength > max) throw new HttpError(413, "That file is too big to share.");
  return b;
}

// ---------- auth ----------

async function authorize(request, store, id) {
  const raw = await store.get(`packs/${id}/meta.json`);
  if (!raw) throw new HttpError(404, "This pack isn't shared anymore.");
  const meta = JSON.parse(text(raw.body));
  const token = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token || !timingSafeEqual(await sha256(token), meta.tokenHash)) throw new HttpError(403, "Only the person who shared this pack can change it.");
  return meta;
}

function requireAdmin(request, config) {
  const token = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!config.adminToken || !token || !timingSafeEqual(token, config.adminToken)) throw new HttpError(403, "Not allowed.");
}

function timingSafeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

async function sha256(s) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function randomId(n) {
  const abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  let out = "";
  while (out.length < n) {
    for (const b of crypto.getRandomValues(new Uint8Array(n * 2))) {
      if (b < 248 && out.length < n) out += abc[b % 62]; // 248 = 4 × 62: no bias
    }
  }
  return out;
}

function randomToken() {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// ---------- responses ----------

function text(body) { return typeof body === "string" ? body : new TextDecoder().decode(body); }

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });
}

async function serveFile(store, key, name, attachment) {
  const f = await store.get(key);
  if (!f) throw new HttpError(404, "File not found.");
  const ext = name.split(".").pop().toLowerCase();
  const inline = !attachment && INLINE_TYPES.has(ext);
  return new Response(f.body, {
    headers: {
      "content-type": typeFor(name),
      "content-disposition": `${inline ? "inline" : "attachment"}; filename="${name}"`,
      "x-content-type-options": "nosniff",
      "content-security-policy": "default-src 'none'; sandbox",
      "cache-control": "public, max-age=300",
    },
  });
}

async function download(url, store) {
  const latest = await store.get("app/latest.json");
  if (!latest) return html(page("Shapr", `<main class="narrow"><h1>Shapr isn't available yet</h1><p>Check back soon.</p></main>`), 404);
  const { file, dmg } = JSON.parse(text(latest.body));
  return Response.redirect(`${url.origin}/api/app/files/${encodeURIComponent(dmg || file)}`, 302);
}

// ---------- pages ----------

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

function html(body, status = 200) {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "content-security-policy": "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
    },
  });
}

function page(title, main) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title><style>${CSS}</style></head><body>${main}</body></html>`;
}

async function landingPage(url, store) {
  const latest = await store.get("app/latest.json");
  const version = latest ? JSON.parse(text(latest.body)).version : null;
  return html(page("Shapr", `<main class="narrow hero">
  <div class="logo">✦</div>
  <h1>Shapr</h1>
  <p class="lede">Grab anything from anywhere on your Mac, keep it in packs, and every AI you use already knows it.</p>
  ${version ? `<a class="btn primary" href="/download">Download for Mac</a><p class="meta">Version ${esc(version)} · macOS 26 or later</p>` : `<p class="meta">Coming soon.</p>`}
</main>`));
}

async function packPage(url, id, store) {
  if (!ID_RE.test(id)) return html(page("Not found", `<main class="narrow"><h1>This link doesn't work</h1></main>`), 404);
  const m = await store.get(`packs/${id}/manifest.json`);
  if (!m) return html(page("Not shared anymore", `<main class="narrow"><h1>This pack isn't shared anymore</h1><p>Ask the person who sent it for a new link.</p></main>`), 404);
  const p = JSON.parse(text(m.body));
  const updated = new Date(p.updated);
  const cards = [...p.captures].reverse().map((c) => {
    const file = (n) => `/api/packs/${id}/files/${encodeURIComponent(n)}`;
    let host = "";
    try { host = c.url ? new URL(c.url).hostname.replace(/^www\./, "") : ""; } catch {}
    const source = [host, c.app].filter(Boolean).join(" · ");
    return `<article class="card">
  ${c.image ? `<div class="shot"><img src="${file(c.image)}" alt="Screenshot" loading="lazy"></div>` : ""}
  ${c.file ? `<a class="file" href="${file(c.file)}"><span class="badge">${esc((c.fileName || c.file).split(".").pop().toUpperCase())}</span>${esc(c.fileName || c.title || c.file)}</a>` : ""}
  ${c.title && !c.file ? `<h3>${esc(c.title)}</h3>` : ""}
  ${c.text && !c.file ? `<p class="text">${esc(c.text.length > 1400 ? c.text.slice(0, 1400) + "…" : c.text)}</p>` : ""}
  ${source ? `<p class="meta">${c.url ? `<a href="${esc(c.url)}" rel="noopener noreferrer nofollow" target="_blank">${esc(source)}</a>` : esc(source)}</p>` : ""}
</article>`;
  }).join("\n");
  return html(page(`${p.emoji ? p.emoji + " " : ""}${p.name} · Shapr`, `<header class="top">
  <div class="title">
    <div class="icon">${esc(p.emoji || "✦")}</div>
    <div><h1>${esc(p.name)}</h1>
    <p class="meta">${p.captures.length} capture${p.captures.length === 1 ? "" : "s"}${p.sharedBy ? ` · shared by ${esc(p.sharedBy)}` : ""} · updated ${esc(updated.toUTCString().slice(5, 16))}</p></div>
  </div>
  <div class="actions">
    <a class="btn primary" href="shapr://join/${esc(id)}">Add to Shapr</a>
    <a class="btn" href="/download">Get Shapr for Mac</a>
  </div>
  <p class="hint">Added packs stay up to date: new captures show up in your Shapr as they're shared.</p>
</header>
<main class="grid">${cards || `<p class="meta">Nothing in this pack yet.</p>`}</main>`));
}

const CSS = `
:root{--canvas:#F6F7F9;--panel:#fff;--well:#F2F3F6;--line:#E1E4EA;--text:#20242C;--text2:#586170;--accent:#5559E0;--accentFill:#5458E8;color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--canvas:#17191F;--panel:#242730;--well:#1C1F26;--line:#363A46;--text:#F3F5F8;--text2:#B6BEC9;--accent:#A5A8FF;--accentFill:#5B5FEF}}
*{box-sizing:border-box}body{margin:0;background:var(--canvas);color:var(--text);font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif}
a{color:var(--accent)}h1{font-size:22px;margin:0;font-weight:650}h3{font-size:14px;margin:0 0 6px;font-weight:600}
.narrow{max-width:560px;margin:12vh auto;padding:0 16px}.hero{text-align:center}.hero h1{font-size:34px;margin:8px 0}
.logo{width:64px;height:64px;margin:0 auto;border-radius:16px;background:linear-gradient(135deg,#9473FF,#5559E0);color:#fff;font-size:32px;display:grid;place-items:center}
.lede{font-size:17px;color:var(--text2);margin:8px 0 24px}
.top{max-width:1100px;margin:0 auto;padding:32px 16px 8px}.title{display:flex;gap:14px;align-items:center}
.icon{width:52px;height:52px;border-radius:14px;background:var(--well);border:0.5px solid var(--line);display:grid;place-items:center;font-size:28px;flex:none}
.meta{color:var(--text2);font-size:13px;margin:2px 0 0}.hint{color:var(--text2);font-size:13px;margin:10px 0 0}
.actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:18px}
.btn{display:inline-block;padding:8px 14px;border-radius:8px;background:var(--well);border:0.5px solid var(--line);color:var(--text);text-decoration:none;font-weight:550;font-size:14px}
.btn.primary{background:var(--accentFill);color:#fff;border-color:transparent}
.grid{max-width:1100px;margin:0 auto;padding:16px;display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:14px;align-items:start}
.card{background:var(--panel);border:0.5px solid var(--line);border-radius:10px;padding:14px;overflow:hidden}
.text{white-space:pre-wrap;margin:0 0 8px;font-size:14px;overflow-wrap:anywhere}
.shot{background:var(--well);border-radius:8px;margin:-4px -4px 10px;padding:6px;text-align:center}.shot img{max-width:100%;max-height:260px;object-fit:contain}
.file{display:flex;gap:10px;align-items:center;text-decoration:none;color:var(--text);font-weight:600;font-size:14px;overflow-wrap:anywhere}
.badge{flex:none;font-size:10px;font-weight:700;color:var(--text2);background:var(--well);border:0.5px solid var(--line);border-radius:6px;padding:8px 6px}
`;
