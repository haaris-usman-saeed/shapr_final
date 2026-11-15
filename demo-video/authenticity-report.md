# Authenticity report

**How the film was made.** No Mac was available, so Shapr was **not** built, run or screen-recorded. Every Shapr
surface in every film is **reconstructed from source**: layout, labels, colours and behaviour were read from the
Swift views and `DesignSystem.swift` and redrawn in HTML at 1.3× scale. None of the Swift features could be
verified by running them here; see `feature-audit.md`. The share server (`server/`) is the one component
verified in this environment (`node server/test.mjs`: 17/17 checks passed).

Categories used below:

- **R** reconstruction of implemented functionality (code exists in the repo; not run on a Mac by us)
- **R+ST** as R, and a self-test in the repo exercises it (`swift run Shapr --selftest`, not run here)
- **C** Shapr Flow concept (no code). Shown in violet with the "Shapr Flow · concept" pill on every frame.
- **Story** framing that shows no product capability (third-party apps, statements, cards)

Third-party apps (Code, Terminal, Browser, Preview, Mail, Messages, AI chat windows, an MCP "AI client") are
generic reconstructions identified by text title only. ChatGPT, Claude and Gemini are named only where the real
handoff feature names them.

## Hero film

| # | Scene | What it shows | Category | Notes and deviations |
|---|---|---|---|---|
| 1 | Problem | windows, tabs, an explanation typed twice | Story | |
| 2 | Meet Shapr | menu-bar icon; the real menu (abridged: header, Auto-sort, three packs, the four shortcut rows, the hint) | R | menu rows copied from `AppController.menuNeedsUpdate`; the icon is an original drawing standing in for SF Symbol `square.stack.3d.up.fill` |
| 3 | Circle | ⌘⌘, loop drawn around the error, lock, the corner card "Add to a pack / Ask about it", flight to the menu bar, "New pack" card | R+ST | **Stylised:** the app draws a short fading comet trail; the film keeps the whole loop visible so it reads on a projector, and springs it into a rounded rectangle (the app keeps the smoothed loop). The screenshot thumbnail travelling into the card is a film transition; the card itself (`offerShot`) appears in the top-right corner as in the app. Veil values (8% / 32%) match `CaptureOverlayView`. |
| 4 | Packs | ⌥C scoop with highlight, a quick circle, a link scoop, three capture flights, captures landing in the library, the wheel, "Equipped Aurora — Backend" | R+ST | Library window simplified (sidebar + cards with source line). Wheel geometry, labels and middle text from `Wheel.swift`. Chips arcing from the menu-bar icon into library cards is a film transition. |
| 5 | Getting things done | Draft for Mail → Insert; Fill form in Browser → fields filled, Submit untouched, "Filled 5 of 5 fields"; hold ⌥V "Save this to Aurora Backend" → saved | R+ST | Draft shown with ⌥⇧D (a classic shortcut, off by default; voice "draft a reply" is the default path). The spoken pack name follows the real command form "Save this to ‹pack›". |
| 6 | Handoff | "ChatGPT hit its message limit" card with "Continue in Claude" / "Gemini", structured handoff, preview in the message box, "Pasted into Claude. Check it, then press Return.", user presses send, "Claude got everything" | R+ST | The compact Goal / Rules / Tried / Evidence / Next card is a visual summary of the handoff text `Relay.build` produces (goal, next step, rules word for word, already tried, S1… notes). Claude opening as a second window rather than a tab is for legibility. |
| 7 | Connected | GitHub repo source "Updated just now"; Share Safely Keep / Replace / Remove on an email address; an AI client calling `read_pack` over MCP | R+ST | The MCP client is generic; the tool name and pack come from `MCPServer.swift`. |
| 8 | Flow: permission | session panel, per-app prompts, Messages blocked and greyed by Shapr, "Designed to process on this Mac" | **C** | macOS grants Screen Recording to Shapr as a whole, not per observed app; the film shows Shapr enforcing the user's choice itself. |
| 9 | Flow: Lens | circle, a concept action row with "Lens", the Lens card with three sourced lines | **C** | The circle and card are the shipping gesture; "Lens" and its card are concept. |
| 10 | Flow: Threads | event chips merge and drop; four lines in a compact card | **C** | |
| 11 | Flow: Simulate | two alternatives with advantage, tradeoff, source, open assumption (marked Unresolved) | **C** | Framed as scenario analysis, never prediction. |
| 12 | Resume + end card | "Welcome back." card, windows sliding back; end card | **C**, then Story | Kept as concept: the shipping Resume (`CheckpointViews`, "Continue in …") inserts a prompt and can reopen browser pages, but does not restore windows, and it could not be verified on a Mac. Its real fields (Working toward / Next) are what the card shows. |

## Trailer

Excerpts of hero scenes 3, 1, 4, 6, 8, 10, 12 with their categories unchanged; concept scenes keep the pill.

## Feature tour

| Chapter | Content | Category |
|---|---|---|
| 1 Capture | hero 3, hero 4 (first 7 s), file suggestion card ("docker-compose.yml · Add to …", Add / Other / Not here), duplicate card ("You saved this 20 minutes ago, so it wasn't added again", Show / Add anyway) | R+ST |
| 2 Packs | hero 4 (library, wheel), map of a pack | R+ST (map simplified from `GraphView`) |
| 3 Ask | Ask panel (status strings from `AskPanel`, "On-device model · 3 notes"), Ask about a screenshot, Use this with my pack (untick a source) | R+ST |
| 4 Speak | hold ⌥V, "Hold ⌥V and say things like" card (examples from `VoiceCommand.examples`, pack names swapped to Aurora) | R+ST |
| 5 Get things done | hero 5 (draft, form), pack picked by sender + facts/style chips, Vault field masked with "Unlocks with Touch ID when you fill", consent box left unticked | R+ST |
| 6 AI continuity | Save progress panel, hero 6, "Continue in Terminal" with "Since you saved this: 1 new capture · .env changed" | R+ST |
| 7 Connected | hero 7, "Live link · 3 joined" / "Joined · synced 2 min ago" | R+ST; live-share server side verified here |
| 8 Shapr Flow | hero 8–12 and session controls (pause, revoke, delete, expiry) | **C** throughout, pill on every frame |
| 9 Close | closing line, end card | Story |

Omitted from the tour because they are off-story or can't be shown clearly without a Mac: "Answer it" (homework
solving), Canvas/Quercus and Google Drive downloads, the updater, `.shapr` import/export dialogs (mentioned in the
audit, not shown), Settings.

## Claims

- No performance, accuracy or speed figures appear in any film. "about 900 tokens" in the handoff card is
  illustrative of the real card's format ("All N messages · about … tokens"), not a measurement.
- "On this Mac" appears only for the Ask status line and the Map caption (both from the app's own strings) and the
  Share Safely subtitle; Flow uses "Designed to process on this Mac". The film never says nothing leaves the device.
- The database error is never resolved; every summary only states what the demo data shows.
