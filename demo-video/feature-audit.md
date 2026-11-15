# Feature audit

Audited from `README.md`, `docs/DEMO.md`, `Package.swift` and `Sources/Shapr/*.swift` (22,195 lines) on branch `claude/brave-planck-1els25`, 2026-11-15.

## Environment limits that decide the classifications

- **No Mac was available.** The film was produced in a Linux cloud container. Shapr targets macOS 26 (`Package.swift: platforms: [.macOS("26.0")]`) and links Carbon, AppKit and SwiftUI, so it cannot be built or launched here, and `swift run Shapr --selftest` could not be run.
- **Consequence:** no Swift feature can honestly be classed "Verified working" by this audit. Where the repo contains a self-test that exercises a feature, that is noted ("self-test in repo, not run here"). Those features are the strongest "implemented" evidence available and are the only ones the film shows in clay.
- **One thing was verified here:** the share server (`server/`). `node server/test.mjs` ran in this container: **All 17 server checks passed** (share, join, live update, token-guarded writes, page escaping, stop-sharing deletes).
- Every Shapr UI in the film is **reconstructed from source** (Swift view code and `DesignSystem.swift`), not screen-recorded.

## Real details copied into the film

| Detail | Source | Value used |
|---|---|---|
| Circle trigger | `README.md`, `HotKeys.swift` comment, `CaptureOverlay.swift` | **⌘⌘** (double-tap Command); hover mode, *no clicking*; a short glowing trail; pause to lock; loop locks with a quick highlight (`lock()` waits 0.28 s before capture) |
| Circle veil | `CaptureOverlayView.draw` | light veil while circling (black 8%), outside of the loop dims to 32% once locked; locked loop = white 5.5 pt under-stroke + 3 pt accent stroke with 8 pt glow |
| After the circle | `AppController.offerShot` | corner card, eyebrow **Screenshot**, preview image first, subtitle "Add it, or ask your packs about it. Or hold ⌥V and ask.", buttons **Add to ‹pack›** (primary) and **Ask about it** |
| Scoop | `README.md` | **⌥C** |
| Talk to Shapr | `README.md`, `AppController` quick item | **hold ⌥V** |
| Wheel | `Wheel.swift` | **hold ⌥S**; one glass dial, 6 places (ring r=150, centre r=58), each a small dot of pack colour over its name; middle shows "Auto-sort / On" or the pack; hint "1–6 equip · A auto · N new · ? ask"; empty slot shows "+ New pack" |
| Capture flight | `CaptureFeedback.landed` | capsule chip (pack orb + title) flies to the menu-bar icon (0.12 s fade-in, 0.45 s move, curve 0.5,0,0.2,1); icon ticks (`checkmark.circle.fill`) |
| Menu-bar icon | `AppController` | SF Symbol `square.stack.3d.up.fill` (drawn as an original stacked-layers glyph) |
| Toast cards | `Panels.swift ToastView` | 340 pt wide, 22 pt radius glass, top-right, title 13.5 semibold, meta 11.5 |
| Panels | `DesignSystem.swift` | 24 pt radius glass, header + Raycast-style footer with keycaps: **Cancel esc · Copy ⇧⌘C · Insert ⌘↩** |
| Draft | `Drop.swift` | "Draft for ‹app›", "Based on N captures", **Insert ⌘↩**; nothing pasted until you click |
| Form fill | `FormFill.swift`, `README.md` | "Fill form in ‹app›", sections "From your packs" / "From your Vault"; **Shapr never presses Submit** |
| Checkpoint | `CheckpointViews.swift` | Save progress: Goal, Next step, "Your rules, word for word", Decisions, Already tried, Open questions; Resume card: **Working toward**, **Already decided**, **Next**, Sources; "Since you saved this: …" |
| Handoff | `Relay.swift`, `RelayController.swift` | Goal / Next step / "My rules (in my own words; follow them exactly)" / Already tried / notes as S1, S2 / `@shapr`; toast "Pasted into ‹AI›. Check it, then press Return."; read-back "‹AI› got everything" |
| Safe Share | `ShareReview.swift` | Keep / Replace / Remove per finding; "Choices here change only the shared copy… Shapr checks on this Mac; nothing is uploaded." (in-app claim about the scan only) |
| MCP | `README.md`, `MCPServer.swift` | `list_packs`, `read_pack`, `search_captures`, `add_to_pack`, `save_checkpoint`, `get_checkpoint`; `Shapr --mcp`, local, reads/writes `~/Shapr/Packs` |
| Tokens | `DesignSystem.swift` | canvas `#F7F6F2`, panel `#FFFFFF`, text `#1F1E1C`, text2 `#5A5852`, accent `#A44A22`, accentFill `#B5562D`, accentSoft `#F6EAE3`, success `#1C7945`, danger `#C2352D`, line 10%; radii 9/14/24; serif for titles only; pack orbs = flat colour circle with initials |

## Network paths (why the film never says "nothing leaves your Mac")

`ClaudeClient.swift` (Anthropic API when a key is set), `Sources.swift` (GitHub, Notion, public pages), `SharedPacks.swift` (share server), `Updater.swift` (update checks), `FileCapture.swift` (downloads circled links), `Relay*` (opens AI sites in the browser). The film uses "on this Mac" only for steps the code runs locally (OCR, speech-to-text, Safe Share scan, sorting with the on-device engine) and "local-first" / "designed to" for everything else.

## Classification

