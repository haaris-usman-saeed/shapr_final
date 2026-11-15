import Foundation

/// A scripted but realistic working session, run through the real engine (permission checks,
/// redaction, de-duplication, task grouping, consolidation). Used by `ShaprCoreChecks --demo`,
/// `Shapr --flow-demo`, the self-test, and "Play demo activity" in the app.
public enum FlowDemo {
    public static let vscode = (id: "com.microsoft.VSCode", name: "Visual Studio Code")
    public static let safari = (id: "com.apple.Safari", name: "Safari")
    public static let messages = (id: "com.apple.MobileSMS", name: "Messages")

    public struct Step {
        public var minute: Double
        public var event: ObservationEvent
    }

    public static let projectRoot = "/Users/demo/code/taskboard-api"

    /// The timeline, starting at `start`. Includes noise Shapr must ignore or refuse.
    public static func steps(start: Date) -> [Step] {
        func at(_ m: Double) -> Date { start.addingTimeInterval(m * 60) }
        func ev(_ m: Double, _ kind: ObservationEvent.Kind, _ app: (id: String, name: String), title: String,
                doc: String? = nil, url: String? = nil, hint: String? = nil, text: String? = nil) -> Step {
            Step(minute: m, event: ObservationEvent(at: at(m), sessionID: nil, kind: kind, bundleID: app.id, appName: app.name,
                                                    windowTitle: title, documentPath: doc, url: url, projectHint: hint, text: text))
        }
        var s: [Step] = [
            // Unrelated project first: it must stay its own task.
            ev(0, .focus, vscode, title: "post.md — blog — Visual Studio Code", doc: "/Users/demo/code/blog/post.md", hint: "blog"),
            ev(1, .content, vscode, title: "post.md — blog — Visual Studio Code", hint: "blog",
               text: "% hugo server\nWARN deprecated: .Site.Author was deprecated in Hugo v0.124.0\nWeb Server is available at http://localhost:1313/"),
            // The real task.
            ev(4, .focus, vscode, title: "db.js — taskboard-api — Visual Studio Code", doc: projectRoot + "/src/db.js", hint: "taskboard-api"),
            ev(5, .content, vscode, title: "db.js — taskboard-api — Visual Studio Code", hint: "taskboard-api",
               text: """
               demo@mac taskboard-api % npm run dev
               > taskboard-api@1.0.0 dev
               > node src/server.js
               Server listening on port 3000
               DATABASE_URL=postgres://app:hunter2secret@localhost:5432/taskboard
               Error: connect ECONNREFUSED 127.0.0.1:5432
                   at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1555:16)
               """),
            ev(7, .focus, safari, title: "PostgreSQL: Documentation: 16: 34.1. Database Connection Control Functions",
               url: "https://www.postgresql.org/docs/16/libpq-connect.html?utm_source=x&token=abc123"),
            ev(9, .focus, safari, title: "node.js - ECONNREFUSED when connecting to Postgres on localhost - Stack Overflow",
               url: "https://stackoverflow.com/questions/14168202/econnrefused-postgres-localhost"),
            ev(12, .content, vscode, title: "db.js — taskboard-api — Visual Studio Code", hint: "taskboard-api",
               text: """
               demo@mac taskboard-api % brew services restart postgresql@16
               ==> Successfully restarted `postgresql@16` (label: homebrew.mxcl.postgresql@16)
               demo@mac taskboard-api % npm run dev
               Server listening on port 3000
               Error: connect ECONNREFUSED 127.0.0.1:5432
               """),
            // Not authorized: must never reach memory.
            ev(13, .content, messages, title: "Messages — Sam", text: "Sam: dinner at 7? my card is 4242 4242 4242 4242"),
            // Unrelated browsing: kept briefly, attached to nothing.
            ev(14, .focus, safari, title: "Elden Ring – Wikipedia", url: "https://en.wikipedia.org/wiki/Elden_Ring"),
            ev(15, .focus, vscode, title: ".env — taskboard-api — Visual Studio Code", doc: projectRoot + "/.env", hint: "taskboard-api"),
        ]
        // Thirty minutes in the same file: one observation, not hundreds.
        for i in 0..<40 {
            s.append(ev(16 + Double(i) * 0.5, .focus, vscode, title: ".env — taskboard-api — Visual Studio Code",
                        doc: projectRoot + "/.env", hint: "taskboard-api"))
        }
        s.append(ev(37, .content, vscode, title: ".env — taskboard-api — Visual Studio Code", hint: "taskboard-api",
                    text: "demo@mac taskboard-api % npm run dev\nError: connect ECONNREFUSED 127.0.0.1:5432"))
        return s
    }

    /// What the user tells Shapr with Threads during the demo.
    public static let threads: [(minute: Double, text: String)] = [
        (10, "Don't change the production DATABASE_URL"),
        (11, "I checked the credentials in .env and they match"),
        (38, "Next step: check which port Postgres is listening on"),
    ]

    public struct Report {
        public var accepted = 0, duplicates = 0, rejected = 0
        public var lines: [String] = []
    }

