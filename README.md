# Shapr

An inventory for everything you read. Highlight text anywhere on your Mac, press a shortcut, and Shapr files it into a **context pack**. Then draft an email, Slack message or GitHub issue from that pack right where you're typing, let Claude read your packs directly, or send a checked copy to a friend.

**Voice first.** Four keys, and your voice for everything else:

| Key | What it does |
|---|---|
| **hold ⌥V** (Option-V) | **Talk to Shapr**: say any command, ask your packs anything, or save a voice note |
| **⌥C** (Option-C) | **Scoop** the highlighted text into a pack |
| **⌘⌘** (double-tap Command) | **Circle** anything on screen, then **add it to a pack or ask about it** |
| **hold ⌥S** (Option-S) | The **wheel**: point at a pack and let go to equip it |
| **tap ⌥S** | Wheel stays open: click a slot or press 1–6 (0 = Auto, N = new pack, ? = ask, Esc = cancel) |
| **⌥S → ＋** | Start a **new empty pack** in that slot and equip it; Shapr names it from the first capture |

Not sure what to say? Hold ⌥V and say **"what can I say"**. The classic one-key-per-command shortcuts below can be turned back on in Settings → Shortcuts.

| Classic shortcut (optional) | What it does |
|---|---|
| **⌥⇧Space** | **Everything, beside the pointer**: what you can do right now (text selected, in a text box, saved progress…) |
| **⌥⇧U** (Option-Shift-U) | **Use this with my pack**: connect what you're looking at with what you collected |
| **⌥⇧A** (Option-Shift-A) | **Ask your packs** a question and get the answer right there, with the notes it came from |
| **⌥⇧D** (Option-Shift-D) | **Drop**: draft from the equipped pack for the text box you're in |
| **⌥⇧X** (Option-Shift-X) | Drag a rectangle around anything on screen |
| **⌥⇧F** (Option-Shift-F) | **Fill the form** you're in from your packs and Vault |
| **⌥⇧P** (Option-Shift-P) | **Save progress**: a checkpoint of where you are in the work |
| **⌥⇧R** (Option-Shift-R) | **Resume** in the AI or coding tool you're in |

## Shapr Flow: working sessions

