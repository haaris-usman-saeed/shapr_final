// Runs the share server on your Mac: node dev.mjs  →  http://localhost:8787
// Data goes in server/.data (git-ignored). Set ADMIN_TOKEN to test publishing app updates.
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { handle } from "./src/app.js";
import { diskStore } from "./src/disk-store.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const port = Number(process.env.PORT || 8787);
const store = diskStore(process.env.DATA_DIR || path.join(here, ".data"));

http.createServer(async (req, res) => {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = chunks.length ? Buffer.concat(chunks) : undefined;
  const request = new Request(`http://${req.headers.host}${req.url}`, {
    method: req.method, headers: req.headers, body: ["GET", "HEAD"].includes(req.method) ? undefined : body,
  });
  const response = await handle(request, store, { adminToken: process.env.ADMIN_TOKEN });
  res.writeHead(response.status, Object.fromEntries(response.headers));
  res.end(Buffer.from(await response.arrayBuffer()));
}).listen(port, "127.0.0.1", () => console.log(`Shapr share server on http://localhost:${port}`));