    /// Plays the session into `engine` (authorizing VS Code and Safari for this session, blocking Messages).
    @discardableResult
    public static func play(into engine: FlowEngine, start: Date) -> Report {
        var r = Report()
        if engine.state != .active { engine.start() }
        for app in [vscode, safari, messages] { engine.noteActivated(app.id) }
        engine.setAccess(.session, bundleID: vscode.id, name: vscode.name)
        engine.setAccess(.session, bundleID: safari.id, name: safari.name)
        engine.setAccess(.denied, bundleID: messages.id, name: messages.name)
        var notes = threads[...]
        for step in steps(start: start) {
            while let n = notes.first, n.minute <= step.minute {
                engine.remember(n.text, evidence: EvidenceRef(kind: .note, bundleID: "app.shapr.Shapr", appName: "Shapr",
                                                               at: start.addingTimeInterval(n.minute * 60)))
                notes = notes.dropFirst()
            }
            engine.noteActivated(step.event.bundleID)
            let result: MemoryKernel.IngestResult
            if let t = engine.ticket(for: step.event.bundleID) { result = engine.submit(step.event, ticket: t) }
            else { result = .rejected("no ticket") }
            switch result {
            case .kept: r.accepted += 1
            case .duplicate: r.duplicates += 1
            case .rejected: r.rejected += 1
            }
        }
        for n in notes {
            engine.remember(n.text, evidence: EvidenceRef(kind: .note, bundleID: "app.shapr.Shapr", appName: "Shapr",
                                                           at: start.addingTimeInterval(n.minute * 60)))
        }
        return r
    }

    /// The whole story as text: session, task memory, Lens context, Simulate, stop, resume.
    public static func narrate(directory: URL, start: Date) -> String {
        var out: [String] = []
        func say(_ s: String = "") { out.append(s) }
        var clock = start
        let engine = FlowEngine(directory: directory, now: { clock })

        say("Scene 1 — Start a working session")
        engine.start()
        say("  Session: \(engine.state.rawValue). Authorized: VS Code, Safari (this session). Blocked: Messages.")

        say("\nScene 2 — Work normally (\(steps(start: start).count) observations, scripted)")
        clock = start.addingTimeInterval(38 * 60)
        let rep = play(into: engine, start: start)
        say("  kept \(rep.accepted) · duplicates folded \(rep.duplicates) · refused \(rep.rejected)")
        say("  immediate memory: \(engine.kernel.immediate.events.count) events in RAM, \(engine.kernel.immediate.bytes) bytes")

        say("\nScene 3 — Shapr understands")
        if let s = engine.summary() {
            say("  Current task: \(s.task.title) [\(s.task.titleProvenance.label)]")
            for sec in s.sections {
                say("  \(sec.heading):")
                for r in sec.records.prefix(4) {
                    let src = r.evidence.last.map { " ← \($0.appName)\($0.title.map { ": " + Text.clip($0, 50) } ?? "")" } ?? ""
                    say("    • \(r.text) (\(r.provenance.label)\(r.occurrences > 1 ? ", ×\(r.occurrences)" : ""))\(src)")
                }
            }
            say("  Sources: " + s.task.sources.map { Text.clip($0.title, 48) }.joined(separator: " | "))
        }
        say("  Other tasks: " + engine.kernel.tasks.filter { $0.id != engine.activeTask?.id }.map(\.title).joined(separator: ", "))

        say("\nScene 4 — Lens on the circled error")
        let ctx = engine.context(for: "Error: connect ECONNREFUSED 127.0.0.1:5432", budget: 2000)
        say(ctx.rendered(now: clock).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))

        say("\nScene 5 — Simulate two approaches")
        let cmp = engine.compare(selection: "DATABASE_URL=postgres://localhost:5432/taskboard",
                                 paths: ["Run Postgres in Docker and point DATABASE_URL at the container",
                                         "Keep local Postgres and fix the port it listens on"])
        say("  " + ScenarioComparison.disclaimer)
        for p in cmp.paths {
            say("  Path: \(p.title)")
            for l in p.consistentWith { say("    + \(l.why): \(Text.clip(l.record.text, 70))") }
            for l in p.possibleTensions { say("    ! \(l.why): \(Text.clip(l.record.text, 70))") }
            for l in p.triedBefore { say("    ↺ \(l.why): \(Text.clip(l.record.text, 70))") }
            for l in p.questions { say("    ? \(l.why): \(Text.clip(l.record.text, 70))") }
            for a in p.assumptions { say("    ~ \(a)") }
        }

        say("\nScene 6 — Stop, restart, continue")
        engine.end()
        engine.store.flush()
        say("  Session ended; \(engine.lastEpisodes.count) episode(s) kept; stored memory \(engine.storedBytes) bytes.")
        clock = start.addingTimeInterval(20 * 3600)
        let restarted = FlowEngine(directory: directory, now: { clock })
        restarted.start()
        if let s = restarted.resumeCandidate() {
            say("  Continue where you left off:")
            for l in s.resume { say("    \(l.text)  [\(l.provenance.label)\(l.evidence.isEmpty ? "" : ", \(l.evidence.count) source\(l.evidence.count == 1 ? "" : "s")")]") }
        } else {
            say("  (nothing to resume)")
        }
        say("\nMetrics\n" + engine.metrics.report.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
        return out.joined(separator: "\n")
    }
}
