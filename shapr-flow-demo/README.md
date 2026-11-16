# SHAPR FLOW: interactive product demonstration

A cinematic, interactive demonstration of **Shapr Flow**, the proposed next generation of Shapr: an
ambient, permission-based, local-first companion that understands the task you're working on, keeps a
compact working memory, helps where you are (Lens · Threads · Simulate) and lets you continue tomorrow.

It is one web app with two modes over the **same demo state**:

- **Autoplay**: a choreographed 3:41 film (and a 60-second trailer) that runs on its own.
- **Interactive**: the presenter starts a session, grants or denies apps, triggers work events, circles
  content, uses Lens / Threads / Simulate, pauses, deletes, ends the day and resumes.

Everything shown is a **concept demonstration with synthetic data**. See `docs/TECHNICAL.md` for exactly what
is simulated, what Shapr already implements, and what would need engineering.

## Run it

Fastest (no install): open **`dist/index.html`** in Chrome, Edge or Safari. It's a single self-contained file
(fonts and code inlined); voice and music load from `dist/audio/` beside it. If your browser blocks audio
from a local file, everything still works with captions.

From source:

```bash
npm install
npm run dev        # http://localhost:5173
npm run build      # → dist/index.html + dist/audio/
```

URL options: `?mode=play` (autoplay immediately), `?mode=play&program=trailer`, `?mode=play&scene=8`
(start at scene 9), `?mode=explore` (interactive), `&muted=1`, `&captions=0`.

## Presenting

The start screen offers **Play cinematic demo**, **60-second trailer** and **Explore interactively**.
Click once anywhere first if you want sound (browsers require a gesture).

| Key | Action |
|---|---|
| Space | play / pause |
| → / ← | next / previous scene (deterministic: every scene starts from exactly the state the story produced) |
| R | restart (in interactive mode: reset the demo state) |
| F | full screen |
| M | mute / unmute |
| Esc | close the top card or popover, then leave full screen |
| L / T / S | pick Lens / Threads / Simulate when the selector is open |
| D | show / hide the presenter panel (interactive mode) |

The presenter bar (bottom right) appears on hover or key press and hides itself during autoplay.

### Interactive mode, a suggested 3-minute walkthrough

1. Click the **Shapr icon** in the menu bar → **Start session**.
2. Click the **VS Code** window → Shapr asks → **Allow this session**. Same for **Safari**. Click **Messages** → **Don't allow**.
3. In the presenter panel, fire activity: *Open db.js and .env*, *Open related documentation*, *Encounter database error*,
   *Attempt a fix: check credentials*, *Attempt a fix: restart server*, *Same error again*, *Receive a message*.
   Watch light pulses travel from allowed apps only. Messages produces nothing.
4. **Show memory consolidation** (or *Review memory*) to see the three layers: immediate (expiring), working, long-term.
5. **Draw a loop** with the mouse around the red terminal error (or use *Circle the terminal error*) → press **L** for Lens → **See evidence**.
6. Open *Read Docker networking docs*, circle the bold sentence → **T** to save it to the thread.
7. *Circle the architecture note* → **S** → choose a path.
8. **End the day → next morning**, then click the Shapr icon → **Continue where I left off**.
9. **Reset** and repeat with Safari **denied**: Lens now says documentation from Safari isn't used, and the memory
   consolidation shows only a contentless "1 event from a blocked app · not observed".

## Exports

```bash
npm run export:hero      # exports/shapr_flow_hero.mp4        (1920×1080, 30 fps, H.264, AAC)
npm run export:trailer   # exports/shapr_flow_60s_trailer.mp4
npm run audio            # regenerate narration (Kokoro TTS, local) and music into public/audio/
npm test                 # browser validation → qa/test-report.json
node scripts/capture.mjs --program hero --stills 12,40,90   # review stills → qa/stills/
```

Video is captured frame by frame from the built app with a stepped clock (no screen recording, no dropped frames):
4 Chromium workers each fast-forward to their chunk, then render. Audio is mixed offline from the exact cue times
the app logged (narration, the same synthesised effects, music ducked under the voice, −16 LUFS).

## Changing things

| What | Where |
|---|---|
| Scene choreography | `src/scenes/hero.ts` (12 hero scenes + 6 trailer scenes) |
| Scene durations (shared with the music) | `src/scenes/programs.json` |
| Narration lines | `src/audio/narration.ts`, then `npm run audio` |
| A human voice | drop `n01.wav … n13.wav` in `public/audio/human/`, run `npm run audio` |
| Synthetic events and files | `src/demo-data/aurora.ts` |
| Memory Kernel policy (TTLs, budgets, inference) | `src/state/kernel.ts` (`POLICY`) |
| Look and feel | `src/styles/main.css` (tokens at the top; one accent: `--accent`) |
| Sounds | `src/audio/sfx.ts` (live) and `scripts/audio.py` (same recipes, offline) |

## Layout

```
src/engine/      clock.ts (one clock: live or stepped) · anim.ts (tweens, easing, spring)
src/state/       kernel.ts (Memory Kernel simulation) · store.ts (the single demo state + actions)
src/demo-data/   aurora.ts (synthetic observations, files, pages)
src/ui/          desktop.ts (stage, windows, camera, cursor) · shapr.ts (popover, permission, status, memory sheet)
                 circle.ts (circle gesture + L/T/S) · assist.ts (Lens, Threads, Simulate, Resume) · kernelview.ts · world.ts
src/scenes/      hero.ts (autoplay programs) · director.ts (sequencing, seeking) · programs.json
src/interactive.ts  presenter mode on the same world and state
scripts/         capture.mjs · audio.py · mux.mjs · test.mjs · sheet.sh
docs/            STORYBOARD.md · TECHNICAL.md
qa/              test-report.json · REVIEW.md · stills
```
