## Known issues and limits

- **No Mac.** Shapr was not built or run; every Shapr surface is a reconstruction from the Swift source. Labels were copied from the code, but small layout details (exact spacing, Liquid Glass refraction, SF Symbols) are approximations. The menu-bar icon is an original drawing standing in for `square.stack.3d.up.fill`.
- **Narration is synthetic** (Kokoro `af_heart`). It was checked by duration and phonemes ("Shapr" fed as "Shaper"), not by ear: this environment has no audio playback. A human read is recommended for the event; `script.md` lists every line with its id and the room available.
- **The music and effects were also not auditioned by ear.** They were checked objectively: no clipping, mix at −16 LUFS, true peak ≤ −1.4 dBTP, music ducked ~9 dB under narration.
- **End-card holds** (hero ~3.5 s, tour ~2.8 s) are deliberately near-static; the validator reports them as `final_hold`, not dead air.
- **Stylised moments** documented in `authenticity-report.md`: the full circle loop staying visible and springing into a rectangle; the thumbnail travelling into the corner card; captures arcing into the library.
- **Trailer, tour and caption-forward hero** are native 1080p renders (deviceScaleFactor 1), not downscaled from 4K; only the hero has a 4K master.
- **File sizes** are generous (hero 1080p ≈ 121 MB, tour ≈ 209 MB) because film grain is encoded at a high quality; re-encode with a higher CRF if a venue needs smaller files.
- Not delivered (optional extras): 15-second teaser, silent loop, vertical 1080×1920 trailer.
