import Foundation

/// Behaviour checks for Shapr Flow's core. Run by `swift run ShaprCoreChecks` (any platform) and
/// by `Shapr --selftest` on a Mac. Each check states the behaviour it guarantees.
public enum FlowCoreChecks {
    public static func run(_ check: (Bool, String) -> Void, section: (String) -> Void = { print($0) }) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shapr-flow-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        var n = 0
        func dir() -> URL { n += 1; return base.appendingPathComponent("\(n)") }
        let t0 = Date(timeIntervalSince1970: 1_793_000_000) // a fixed Tuesday afternoon
        let vs = FlowDemo.vscode, safari = FlowDemo.safari, msgs = FlowDemo.messages

        func event(_ app: (id: String, name: String), _ kind: ObservationEvent.Kind = .content, at: Date = t0, title: String = "main.js — api — Visual Studio Code",
                   text: String? = nil, url: String? = nil, hint: String? = "api") -> ObservationEvent {
            ObservationEvent(at: at, sessionID: nil, kind: kind, bundleID: app.id, appName: app.name, windowTitle: title, url: url, projectHint: hint, text: text)
        }
        func submit(_ e: FlowEngine, _ ev: ObservationEvent) -> MemoryKernel.IngestResult {
            e.noteActivated(ev.bundleID)
            guard let t = e.ticket(for: ev.bundleID) else { return .rejected("no ticket") }
            return e.submit(ev, ticket: t)
        }
        func kept(_ r: MemoryKernel.IngestResult) -> Bool { if case .kept = r { return true }; return false }

        // MARK: Permissions
        section("Flow: session and app permissions")
        do {
            var clock = t0
            let e = FlowEngine(directory: dir(), now: { clock })
            check(e.state == .off && e.decision(for: vs.id) == .deny(.sessionOff), "a session is off until started, and nothing is observable")
            e.start()
            e.noteActivated(vs.id)
            check(e.decision(for: vs.id) == .ask, "an app nobody decided on is asked about (only its identity was looked at)")
            check(e.ticket(for: vs.id) == nil, "no read is allowed while the question is open")
            check(e.decision(for: nil) == .deny(.noIdentity), "an app without a bundle identifier is never observed")

            e.setAccess(.denied, bundleID: msgs.id, name: msgs.name)
            let r = submit(e, event(msgs, title: "Messages — Sam", text: "Error: dinner plans failed, card 4242 4242 4242 4242", hint: nil))
            check(!kept(r) && e.kernel.records.isEmpty && e.kernel.immediate.events.isEmpty, "a denied app produces no observations and no records")
            e.setAccess(.always, bundleID: "com.1password.1password", name: "1Password")
            e.noteActivated("com.1password.1password")
            check(e.decision(for: "com.1password.1password") == .deny(.neverObserved), "password managers are never observed, even if allowed")

            e.setAccess(.once, bundleID: vs.id, name: vs.name)
            check(e.ticket(for: vs.id) != nil, "Allow once permits reading during this activation")
            e.noteDeactivated(vs.id)
            e.noteActivated(vs.id)
            check(e.decision(for: vs.id) == .ask, "Allow once ends when you leave the app")

            e.setAccess(.session, bundleID: vs.id, name: vs.name)
            let ticket = e.ticket(for: vs.id)
            e.pause()
            check(e.ticket(for: vs.id) == nil, "pausing stops new reads at once")
            check(ticket.map { !kept(e.submit(event(vs, text: "Error: late result"), ticket: $0)) } ?? false,
                  "a read that finishes after Pause is thrown away")
            e.resume()
            check(kept(submit(e, event(vs, text: "Error: connect ECONNREFUSED 127.0.0.1:5432"))), "after Resume, an allowed app is observed again")

            let t2 = e.ticket(for: vs.id)!
            _ = submit(e, event(vs, at: t0.addingTimeInterval(5), title: "other.js — api — Visual Studio Code", text: "TypeError: x is undefined"))
            e.revoke(bundleID: vs.id)
            check(!kept(e.submit(event(vs, text: "Error: after revoke"), ticket: t2)), "revoking access rejects reads already in flight")
            check(!e.kernel.immediate.events.contains { $0.bundleID == vs.id }, "revoking access drops that app's unprocessed observations")
            check(e.decision(for: vs.id) == .ask, "after revoking, the app is asked about again")

            e.setAccess(.session, bundleID: safari.id, name: safari.name)
            e.setAccess(.always, bundleID: "com.apple.Terminal", name: "Terminal")
            e.end()
            e.start()
            e.noteActivated(safari.id)
            e.noteActivated("com.apple.Terminal")
            check(e.decision(for: safari.id) == .ask, "a this-session grant ends with the session")
            clock = clock.addingTimeInterval(60)
            let reopened = FlowEngine(directory: e.store.url!.deletingLastPathComponent(), now: { clock })
            reopened.start()
            reopened.noteActivated("com.apple.Terminal")
            reopened.noteActivated(msgs.id)
            check(reopened.decision(for: "com.apple.Terminal") == .observe && reopened.decision(for: msgs.id) == .deny(.userDenied),
                  "Always allow and Don't allow survive a restart; nothing else does")
            check(reopened.state == .active, "(sanity) restarted engine can start a session")
        }

