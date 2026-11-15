import AppKit

/// `Shapr --share-smoke http://localhost:8787`: shares a pack from one throwaway library, joins it
/// from another, and checks live updates end to end against a running share server
/// (cd server && node dev.mjs). Never touches ~/Shapr or your Keychain.
@MainActor
enum ShareSmoke {
    private static var failures = 0
    private static func check(_ ok: Bool, _ what: String) {
        print("  \(ok ? "PASS" : "FAIL") \(what)")
        if !ok { failures += 1 }
    }

    static func run(server: URL) async -> Int32 {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("shapr-share-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        func library(_ name: String) -> (PackStore, SharedPacks) {
            let suite = "app.shapr.smoke.\(name)"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            let store = PackStore(root: tmp.appendingPathComponent(name), defaults: UserDefaults(suiteName: suite)!)
            let shared = SharedPacks(store: store, client: ShareClient(base: server))
            var memory: [String: String] = [:]
            shared.tokens = (get: { memory[$0] }, set: { memory[$0] = $1 })
            return (store, shared)
        }
        let (mine, myShares) = library("sharer")
        let (theirs, theirShares) = library("friend")
        var heldCount = 0
        myShares.onHeld = { _, n in heldCount += n }

        print("Share a pack")
        let pack = mine.createPack(name: "MAT223", emoji: "📘", autoNamed: false)
        mine.add(CaptureDraft(text: "Eigenvalues are the roots of the characteristic polynomial.", title: "Lecture 5",
                              url: "https://q.utoronto.ca/courses/1/pages/lecture-5"), to: pack.id)
        mine.add(CaptureDraft(text: "Diagonal matrix", title: "Board photo",
                              imageData: ScreenCapture.png(SelfTest.textImage("A = PDP⁻¹"))), to: pack.id)
        mine.add(CaptureDraft(text: "Ask the TA at jane.doe@mail.utoronto.ca about question 4.", title: "Office hours"), to: pack.id)
        let session = ShareSession(pack: mine.pack(pack.id)!, rules: RedactionRules())
        session.includeImages = true
        let link: URL
        do { link = try await myShares.share(session) } catch {
            print("  FAIL couldn't share: \(error.localizedDescription). Is the server running at \(server)?")
            return 1
        }
        check(link.path.hasPrefix("/p/"), "sharing gives a link")

        print("Join it")
        let joined: Pack
        do { joined = try await theirShares.join(link.absoluteString) } catch {
            print("  FAIL couldn't join: \(error.localizedDescription)")
            return 1
        }
        let theirPack = { theirs.pack(joined.id)! }
        check(theirPack().name == "MAT223" && theirPack().captures.count == 3, "a friend's Mac gets the pack with all 3 captures")
        check(theirPack().captures.contains { $0.image != nil }, "screenshots come along when you include them")
        check(!theirPack().captures.contains { $0.text.contains("jane.doe@") }, "the private email was hidden in the shared copy")
        check(mine.pack(pack.id)!.captures.contains { $0.text.contains("jane.doe@") }, "your own pack keeps it")

        print("Live updates")
        mine.add(CaptureDraft(text: "Midterm covers chapters 1 to 5.", title: "Announcement"), to: pack.id)
        try? await myShares.publish(pack.id)
        try? await theirShares.sync(joined.id)
        check(theirPack().captures.count == 4, "a new capture shows up on your friend's Mac")
        mine.add(CaptureDraft(text: "Call me at 416-555-0199 if the midterm moves.", title: "Phone"), to: pack.id)
        try? await myShares.publish(pack.id)
        try? await theirShares.sync(joined.id)
        check(theirPack().captures.count == 4 && heldCount == 1, "a new capture with private info waits for your review instead")
        if let first = mine.pack(pack.id)?.captures.first { mine.removeCapture(first.id, toTrash: false) }
        try? await myShares.publish(pack.id)
        try? await theirShares.sync(joined.id)
        check(theirPack().captures.count == 3 && !theirPack().captures.contains { $0.title == "Lecture 5" },
              "deleting a capture removes it for your friend too")
        check((myShares.shared[pack.id]?.joins ?? 0) == 1, "you can see that 1 person joined")
        let again = try? await theirShares.join(link.absoluteString)
        check(again?.id == joined.id && theirs.packs.count == 1, "opening the link again doesn't make a second copy")

        print("Stop sharing")
        await myShares.stopSharing(pack.id)
        var gone = false
        do { try await theirShares.sync(joined.id) } catch { gone = error.localizedDescription.contains("isn't shared anymore") }
        check(gone && theirPack().captures.count == 3, "after you stop sharing, the link stops working and your friend keeps their copy")

        print(failures == 0 ? "\nAll sharing checks passed." : "\n\(failures) sharing check(s) failed.")
        return failures == 0 ? 0 : 1
    }
}
