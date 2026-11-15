// Storage on disk, for running the server on your Mac (dev.mjs) and in tests.
import { promises as fs } from "node:fs";
import path from "node:path";

export function diskStore(root) {
  const file = (key) => {
    const p = path.resolve(root, key);
    if (!p.startsWith(path.resolve(root) + path.sep)) throw new Error("bad key");
    return p;
  };
  return {
    async get(key) {
      try { return { body: (await fs.readFile(file(key))).buffer }; } catch { return null; }
    },
    async put(key, body, _type) {
      await fs.mkdir(path.dirname(file(key)), { recursive: true });
      await fs.writeFile(file(key), typeof body === "string" ? body : Buffer.from(body));
    },
    async delete(key) { await fs.rm(file(key), { force: true }); },
    async list(prefix) {
      const out = [];
      async function walk(dir, rel) {
        let entries = [];
        try { entries = await fs.readdir(dir, { withFileTypes: true }); } catch { return; }
        for (const e of entries) {
          const r = rel ? `${rel}/${e.name}` : e.name;
          if (e.isDirectory()) await walk(path.join(dir, e.name), r); else if (r.startsWith(prefix)) out.push(r);
        }
      }
      await walk(root, "");
      return out;
    },
  };
}