Legend: **V** verified working · **I** implemented, unverified · **P** partially implemented · **C** proposed concept. "ST" = a self-test in the repo exercises it (not run here).

| # | Feature | Class | Evidence | Scene |
|---|---|---|---|---|
| 1 | Text capture by shortcut (⌥C scoop) | I (ST: Front matter, Disk, Auto-sort) | `CaptureService`, `AppController.scoop` | Hero 4 (doc passage), Tour 1 |
| 2 | Circle-to-capture (⌘⌘) | I (ST: Hover circle) | `CaptureOverlay.findLoop`, `DoubleTapDetector` | Hero 3 (signature 1), Trailer 0:00, Tour 1 |
| 3 | Screen capture + OCR | I (ST: Screen capture, OCR read) | `ScreenCapture`, Vision OCR | Hero 3/4, Tour 1 |
| 4 | Context packs + automatic sorting | I (ST: Auto-sort) | `Sorter`, `PackStore` | Hero 4, Tour 2 |
| 5 | Radial pack wheel | I (ST: Wheel) | `Wheel.swift` | Hero 4, Tour 2 |
| 6 | Voice commands and voice notes | I (ST: Talk to Shapr, Voice notes, Voice first) | `VoiceCommands`, `VoiceNotes` | Hero 5, Tour 4 |
| 7 | On-device processing, optional Claude | I | `Sorter` engines, `ClaudeClient`; README "Engines" | Tour 3 (stated carefully) |
| 8 | Source-grounded Q&A (Ask) | I (ST: Ask the pack) | `AskPanel`, `AskEngine` | Tour 3 |
| 9 | Context-aware drafting (Drop) | I (ST: Drop) | `Drop.swift` | Hero 5, Tour 5 |
| 10 | Facts packs + style packs | I (ST: Facts pack + style pack) | `Drop`, `PackAssist` | Tour 5 |
| 11 | Form filling, never submits | I (ST: Form fill) | `FormFill`, `FormScanner` | Hero 5, Tour 5 |
| 12 | Sensitive-information Vault | I | `Vault.swift` (Keychain, Touch ID) | Tour 5 (masked only) |
| 13 | AI conversation handoff (Relay) | I (ST: Moving between AIs; Handing over a whole chat) | `Relay`, `RelayController`, `ChatReader`, `ChatCompactor` | Hero 6 (signature 5), Trailer, Tour 6 |
| 14 | Checkpoints + resume | I (ST: Save progress → Resume) | `Checkpoints`, `CheckpointViews` | Hero 12 (resume card), Tour 6 |
| 15 | Live sources and sync | I (ST: Live sources) | `Sources.swift` | Hero 7, Tour 7 |
| 16 | File suggestions | I (ST: File suggestions) | `FileSuggestions` | Tour 2 |
| 17 | Context-aware pack selection | I (ST: Picking the pack) | `Routing.swift` | Tour 2 |
| 18 | MCP server | I (ST: MCP server) | `MCPServer.swift` | Hero 7, Tour 7 |
| 19 | Safe sharing (Safe Share) | I (ST: Safe Share) | `PrivacyScanner`, `ShareReview` | Hero 7, Tour 7 |
| 20 | Live shared packs | **P/V split**: server side **V** (17/17 checks run here); app side I (ST: Shared pack links) | `SharedPacks`, `server/` | Tour 7 |
| 21 | Pack import/export (.shapr, .md) | I (ST: Export, .shapr files) | `Exporter`, `PackBundle` | Tour 7 |
| 22 | Source graph ("Map of a pack") | I (ST: The map of a pack) | `GraphView.swift` | Tour 2 (brief) |
| 23 | Use this with my pack (⌥⇧U) | I (ST: the demo flow) | `UsePanel` | Tour 3 |
| F1 | Shapr Flow: user-started working sessions | **C** | no code | Hero 8, Tour 8 |
| F2 | Per-app permission controls enforced by Shapr | **C** | no code (macOS Screen Recording is all-or-nothing per app *granted to Shapr*, not per observed app) | Hero 8, Tour 8 |
| F3 | Local-first Memory Kernel | **C** | no code | Tour 8 (named only) |
| F4 | Task understanding | **C** | no code | Hero 9–10 (implied) |
| F5 | Lens | **C** | no code | Hero 9, Tour 8 |
| F6 | Threads (portable working memory) | **C** | no code | Hero 10 (signature 3), Trailer, Tour 8 |
| F7 | Simulate | **C** | no code | Hero 11 (signature 4), Tour 8 |
| F8 | Unobtrusive assistance | **C** | no code | Tour 8 |

`grep -riE 'lens|simulate|memory kernel|ambient|per-app'` over `Sources/` finds nothing related to Flow; all eight are concepts.

## Consequences for the film

- Clay (ships-today accent) is used only for rows 1–23, all of which have code in the repo; the authenticity report marks them "reconstruction of implemented functionality, unverified on a Mac".
- Violet + the **Shapr Flow · concept** pill is used for F1–F8 for every frame they are on screen.
- Hero beat 12 (resume): the *welcome-back* popover and the windows sliding back are Flow-style presentation; the real Resume card (`CheckpointViews`) shows Working toward / Already decided / Next and inserts a prompt. The film shows the real card's fields in clay and does not claim windows restore themselves (the real feature offers **Reopen N pages** for browser tabs only). See `authenticity-report.md`.
- Omitted from the film: "Answer it" (homework solving) and Quercus/Canvas downloads (off-story), the updater (not user-facing), private live links (not built).
