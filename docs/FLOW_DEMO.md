# Shapr Flow — the TechniGala demo and the Mac test plan

## The story (about 3 minutes)

> The user worked normally. Shapr observed only what was authorized, understood enough to help, remembered useful things without storing an endless recording, and let them continue without re-explaining their work.

### Before you go on stage

1. Build and install: `scripts/build-app.sh --install`, then open Shapr. Accessibility and Screen Recording must be on (see the README).
2. Open `demo/taskboard-api` in VS Code, with its integrated terminal open.
   - This tiny project has no dependencies. `npm run dev` prints `Error: connect ECONNREFUSED 127.0.0.1:5433`, because `.env` points at the wrong port.
3. Have Safari ready, and Messages open with any conversation.
4. Delete any earlier rehearsal: **Privacy & memory… → Delete all Flow memory…**. Then quit and reopen Shapr.

### Scene 1 — Start working

Click the Shapr icon in the menu bar. The popover reads **SHAPR · Session off**. Click **Start working session**, and a green dot appears next to the icon.

Switch to VS Code. The prompt reads **"Allow Shapr to observe Visual Studio Code?"**. Choose **Allow for this session**. Do the same for Safari. When you switch to Messages, choose **Don't allow**.

> Say: "macOS gives Shapr Accessibility everywhere. Shapr narrows it to the apps I trust. It hasn't read anything from Messages."

### Scene 2 — Work normally

1. In VS Code's terminal, run `npm run dev`. The connection error appears.
2. In Safari, open the PostgreSQL documentation on connection strings, then a Stack Overflow answer about `ECONNREFUSED`.
3. Back in the terminal, run `brew services restart postgresql@16`, or any "fix" you like, then `npm run dev` again. The error is still there.
4. Circle the line `Don't change the production DATABASE_URL` in your notes and press **T**. Or just say it with ⌥V.

### Scene 3 — Shapr understands

Open the popover. It shows:
- **Current task: Fix: connect ECONNREFUSED 127.0.0.1:5433** (marked *inferred*: Shapr named it)
- What was tried, and that the error was still showing afterwards
- **Review** opens Threads: every item shows *observed* or *you said*, with its source (app, window, time). The two Safari pages are listed as sources.

> Say: "Every line here points to where it came from. Nothing from Messages, and Shapr didn't invent anything."

### Scene 4 — Lens

Double-tap ⌘, circle the error in the terminal, and press **L**. Lens shows what you circled, the context it picked (your rule, the restart you tried, the docs you read), and an answer written on this Mac.

> Say: "A screenshot tool would explain the error from scratch. Lens knows what I already tried."

### Scene 5 — Simulate

Circle the `DATABASE_URL` line in `.env` and press **S**. Two paths appear, for example "Run Postgres in Docker" and "Fix the port". Each path shows what it is *in line with*, any *possible tension* (the Docker path touches `DATABASE_URL`, so your rule is flagged), what was *tried before*, and open questions. The banner reads: *Scenario exploration — not a prediction*.

### Scene 6 — Stop and resume

In the popover, click **End**. The toast says the task summary was kept and temporary observations were cleared. Quit Shapr, reopen it, and click **Start working session**. **Continue where you left off?** appears:

- "Earlier today you were working on Fix: connect ECONNREFUSED…"
- "You … ran `brew services restart postgresql@16`."
- "“Error: connect ECONNREFUSED…” was still showing at 2:37 PM, after that."
- "Your next step was to check which port Postgres is listening on." (only if you said one)

Click **Continue**, then **Continue in an AI tool…**. The existing Resume panel opens with the task as a reviewed prompt.

### If something goes wrong on stage

- **Live reading fails** (an app exposes no text through Accessibility): open **Privacy & memory… → Play demo activity**. It feeds the same scripted session through the real engine: permission checks, redaction, de-duplication, grouping. Then continue from Scene 3.
- **No Mac at hand:** `swift run ShaprCoreChecks --demo` on any computer, or `Shapr --flow-demo`, prints the whole story from the real engine.

