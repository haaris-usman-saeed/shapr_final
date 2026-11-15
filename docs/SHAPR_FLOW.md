# Shapr Flow — architecture and memory specification

> Shapr understands your work so you don't have to explain it again.

Shapr Flow adds **working sessions** to Shapr. You start a session from the menu-bar icon, decide which apps Shapr may observe, and keep working. Shapr keeps a small, evidence-backed picture of the task you're on (goal, rules, attempts, errors, open questions, next step). Circling something on screen then gives you three actions: **L**ens (understand), **T**hreads (remember) and **S**imulate (explore). When you come back later, **Continue where you left off** shows what you were doing without you re-explaining it.

Related documents: [privacy specification](FLOW_PRIVACY.md) · [TechniGala demo and Mac test plan](FLOW_DEMO.md)

---

## 1. Technical assessment (audit of the existing app)

**Reused as is**
- Circle gesture and capture: `CaptureOverlay`, `ScreenCapture` (ScreenCaptureKit + Vision OCR), `ScreenSource`. The circle stays Shapr's entry point; Flow only replaces the card that appears afterwards.
- Accessibility reading: `ChatReader.attr`. The read-only, time-boxed approach from `WindowText`.
- Checkpoints (`Checkpoint`, `PackStore.saveCheckpoint`), Resume (`ResumeController`, `HandoffBuilder`), Relay and MCP. A Flow task becomes a normal checkpoint, so ⌥⇧R, `get_checkpoint` and Relay all work with it.
- Packs as the source archive (level 5). Threads saves the capture to a pack exactly as **Add** does.
- `ToastController`, `FloatingPanel`, the design system (`DS`, `dsPanel`, `PanelHeader`, `glassSurface`).
- The on-device model (FoundationModels) used the same way as in `PackAssist` and `Checkpoints`, and `ClaudeClient.stream` for optional cloud answers.

**Extended**
- `AppController`: status-item click → popover (right-click → the classic menu); `offerShot` → the L/T/S bar; a session dot on the menu-bar icon; save on quit.
- `ResumeController.open(preferring:)`: opens the Flow task's pack first.
- `MCPServer`: a read-only `get_current_task` tool.
- `SelfTest`: runs the Flow checks. `main.swift`: `--flow-demo`.
- `SettingsView` → Privacy: a link to Flow's Privacy & Memory window.

**New**
- `ShaprCore` (Foundation only; builds and is tested on any platform):
  - `FlowModels`
  - `FlowText`
  - `FlowPrivacy` (sensitive apps, redaction, salience)
  - `ObservationPolicy` (app authorization + session tickets)
  - `MemoryKernel`
  - `MemoryRetrieval` (context packages, summaries, Simulate, suggestions, metrics)
  - `FlowStore`
  - `FlowEngine` (the facade)
  - `FlowDemo`
  - `FlowCoreChecks`
- App: `ActivityObserver` (+ `FlowReader`), `FlowController`, `FlowViews` (popover, permission prompt, L/T/S bar, Lens/Threads/Simulate panel, Privacy & Memory window).

**Already persisted before Flow:** packs as Markdown in `~/Shapr/Packs`, checkpoints as JSON in each pack's `.shapr/checkpoints`, settings in UserDefaults, secrets in the Keychain.

**Flow adds:** `~/Library/Application Support/Shapr/Flow/{memory,permissions,settings}.json`.

**Privacy mechanisms that already existed:** Safe Share's `PrivacyScanner`, the Keychain Vault, and Accessibility and Screen Recording permission gates. Flow adds its own app-level authorization on top of these (see the privacy spec).

**Workflows that could have broken, and how they're protected**
- **The screenshot card.** It's replaced by the L/T/S bar, but **Add** (A) and **Ask** (Q) are still one key away, and doing nothing still saves the screenshot (12 s on the bar, 45 s fallback). Setting `defaults write app.shapr.Shapr flowCircleMenu -bool NO` restores the old card.
- **The status-item menu.** It now opens on right-click, Control-click, or **More** in the popover. Every item is unchanged.

**macOS permissions**
- No new system permissions are needed. Flow uses Accessibility (already required) and Automation for browsers (already requested by capture).
- It does **not** use Screen Recording for background observation; screenshots happen only when you circle.

