import AppKit
import SwiftUI

/// Brand colors for the app icon only. Everything else uses `DS`.
enum Theme {
    static let indigo = Color(red: 0.36, green: 0.37, blue: 0.94)
    static let violet = Color(red: 0.58, green: 0.45, blue: 1.0)
    static let gradient = LinearGradient(colors: [violet, indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Borderless floating panel that never activates Shapr, so the app you're working in keeps focus.
/// Follows the system's light or dark appearance.
final class FloatingPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    init(size: NSSize, level: NSWindow.Level) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        self.level = level
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }
}

/// Lets the first click on a panel button work without activating the app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSScreen {
    static var underMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main
    }
}

// MARK: - Toast

struct ToastAction: Identifiable {
    enum Style { case primary, normal, menu([(String, () -> Void)]) }
    let id = UUID()
    let title: String
    var style: Style = .normal
    var run: () -> Void = {}
}

struct ToastContent {
    enum Icon { case emoji(String), symbol(String), spinner, pack(Pack) }
    var icon: Icon
    var title: String
    var subtitle: String?
    var actions: [ToastAction] = []
    var tint: Color = DS.accent
    /// Capture cards (Dropover-style): a thumbnail, "Added to <pack>", and an expandable preview.
    var preview: CapturePreview? = nil
    var pack: Pack? = nil
    var eyebrow: String? = nil
    var expandable = false
}

/// The small glass card in the top-right corner: what happened, where it went, and at most a couple
/// of actions. Screenshots lead with the picture; everything else leads with the pack's orb or a symbol.
struct ToastView: View {
    let content: ToastContent
    var onHover: (Bool) -> Void = { _ in }
    var onResize: () -> Void = {}
    @State private var expanded = false
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 340

    private var image: NSImage? {
        if case .image(let img)? = content.preview { return img }
        return nil
    }

