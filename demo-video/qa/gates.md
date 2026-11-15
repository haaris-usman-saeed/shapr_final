# Review log (gates A–C)

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
