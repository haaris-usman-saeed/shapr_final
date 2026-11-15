import AppKit
import Carbon
import SwiftUI

/// ⌥⇧Space: one shortcut that shows what you can do right now, beside the pointer.
/// Text selected → use it with your pack, or scoop it. In a text box → draft here. Saved progress → continue.
/// Every row shows its own shortcut, so the panel teaches the faster way without anything to memorize.
struct QuickItem: Identifiable {
    let id: String
    let symbol: String
    let title: String
    var subtitle: String?
    var keys: String?
    let run: () -> Void
}

@MainActor
final class QuickModel: ObservableObject {
    @Published var items: [QuickItem] = []
    @Published var selected = 0
    @Published var pack: Pack?
    @Published var context = ""
    /// Type to filter, Maccy-style.
    @Published var query = "" { didSet { selected = 0 } }
    @Published var opened = 0

    /// The actions that match what you typed.
    var shown: [QuickItem] {
        guard let q = query.nonEmpty?.lowercased() else { return items }
        return items.filter { $0.title.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) ?? false) }
    }
}

/// Maccy-style: a small search field that's ready for typing, a compact list where the selected row
/// takes the accent, number keys on the right, and the selected action's detail at the bottom.
struct QuickView: View {
    @ObservedObject var model: QuickModel
    var onRun: (Int) -> Void = { _ in }
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 320
    /// Concentric corners: rows (7) inside 5 pt of padding make the panel's 12.
    private static let rowRadius: CGFloat = 7
    private static let padding: CGFloat = 5

    var body: some View {
        let shown = model.shown
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.text3)
                TextField("Search actions", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onSubmit { onRun(model.selected) }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(DS.text3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                } else if let p = model.pack {
                    PackChip(pack: p)
                }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Self.rowRadius, style: .continuous).fill(.quinary))
            .padding(Self.padding)

            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                    Button { onRun(i) } label: { row(item, index: i) }
                        .buttonStyle(.plain)
                        .onHover { if $0 { model.selected = i } }
                        .accessibilityLabel(item.title + (item.subtitle.map { ", " + $0 } ?? ""))
                }
                if shown.isEmpty {
                    Text("No matching action. Hold ⌥V and say it instead.")
                        .font(.dsMeta).foregroundStyle(DS.text3)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                }
            }
            .padding(.horizontal, Self.padding)

            Divider().padding(.horizontal, 6).padding(.top, Self.padding)
            // The selected action's detail, instead of a subtitle on every row.
            Text(detail(shown))
                .font(.dsMeta).foregroundStyle(DS.text2).lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 7)
        }
        .frame(width: Self.width)
        .glassSurface(RoundedRectangle(cornerRadius: Self.rowRadius + Self.padding, style: .continuous))
        .padding(1)
        .onAppear { searchFocused = true }
        .onChange(of: model.opened) { _, _ in searchFocused = true }
    }

    /// "The selection, or this page · ⌥C": what the selected action does, and its own shortcut.
    private func detail(_ shown: [QuickItem]) -> String {
        guard shown.indices.contains(model.selected) else { return "Return to run · ⌥V to say it" }
        let item = shown[model.selected]
        return [item.subtitle, item.keys].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Return to run"
    }

    private func row(_ item: QuickItem, index i: Int) -> some View {
        let on = model.selected == i
        return HStack(spacing: 9) {
            Image(systemName: item.symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(on ? Color.white : DS.text2)
                .frame(width: 18)
            Text(item.title).font(.system(size: 13)).foregroundStyle(on ? Color.white : DS.text).lineLimit(1)
            Spacer(minLength: 6)
            if i < 9 {
                Text("\(i + 1)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(Color.secondary.opacity(on ? 0.5 : 0.75)))
            }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: Self.rowRadius, style: .continuous).fill(on ? AnyShapeStyle(DS.accentFill.opacity(0.9)) : AnyShapeStyle(Color.clear)))
        .contentShape(Rectangle())
    }
}

@MainActor
final class QuickPanelController {
    private let model = QuickModel()
    private let panel = FloatingPanel(size: NSSize(width: QuickView.width, height: 300), level: .popUpMenu)
    private var monitors: [Any] = []

    var isVisible: Bool { panel.isVisible }

    init() {
        panel.contentView = FirstMouseHostingView(rootView: QuickView(model: model) { [weak self] i in
            MainActor.assumeIsolated { self?.run(i) }
        })
    }

    /// Shows the panel beside the pointer right away (no waiting on AI or the network).
    func show(pack: Pack?, context: String, items: [QuickItem]) {
        if isVisible { hide(); return }
        model.pack = pack
        model.context = context
        model.items = items
        model.query = ""
        model.selected = 0
        model.opened += 1
        let host = panel.contentView!
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let m = NSEvent.mouseLocation
        var origin = CGPoint(x: m.x + 14, y: m.y - size.height - 10)
        if let vf = NSScreen.underMouse?.visibleFrame {
            if origin.x + size.width > vf.maxX { origin.x = m.x - size.width - 14 }
            if origin.y < vf.minY { origin.y = m.y + 14 }
            origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
            origin.y = min(max(origin.y, vf.minY + 4), vf.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.allowsKey = true
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        installMonitors()
    }

    func hide() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.allowsKey = false
        panel.orderOut(nil)
    }

    private func run(_ i: Int) {
        let shown = model.shown
        guard shown.indices.contains(i) else { return }
        let action = shown[i].run
        hide()
        // Let the app you were in become key again before acting on it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { action() }
    }

    private func installMonitors() {
        let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            MainActor.assumeIsolated { self?.key(e) == true ? nil : e }
        }
        let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        monitors = [keys, outside].compactMap { $0 }
    }

    private func key(_ e: NSEvent) -> Bool {
        switch Int(e.keyCode) {
        case kVK_Escape: hide()
        case kVK_DownArrow, kVK_Tab: model.selected = (model.selected + 1) % max(model.shown.count, 1)
        case kVK_UpArrow: model.selected = (model.selected - 1 + model.shown.count) % max(model.shown.count, 1)
        case kVK_Return, kVK_ANSI_KeypadEnter: run(model.selected)
        default:
            // Number keys run a row only while the search is empty; otherwise they're typing.
            if model.query.isEmpty, let c = e.charactersIgnoringModifiers, let n = Int(c), n >= 1, n <= model.shown.count { run(n - 1) }
            else { return false }
        }
        return true
    }
}
