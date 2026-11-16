import { defineConfig } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";

// One self-contained index.html (JS, CSS and fonts inlined) so the demo runs by double-clicking
// dist/index.html, with audio files beside it in dist/audio/.
export default defineConfig({
  base: "./",
  plugins: [viteSingleFile()],
  build: { assetsInlineLimit: 100_000_000, cssCodeSplit: false, chunkSizeWarningLimit: 5000 },
});
