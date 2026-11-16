# Review against the brief

Evidence: stills captured from the built app (`node scripts/capture.mjs --stills …`), browser tests
(`qa/test-report.json`, 17/17), validator output (`qa/validate-*.json`) and contact sheets (`qa/sheet-*.png`).

## Visual review passes (what was wrong, what changed)

| Area | Found | Fixed |
|---|---|---|
| Session popover | wordmark collided with the Memory Kernel card's class and rendered as a detached box | renamed (`.brand`) |
| Statements | cursor stayed visible over full-screen statements | statements hide and restore the cursor |
| Memory Kernel | big statement landed on top of the working-memory card, followed by an empty dark gap | card flies home first, darkness, then the statement |
| L/T/S selector | clipped at the right edge at 1.85× | anchored to the selection's left edge |
| Lens | sat low enough to collide with captions | placed beside and above the error |
| Evidence | switching to `.env` moved the terminal, leaving the circle around empty space | terminal pinned to the bottom of the editor |
| Threads → End session | "Checkpoint saved" toast overlapped the open popover | popover closes first; menu bar reads "Aurora · checkpoint saved" |
| Memory sheet | delete toast overlapped the sheet | inline confirmation inside the sheet |
| Simulate | small and cluttered over a busy desktop | larger cards, desktop receded |
| Interactive mode | an overlay layer swallowed clicks; window z-order rose above Shapr's layer; invisible lock overlays caught clicks; toasts stacked; Esc didn't close the popover; presenter panel covered the desktop | click-through layers, isolated window stack, inert overlays, single toast, Esc closes, panel toggles with D |
| Trailer | 2.5 s near-still after the Resume restore | slow camera push through the hold |

## Against the quality questions

- **Emotional impact.** The arc is one person's afternoon, evening and next morning; the Resume card is the centrepiece and reads as relief, not a feature.
- **Visual impact.** One accent, warm neutrals, translucent surfaces, no dashboards; every frame has one focal point (sampled stills in `qa/`).
- **Clarity.** Every beat has an on-screen line and a caption; works with sound off.
- **Novelty.** No chat window as the product; intelligence appears as a menu-bar presence, a selection, a card.
- **Engineering credibility.** The kernel is a real (simulated) algorithm with gates, TTLs, budgets, dedup, statuses and sources; outputs depend on state; denial is enforced and testable.
- **Privacy.** Shown, not said: per-app prompts with scopes, nothing flows from Messages, a contentless blocked count, pause, review, delete, and session-scoped permissions that end with the session.
- **Memory.** Three layers made visible, with expiry rings, repeats merging and source chips on every line.
- **Interaction.** 17 automated checks cover sessions, permissions, gating, kernel behaviour, free-hand circling, Lens, Threads, Simulate, pause/delete, resume, reset and layout.
- **Honesty.** "Shapr Flow · concept demonstration · synthetic data" on every frame; Simulate says "not a prediction" and shows unresolved assumptions; the bug is never fixed by Shapr.

## Known limits

- Narration and music were generated and measured, not auditioned by ear (no audio playback in this environment). A human read can replace any line (`public/audio/human/`).
- No Mac: Shapr itself was not run; nothing here is a screen recording.
- The demo's understanding is declared per synthetic event; it demonstrates the proposed behaviour, not a model's accuracy.
- Hero runtime is 3:41 (brief: about 3 minutes; the brief's own scene timings sum to about 4).