        // MARK: Privacy in content
        section("Flow: privacy inside allowed apps")
        do {
            let e = FlowEngine(directory: dir(), now: { t0 })
            e.start(); e.noteActivated(vs.id)
            e.setAccess(.session, bundleID: vs.id, name: vs.name)
            _ = submit(e, event(vs, text: """
                $ export DATABASE_URL=postgres://app:hunter2secret@db:5432/x
                Error: auth failed for token=sk-ant-abcdefghijklmnopqrstuvwx and card 4111 1111 1111 1111
                """))
            e.save(force: true, sync: true)
            let disk = (try? String(contentsOf: e.store.url!, encoding: .utf8)) ?? ""
            check(!disk.contains("hunter2secret") && !disk.contains("sk-ant-abc") && !disk.contains("4111 1111"),
                  "passwords, API keys and card numbers are redacted before anything is stored")
            check(disk.contains("auth failed"), "(sanity) the rest of the error is kept")
            check(!kept(submit(e, event(vs, title: "Private Browsing — Safari", text: "Error: x"))), "private-browsing and password windows are not recorded")
            let raw = "line one\nsome ordinary sentence about lunch\n" + String(repeating: "lorem ipsum ", count: 500)
            _ = submit(e, event(vs, at: t0.addingTimeInterval(1), title: "notes.txt — api — Visual Studio Code", text: raw))
            check(!e.kernel.records.contains { $0.text.contains("lunch") } && !((try? String(contentsOf: e.store.url!, encoding: .utf8)) ?? "").contains("lunch"),
                  "ordinary window text is not kept: only error lines and shell commands are")
        }

