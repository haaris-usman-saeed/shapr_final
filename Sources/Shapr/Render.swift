import AppKit
import SwiftUI

/// Developer helpers that need no permissions:
///   `Shapr --render <dir>`     PNG snapshots of every surface, in light and dark
///   `Shapr --make-icon <dir>`  the app icon as an .iconset folder
@MainActor
enum Render {
    enum Mode: CaseIterable {
        case light, dark
        var appearance: NSAppearance { NSAppearance(named: self == .light ? .aqua : .darkAqua)! }
        var suffix: String { self == .light ? "" : "-dark" }
        /// Stands in for a desktop behind floating panels.
        var backdrop: some View {
            LinearGradient(colors: self == .light ? [Color(white: 0.80), Color(red: 0.74, green: 0.76, blue: 0.82)]
                                                  : [Color(white: 0.16), Color(red: 0.10, green: 0.11, blue: 0.15)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Offscreen snapshots can't sample what's behind a window, so glass is drawn as a stand-in here.
        GlassSettings.snapshotFallback = true

        // Sample library in a throwaway folder.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("shapr-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "app.shapr.render")!
        defaults.removePersistentDomain(forName: "app.shapr.render")
        let store = PackStore(root: tmp, defaults: defaults)

        let course = store.createPack(name: "MAT223", emoji: nil, autoNamed: false)
        for (title, text) in [
            ("Lecture 14 · Eigenvalues", "Eigenvalues of A are the roots of det(A − λI) = 0. For each eigenvalue λ, solve (A − λI)v = 0 to get the eigenspace."),
            ("Lecture 15 · Diagonalization", "A matrix is diagonalizable when it has n independent eigenvectors: A = PDP⁻¹, with the eigenvalues on the diagonal of D."),
            ("Problem Set 6", "Find the eigenvalues and a basis for each eigenspace of the 2×2 matrix. Then decide whether the matrix is diagonalizable."),
            ("Lecture 7 · Rank–nullity", "Rank-nullity theorem: for an m×n matrix A, rank(A) + nullity(A) = n. The null space is found by row reduction."),
            ("Row reduction cheat sheet", "Row reduction steps: swap rows, scale a row, add a multiple of one row to another. Pivots give the rank."),
            ("Lecture 9 · Determinants", "The determinant changes sign when rows swap, and scales when a row is scaled. A matrix is invertible exactly when its determinant is non-zero."),
            ("Midterm 2 info", "Midterm 2 covers determinants, eigenvalues and diagonalization. Thursday 6pm, EX 100. One aid sheet allowed."),
            ("TA office hours", "Office hours before the midterm: Tuesday 3–5 in BA 6283. Bring your aid sheet questions."),
            ("Null space example", "Null space of A: solve Ax = 0 by row reduction; the free variables give a basis. Its dimension is the nullity."),
            ("Piazza: common mistakes", "Common mistakes on the midterm: forgetting that swapping rows flips the determinant, and mixing up eigenvalues with pivots.")] {
            store.add(CaptureDraft(text: text, appName: "Safari", title: title, url: "https://q.utoronto.ca/courses/mat223"), to: course.id)
        }
        let cars = store.createPack(name: "Cars", emoji: "🚗", autoNamed: true)
        store.add(CaptureDraft(text: "The 2025 Toyota Supra uses a turbocharged inline-six engine making 382 horsepower and 368 lb-ft of torque. A six-speed manual is available.",
                               appName: "Safari", title: "Toyota Supra specs", url: "https://www.caranddriver.com/toyota/supra"), to: cars.id)
        store.add(CaptureDraft(text: "Electric cars like the Tesla Model 3 cost less to maintain than gasoline cars: no oil changes, fewer moving parts, and regenerative braking saves pads.",
                               appName: "Google Chrome", title: "EV maintenance costs", url: "https://www.motortrend.com/ev-costs"), to: cars.id)
        let shotImage = SelfTest.textImage("Supra GR  ·  0–60 in 3.9 s  ·  382 hp")
        store.add(CaptureDraft(text: "Supra GR · 0–60 in 3.9 s · 382 hp", appName: "Safari", title: "Supra dashboard",
                               url: "https://www.toyota.com/grsupra", imageData: ScreenCapture.png(shotImage)), to: cars.id)
        let csv = tmp.appendingPathComponent("ev-costs.csv")
        try? "model,cost_per_year\nModel 3,620\nSupra,1180".write(to: csv, atomically: true, encoding: .utf8)
        store.add(CaptureDraft(text: "model,cost_per_year\nModel 3,620\nSupra,1180", appName: "Finder", title: "ev-costs.csv",
                               url: csv.absoluteString, attachment: csv), to: cars.id)
        store.add(CaptureDraft(text: "Insurance for a sports coupe under 25 is roughly 40% higher than for a sedan. Bundling with renters insurance and a telematics discount can bring it down.",
                               appName: "Arc", title: "Insurance for young drivers", url: "https://www.nerdwallet.com/car-insurance"), to: cars.id)
        let games = store.createPack(name: "Video Games", emoji: "🎮", autoNamed: true)
        store.add(CaptureDraft(text: "Elden Ring is an open-world action RPG by FromSoftware.", appName: "Arc",
                               title: "Elden Ring", url: "https://en.wikipedia.org/wiki/Elden_Ring"), to: games.id)
        let bug = store.createPack(name: "Bug #42", emoji: "🐞", autoNamed: true)
        store.add(CaptureDraft(text: "Hi, I'm Jane Doe from Acme. The dashboard crashes for me (jane.doe@acme.com). Repro on https://staging.acme.internal/dash?token=abc123. TypeError: Cannot read properties of undefined (reading 'map')",
                               appName: "Mail", title: "Customer report"), to: bug.id)
        store.add(CaptureDraft(text: "function render(summary) {\n    const rows = summary.items.map(toRow);\n    return <Table rows={rows} />;\n}",
                               appName: "Cursor", title: "Dashboard.render"), to: bug.id)
        let me = store.createPack(name: "About me", emoji: "🙋", autoNamed: false)
        store.add(CaptureDraft(text: "Moosa Usman · moosa@example.com · Software Engineering, University of Toronto",
                               appName: "Notes", title: "My details"), to: me.id)
        store.add(CaptureDraft(text: "I build developer tools. Shapr, my macOS app, moves context between apps.",
                               appName: "Notes", title: "Why I build tools"), to: me.id)
        let longPack = store.createPack(name: "Internship applications for summer 2027", emoji: "💼", autoNamed: false)
        let writing = store.createPack(name: "My Writing", emoji: "✍️", autoNamed: false)
        store.setRole(writing.id, .style)
        store.add(CaptureDraft(text: "Hey Jane! Thanks for flagging this. On it today, will update you by EOD. Cheers, Moosa",
                               appName: "Mail", title: "Reply to a customer"), to: writing.id)
        var repoSource = PackSource(kind: .github, location: "acme/app", title: "acme/app")
        repoSource.lastChecked = Date().addingTimeInterval(-240)
        repoSource.itemCount = 14
        var folderSource = PackSource(kind: .folder, location: "/Users/moosa/Documents/Car research", title: "Car research")
        folderSource.lastChecked = Date().addingTimeInterval(-60)
        var threadSource = PackSource(kind: .page, location: "https://mail.google.com/mail/u/0/#inbox/FMfcgzQXJabcdefghijk", title: "Dealer quote thread")
        threadSource.lastChecked = Date().addingTimeInterval(-10 * 86_400)
        store.saveSources([folderSource, repoSource, threadSource], for: cars.id)
        let empty = store.createPack(name: "History Essay", emoji: "📚", autoNamed: false)
        _ = longPack
        store.equip(cars.id)
        // Cars is shared with a live link (3 people joined, 1 capture waiting); Video Games was added from someone's link.
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        func keep<T: Encodable>(_ v: T, in pack: Pack, as name: String) {
            let dir = pack.folder.appendingPathComponent(".shapr")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? enc.encode(v).write(to: dir.appendingPathComponent(name))
        }
        var liveCars = ShareState(id: "AbC123xyz789", url: "https://shapr.app/p/AbC123xyz789")
        liveCars.joins = 3
        liveCars.held = [UUID()]
        keep(liveCars, in: store.pack(cars.id)!, as: "share.json")
        keep(Subscription(id: "XyZ987abc654", server: "https://shapr.app", lastSync: Date().addingTimeInterval(-120)),
             in: store.pack(games.id)!, as: "subscription.json")

        for mode in Mode.allCases {
            let sfx = mode.suffix

            // Wheel: hovering a pack, and holding over the neutral center.
            let model = WheelModel()
            model.slots = store.wheelSlots.map { id in
                guard let p = store.pack(id) else { return WheelSlot(packID: nil, badge: "", name: "", count: 0) }
                return WheelSlot(packID: p.id, badge: PackStyle.initials(p.name), name: p.name, count: p.captures.count, color: PackStyle.color(p.id),
                                 isEmoji: p.meta.emoji != nil, deep: PackStyle.deep(p.id))
            }
            model.appeared = true
            model.equipped = store.wheelSlots.firstIndex(of: cars.id) ?? 0
            model.highlighted = store.wheelSlots.firstIndex(of: games.id) ?? 1
            panel(WheelView(model: model), mode: mode, to: dir.appendingPathComponent("wheel\(sfx).png"))
            let center = WheelModel()
            center.slots = model.slots
            center.appeared = true
            center.equipped = model.equipped
            center.highlighted = WheelModel.autoIndex
            panel(WheelView(model: center), mode: mode, to: dir.appendingPathComponent("wheel-center\(sfx).png"))

            // Capture cards.
            let shot = NSImage(cgImage: shotImage, size: NSSize(width: shotImage.width, height: shotImage.height))
            let carsPack = store.pack(cars.id)!
            let cards: [(String, ToastContent)] = [
                ("card-screenshot", ToastContent(icon: .emoji("🚗"), title: "Supra dashboard", subtitle: "toyota.com · Safari · just now",
                                                 actions: [ToastAction(title: "Undo"), ToastAction(title: "Move", style: .menu([]))],
                                                 preview: .image(shot), pack: carsPack, eyebrow: "Added to", expandable: true)),
                ("card-quote", ToastContent(icon: .emoji("🚗"), title: "EV maintenance costs", subtitle: "motortrend.com · Chrome · just now",
                                            actions: [ToastAction(title: "Add", style: .primary), ToastAction(title: "Change", style: .menu([])),
                                                      ToastAction(title: "New pack"), ToastAction(title: "Discard")],
                                            preview: .quote("Electric cars cost less to maintain…"), pack: carsPack, eyebrow: "Add to", expandable: true)),
                ("card-file", ToastContent(icon: .emoji("📕"), title: "mat223_2_6_I.pdf", subtitle: "You opened it in Preview",
                                           actions: [ToastAction(title: "Add", style: .primary), ToastAction(title: "Other", style: .menu([])),
                                                     ToastAction(title: "Not here")],
                                           preview: .file(name: "mat223_2_6_I.pdf", ext: "pdf"), pack: carsPack, eyebrow: "Add to")),
                ("toast-working", ToastContent(icon: .spinner, title: "Sorting…", subtitle: "Saved. Picking a pack for it.")),
                ("toast-new", ToastContent(icon: .emoji("🐞"), title: "New pack: Bug #42", subtitle: "Issue #42 · dashboard crash",
                                           actions: [ToastAction(title: "Undo"), ToastAction(title: "Rename"), ToastAction(title: "Move", style: .menu([]))])),
                // Moving between AIs.
                ("relay-limit", ToastContent(icon: .symbol("arrow.triangle.branch"), title: "ChatGPT hit its message limit",
                                             subtitle: "It says “You've hit the Free plan limit for GPT-5.” Keep going in another AI with this chat and your rules.",
                                             actions: [ToastAction(title: "Continue in Claude", style: .primary), ToastAction(title: "Gemini")])),
                ("relay-pasted", ToastContent(icon: .symbol("checkmark.circle"), title: "Pasted into Claude. Check it, then press Return.",
                                              subtitle: "About 2,900 tokens, sized for free Claude. Shapr will check it read everything and answer its @shapr requests.",
                                              actions: [ToastAction(title: "Stop watching")], tint: DS.success)),
                ("relay-readback-ok", ToastContent(icon: .symbol("checkmark.seal"), title: "Claude got everything",
                                                   subtitle: "All 5 things you saved (goal, rules and next step) carried over.", tint: DS.success, eyebrow: "Read-back")),
                ("relay-readback-missed", ToastContent(icon: .symbol("exclamationmark.bubble"), title: "Claude missed 1 of 5",
                                                       subtitle: "Rule: “Don't use numpy.”",
                                                       actions: [ToastAction(title: "Send it", style: .primary), ToastAction(title: "Ignore")],
                                                       tint: DS.warning, eyebrow: "Read-back")),
                ("relay-request", ToastContent(icon: .symbol("arrow.down.doc"), title: "Claude asked for S2: A2.pdf",
                                               subtitle: "4,800 characters from MAT223. Send it into the chat?",
                                               actions: [ToastAction(title: "Send", style: .primary), ToastAction(title: "Skip")], eyebrow: "Asked Shapr")),
            ]
            for (name, content) in cards {
                panel(ToastView(content: content), mode: mode, to: dir.appendingPathComponent("\(name)\(sfx).png"))
            }

            // Library.
            let state = LibraryState()
            state.layout = .grid
            state.selection = cars.id
            state.selectedCapture = store.pack(cars.id)?.captures.first?.id
            state.axTrusted = true
            state.screenTrusted = true
            library(store, state, size: CGSize(width: 1240, height: 760), mode: mode, to: dir.appendingPathComponent("library\(sfx).png"))

            // The map of a pack.
            let map = LibraryState()
            map.selection = course.id
            map.layout = .graph
            map.selectedCapture = store.pack(course.id)?.captures.first?.id
            library(store, map, size: CGSize(width: 1240, height: 760), mode: mode, to: dir.appendingPathComponent("library-graph\(sfx).png"))
            map.layout = .grid

            if mode == .light {
                let list = LibraryState()
                list.selection = cars.id
                list.layout = .list
                list.selectedCapture = store.pack(cars.id)?.captures[2].id
                library(store, list, size: CGSize(width: 1240, height: 700), mode: mode, to: dir.appendingPathComponent("library-list.png"))
                list.layout = .grid

                let small = LibraryState()
                small.selection = cars.id
                small.layout = .grid
                small.selectedCapture = store.pack(cars.id)?.captures[2].id
                library(store, small, size: CGSize(width: 900, height: 620), mode: mode, to: dir.appendingPathComponent("library-small.png"))

                let emptyState = LibraryState()
                emptyState.selection = empty.id
                library(store, emptyState, size: CGSize(width: 1040, height: 620), mode: mode, to: dir.appendingPathComponent("library-empty.png"))

                let search = LibraryState()
                search.query = "turbo diesel"
                library(store, search, size: CGSize(width: 1040, height: 620), mode: mode, to: dir.appendingPathComponent("library-search-none.png"))

                let found = LibraryState()
                found.query = "supra"
                library(store, found, size: CGSize(width: 1040, height: 620), mode: mode, to: dir.appendingPathComponent("library-search.png"))

                let welcome = LibraryState()
                welcome.axTrusted = true
                welcome.screenTrusted = false
                library(store, welcome, size: CGSize(width: 1040, height: 700), mode: mode, to: dir.appendingPathComponent("library-welcome.png"))
            }

            // Draft.
            let dm = DropModel()
            dm.target = DropTarget(app: nil, appName: "Google Chrome", url: "https://mail.google.com", title: "Re: Dashboard is broken – jane.doe@acme.com",
                                   fieldText: nil, destination: .email, label: "Gmail")
            dm.packID = bug.id
            dm.draft = "Hi Jane,\n\nThanks for reporting this. I can reproduce the crash: the dashboard throws “Cannot read properties of undefined (reading 'map')” when it loads.\n\nCould you tell me which browser and version you're using? That will help us confirm the fix.\n\nBest,\nMoosa"
            dm.sources = [1]
            dm.engine = "Written by Claude Opus 5.5"
            panel(DropView(model: dm, store: store), mode: mode, to: dir.appendingPathComponent("drop\(sfx).png"))
            if mode == .light {
                dm.instruction = "make it shorter"
                dm.phase = .failed("Claude didn't answer (network offline).")
                panel(DropView(model: dm, store: store), mode: mode, to: dir.appendingPathComponent("drop-failed.png"))
            }

            // Form review.
            let fm = FormFillModel()
            fm.target = DropTarget(app: nil, appName: "Safari", url: "https://jobs.stripe.com/apply", title: "Apply · Software Engineering Intern",
                                   destination: .generic, label: "Safari")
            let dummy = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            func f(_ id: Int, _ label: String, _ kind: SensitiveKind? = nil, multi: Bool = false) -> FormField {
                FormField(id: id, element: dummy, label: label, placeholder: nil, currentValue: nil, isSecure: kind == .password,
                          isMultiline: multi, sensitive: kind)
            }
            let demoVault = [VaultItem(id: UUID(), kind: .cardNumber, label: "Chase Visa", site: nil)]
            fm.rows = [
                .init(field: f(1, "Full name"), include: true, value: "Moosa Usman", source: 1, vaultItem: nil),
                .init(field: f(2, "Email"), include: true, value: "moosa@example.com", source: 1, vaultItem: nil),
                .init(field: f(3, "Phone"), include: false, value: "", source: nil, vaultItem: nil),
                .init(field: f(4, "Why do you want to work at Stripe?", multi: true), include: true,
                      value: "I build developer tools. Shapr, my macOS app, moves context between apps, and Stripe's API-first culture is where I want to learn to do that at scale.", source: 2, vaultItem: nil),
                .init(field: f(5, "Card number", .cardNumber), include: true, value: "", source: nil, vaultItem: demoVault[0].id),
            ]
            var country = f(6, "Country of residence")
            country.kind = .choice
            country.options = ["Select…", "Canada", "Pakistan", "United States"]
            var start = f(7, "Earliest start date")
            start.kind = .date
            var relocate = f(8, "I'm willing to relocate")
            relocate.kind = .checkbox
            var terms = f(9, "I agree to the Terms and the Privacy Policy")
            terms.kind = .checkbox
            fm.rows += [
                .init(field: country, include: true, value: "Canada", source: 1, vaultItem: nil),
                .init(field: start, include: true, value: "2027-05-03", source: 2, vaultItem: nil),
                .init(field: relocate, include: true, value: "yes", source: 2, vaultItem: nil),
                .init(field: terms, include: false, value: "", source: nil, vaultItem: nil),
            ]
            fm.packIDs = [me.id]
            fm.refs = FormMapper.context(from: [store.pack(me.id)!]).refs
            fm.phase = .ready
            panel(FormFillView(model: fm, store: store, vaultItems: demoVault), mode: mode, to: dir.appendingPathComponent("formfill\(sfx).png"))
            if mode == .light {
                let choices = FormFillModel()
                choices.target = fm.target
                choices.rows = Array(fm.rows.suffix(4))
                choices.packIDs = fm.packIDs
                choices.refs = fm.refs
                choices.phase = .ready
                panel(FormFillView(model: choices, store: store, vaultItems: demoVault), mode: mode, to: dir.appendingPathComponent("formfill-choices.png"))
            }

            // Save progress and Continue in.
            var cp = Checkpoint()
            let bugCaps = store.pack(bug.id)!.captures
            cp.title = "Fix dashboard crash on load"
            cp.goal = "Stop the dashboard crashing for customers on load."
            cp.decisions = [.init(text: "Fix it in the API response, not with a frontend guard.", sources: bugCaps.prefix(1).map(\.id))]
            cp.tried = [.init(text: "Defaulting items to [] in Dashboard.render hid the error but showed an empty dashboard.", sources: bugCaps.suffix(1).map(\.id))]
            cp.openProblems = [.init(text: "Why /api/summary sometimes returns no items field.", sources: bugCaps.prefix(1).map(\.id))]
            cp.nextStep = "Log the raw /api/summary response for Jane's account."
            cp.tabs = [.init(url: "https://github.com/acme/app/issues/42", title: "Dashboard crash · Issue #42", browserBundleID: "com.apple.Safari"),
                       .init(url: "https://www.youtube.com/watch?v=dQw4", title: "Lo-fi beats", browserBundleID: "com.apple.Safari", keep: false)]
            cp.engine = "Claude Opus 5.5"
            cp.rules = [.init(text: "Don't add a frontend guard; fix the data."), .init(text: "Keep the fix under 20 lines.")]
            let cm = CheckpointModel()
            cm.packID = bug.id
            cm.cp = cp
            cm.phase = .ready
            cm.transcript = ChatTranscript(service: "ChatGPT", url: "https://chatgpt.com/c/demo", title: "Dashboard crash",
                                           turns: (0..<24).map { ChatTurn(role: $0 % 2 == 0 ? .user : .assistant, text: "message \($0)") })
            panel(CheckpointView(model: cm, store: store), mode: mode, to: dir.appendingPathComponent("checkpoint\(sfx).png"))
            if store.latestCheckpoint(for: bug.id) == nil { _ = store.saveCheckpoint(cp, for: bug.id) }
            let rm = ResumeModel()
            rm.target = DropTarget(app: nil, appName: "ChatGPT", destination: .aiChat, label: "ChatGPT")
            rm.destinationLabel = "ChatGPT"
            rm.packID = bug.id
            rm.checkpointID = store.latestCheckpoint(for: bug.id)?.id
            let rh = HandoffBuilder.build(pack: store.pack(bug.id)!, checkpoint: store.latestCheckpoint(for: bug.id)!,
                                          target: HandoffBuilder.target(for: "ChatGPT"))
            rm.handoff = rh
            rm.prompt = rh.text
            panel(ResumeView(model: rm, store: store), mode: mode, to: dir.appendingPathComponent("resume\(sfx).png"))
            rm.stale = Checkpoint.Staleness(removedSources: 0, changedFiles: ["Dashboard.js"], newCaptures: 2)
            panel(ResumeView(model: rm, store: store), mode: mode, to: dir.appendingPathComponent("resume-stale\(sfx).png"))

            // Use this with my pack: an error, against the Bug #42 pack.
            let um = UseModel()
            um.packID = bug.id
            um.target = DropTarget(app: nil, appName: "Google Chrome", url: "https://github.com/acme/app/issues/42",
                                   title: "Dashboard crash · Issue #42", destination: .github, label: "GitHub issue")
            um.input = "TypeError: Cannot read properties of undefined (reading 'map')\n    at render (Dashboard.js:12:5)"
            um.kind = PackAssist.kind(of: um.input, app: "Google Chrome")
            um.excerpts = PackAssist.excerpts(for: um.input, in: store.pack(bug.id)!, kind: um.kind)
            um.brief = PackAssist.brief(kind: um.kind, input: um.input, packName: "Bug #42", excerpts: um.excerpts,
                                        checkpoint: store.latestCheckpoint(for: bug.id))
            um.canInsertHere = true
            um.destination = .claude
            panel(UseView(model: um, store: store), mode: mode, to: dir.appendingPathComponent("use\(sfx).png"))

            // Draft with the pack picked from the sender, and a style pack for your voice.
            let pm = DropModel()
            pm.target = DropTarget(app: nil, appName: "Google Chrome", url: "https://mail.google.com", title: "Re: Dashboard is broken – jane.doe@acme.com",
                                   fieldText: nil, destination: .email, label: "Gmail")
            pm.packID = bug.id
            pm.fallbackID = cars.id
            pm.picked = RouteSuggestion(packID: bug.id, reason: "the email is from someone at acme.com", score: 4.2)
            pm.styleID = writing.id
            pm.draft = "Hey Jane! Thanks for flagging this. I can reproduce the crash on load, so we're on it today.\n\nWhich browser are you on? That'll help us confirm the fix.\n\nCheers,\nMoosa"
            pm.sources = [1]
            pm.engine = "Claude Opus 5.5 · sounds like My Writing"
            panel(DropView(model: pm, store: store), mode: mode, to: dir.appendingPathComponent("drop-picked\(sfx).png"))

            // Ask the pack.
            let am = AskModel()
            am.scope = nil
            am.question = "What did they say about the crash?"
            am.asked = am.question
            am.hits = AskEngine.hits(for: "dashboard crash map undefined", in: store.packs.filter { !$0.isStyle })
            am.answer = "Jane from Acme reported that the dashboard crashes when it loads, with “Cannot read properties of undefined (reading 'map')” [1]. The crash comes from Dashboard.render calling summary.items.map when items is missing [2]."
            am.phase = .done("Claude Opus 5.5")
            panel(AskView(model: am, store: store), mode: mode, to: dir.appendingPathComponent("ask\(sfx).png"))
            if mode == .light {
                let sm = AskModel()
                let errImage = SelfTest.textImage("TypeError: Cannot read properties of undefined (reading 'map')")
                sm.shot = AskModel.Shot(image: NSImage(cgImage: errImage, size: .zero), png: ScreenCapture.png(errImage) ?? Data(),
                                        text: "TypeError: Cannot read properties of undefined (reading 'map')",
                                        draft: CaptureDraft(text: "", title: "Dashboard · localhost:3000"))
                sm.scope = bug.id
                sm.question = "Why is this happening?"
                sm.asked = sm.question
                sm.hits = AskEngine.hits(for: "map undefined dashboard", in: [store.pack(bug.id)!])
                sm.answer = "Dashboard.render calls summary.items.map, and the API sometimes returns no items field [2]. Jane hit the same crash on load [1]."
                sm.phase = .done("Claude Opus 5.5")
                panel(AskView(model: sm, store: store), mode: mode, to: dir.appendingPathComponent("ask-shot.png"))
            }

            // Voice note.
            let vm = VoiceModel()
            vm.preparing = false
            vm.status = "Listening"
            vm.text = "Remember to ask Jane which browser she's on, and log the raw summary response for her account"
            vm.level = 0.5
            vm.hint = "Let go when you're done · esc cancels"
            vm.pack = store.pack(bug.id)
            panel(VoiceView(model: vm), mode: mode, to: dir.appendingPathComponent("voice\(sfx).png"))

            // ⌥⇧Space with text selected in Safari.
            let qm = QuickModel()
            qm.pack = store.pack(cars.id)
            qm.context = "Safari"
            qm.items = [
                QuickItem(id: "use", symbol: "sparkle.magnifyingglass", title: "Use with Cars", subtitle: "What in your pack matters for “Is the Supra AWD?”", keys: "⌥⇧U") {},
                QuickItem(id: "scoop", symbol: "plus.square.on.square", title: "Scoop into Cars", subtitle: "Save the selection", keys: "⌥⇧C") {},
                QuickItem(id: "continue", symbol: "arrow.uturn.right", title: "Continue: Pick a first car", subtitle: "Next: Compare insurance quotes", keys: "⌥⇧R") {},
                QuickItem(id: "circle", symbol: "lasso", title: "Circle something on screen", subtitle: "Screenshots, text, or file links", keys: "⌘⌘") {},
                QuickItem(id: "switch", symbol: "circle.grid.cross", title: "Switch pack", subtitle: "Now: Cars", keys: "⌥S") {},
                QuickItem(id: "library", symbol: "books.vertical", title: "Open library", keys: nil) {},
            ]
            panel(QuickView(model: qm), mode: mode, to: dir.appendingPathComponent("quick\(sfx).png"))

            let cpState = LibraryState()
            cpState.selection = bug.id
            library(store, cpState, size: CGSize(width: 1040, height: 680), mode: mode, to: dir.appendingPathComponent("library-checkpoint\(sfx).png"))

            // Settings: every tab in light, General in dark.
            for tab in SettingsView.Tab.allCases where mode == .light || tab == .general {
                window(SettingsView(tab: tab, appleStatus: "Ready"), size: SettingsView.size, mode: mode,
                       to: dir.appendingPathComponent("settings-\(tab.rawValue)\(sfx).png"))
            }
        }

        let session = ShareSession(pack: store.pack(bug.id)!, rules: RedactionRules())
        window(ShareReviewView(session: session), size: CGSize(width: 1040, height: 640), mode: .light,
               to: dir.appendingPathComponent("share.png"))

        for (name, done) in [("circle", false), ("circle-done", true)] {
            let size = CGSize(width: 900, height: 560)
            let container = NSView(frame: CGRect(origin: .zero, size: size))
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.97, alpha: 1).cgColor
            let label = NSTextField(labelWithString: "Toyota Supra · 382 hp · 0–60 in 3.9 s")
            label.font = .systemFont(ofSize: 30, weight: .bold)
            label.textColor = NSColor(calibratedWhite: 0.15, alpha: 1)
            label.frame = CGRect(x: 230, y: 250, width: 520, height: 40)
            container.addSubview(label)
            let overlay = CaptureOverlayView(frame: container.bounds)
            overlay.hint = "Circle anything with your pointer, then pause  ·  saves to 🚗 Cars  ·  esc to cancel"
            overlay.accent = NSColor(PackStyle.color(cars.id))
            var loop: [CGPoint] = []
            for i in 0...120 {
                let t = Double(i) / 120 * 2 * .pi + 0.4
                loop.append(CGPoint(x: 470 + 300 * cos(t) + 6 * sin(5 * t), y: 268 + 72 * sin(t)))
            }
            if done {
                overlay.previewLocked(loop)
            } else {
                // The last ~0.55 s of movement: a fading comet on the far side of the loop.
                let recent = Array(loop[40...78])
                overlay.preview(trail: recent, ages: recent.indices.map { Double(recent.count - 1 - $0) * 0.014 })
            }
            container.addSubview(overlay)
            let w = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = Mode.light.appearance
            w.contentView = container
            w.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            w.orderFrontRegardless()
            overlay.stop() // snapshot the staged trail, not the real pointer
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
                container.cacheDisplay(in: container.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            }
            w.orderOut(nil)
        }
        print("Rendered to \(dir.path)")
    }

    /// A floating panel or card over a desktop-like backdrop, sized to fit.
    private static func panel<V: View>(_ view: V, mode: Mode, to url: URL) {
        window(view.padding(28).background(mode.backdrop), size: nil, mode: mode, to: url)
    }

    private static func library(_ store: PackStore, _ state: LibraryState, size: CGSize, mode: Mode, to url: URL) {
        let view = LibraryView(actions: LibraryActions()).environmentObject(store).environmentObject(state)
            .environmentObject(SourceSync(store: store))
            .environmentObject(SharedPacks(store: store))
        window(view, size: size, mode: mode, to: url, library: true)
    }

    private static func window<V: View>(_ view: V, size: CGSize?, mode: Mode, to url: URL, library: Bool = false) {
        let host = NSHostingView(rootView: view)
        host.appearance = mode.appearance
        let fit = size ?? host.fittingSize
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: fit),
                         styleMask: library ? [.titled, .resizable, .fullSizeContentView] : [.titled, .resizable],
                         backing: .buffered, defer: false)
        w.appearance = mode.appearance
        if library { LibraryWindow.style(w) }
        w.contentView = host
        w.setContentSize(fit)
        w.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        w.orderFrontRegardless()
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        w.orderOut(nil)
    }

    private static func write(_ img: NSImage, to url: URL) {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    // MARK: Icon

    static func makeIcon(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let r = ImageRenderer(content: AppIconView().frame(width: 1024, height: 1024))
                r.scale = CGFloat(px) / 1024
                guard let img = r.nsImage else { continue }
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                write(img, to: dir.appendingPathComponent(name))
            }
        }
    }
}

/// Six-slot inventory wheel on a dark tile, one slot lit.
struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.19), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 4)
                    .frame(width: 824, height: 824))
            ForEach(0..<6, id: \.self) { i in
                let mid = Double(i) * 60 - 90
                AnnularSector(start: .degrees(mid - 30 + 3), end: .degrees(mid + 30 - 3), inner: 150, outer: 330)
                    .fill(i == 1 ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.13)))
                    .frame(width: 1024, height: 1024)
            }
            Circle().fill(Color(white: 0.09)).frame(width: 236, height: 236)
                .overlay(Circle().strokeBorder(Theme.indigo, lineWidth: 10).frame(width: 236, height: 236))
            Image(systemName: "sparkles")
                .font(.system(size: 104, weight: .bold))
                .foregroundStyle(Theme.gradient)
        }
        .frame(width: 1024, height: 1024)
    }
}
