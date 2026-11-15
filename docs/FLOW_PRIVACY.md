# Shapr Flow — privacy specification

This document says what Shapr Flow observes, what it stores, what stays on the Mac, and what can leave it. It describes the code in `Sources/ShaprCore` and `Sources/Shapr/ActivityObserver.swift`. Statements marked **(checked)** are covered by automated checks in `FlowCoreChecks`. Statements marked **(Mac)** depend on macOS behaviour and still need manual verification on a Mac.

## Two layers of permission

| Layer | Who grants it | Scope |
|---|---|---|
| macOS Accessibility (and Automation for browsers) | System Settings | Lets Shapr read any app. Shapr already needed this for capturing selections. |
| **Shapr Flow app authorization** | The prompt "Allow Shapr to observe *App*?" | Narrows the above to the apps you choose, only while a session is on. |

The prompt explains this difference. Flow enforces its own layer in code: the macOS permission is never treated as consent to observe.

## When anything is observed

- **Sessions are off at every launch.** Nothing is observed until you click **Start working session** (checked).
- **While paused**, no reads start, and reads already in flight are discarded when they return (checked).
- **Sleep, display sleep and screen lock** stop observation and invalidate in-flight reads (Mac).
- **Apps:**
  - Before a decision, Shapr looks only at the app's **bundle identifier**, to show the prompt. Nothing is read (checked).
  - **Don't allow** blocks the app until you change it, and takes precedence over every other rule (checked).
  - **Allow once** lasts until you leave the app (checked). **Allow for this session** lasts until the session ends (checked). Neither is ever written to disk, so neither survives a restart (checked).
  - **Revoking** access stops reads at once, rejects reads in flight, and drops that app's unprocessed observations (checked).
  - Closing the prompt without choosing means "not now": that app isn't asked about again during this session (checked).
- **Never observed, even if allowed:** 1Password, Bitwarden, LastPass, Dashlane, KeePassXC, Keychain Access, Passwords, the login window, SecurityAgent and system authentication dialogs, the screen saver, notifications (`UserNotificationCenter`), Shapr itself, and any app whose bundle ID contains "password" (checked).

## What is read from an allowed app

| Read | How | Kept? |
|---|---|---|
| Window title | Accessibility | Yes, as a source title or evidence. Secrets are redacted |
| The document a window shows (AXDocument) | Accessibility | The file path and its project folder name |
| Browser page address and title | AppleScript | Yes, **without** query strings or fragments (checked) |
| Window text | Accessibility, at most 3,000 elements / 0.5 s, on a background thread | **No.** It's reduced to error lines and shell-command lines before it leaves the reader. Everything else is dropped (checked) |

**Never read**
- Secure text fields: if one is focused, the whole read is skipped (Mac).
- Chrome-family **incognito** windows (Mac).
- Windows whose titles mention private browsing, passwords, sign-in or verification codes (checked).
- Keystrokes: no keyboard monitoring of any kind.
- The clipboard.
- The screen: no screenshots in the background. Screenshots happen only when you circle something.
- **Safari private windows can't be detected through AppleScript.** If you browse privately in Safari, don't authorize Safari, or pause the session.

**Redaction before anything is stored** (checked): passwords in connection strings, `password=`/`token=`/`api_key=` values, provider keys (`sk-…`, `ghp_…`, `AKIA…`, `xox…`, …), JWTs, bearer tokens, private keys, long key-like strings, US SSNs, and card numbers that pass the Luhn check. This is pattern matching. It **can miss things**, and it's a second line of defence behind app authorization, not a guarantee.

## What is stored, where, and for how long

All Flow data lives in `~/Library/Application Support/Shapr/Flow/`:

| File | Contents |
|---|---|
| `permissions.json` | Only your *Always allow* and *Don't allow* choices |
| `settings.json` | Processing mode, assistance mode, retention, MCP sharing |
| `memory.json` | Tasks, working-memory records with their evidence (app, window title, address, time, an excerpt of at most 240 characters), and episodes |

- **Immediate observations are never written to disk.** They live in RAM for at most 20 minutes and are cleared when the session ends (checked).
- Episodes expire after 30 days by default (7 or 90 in settings). Things you pinned are kept until you delete them.
- The file is capped at 1.5 MB (checked).
- Your **packs** (`~/Shapr/Packs`) are separate. Flow writes to them only when you act: Threads saves the capture you circled, and **Continue in an AI tool** writes a checkpoint.

## Deleting

Everything is under **Privacy & Memory** (from the popover, or Settings → Privacy):

- **Delete an app's data:** its observations, records, episode entries and sources. Each task's word index is rebuilt and inferred titles are reset, so deleted content can't come back in a summary, a match, Lens context or the MCP summary (checked).
- **Delete this session's data**, **delete a task** (including the checkpoints Flow wrote for it, checked), **clear temporary memory**, **delete all Flow memory**.
- Records can be deleted one at a time in Threads.
- Summaries, resume cards and context packages are never stored. They're rebuilt from what remains each time.

## What can leave the Mac

| Path | When | What |
|---|---|---|
| **Lens → Ask Claude…** | Only if *AI for Flow* is set to "Claude when I ask", an Anthropic key is set, **and** you press **Send to Claude** after seeing the exact text | Exactly the shown text (task title, what you circled, the context items you left checked), and the screenshot only if you tick it |
| **MCP `get_current_task`** | Only when an AI tool you connected to Shapr's local MCP server asks, and "Let AI tools read the current task's summary" is on | The current task's summary (no temporary observations, nothing from blocked apps or deleted data, checked). The tool may send it to its own provider |
| **Continue in an AI tool** | When you insert or copy the reviewed Resume prompt | What the Resume panel shows you |

**Nothing is sent automatically, and session histories are never sent.**

With *AI for Flow* set to **AI on this Mac only** (the default), Flow memory is built without any model. Lens and Simulate use Apple Intelligence on the Mac, or no AI at all.

The app says "AI on this Mac", not "nothing leaves this device", because other Shapr features you may have turned on (shared packs, live sources, the Claude engine for sorting) keep using the network as before.

## Known limits

- Accessibility coverage differs between apps. Some apps expose little or no text (Mac).
- Safari private windows are not detected.
- Redaction can miss secrets in unusual formats.
- Task grouping and titles are heuristics, so they're marked *inferred* and can be corrected.