        // MARK: Memory
        section("Flow: memory kernel")
        do {
            var clock = t0
            let d = dir()
            let e = FlowEngine(directory: d, now: { clock })
            let rep = FlowDemo.play(into: e, start: t0)
            clock = t0.addingTimeInterval(40 * 60)
            check(rep.duplicates >= 39, "thirty minutes in one file folds into one observation (\(rep.duplicates) repeats folded)")
            let tasks = e.kernel.tasks
            let api = tasks.first { $0.projectKeys.contains("proj:taskboard-api") }
            let blog = tasks.first { $0.projectKeys.contains("proj:blog") }
            check(api != nil && blog != nil && api?.id != blog?.id, "two projects stay two separate tasks")
            check(!(api?.sources ?? []).contains { $0.title.contains("Elden Ring") }, "unrelated browsing isn't attached to the task")
            check((api?.sources ?? []).contains { $0.title.contains("PostgreSQL") }, "the related documentation page is attached as a source")
            check((api?.sources ?? []).allSatisfy { !($0.location ?? "").contains("token=") }, "page addresses are stored without query strings")
            let recs = api.map { e.kernel.records(for: $0.id) } ?? []
            let err = recs.first { $0.kind == .error && $0.text.contains("ECONNREFUSED") }
            check(err?.occurrences == 3 && err?.provenance == .observed, "a repeated error is one record seen 3 times, marked observed")
            check(err?.evidence.first?.appName == vs.name && err?.evidence.first?.excerpt?.contains("ECONNREFUSED") == true,
                  "each record points back to where it was seen")
            check(recs.contains { $0.kind == .attempt && $0.text.contains("brew services restart") && $0.provenance == .observed },
                  "a fix-like shell command is recorded as an observed attempt")
            let rule = recs.first { $0.kind == .instruction }
            check(rule?.text == "Don't change the production DATABASE_URL" && rule?.pinned == true && rule?.provenance == .userStated,
                  "an instruction is kept word for word, pinned, as the user's own words")
            check(api?.titleProvenance == .inferred, "a task title Shapr made up is marked inferred")
            check(!e.kernel.records.contains { $0.apps.contains(msgs.id) }, "nothing from the blocked app is in memory")

            let goodTask = api!.id
            check(e.kernel.records(for: blog!.id).allSatisfy { !$0.text.contains("ECONNREFUSED") }, "records don't leak between tasks")

            // Budgets
            for i in 0..<400 {
                _ = submit(e, event(vs, at: clock.addingTimeInterval(Double(i)), title: "db.js — taskboard-api — Visual Studio Code",
                                    text: "Error: unique failure number \(String(UnicodeScalar(65 + i % 26)!))\(i) in module m\(i)", hint: "taskboard-api"))
            }
            e.kernel.consolidate()
            let perTask = e.kernel.records(for: goodTask, includeSuperseded: true)
            let p = e.kernel.policy
            check(perTask.count <= p.maxRecordsPerTask && perTask.filter { $0.kind == .error }.count <= p.maxRecordsPerKind,
                  "working memory stays within its budget (\(perTask.count) records after 400 distinct errors)")
            check(e.kernel.immediate.events.count <= p.immediateMaxEvents && e.kernel.immediate.bytes <= p.immediateMaxBytes,
                  "immediate memory stays within its event and byte budget")
            check(perTask.contains { $0.text == "Don't change the production DATABASE_URL" }, "pinned memory survives compaction")
            clock = clock.addingTimeInterval(p.immediateTTL + 600)
            e.kernel.consolidate()
            check(e.kernel.immediate.events.isEmpty, "temporary observations expire on their own")

            // Episodes and restart
            e.end()
            check(e.kernel.immediate.events.isEmpty && e.kernel.tasks.allSatisfy { $0.status != .active }, "ending a session drops temporary memory and pauses tasks")
            clock = clock.addingTimeInterval(18 * 3600)
            let again = FlowEngine(directory: d, now: { clock })
            check(again.kernel.tasks.count == e.kernel.tasks.count && !again.kernel.episodes.isEmpty, "working memory and episodes survive a restart")
            let resume = again.resumeCandidate()
            check(resume?.task.id == goodTask, "Continue offers the task you were last on")
            let text = resume?.resume.map(\.text).joined(separator: "\n") ?? ""
            check(text.contains("next step was to check which port"), "the stated next step is offered back")
            check(!text.lowercased().contains("fixed the") && !text.lowercased().contains("resolved"), "Continue never claims the problem was solved")

            // Deletion invalidates derived data
            let before = again.kernel.records.count
            let report = again.deleteData(fromApp: safari.id)
            check(again.kernel.tasks.allSatisfy { $0.sources.allSatisfy { $0.bundleID != safari.id } } && report.sources > 0,
                  "deleting an app's data removes its sources")
            check(again.kernel.tasks.allSatisfy { !$0.keywords.keys.contains("stackoverflow") && !$0.keywords.keys.contains("libpq") },
                  "…and its words from the task index, so it can't come back in a match or summary")
            check(again.kernel.records.count <= before, "(sanity) nothing was added by deleting")
            let r2 = again.deleteData(fromApp: vs.id)
            let left = again.kernel.records.filter { r in r.evidence.contains { $0.bundleID == vs.id } }
            let epLeft = again.kernel.episodes.flatMap(\.records).filter { r in r.evidence.contains { $0.bundleID == vs.id } }
            check(left.isEmpty && epLeft.isEmpty && r2.records > 0, "deleting an app's data removes it from working memory and episodes")
            check(again.kernel.tasks.first { $0.id == goodTask }?.title == "Untitled task", "a title inferred from deleted data is reset")
            let ctx = again.context(for: "ECONNREFUSED 5432")
            check(!ctx.rendered(includeRequest: false).contains("ECONNREFUSED"), "deleted observations never reappear in AI context")
            check(ctx.items.contains { $0.record.kind == .instruction }, "the user's own words (not from that app) are kept")
            let files = again.deleteTask(goodTask)
            check(again.kernel.task(goodTask) == nil && !again.kernel.episodes.contains { $0.taskID == goodTask } && files.isEmpty,
                  "deleting a task removes its records and episodes")
            let disk = (try? String(contentsOf: again.store.url!, encoding: .utf8)) ?? ""
            check(!disk.contains(goodTask.uuidString), "…including from the stored file")
        }