**Needs deeper app integration to do reliably** (not attempted)
- Reading editor buffers or terminal output in apps that don't expose them through Accessibility, for example some VS Code terminal configurations.
- Detecting Safari private windows (AppleScript can't tell them apart).
- Knowing whether a fix "worked" (Shapr only sees whether the error appears again).
- Restoring arbitrary third-party app state on resume. Browser tabs are reopened through the existing `BrowserTabs`.

---

## 2. Architecture

```
          macOS (Sources/Shapr)                                 ShaprCore (any platform)
 ┌────────────────────────────────────┐            ┌────────────────────────────────────────────┐
 │ NSWorkspace activation, AX window/  │  bundle ID │ FlowEngine                                 │
 │ title notifications, sleep / lock   │ ─────────▶ │  ├ FlowSession   off/active/paused/ending  │
 │            ActivityObserver         │ ◀───────── │  │               + epoch tickets           │
 │  (debounce, throttle, settle)       │  decision  │  ├ AppAuthorizationStore  denied wins      │
 │        │ ticket                     │            │  │   once/session in RAM, always/denied    │
 │        ▼ (background thread)        │            │  │   on disk; password managers never      │
 │ FlowReader: title, AXDocument, URL, │            │  ├ MemoryKernel  (pipeline below)          │
 │ salient lines only (errors, shell   │  event +   │  ├ MemoryRetrieval / TaskSummary /         │
 │ commands); skips secure fields,     │  ticket    │  │   ScenarioExplorer / SuggestionEngine   │
 │ incognito, password windows         │ ─────────▶ │  ├ FlowStore  memory.json (atomic)         │
 │                                     │            │  └ FlowMetrics                             │
 │ Circle → FlowActionBar (L/T/S)      │            └────────────────────────────────────────────┘
 │  Lens → context package → on-device │                        │ portableTaskSummary (read-only)
 │         model | deterministic |     │                        ▼
 │         Claude after consent        │              MCP get_current_task (separate process)
 │  Threads → remember (pinned) + pack │
 │  Simulate → deterministic compare   │      Flow task ──▶ Checkpoint ──▶ ResumeController / Relay
 └────────────────────────────────────┘
```

**The permission boundary is checked twice, before and after every read.**
1. `FlowEngine.decision(for:)` uses only the bundle identifier. Anything other than `.observe` means no read happens; `.ask` shows the prompt.
2. `FlowEngine.ticket(for:)` issues a ticket tied to the session **epoch** and the app's activation.
3. The read runs off the main thread.
4. `FlowEngine.submit(event, ticket:)` throws the result away unless the ticket is still current *and* the app is still authorized. Pause, end, revoke, sleep and screen lock all bump the epoch.
5. `MemoryKernel.ingest` checks authorization again (defence in depth) before any content is processed.

**Threading.** The engine runs on the main actor. Its work per observation is small, bounded string processing (measured below). Accessibility walks and AppleScript run on background threads, and AppleScript runs one call at a time on a serial queue. Disk writes run on a background serial queue.

**Failure isolation.**
- If Flow memory can't be read, the file is moved aside (`memory.unreadable.json`) and Flow starts empty. A file written by a newer version is never overwritten.
- Every other Shapr feature works with Flow off.
- A session is **off at every launch**.

---

## 3. Memory specification

### Pipeline

```
Observe → session active? → app authorized? → ticket still current? → private window? → redact secrets
→ de-duplicate (fingerprint, 20 min) → salience (errors, fix-like commands) → task grouping
→ update task state (provenance + evidence) → consolidate (every 25 kept events, on pause/end) → retain or expire
```

### Levels

| Level | What | Where | Lifetime | Budget |
|---|---|---|---|---|
| 1 Immediate | Recent permitted observations: app, window title, document, page address, salient lines | **RAM only** | 20 min TTL; kept while paused, cleared at session end | 200 events, 256 KB |
| 2 Working | Task state (`TaskState`) and records (`MemoryRecord`): goal, rules, decisions, attempts, errors, open questions, next step, notes, sources | `memory.json` | Until evicted by budget, deleted, or task dropped | 60 records/task, 12 per kind, 5 evidence refs/record, 20 sources, 40 keywords, 30 tasks |
| 3 Episodic | Copies of what mattered when a session ended (`Episode`) | `memory.json` | 30 days by default (7/30/90 in settings) | 60 episodes; file ≤ 1.5 MB |
| 4 Knowledge | Records the user pinned (everything saved with Threads, rules) | `memory.json` | Never forgotten automatically | Exempt from eviction |
| 5 Source archive | Screenshots, files and captures the user saved | Packs (`~/Shapr/Packs`) | Owned by the user; consolidation never touches them | — |

### Relevance (deterministic, no model)
- **Error lines.** Pattern-based (`error`, `exception`, `refused`, `ECONN…`, `failed`, `not found`, HTTP 4xx/5xx…). Panel headers like "Problems" don't count.
- **Shell commands** come from prompt lines. Only *fix-like* commands (restart, install, migrate, export, `brew services`, `git checkout`…) become **attempts**. Re-running `npm run dev` reproduces an error; it isn't a fix.
- **Pages and documents** become task **sources** only when they match the task (below).
- **Everything else in a window is discarded inside the reader.** Ordinary text never reaches memory.

### Task grouping (conservative)

| Signal | Score |
|---|---|
| Same project or repository (`proj:`/`repo:` from the title, AXDocument's project folder, or a GitHub URL) | +3 |
| A *different* project | −3 (never merged on words alone) |
| Same file or localhost port | +2 |
| Shared terms with the task (≥2 terms, ≥34% overlap) | +2 |
| …or a weaker overlap | +1 |
| The task is active and the activity is within 10 minutes of it | +1 |
| Shares words with the task's latest error ("looking it up") | +1 |

- **≥3** attaches the activity to the task.
- **2** with content asks **"Is this part of X?"**, at most once per 10 minutes and never twice about the same thing. The answers are Yes, Separate task, or Ignore.
- **Lower**: a new task starts only if the activity has a project identity or an error. Otherwise it stays in immediate memory and expires.
- **User-confirmed links always win.**

### Provenance (never upgraded by compression)
`userConfirmed` > `userStated` > `observed` > `inferred` > `hypothesis`.

- Every record keeps the provenance it was created with.
- Merging only combines records of **equal** provenance.
- Only new, stronger evidence, or the user's own confirmation, raises it.
- Task titles Shapr makes up (e.g. "Fix: connect ECONNREFUSED…") are `inferred` and shown as such.
- Text quoted on screen ("We decided to use MySQL") is never turned into the user's decision or rule.

### Consolidation and budgets

Consolidation runs on thresholds, pause and end, never continuously. It:
1. expires immediate memory;
2. merges near-duplicates (same task, kind and provenance, ≥85% term overlap);
3. trims each task by **utility**: superseded < guesses < old one-off observations < the user's words. Pinned items are never trimmed.
4. trims tasks, sources and keywords;
5. drops expired episodes, then the oldest unpinned episodes until the file is under 1.5 MB.

### Summaries are derived, never stored
The task summary, the resume card, Lens context and the MCP summary are all **computed from records when they're shown**. There is no cached summary or embedding that could keep deleted data alive.

The resume card states only what records support. It says "was still showing at 2:37 PM, after that" when the error reappeared after the last attempt. If the error wasn't seen again, it says "Shapr didn't see whether it's fixed". It never says "fixed" or "resolved".

### Deletion
`purge(where:)` removes matching observations, records and episode records, plus the task sources from that app. It then **rebuilds** each task's keyword index and app list from what remains, and resets a task title inferred from deleted evidence.

Deleting a task also deletes the checkpoints Flow wrote for it. The available controls:
- Delete an app's data
- Delete a session's data
- Delete a task
- Clear temporary memory
- Delete all Flow memory (packs are untouched)

### Retrieval (Lens, handoffs)
- The pool is the active task's records, plus its episodes, plus the **same error** from other tasks. Nothing else crosses tasks.
- **Ranking** uses term IDF and kind weight (rules > goal > decisions > open questions/attempts/next step > errors), plus a pinned bonus and gentle recency.
- **Excluded:** superseded records, and anything from an app that is *now* blocked.
- **Budget:** a character budget, default 3,500 for Lens. Every item carries its kind, provenance, app and time.

---

## 4. L / T / S and continuity

**Lens.**
- Shows what you circled, the context items it picked (each with a checkbox, provenance and source), and an answer.
- The answer is written on this Mac by Apple Intelligence when it's available. Otherwise it's a deterministic list of what your memory says.
- **Ask Claude…** appears only if Flow processing is set to "Claude when I ask" and a key exists. It shows the exact text that will be sent (and asks whether to include the screenshot) before sending.

**Threads.**
- **T** remembers the selection on the active task: pinned, in your words, kind inferred from wording.
- Right-click T for *decision*, *something I tried*, *new task* or *inspect*.
- The capture also goes to a pack, so the original is kept.
- The Threads panel shows every record with provenance and sources. Each record can be confirmed, pinned, marked outdated or deleted, and the task can be renamed or given a goal.

**Simulate.**
- Two editable paths. They're suggested by the on-device model if available; otherwise "Keep / Change".
- A **deterministic** comparison links each path to stored records: *in line with*, *possible tension — check*, *tried before*, *questions*, *assumptions*.
- Every comparison is labelled "Scenario exploration from your saved work — not a prediction". There are no probabilities or scores.

**Continue where you left off.** When a session starts, a card offers the most recent paused task (within 7 days). The choices are **Continue**, **Review context** or **Dismiss**.

**Continue in an AI tool.**
1. Shapr writes the task as a `Checkpoint` in its pack, creating one named after the task if needed. Guesses are labelled and rules are kept word for word.
2. It opens the existing Resume panel, where you review and edit the exact prompt.
3. Relay can then watch the new chat.

---

## 5. Verification

| What | How | Result |
|---|---|---|
| Flow core behaviour (permissions, privacy, memory, inference, retrieval, Simulate, suggestions, robustness, resources) | `swift run ShaprCoreChecks` on Linux (Swift 6.1.2) | **81 / 81 passed** |
| Demo story through the real engine | `swift run ShaprCoreChecks --demo` | Output in [FLOW_DEMO.md](FLOW_DEMO.md) |
| Share server (unchanged) | `node server/test.mjs` | 17 / 17 passed |
| App sources I changed or added | `swiftc -parse` (syntax only) | Parse cleanly |
| **macOS app build, `--selftest`, GUI, Accessibility reading** | Needs a Mac with Xcode 26 | **Not run. Not verified.** See the Mac test plan |

Measured on the Linux container (release build):

| Measurement | Result |
|---|---|
| Processing one observation (incl. permission checks, redaction, grouping) | **0.031 ms** average over 5,000 |
| Retrieval for Lens | **0.4 ms** |
| Consolidation | **p95 0.14 ms** |
| Disk after 12 sessions of 150 observations each | **38 KB** (budget 1.5 MB) |

Window reads on a Mac are timed and shown under **Privacy & Memory → Resource use**. Their budget is 0.5 s and 3,000 Accessibility nodes, and they run only on activity.

---

## 6. Roadmap

**Done in this change (P0 / P1, most of P2)**
- Permission-gated sessions
- Event-driven local observation
- Compact, evidence-grounded working memory with budgets, expiry and real deletion
- The menu-bar popover
- Lens, Threads and Simulate on the circle
- Continue where you left off
- Handoff through checkpoints and MCP
- Quiet / Balanced / Proactive assistance
- A reproducible demo

**Next**
1. **Verify on a Mac:** build, run `--selftest`, and work through the manual test plan. Fix compile issues, since the app layer has only been syntax-checked.
2. **Better observation in editors and terminals:** test which VS Code / Xcode / iTerm surfaces expose their text through Accessibility. Add file-change events (FSEvents) for files explicitly linked to a task.
3. **Task grouping:** add on-device semantic similarity (NaturalLanguage sentence embeddings) as one more signal. Keep scores explainable.
4. **Simulate:** run reversible experiments on request (for example tests in a separate git worktree), only after explicit approval.
5. **Memory-aware agents:** scoped MCP access, so a tool can request one task, not all memory. Show which tool read what.
6. **Project branching and decision history:** keep separate assumptions per branch, and flag decisions whose supporting evidence changed.
7. **Open context format:** document the `memory.json` task schema as a portable task-state format.
8. **Optional sync** of compact task states, end-to-end encrypted and off by default.
