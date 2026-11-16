# SHAPR FLOW: storyboard, script and creative rationale

## Why the previous film undersold Shapr Flow (reviewed: `../demo-video/`)

| Previous film (3:21) | Problem against this brief | This demonstration |
|---|---|---|
| 1:48 of shipping foundations (capture, packs, drafts, forms, AI handoff, MCP) before any Flow | Made Shapr look like an organiser; Flow arrived as an appendix | Foundations appear only as invisible plumbing (the circle, checkpoints); 100% of the story is Flow |
| Each feature introduced, shown, captioned with a slogan | Feature tour rhythm; little emotional arc | One continuous afternoon → evening → next morning, one bug, one decision |
| Memory shown once as chips merging into a card (22 s) | The central invention got one beat | Memory is the spine: observation → kernel consolidation → Threads → Resume → review/delete |
| Rendered video only | No way for a presenter to explore or answer "what if Safari were blocked?" | Interactive mode on the same state; blocking an app visibly changes memory and Lens |
| Violet "concept" pill on Flow scenes | Correct, but split the film into "real" and "maybe" | Whole piece framed as a concept demonstration; a quiet label on every frame, specifics in TECHNICAL.md |

## The story

**Aurora**, a campus energy-monitoring app. Maya's backend can't reach PostgreSQL (`ECONNREFUSED 127.0.0.1:5432`).
She checks credentials, restarts the service, reads docs. Still refused. Shapr, allowed in VS Code and Safari
(not Messages), builds a compact understanding, helps with Lens, saves a finding, and the next morning lets her continue.
Then a new requirement collides with an earlier decision, and she explores both paths with Simulate.
The bug is never "solved by magic": the film ends with the right next step, not a fix.

## Hero (3:41)

| # | Time | Scene | What we see | Narration / statement |
|---|---|---|---|---|
| 1 | 0:00 | The computer that forgets | Darkness, two lines; VS Code error, Safari search, docs, ChatGPT and Claude each receive the same typed explanation; everything mutes | "Your computer sees everything you do." / "But does it understand any of it?" / **What if you never had to explain your work again?** |
| 2 | 0:17 | Turn Shapr on | The Shapr mark arrives in the menu bar; translucent popover: *SHAPR Flow · Off · Start session*; one click → green *Session active* | "Start a session. Choose what Shapr can see." |
| 3 | 0:29 | Your permission | Per-app prompts: VS Code → *Allow this session*, Safari → *Allow this session*, Messages → *Don't allow*. Light pulses travel from allowed apps to Shapr; Messages greys behind a lock | **Your computer. Your permission.** / **Local-first by design.** |
| 4 | 0:48 | Shapr starts understanding ★1 | Opening .env, searching, reading docs, the error: each sends a pulse (the message from Messages sends nothing). *Observed* labels appear at their sources, converge into a task object; *Likely task: Fix database connection* (Inferred) → Confirm | "Start working. Shapr keeps up." / **Shapr doesn't just collect what you see. It connects what you're doing.** |
| 5 | 1:10 | The Memory Kernel ★2 | Three lanes: Immediate · Working memory · Long-term. Fragments stream in with expiry rings; repeats merge (×2); a contentless "1 event from a blocked app · not observed"; light flows from relevant fragments into AURORA / BACKEND: Goal, Tried, Current issue, Next, each with its source; confirmed task drops into long-term; the rest expire; the card flies home | **NOT EVERYTHING YOU DID. EVERYTHING YOU NEED TO CONTINUE.** |
| 6 | 1:36 | Circle anything ★3 | Close-up; ⌘⌘; a hand-drawn ember loop closes and springs into a rounded selection; L / T / S unfolds below it | "Circle anything." / **Make it useful.** |
| 7 | 1:48 | Lens | Lens beside the error: "This may be related to your earlier connection attempt." Previous attempt, likely wrong host; sources; *See evidence* lights `DB_HOST=127.0.0.1` | "Lens starts from where you are, not from zero." / **Don't ask from scratch. Ask from where you are.** |
| 8 | 2:06 | Threads | Docker docs: "Inside a container, localhost refers to the container itself." Circle → T → *Saved to the Aurora thread · Next: Inspect environment configuration*. End session → *Checkpoint saved* | "Your work keeps moving. Its context stays connected." |
| 9 | 2:22 | Resume ★4 | Night. "You stopped working." Morning light, empty desktop. "Your progress didn't disappear." *Welcome back. Continue Aurora?* with yesterday's state and the app choices it reuses → *Continue where I left off* → windows glide back; restored list; *Share context with coding assistant* (review before sending) | "Stop now. Continue tomorrow." / **Pick up exactly where you left off.** |
| 10 | 2:46 | Simulate ★5 | Spec: new requirement vs "Store user data locally." Circle → S. The decision lifts and branches into Path A (local-first + sync) and Path B (managed backend): advantages, tradeoff, evidence, open questions (dashed), "Scenario exploration · not a prediction"; choose A | "Explore the options, and the evidence behind them." / **Don't just ask what to do. Explore what could happen.** |
| 11 | 3:08 | You stay in control | Pause (amber), Review memory (three layers, expiry timers, sources), Delete this session | "Pause it. Review it. Delete it. It's your context." / **Your work belongs to you. So does your context.** |
| 12 | 3:21 | Finally connected | Work moves across apps; thin lines briefly link Active work · Context · Working memory · Assistance to Shapr, then vanish. Darkness: YOUR COMPUTER. YOUR CONTEXT. FINALLY CONNECTED. Mark, **SHAPR Flow**, "Your work. Understood." | "Your computer. Your context. Finally connected." |

★ = the five wow moments. Silence is used before the circle, during the kernel's consolidation and on the end card.

## Trailer (1:00), recomposed

| Time | Beat |
|---|---|
| 0:00 | Fragmented work: the same explanation typed into two AIs → **What if you never had to explain your work again?** |
| 0:09 | Shapr on; VS Code and Safari allowed, Messages denied; pulses from allowed apps only |
| 0:21 | Work streams into the Memory Kernel → **NOT EVERYTHING YOU DID. EVERYTHING YOU NEED TO CONTINUE.** |
| 0:35 | Circle the error → Lens |
| 0:45 | "Stop now. Continue tomorrow." → morning → *Continue where I left off* |
| 0:55 | SHAPR Flow · Your work. Understood. |

## Sound

Original and synthesised: soft keys, warm pads, a light pulse at 92 bpm; a darker sparse opening, the theme on
"Start session", a curious variation in the kernel and Simulate, near-silence at night, a three-note signature
(A–C–F) on the end card. Effects: session start, permission granted/denied, circle draw and close, memory merge
and settle, Lens, save, branch, resume, logo. Narration: Kokoro `af_heart` (local, open-weight), replaceable by a
human read per line.
