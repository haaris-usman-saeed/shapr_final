// node test.mjs: exercises the share server against a throwaway folder.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { handle } from "./src/app.js";
import { diskStore } from "./src/disk-store.mjs";

const dir = mkdtempSync(path.join(tmpdir(), "shapr-server-test-"));
const store = diskStore(dir);
const base = "http://localhost:8787";
const call = (method, p, { body, token, headers = {} } = {}) => handle(new Request(base + p, {
  method, body: body === undefined ? undefined : (typeof body === "string" || body instanceof Uint8Array ? body : JSON.stringify(body)),
  headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
}), store, { adminToken: "admin-secret" });
let passed = 0;
const ok = (cond, what) => { assert.ok(cond, what); passed++; console.log("  PASS " + what); };

try {
  // Share
  let r = await call("POST", "/api/packs", { body: { name: "MAT223", emoji: "📘", captures: [] } });
  const created = await r.json();
  ok(r.status === 201 && /^[A-Za-z0-9]{12}$/.test(created.id) && created.token.length > 30 && created.url.endsWith(`/p/${created.id}`), "sharing returns a link and a secret token");
  const { id, token } = created;

  r = await call("PUT", `/api/packs/${id}/files/shot.png`, { body: new Uint8Array([137, 80, 78, 71]), token });
  ok(r.status === 200, "the sharer can upload a screenshot");
  r = await call("PUT", `/api/packs/${id}`, { token, body: { name: "MAT223", emoji: "📘", captures: [
    { id: "a1", text: "Eigenvalues <script>alert(1)</script>", title: "Lecture 5", url: "https://q.utoronto.ca/x", image: "shot.png" },
    { id: "a2", text: "bad link", url: "javascript:alert(1)" },
  ] } });
  ok((await r.json()).version === 2, "updating the pack bumps its version");

  r = await call("GET", `/api/packs/${id}`);
  const m = await r.json();
  ok(m.captures.length === 2 && m.captures[1].url === undefined, "anyone with the link can read it; unsafe links are dropped");
  r = await call("GET", `/api/packs/${id}`, { headers: { "if-none-match": `"v2"` } });
  ok(r.status === 304, "an unchanged pack costs nothing to check");

  r = await call("PUT", `/api/packs/${id}`, { token: "wrong", body: { name: "Hacked", captures: [] } });
  ok(r.status === 403, "without the token nobody can change it");
  r = await call("PUT", `/api/packs/${id}/files/..%2Fmeta.json`, { token, body: "x" });
  ok(r.status === 400, "file names can't escape the pack");

  r = await call("GET", `/p/${id}`);
  const page = await r.text();
  ok(r.status === 200 && page.includes("MAT223") && page.includes("&lt;script&gt;") && !page.includes("<script>alert"), "the pack page shows the pack and escapes what's in it");
  ok(r.headers.get("content-security-policy").includes("default-src 'none'"), "the pack page runs no scripts");
  ok(page.includes(`shapr://join/${id}`), "the pack page has an Add to Shapr button");

  r = await call("POST", `/api/packs/${id}/join`);
  await call("POST", `/api/packs/${id}/join`);
  r = await call("GET", `/api/packs/${id}/stats`, { token });
  ok((await r.json()).joins === 2, "the sharer can see how many people joined");

  r = await call("GET", `/api/packs/${id}/files/shot.png`);
  ok(r.status === 200 && r.headers.get("x-content-type-options") === "nosniff", "files are served safely");

  r = await call("PUT", `/api/packs/${id}`, { token, body: { name: "MAT223", captures: [{ id: "a2", text: "kept" }] } });
  r = await call("GET", `/api/packs/${id}/files/shot.png`);
  ok(r.status === 404, "files no capture uses anymore are removed");

  r = await call("DELETE", `/api/packs/${id}`, { token });
  r = await call("GET", `/api/packs/${id}`);
  ok(r.status === 404, "stopping sharing removes the pack");

  // App updates
  r = await call("PUT", "/api/app/latest", { token: "nope", body: { version: "1.0", build: "12", file: "Shapr.zip", sha256: "x" } });
  ok(r.status === 403, "only the release script can publish an update");
  r = await call("PUT", "/api/app/latest", { token: "admin-secret", body: { version: "1.0", build: "12", file: "Shapr-1.0.zip", dmg: "Shapr-1.0.dmg", sha256: "abc" } });
  r = await call("GET", "/api/app/latest");
  ok((await r.json()).build === "12", "the app can check for updates");
  r = await call("GET", "/download");
  ok(r.status === 302 && r.headers.get("location").endsWith("/api/app/files/Shapr-1.0.dmg"), "the download link points at the latest disk image");
  console.log(`\nAll ${passed} server checks passed.`);
} finally {
  rmSync(dir, { recursive: true, force: true });
}