        // MARK: Inference
        section("Flow: inference stays honest")
        do {
            let e = FlowEngine(directory: dir(), now: { t0 })
            e.start()
            for a in [vs, safari] { e.noteActivated(a.id); e.setAccess(.session, bundleID: a.id, name: a.name) }
            _ = submit(e, event(vs, title: "server.ts — billing — Visual Studio Code", text: "Error: Stripe webhook signature verification failed", hint: "billing"))
            let r = submit(e, event(safari, .focus, at: t0.addingTimeInterval(5 * 60), title: "Billing FAQ – Example Corp", url: "https://example.com/billing-faq", hint: nil))
            check(e.kernel.pendingQuestion != nil && e.kernel.activeTask?.sources.isEmpty == true,
                  "a page that only loosely matches is asked about, not merged")
            _ = r
            e.answer(.separateTask)
            check(e.kernel.tasks.count == 2, "answering “Separate task” makes a new task")
            let s = e.summary(for: e.kernel.tasks[0].id)
            let txt = s?.resume.map(\.text).joined(separator: " ") ?? ""
            check(!txt.contains("Next step") && !txt.contains("Goal:"), "no goal or next step is invented when none was stated")
            _ = submit(e, event(vs, at: t0.addingTimeInterval(30 * 60), title: "server.ts — billing — Visual Studio Code",
                                text: "We decided to use MySQL instead\nThe docs say: always retry webhooks", hint: "billing"))
            check(!e.kernel.records.contains { $0.kind == .decision || $0.kind == .instruction },
                  "text quoted on screen is never turned into the user's decision or rule")
            let k = e.kernel
            let tid = k.tasks[0].id
            k.upsert(taskID: tid, kind: .note, text: "Maybe the webhook secret rotated last week in production", provenance: .hypothesis, evidence: nil)
            k.upsert(taskID: tid, kind: .note, text: "The webhook secret rotated last week in production", provenance: .observed, evidence: nil)
            k.consolidate()
            let notes = k.records(for: tid).filter { $0.kind == .note }
            check(notes.count == 2 && notes.contains { $0.provenance == .hypothesis }, "consolidation never merges a guess into a fact")
            k.confirm(recordID: notes.first { $0.provenance == .hypothesis }!.id)
            check(k.records(for: tid).contains { $0.provenance == .userConfirmed }, "only the user's confirmation upgrades a guess")
            check(Provenance.hypothesis < .inferred && Provenance.inferred < .observed && Provenance.observed < .userConfirmed, "(sanity) provenance order")
        }

