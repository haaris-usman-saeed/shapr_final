import AppKit
import SwiftUI

/// One Safe Share review. Edits only the shared copy; the pack on disk never changes.
@MainActor
final class ShareSession: ObservableObject {
    let packID: UUID
    let packName: String
    let captures: [Capture]
    let newCaptureIDs: Set<UUID>

    @Published var flags: [PrivacyFlag]
    @Published var excluded: Set<UUID>
    @Published var includeSources = true
    @Published var includeTimes = false
    @Published var includeApps = false
    /// Screenshots can't be redacted, so they stay out unless you turn this on.
    @Published var includeImages = false
    var hasImages: Bool { captures.contains { $0.image != nil || $0.file != nil } }

    init(pack: Pack, rules: RedactionRules) {
        packID = pack.id
        packName = pack.name
        captures = pack.captures
        excluded = rules.excludedCaptures.intersection(pack.captures.map(\.id))
        newCaptureIDs = rules.reviewedCaptures.isEmpty ? [] : Set(pack.captures.map(\.id)).subtracting(rules.reviewedCaptures)
        flags = PrivacyScanner.scan(pack.captures, rules: rules)
    }

    /// The captures as your friend gets them: excluded ones dropped, flags applied,
    /// and app names, times and links removed when those switches are off.
    func sharedCaptures(now: Date = Date()) -> [Capture] {
        captures.filter { !excluded.contains($0.id) }.enumerated().map { i, c in
            var out = PrivacyScanner.apply(flags, to: c)
            out.bundleID = nil
            if !includeImages { out.image = nil; out.file = nil }
            if !includeApps { out.appName = nil }
            if !includeSources { out.url = nil }
            if !includeTimes { out.capturedAt = now.addingTimeInterval(Double(i) * 0.001) }
            return out
        }
    }

    var output: String {
        let kept = captures.filter { !excluded.contains($0.id) }.map { PrivacyScanner.apply(flags, to: $0) }
        return Exporter.markdown(packName: packName, captures: kept,
                                 options: .init(includeSources: includeSources, includeTimes: includeTimes,
                                                includeApps: includeApps),
                                 footnote: "shared copy, checked for private info")
    }

    var hiddenCount: Int { flags.filter { $0.action != .keep }.count }

    func rules() -> RedactionRules {
        var r = RedactionRules()
        for f in flags { r.rules[f.ruleKey] = .init(action: f.action, replacement: f.replacement) }
        r.excludedCaptures = excluded
        r.reviewedCaptures = Set(captures.map(\.id))
        return r
    }
}

struct ShareReviewView: View {
    @ObservedObject var session: ShareSession
    /// The pack's live link, if it's already shared that way.
    var liveLink: URL? = nil
    var onLiveLink: () -> Void = {}
    var onCopy: () -> Void = {}
    var onSave: () -> Void = {}
    var onSaveBundle: () -> Void = {}

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                banner
                List {
                    ForEach(session.captures) { c in
                        Section {
                            captureSection(c)
                        } header: {
                            captureHeader(c)
                        }
                    }
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 480, idealWidth: 560)

            VStack(alignment: .leading, spacing: 10) {
                Text("What your friend gets").font(.headline)
                ScrollView {
                    Text(session.output)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

                Toggle("Include source links", isOn: $session.includeSources)
                Toggle("Include capture times", isOn: $session.includeTimes)
                Toggle("Include app names", isOn: $session.includeApps)
                if session.hasImages {
                    Toggle("Include screenshots and files in the .shapr file", isOn: $session.includeImages)
                    if session.includeImages {
                        Label("Screenshots and files aren't checked. Only their text is. Look at them before sharing.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(DS.warning)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button(action: onLiveLink) {
                        Label(liveLink == nil ? "Create live link" : "Update live link", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.dsPrimary)
                    .keyboardShortcut(.defaultAction)
                    .help("Anyone with the link can see this shared copy and add it to Shapr")
                    Text(liveLink == nil
                         ? "Anyone with the link can view the pack and add it to their Shapr. New captures are shared as you add them; anything that looks private waits for you here first."
                         : "Shared at \(liveLink!.absoluteString). Your choices here apply to everything shared from now on.")
                        .font(.dsMeta).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Copy text") { onCopy() }
                        Spacer()
                        Button("Save .md…") { onSave() }
                            .help("A Markdown file anyone can open")
                        Button("Save .shapr…") { onSaveBundle() }
                            .help("A pack file: your friend double-clicks it and it appears in their Shapr")
                    }
                    .buttonStyle(DSButtonStyle(kind: .secondary, small: true))
                }
            }
            .padding(16)
            .frame(minWidth: 360, idealWidth: 420)
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill").font(.title2).foregroundStyle(DS.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.flags.isEmpty ? "Nothing private found in “\(session.packName)”"
                                           : "\(session.flags.count) thing\(session.flags.count == 1 ? "" : "s") that might be private")
                    .font(.headline)
                Text("Choices here change only the shared copy. Your own pack stays exactly as it is. Shapr checks on this Mac; nothing is uploaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    private func captureHeader(_ c: Capture) -> some View {
        HStack {
            Text(c.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
            if session.newCaptureIDs.contains(c.id) {
                Text("NEW")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(DS.accent.opacity(0.25)))
            }
            Spacer()
            Toggle("Include", isOn: Binding(
                get: { !session.excluded.contains(c.id) },
                set: { on in if on { session.excluded.remove(c.id) } else { session.excluded.insert(c.id) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }

    @ViewBuilder
    private func captureSection(_ c: Capture) -> some View {
        let indices = session.flags.indices.filter { session.flags[$0].captureID == c.id }
        if session.excluded.contains(c.id) {
            Text("Left out of the shared copy").font(.callout).foregroundStyle(.secondary)
        } else if indices.isEmpty {
            Label("Nothing flagged", systemImage: "checkmark").font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(indices, id: \.self) { i in
                FlagRow(flag: $session.flags[i])
            }
        }
    }
}

private struct FlagRow: View {
    @Binding var flag: PrivacyFlag

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(flag.kind.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(color.opacity(0.2)))
                    .foregroundStyle(color)
                Text(flag.match.singleLine.truncated(60))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if flag.remembered {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                        .help("Using your choice from the last time you shared this pack")
                }
                Spacer()
                Picker("", selection: $flag.action) {
                    ForEach(RedactAction.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }
            if flag.field == .text || flag.field == .title {
                Text(flag.context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if flag.action == .replace {
                HStack {
                    Text("Replace with").font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $flag.replacement)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var color: Color {
        switch flag.kind {
        case .secret, .card: return .red
        case .email, .phone, .address, .ipAddress: return .orange
        case .person: return .purple
        case .organization, .place: return .blue
        case .secretURL, .internalURL: return .teal
        }
    }
}
