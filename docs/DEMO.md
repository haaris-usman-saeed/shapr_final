# The Shapr demo (about 90 seconds)

One story, start to finish: **capture from three places → equip the pack → use it on a new question → save progress → continue in another AI.**
The same flow is checked automatically by `swift run Shapr --selftest` ("Use this with my pack: the demo flow").

## Before you record

- Shapr 0.13+ is running; Accessibility and Screen Recording are on.
- Have a course page (Quercus), a lecture PDF in Preview, and an email open.
- Start with no MAT223 pack, so the first scoop makes one.

## The flow

1. **Capture from three places (about 30 s)**
   - Quercus: select the paragraph on diagonalization and press **⌥⇧C**. It lights up, and a card flies into the menu bar: **New pack: 📘 MAT223**.
   - Preview: select the eigenvalue definition in the PDF and press **⌥⇧C**. It goes into MAT223.
   - Quercus Files: double-tap **⌘** and circle the lecture PDFs. You see "Adding 4 files: 4 downloaded · 0 in progress", then **4 of 4 files added**.
2. **Equip it (5 s):** hold **⌥S**, point at 📘 MAT223 and let go. The menu bar shows 📘.
3. **Use it on a new question (25 s)**
   - Open a practice problem and select it: *"How do I check whether a 3×3 matrix is diagonalizable?"*
   - Press **⌥⇧Space**. The first row is **Use with MAT223**; press Return.
   - Shapr shows the lecture excerpt it picked as [1], with the PDF definition as [2], and the email isn't included.
   - Untick one to show you're in control. **For your AI** is the ready brief; **Shapr's answer** writes one, citing [1].
4. **Save progress (15 s):** press **⌥⇧P**. Shapr drafts Working toward, Already decided, Already tried, and Next. Edit the title, then **Save checkpoint**.
5. **Continue in another AI (15 s)**
   - Open ChatGPT and click into the message box. Press **⌥⇧R**.
   - The card shows Working toward, Already decided, Next and the Sources, with the exact prompt. **Insert** pastes it.
   - Then scoop one more thing and press ⌥⇧R again. The card warns: **"Since you saved this: 1 new capture"**, with **Update progress first**.

## Bonus: out of free messages (30 s)

1. In free ChatGPT, work on the MAT223 question until the "You've hit the Free plan limit" banner appears (or open a chat that already shows it). Somewhere in the chat, say a rule: *"Don't use numpy. Keep it under 200 words."*
2. Shapr's card appears: **ChatGPT hit its message limit**, quoting the banner, with **Claude** and **Gemini**. Click **Claude**.
3. Claude opens in the same browser with the handoff already in the message box: your goal, your rules in quotes, what was tried, where the chat stopped, the lecture excerpt, and the `@shapr` list. Press Return.
4. Claude's reply starts with Goal / Rules / Next, and Shapr's card says **Claude got everything**.
5. Claude writes `@shapr S2`; the card **Claude asked for S2: A2.pdf** appears; click **Send**.

The same flow (minus the browser) is checked by `swift run Shapr --selftest` ("Moving between AIs").

## Bonus: Shapr knows which pack (30 s)

1. Make a pack called **Acme**, and a style pack (**New Style Pack…** in the draft panel) with two emails you wrote.
2. Open an email from someone at acme.com in Gmail, click Reply and press **⌥⇧D**. The panel says **Picked Acme because the email is from someone at acme.com**, and the draft sounds like your emails, with facts only from Acme.
3. Hold **⌥⇧V** and say *"Acme wants the proposal by the 22nd."* Let go: it lands in Acme.
4. Press **⌥⇧A** and ask *"when is the Acme proposal due?"*: the answer, with the voice note as its source.
5. In the Acme pack's menu choose **Keep Updated From → A GitHub Repo…** and paste acme's repo: its README and open issues appear, with "Updated just now".

The same pieces are checked by `swift run Shapr --selftest` ("Picking the pack", "Facts pack + style pack", "Live sources", "Ask the pack").

## What to say

"Every AI tool forgets what you're working on. Shapr is the inventory you carry between them: grab anything, and the right parts come with you, checked by you, into whatever AI you use next."
