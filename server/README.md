# Shapr share server

Hosts live shared packs (`/p/<id>` pages and the `/api/packs` API used by the app) and app downloads and
updates (`/download`, `/api/app/latest`). Plain JavaScript on the Fetch API: the same code runs on
Cloudflare Workers (storage in R2) and on your Mac (storage on disk).

## Run it on your Mac

```bash
node test.mjs     # 17 checks against a throwaway folder
node dev.mjs      # http://localhost:8787 (data in server/.data)
```

Shapr uses `http://localhost:8787` until it's built with `SHAPR_SHARE_SERVER` (or you change it in
Settings → Connections → Shared packs).

## Deploy (Cloudflare, free tier)

```bash
npx wrangler login
npx wrangler r2 bucket create shapr-packs
npx wrangler deploy                  # prints https://shapr-share.<you>.workers.dev
npx wrangler secret put ADMIN_TOKEN  # any long random string; scripts/release.sh uses it to publish releases
```

Then build Shapr pointing at it: `SHAPR_SHARE_SERVER=https://shapr-share.<you>.workers.dev scripts/build-app.sh --install`.
A custom domain (for example `shapr.app`) can be added in the Cloudflare dashboard.

## How it stays safe

- **No accounts.** Sharing returns an unguessable 12-character id (the link) and a secret write token.
  Only a SHA-256 hash of the token is stored; anyone can read a pack, but only the token can change or delete it.
- **Limits.** Packs: 2 MB of text and 2000 captures. Files: 25 MB each, with safe names only. Files no capture uses are removed.
- **The pack page** escapes everything, runs no scripts (CSP `default-src 'none'`) and allows only http(s) source links.
  Files are served with `nosniff`, and anything that isn't an image or PDF downloads instead of opening.
- **App releases** can only be published with `ADMIN_TOKEN`; the app also checks the checksum and the code signature itself.
- **Not yet:** rate limiting and abuse reporting. Add a Cloudflare rate-limiting rule before sharing links widely.
