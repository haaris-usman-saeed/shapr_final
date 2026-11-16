# Technical explanation: what is real, what is simulated, what needs engineering

## In one paragraph

This demo runs a deterministic **simulation** of the proposed Shapr Flow algorithms over **synthetic,
pre-labelled observations**. Nothing here observes your computer, reads real screens, or calls an AI model.
Shapr Flow itself (sessions, per-app observation, the Memory Kernel, task understanding, Lens, Threads,
Simulate, Resume-by-session) is **not implemented** in the Shapr repository. The foundations it would build on
(circle capture, OCR, packs, checkpoints, local AI, handoff) are; see `../demo-video/feature-audit.md`.

## What the demo actually computes

`src/state/kernel.ts` processes each synthetic observation exactly as the concept describes:

1. **Session gate.** No active session, or paused → `ignored`.
2. **Permission gate.** The app isn't allowed → `blocked`. Nothing about the event is stored except a count.
   "Allow once" is consumed by one event; "Allow this session" ends with the session; "Always" persists.
3. **Repetition.** The same information key (for example the same error, the same doc page) → `duplicate`: the existing
   item's count goes up and its expiry is refreshed.
4. **Relevance.** Events marked unrelated (the dining-menu tab, opening the editor) → kept briefly as `noise`, then expire.
5. **Immediate memory.** Retained events live for a fixed TTL (90 s of demo time, 12 s for noise) and a budget of 6 items.
6. **Working memory.** An event's declared effect updates Goal / Tried / Current issue / Next, **with its source reference**.
   Each line carries a status: observed, inferred, or confirmed by the user.
7. **Task inference.** After 3 retained signals including a blocker, Shapr proposes a task (status *inferred*);
   the user confirms it. A next step is proposed from evidence it's allowed to use.
8. **Long-term.** Session end writes a checkpoint; pinned findings (Threads) and confirmed facts stay.
9. **Delete.** Removes immediate memory and decisions; keeps only what was checkpointed or pinned.

Lens, the Resume card and Simulate are **computed from that state**, so they change with permissions:
with Safari denied, Lens says documentation from Safari isn't used and cites no docs (verified by `scripts/test.mjs`).

The "meaning" of each observation is written into `src/demo-data/aurora.ts`. The demo does **not** infer it from
pixels, and the film never claims that arbitrary actions can be reliably inferred from screen content.

## What the film shows vs what exists

| Shown | Status |
|---|---|
| Circle gesture (⌘⌘), selection lock | **Exists** in Shapr (`CaptureOverlay.swift`); the L/T/S selector on top of it is concept |
| Screen/window text extraction, OCR | **Exists** (Vision OCR, `WindowText.swift`) |
| Checkpoints with goal / tried / next | **Exists** (`Checkpoints.swift`); automatic checkpointing at session end is concept |
| Local model / optional Claude | **Exists** (on-device model default; Claude with the user's key) |
| Handoff to an AI assistant with review before sending | **Exists** (`Relay.swift`); "share context with coding assistant" at resume is concept |
| Sessions, per-app permission prompts, pause | **Concept**. Note: macOS grants Screen Recording to Shapr as a whole, not per observed app; Shapr would have to enforce per-app choices itself, which is what the film shows |
| Memory Kernel (immediate / working / long-term, expiry, dedup, budgets) | **Concept**, simulated here |
| Task understanding, observed vs inferred vs confirmed | **Concept**, simulated with declared effects |
| Lens | **Concept** |
| Threads (background working memory, pinning) | **Concept**; pinning resembles adding to a pack today |
| Simulate | **Concept**. Scenario exploration by a language model in the real product; here, fixed alternatives with evidence chips and open questions, no probabilities |
| Resume: reopening files and pages | **Concept**: reopens files/URLs Shapr has references to. It does not restore unsaved editor state or other apps' internal state |
| "Designed to process on this Mac" | Design intent. Today, Shapr's on-device engine is local but Claude, live sources, sharing and updates use the network |

## Engineering still required for a real Shapr Flow

- An app-scoped observation layer (Accessibility tree + window text, per-app allow-list enforced before anything is
  read or stored), with a visible session indicator and a hard pause.
- Event extraction from real activity (file opened, error printed, page read) with confidence, and a way to show
  uncertainty and correct it.
- The Memory Kernel as a local store with TTLs, budgets, dedup keys, source references and deletion guarantees.
- Task inference with a local model, and user confirmation as a first-class signal.
- Lens / Simulate prompting grounded only in authorised memory, with citations and refusal when evidence is missing.
- Resume: a registry of reopenable resources (file paths, URLs, terminal commands) per checkpoint.
- Evaluation: precision of retained context, leakage tests for blocked apps, deletion verification, latency and cost.

## How the presentation is built

- **One clock** (`src/engine/clock.ts`) drives everything: real time in the browser, stepped frame by frame for video.
  Scripts `await wait(ms)` on it; tweens are evaluated against it. Seeking a scene replays the story in fast-forward,
  so every scene starts from the state the story produced. Autoplay and interactive mode share `src/state/store.ts`.
- **The cursor clicks real elements**: autoplay moves a drawn cursor to the element and calls its real click handler,
  the same one a presenter's click triggers.
- **No external services**: no network calls at runtime. Fonts are inlined; audio is local files.