Click the Shapr icon and press **Start working session**. Shapr asks before it observes each app (**Allow once**, **for this session**, **always**, or **Don't allow**), then quietly keeps a small, evidence-backed picture of what you're working on: the task, your rules word for word, what you tried, errors that keep showing, open questions and your next step. Every item says how Shapr knows it (*observed*, *you said*, or *inferred*) and links to where it came from.

- **Circle anything** (double-tap ⌘), then press **L** for **Lens** (understand it, using what you already tried and read), **T** for **Threads** (remember it for this task), or **S** for **Simulate** (compare two approaches against your rules and past attempts; scenario exploration, not prediction). **A** still adds it to a pack and **Q** asks your packs; doing nothing saves it, as before.
- **Continue where you left off**: start a session tomorrow and Shapr offers yesterday's task, what was tried, and what was still failing, then hands it to any AI tool through Resume.
- **Private by design**: off at every launch; only apps you allow; no keystrokes, clipboard or background screenshots; window text is reduced to error lines before anything is kept; password managers and secure fields are never read. Memory is processed on this Mac; Claude is used only when you ask and after you've seen what's sent.
- **Privacy & memory** (from the popover) shows and deletes everything, per app, per session or per task.
- Right-click the icon (or **More**) for the classic menu.

Details: [architecture and memory](docs/SHAPR_FLOW.md) · [privacy specification](docs/FLOW_PRIVACY.md) · [demo and Mac test plan](docs/FLOW_DEMO.md)

## Use this with my pack (⌥⇧U)

Point at something (select a question, an email, an error) and press **⌥⇧U**, or pick **Use with…** from ⌥⇧Space. Shapr connects it with what you already collected:

| You're looking at | Equipped pack | Shapr prepares |
|---|---|---|
| A confusing question | MAT223 | The lecture excerpts that answer it, plus your previous attempt, ready for any AI |
| A customer email | Client project | A reply brief built on the project's decisions and documents |
| An error message | Coding project | A debugging brief with the relevant code, your constraints and what you already tried |

- **Your sources come first.** Before anything is used, you see the parts of the pack Shapr picked and can leave any out.
- **How it picks them:** on this Mac, by matching words and meaning.
- **The brief needs no API key:** copy it, or send it to Claude, ChatGPT or Gemini.
- **Shapr's answer** writes one from those sources, with Claude (your key) or Apple Intelligence, citing [1], [2]….
- **Insert** puts it in the text box you were in. If that fails, it stays on your clipboard and Shapr tells you.

## Capturing feels physical

- **Feedback right away:** the selection lights up the moment you press ⌥⇧C, before anything is read or sorted.
- **Only real saves fly:** once the capture is saved, a small card flies into the menu bar icon, which ticks. If it fails, the highlight just fades and the card explains why. Reduce Motion fades it in place instead.
- **Honest counts for files:** "Adding 12 files: 8 downloaded · 4 in progress", then "10 of 12 files added · 2 need attention: …".
- **No duplicates:** the same text from the same place isn't saved twice. You see "Already in MAT223", with **Add anyway** if you meant it.

## How sorting works

- **Equipped pack:** if you picked a pack on the wheel, every capture goes there.
- **Auto-sort** (press A on the wheel, or click its center): Shapr decides.
  - A new subject (cars, then video games) starts a new pack with a name and an emoji.
  - The first time a capture lands in an existing pack, a toast asks **"Add to Cars?"**: Yes / Other / New pack / Discard. After **Yes**, similar captures go there quietly for the next 45 minutes.
  - Every toast has **Undo**, and captures can be moved later (drag them onto another pack in the library).
  - When an auto-named pack reaches 3 and 6 captures, Shapr renames it from everything inside.
- **Engines** (Settings):
  - **On-device** (default): Apple Intelligence's on-device model. Free, and nothing leaves your Mac.
  - **Claude**: paste an Anthropic API key (stored in your Keychain) and choose Opus 5.5, Sonnet 5.5 or Haiku 5.5. Captured text is sent to Anthropic's API.
  - If neither is available, Shapr falls back to keyword matching.

## Circle to capture

Double-tap **⌘**, then move your pointer around anything on screen. Then choose:

- **Add to <pack>** saves it (this also happens if you don't choose), or
- **Ask about it** opens Ask with the screenshot: type a question or hold ⌥V and say it ("what does this error mean?"). Shapr answers from the screenshot and your pack, citing your notes; with a Claude key, Claude sees the image itself. Keep the screenshot with **Save it to <pack>**, or ask without it.
- **Answer it** appears instead when the screenshot holds a question or problem (homework, a quiz). Shapr works it out in full, step by step, using the definitions, methods and notation from your pack, and ends with the final answer.

Right after a screenshot, a spoken question is about the screenshot, and "add it" / "add it to Acme" saves it.

How circling works:  **No clicking.** A short glowing trail follows the pointer and fades behind it. When you **pause**, Shapr finds the loop you drew (ignoring the path you took to get there), locks it in with a quick highlight, and captures it. Pausing without circling anything does nothing, and Esc, a click, or double-tapping ⌘ again cancels. The double-tap key can be changed to Control or Option, or turned off, in Settings.

What gets saved:

1. a screenshot of what you circled (never including Shapr's own windows),
2. the text in it, read on your Mac with Apple's Vision OCR (or a few words describing a picture with no text),
3. the app and page it came from,
4. all of it goes to the equipped pack, or is auto-sorted like any scoop.

**Circle a link to a file and Shapr saves the file itself.** Circle "Download the syllabus (PDF)" or a list of attachments, and Shapr finds the links inside the circle, downloads them, and saves each one with its text: PDFs (including scanned ones, with OCR), Word, PowerPoint, Excel, CSV, text, Markdown, code and images. Public links download directly. Files behind a login (Quercus and other Canvas sites, Google Drive, a company wiki) are downloaded by your browser with your session, and Shapr picks them up from Downloads. Shapr also reads each link's visible text, so a link that *says* "mat223_2_6_I.pdf" counts as a PDF even when its address doesn't end in `.pdf`, and it knows the download addresses for Canvas/Quercus, Google Drive, Dropbox and GitHub.

**Circle a whole list of files at once.** Every link in the circle downloads together: public links in parallel, and login-protected ones by pressing the page's own download buttons (like Quercus's ↓), so **no new tabs open**. If a link can't be pressed, its tab opens in the background and is closed when the download finishes, and you're put back on your page. You get one progress toast and one summary ("Saved 3 files to 📐 MAT223") with Undo and Move; all the files go into the same pack. Chrome may ask once to allow multiple downloads from the site. Shapr refuses apps, installers, scripts and archives, has a 50 MB limit, never opens or runs what it saves, and marks files as downloaded from the web so macOS checks them if you open them.

You can also **drag files from Finder onto an open pack** in the library (or use More → Add Files…).

### File suggestions

While you're working on a pack, Shapr notices documents and code you **open** (PDF in Preview, a `.docx` in Word, `.sql` or `.py` in VS Code or Cursor, Pages, Keynote, Markdown, CSV and more) and new ones that land in **Downloads**, and offers: *"Add schema.sql to 🗄️ Orders Database?"* with **Add**, **Other**, or **Not here** (stop asking about that folder). Ignore it and nothing happens.

- It only asks while you're working on something: a pack is equipped, or you used one in the last couple of hours.
- With a pack equipped, it offers that pack. Otherwise it picks among your recent packs, and only asks if the file clearly fits one. That check always runs **on this Mac**, even when sorting is set to Claude.
- Once per file, at most once a minute. Skips images, apps, installers, Shapr's own folder, `~/Library`, hidden folders, `node_modules` and build folders.
- Turn either source off, or clear "Not here" folders, in Settings → File suggestions.

**⌥⇧X** does the same with a rectangle. Esc or a right-click cancels. Screenshots show up in the library, and Claude sees them through MCP. The first capture asks for **Screen Recording** access; after turning it on, quit and reopen Shapr.

## Shapr picks the pack for you

You rarely have to choose a pack. When you draft (⌥⇧D), use (⌥⇧U), fill a form (⌥⇧F) or capture with Auto-sort on, Shapr looks at where you are:

- **who the email is from**: an email from someone at acme.com goes with your Acme pack (a pack named Acme, or one with acme.com addresses or pages in it). Gmail, Outlook and other free-mail addresses only count as that one person.
- **which repo, folder or page**: a pull request in acme/app goes with the pack that has that repo's issues; a file goes with the pack its folder is linked to.
- **what you chose there before**: pick a different pack once, and Shapr remembers it for that person, repo or page.

The panel says what it picked and why ("Picked Acme because the email is from someone at acme.com"), with one click to use the pack you had on instead. With a pack equipped, only strong evidence (the sender, the repo, your own earlier choice) overrides it. When two packs fit equally, Shapr doesn't guess. It all runs on your Mac (Settings → General → "Pick the pack from where I am").

## Facts pack + style pack

Keep "what's true" apart from "how I sound". Make a pack of things you wrote (emails, messages) and choose **Use as My Writing Style** in its menu, or pick **New Style Pack…** from the voice chip in the draft panel. Then every draft, reply brief and long form answer:

- takes **facts only from the facts pack** (Acme), and
- takes **your voice from the style pack**: greetings, sign-offs, sentence length, punctuation. The model is told never to take a fact, name, number or promise from it, and it's never cited as a source.

Shapr picks samples of the same kind first (your emails for an email, your Slack messages for Slack). Style packs never receive auto-sorted captures and are never picked for facts.

## Ask the pack

Press **⌥⇧A** (or **?** on the wheel, or the **Ask** button in its corner) and type a question: "what did they say about the deadline?" Shapr searches the pack you point at, or every pack, on your Mac, and writes a short answer right in the panel, citing the notes it used. Click a note to see it in the library. Nothing is pasted anywhere. With no AI available (no Apple Intelligence and no Claude key), you still get the notes that answer it.

## Talk to Shapr: one key for everything

Hold **⌥V**, speak, and let go. Speech is turned into text on your Mac (Apple's speech model; nothing is sent anywhere), then:

- **A command runs.** For example:

  | Say | It does |
  |---|---|
  | "Draft a reply saying I'll send it Friday" | drafts where you're typing, with that instruction |
  | "Ask Acme when the proposal is due" | asks the Acme pack (or "ask my packs …") |
  | "Fill this form" | opens form fill |
  | "Add this" / "Save this to Acme" | saves what you selected, to that pack if you name one. With nothing selected, it saves what's in front of you: the chat, the page, or the window |
  | "Get the context of this chat" / "Add my WhatsApp chat to Acme" | saves the whole chat to the pack you name, or the one you have on |
  | "Get the context of my screen" / "Take a screenshot and add it to Acme" | takes a picture of your screen, reads the text off it, and saves both |
  | "Switch to Acme" / "Turn on auto sort" | equips a pack, or goes back to Auto-sort |
  | "Make a new pack called History Essay" | starts and equips a new pack |
  | "Save my progress" / "Pick up where I left off" | save progress, or continue |
  | "Continue in ChatGPT" | carries this AI chat over to ChatGPT, Claude or Gemini |
  | "Keep this page updated in Acme" | links the page, thread or repo to the pack |
  | "Take a screenshot" | starts circle capture |
  | "Use this with my pack", "Open the library", "Open settings", "Open the wheel" | what they say |
  | "Show me the map of Acme" / "Open Acme" | opens the pack, as a map or as cards |
  | "Share Acme" / "Copy the Acme pack for Claude" | opens Share Safely, or copies the pack as a prompt |
  | "Undo that" / "Move that to Acme" | takes back, or moves, the last thing you saved |
  | "Rename this pack to Globex" | renames the equipped pack (or "rename Acme to Globex") |
  | "Summarize this page" / "Translate this to French" | reads the window you're on and does it |
  | "Type see you at five" | types those words where your cursor is |
  | "Open Safari" / "Search the web for flights to Tokyo" | opens the app, or a web search |
  | "Stop" | stops reading aloud |
  | "What can I say" | shows these examples |

- **What "this" is when nothing is selected.** In ChatGPT, Claude or Gemini (website or app), Shapr reads the conversation itself, message by message, and saves it under the chat's name with a count ("Rank-nullity help · 42 messages"); saving the same chat again later replaces the earlier copy. On any other web page it saves the page's text. In any other app (WhatsApp, Messages, Slack, Notes, a PDF) it reads the text the window has loaded, which is usually more than fits on screen. If there's no text to read, it saves a picture of the window with its text read off it. It reads only what the app has loaded: an app that keeps just the recent messages in memory (the Claude desktop app's Code tab does) gives Shapr just those, and the count tells you. Shapr never scrolls or clicks to load more.
- **Several things in one breath.** "Switch to Acme, then add this", "add this to Acme and draft a reply saying thanks", "save progress and continue in Claude". "Then" always starts a new step; "and" only does when both sides are things Shapr does, so "a reply saying yes and thanks" stays one draft. Quick steps run one after another; a step that needs you (a draft, a form) ends the run and Shapr tells you what's left.

- **"Answer this using my MAT223 pack"** (or "solve this", "what's on my screen?", "explain this error") reads the window you're on, no circling needed, and answers from the pack you name, or the one you have on. A question on screen is worked out step by step.
- **A question goes to Ask:** "what did they say about the deadline?", "tell me what Ana said about pricing", "summarize the Acme pack". The answer appears in the Ask panel and is read out loud (turn that off in Settings).
- **Said it another way?** If your words don't match a known command but sound like a request (they start with a verb, or with "could you…"), Apple Intelligence on your Mac works out the steps you meant, up to three. It only ever picks packs that exist, and if any step isn't something Shapr does, nothing runs and it's kept as a note.
- **Anything else is a voice note**, saved like any capture to the equipped pack or wherever Auto-sort puts it. "Take a note: …" or "Remember to …" always saves a note.

Commands act on the app you were in (the voice card never takes focus). "Show options" opens what you can do right where you are. A pack name that doesn't exist is never guessed: "switch to Narnia" becomes a note. Tap ⌥⇧V instead of holding it to keep talking as long as you like, then tap again or click Save. Esc cancels. Turn commands off in Settings → General → Talk to Shapr to make ⌥⇧V voice notes only. macOS asks once for the microphone; the first time may take a moment while the speech model downloads.

## Live sources: packs that update themselves

Link a pack to where its information lives (pack menu → **Keep Updated From**, or **Keep this page updated** in ⌥⇧Space):

| Source | What Shapr keeps | How it stays current |
|---|---|---|
| A **folder** | its documents and text files (skips images, node_modules, build folders) | when files change |
| A **GitHub repo** | README, open issues and pull requests, recent commits | every 30 minutes (a token in Settings is only needed for private repos) |
| A **Notion page** | the page as Markdown | every 30 minutes, with your own Notion integration token |
| A **public web page** | its main text | every 30 minutes |
| A **Gmail thread** or other page behind a login | the page as you see it | whenever you open it in your browser |
| An **Apple Mail thread** | each message in the thread | as you open them in Mail |

Updated items replace their old notes instead of piling up, and deleted files or closed issues drop out. The pack shows each source with when it last updated, and flags any that failed or haven't been seen in a while, so you know when a pack might be out of date.

## Drop: drafts where you're typing

Click into a reply box and press **⌥⇧D**. Shapr sees where you are and writes in the right style, using only what's in the equipped pack:

| Where | What you get |
|---|---|
| Gmail, Outlook, Apple Mail | an email body with a sign-off |
| Slack, Discord, Teams, Messages | a short chat message |
| GitHub, GitLab | an issue (title + Summary / Steps / Expected / Actual / Evidence) or a comment |
| Linear, Jira, Asana | a ticket with acceptance criteria |
| Claude, ChatGPT, Gemini | no drafting: the pack itself, pasted as context |
| Notion, Google Docs, Notes | skimmable notes |

Add an instruction ("ask for the logs"), edit the draft, then **Insert** (⌘↩) pastes it into the app you were in. Shapr puts your clipboard back afterwards. Nothing is pasted until you click. The panel shows which captures the draft used, and anything missing appears as a `[placeholder]` instead of being made up. Drafts use Claude when you've added an API key, and Apple's on-device model otherwise (shorter packs only).

## Move between AIs without losing anything

Works with the **free** versions of ChatGPT, Claude and Gemini: Shapr only reads the chat on your screen and pastes into the message box, so there's no API, plugin, login or paid plan involved. Nothing is sent to the new AI until you press Return.

- **Out of messages? Keep going.** When a free AI shows its limit banner ("You've hit the Free plan limit", "You're out of free messages until 4 PM"), a card offers **Continue in Claude / Gemini / ChatGPT**. One click: Shapr reads the conversation, saves your progress to the equipped pack, opens the other AI in the same browser and pastes a handoff into its message box for you to check and send. Also in ⌥⇧Space and the menu bar (**Continue This Chat In**).
- **It reads the whole chat itself.** Press **⌥⇧P** inside ChatGPT, Claude or Gemini and Shapr reads the conversation on screen (no copying), then drafts the checkpoint from it, with or without an AI key.
- **Your words are kept exactly.** Instructions you gave ("don't use numpy", "the prof wants it as a table") are pulled out of your own messages word for word and never summarized. The AI's long answers are shortened, but code and final answers are kept whole.
- **The new AI can ask Shapr for more.** The handoff stays small enough for free plans and ends with a list of what Shapr has: `S1 Lecture 7`, `S2 A2.pdf`, `C the full earlier chat`. The AI can write `@shapr S2` or `@shapr the error from earlier`, and a card offers to send exactly that (one click; Shapr checks it landed in the message box before pressing Return).
- **Read-back check.** The handoff asks the AI to start its reply with three lines: Goal, Rules, Next. Shapr compares them with what you saved and tells you **"Claude got everything"** or **"Claude missed 1 of 5: Rule: “Don't use numpy.”"** with **Send it**. A rule that comes back reversed ("use numpy") counts as missed.
- **The whole chat, in few tokens.** The handoff carries every message in order, each with a short code (`U1`, `A2`…). Your messages are word for word. The AI's lose what the next AI doesn't need: "Sure!" and "let me know if…", bold and headings, and code that a later message rewrote (kept once). If it still doesn't fit, older answers are shortened first, keeping their conclusions and code, and marked "(cut)"; the AI can write `@shapr A7` to get any message in full. Only in very long chats are the oldest messages left out, and then `@shapr C` has them. The card tells you what it did: "All 42 messages · about 3,100 tokens, down from 18,400".
- **Sized for where it's going.** Each handoff fits that AI's free plan (about 3,000 tokens for ChatGPT, 5,000 for Claude and Gemini, more for code tools): goal, rules and next step always, then the chat, then the most relevant notes while they fit. What was decided and tried is listed separately only when the chat had to be shortened, so nothing is said twice.

Settings → General → **Moving between AIs** turns each part on or off.

## Save progress → Resume

**Continue (⌥⇧R)** shows a compact card: **Working toward**, **Already decided**, **Next**, and the **Sources** behind them, plus the exact prompt it will insert (editable), and where it's going. If anything changed since you saved (new captures, an edited source file, a removed source), it says so first and offers **Update progress first** or **Continue anyway**, so stale information is never handed over without you knowing.


1. **Save progress (⌥⇧P, or the button on a pack).** Scoop the conversation or notes first. Shapr reads the pack and proposes a checkpoint with five parts: the **goal**, **decisions** made, approaches **already tried**, **open problems**, and the **next step**. Each point links to the captures that back it up. It also lists your open browser tabs, with pages from the pack's sites pre-ticked. Edit anything, then save.
2. **Resume (⌥⇧R).** In ChatGPT, Claude, Cursor, Terminal or anywhere else, Shapr builds a continuation prompt from the checkpoint and the evidence it cites. Review it, **Insert** it, and **Reopen the pages** if you want them. The prompt is assembled directly from your checkpoint, with no AI call, so it's instant, free and can't invent anything. Coding tools get logs and code in code blocks.
3. **Update progress** after more work. The new checkpoint becomes current, and earlier versions stay in the pack's history.

The library shows a **Where you left off** card on each pack. Through MCP, Claude can also `save_checkpoint` ("save our progress to Shapr") and `get_checkpoint` ("pick up my Login Bug work"), so you can stop in one AI tool and continue in another. Checkpoints are stored as JSON in each pack's `.shapr/checkpoints/` folder.

## Fill a whole form

Click into a form (a job application, a sign-up page) and press **⌥⇧F**. Shapr:

1. reads every field and its label through macOS Accessibility (Safari, Chrome, Arc, Edge and native apps): text boxes, **dropdowns, radio buttons, checkboxes and date fields**,
2. matches your packs to the normal fields (name, email, links, "Why do you want to work here?"). It uses the equipped pack plus any pack named like *About Me*, *Profile* or *Résumé*, and you can switch packs in the panel,
3. shows every field with its proposed value and the snippet it came from. Edit or untick anything,
4. fills the ones you kept when you press **Fill** (⌘↩). **Shapr never presses Submit.**

**Passwords, card numbers, security codes, SSNs / national IDs, passports, driver's licenses and bank accounts** are filled only from your **Vault** (Settings → Vault). Vault values live in your Mac's Keychain, never in packs. Shapr asks for Touch ID or your Mac password before filling them. They're never sent to Claude, and they're typed rather than pasted, so they never touch the clipboard. A password is only offered on the site it was saved for.

Short answers (names, phone numbers, emails, dates) must appear in your packs and have the right shape for the field, or Shapr leaves the field blank instead of guessing. A dropdown or radio answer must be one of the field's own options; a checkbox is only ticked when a note says so; dates are typed in your region's order. **Checkboxes that agree to terms, consent or subscribe are never ticked for you.** Long answers are written from your packs (in your voice, if you have a style pack) and are yours to edit before filling.

⌥⇧D drafts also know the label of the box you're in, so "Why this role?" gets answered, not just written around.

## Claude can read your packs (MCP)

Settings → **Connect Claude to your packs** adds Shapr to Claude Desktop in one click, or copies the command for Claude Code or the config for Cursor. Claude then gets these tools:

| Tool | What it does |
|---|---|
| `list_packs`, `read_pack`, `get_equipped_pack` | find and read your packs ("use my Bug #42 pack…") |
| `search_captures` | search every capture |
| `create_pack`, `add_to_pack` | save things, e.g. "make a context pack from this chat" |
| `save_checkpoint`, `get_checkpoint` | save where you are and pick it up in another AI tool |
| `get_current_task` | Shapr Flow's current task summary (can be turned off in Privacy & memory) |

New packs show up on your wheel straight away. Under the hood it's `Shapr --mcp`, a local server that only reads and writes `~/Shapr/Packs`.

## Safe Share

**Share Safely…** on a pack scans it on your Mac for emails, phone numbers, API keys and tokens, card numbers, IP addresses, links with tokens, internal links, and names of people, companies and places. For each one you choose **Keep / Replace / Remove**. Only the shared copy changes; your pack stays as it is. Your choices are remembered, so the next share only asks about new captures.

Screenshots and attached files stay out of `.shapr` files unless you turn them on, because only their text can be checked. Save the result as **.md** (anyone can read it) or **.shapr**: your friend double-clicks the `.shapr` file and the pack appears in their Shapr. **Import Pack…** in the menu bar works too. Imported packs always arrive as a new pack and are never merged into yours.

## Live shared packs

In **Share Safely…**, **Create live link** puts the shared copy online and copies a link like `https://your-server/p/AbC123xyz789`.

- **Anyone with the link** sees the pack on a web page and can click **Add to Shapr**. The pack lands in their library and stays up to date: new captures you add show up for them, and deleted ones disappear.
- **Your privacy choices apply to everything shared later.** A new capture with something private-looking in it (an email, a phone number, a key) isn't shared; it waits, and Shapr asks you to review it.
- **In the library**, a shared pack shows **Live link · 3 joined**: copy the link, open the page, review, or stop sharing. A pack you added shows **Joined · synced 2 min ago**, with Sync now and Stop syncing.
- **Adding a pack:** **Add Shared Pack…** in the menu bar takes a pasted link; the page's button uses `shapr://join/…`.
- **No accounts:** the server gives your Mac a secret key for each link, kept in your Keychain, and stores only a hash of it. Stopping sharing deletes the pack from the server; people who added it keep their copy.

The server is in `server/` (see `server/README.md`); it runs on Cloudflare's free tier, or on your Mac for testing.

## Where your packs live

```
~/Shapr/Packs/cars/pack.json                         name, emoji
~/Shapr/Packs/cars/2026-11-07-102201-toyota-supra.md  one Markdown file per capture
~/Shapr/Shared/                                       shareable copies you saved
```

Each capture is plain Markdown with its source URL, app and time in the front matter, so you can open packs in Finder, Obsidian or VS Code, or hand a folder to Claude.

## Build and run

Needs macOS 26+ and Xcode (Swift 6).

```bash
scripts/build-app.sh            # builds build/Shapr.app
scripts/build-app.sh --install  # and copies it to /Applications
open build/Shapr.app
```

On first launch, turn Shapr on in **System Settings → Privacy & Security → Accessibility**. Shapr reads the text you highlight that way. The first capture from a browser also asks for **Automation** access, which is how Shapr gets the page's URL and title.

> To keep Accessibility and Screen Recording across rebuilds, sign with a fixed identity: put its name in `.signing-identity` (git-ignored) or set `SHAPR_SIGN_IDENTITY` (`security find-identity -v -p codesigning` lists them). Ad-hoc builds lose those permissions every time.

### A release anyone can install

`scripts/release.sh` signs with your **Developer ID**, turns on the hardened runtime, has Apple **notarize** the app, staples the ticket, and makes `build/Shapr-<version>.dmg` (for people) and a `.zip` (for in-app updates). With `--publish` it uploads both to your share server: `https://your-server/download` then serves the new version, and every installed Shapr offers **Install and Restart**.

1. Join the Apple Developer Program, then create a **Developer ID Application** certificate (Xcode → Settings → Accounts).
2. Save notarization credentials once: `xcrun notarytool store-credentials shapr-notary --apple-id you@example.com --team-id TEAMID`.
3. Run `SHAPR_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" SHAPR_SHARE_SERVER=https://… SHAPR_ADMIN_TOKEN=… scripts/release.sh --publish`.

Updates are checked at launch and every six hours (**Settings → General → Updates**). An update is installed only if its checksum matches and it's signed the same way as the copy you're running, so nobody else can push an app to you. Copies built on your own Mac don't update themselves.

### Developer commands

```bash
swift run Shapr --selftest            # storage, auto-sort, export and Safe Share checks (no UI, temp folder)
swift run ShaprCoreChecks             # Shapr Flow's core checks: permissions, memory, retrieval (any platform, no Mac needed)
swift run ShaprCoreChecks --demo      # the Shapr Flow demo story, run through the real engine (also: Shapr --flow-demo)
swift run Shapr --render /tmp/shots   # PNG snapshots of the wheel, toasts, library, share, drop and settings
swift run Shapr --mcp                 # the MCP server on stdin/stdout
swift run Shapr --share-smoke http://localhost:8787   # share, join and live-update end to end (server running)
swift run Shapr --probe-downloads     # read-only: which download button would be pressed on the front Safari page
open -n /Applications/Shapr.app --args --probe-chat /tmp/chat.txt   # read-only: what Shapr reads from the AI chat in front, 3 s later
swift run Shapr --probe-source https://github.com/owner/repo   # read-only: what a live source would keep (folder, repo, page)
swift run Shapr --probe-window   # read-only: the window "answer this using my screen" would read
open -n /Applications/Shapr.app --args --probe-window-text /tmp/window.txt net.whatsapp.WhatsApp   # read-only: how much text Shapr reads from that app's front window (sizes only, never the text)
open -n /Applications/Shapr.app --args --showcase /tmp/glass   # shows the glass surfaces for a few seconds and captures them
open -n /Applications/Shapr.app --args --probe-form /tmp/form.txt   # read-only: the form fields in the front window, 3 s later (add "fill" on a test page to fill test values)
say -o /tmp/note.aiff "hello" && swift run Shapr --transcribe /tmp/note.aiff   # speech to text on this Mac
cd server && node test.mjs && node dev.mjs            # share server tests, then run it on your Mac
SHAPR_HOME=/tmp/shapr swift run Shapr # run against a scratch packs folder
```

## Look and feel

Calm and defined: warm paper-like neutrals, flat fills, one clay accent, a serif only for titles, and nothing that shines or bounces. One thing in focus at a time, actions where your eyes already are, and one thing to learn first: hold ⌥V and say what you want. Each surface was checked against an app that does it well: Loop for the radial wheel, Maccy for the quick menu, CodeEdit for native windows, and Luminare for one consistent set of controls.

- **Liquid Glass for everything that floats.** The voice card, Ask, the draft and form panels, the cards in the corner and the wheel are all macOS's Liquid Glass, so they sit lightly over whatever you're working on. What's on the glass stays plain and readable. With Reduce Transparency on, they turn solid; with Reduce Motion, nothing springs or swirls.
- **Packs are orbs, not emoji.** Each pack is a flat circle of its color with its initials ("JT" for Japan Trip), the same in the wheel, the library, chips and cards. Every new pack gets a color no other pack has (until all ten are taken), and keeps it.
- **Talk to Shapr (hold ⌥V):** a glass pill right next to your cursor. A halo round its disc swells with your voice, your words appear as you say them, and it shows "Thinking…" while Shapr does what you asked. No buttons while you hold the key; say "add this" or ask anything.
- **Ask:** one big question field, Spotlight-style, with the pack it asks in the field. The answer, then the notes it came from (three, with "Show all"). One action bar: what happened on the left, Copy and Ask on the right.
- **Wheel (⌥S):** one quiet glass dial at your pointer. Six places round the edge, each a small dot of the pack's color over its name; the place you point at lights up, and the middle says what you'd get. The equipped pack's dot is ringed. No orbs, no gloss, no bounce.
- **Cards in the corner:** the pack's orb, what happened ("Added to Cars · caranddriver.com"), and at most a couple of buttons. Screenshots lead with the picture.
- **Panels (draft, form, Use, progress):** a short header, the content, and a Raycast-style action bar with each action's key. Fewer controls on screen: Use picks its mode itself (change it from one small menu) and keeps its notes folded until you want them.
- **Buttons are flat capsules;** the primary one is the accent color.
- **Quick menu** (say "what can I do here", or ⌥⇧Space with the classic keys): a search field on top, then a short numbered list: type to filter, arrows and Return to run, or press a number. The selected action's detail and key sit at the bottom.
- **Library:** a native Mac window. Packs and search in the sidebar; the pack's name, details, Equip and a "…" menu (Copy for Claude, Save progress, Share) in the toolbar; cards with the content first and the source second; the selected capture opens in an inspector on the right.
- **Map of a pack:** the third layout next to cards and list. A dot for each capture, a ring for each topic two or more captures share, and lines between them, so you can see what's in a pack and what belongs together. Hover to light up what something is joined to, click a dot to open it, drag to move, scroll or pinch to zoom. Worked out on your Mac from the words in the captures.
- **First run:** one line ("Hold ⌥V and say what you want"), four things to try, and only the permissions that are still off.
- **Settings:** a sidebar of sections (General, Shortcuts, AI, Privacy, Connections), each a plain grouped form.

### Quality targets (what we test for)

- Something visible within about 100 ms of every shortcut: the selection highlight, or the ⌥⇧Space panel. Both log how long they took (`log stream --predicate 'subsystem == "app.shapr.Shapr"'`).
- The wheel and the ⌥⇧Space panel never wait for AI or the network.
- Esc closes or cancels every panel and overlay.
- If inserting fails, what Shapr prepared stays on your clipboard, and Shapr says so.
- A new user's first capture and first useful **Use** work without an API key: the brief is built on the Mac.
- Capturing the same thing twice doesn't create a duplicate.
- A handoff never exceeds what the destination's free plan handles well; your rules are always in it, word for word.

## Not in v0.17 yet

Reading chats in the ChatGPT desktop app is best-effort (the website is fully supported). Gmail threads update when you open them, not in the background (that needs a Google sign-in app of your own). Accounts and private (invite-only) links, launch at login, custom shortcuts, blurring private details inside screenshots, and file uploads in forms.
