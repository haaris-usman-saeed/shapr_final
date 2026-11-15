import AppKit
import FoundationModels
import ApplicationServices

/// Checks for 0.13: picking the pack, style packs, live sources, asking a pack, voice notes and whole forms.
/// Runs on a throwaway folder and a throwaway UserDefaults suite, never ~/Shapr or your settings.
extension SelfTest {
    static func smarterCaptureChecks(root: URL, defaults: UserDefaults) async {
        let store = PackStore(root: root, defaults: defaults)
        func capture(_ text: String, title: String, url: String? = nil, app: String? = nil, bundle: String? = nil,
                     into pack: Pack) {
            store.add(CaptureDraft(text: text, appName: app, bundleID: bundle, title: title, url: url), to: pack.id)
        }

        print("Picking the pack")
        check(PackRouter.baseDomain("mail.acme.co.uk") == "acme.co.uk" && PackRouter.baseDomain("docs.acme.com") == "acme.com"
              && PackRouter.baseDomain("www.acme.io") == "acme.io", "sites are grouped by company domain (acme.co.uk, acme.com)")
        let found = PackRouter.emails(in: "From: Ana Ruiz <Ana.Ruiz@Acme.com>\nTo: me@gmail.com, no-reply@acme.com\nimage001.png@01DA")
        check(found == ["ana.ruiz@acme.com", "me@gmail.com"], "addresses on screen are found, lowercased, without no-reply ones (\(found))")

        let acme = store.createPack(name: "Acme", emoji: "🏢", autoNamed: false)
        capture("Ana said the launch is on March 15. Contact: ana.ruiz@acme.com", title: "Acme launch call", into: acme)
        let bug = store.createPack(name: "Bug 42", emoji: "🐞", autoNamed: false)
        capture("TypeError at Dashboard.tsx:42", title: "Issue #42", url: "https://github.com/acme/app/issues/42", into: bug)
        let trip = store.createPack(name: "Japan Trip", emoji: "🗾", autoNamed: false)
        capture("Ryokan booking for April", title: "Ryokan", url: "https://www.japan-guide.com/e/e2029.html", into: trip)
        let packs = { store.packs }
        let valid = Set(packs().map(\.id))
        var ix = PackRouter.index(packs: packs())

        let fromAcme = PackRouter.suggest(RouteSignals(emails: ["ben@acme.com", "me@gmail.com"], senderKnown: true,
                                                       url: "https://mail.google.com/mail/u/0/#inbox/FMfcgzQXJabcdefghijk"),
                                          index: ix, valid: valid)
        check(fromAcme?.packID == acme.id && fromAcme?.reason == "the email is from someone at acme.com",
              "an email from someone at acme.com picks the Acme pack, and says why (\(fromAcme?.reason ?? "none"))")
        let fromGmail = PackRouter.suggest(RouteSignals(emails: ["stranger@gmail.com"], url: "https://mail.google.com/mail/u/0/#inbox"),
                                           index: ix, valid: valid)
        check(fromGmail == nil, "a gmail.com sender says nothing about which pack")
        let repo = PackRouter.suggest(RouteSignals(url: "https://github.com/acme/app/pull/77"), index: ix, valid: valid)
        check(repo?.packID == bug.id, "a page in the acme/app repo picks the pack with that repo's issues")
        // Two packs with the same evidence: no guess.
        let other = store.createPack(name: "Acme Hiring", emoji: nil, autoNamed: false)
        capture("Recruiter: maria@acme.com", title: "Recruiter", into: other)
        ix = PackRouter.index(packs: packs())
        let tie = PackRouter.suggest(RouteSignals(emails: ["ben@acme.com"]), index: ix, valid: Set(packs().map(\.id)))
        check(tie == nil, "when two packs fit equally, Shapr doesn't guess")
        PackRouter.learn(RouteSignals(emails: ["ben@acme.com"]), packID: other.id, defaults: defaults)
        let learned = PackRouter.suggest(RouteSignals(emails: ["ben@acme.com"]), index: ix, learned: PackRouter.learned(defaults),
                                         valid: Set(packs().map(\.id)))
        check(learned?.packID == other.id && learned?.reason == "you used it here before" && learned?.isStrong == true,
              "after you pick a pack for someone, Shapr picks it for them next time")
        store.deletePack(other.id)

        let style = store.createPack(name: "My Writing", emoji: "✍️", autoNamed: false)
        store.setRole(style.id, .style)
        capture("Hey Ana! Quick one: can we push the sync to Thursday? Cheers, Moosa", title: "Email to Ana",
                url: "https://mail.google.com/mail/u/0/#sent/abc", app: "Safari", into: style)
        capture("yo, pushing the deploy to tmrw, all good?", title: "Slack to team", url: "https://app.slack.com/client/T1/C1", app: "Slack", into: style)
        capture("Acme renewal is $40,000 a year. ana.ruiz@acme.com", title: "Style pack facts that must never leak", into: style)
        store.load()
        check(store.pack(style.id)?.isStyle == true, "a style pack stays a style pack after reloading from disk")
        check(!store.summaries().contains { $0.id == style.id }, "Auto-sort never files captures into a style pack")
        ix = PackRouter.index(packs: store.packs)
        let notStyle = PackRouter.suggest(RouteSignals(emails: ["ana.ruiz@acme.com"]), index: ix,
                                          valid: Set(store.packs.filter { !$0.isStyle }.map(\.id)))
        check(notStyle?.packID == acme.id, "style packs are never picked for facts, even when they mention the sender")

        store.equip(bug.id)
        let weak = RouteSuggestion(packID: trip.id, reason: "you've saved pages from japan-guide.com there", score: 2.2)
        let strong = RouteSuggestion(packID: acme.id, reason: "the email is from someone at acme.com", score: 4.1)
        check(store.packToUse(weak).pack?.id == bug.id && store.packToUse(weak).picked == nil,
              "with a pack equipped, weak evidence doesn't override it")
        check(store.packToUse(strong).pack?.id == acme.id && store.packToUse(strong).picked != nil,
              "strong evidence (the sender) switches the draft to the right pack, with a way back")
        store.equip(nil)

        print("Facts pack + style pack")
        let target = DropTarget(app: nil, appName: "Safari", url: "https://mail.google.com/mail/u/0/#inbox/x", destination: .email, label: "Gmail")
        let prompt = Drafter.prompt(pack: store.pack(acme.id)!, style: store.pack(style.id), target: target, instruction: "")
        let facts = prompt.components(separatedBy: "<writing_samples").first ?? ""
        check(prompt.contains("<writing_samples") && prompt.contains("Hey Ana! Quick one") && facts.contains("March 15"),
              "a draft gets the facts pack as context and the style pack as writing samples")
        check(!facts.contains("$40,000"), "nothing from the style pack is offered as a fact")
        let samples = StyleSamples.pick(from: store.pack(style.id)!, for: .email, limit: 3000)
        check(samples.first?.hasPrefix("Hey Ana!") == true, "for an email, your emails come first as samples")
        check(Drafter.system.contains("Never take facts"), "the model is told never to take facts from the samples")
        check(FormMapper.context(from: [store.pack(acme.id)!, store.pack(style.id)!]).markdown.contains("$40,000") == false,
              "forms never fill a field from a style pack")

        print("Live sources")
        check(PackSource.from(link: "https://github.com/acme/app/issues/4")?.kind == .github
              && PackSource.from(link: "https://github.com/acme/app/issues/4")?.location == "acme/app", "a GitHub link becomes the repo")
        check(PackSource.from(link: "https://www.notion.so/acme/Launch-plan-1f2e3d4c5b6a79881f2e3d4c5b6a7988")?.kind == .notion,
              "a Notion link becomes a Notion page")
        check(PackSource.from(link: "https://mail.google.com/mail/u/0/#inbox/FMfcgzQXJabcdefghijk")?.kind == .page,
              "a Gmail thread updates from your screen when you open it (it needs your login)")
        check(PackSource.from(link: "https://docs.python.org/3/library/re.html")?.kind == .web, "a public page is fetched")
        check(NotionSource.pageID(from: "https://www.notion.so/acme/Launch-plan-1f2e3d4c5b6a79881f2e3d4c5b6a7988?pvs=4")
              == "1f2e3d4c-5b6a-7988-1f2e-3d4c5b6a7988", "the page ID is read from a Notion link")
        let todo: [String: Any] = ["type": "to_do", "to_do": ["checked": true, "rich_text": [["plain_text": "Ship it"]]]]
        let code: [String: Any] = ["type": "code", "code": ["language": "swift", "rich_text": [["plain_text": "let x = 1"]]]]
        check(NotionSource.line(todo, depth: 1) == "  - [x] Ship it" && NotionSource.line(code, depth: 0) == "```swift\nlet x = 1\n```",
              "Notion blocks become Markdown (to-dos, code)")

        let issues: [[String: Any]] = [
            ["number": 7, "title": "Crash on login", "body": "Steps…", "updated_at": "2026-11-01T10:00:00Z", "html_url": "https://github.com/acme/app/issues/7",
             "labels": [["name": "bug"]], "user": ["login": "ana"], "comments": 2],
            ["number": 9, "title": "Faster sync", "body": "", "updated_at": "2026-11-02T10:00:00Z", "pull_request": [:], "html_url": "https://github.com/acme/app/pull/9"],
        ]
        let commits: [[String: Any]] = [["sha": "abc1234def", "commit": ["message": "Fix login crash\n\nDetails", "author": ["name": "Ana", "date": "2026-11-02T09:00:00Z"]]]]
        let gh = GitHubSource.items(repo: "acme/app", info: ["full_name": "acme/app", "description": "The Acme app"], readme: "# Acme\nSetup…",
                                    issues: issues, commits: commits)
        check(gh.map(\.key) == ["readme", "issue-7", "issue-9", "commits"], "a repo gives its README, each open issue and PR, and recent commits")
        check(gh[1].draft.text.contains("labels: bug") && gh[2].draft.title?.hasPrefix("PR #9") == true
              && gh[3].draft.text.contains("abc1234 Fix login crash (Ana, 2026-11-02)"), "issues keep labels, PRs are marked, commits are listed")

        let html = """
        <html><head><title>Release notes &amp; plans</title><script>var x = "<p>no</p>";</script></head>
        <body><nav>Home · Docs</nav><main><h1>Release 2.0</h1><p>Ships on <b>March&nbsp;15</b>.</p><ul><li>Faster</li><li>Safer</li></ul>
        \(String(repeating: "<p>More detail about the release.</p>", count: 14))</main><footer>© Acme</footer></body></html>
        """
        let page = HTMLText.text(html)
        check(HTMLText.title(html) == "Release notes & plans" && page.contains("Ships on March 15.") && page.contains("- Faster")
              && !page.contains("Home · Docs") && !page.contains("no</p>") && !page.contains("© Acme"),
              "web pages keep their main text, without scripts, menus or footers")

        check(PageText.samePage("https://mail.google.com/mail/u/0/#inbox/FMfcgzQXJabcdefghijk",
                                "https://mail.google.com/mail/u/0/#label/Acme/FMfcgzQXJabcdefghijk"),
              "a Gmail thread is recognized whichever label you open it from")
        check(MailThread.normalize("Re: Fwd: RE: Q3   plan") == "q3 plan", "a Mail thread matches its replies and forwards")

        // A folder kept in sync.
        let folder = root.appendingPathComponent("Linked folder", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: folder.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try? "# Plan\nLaunch March 15".write(to: folder.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)
        try? "notes".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try? "skip".write(to: folder.appendingPathComponent("node_modules/dep.js"), atomically: true, encoding: .utf8)
        try? Data([0x89, 0x50]).write(to: folder.appendingPathComponent("logo.png"))
        let src = PackSource(kind: .folder, location: folder.path, title: "Linked folder")
        store.saveSources([src], for: trip.id)
        store.load()
        check(store.sources(for: trip.id).first?.location == folder.path, "a pack remembers its sources after reloading")
        if let scan = try? await FolderSource.scan(path: folder.path, known: [:]) {
            check(Set(scan.changed.map(\.key)) == ["plan.md", "notes.txt"], "a folder's documents are read, not images or node_modules")
            for item in scan.changed { store.upsertSourceItem(packID: trip.id, sourceID: src.id, key: item.key, rev: item.rev, draft: item.draft) }
            let known = Dictionary(uniqueKeysWithValues: store.pack(trip.id)!.captures.compactMap { c in c.sourceKey.map { ($0, c.sourceRev ?? "") } })
            let again = try? await FolderSource.scan(path: folder.path, known: known)
            check(again?.changed.isEmpty == true, "an unchanged folder changes nothing")
            try? "# Plan\nLaunch moved to March 22".write(to: folder.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)
            let later = Date().addingTimeInterval(5)
            try? fm.setAttributes([.modificationDate: later], ofItemAtPath: folder.appendingPathComponent("plan.md").path)
            try? fm.removeItem(at: folder.appendingPathComponent("notes.txt"))
            if let third = try? await FolderSource.scan(path: folder.path, known: known) {
                for item in third.changed { store.upsertSourceItem(packID: trip.id, sourceID: src.id, key: item.key, rev: item.rev, draft: item.draft) }
                let removed = store.removeSourceItems(packID: trip.id, sourceID: src.id, keep: third.present)
                let mine = store.pack(trip.id)!.captures.filter { $0.sourceID == src.id.uuidString }
                check(third.changed.map(\.key) == ["plan.md"] && removed == 1 && mine.count == 1 && mine[0].text.contains("March 22"),
                      "an edited file updates its note in place, and a deleted file's note goes away")
            }
        } else {
            check(false, "a linked folder can be read")
        }
        let reread = store.pack(trip.id)!.captures.first { $0.sourceID != nil }
        let back = reread.flatMap { CaptureFile.parse(CaptureFile.serialize($0), fileName: $0.fileName) }
        check(back != nil && back?.sourceID == reread?.sourceID && back?.sourceKey == "plan.md" && back?.sourceRev == reread?.sourceRev,
              "a live note keeps which source and version it came from on disk")
        var failing = PackSource(kind: .github, location: "acme/app", title: "acme/app")
        failing.lastError = "GitHub refused the token"
        var oldPage = PackSource(kind: .page, location: "https://docs.google.com/document/d/1", title: "Doc")
        oldPage.lastChecked = Date().addingTimeInterval(-9 * 86_400)
        var fresh = PackSource(kind: .web, location: "https://acme.com", title: "acme.com")
        fresh.lastChecked = Date().addingTimeInterval(-120)
        check(failing.status().stale && oldPage.status().stale && !fresh.status().stale && fresh.status().text.hasPrefix("Updated"),
              "a source that failed or hasn't been seen in a while is flagged as possibly out of date")

        print("Ask the pack")
        capture("Ana: the deadline for the Acme proposal moved to March 22. Budget stays at $40k.", title: "Call notes with Ana", into: acme)
        let hits = AskEngine.hits(for: "what did they say about the deadline?", in: store.packs.filter { !$0.isStyle })
        check(hits.first?.packID == acme.id && hits.first?.excerpt.text.contains("March 22") == true,
              "asking every pack finds the note that answers it (\(hits.first?.excerpt.title ?? "none"))")
        check(!hits.contains { $0.packID == trip.id || $0.packID == style.id }, "packs that don't match, and style packs, add nothing")
        let askPrompt = AskEngine.prompt(question: "When is the deadline?", hits: hits)
        check(askPrompt.contains("[1] Call notes with Ana (Acme") && askPrompt.contains("Your notes don't say"),
              "the answer is written only from the notes found, with citations")

        print("Voice notes")
        check(VoiceNoteController.title(for: "Remember to send Ana the numbers. Also book the room.") == "Voice note: Remember to send Ana the numbers.",
              "a voice note is titled by its first sentence")

        print("Talk to Shapr")
        let names = ["Acme", "Bug #42", "Japan Trip", "My Writing"]
        let said: [(String, VoiceCommand)] = [
            ("Draft a reply saying I'll send it Friday.", .draft("I'll send it Friday")),
            ("Hey Shapr, reply to this email", .draft("")),
            ("Ask Acme when the proposal is due", .ask("when the proposal is due", pack: "Acme")),
            ("Ask my packs about the invoice", .ask("the invoice", pack: nil)),
            ("What did they say about the deadline?", .ask("What did they say about the deadline?", pack: nil)),
            ("Fill this form", .fill),
            ("Can you fill out the application please", .fill),
            ("Save this to the Japan trip pack", .scoop(pack: "Japan Trip")),
            ("Save this", .scoop(pack: nil)),
            ("Save my progress", .saveProgress),
            ("Pick up where I left off", .resume),
            ("Continue in ChatGPT", .continueIn("ChatGPT")),
            ("Move this chat to Claude", .continueIn("Claude")),
            ("Switch to bug 42", .equip("Bug #42")),
            ("Use the Acme pack", .equip("Acme")),
            ("Turn on auto sort", .autoSort),
            ("Make a new pack called history essay", .newPack("history essay")),
            ("Keep this page updated in Acme", .keepUpdated(pack: "Acme")),
            ("Take a screenshot", .screenshot),
            ("Open the library", .library),
            ("What can I say", .help),
            ("Use this with my pack", .use),
            ("Take a note: Ana prefers calls after 3", .note("Ana prefers calls after 3")),
            ("Remember to call Ana tomorrow", .note("Remember to call Ana tomorrow")),
            ("The supplier said shipping is delayed two weeks", .note("The supplier said shipping is delayed two weeks")),
            ("Switch to Narnia", .note("Switch to Narnia")),
        ]
        let wrongVoice = said.filter { VoiceCommand.parse($0.0, packs: names) != $0.1 }
        for w in wrongVoice { print("    heard “\(w.0)” → \(VoiceCommand.parse(w.0, packs: names))") }
        check(wrongVoice.isEmpty, "spoken commands run the right thing (\(said.count - wrongVoice.count) of \(said.count))")
        check(VoiceCommand.parse("Switch to Narnia", packs: names) == .note("Switch to Narnia"),
              "a pack that doesn't exist isn't guessed; it's kept as a note instead")

        print("Voice first")
        let more: [(String, VoiceCommand)] = [
            ("Show options", .quick),
            ("Tell me what Ana said about pricing", .ask("Tell me what Ana said about pricing", pack: nil)),
            ("Explain this error.", .screen("Explain this error", pack: nil)),
            ("Summarize the Acme pack", .ask("Summarize the Acme pack", pack: nil)),
            ("Show me the invoice from Ana", .ask("Show me the invoice from Ana", pack: nil)),
            ("Show me my packs", .library),
            ("Remind me to call Ana", .note("Remind me to call Ana")),
            ("Add it to Japan trip", .scoop(pack: "Japan Trip")),
        ]
        let wrongMore = more.filter { VoiceCommand.parse($0.0, packs: names) != $0.1 }
        for w in wrongMore { print("    heard “\(w.0)” → \(VoiceCommand.parse(w.0, packs: names))") }
        check(wrongMore.isEmpty, "questions in any form go to Ask; “show options” opens what you can do here (\(more.count - wrongMore.count) of \(more.count))")
        check(VoiceCommand.looksLikeRequest("Could you get the form filled for me") && VoiceCommand.looksLikeRequest("Get the Acme stuff up")
              && !VoiceCommand.looksLikeRequest("The supplier said shipping is delayed") && !VoiceCommand.looksLikeRequest("Remind me to call Ana"),
              "only things that sound like requests go to the on-device model; dictation stays a note")
        check(VoiceIntent.map(VoiceIntentChoice(action: "switch_pack", pack: "Narnia", text: ""), packs: names, said: "x") == nil
              && VoiceIntent.map(VoiceIntentChoice(action: "switch_pack", pack: "acme", text: ""), packs: names, said: "x") == .equip("Acme")
              && VoiceIntent.map(VoiceIntentChoice(action: "ask", pack: "", text: ""), packs: names, said: "the invoice?") == .ask("the invoice?", pack: nil)
              && VoiceIntent.map(VoiceIntentChoice(action: "fill_form", pack: "", text: ""), packs: names, said: "x") == .fill,
              "the model's choice only runs with packs that exist")
        if case .available = SystemLanguageModel.default.availability {
            let understood = await VoiceIntent.classify("Could you get this application filled in for me", packs: names)
            print("    on-device model understood: \(understood.map { "\($0)" } ?? "nothing")")
            check(understood == .fill, "the on-device model understands a request in other words (“get this application filled in”)")
        }
        print("Answering what's on screen")
        let course = ["MAT223", "Acme", "Japan Trip"]
        let onScreen: [(String, VoiceCommand)] = [
            ("Answer this question using my MAT223 pack.", .screen("Answer this question using my MAT223 pack", pack: "MAT223")),
            ("Use my MAT223 pack to answer this", .screen("Use my MAT223 pack to answer this", pack: "MAT223")),
            ("Solve this", .screen("Solve this", pack: nil)),
            ("What's on my screen?", .screen("What's on my screen", pack: nil)),
            ("What does this mean?", .screen("What does this mean", pack: nil)),
            ("Help me with this problem", .screen("Help me with this problem", pack: nil)),
            ("Answer this email saying yes", .draft("yes")),
            ("Take a screenshot", .screenshot),
        ]
        let wrongScreen = onScreen.filter { VoiceCommand.parse($0.0, packs: course) != $0.1 }
        for w in wrongScreen { print("    heard “\(w.0)” → \(VoiceCommand.parse(w.0, packs: course))") }
        check(wrongScreen.isEmpty, "“answer this using my MAT223 pack” reads your screen and uses that pack; an email to answer is still a draft (\(onScreen.count - wrongScreen.count) of \(onScreen.count))")
        check(VoiceCommand.mentionedPack("what's the deadline in acme", packs: course) == "Acme"
              && VoiceCommand.mentionedPack("solve it with the mat 223 notes", packs: course) == nil,
              "a pack named in a typed question is used for it; a near miss isn't guessed")
        let problem = "Let A = [2 1; 1 2]. Find the eigenvalues of A and a basis for each eigenspace."
        check(AskEngine.wantsSolution(AskEngine.solveDefault, shotText: "") && AskEngine.wantsSolution("", shotText: problem)
              && AskEngine.wantsSolution("use my MAT223 pack to answer this", shotText: "") && !AskEngine.wantsSolution("what app is this?", shotText: "Settings"),
              "a question on screen gets worked out in full; a question about the screen just gets answered")
        let bigHits = (0..<20).map { i in AskModel.Hit(packID: UUID(), packName: "MAT223", excerpt: PackAssist.Excerpt(
            captureID: UUID(), index: i, title: "Lecture \(i)", source: "q.utoronto.ca", text: String(repeating: "eigenvalue ", count: 70), score: 1, isCode: false)) }
        let solvePrompt = AskEngine.prompt(question: AskEngine.solveDefault, hits: bigHits, shotText: problem, solve: true, budget: 6500)
        check(solvePrompt.contains("step by step") && solvePrompt.contains("Find the eigenvalues") && solvePrompt.count < 7600
              && AskEngine.solveSystem.contains("Answer:") && AskEngine.solveSystem.contains("not LaTeX"),
              "solving asks for the steps and a final answer, in readable math, and fits the on-device model's room")
        if let ctx = CGContext(data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let big = ctx.makeImage(),
           let small = ScreenCapture.pngForAI(big), let rep = NSBitmapImageRep(data: small) {
            check(rep.pixelsWide == 1568 && rep.pixelsHigh == 1045, "a full-window screenshot is shrunk to 1568 px before it's sent")
        } else {
            check(false, "a full-window screenshot is shrunk to 1568 px before it's sent")
        }

        let shotPrompt = AskEngine.prompt(question: "What does this error mean?", hits: [], shotText: "TypeError: x.map is not a function")
        check(shotPrompt.contains("TypeError: x.map is not a function") && !shotPrompt.contains("Your notes don't say")
              && AskEngine.shotSystem.contains("screenshot"), "asking about a screenshot sends what's on it along with your notes")
        let keys = ShortcutsList.items.map(\.1)
        check(ShortcutSettings.classic || (keys.contains("⌥V") && keys.contains("⌥C") && keys.contains("⌥S") && !keys.contains("⌥⇧D")),
              "by default the keys are ⌥V (talk), ⌥C (scoop), ⌥S (wheel) and the circle; the rest is voice")

        print("Simpler, glassier look")
        check(PackStyle.initials("Japan Trip") == "JT" && PackStyle.initials("MAT223") == "M" && PackStyle.initials("Bug #42") == "B"
              && PackStyle.initials("about me") == "AM" && PackStyle.initials("") == "",
              "each pack gets an orb with its initials instead of an emoji")
        var emojiPack = store.packs.first!
        emojiPack.meta.emoji = "🚗"
        check(emojiPack.label == emojiPack.name && !emojiPack.badge.unicodeScalars.contains { $0.properties.isEmojiPresentation },
              "packs are shown by name and orb, never with emoji")
        check(!GlassSettings.snapshotFallback, "the real Liquid Glass is used in the app (the stand-in is only for offscreen renders)")
        let hueRoot = root.appendingPathComponent("hues", isDirectory: true)
        let hueStore = PackStore(root: hueRoot, defaults: defaults, persistPrefs: false)
        let made = (1...6).map { hueStore.createPack(name: "Hue \($0)", emoji: nil, autoNamed: false) }
        check(Set(made.map { PackStyle.index($0.id) }).count == 6, "new packs each get a color of their own")
        // Two packs from before 0.16 whose ids suggest the same color: the newer one moves, once, and keeps it.
        let legacyRoot = root.appendingPathComponent("hues-legacy", isDirectory: true)
        let older = UUID()
        var newer = UUID()
        while PackStyle.hashIndex(newer) != PackStyle.hashIndex(older) { newer = UUID() }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        for (id, name, age) in [(older, "Older", 0.0), (newer, "Newer", 60.0)] {
            let dir = legacyRoot.appendingPathComponent("Packs/\(name)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let meta = PackMeta(id: id, name: name, emoji: nil, created: Date(timeIntervalSince1970: 1_790_000_000 + age), autoNamed: false)
            try? enc.encode(meta).write(to: dir.appendingPathComponent("pack.json"))
        }
        let legacy = PackStore(root: legacyRoot, defaults: defaults, persistPrefs: false)
        let olderHue = PackStyle.index(older), newerHue = PackStyle.index(newer)
        let savedHue = legacy.pack(newer)?.meta.hue
        _ = PackStore(root: legacyRoot, defaults: defaults, persistPrefs: false)
        check(olderHue == PackStyle.hashIndex(older) && newerHue != olderHue && savedHue == newerHue
              && PackStyle.index(newer) == newerHue,
              "two older packs that shared a color are told apart, and keep their colors after a reload")
        print("Voice does what you say, several things in a row")
        let ap = ["Acme", "MAT223", "Japan Trip"]
        let spoken: [(String, VoiceCommand)] = [
            ("Undo that", .undo), ("Move that to Acme", .moveLast(pack: "Acme")),
            ("Rename this pack to Globex", .rename(pack: nil, to: "Globex")), ("Rename Acme to Globex", .rename(pack: "Acme", to: "Globex")),
            ("Type see you at five", .type("see you at five")), ("Show me the map of Acme", .map(pack: "Acme")),
            ("Open MAT223", .openPack("MAT223")), ("Open Safari", .openApp("Safari")), ("Open the library", .library),
            ("Share Acme", .share(pack: "Acme")), ("Copy the Acme pack for Claude", .copyPack(pack: "Acme")),
            ("Search the web for flights to Tokyo", .web("flights to Tokyo")), ("Stop", .stop),
            ("Summarize this page", .screen("Summarize this page", pack: nil)),
            ("Translate this to French", .screen("Translate this to French", pack: nil)),
            ("Go to Acme", .equip("Acme")),
        ]
        let missed = spoken.filter { VoiceCommand.parse($0.0, packs: ap) != $0.1 }
        for m in missed { print("    heard “\(m.0)” → \(VoiceCommand.parse(m.0, packs: ap))") }
        check(missed.isEmpty, "undo, move, rename, type, open, share, copy, search, the map and “summarize this page” all work by voice (\(spoken.count - missed.count) of \(spoken.count))")
        let plans: [(String, [VoiceCommand])] = [
            ("Switch to Acme, then add this", [.equip("Acme"), .scoop(pack: nil)]),
            ("Add this to Acme and draft a reply saying thanks", [.scoop(pack: "Acme"), .draft("thanks")]),
            ("Save progress and continue in Claude", [.saveProgress, .continueIn("Claude")]),
            ("Switch to MAT223 and answer this", [.equip("MAT223"), .screen("answer this", pack: nil)]),
            ("Switch to Acme. Add this.", [.equip("Acme"), .scoop(pack: nil)]),
            ("Draft a reply saying yes and thanks for the update", [.draft("yes and thanks for the update")]),
            ("What is the rank and nullity of this matrix", [.ask("What is the rank and nullity of this matrix", pack: nil)]),
            ("Add this and that to Acme", [.scoop(pack: "Acme")]),
            ("The meeting moved to Friday and Ana will call", [.note("The meeting moved to Friday and Ana will call")]),
        ]
        let wrongPlans = plans.filter { VoiceCommand.plan($0.0, packs: ap) != $0.1 }
        for w in wrongPlans { print("    heard “\(w.0)” → \(VoiceCommand.plan(w.0, packs: ap))") }
        check(wrongPlans.isEmpty, "“then” and “and” between things Shapr does make steps; an “and” inside your own words doesn't (\(plans.count - wrongPlans.count) of \(plans.count))")
        check(VoiceCommand.looksLikeRequest("Translate the second paragraph") && !VoiceCommand.looksLikeRequest("The supplier said shipping is delayed"),
              "a sentence that starts with a verb is treated as a request, even one Shapr has no rule for")
        let twoSteps = VoicePlanChoice(steps: [VoiceIntentChoice(action: "switch_pack", pack: "acme", text: ""),
                                               VoiceIntentChoice(action: "type_text", pack: "", text: "on my way")])
        let badStep = VoicePlanChoice(steps: [VoiceIntentChoice(action: "switch_pack", pack: "Narnia", text: "")])
        check(VoiceIntent.steps(twoSteps, packs: ap, said: "x") == [.equip("Acme"), .type("on my way")] && VoiceIntent.steps(badStep, packs: ap, said: "x") == nil,
              "the on-device model can plan several steps, and a step it can't ground stops the whole plan")
        check(VoiceCommand.scoop(pack: nil).opensPanel == false && VoiceCommand.draft("x").opensPanel && VoiceCommand.fill.opensPanel,
              "steps that need you (a draft, a form) end a run; quick ones carry straight on")

        print("“Get the context of this chat”")
        let chatSaid: [(String, VoiceCommand)] = [
            ("Get context of this chat", .scoop(pack: nil)), ("Get the context from this chat", .scoop(pack: nil)),
            ("Grab everything from this conversation", .scoop(pack: nil)), ("Add this chat as context", .scoop(pack: nil)),
            ("Add this as context", .scoop(pack: nil)), ("Save the chat", .scoop(pack: nil)), ("Remember this chat", .scoop(pack: nil)),
            ("Use this page as context", .scoop(pack: nil)), ("Save this conversation to Acme", .scoop(pack: "Acme")),
            ("Get the context of this chat into my Acme pack", .scoop(pack: "Acme")),
            ("Remember to call Ana", .note("Remember to call Ana")),
        ]
        let screenSaid: [(String, VoiceCommand)] = [
            ("Get context of my screen", .addScreen(pack: nil)), ("Add my screen to Acme", .addScreen(pack: "Acme")),
            ("Get what's on my screen", .addScreen(pack: nil)), ("Save my whole screen to my Japan Trip pack", .addScreen(pack: "Japan Trip")),
            ("Add my current chat to Acme", .scoop(pack: "Acme")), ("Add my WhatsApp chat to Acme", .scoop(pack: "Acme")),
            ("Add the entire chat to my Japan Trip pack", .scoop(pack: "Japan Trip")), ("Save this WhatsApp conversation", .scoop(pack: nil)),
            ("Remember my Gemini chat", .scoop(pack: nil)),
            ("Take a screenshot", .screenshot), ("Add milk to Acme", .note("Add milk to Acme")),
        ]
        let screenMissed = screenSaid.filter { VoiceCommand.parse($0.0, packs: ap) != $0.1 }
        for m in screenMissed { print("    heard “\(m.0)” → \(VoiceCommand.parse(m.0, packs: ap))") }
        check(screenMissed.isEmpty, "“my screen” saves a picture of the screen, read; “my chat” saves the chat, whichever app it's in (\(screenSaid.count - screenMissed.count) of \(screenSaid.count))")
        check(VoiceCommand.plan("Take a screenshot and add it to Acme", packs: ap) == [.addScreen(pack: "Acme")]
              && VoiceCommand.plan("Add my screen to Acme, then switch to MAT223", packs: ap) == [.addScreen(pack: "Acme"), .equip("MAT223")],
              "“take a screenshot and add it” is one step, and still chains with “then”")
        check(WindowText.join(["Ana, see you at five, 10:42", "see you at five", "10:42", "", "Me, ok, 10:43", "ok", "Hello", "Hello there, how are you"])
              == "Ana, see you at five, 10:42\nMe, ok, 10:43\nHello there, how are you",
              "a chat window's text is read once: a message isn't repeated by the pieces it's made of")
        let chatMissed = chatSaid.filter { VoiceCommand.parse($0.0, packs: ap) != $0.1 }
        for m in chatMissed { print("    heard “\(m.0)” → \(VoiceCommand.parse(m.0, packs: ap))") }
        check(chatMissed.isEmpty, "asking for the context of a chat, page or window saves it, into the pack you name (\(chatSaid.count - chatMissed.count) of \(chatSaid.count))")
        let talk = ChatTranscript(service: "ChatGPT", url: "https://chatgpt.com/c/xyz", title: "Rank-nullity help", turns: [
            ChatTurn(role: .user, text: "What is the rank-nullity theorem?"),
            ChatTurn(role: .assistant, text: "rank(A) + nullity(A) = n for an m×n matrix A.")])
        let talkDraft = AppController.draft(for: talk, bundleID: "com.apple.Safari")
        check(talkDraft.title == "Rank-nullity help · 2 messages" && talkDraft.appName == "ChatGPT" && talkDraft.url == talk.url
              && talkDraft.text.contains("Me: What is the rank-nullity theorem?") && talkDraft.text.contains("ChatGPT: rank(A) + nullity(A) = n"),
              "a chat is saved whole: every message, word for word, under the chat's name")
        let chatStore = PackStore(root: root.appendingPathComponent("chats", isDirectory: true), defaults: defaults, persistPrefs: false)
        let chatPack = chatStore.createPack(name: "Chats", emoji: nil, autoNamed: false)
        chatStore.add(talkDraft, to: chatPack.id)
        chatStore.add(CaptureDraft(text: "Unrelated note from the same site", appName: "Safari", title: "Other", url: "https://chatgpt.com/c/other"), to: chatPack.id)
        var longer = talk
        longer.turns.append(ChatTurn(role: .user, text: "Show me an example."))
        let longerDraft = AppController.draft(for: longer, bundleID: "com.apple.Safari")
        chatStore.add(longerDraft, to: chatPack.id)
        let stale = AppController.olderCopies(of: longer, in: chatStore.pack(chatPack.id)!, keeping: longerDraft.text)
        check(stale.count == 1 && stale.first?.title == "Rank-nullity help · 2 messages",
              "saving the same chat again later replaces the earlier copy and leaves everything else alone")

        print("The map of a pack")
        let graphStore = PackStore(root: root.appendingPathComponent("graph", isDirectory: true), defaults: defaults, persistPrefs: false)
        let mapped = graphStore.createPack(name: "Mixed", emoji: nil, autoNamed: false)
        for (title, text) in [
            ("Lecture 14", "Eigenvalues of a matrix are the roots of the characteristic polynomial. Each eigenvalue has an eigenspace."),
            ("Problem set", "Find the eigenvalues of the matrix and a basis for each eigenspace."),
            ("Kyoto hotels", "Three hotels near Kyoto station with tatami rooms; the ryokan includes breakfast."),
            ("Kyoto trains", "The Shinkansen from Tokyo reaches Kyoto station in about two hours; reserve seats."),
            ("Dentist", "Appointment moved to Friday afternoon.")] {
            graphStore.add(CaptureDraft(text: text, appName: "Safari", title: title), to: mapped.id)
        }
        let graph = PackGraph.build(graphStore.pack(mapped.id)!)
        let near = graph.neighbors
        let topicLabels = Set(graph.nodes.filter(\.isTopic).map(\.label))
        func together(_ a: Int, _ b: Int) -> Bool { near[a].contains(b) || !near[a].intersection(near[b]).isEmpty }
        check(graph.captureCount == 5 && topicLabels.contains { $0.hasPrefix("eigen") } && topicLabels.contains("kyoto"),
              "a pack's map has a dot per capture and a ring per topic they share (\(topicLabels.sorted()))")
        check(together(0, 1) && together(2, 3) && !together(0, 2) && !together(1, 3) && graph.nodes[4].degree == 0,
              "captures about the same thing are joined; unrelated ones aren't")
        check(PackGraph.build(graphStore.pack(mapped.id)!) == graph, "the map comes out the same every time")
        let sim = GraphSim()
        sim.load(graph)
        func gap(_ a: Int, _ b: Int) -> CGFloat { hypot(sim.pos[a].x - sim.pos[b].x, sim.pos[a].y - sim.pos[b].y) }
        let pairs = graph.nodes.indices.flatMap { a in graph.nodes.indices.filter { $0 > a }.map { (a, $0) } }
        let farthest = sim.pos.map { hypot($0.x, $0.y) }.max() ?? 0
        let closest = pairs.map { gap($0.0, $0.1) }.min() ?? 0
        let longest = graph.edges.map { gap($0.a, $0.b) }.max() ?? 0
        check(sim.pos.count == graph.nodes.count && sim.pos.allSatisfy { $0.x.isFinite && $0.y.isFinite } && farthest < 500
              && closest > 14 && longest < 170,
              "the map settles with joined things close and nothing on top of anything else (farthest \(Int(farthest)), closest \(Int(closest)), longest link \(Int(longest)))")

        let adds: [(String, VoiceCommand)] = [
            ("Add this", .scoop(pack: nil)),
            ("Add this to my Acme pack", .scoop(pack: "Acme")),
            ("Save this page", .scoop(pack: nil)),
            ("Add what's on my screen", .addScreen(pack: nil)),
            ("Add to my pack", .scoop(pack: nil)),
            ("Add a note: call Ana", .note("call Ana")),
            ("What's on my screen?", .screen("What's on my screen", pack: nil)),
            ("When is the Acme proposal due?", .ask("When is the Acme proposal due?", pack: nil)),
        ]
        let wrongAdds = adds.filter { VoiceCommand.parse($0.0, packs: names) != $0.1 }
        for w in wrongAdds { print("    heard “\(w.0)” → \(VoiceCommand.parse(w.0, packs: names))") }
        check(wrongAdds.isEmpty, "⌥V does the two big things: “add this” saves (the page or screen if nothing's selected), and questions get answered (\(adds.count - wrongAdds.count) of \(adds.count))")

        print("Whole forms")
        let dummy = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var country = FormField(id: 1, element: dummy, label: "Country", placeholder: nil, currentValue: "Select…", isSecure: false,
                                isMultiline: false, sensitive: nil)
        country.kind = .choice
        country.options = ["Select…", "Canada", "Pakistan", "United States"]
        var adult = FormField(id: 2, element: dummy, label: "I am 18 or older", placeholder: nil, currentValue: "no", isSecure: false,
                              isMultiline: false, sensitive: nil)
        adult.kind = .checkbox
        var terms = FormField(id: 3, element: dummy, label: "I agree to the Terms and Privacy Policy", placeholder: nil, currentValue: "no",
                              isSecure: false, isMultiline: false, sensitive: nil)
        terms.kind = .checkbox
        var start = FormField(id: 4, element: dummy, label: "Start date", placeholder: nil, currentValue: nil, isSecure: false,
                              isMultiline: false, sensitive: nil)
        start.kind = .date
        let formPrompt = FormMapper.prompt(fields: [country, adult, start], context: FormMapper.Context(markdown: "Lives in Lahore, Pakistan", refs: []),
                                           target: DropTarget(app: nil, appName: "Safari", destination: .generic, label: "Safari"))
        check(formPrompt.contains("1: Country {Select…} (choose one: Select… | Canada | Pakistan | United States)")
              && formPrompt.contains("2: I am 18 or older {no} (yes/no checkbox)") && formPrompt.contains("4: Start date (date)"),
              "the model sees each dropdown's options, checkboxes and date fields")
        check(terms.isConsent && !adult.isConsent, "agreeing to terms is never ticked for you; ordinary checkboxes are")
        check(FormMapper.option(matching: "pakistan", in: country.options) == "Pakistan"
              && FormMapper.option(matching: "United States of America", in: country.options) == "United States"
              && FormMapper.option(matching: "Mars", in: country.options) == nil, "an answer is matched to the exact option, or dropped")
        let ctx = "lives in lahore pakistan started 2026 03 15"
        let graded = FormMapper.grounded([1: FieldAnswer(value: "Pakistan", source: nil), 2: FieldAnswer(value: "yes", source: nil),
                                          4: FieldAnswer(value: "2026-03-15", source: 1)],
                                         fields: [country, adult, start], context: ctx)
        check(graded[1]?.value == "Pakistan" && graded[2]?.value == "" && graded[4]?.value == "2026-03-15",
              "a choice backed by your notes is kept; a yes/no with no source is dropped; a cited date is kept")
        let d = DateEntry.parse("2026-03-15")!
        check(DateEntry.keystrokes(for: d, locale: Locale(identifier: "en_US")) == "03152026"
              && DateEntry.keystrokes(for: d, locale: Locale(identifier: "en_GB")) == "15032026"
              && DateEntry.keystrokes(for: d, order: ["M", "d", "y"], locale: Locale(identifier: "en_GB")) == "03152026",
              "dates are typed in the field's own order when it shows one, else this Mac's region order")
    }
}
