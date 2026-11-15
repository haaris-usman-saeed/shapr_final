# QA report

## Gate D: exports

Measured by `scripts/validate.py` (ffprobe, frame differences on a 96×54 downscale, ebur128, SRT checks).
"Dead air" = any stretch over 2.5 s where the frame 1 s later is nearly identical. "Spikes" = a single frame that
differs from both neighbours while the neighbours match. Contact sheets: `qa/sheet-<export>.png`.

| File | Duration | Resolution | fps | Video | Audio | Loudness | Dead air | Spikes | Captions | Result |
|---|---|---|---|---|---|---|---|---|---|---|
| `shapr_feature_tour.mp4` | 6:03.17 | 1920×1080 | 30/1 | h264 High yuv420p | aac 48000 Hz 2ch | -16.0 LUFS / -1.4 dBTP | 0 | 0 | 57 | PASS |
| `shapr_hero_1080p.mp4` | 3:21.40 | 1920×1080 | 30/1 | h264 High yuv420p | aac 48000 Hz 2ch | -16.0 LUFS / -1.5 dBTP | 0 | 0 | 27 | PASS |
| `shapr_hero_4k.mp4` | 3:21.40 | 3840×2160 | 30/1 | h264 High yuv420p | aac 48000 Hz 2ch | -16.0 LUFS / -1.5 dBTP | 0 | 0 | 27 | PASS |
| `shapr_hero_captions.mp4` | 3:21.40 | 1920×1080 | 30/1 | h264 High yuv420p | aac 48000 Hz 2ch | -16.0 LUFS / -1.5 dBTP | 0 | 0 | 27 | PASS |
| `shapr_trailer_60s.mp4` | 1:00.00 | 1920×1080 | 30/1 | h264 High yuv420p | aac 48000 Hz 2ch | -16.0 LUFS / -1.5 dBTP | 0 | 0 | 6 | PASS |

## Gates A–C: visual review

What was looked at, what was wrong, what changed. Images referenced are in this folder.

## Gate A: style frames (`gate-a/*.jpg`, rendered at 3840×2160)

| Frame | Verdict | Notes |
|---|---|---|
| Cluttered desktop (s01 3.7 s) | pass | Busy on purpose; newest window full contrast, older ones receded. Caption sits over terminal text in this one beat; accepted because it is the "chaos" shot. |
| Shapr menu on a clean desktop (s02 7.5 s) | pass after fix | First pass: the menu opened off the right edge and the dim turned the paper desktop muddy brown. Fixed: menu clamped inside the screen like a real macOS menu, dim reduced to 14%. |
| Circle mid-draw (s03 3.45 s) | pass | Pressure-varying clay stroke, glow under 12 px, pen dot at the head, real hint "⌘ ⌘ double-tap". |
| Threads card (s10 14 s) | pass after fix | Dark terminal behind the card read as a grey blob: removed from Flow backgrounds. Labels raised to 16 px, values to 23 px so they read at the final camera scale. |
| End card (s12 17.5 s) | pass after fix | Cursor was visible on the end card: hidden. |

Display face: Instrument Serif chosen over Fraunces for statements (calmer at 112 px, tighter, reads as editorial rather than quirky); Fraunces kept for in-app serif titles ("Welcome back.", pack names) where the app itself uses a serif.

## Gate B: animatic (`sheet-shapr_hero_proxy.png`, proxy MP4 with audio)

- Sound off: statements plus captions carry the whole story; act change to violet is legible from the chapter card and the pill.
- Fixed: "Meet Shapr" narration collided with the statement (split into two cues, statement moved to the downbeat at 1.154 s); the last narration line overlapped the end card (moved earlier); captions overlapped the concept pill in the Flow act (caption width capped at 1080 px).
- Timing: no beat drags; the longest single holds are the Threads card (≈8 s, with narration) and the end card (≈7.5 s, required ≥3 s).
- Validator: no dead air (minimum change over any 1 s: 0.18 grey levels on a 96×54 downscale), no single-frame spikes, −16.0 LUFS, −1.5 dBTP.

## Gate C: per scene (`s04.png` … `s09s11.png`, `tour-panels.png`) and signature strips

| Scene | Found | Fixed |
|---|---|---|
| s03 circle | windows painted over the circle (z-index); loop too wide (included the stack trace); locked shape had chamfered corners (angle sampling); card text under 24 px; blur softened the circled text | stacking contexts; circle only the error line; rounded rect sampled by perimeter; camera moves to the card at 1.55×; no blur for corner cards |
| s03 strips (`strip-circle.png`, `strip-circle2.png`) | pass 1: 95% of the loop drawn in the first half of 900 ms (snap) | pass 2: quadratic ease-out, 33/63/82/94% at quarter points; spring close and 250 ms hold confirmed frame by frame |
| s04 packs | library window sat under the dim veil (washed out); wheel too small on screen | library moved to the Shapr layer; camera 1.75× on the wheel |
| s05 doing | panels clipped by the camera clamp; "Filled 5 of 5 fields" off-frame; duplicate ".env" tab | camera centres recomputed; editor tabs de-duplicated |
| s06 handoff | framing wandered, reply bubble off-frame, cursor "reading" below the preview | windows resized, camera path rebuilt, cursor path moved onto the preview |
| s07 connected | panels high in the frame; AI answer still typing at the statement | panels centred; typing speed doubled |
| s08 flow | caption collided with the concept pill | caption width cap |
| s09, s11 | pass; open assumptions visibly marked "Unresolved" | — |
| tour panels | dark terminal blobs behind dimmed panels | terminal hidden in those variants |
| key hints | crowded the caption zone | hints clamped above y = 790 |
| master encode | per-frame grain in 4K segments → ~180 Mbit/s | grain moved to the export encode only |

## Known issues and limits

- **No Mac.** Shapr was not built or run; every Shapr surface is a reconstruction from the Swift source. Labels were copied from the code, but small layout details (exact spacing, Liquid Glass refraction, SF Symbols) are approximations. The menu-bar icon is an original drawing standing in for `square.stack.3d.up.fill`.
- **Narration is synthetic** (Kokoro `af_heart`). It was checked by duration and phonemes ("Shapr" fed as "Shaper"), not by ear: this environment has no audio playback. A human read is recommended for the event; `script.md` lists every line with its id and the room available.
- **The music and effects were also not auditioned by ear.** They were checked objectively: no clipping, mix at −16 LUFS, true peak ≤ −1.4 dBTP, music ducked ~9 dB under narration.
- **End-card holds** (hero ~3.5 s, tour ~2.8 s) are deliberately near-static; the validator reports them as `final_hold`, not dead air.
- **Stylised moments** documented in `authenticity-report.md`: the full circle loop staying visible and springing into a rectangle; the thumbnail travelling into the corner card; captures arcing into the library.
- **Trailer, tour and caption-forward hero** are native 1080p renders (deviceScaleFactor 1), not downscaled from 4K; only the hero has a 4K master.
- **File sizes** are generous (hero 1080p ≈ 121 MB, tour ≈ 209 MB) because film grain is encoded at a high quality; re-encode with a higher CRF if a venue needs smaller files.
- Not delivered (optional extras): 15-second teaser, silent loop, vertical 1080×1920 trailer.
