import AppKit
import CoreText
import SwiftUI

/// `Shapr --selftest` exercises storage, auto-sorting, export and Safe Share without any UI or permissions.
/// Runs against a throwaway folder, never ~/Shapr.
@MainActor
enum SelfTest {
    private static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS" : "  FAIL", what)
        if !ok { failures += 1 }
    }

    /// White image with black text, standing in for a real screen capture.
    static func textImage(_ text: String) -> CGImage {
        let size = NSSize(width: 640, height: 160)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(in: NSRect(x: 20, y: 20, width: 600, height: 120),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 28, weight: .medium), .foregroundColor: NSColor.black])
        img.unlockFocus()
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    static func run() async -> Int32 {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("shapr-selftest-\(UUID().uuidString)")
        let suite = "app.shapr.selftest"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer {
            try? FileManager.default.removeItem(at: tmp)
            defaults.removePersistentDomain(forName: suite)
        }

        print("Front matter")
        let original = Capture(id: UUID(), text: "Line one\n\nLine \"two\" with: colons\n---\nend", capturedAt: Date(timeIntervalSince1970: 1_790_000_000),
                               appName: "Safari", bundleID: "com.apple.Safari", title: "A \"quoted\" title: yes",
                               url: "https://example.com/a?b=c", fileName: "x.md")
        let parsed = CaptureFile.parse(CaptureFile.serialize(original), fileName: "x.md")
        check(parsed == original, "capture survives a write/read round trip")

        print("Auto-sort (\(Sorter().appleModelAvailable ? "on-device model" : "keyword fallback"))")
        let store = PackStore(root: tmp, defaults: defaults)
        let sorter = Sorter()
        let drafts: [CaptureDraft] = [
            CaptureDraft(text: "The 2025 Toyota Supra uses a turbocharged inline-six engine making 382 horsepower.",
                         title: "Toyota Supra specs", url: "https://www.caranddriver.com/toyota/supra"),
            CaptureDraft(text: "Elden Ring is an open-world action RPG developed by FromSoftware and released in 2022.",
                         title: "Elden Ring – Wikipedia", url: "https://en.wikipedia.org/wiki/Elden_Ring"),
            CaptureDraft(text: "Electric cars like the Tesla Model 3 cost less to maintain than gasoline cars.",
                         title: "EV maintenance costs", url: "https://www.motortrend.com/ev-costs"),
            CaptureDraft(text: "The Nintendo Switch 2 launched with better graphics and runs most Switch games.",
                         title: "Switch 2 review", url: "https://www.ign.com/switch-2-review"),
            CaptureDraft(text: "TypeError: Cannot read properties of undefined (reading 'map') at Dashboard.render (Dashboard.tsx:42)",
                         title: "Issue #42 · dashboard crash", url: "https://github.com/acme/app/issues/42"),
        ]
        for d in drafts {
            let decision = await sorter.decide(d, packs: store.summaries())
            let target: UUID
            if let id = decision.packID, store.pack(id) != nil {
                target = id
            } else {
                target = store.createPack(name: decision.name, emoji: decision.emoji, autoNamed: true).id
            }
            store.add(d, to: target)
            print("    \(d.title ?? "") → \(store.pack(target)?.label ?? "?") [\(decision.engine)]")
        }
        func packOf(_ i: Int) -> UUID? { store.packs.first { $0.captures.contains { $0.title == drafts[i].title } }?.id }
        check(packOf(0) == packOf(2), "the two car snippets share a pack")
        check(packOf(1) == packOf(3), "the two video-game snippets share a pack")
        check(packOf(0) != packOf(1), "cars and video games are in different packs")
        check(packOf(4) != packOf(0) && packOf(4) != packOf(1), "the bug report gets its own pack")

        print("Disk")
        let reloaded = PackStore(root: tmp, defaults: defaults)
        check(reloaded.packs.map(\.id).sorted { $0.uuidString < $1.uuidString }
              == store.packs.map(\.id).sorted { $0.uuidString < $1.uuidString }, "packs reload with the same ids")
        check(reloaded.packs.flatMap(\.captures).count == drafts.count, "all captures reload")
        check(store.wheelSlots.compactMap { $0 }.count == store.packs.count, "every pack has a wheel slot")

        if let cars = packOf(0), let games = packOf(1), let capture = store.pack(cars)?.captures.first {
            store.rename(cars, to: "Fast Cars")
            check(store.pack(cars)?.folder.lastPathComponent == "fast-cars", "rename moves the folder")
            store.moveCapture(capture.id, to: games)
            check(store.pack(games)?.captures.contains { $0.id == capture.id } == true, "move puts the capture in the other pack")
            check(FileManager.default.fileExists(atPath: store.pack(games)!.folder
                .appendingPathComponent(store.pack(games)!.captures.first { $0.id == capture.id }!.fileName).path),
                  "moved file exists on disk")
            store.moveCapture(capture.id, to: cars)
        }

        print("Export")
        if let p = store.packs.first {
            let md = Exporter.markdown(packName: p.name, captures: p.captures)
            check(md.hasPrefix("# \(p.name)") && p.captures.allSatisfy { md.contains($0.text) }, "markdown has every capture")
        }

        print("Safe Share")
        let secretText = """
        Hi Jane Doe, the staging key is sk-ant-api03-abcdefghijklmnop1234 and my email is jane.doe@acme.com.
        Call me at (415) 555-0132. Card 4242 4242 4242 4242. Server 10.0.0.12. We use Toyota parts.
        """
        let c = Capture(id: UUID(), text: secretText, capturedAt: Date(), appName: nil, bundleID: nil,
                        title: "Notes", url: "https://app.example.com/view?token=abc123&id=4", fileName: "n.md")
        let flags = PrivacyScanner.scan([c], rules: RedactionRules())
        for f in flags { print("    \(f.kind.label): \(f.match) → \(f.action.rawValue)") }
        let kinds = Set(flags.map(\.kind))
        for k in [FlagKind.secret, .email, .phone, .card, .ipAddress, .secretURL] {
            check(kinds.contains(k), "flags \(k.label)")
        }
        check(flags.contains { $0.kind == .person && $0.match.contains("Jane") }, "flags the person's name")
        let shared = PrivacyScanner.apply(flags, to: c)
        check(!shared.text.contains("sk-ant") && !shared.text.contains("jane.doe@") && !shared.text.contains("4242"),
              "shared copy hides the secrets")
        check(shared.url == "https://app.example.com/view", "shared link drops the token")
        check(c.text == secretText, "original capture is untouched")

        let internalText = "Repro on https://staging.acme.internal/dash?token=abc123. Thanks!"
        let internalFlags = PrivacyScanner.scanText(internalText, captureID: UUID(), field: .text, rules: RedactionRules())
        let nameFlags = PrivacyScanner.scanText("Hi, I'm Jane Doe from Acme. The app crashes.", captureID: UUID(),
                                                field: .text, rules: RedactionRules())
        check(nameFlags.contains { $0.kind == .person && $0.match == "Jane Doe" }, "flags a full name, not just the first name")
        check(internalFlags.contains { $0.kind == .internalURL && $0.match == "https://staging.acme.internal/dash?token=abc123" },
              "flags a whole internal link (without the trailing period)")

        var rules = RedactionRules()
        if let email = flags.first(where: { $0.kind == .email }) {
            rules.rules[email.ruleKey] = .init(action: .keep, replacement: email.replacement)
        }
        let again = PrivacyScanner.scan([c], rules: rules)
        check(again.first { $0.kind == .email }?.action == .keep && again.first { $0.kind == .email }?.remembered == true,
              "a saved choice is remembered next time")

        print("New pack from the wheel")
        let fresh = store.createPack(name: PackStore.placeholderName, emoji: nil, autoNamed: true)
        if let emptySlot = store.wheelSlots.firstIndex(where: { $0 == nil }) ?? Optional(5) {
            store.place(fresh.id, inSlot: emptySlot)
            check(store.wheelSlots[emptySlot] == fresh.id, "the new pack sits in the slot you picked")
        }
        store.equip(fresh.id)
        let scoop = CaptureDraft(text: "Stripe internship: apply by Dec 1, needs a cover letter.", title: "Stripe internship")
        if let eq = store.equippedPackID { store.add(scoop, to: eq) }
        check(store.pack(fresh.id)?.captures.first?.text == scoop.text, "the next scoop goes into the new pack, not an old one")
        if let better = await sorter.name(for: [scoop.text]) {
            print("    first capture would name it: \(better.emoji ?? "") \(better.name)")
        }
        store.equip(nil)

        print("MCP server")
        let mcp = MCPServer(store: store)
        let initReply = mcp.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                    "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "selftest"]]])
        check((initReply?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18", "initialize echoes the protocol version")
        check(mcp.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil, "notifications get no reply")
        let toolsReply = mcp.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        check(((toolsReply?["result"] as? [String: Any])?["tools"] as? [Any])?.count == 8, "lists 8 tools")
        func callText(_ name: String, _ args: [String: Any]) -> (String, Bool) {
            let r = mcp.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": name, "arguments": args]])
            let result = r?["result"] as? [String: Any]
            let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            return (text, result?["isError"] as? Bool ?? true)
        }
        let made = callText("create_pack", ["name": "Chat Notes", "emoji": "💬",
                                            "captures": [["text": "We picked Postgres over Mongo.", "title": "DB decision"],
                                                         ["text": "Launch is March 3.", "title": "Launch date"]]])
        check(!made.1 && store.packs.contains { $0.name == "Chat Notes" && $0.captures.count == 2 }, "create_pack makes a pack with captures")
        let read = callText("read_pack", ["pack": "chat notes"])
        check(!read.1 && read.0.contains("Postgres") && read.0.range(of: "DB decision")!.lowerBound < read.0.range(of: "Launch date")!.lowerBound,
              "read_pack returns captures in order")
        check(callText("search_captures", ["query": "postgres"]).0.contains("Chat Notes"), "search finds a capture by word")
        check(callText("read_pack", ["pack": "nope"]).1, "an unknown pack is a tool error, not a crash")

        print(".shapr files")
        let leaky = Capture(id: UUID(), text: "Email jane.doe@acme.com, key sk-ant-api03-zzzzzzzzzzzzzzzzzz", capturedAt: Date(),
                            appName: "Mail", bundleID: "com.apple.mail", title: "Leaky note",
                            url: "https://x.example.com/a?token=secret1", fileName: "l.md")
        let packForShare = Pack(meta: PackMeta(id: UUID(), name: "Bug #42", emoji: "🐞", created: Date(), autoNamed: false),
                                folder: tmp, captures: [leaky])
        let session = ShareSession(pack: packForShare, rules: RedactionRules())
        let bundleURL = tmp.appendingPathComponent("Bug 42.shapr")
        do {
            try PackBundle.write(name: "Bug #42", emoji: "🐞", captures: session.sharedCaptures(), to: bundleURL)
            let back = try PackBundle.read(bundleURL)
            check(back.name == "Bug #42" && back.emoji == "🐞" && back.drafts.count == 1, "a .shapr file reads back with its name, emoji and captures")
            let t = back.drafts.first?.text ?? ""
            check(!t.contains("jane.doe@") && !t.contains("sk-ant"), "the .shapr file has the Safe Share redactions")
            check(back.drafts.first?.appName == nil && back.drafts.first?.url == "https://x.example.com/a",
                  "app names are off and the link lost its token")
            let before = store.packs.count
            let imported = try PackBundle.importPack(bundleURL, into: store)
            check(store.packs.count == before + 1 && imported.captures.count == 1, "importing adds a new pack")
        } catch {
            check(false, ".shapr round trip: \(error)")
        }
        let junk = tmp.appendingPathComponent("junk.shapr")
        try? Data("not a zip".utf8).write(to: junk)
        check((try? PackBundle.read(junk)) == nil, "a broken file is rejected")

        print("Drop")
        check(DropDetector.classify(bundleID: "com.google.Chrome", url: "https://mail.google.com/mail/u/0/#inbox", appName: "Chrome").0 == .email, "Gmail is an email")
        check(DropDetector.classify(bundleID: "com.tinyspeck.slackmacgap", url: nil, appName: "Slack").0 == .chat, "Slack is a chat")
        check(DropDetector.classify(bundleID: "com.apple.Safari", url: "https://github.com/acme/app/issues/new", appName: "Safari").1 == "GitHub new issue", "GitHub new issue is recognized")
        check(DropDetector.classify(bundleID: "com.apple.Safari", url: "https://claude.ai/new", appName: "Safari").0 == .aiChat, "claude.ai gets the pack as context")
        let draftParts = Drafter.parse("Title: Dashboard crashes on load\n## Summary\nIt crashes.\n\nSOURCES: 2, 1, 2")
        check(draftParts.title == "Dashboard crashes on load" && draftParts.body.hasPrefix("## Summary") && draftParts.sources == [1, 2],
              "draft output splits into title, body and sources")
        if Sorter().appleModelAvailable, let bugPack = store.packs.first(where: { $0.captures.contains { $0.title?.contains("Issue #42") == true } }) {
            let target = DropTarget(app: nil, appName: "Slack", destination: .chat, label: "Slack")
            var out = ""
            if let engine = try? await Drafter.run(pack: bugPack, target: target, instruction: "tell the team I'm on it",
                                                    allowClaude: false, onText: { out = $0 }) {
                let d = Drafter.parse(out)
                print("    [\(engine)] Slack draft: \(d.body.singleLine.truncated(160))  sources \(d.sources)")
                check(!d.body.isEmpty, "the on-device model writes a draft")
            }
        }

        print("Screen capture")
        let sample = Self.textImage("Toyota Supra: 382 hp\nZero to 60 in 3.9 seconds")
        let ocrText = OCR.recognize(sample)
        print("    OCR read: \(ocrText.singleLine)")
        check(ocrText.contains("Supra") && ocrText.contains("382"), "OCR reads text out of a screenshot")
        let png = ScreenCapture.png(sample)
        check(png != nil, "a capture becomes a PNG")
        let shotPack = store.createPack(name: "Screenshots Test", emoji: "📸", autoNamed: false)
        let shot = store.add(CaptureDraft(text: ocrText, appName: "Safari", title: "Supra specs", imageData: png), to: shotPack.id)
        let shotURL = shot.flatMap { store.imageURL(for: $0) }
        check(shot?.image != nil && shotURL.map { FileManager.default.fileExists(atPath: $0.path) } == true,
              "the screenshot is saved next to the capture")
        let again2 = PackStore(root: tmp, defaults: defaults)
        check(again2.pack(shotPack.id)?.captures.first?.image == shot?.image, "the screenshot link survives a reload")
        if let shot, let other = store.packs.first(where: { $0.id != shotPack.id }) {
            store.moveCapture(shot.id, to: other.id)
            let moved = store.pack(other.id)?.captures.first { $0.id == shot.id }
            check(moved.flatMap { store.imageURL(for: $0) }.map { FileManager.default.fileExists(atPath: $0.path) } == true,
                  "moving a capture moves its screenshot")
            check(moved.map { CaptureFile.parse((try? String(contentsOf: other.folder.appendingPathComponent($0.fileName), encoding: .utf8)) ?? "", fileName: $0.fileName)?.image == $0.image } == true,
                  "the moved file points at the moved screenshot")
            store.moveCapture(shot.id, to: shotPack.id)
        }

        if let sp = store.pack(shotPack.id) {
            let s1 = ShareSession(pack: sp, rules: RedactionRules())
            let withImages = tmp.appendingPathComponent("with.shapr"), without = tmp.appendingPathComponent("without.shapr")
            try? PackBundle.write(name: sp.name, emoji: sp.meta.emoji, captures: s1.sharedCaptures(), imageFolder: sp.folder, to: without)
            s1.includeImages = true
            try? PackBundle.write(name: sp.name, emoji: sp.meta.emoji, captures: s1.sharedCaptures(), imageFolder: sp.folder, to: withImages)
            check((try? PackBundle.read(without))?.drafts.first?.imageData == nil, "screenshots stay out of .shapr files by default")
            check((try? PackBundle.read(withImages))?.drafts.first?.imageData != nil, "screenshots go in when you turn them on")

            let r = mcp.handle(["jsonrpc": "2.0", "id": 9, "method": "tools/call",
                                "params": ["name": "read_pack", "arguments": ["pack": "Screenshots Test"]]])
            let blocks = ((r?["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            check(blocks.contains { $0["type"] as? String == "image" && $0["mimeType"] as? String == "image/jpeg" },
                  "Claude gets the screenshot through MCP")
        }

        print("Form fill")
        let cases: [(String, String?, Bool, SensitiveKind?)] = [
            ("Card number", nil, false, .cardNumber), ("CVV", nil, false, .cardCode), ("Expiration date", "MM/YY", false, .cardExpiry),
            ("Social Security Number", nil, false, .nationalID), ("Passport No.", nil, false, .passport),
            ("Password", nil, true, .password), ("Confirm", nil, true, .password), ("Routing number", nil, false, .bankAccount),
            ("Email", "you@example.com", false, nil), ("Phone number", nil, false, nil), ("First name", nil, false, nil),
            ("Why do you want to work at Stripe?", nil, false, nil), ("LinkedIn profile URL", nil, false, nil),
        ]
        let wrong = cases.filter { SensitiveKind.classify(label: $0.0, placeholder: $0.1, isSecure: $0.2) != $0.3 }
        for w in wrong { print("    misread: \(w.0)") }
        check(wrong.isEmpty, "spots password, card, ID and bank fields, and leaves normal fields alone")

        Vault.service = "app.shapr.selftest.vault"
        Vault.metadataKey = "selftest.vaultItems"
        Vault.items = []
        let card = Vault.add(kind: .cardNumber, label: "Test Visa", site: nil, value: "4242 4242 4242 4242")
        let gh = Vault.add(kind: .password, label: "GitHub", site: "https://www.github.com/login", value: "test-password-1")
        Vault.lock()
        check(card != nil && Vault.value(for: card!.id) == nil, "the Vault won't hand out values while locked")
        Vault.unlockForTesting()
        check(card.flatMap { Vault.value(for: $0.id) } == "4242 4242 4242 4242", "an unlocked Vault returns the value from the Keychain")
        check(Vault.match(.password, pageURL: "https://github.com/login")?.id == gh?.id, "a password is offered on its own site")
        check(Vault.match(.password, pageURL: "https://evil-github.example.com") == nil, "and not on a different site")
        for item in Vault.items { Vault.delete(item.id) }
        check(card.flatMap { Keychain.get($0.id.uuidString, service: Vault.service) } == nil, "deleting removes it from the Keychain")
        Vault.lock()
        UserDefaults.standard.removeObject(forKey: Vault.metadataKey)

        let me = store.createPack(name: "About Me", emoji: "🙋", autoNamed: false)
        store.add(CaptureDraft(text: "Moosa Usman · moosa.test@example.com · Toronto, Canada. CS student at the University of Toronto, graduating 2027. Built Shapr, a macOS context app in Swift.",
                               title: "Résumé basics"), to: me.id)
        check(FormMapper.defaultPacks(store).contains(me.id), "an About Me pack is used for forms by default")
        let dummy = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        func field(_ id: Int, _ label: String, multiline: Bool = false, secure: Bool = false) -> FormField {
            FormField(id: id, element: dummy, label: label, placeholder: nil, currentValue: nil, isSecure: secure,
                      isMultiline: multiline, sensitive: SensitiveKind.classify(label: label, placeholder: nil, isSecure: secure))
        }
        let form = [field(1, "Full name"), field(2, "Email"), field(3, "Card number"), field(4, "Phone"),
                    field(5, "Tell us about a project you built", multiline: true)]
        let target = DropTarget(app: nil, appName: "Safari", url: "https://jobs.example.com/apply", title: "Apply: Intern",
                                destination: .generic, label: "Safari")
        let promptText = FormMapper.prompt(fields: form.filter { $0.sensitive == nil }, context: FormMapper.context(from: [store.pack(me.id)!]), target: target)
        check(!promptText.contains("Card number"), "card fields are never described to the model")
        if Sorter().appleModelAvailable, let res = try? await FormMapper.answers(fields: form, packs: [store.pack(me.id)!], target: target, allowClaude: false) {
            for f in form { print("    \(f.label): \(res.answers[f.id]?.value.singleLine.truncated(80) ?? "–")") }
            check(res.answers[3] == nil, "no answer is produced for the card field")
            check(res.answers[2]?.value == "moosa.test@example.com", "the email comes from the pack")
            check(res.answers[1]?.value.contains("Moosa") == true, "the name comes from the pack")
            check(res.answers[4]?.value.isEmpty != false, "a phone number that isn't in the pack stays blank")
        }
        let ctxText = "Moosa Usman · moosa.test@example.com · Toronto, Canada. Graduating 2027. Call 416-555-0199."
        let fakeAnswers: [Int: FieldAnswer] = [1: .init(value: "Moosa Usman", source: 1), 2: .init(value: "(416) 555 0199", source: 1),
                                               3: .init(value: "+1 647 222 3333", source: 1), 4: .init(value: "Toronto", source: 1),
                                               5: .init(value: "Jane Smith", source: 1)]
        let gf = [field(1, "Name"), field(2, "Phone"), field(3, "Mobile"), field(4, "City"), field(5, "Reference name")]
        let kept = FormMapper.grounded(fakeAnswers, fields: gf, context: ctxText)
        check(kept[1]?.value == "Moosa Usman" && kept[2]?.value == "(416) 555 0199" && kept[4]?.value == "Toronto",
              "answers found in the packs are kept, even reformatted")
        check(kept[3]?.value == "" && kept[5]?.value == "", "made-up phone numbers and names are thrown out")
        let misplaced = FormMapper.grounded([2: .init(value: "Toronto, Canada", source: 1), 4: .init(value: "moosa.test@example.com", source: 1)],
                                            fields: [field(2, "Phone"), field(4, "Email")], context: ctxText)
        check(misplaced[2]?.value == "" && misplaced[4]?.value == "moosa.test@example.com", "a city typed into a phone field is thrown out")
        check(FormMapper.clean("0") == "" && FormMapper.clean("N/A") == "" && FormMapper.clean("[your phone]") == ""
              && FormMapper.clean(" Moosa ") == "Moosa", "junk answers like 0 or N/A are dropped")
        check(Drafter.prompt(pack: store.pack(me.id)!, target: DropTarget(app: nil, appName: "Safari", destination: .generic, label: "Safari",
                                                                          fieldLabel: "Why do you want this role?"),
                             instruction: "").contains("Why do you want this role?"), "⌥⇧D drafts know the field's label")

        print("Save progress → Resume")
        let work = store.createPack(name: "Login Bug", emoji: "🐞", autoNamed: false)
        let w1 = store.add(CaptureDraft(text: "Users get logged out after 5 minutes on Safari. Started after the 2.3 release.",
                                        title: "Bug report", url: "https://github.com/acme/app/issues/88"), to: work.id)
        let w2 = store.add(CaptureDraft(text: "Tried raising the session cookie max-age to 24h. Didn't help, still logged out after 5 min.",
                                        title: "Attempt 1: cookie max-age"), to: work.id)
        let w3 = store.add(CaptureDraft(text: "Decided to keep JWTs and not move to server sessions. Next: check whether Safari ITP is deleting the refresh-token cookie.",
                                        title: "Team decision"), to: work.id)
        var hand = Checkpoint()
        hand.goal = "Stop Safari users getting logged out after 5 minutes."
        hand.decisions = [.init(text: "Keep JWTs.", sources: [w3!.id])]
        hand.tried = [.init(text: "Raised cookie max-age to 24h; no effect.", sources: [w2!.id])]
        hand.openProblems = [.init(text: "Why the refresh token disappears.", sources: [w1!.id])]
        hand.nextStep = "Check Safari ITP and the refresh-token cookie."
        hand.tabs = [.init(url: "https://github.com/acme/app/issues/88", title: "Issue 88", browserBundleID: "com.apple.Safari")]
        hand.created = Date().addingTimeInterval(-3600)
        store.saveCheckpoint(hand, for: work.id)
        var newer = hand
        newer.id = UUID()
        newer.created = Date()
        newer.nextStep = "Test with ITP disabled."
        store.saveCheckpoint(newer, for: work.id)
        check(store.checkpoints(for: work.id).count == 2 && store.latestCheckpoint(for: work.id)?.nextStep == "Test with ITP disabled.",
              "checkpoints are versioned; the newest is current")
        check(PackStore(root: tmp, defaults: defaults).pack(work.id)?.captures.count == 3, "checkpoint files don't show up as captures")
        let back = store.checkpoints(for: work.id).last
        check(back?.decisions.first?.sources == [w3!.id] && back?.tabs.first?.url.contains("issues/88") == true,
              "a checkpoint keeps its links to captures and its open pages")

        let resumeText = ResumePrompt.build(pack: store.pack(work.id)!, checkpoint: newer)
        check(resumeText.contains("Stop Safari users") && resumeText.contains("Already tried") && resumeText.contains("Test with ITP disabled")
              && resumeText.contains("cookie max-age to 24h") && resumeText.contains("issues/88"),
              "the resume prompt has the goal, what was tried, the next step, the evidence and the pages")
        let lean = ResumePrompt.build(pack: store.pack(work.id)!, checkpoint: newer, options: .init(includeEvidence: false, includeTabs: false))
        check(!lean.contains("Key evidence") && !lean.contains("Pages I had open"), "evidence and pages can be left out")
        check(ResumePrompt.build(pack: store.pack(work.id)!, checkpoint: newer, options: .init(forCode: true)).contains("```"),
              "coding tools get evidence in code blocks")

        let tabs = BrowserTabs.preselect([.init(url: "https://github.com/acme/app/pull/90", browserBundleID: "com.apple.Safari"),
                                          .init(url: "https://www.youtube.com/watch?v=x", browserBundleID: "com.apple.Safari")],
                                         for: store.pack(work.id)!)
        check(tabs[0].keep && !tabs[1].keep, "pages from the pack's sites are pre-ticked; unrelated ones aren't")

        if Sorter().appleModelAvailable,
           let written = try? await CheckpointWriter.write(pack: store.pack(work.id)!, previous: nil, allowClaude: false) {
            print("    goal: \(written.goal)")
            print("    tried: \(written.tried.map(\.text))")
            print("    next: \(written.nextStep)")
            let validIDs = Set(store.pack(work.id)!.captures.map(\.id))
            check(written.goal.nonEmpty != nil && written.nextStep.nonEmpty != nil, "the on-device model writes a goal and a next step")
            check((written.decisions + written.tried + written.openProblems).allSatisfy { $0.sources.allSatisfy(validIDs.contains) },
                  "every cited source is a real capture")
        }

        let saved = mcp.handle(["jsonrpc": "2.0", "id": 20, "method": "tools/call", "params": ["name": "save_checkpoint", "arguments": [
            "pack": "Thesis Draft", "goal": "Finish chapter 2", "decisions": ["Use APA style"], "tried": ["Outlining by theme; too loose"],
            "next_step": "Write the methods section"]]])
        check(((saved?["result"] as? [String: Any])?["isError"] as? Bool) == false && store.packs.contains { $0.name == "Thesis Draft" },
              "Claude can save a checkpoint through MCP, creating the pack")
        let got = mcp.handle(["jsonrpc": "2.0", "id": 21, "method": "tools/call", "params": ["name": "get_checkpoint", "arguments": ["pack": "thesis draft"]]])
        let gotText = (((got?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        check(gotText.contains("Finish chapter 2") && gotText.contains("Write the methods section"), "and any AI tool can get it back")

        print("Files from links and Finder")
        check(FileTypes.looksLikeFile(URL(string: "https://x.com/report.pdf")!) && !FileTypes.looksLikeFile(URL(string: "https://x.com/setup.dmg")!)
              && !FileTypes.looksLikeFile(URL(string: "https://x.com/page.html")!), "PDF links count as files; installers and web pages don't")
        check(FileTypes.mightBeFile(URL(string: "https://arxiv.org/pdf/2401.12345")!), "download-style links get checked with the server")

        let fdir = tmp.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: fdir, withIntermediateDirectories: true)
        let pdfData = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        if let consumer = CGDataConsumer(data: pdfData), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) {
            ctx.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: "Quarterly revenue grew 12 percent, driven by the Toronto launch.",
                attributes: [.font: NSFont.systemFont(ofSize: 14)]))
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
            ctx.closePDF()
        }
        pdfData.write(to: fdir.appendingPathComponent("report.pdf"), atomically: true)
        let docx = NSAttributedString(string: "Meeting notes: ship the beta on March 3.")
        if let d = try? docx.data(from: NSRange(location: 0, length: docx.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]) {
            try? d.write(to: fdir.appendingPathComponent("notes.docx"))
        }
        try? "name,score\nAva,91\nNoah,87".write(to: fdir.appendingPathComponent("scores.csv"), atomically: true, encoding: .utf8)
        try? ScreenCapture.png(Self.textImage("Whiteboard: launch checklist"))?.write(to: fdir.appendingPathComponent("board.png"))
        let deck = tmp.appendingPathComponent("deck-src/ppt/slides", isDirectory: true)
        try? FileManager.default.createDirectory(at: deck, withIntermediateDirectories: true)
        try? "<p:sld><a:t>Roadmap</a:t><a:t>Q3 &amp; Q4 goals</a:t></p:sld>".write(to: deck.appendingPathComponent("slide1.xml"), atomically: true, encoding: .utf8)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", tmp.appendingPathComponent("deck-src").path, fdir.appendingPathComponent("deck.pptx").path]
        try? zip.run(); zip.waitUntilExit()

        let extracted = [
            ("report.pdf", "Quarterly revenue"), ("notes.docx", "ship the beta"), ("scores.csv", "Ava,91"),
            ("board.png", "launch checklist"), ("deck.pptx", "Q3 & Q4 goals"),
        ]
        for (name, needle) in extracted {
            let t = await FileText.extract(fdir.appendingPathComponent(name))
            check(t.contains(needle), "reads the text in a .\((name as NSString).pathExtension) file")
        }

        // A tiny local web server stands in for websites.
        try? "<html><body>Please sign in</body></html>".write(to: fdir.appendingPathComponent("wall.html"), atomically: true, encoding: .utf8)
        try? Data("fake installer".utf8).write(to: fdir.appendingPathComponent("setup.dmg"))
        let port = Int.random(in: 20000...40000)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", fdir.path]
        server.standardOutput = Pipe(); server.standardError = Pipe()
        let errPipe = Pipe()
        server.standardError = errPipe
        if (try? server.run()) != nil {
            let base = "http://127.0.0.1:\(port)/"
            var ready = false
            for _ in 0..<25 where !ready {
                try? await Task.sleep(for: .milliseconds(200))
                ready = (try? await URLSession.shared.data(from: URL(string: base + "scores.csv")!)) != nil
            }
            if !ready { print("    test server didn't start: \(String(data: errPipe.fileHandleForReading.availableData, encoding: .utf8) ?? "")") }
            if let r = try? await FileDownloader.download(URL(string: base + "report.pdf")!, expectedExt: "pdf") {
                check(r.name == "report.pdf" && Quarantine.isMarked(r.file), "downloads a public file and marks it as from the web")
                let d = await FileImporter.draft(file: r.file, name: r.name, sourceURL: URL(string: base + "report.pdf"), appName: "Safari")
                if let d, let shot = store.add(d, to: fresh.id) {
                    let stored = store.fileURL(for: shot)
                    check(stored?.lastPathComponent.hasSuffix(".file.pdf") == true && Quarantine.isMarked(stored!),
                          "the file is kept in the pack next to its capture, still marked")
                    check(shot.text.contains("Quarterly revenue") && shot.url == base + "report.pdf", "the capture has the file's text and link")
                    check(Exporter.markdown(packName: "x", captures: [shot]).contains("_File:"), "exports say the text came from a file")
                }
            } else {
                check(false, "downloads a public file")
            }
            let started = Date()
            let parallel = await withTaskGroup(of: Bool.self) { group -> Int in
                for name in ["report.pdf", "scores.csv", "notes.docx"] {
                    group.addTask { (try? await FileDownloader.download(URL(string: base + name)!, expectedExt: nil)) != nil }
                }
                var ok = 0
                for await r in group where r { ok += 1 }
                return ok
            }
            check(parallel == 3, "several public files download at once (\(String(format: "%.1f", Date().timeIntervalSince(started)))s)")
            do {
                _ = try await FileDownloader.download(URL(string: base + "wall.html")!, expectedExt: "pdf")
                check(false, "a sign-in page is detected")
            } catch FileDownloader.DownloadError.needsBrowser {
                check(true, "a sign-in page instead of a file hands off to the browser")
            } catch { check(false, "a sign-in page is detected (\(error))") }
            do {
                _ = try await FileDownloader.download(URL(string: base + "setup.dmg")!, expectedExt: nil)
                check(false, "installers are refused")
            } catch FileDownloader.DownloadError.blocked {
                check(true, "installers are refused")
            } catch { check(false, "installers are refused (\(error))") }
            server.terminate()
        } else {
            print("    (python3 not available; skipped download checks)")
        }

        let mdNote = fdir.appendingPathComponent("plan.md")
        try? "# Plan\nShip it.".write(to: mdNote, atomically: true, encoding: .utf8)
        let before2 = store.pack(fresh.id)?.captures.count ?? 0
        if let d = await FileImporter.draft(file: mdNote, appName: "Finder") { store.add(d, to: fresh.id) }
        let reloadedCount = PackStore(root: tmp, defaults: defaults).pack(fresh.id)?.captures.count
        check(reloadedCount == before2 + 1, "an attached .md file isn't mistaken for a capture")
        check(await FileImporter.draft(file: fdir.appendingPathComponent("setup.dmg")) == nil, "dropping an installer onto a pack is refused")
        if let withFile = store.pack(fresh.id)?.captures.first(where: { $0.file != nil }), let other = store.packs.first(where: { $0.id != fresh.id }) {
            store.moveCapture(withFile.id, to: other.id)
            let moved = store.pack(other.id)?.captures.first { $0.id == withFile.id }
            check(moved.flatMap { store.fileURL(for: $0) }.map { FileManager.default.fileExists(atPath: $0.path) } == true,
                  "moving a capture moves its file")
            store.removeCapture(withFile.id, toTrash: false)
            check(moved.flatMap { store.fileURL(for: $0) } == nil, "deleting a capture removes its file")
        }

        print("File suggestions")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("Shapr")
        func cand(_ rel: String, never: [String] = []) -> Bool {
            FileSuggester.isCandidate(home.appendingPathComponent(rel), shaprRoot: root, neverFolders: never, home: home)
        }
        check(cand("Code/shop/schema.sql") && cand("Code/shop/etl.py") && cand("Documents/syllabus.pdf")
              && cand("Documents/notes.docx") && cand("Desktop/todo.txt"),
              "documents and code you open are offered (sql, py, pdf, docx, txt)")
        check(!cand("Downloads/setup.dmg") && !cand("Pictures/beach.jpg") && !cand("Shapr/Packs/cars/a.md")
              && !cand("Library/Preferences/x.txt") && !cand("Code/shop/.git/config.txt") && !cand("Code/web/node_modules/x/README.md"),
              "installers, photos, Shapr's own files, Library, hidden and dependency folders are skipped")
        check(!cand("Work/clients/contract.pdf", never: [home.appendingPathComponent("Work").path]), "\"Not here\" folders are never asked about")

        let db = store.createPack(name: "Orders Database", emoji: "🗄️", autoNamed: false)
        store.add(CaptureDraft(text: "CREATE TABLE orders (id INT PRIMARY KEY, customer_id INT, total DECIMAL(10,2), created_at TIMESTAMP);",
                               title: "orders table"), to: db.id)
        let suggester = FileSuggester(store: store, toast: ToastController(), sorter: sorter)
        check(suggester.workingPacks().contains { $0.id == db.id }, "packs you added to recently count as ones you're working on")
        let sqlProbe = CaptureDraft(text: "monthly_revenue.sql\nSELECT date_trunc('month', created_at) AS month, SUM(total) FROM orders GROUP BY 1;",
                                    title: "monthly_revenue.sql")
        let fit = await sorter.decide(sqlProbe, packs: store.summaries(limit: 50).filter { s in [db.id, packOf(0) ?? db.id].contains(s.id) },
                                      allowClaude: false)
        print("    monthly_revenue.sql → \(store.pack(fit.packID)?.label ?? "no pack") [\(fit.engine)]")
        check(fit.packID == db.id, "an opened .sql file is matched to the database pack, on this Mac")
        let localFile = fdir.appendingPathComponent("scores.csv")
        if let d = await FileImporter.draft(file: localFile, name: "scores.csv", sourceURL: localFile.standardizedFileURL),
           let c = store.add(d, to: db.id) {
            check(c.url == localFile.standardizedFileURL.absoluteString, "added files remember where they came from, so they aren't offered twice")
        }

        print("Quercus / Canvas and other file links")
        let q = "https://q.utoronto.ca/courses/337245/files/"
        let quercus: [FoundLink] = [
            .init(url: URL(string: q + "31234567?wrap=1")!, text: "mat223_2_6_I.pdf"),
            .init(url: URL(string: q + "31234567/download?download_frd=1")!, text: nil),
            .init(url: URL(string: q + "31234568?wrap=1")!, text: "mat223_2_6_II.pdf"),
            .init(url: URL(string: q + "31234568/download?download_frd=1")!, text: "Download mat223_2_6_II.pdf"),
            .init(url: URL(string: q + "31234569?verifier=abc&wrap=1")!, text: "mat223_5_1.pdf"),
            .init(url: URL(string: "https://q.utoronto.ca/courses/337245/pages/week-3")!, text: "Week 3"),
        ]
        let qt = FileLinkResolver.targets(from: quercus).sure
        for t in qt { print("    \(t.name ?? "?") → \(t.download.absoluteString)") }
        check(qt.count == 3, "three Quercus PDFs (name link + ↓ icon each) become three files, and the page link is ignored")
        check(qt.map(\.name) == ["mat223_2_6_I.pdf", "mat223_2_6_II.pdf", "mat223_5_1.pdf"], "each keeps the name shown on the page")
        check(qt.allSatisfy { $0.needsLogin && $0.download.path.hasSuffix("/download") && $0.download.query == "download_frd=1" },
              "each uses Quercus's download address, through your browser's login")
        let page = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var withIcon = quercus
        withIcon[1] = FoundLink(url: quercus[1].url, text: nil, element: page)   // the ↓ icon on the page
        withIcon[0] = FoundLink(url: quercus[0].url, text: quercus[0].text, element: page)
        let pressable = FileLinkResolver.targets(from: withIcon).sure
        check(pressable.first?.pressElement != nil, "the ↓ download icon is pressed in place, so no new tab opens")
        check(FileLinkResolver.targets(from: [withIcon[0]]).sure.first?.pressElement == nil,
              "a file-name link that would open a preview page is never pressed")
        check(FileDownloader.matches("mat223_5_1 (1).pdf", "mat223_5_1.pdf") && FileDownloader.matches("mat223_5_1.pdf", "mat223_5_1.pdf")
              && !FileDownloader.matches("mat223_2_6_II.pdf", "mat223_2_6_I.pdf") && !FileDownloader.matches("mat223_5_1.docx", "mat223_5_1.pdf"),
              "finished downloads are matched to the right link, even when the browser adds \"(1)\"")
        let iconFirst = FileLinkResolver.targets(from: [quercus[1], quercus[0]]).sure
        check(iconFirst.count == 1 && iconFirst.first?.name == "mat223_2_6_I.pdf", "hitting the ↓ icon first still gets the right name")

        let others = FileLinkResolver.targets(from: [
            .init(url: URL(string: "https://drive.google.com/file/d/1AbCdEf/view?usp=sharing")!, text: "Lecture 4.pdf"),
            .init(url: URL(string: "https://www.dropbox.com/s/xyz/budget.xlsx?dl=0")!, text: "budget.xlsx"),
            .init(url: URL(string: "https://github.com/acme/app/blob/main/db/schema.sql")!, text: "schema.sql"),
            .init(url: URL(string: "https://example.com/get?id=5")!, text: "Syllabus.docx"),
            .init(url: URL(string: "https://example.com/about")!, text: "Download (PDF)"),
        ]).sure
        check(others.count == 4, "Drive, Dropbox, GitHub and a link whose text names a file are found; vague text isn't")
        check(others.first { $0.name == "Lecture 4.pdf" }?.download.absoluteString == "https://drive.google.com/uc?export=download&id=1AbCdEf",
              "Google Drive links become direct downloads")
        check(others.first { $0.name == "budget.xlsx" }?.download.query?.contains("dl=1") == true, "Dropbox links switch to dl=1")
        check(others.first { $0.name == "schema.sql" }?.download.host == "raw.githubusercontent.com", "GitHub file pages become raw files")

        print("Hover circle")
        func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, turns: Double = 1, start: Double = 0) -> [CGPoint] {
            (0...Int(90 * turns)).map { i in
                let t = start + Double(i) / 90 * 2 * .pi
                return CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t))
            }
        }
        let approach = (0..<40).map { CGPoint(x: 900 - CGFloat($0) * 10, y: 700 - CGFloat($0) * 8) }   // pointer moving in from far away
        let circle = ellipse(cx: 400, cy: 300, rx: 120, ry: 60)
        if let loop = CaptureOverlayView.findLoop(approach + circle) {
            let r = CaptureOverlayView.bounds(of: loop)
            check(abs(r.midX - 400) < 15 && abs(r.midY - 300) < 15 && r.width < 270 && r.height < 140,
                  "the circle is found and the path taken to reach it is ignored")
        } else {
            check(false, "the circle is found")
        }
        check(CaptureOverlayView.findLoop((0..<80).map { CGPoint(x: CGFloat($0) * 6, y: 200) }) == nil, "moving the pointer across the screen captures nothing")
        check(CaptureOverlayView.findLoop(ellipse(cx: 400, cy: 300, rx: 120, ry: 60, turns: 0.5)) == nil, "half a circle captures nothing")
        check(CaptureOverlayView.findLoop(ellipse(cx: 400, cy: 300, rx: 8, ry: 8)) == nil, "a tiny wiggle captures nothing")
        check(CaptureOverlayView.findLoop(ellipse(cx: 400, cy: 300, rx: 120, ry: 60, turns: 0.9)) != nil, "an almost-closed loop still counts")
        check(DoubleTapDetector.Key.current == .command || UserDefaults.standard.string(forKey: DoubleTapDetector.Key.defaultsKey) != nil,
              "double-tap ⌘ is the default circle gesture")
        if DoubleTapDetector.Key.current == .command {
            func run(_ steps: [(UInt16, NSEvent.ModifierFlags, Double)]) async -> Int {
                var fired = 0
                let d = DoubleTapDetector(listen: false) { fired += 1 }
                for (code, mods, wait) in steps {
                    if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
                    if code == 0 { d.otherInput() } else { d.flags(keyCode: code, mods: mods) }
                }
                return fired
            }
            let cmd: NSEvent.ModifierFlags = .command
            let tap2 = await run([(55, cmd, 0), (55, [], 0.05), (55, cmd, 0.1), (55, [], 0.05)])
            check(tap2 == 1, "two quick taps of ⌘ start circling")
            let rightCmd = await run([(54, cmd, 0), (54, [], 0.05), (54, cmd, 0.1), (54, [], 0.05)])
            check(rightCmd == 1, "the right ⌘ key works too")
            let shortcut = await run([(55, cmd, 0), (0, [], 0.03), (55, [], 0.03), (55, cmd, 0.1), (0, [], 0.03), (55, [], 0.03)])
            check(shortcut == 0, "⌘C, ⌘V and other shortcuts don't count as taps")
            let slow = await run([(55, cmd, 0), (55, [], 0.05), (55, cmd, 0.6), (55, [], 0.05)])
            check(slow == 0, "two slow taps don't count")
        }

        print("Files your browser downloads")
        do {
            let dl = tmp.appendingPathComponent("fake-downloads-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
            // An old file from yesterday, and a download that finished a moment before Shapr looked.
            let old = dl.appendingPathComponent("syllabus.pdf")
            try? Data("%PDF-1.4 old".utf8).write(to: old)
            var oldValues = URLResourceValues()
            oldValues.creationDate = Date().addingTimeInterval(-86_400)
            var oldURL = old
            try? oldURL.setResourceValues(oldValues)
            // A copy of mat223_2_6_I.pdf from an earlier try, which Safari will save over.
            let earlier = dl.appendingPathComponent("mat223_2_6_I.pdf")
            try? Data("%PDF-1.4 earlier".utf8).write(to: earlier)
            var earlierURL = earlier
            try? earlierURL.setResourceValues(oldValues)
            let start = Date()
            try? Data("%PDF-1.4 early".utf8).write(to: dl.appendingPathComponent("mat223_5_1.pdf"))
            let items = [FileDownloader.BrowserItem(url: URL(string: "https://q.utoronto.ca/files/1/download")!, press: nil,
                                                    expectedName: "mat223_5_1.pdf"),
                         FileDownloader.BrowserItem(url: URL(string: "https://q.utoronto.ca/files/2/download")!, press: nil,
                                                    expectedName: "mat223_1_3.pdf"),
                         FileDownloader.BrowserItem(url: URL(string: "https://q.utoronto.ca/files/3/download")!, press: nil,
                                                    expectedName: "mat223_2_6_I.pdf")]
            // The second file arrives while Shapr is watching.
            let got = await FileDownloader.viaBrowser(items, browserBundleID: nil, since: start, timeout: 6, folder: dl,
                                                      open: { url in
                if url.path.contains("/2/") {
                    try? Data("%PDF-1.4 late".utf8).write(to: dl.appendingPathComponent("mat223_1_3.pdf"))
                }
                if url.path.contains("/3/") {
                    try? await Task.sleep(for: .milliseconds(1100))
                    try? FileManager.default.removeItem(at: earlier)
                    try? Data("%PDF-1.4 replaced".utf8).write(to: earlier)
                }
            })
            check(got[0]?.name == "mat223_5_1.pdf", "a download that lands before Shapr looks is still picked up")
            check(got[1]?.name == "mat223_1_3.pdf", "a download that lands while Shapr watches is picked up")
            check(got[2]?.name == "mat223_2_6_I.pdf" && (try? String(contentsOf: got[2]!.file, encoding: .utf8)) == "%PDF-1.4 replaced",
                  "a download that replaces an earlier copy with the same name is picked up")
            check(!got.values.contains { $0.name == "syllabus.pdf" }, "older files in Downloads are left alone")
            try? FileManager.default.removeItem(at: dl)
        }

        do {
            // Safari-like: pressing a download button starts a page load, and pressing another before the
            // download begins cancels the first. Shapr must press one at a time, and open no tabs.
            let dl = tmp.appendingPathComponent("fake-downloads-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
            final class Browser: @unchecked Sendable { var latest = 0; var tabs = 0 }
            let browser = Browser()
            let names = ["mat223_1_1.pdf", "mat223_1_2.pdf", "mat223_1_3.pdf", "mat223_5_1.pdf"]
            let dummy = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            let items = names.enumerated().map { i, n in
                FileDownloader.BrowserItem(url: URL(string: "https://q.utoronto.ca/files/\(i)/download")!, press: dummy, expectedName: n)
            }
            let got = await FileDownloader.viaBrowser(items, browserBundleID: nil, since: Date(), timeout: 10, folder: dl,
                                                      open: { _ in browser.tabs += 1 },
                                                      press: { i in
                browser.latest += 1
                let token = browser.latest
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    if token == browser.latest { try? Data("%PDF-1.4 \(i)".utf8).write(to: dl.appendingPathComponent(names[i])) }
                }
                return true
            })
            check(got.count == names.count && browser.tabs == 0, "pressing several ↓ buttons downloads every file with no new tabs")
            try? FileManager.default.removeItem(at: dl)
        }

        print("Links inside a circle")
        let lasso = CGRect(x: 100, y: 100, width: 300, height: 400)
        check(LinkFinder.covers(lasso, CGRect(x: 120, y: 110, width: 160, height: 18))
              && LinkFinder.covers(lasso, CGRect(x: 300, y: 300, width: 160, height: 18)),
              "a link counts when its middle or most of it is inside the circle")
        check(!LinkFinder.covers(lasso, CGRect(x: 380, y: 300, width: 200, height: 18))
              && !LinkFinder.covers(lasso, CGRect(x: 120, y: 520, width: 160, height: 18)),
              "a link the circle only grazes is left out")

        print("Quercus download buttons")
        check(LinkFinder.isDownloadLabel("Download mat223_1_1.pdf", for: "mat223_1_1.pdf"), "\"Download mat223_1_1.pdf\" is that file's button")
        check(!LinkFinder.isDownloadLabel("Download mat223_1_2.pdf", for: "mat223_1_1.pdf")
              && !LinkFinder.isDownloadLabel("Download lecture_notes_week_02.pdf", for: "lecture_notes_week_01.pdf")
              && !LinkFinder.isDownloadLabel("Download mat223_4_1-4_2-1.pdf", for: "mat223_4_1-4_2.pdf"),
              "a neighbouring file's button is never pressed, even with a similar name")
        check(LinkFinder.isDownloadLabel("Download \"Linear Algebra and Applications\" by Nicholson", for: "“Linear Algebra and Applications” by Nicholson")
              && LinkFinder.isDownloadLabel("Download", for: "notes.pdf") && LinkFinder.isDownloadLabel("Download Lecture 3 slid…", for: "Lecture 3 slides.pdf"),
              "quotes, a bare \"Download\" and shortened names still match")
        check(!LinkFinder.isDownloadLabel("mat223_1_1.pdf", for: "mat223_1_1.pdf"), "a plain file link isn't mistaken for a download button")

        print("Shared pack links")
        let shareBase = URL(string: "https://shapr-share.example.dev")!
        check(ShareServer.packID(from: "https://shapr-share.example.dev/p/AbC123xyz789", base: shareBase) == "AbC123xyz789"
              && ShareServer.packID(from: "shapr://join/AbC123xyz789", base: shareBase) == "AbC123xyz789"
              && ShareServer.packID(from: "  AbC123xyz789 ", base: shareBase) == "AbC123xyz789",
              "pack links, shapr:// links and bare codes all work")
        check(ShareServer.packID(from: "https://evil.example.com/p/AbC123xyz789", base: shareBase) == nil
              && ShareServer.packID(from: "https://shapr-share.example.dev/p/../../etc", base: shareBase) == nil
              && ShareServer.packID(from: "shapr://join/short", base: shareBase) == nil,
              "links to other servers or malformed links are refused")

        print("Use this with my pack: the demo flow")
        check(PackAssist.kind(of: "What is an eigenvalue of a 2x2 matrix?") == .question
              && PackAssist.kind(of: "TypeError: Cannot read properties of undefined (reading 'map')\n    at render (Dashboard.js:12:5)", app: "Google Chrome") == .debug
              && PackAssist.kind(of: "Hi Moosa,\n\nCould you send the updated proposal by Friday?\n\nThanks,\nJane", app: "Mail") == .reply,
              "it tells a question, an error and an email apart")
        // 1. Capture from three places.
        let demoPack = store.createPack(name: "MAT223", emoji: "📘", autoNamed: false)
        let lecture = store.add(CaptureDraft(text: "Lecture 5: A square matrix A is diagonalizable when it has n linearly independent eigenvectors. Then A = PDP^-1, where the columns of P are those eigenvectors.",
                                             appName: "Safari", title: "Lecture 5: Diagonalization", url: "https://q.utoronto.ca/courses/1/pages/lecture-5"), to: demoPack.id)
        store.add(CaptureDraft(text: "Eigenvalues are the roots of the characteristic polynomial det(A - λI) = 0.", appName: "Preview",
                               title: "mat223_5_1.pdf", url: "file:///tmp/mat223_5_1.pdf"), to: demoPack.id)
        store.add(CaptureDraft(text: "Office hours moved to Thursday 3pm in BA 2155.", appName: "Mail", title: "Course announcement"), to: demoPack.id)
        // 2. Equip it. 3. Use it on a new question.
        store.equip(demoPack.id)
        let demoQuestion = "How do I check whether a 3x3 matrix is diagonalizable?"
        let demoFound = PackAssist.excerpts(for: demoQuestion, in: store.pack(demoPack.id)!, kind: .question)
        check(demoFound.first?.title == "Lecture 5: Diagonalization", "it finds the lecture excerpt that answers a new question")
        check(!demoFound.contains { $0.title == "Course announcement" }, "unrelated captures stay out")
        // 4. Save progress.
        var demoCP = Checkpoint()
        demoCP.title = "Midterm prep: diagonalization"
        demoCP.goal = "Pass the MAT223 midterm"
        demoCP.decisions = [.init(text: "Focus on diagonalization first", sources: lecture.map { [$0.id] } ?? [])]
        demoCP.tried = [.init(text: "Found eigenvalues 1 and 4 for [[2,1],[1,2]] but wasn't sure how to finish")]
        demoCP.nextStep = "Do practice problem 5.2 #4"
        _ = store.saveCheckpoint(demoCP, for: demoPack.id)
        let savedCP = store.latestCheckpoint(for: demoPack.id)!
        let demoBrief = PackAssist.brief(kind: .question, input: demoQuestion, packName: "MAT223", excerpts: demoFound, checkpoint: savedCP)
        check(demoBrief.contains(demoQuestion) && demoBrief.contains("[1] Lecture 5") && demoBrief.contains("Already tried")
              && demoBrief.contains("Pass the MAT223 midterm"), "the brief has the question, the right excerpts and your saved progress")
        // 5. Continue in another AI.
        check(ResumePrompt.build(pack: store.pack(demoPack.id)!, checkpoint: savedCP).contains("Do practice problem 5.2 #4"),
              "saved progress continues in another AI")
        check(!savedCP.staleness(in: store.pack(demoPack.id)!).isStale, "a fresh checkpoint isn't flagged")
        store.add(CaptureDraft(text: "Practice problem 5.2 #4 solution sketch", capturedAt: Date().addingTimeInterval(5), title: "Practice"), to: demoPack.id)
        check(savedCP.staleness(in: store.pack(demoPack.id)!).newCaptures == 1, "new captures since you saved are pointed out before you continue")
        let twice = CaptureDraft(text: "Office hours moved to   Thursday 3pm in BA 2155.", appName: "Mail", title: "Course announcement")
        check(store.duplicate(of: twice)?.1.title == "Course announcement", "the same capture twice isn't saved twice")
        check(store.duplicate(of: CaptureDraft(text: "Office hours moved to Friday at noon.")) == nil, "a different capture is still saved")
        let longText = (1...12).map { "Paragraph \($0) about eigenvectors and bases, with enough words to be a real paragraph of notes." }.joined(separator: "\n\n")
        check(PackAssist.chunks(longText).count >= 2 && PackAssist.chunks(longText).allSatisfy { $0.count <= 1500 },
              "long captures are split into readable excerpts")

        print("Moving between AIs")
        func N(_ role: String, _ text: String? = nil, cls: [String] = [], sub: String? = nil, _ kids: [ChatReader.Node] = []) -> ChatReader.Node {
            ChatReader.Node(role: role, subrole: sub, classes: cls, text: text, children: kids)
        }
        func T(_ s: String) -> ChatReader.Node { N("AXStaticText", s) }
        func H(_ s: String) -> ChatReader.Node { N("AXHeading", nil, [T(s)]) }
        func P(_ s: String) -> ChatReader.Node { N("AXGroup", nil, [T(s)]) }
        let gptPage = N("AXWebArea", nil, [
            N("AXGroup", nil, [N("AXLink", nil, [T("Rank-nullity homework help")]), N("AXLink", nil, [T("Old chat about cooking")])]),
            N("AXGroup", nil, [
                N("AXGroup", sub: "AXDocumentArticle", [H("You said:"), N("AXGroup", cls: ["whitespace-pre-wrap"], [T("I need to finish MAT223 assignment 2 tonight. Don't use numpy.")])]),
                N("AXGroup", sub: "AXDocumentArticle", [H("ChatGPT said:"), N("AXGroup", cls: ["markdown", "prose"], [
                    P("Sure. Rank-nullity says rank + nullity = n."),
                    N("AXGroup", cls: ["language-python"], [T("print('rank')")]),
                    N("AXButton", nil, [T("Copy code")]),
                ])]),
                N("AXGroup", sub: "AXDocumentArticle", [H("You said:"), N("AXGroup", nil, [T("I tried row reducing by hand but it didn't work. Keep it under 200 words. The prof wants the answer as a table.")])]),
                N("AXGroup", sub: "AXDocumentArticle", [H("ChatGPT said:"), N("AXGroup", cls: ["markdown"], [
                    P("The issue was a sign error in row 2."), P("Next, compute the null space basis."),
                ])]),
                N("AXGroup", sub: "AXDocumentArticle", [H("You said:"), N("AXGroup", nil, [T("Why do we hit the rate limit on the API so often?")])]),
                N("AXGroup", sub: "AXDocumentArticle", [H("ChatGPT said:"), N("AXGroup", cls: ["markdown"], [P("Because you've reached the usage limit for that key.")])]),
            ]),
            N("AXGroup", nil, [T("You've hit the Free plan limit for GPT-5. Responses will use another model until your limit resets after 4:12 PM.")]),
            N("AXGroup", nil, [T("ChatGPT can make mistakes. Check important info.")]),
        ])
        let gptTurns = ChatReader.parse(gptPage, service: "ChatGPT")
        check(gptTurns.map(\.role) == [.user, .assistant, .user, .assistant, .user, .assistant],
              "it reads a ChatGPT chat as your messages and its answers, in order")
        check(gptTurns.first?.text == "I need to finish MAT223 assignment 2 tonight. Don't use numpy."
              && !gptTurns.contains { $0.text.contains("You said") || $0.text.contains("Copy code") || $0.text.contains("cooking") },
              "your words come through exactly, without labels, buttons or the sidebar")
        check(gptTurns[1].text.contains("```\nprint('rank')\n```"), "code in an answer stays code")
        let claudePage = N("AXWebArea", nil, [
            N("AXGroup", nil, [N("AXLink", nil, [T("Recents")])]),
            N("AXGroup", cls: ["font-user-message"], [P("Help me understand eigenvalues. Never skip steps.")]),
            N("AXGroup", cls: ["font-claude-response"], [P("An eigenvalue λ satisfies Av = λv."), P("Want an example?")]),
            N("AXGroup", nil, [T("You are out of free messages until 3:00 PM")]),
        ])
        let claudeTurns = ChatReader.parse(claudePage, service: "Claude")
        check(claudeTurns.map(\.role) == [.user, .assistant] && claudeTurns[1].text.contains("Av = λv.\nWant an example?"),
              "it reads a Claude chat, paragraphs kept apart")
        let geminiTurns = ChatReader.parse(N("AXWebArea", nil, [
            N("AXGroup", cls: ["user-query-container"], [T("What is a basis?")]),
            N("AXGroup", cls: ["model-response-text", "markdown"], [P("A basis is a set of linearly independent vectors that spans the space.")]),
        ]), service: "Gemini")
        check(geminiTurns.map(\.role) == [.user, .assistant], "it reads a Gemini chat")
        let labelled = ChatReader.parse(N("AXWebArea", nil, [
            N("AXGroup", sub: "AXDocumentArticle", [N("AXHeading", nil, [T("You said: build all of it")])]),
            N("AXGroup", sub: "AXDocumentArticle", [N("AXHeading", nil, [T("Claude responded:")]), P("On it. First, the chat reader.")]),
        ]), service: "Claude")
        check(labelled.map(\.role) == [.user, .assistant] && labelled[0].text == "build all of it" && labelled[1].text == "On it. First, the chat reader.",
              "it reads “You said: …” and “Claude responded:” headings (the Claude app)")
        check(ChatReader.limitNotice(in: gptPage)?.contains("Free plan limit") == true
              && ChatReader.limitNotice(in: claudePage)?.contains("out of free messages") == true,
              "it notices when ChatGPT or Claude runs out of free messages")
        check(ChatReader.limitNotice(in: N("AXWebArea", nil, [N("AXGroup", sub: "AXDocumentArticle", [H("You said:"), P("We keep hitting the usage limit on our API.")])])) == nil
              && !ChatReader.isLimitNotice("Limits of functions, chapter 2"),
              "a chat about limits doesn't set it off")
        // Claude Code in the Claude app: replies aren't marked as messages, and one had the heading "Out of messages."
        let codePage = N("AXWebArea", nil, [
            N("AXGroup", nil, [N("AXGroup", nil, [T("Out of messages.")]), P("When a free AI hits its limit, one click continues the chat.")]),
            N("AXList", nil, [N("AXGroup", nil, [T("You're out of free messages until 3 PM")])]),
        ])
        check(ChatReader.limitNotice(in: codePage) == nil && !ChatReader.isLimitNotice("Out of messages."),
              "a heading or list item about limits isn't mistaken for a limit banner")
        check(ChatReader.isLimitNotice("You've reached your usage limit. Your limit resets at 5:00 PM.")
              && ChatReader.isLimitNotice("You are out of free messages until 3:00 PM"),
              "real banners, free or paid, are still noticed")
        check(!ChatReader.isChatPage("https://claude.ai/epitaxy/local_123") && !ChatReader.isChatPage("https://chatgpt.com/settings")
              && ChatReader.isChatPage("https://claude.ai/chat/abc") && ChatReader.isChatPage("https://chatgpt.com/c/abc")
              && ChatReader.isChatPage("https://gemini.google.com/app/abc") && ChatReader.isChatPage(nil),
              "only conversation pages are watched for limits (not Claude Code or settings)")
        check(ChatReader.service(url: "https://chatgpt.com/c/123", bundleID: "com.apple.Safari") == "ChatGPT"
              && ChatReader.service(url: "https://claude.ai/chat/1", bundleID: nil) == "Claude"
              && ChatReader.service(url: nil, bundleID: "com.anthropic.claudefordesktop") == "Claude"
              && ChatReader.service(url: "https://github.com", bundleID: "com.apple.Safari") == nil
              && ChatReader.cleanTitle("Rank-nullity homework help - ChatGPT", service: "ChatGPT") == "Rank-nullity homework help"
              && ChatReader.cleanTitle("ChatGPT", service: "ChatGPT") == nil,
              "it knows which sites are AI chats and cleans up their titles")

        let gptChat = ChatTranscript(service: "ChatGPT", url: "https://chatgpt.com/c/abc", title: "Rank-nullity homework help", turns: Array(gptTurns.prefix(4)))
        let chatRules = ChatDigest.rules(from: gptChat)
        check(chatRules == ["Don't use numpy.", "Keep it under 200 words.", "The prof wants the answer as a table."],
              "your rules are kept word for word, in order (\(chatRules))")
        let digest = ChatDigest.checkpoint(from: gptChat)
        check(digest.title == "Rank-nullity homework help" && digest.goal == "I need to finish MAT223 assignment 2 tonight."
              && digest.tried.map(\.text) == ["I tried row reducing by hand but it didn't work."]
              && digest.decisions.contains { $0.text == "The issue was a sign error in row 2." }
              && digest.nextStep == "Compute the null space basis."
              && digest.rules?.count == 3 && digest.conversation?.turns.count == 4,
              "without any AI, a chat becomes a checkpoint: goal, what was tried, what was found, the next step")
        check(ChatDigest.condense(String(repeating: "A long explanation sentence here. ", count: 200) + "\n\n```\nlet x = 1\n```", limit: 400).contains("let x = 1"),
              "a long answer is shortened but its code is kept")

        let relayPack = store.createPack(name: "MAT223 A2", emoji: "📗", autoNamed: false)
        store.add(CaptureDraft(text: "Rank-nullity theorem: for an m×n matrix A, rank(A) + nullity(A) = n.", appName: "Safari",
                               title: "Lecture 7: Rank-nullity", url: "https://q.utoronto.ca/courses/1/pages/lecture-7"), to: relayPack.id)
        store.add(CaptureDraft(text: String(repeating: "Assignment 2 question text and marking scheme details. ", count: 400), appName: "Preview",
                               title: "A2.pdf", url: "file:///tmp/A2.pdf"), to: relayPack.id)
        var relayCP = digest
        _ = store.saveCheckpoint(relayCP, for: relayPack.id)
        relayCP = store.latestCheckpoint(for: relayPack.id)!
        check(relayCP.conversation?.turns.count == 4 && relayCP.rules?.first?.text == "Don't use numpy.",
              "the chat and your rules are saved with the checkpoint")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var oldStyle = Checkpoint(); oldStyle.goal = "From Shapr 0.11"
        check((try? dec.decode(Checkpoint.self, from: enc.encode(oldStyle)))?.goal == "From Shapr 0.11", "checkpoints saved by older versions still open")

        let rp = store.pack(relayPack.id)!
        let toClaude = HandoffBuilder.build(pack: rp, checkpoint: relayCP, target: HandoffBuilder.target(for: "Claude"))
        check(toClaude.text.contains("“Don't use numpy.”") && toClaude.text.contains("“The prof wants the answer as a table.”"),
              "the handoff quotes your rules exactly")
        check(toClaude.chat?.complete == true && toClaude.chat?.messages == 4 && toClaude.text.contains("U1: ")
              && gptChat.userTurns.allSatisfy { toClaude.text.contains(ChatCompactor.clean($0.text, role: .user, keepOffer: true)) }
              && toClaude.text.contains("Next step: Compute the null space basis.") && toClaude.text.contains(Handoff.marker),
              "it carries the whole chat, every message in order, with your messages word for word")
        check(!toClaude.text.contains("Already tried") && !toClaude.text.contains("C: the full earlier chat"),
              "when the whole chat is in, nothing is said twice and the chat isn't offered again")
        check(toClaude.text.contains("@shapr") && toClaude.text.contains("Start your reply with these three lines"),
              "it tells the new AI how to ask for more and to read back first")
        check(toClaude.fits && toClaude.text.count < 20_000 && !toClaude.text.contains(String(repeating: "Assignment 2 question text and marking scheme details. ", count: 30)),
              "a huge file isn't dumped in; it's offered on request (\(toClaude.text.count) characters)")
        var longChat = gptChat
        longChat.turns = (1...90).flatMap { i in [ChatTurn(role: .user, text: "Message \(i): " + String(repeating: "more detail about the matrix question ", count: 8)),
                                                  ChatTurn(role: .assistant, text: String(repeating: "A long answer. ", count: 60))] }
        longChat.turns.insert(ChatTurn(role: .user, text: "Always show every step."), at: 0)
        var longCP = ChatDigest.checkpoint(from: longChat)
        longCP.created = Date()
        let toPerplexity = HandoffBuilder.build(pack: rp, checkpoint: longCP, target: HandoffBuilder.target(for: "Perplexity"))
        check(toPerplexity.fits && toPerplexity.text.contains("“Always show every step.”") && toPerplexity.text.contains("Goal:")
              && toPerplexity.text.contains("@shapr"),
              "a 180-message chat still fits a small free plan, rules and all (\(toPerplexity.text.count) of \(toPerplexity.budget))")
        check((toPerplexity.chat?.omitted ?? 0) > 0 && toPerplexity.text.contains("left out to fit") && toPerplexity.text.contains("Message 90:")
              && toPerplexity.text.contains("C: the full earlier chat"),
              "when a chat is too long for a line per message, the newest stay and the whole chat is offered on request (\(toPerplexity.chat?.summary ?? ""))")

        print("Handing over a whole chat in few tokens")
        let code1 = "```python\ndef rank(m):\n    rows = reduce(m)\n    count = 0\n    for r in rows:\n        if any(r): count += 1\n    return count\n```"
        let code2 = code1.replacingOccurrences(of: "count += 1", with: "count = count + 1")
        let filler = String(repeating: "This paragraph explains row reduction in a lot of detail. ", count: 30)
        let wordy = ChatTranscript(service: "ChatGPT", turns: [
            ChatTurn(role: .user, text: "Write rank() without numpy.\n\n\nKeep it short."),
            ChatTurn(role: .assistant, text: "Sure! Here's a first version:\n\n\(code1)\n\n**Why it works**\n\n\(filler)\n\nLet me know if you'd like me to explain more!"),
            ChatTurn(role: .user, text: "It fails on empty rows."),
            ChatTurn(role: .assistant, text: "You're right. The issue was the empty-row check.\n\n\(code2)\n\n\(filler)\n\nWould you like tests for it?"),
            ChatTurn(role: .user, text: "yes"),
            ChatTurn(role: .assistant, text: "## Tests\n\n\(filler)\n\nTherefore the answer is 3 pivots.")])
        let whole = ChatCompactor.compact(wordy, budget: 50_000)
        check(whole.complete && whole.text.hasPrefix("U1: Write rank() without numpy.\nKeep it short.\nA2: Here's a first version:"),
              "your words stay exactly; the AI's “Sure!” goes")
        check(!whole.text.contains("**") && !whole.text.contains("## ") && !whole.text.contains("Let me know")
              && whole.text.contains("Would you like tests for it?"),
              "bold, headings and “let me know” go; an offer you said yes to stays")
        check(whole.text.contains("[code: an earlier version of what's in A4]") && whole.text.contains("count = count + 1")
              && !whole.text.contains("count += 1") && whole.tokens < whole.originalTokens,
              "code that a later message rewrote is kept once (\(whole.summary))")
        let tight = ChatCompactor.compact(wordy, budget: 1500)
        check(tight.text.count <= 1500 && tight.omitted == 0 && tight.shortened > 0
              && ["U1:", "A2 (cut):", "U3:", "A4 (cut):", "U5:", "A6 (cut):"].allSatisfy { tight.text.contains($0) },
              "in a tight space every message still has its line (\(tight.text.count) characters)")
        check(tight.text.contains("It fails on empty rows.") && tight.text.contains("Therefore the answer is 3 pivots.")
              && tight.text.contains("The issue was the empty-row check.") && tight.text.contains("count = count + 1"),
              "what gets cut is the middle of answers: conclusions, the latest code and your words stay")
        var wordyCP = ChatDigest.checkpoint(from: wordy)
        wordyCP.created = Date()
        let wordyHandoff = HandoffBuilder.build(pack: nil, checkpoint: wordyCP, target: HandoffBuilder.Target(name: "Perplexity", budget: 3200, forCode: false))
        check(wordyHandoff.fits && wordyHandoff.chat?.summary.hasPrefix("All 6 messages") == true && wordyHandoff.text.contains("“@shapr A6”"),
              "the handoff says how to get a shortened message in full (\(wordyHandoff.chat?.summary ?? ""))")
        check(HandoffBuilder.answer("a4", handoff: wordyHandoff, pack: nil, checkpoint: wordyCP)?.text.contains("Would you like tests for it?") == true,
              "“@shapr A4” sends that message in full")

        check(HandoffBuilder.requests(in: "Happy to help.\n@shapr S2\nAlso, **@shapr the sign error from earlier**.") == ["S2", "the sign error from earlier"],
              "it spots the new AI's @shapr requests")
        let gotS1 = HandoffBuilder.answer("S1", handoff: toClaude, pack: rp, checkpoint: relayCP)
        check(gotS1?.text.contains("rank(A) + nullity(A) = n") == true, "“@shapr S1” sends that capture")
        let gotC = HandoffBuilder.answer("C", handoff: toClaude, pack: rp, checkpoint: relayCP)
        check(gotC?.text.contains("I tried row reducing by hand") == true, "“@shapr C” sends the earlier chat")
        let gotTopic = HandoffBuilder.answer("the sign error from earlier", handoff: toClaude, pack: rp, checkpoint: relayCP)
        check(gotTopic?.text.contains("sign error in row 2") == true, "“@shapr the sign error from earlier” finds it in the old chat")

        let goodReply = "Goal: Finish MAT223 assignment 2 tonight\nRules: no numpy; keep it under 200 words; answer as a table\nNext: compute the null space basis\n\nLet's do it."
        let goodLines = ReadBack.parse(goodReply)
        check(goodLines != nil && ReadBack.check(goodLines!, against: relayCP, reply: goodReply).allCovered,
              "a complete read-back passes")
        let droppedReply = "Goal: Finish the MAT223 assignment\nRules: keep it under 200 words\nNext: compute the null space basis"
        let dropped = ReadBack.check(ReadBack.parse(droppedReply)!, against: relayCP, reply: droppedReply)
        check(dropped.missed.count == 2 && dropped.missed.contains("Rule: “Don't use numpy.”"), "a read-back that drops your rules is caught (\(dropped.missed))")
        let flippedReply = "Goal: Finish MAT223 assignment 2 tonight\nRules: use numpy; keep it under 200 words; answer as a table\nNext: compute the null space basis"
        check(ReadBack.check(ReadBack.parse(flippedReply)!, against: relayCP, reply: flippedReply).missed == ["Rule: “Don't use numpy.”"],
              "a rule turned around (“use numpy”) is caught too")
        check(ReadBack.parse("Sure! Here's the next step: compute the basis.") == nil, "an ordinary reply isn't mistaken for a read-back")

        print("Wheel")
        check(WheelController.release(highlighted: WheelModel.autoIndex, heldFor: 1) == .cancel,
              "letting go over the center changes nothing")
        check(WheelController.release(highlighted: 2, heldFor: 1) == .commit(2), "letting go over a slot picks it")
        check(WheelController.release(highlighted: nil, heldFor: 0.1) == .stayOpen, "a quick tap keeps the wheel open")
        check(WheelController.release(highlighted: nil, heldFor: 1) == .cancel, "holding without pointing changes nothing")

        await smarterCaptureChecks(root: tmp.appendingPathComponent("smarter"), defaults: defaults)

        print("Design tokens")
        func rgb(_ c: Color, _ dark: Bool) -> NSColor {
            var out = NSColor.black
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                out = NSColor(c).usingColorSpace(.sRGB) ?? .black
            }
            // See-through fills are measured as they look on a panel.
            if out.alphaComponent < 1 {
                var base = NSColor.white
                NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                    base = NSColor(DS.panel).usingColorSpace(.sRGB) ?? .white
                }
                let a = out.alphaComponent
                out = NSColor(srgbRed: out.redComponent * a + base.redComponent * (1 - a), green: out.greenComponent * a + base.greenComponent * (1 - a),
                              blue: out.blueComponent * a + base.blueComponent * (1 - a), alpha: 1)
            }
            return out
        }
        func contrast(_ a: NSColor, _ b: NSColor) -> Double {
            func l(_ c: NSColor) -> Double {
                func f(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
                return 0.2126 * f(c.redComponent) + 0.7152 * f(c.greenComponent) + 0.0722 * f(c.blueComponent)
            }
            let (x, y) = (l(a), l(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        var worstText = 99.0
        for dark in [false, true] {
            for t in [DS.text, DS.text2, DS.text3, DS.accent] {
                for bg in [DS.canvas, DS.panel, DS.well, DS.hover, DS.accentSoft, LibraryViewColors.sidebar] {
                    worstText = min(worstText, contrast(rgb(t, dark), rgb(bg, dark)))
                }
            }
        }
        check(worstText >= 4.5, "every text color reads at 4.5:1 or better on every surface, light and dark (worst \(String(format: "%.2f", worstText)))")
        let onAccent = [false, true].map { contrast(white, rgb(DS.accentFill, $0)) }.min()!
        check(onAccent >= 4.5, "white on the accent button reads at 4.5:1 or better")
        let onDeep = PackStyle.deepHex.map { contrast(white, NSColor(hex: $0)) }.min()!
        check(onDeep >= 4.5, "white labels on hovered wheel slots read at 4.5:1 or better")
        // The orb's initials sit at its middle, where the gloss gradient is about 6% white.
        let onOrb = PackStyle.deepHex.map { h -> Double in
            let c = NSColor(hex: h)
            return contrast(white, NSColor(srgbRed: c.redComponent * 0.94 + 0.06, green: c.greenComponent * 0.94 + 0.06, blue: c.blueComponent * 0.94 + 0.06, alpha: 1))
        }.min()!
        check(onOrb >= 4.0, "initials on pack orbs stay readable (worst \(String(format: "%.2f", onOrb)):1)")
        let packCue = [false, true].flatMap { d in PackStyle.palette.map { contrast(rgb($0, d), rgb(DS.panel, d)) } }.min()!
        check(packCue >= 3, "pack color cues stand out 3:1 from panels in light and dark")
        check(Capture(id: UUID(), text: "func a() {\n    return 1;\n}", capturedAt: Date(), fileName: "a.md").looksLikeCode
              && !Capture(id: UUID(), text: "A normal sentence.\nAnd another one.", capturedAt: Date(), fileName: "b.md").looksLikeCode,
              "code reads in a monospaced font, prose doesn't")

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }
}