        // MARK: Retrieval
        section("Flow: retrieval")
        do {
            var clock = t0
            let e = FlowEngine(directory: dir(), now: { clock })
            FlowDemo.play(into: e, start: t0)
            clock = t0.addingTimeInterval(40 * 60)
            let q = "Error: connect ECONNREFUSED 127.0.0.1:5432"
            let started = DispatchTime.now()
            let ctx = e.context(for: q, budget: 1500)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
            let out = ctx.rendered(now: clock)
            check(out.contains("brew services restart"), "Lens context recovers the earlier attempt")
            check(out.contains("Don't change the production DATABASE_URL"), "…and keeps the user's rule word for word")
            check(!out.contains("hugo") && !out.contains("Elden"), "…and leaves out unrelated work")
            check(out.count <= 1500 + 400, "…within its context budget (\(out.count) characters for a 1500 budget)")
            check(out.contains("(error") && out.contains("observed"), "every item says how Shapr knows it")
            check(ms < 50, String(format: "retrieval is fast (%.2f ms)", ms))
            if let rule = ctx.items.first(where: { $0.record.kind == .instruction }) {
                e.edit { $0.supersede(recordID: rule.record.id) }
                check(!e.context(for: q).rendered().contains("production DATABASE_URL"), "superseded memory is left out")
            }
            e.setAccess(.denied, bundleID: safari.id, name: safari.name)
            e.kernel.upsert(taskID: e.activeTask?.id, kind: .note, text: "Postgres docs say check listen_addresses", provenance: .observed,
                            evidence: EvidenceRef(kind: .page, bundleID: safari.id, appName: "Safari", at: clock))
            check(!e.context(for: "postgres listen_addresses").rendered(includeRequest: false).contains("listen_addresses"),
                  "memory from an app that was blocked later is excluded from context")
        }