```
Scene 2 — Work normally (51 observations, scripted)
  kept 10 · duplicates folded 40 · refused 1
Scene 3 — Shapr understands
  Current task: Fix: connect ECONNREFUSED 127.0.0.1:5432 [inferred]
  Your rules:
    • Don't change the production DATABASE_URL (you said) ← Shapr
  Tried:
    • Ran `brew services restart postgresql@16` (observed) ← Visual Studio Code: db.js — taskboard-api — Visual Studio Code
    • I checked the credentials in .env and they match (you said) ← Shapr
  Errors seen:
    • Error: connect ECONNREFUSED 127.0.0.1:5432 (observed, ×3) ← Visual Studio Code: .env — taskboard-api — Visual Studio Code
  Sources: … | PostgreSQL: Documentation: 16: 34.1. Database C… | node.js - ECONNREFUSED when connecting to Postg… | …
  Other tasks: Work on blog
Scene 4 — Lens on the circled error
  [1] (your rules; you said · Shapr · 2:10 PM) Don't change the production DATABASE_URL
  [2] (errors seen; observed · Visual Studio Code · 2:37 PM) Error: connect ECONNREFUSED 127.0.0.1:5432 — seen 3 times
  [5] (tried; observed · Visual Studio Code · 2:12 PM) Ran `brew services restart postgresql@16`
Scene 5 — Simulate two approaches
  Path: Run Postgres in Docker and point DATABASE_URL at the container
    ! your rule may rule this out: Don't change the production DATABASE_URL
  Path: Keep local Postgres and fix the port it listens on
    + related note: Next step: check which port Postgres is listening on
Scene 6 — Stop, restart, continue
  Continue where you left off:
    Yesterday you were working on Fix: connect ECONNREFUSED 127.0.0.1:5432 (Shapr's name for it).  [inferred]
    You checked the credentials in .env and they match and ran `brew services restart postgresql@16`.  [observed, 2 sources]
    “Error: connect ECONNREFUSED 127.0.0.1:5432” was still showing at Tue 2:37 PM, after that.  [observed, 1 source]
    Your next step was to check which port Postgres is listening on.  [you said, 1 source]
```

---

## Mac test plan

These steps have **not** been run yet: the work was done on Linux, where AppKit can't be built. Record results in the pull request.

### Build and automated checks

```bash
swift build
swift run ShaprCoreChecks          # expect: All 81 Flow core checks passed.
swift run Shapr --selftest         # existing checks + the Flow checks + checkpoint mapping
swift run Shapr --flow-demo
scripts/build-app.sh
```

### Manual checks

| # | Do | Expect |
|---|---|---|
| 1 | Launch | The popover says *Session off*. No prompts, no reads. The **Resource use** section is empty |
| 2 | Right-click the icon | The classic menu, every item works. **More** in the popover opens the same menu |
| 3 | Start a session, switch to an app | After about 1 s, the permission prompt. Nothing from that app appears in Privacy & Memory → Memory |
| 4 | **Don't allow** Messages; use it for a minute | *Temporary* count unchanged; no task from it. It shows as *Blocked* |
| 5 | **Allow once** for Notes; switch away and back | Asked again |
| 6 | **This session** for VS Code; end the session; start a new one | Asked again |
| 7 | **Always allow** Terminal; quit; reopen; start | Not asked; observed |
| 8 | 1Password with any choice | Never observed (Resource use: no reads for it) |
| 9 | Pause during work | Amber dot; *Temporary* count stops changing; no reads in Resource use |
| 10 | Focus a password field in Safari | `reads.skipped.secure_field` increases |
| 11 | Chrome incognito window | `reads.skipped.private_window_or_no_page` increases |
| 12 | Run the demo project in the VS Code terminal and in Terminal.app | An error record ×N, a "Ran `…`" attempt for fix-like commands. Note which terminals expose text (they may differ) |
| 13 | Circle anything | The L/T/S bar under the circle. Keys L, T, S, A, Q and Esc work. Waiting 12 s saves the screenshot to the pack as before |
| 14 | L with Apple Intelligence on / off | An on-device answer / the deterministic list. *AI on this Mac only* is shown |
| 15 | Set *Claude when I ask*, then Lens → Ask Claude… | The consent card shows the exact text. Nothing is sent before **Send to Claude** |
| 16 | T, then right-click T → decision | A pinned record (*you said*). The capture is in the pack |
| 17 | S | Two paths, evidence links, the disclaimer, no numbers |
| 18 | End, quit, reopen, start | The *Continue where you left off* toast and popover card. Continue → Threads panel |
| 19 | Continue in an AI tool… | A checkpoint in the task's pack (author *Shapr Flow*); the Resume panel opens on it |
| 20 | Privacy → Delete its data (VS Code) | Its records and sources disappear; the inferred title resets |
| 21 | Delete task | Its Flow checkpoint file is removed from the pack |
| 22 | Claude Desktop with Shapr MCP: "what am I working on?" | `get_current_task` returns the summary. With sharing off, it declines |
| 23 | Sleep the Mac / lock the screen during a session | No reads until wake/unlock |
| 24 | VoiceOver on the popover, prompt and L/T/S bar | Every control is labelled; status isn't conveyed by colour alone |
| 25 | Reduce Motion, Reduce Transparency, light and dark | No scale animation on the bar; solid surfaces; readable in both themes |
| 26 | Activity Monitor during an hour of normal work | Record CPU% while idle and while working, and the read timings, in the PR |
