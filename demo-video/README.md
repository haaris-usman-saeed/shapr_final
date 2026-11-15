# Shapr product film

A hero film (3:21), a 60-second trailer and a 6-minute feature tour for Shapr, built as code: every
scene is HTML/CSS/SVG that is a pure function of the frame number, rendered frame by frame in headless
Chromium and encoded with FFmpeg. Music and sound are synthesised in NumPy; narration is a local
open-weight TTS voice that a human read can replace file by file.

Nothing here touches the app source (`Sources/`). Rendered video, audio and the TTS model are not committed.

## Environment

| Need | Used here | Notes |
|---|---|---|
| Node 22 | 22.23 | ES modules (`"type": "module"`) |
| Playwright + Chromium | pre-installed | resolved with `createRequire`; do not reinstall |
| FFmpeg | 6.x with libx264, aac | |
| Python 3.11+ | 3.13 + numpy, scipy | `pip install numpy scipy` |
| Fonts | Inter, JetBrains Mono, Instrument Serif, Fraunces | open licences, installed by `npm install` (`@fontsource*`); the page waits for `document.fonts` and fails if any font errors |
| TTS (optional) | Kokoro v1.0 via `kokoro-onnx` | `pip install kokoro-onnx soundfile`; put `kokoro.onnx` and `voices.bin` (github.com/thewh1teagle/kokoro-onnx, release `model-files-v1.0`) in `.cache/tts/` or set `KOKORO_DIR` |

```bash
npm install
```

## One command each

```bash
node scripts/render.mjs still --film hero --entry 2 --t 3.4,4.3        # stills of one scene (PNG, 3840x2160)
node scripts/render.mjs still --film hero --entry 2 --t 3.4 --proxy     # same at 960x540
node scripts/render.mjs segment --film hero --entry 2                   # render one scene (cached by content hash)
npm run render:hero                                                      # all hero scenes, 4K master segments
npm run proxy:hero                                                       # whole hero at 960x540, with audio (animatic)
npm run audio                                                            # narration, music, effects and mixes for all films
npm run captions                                                         # .srt and .vtt for all films
npm run assemble:hero                                                    # exports/shapr_hero_4k.mp4 + shapr_hero_1080p.mp4
python3 scripts/validate.py exports/shapr_hero_1080p.mp4 --srt exports/shapr_hero.srt --expect 1920x1080
scripts/sheet.sh qa/sheet.png 4 qa/frames/*.png                          # contact sheet from any PNGs
npm run docs                                                             # regenerate script.md from the timeline
```

Trailer: `npm run render:trailer && npm run assemble:trailer`. Tour (native 1080p): `npm run render:tour && npm run assemble:tour`.
Caption-forward hero: `node scripts/render.mjs film --film hero --hd --captions big && node scripts/assemble.mjs --film hero --hd --captions big --name shapr_hero_captions --exact`.

Renders run 4 Chromium workers in parallel; each scene is its own segment and is re-rendered only when
its inputs change (scene code, shared modules, CSS, tokens, story data, timeline entry, narration timing).

## How it fits together

```
timeline.json          one source of truth: scene order, durations (whole beats at 104 bpm), marks,
                       narration cues, statements, concept-pill ranges, sound cues, music sections
tokens.css             every colour, radius, shadow and type size (Shapr's own values from DesignSystem.swift)
src/motion.js          easing curves, spring, durations, keyframes, reading-time rule, typing, cursor paths, arcs
src/stage.js           desktop, menu bar, windows, virtual camera, cursor, statements, captions, concept pill
src/apps.js            generic app reconstructions (Code, Terminal, Browser, Preview, Mail, Messages, AI chat)
src/ui.js              Shapr surfaces reconstructed from the Swift views, plus the Shapr Flow concept surfaces
src/cues.js            narration → caption chunks (shared by the page and the SRT/VTT builder)
scenes/*.js            one module per scene: build once, then update(t) for any time t
assets/demo-data/      the fictional project: story.json plus real files (db.js, .env, terminal log, docs, email)
scripts/               render, assemble, captions, validate, docs, audio/{narration,score}.py
```

A scene is `export default async (ctx) => (t) => { … }`. It reads its choreography times from `marks` in
the timeline, so sound cues and picture use the same numbers.

## Changing things

- **Narration text or timing:** edit the `narration` cues in `timeline.json`, then `npm run audio`, `npm run captions`, `npm run docs`, re-render (captions are burned in) and assemble.
- **A human voice:** drop one WAV per line, named by cue id, into `assets/audio/narration/human/` (see `script.md` for ids and room per line), then `npm run audio` and assemble. No re-render needed unless a line runs longer than its room.
- **Scene length or order:** edit `films.<film>.entries` (keep durations in whole beats: 0.5769 s each). An entry can excerpt a scene with `from` and `dur`, override `narration`, `statements`, `concept`, `music`.
- **On-screen text:** statements live in the timeline; every product string lives in `assets/demo-data/story.json`.
- **Music:** `scripts/audio/score.py` (sections `tension`, `reveal`, `theme`, `flow`, `resolve`, `intro`; progression and arpeggios at the top; `musicDrop` ranges in the timeline make room for silence).
- **Sound effects:** `sfx()` in the same file; cues by name in the timeline.
- **Brand:** `tokens.css`. Clay (`--clay`) marks what ships today; violet (`--violet`) is reserved for Shapr Flow concepts. The menu-bar mark is `shaprGlyph()` in `src/stage.js`; the end card is in `scenes/s12_resume.js`.
- **A new scene:** add `scenes/<id>.js`, an entry under `scenes` (marks, narration, statements) and a film entry.

## Honesty rules the code enforces

- Shapr Flow scenes carry the violet "Shapr Flow · concept" pill for every frame (`concept` ranges in the timeline); nothing else does.
- No benchmarks, speeds, testimonials or security guarantees anywhere. "On this Mac" is used only where the code runs locally; Flow says "designed to".
- Forms are never submitted, the handoff is sent by the user, the database error is never solved.

See `feature-audit.md`, `authenticity-report.md` and `qa/report.md`.
