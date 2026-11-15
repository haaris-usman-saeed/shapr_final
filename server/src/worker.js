// Cloudflare Workers entry point: packs and app downloads live in an R2 bucket.
import { handle } from "./app.js";

function r2Store(bucket) {
  return {
    async get(key) {
      const o = await bucket.get(key);
      if (!o) return null;
      return { body: await o.arrayBuffer(), type: o.httpMetadata?.contentType };
    },
    async put(key, body, type) {
      await bucket.put(key, body, { httpMetadata: type ? { contentType: type } : undefined });
    },
    async delete(key) { await bucket.delete(key); },
    async list(prefix) {
      const keys = [];
      let cursor;
      do {
        const page = await bucket.list({ prefix, cursor });
        keys.push(...page.objects.map((o) => o.key));
        cursor = page.truncated ? page.cursor : undefined;
      } while (cursor);
      return keys;
    },
  };
}

export default {
  async fetch(request, env) {
    return handle(request, r2Store(env.PACKS), { adminToken: env.ADMIN_TOKEN });
  },
};