        // MARK: Simulate and suggestions
        section("Flow: Simulate and suggestions")
        do {
            var clock = t0
            let d = dir()
            let e = FlowEngine(directory: d, now: { clock })
            FlowDemo.play(into: e, start: t0)
            clock = t0.addingTimeInterval(40 * 60)
            let cmp = e.compare(selection: "DATABASE_URL", paths: ["Change the production DATABASE_URL to the new server",
                                                                  "Keep local Postgres and fix the port it listens on"])
            check(cmp.paths[0].possibleTensions.contains { $0.record.kind == .instruction }, "Simulate flags a path that goes against your rule")
            check(!cmp.paths[1].questions.isEmpty || !cmp.paths[1].triedBefore.isEmpty, "Simulate links the other path to stored evidence")
            var links: [ScenarioLink] = []
            for p in cmp.paths { links += p.consistentWith; links += p.possibleTensions; links += p.triedBefore; links += p.questions }
            let all: String = links.map(\.why).joined() + cmp.paths.flatMap(\.assumptions).joined()
            check(all.range(of: #"\d+\s?%|probabilit|likely to succeed|will work"#, options: .regularExpression) == nil,
                  "Simulate shows no made-up probabilities or certainty")
            let empty = ScenarioExplorer.compare(selection: "x", paths: ["Rewrite it in Rust"], records: [])
            check(empty.paths[0].assumptions.contains { $0.contains("nothing saved") }, "a path with no evidence says so")

            e.settings.assistance = .quiet
            e.end()
            clock = clock.addingTimeInterval(24 * 3600)
            let next = FlowEngine(directory: d, now: { clock })
            var got: [Suggestion] = []
            next.onSuggestion = { got.append($0) }
            next.start()
            next.noteActivated(vs.id); next.setAccess(.session, bundleID: vs.id, name: vs.name)
            _ = submit(next, event(vs, at: clock, title: "db.js — taskboard-api — Visual Studio Code", text: "Error: connect ECONNREFUSED 127.0.0.1:5432", hint: "taskboard-api"))
            check(got.isEmpty, "Quiet mode never interrupts")
            next.settings.assistance = .balanced
            clock = clock.addingTimeInterval(60)
            _ = submit(next, event(vs, at: clock, title: "server.js — taskboard-api — Visual Studio Code", text: "Error: connect ECONNREFUSED 127.0.0.1:5432", hint: "taskboard-api"))
            check(got.count == 1 && got[0].detail.contains("brew services restart"), "Balanced: a returning error brings back what you tried, once")
            clock = clock.addingTimeInterval(120)
            _ = submit(next, event(vs, at: clock, title: "index.js — taskboard-api — Visual Studio Code", text: "Error: connect ECONNREFUSED 127.0.0.1:5432", hint: "taskboard-api"))
            check(got.count == 1, "…and doesn't repeat itself")
        }

        // MARK: Robustness and resources
        section("Flow: robustness and resources")
        do {
            let d = dir()
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try? Data("{ not json".utf8).write(to: d.appendingPathComponent("memory.json"))
            let e = FlowEngine(directory: d, now: { t0 })
            check(e.kernel.tasks.isEmpty && e.loadProblem != nil && FileManager.default.fileExists(atPath: d.appendingPathComponent("memory.unreadable.json").path),
                  "unreadable memory is set aside, not lost or overwritten, and Flow starts fresh")
            var future = FlowSnapshot(); future.schema = FlowSchema.version + 1
            try? JSONEncoder.flow.encode(future).write(to: d.appendingPathComponent("memory.json"))
            let e2 = FlowEngine(directory: d, now: { t0 })
            check(e2.kernel.tasks.isEmpty && e2.loadProblem?.contains("newer") == true, "memory from a newer version is never overwritten")

            var clock = t0
            let perf = FlowEngine(directory: dir(), now: { clock })
            perf.start()
            perf.noteActivated(vs.id); perf.setAccess(.session, bundleID: vs.id, name: vs.name)
            let started = DispatchTime.now()
            let count = 5000
            for i in 0..<count {
                clock = t0.addingTimeInterval(Double(i) * 2)
                let text = i % 5 == 0 ? "Error: request \(i % 50) failed with status 500 internal server error" : nil
                _ = submit(perf, event(vs, i % 5 == 0 ? .content : .focus, at: clock,
                                       title: "file\(i % 30).swift — api — Visual Studio Code", text: text))
            }
            let total = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
            let ingest = perf.metrics.timing("ingest")
            let cons = perf.metrics.timing("consolidate")
            perf.save(force: true, sync: true)
            check(total / Double(count) < 2.0, String(format: "processing an observation is cheap (%.3f ms average over %d, incl. permission checks)", total / Double(count), count))
            check((cons?.p95Ms ?? 0) < 100, String(format: "consolidation is quick (p95 %.2f ms over %d runs)", cons?.p95Ms ?? 0, cons?.count ?? 0))
            check(perf.storedBytes < perf.kernel.policy.maxStoredBytes, "stored memory stays under budget after \(count) observations (\(perf.storedBytes) bytes)")
            _ = ingest

            // Disk growth over many sessions
            let d3 = dir()
            var c3 = t0
            var sizes: [Int] = []
            for s in 0..<12 {
                let eng = FlowEngine(directory: d3, now: { c3 })
                eng.start()
                eng.noteActivated(vs.id); eng.setAccess(.session, bundleID: vs.id, name: vs.name)
                for i in 0..<150 {
                    c3 = c3.addingTimeInterval(30)
                    _ = submit(eng, event(vs, at: c3, title: "s\(s)f\(i % 10).swift — proj\(s % 4) — Visual Studio Code",
                                          text: "Error: failure \(s)-\(i) in step \(i)", hint: "proj\(s % 4)"))
                }
                eng.end()
                sizes.append(eng.storedBytes)
                c3 = c3.addingTimeInterval(3600 * 20)
            }
            check(sizes.max()! < MemoryPolicy().maxStoredBytes && sizes.last! < sizes.max()! * 2,
                  "disk use stays bounded over 12 sessions (largest \(sizes.max()!) bytes, last \(sizes.last!))")
        }
    }
}