    /// "Added to Cars", then the subtitle.
    private var metaLine: String? {
        let place = content.pack.map { "\(content.eyebrow ?? "Added to") \($0.name)" }
        let parts = [place, content.subtitle].compactMap { $0?.nonEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            // Screenshots lead with the picture itself, whole and unstretched.
            if let img = image {
                let natural = (Self.width - 28) * img.size.height / max(img.size.width, 1)
                FittedImage(image: img, height: expanded ? min(240, max(110, natural)) : min(96, max(64, natural)), corner: 14)
                    .accessibilityLabel("Screenshot preview")
            }
            HStack(alignment: .top, spacing: 11) {
                if image == nil { leading }
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(DS.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let m = metaLine {
                        Text(m)
                            .font(.system(size: 11.5))
                            .foregroundStyle(DS.text2)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if content.expandable, content.preview != nil {
                    IconButton(symbol: expanded ? "chevron.up" : "chevron.down", help: expanded ? "Show less" : "Show more", size: 22) {
                        withAnimation(DS.spring(reduceMotion)) { expanded.toggle() }
                        DispatchQueue.main.async { onResize() }
                    }
                }
            }
            if expanded, image == nil, let p = content.preview { expandedPreview(p) }
            if !content.actions.isEmpty {
                // One row when it fits, else two.
                ViewThatFits(in: .horizontal) {
                    actionRow
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) { ForEach(content.actions.prefix(2)) { a in ToastButton(action: a) } }
                        HStack(spacing: 6) { ForEach(content.actions.dropFirst(2)) { a in ToastButton(action: a) } }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(1)
        .scaleEffect(shown || reduceMotion ? 1 : 0.96, anchor: .topTrailing)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(DS.spring(reduceMotion) ?? .linear(duration: 0.01)) { shown = true } }
        .onHover(perform: onHover)
        .accessibilityElement(children: .contain)
    }

    private var actionRow: some View {
        HStack(spacing: 6) {
            ForEach(content.actions) { a in ToastButton(action: a) }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var leading: some View {
        switch content.preview {
        case .image(let img)?:
            ZStack {
                DS.well
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(3)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .accessibilityLabel("Screenshot thumbnail")
        case .file(_, let ext)?:
            FileBadge(ext: ext, size: 38).frame(width: 44, height: 44)
        case .quote?, nil:
            switch content.icon {
            case .pack(let p): PackIcon(pack: p, size: 32)
            case .spinner: ProgressView().controlSize(.small).frame(width: 32, height: 32)
            case .symbol(let s):
                if let p = content.pack, s == "tray" || s == "tray.full" { PackIcon(pack: p, size: 32) } else {
                    Image(systemName: s)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(content.tint)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(content.tint.opacity(0.14)))
                        .accessibilityHidden(true)
                }
            case .emoji:
                // Emoji aren't used any more: show the pack's orb, or a neutral mark.
                PackIcon(pack: content.pack, size: 32)
            }
        }
    }

    @ViewBuilder
    private func expandedPreview(_ p: CapturePreview) -> some View {
        switch p {
        case .image(let img):
            FittedImage(image: img, height: min(220, max(90, (Self.width - 28) * img.size.height / max(img.size.width, 1))), corner: 14)
        case .quote(let q):
            Text(q)
                .font(.dsCallout)
                .foregroundStyle(DS.text)
                .lineLimit(8)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.well))
        case .file(let name, let ext):
            Label("\(name) · \(ext.uppercased())", systemImage: CapturePreview.fileSymbol(ext))
                .font(.dsCallout)
                .foregroundStyle(DS.text)
        }
    }
}

private struct ToastButton: View {
    let action: ToastAction

    var body: some View {
        switch action.style {
        case .menu(let items):
            Menu {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button(item.0, action: item.1)
                }
            } label: {
                HStack(spacing: 3) {
                    Text(action.title)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }
            .menuStyle(.button)
            .buttonStyle(DSButtonStyle(kind: .secondary, small: true))
            .menuIndicator(.hidden)
            .fixedSize()
        case .primary:
            Button(action.title, action: action.run)
                .buttonStyle(DSButtonStyle(kind: .primary, small: true))
                .fixedSize()
        case .normal:
            Button(action.title, action: action.run)
                .buttonStyle(DSButtonStyle(kind: .secondary, small: true))
                .fixedSize()
        }
    }
}

@MainActor
final class ToastController {
    private let panel = FloatingPanel(size: NSSize(width: 340, height: 80), level: .statusBar)
    private var dismissWork: DispatchWorkItem?
    private var onTimeout: (() -> Void)?
    private var duration: TimeInterval?
    private var hovering = false
    private(set) var token = UUID()

    /// Shows a toast. `duration == nil` keeps it up until replaced.
    /// `onTimeout` runs only if the toast disappears on its own (not when a button was clicked).
    @discardableResult
    func show(_ content: ToastContent, duration: TimeInterval? = 4, onTimeout: (() -> Void)? = nil) -> UUID {
        let t = UUID()
        token = t
        self.onTimeout = onTimeout
        self.duration = duration

        // Wrap every button so clicking it also closes the toast.
        var c = content
        c.actions = content.actions.map { a in
            var a = a
            let run = a.run
            a.run = { [weak self] in self?.close(); run() }
            if case .menu(let items) = a.style {
                a.style = .menu(items.map { item in (item.0, { [weak self] in self?.close(); item.1() }) })
            }
            return a
        }

        let host = FirstMouseHostingView(rootView: ToastView(
            content: c,
            onHover: { [weak self] h in MainActor.assumeIsolated { self?.hover(h) } },
            onResize: { [weak self] in MainActor.assumeIsolated { self?.refit() } }
        ))
        panel.contentView = host
        refit()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        }
        schedule()
        return t
    }

    /// Sizes the panel to its content, pinned to the top-right corner (also when a card expands).
    private func refit() {
        guard let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard let screen = NSScreen.underMouse else { return }
        let vf = screen.visibleFrame
        panel.setFrame(NSRect(x: vf.maxX - size.width - 14, y: vf.maxY - size.height - 10,
                              width: size.width, height: size.height), display: true, animate: panel.isVisible)
    }

    func dismiss(ifToken t: UUID? = nil) {
        if let t, t != token { return }
        close()
    }

    private func close() {
        dismissWork?.cancel()
        onTimeout = nil
        panel.orderOut(nil)
    }

    private func hover(_ h: Bool) {
        hovering = h
        if h { dismissWork?.cancel() } else { schedule(after: 2) }
    }

    private func schedule(after override: TimeInterval? = nil) {
        dismissWork?.cancel()
        guard let d = override ?? duration, !hovering else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let timeout = self.onTimeout
                self.close()
                timeout?()
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: work)
    }
}
