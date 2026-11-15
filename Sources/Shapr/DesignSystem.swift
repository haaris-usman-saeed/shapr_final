import AppKit
import SwiftUI

// MARK: - Tokens

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Resolves to `light` or `dark` with the view's appearance (follows System Settings).
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { ap in ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
}

extension Color {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: .dynamic(light: NSColor(hex: light), dark: NSColor(hex: dark)))
    }

    /// A see-through color that works on solid surfaces and on Liquid Glass alike.
    static func dynamic(_ light: UInt32, _ lightAlpha: CGFloat, _ dark: UInt32, _ darkAlpha: CGFloat) -> Color {
        Color(nsColor: .dynamic(light: NSColor(hex: light, alpha: lightAlpha), dark: NSColor(hex: dark, alpha: darkAlpha)))
    }
}

/// Shapr's design tokens. Calm and defined: warm paper-like neutrals, flat fills, one clay accent
/// for actions, focus and selection, and one color per pack, shown as its orb. Nothing shines and
/// nothing is decorated. Everything that floats (the voice card, panels, toasts, the wheel) is
/// Liquid Glass; what sits on it stays plain. Fills are see-through, so they read on glass and on
/// the library's solid surfaces alike.
enum DS {
    // Surfaces
    static let canvas = Color.dynamic(0xF7F6F2, 0x1C1B19)
    /// Solid panel color: the library's cards, and every surface when Reduce Transparency is on.
    static let panel = Color.dynamic(0xFFFFFF, 0x292825)
    /// Inset areas: editors, fields, quiet groups.
    static let well = Color.dynamic(0x1F1E1C, 0.045, 0xFFFFFF, 0.05)
    /// Hovered rows and secondary buttons.
    static let hover = Color.dynamic(0x1F1E1C, 0.075, 0xFFFFFF, 0.07)
    /// Hairlines.
    static let line = Color.dynamic(0x1F1E1C, 0.10, 0xFFFFFF, 0.13)
    /// A card on glass: a lighter layer that keeps lists and notes grouped without a solid block.
    static let card = Color.dynamic(0xFFFFFF, 0.55, 0xFFFFFF, 0.05)

    // Text (all pairs checked for 4.5:1 on canvas, panel and well)
    static let text = Color.dynamic(0x1F1E1C, 0xF4F2ED)
    static let text2 = Color.dynamic(0x5A5852, 0xBDB9B0)
    static let text3 = Color.dynamic(0x65625B, 0xABA79E)

    // Accent
    /// For text, icons, focus rings and selection outlines.
    static let accent = Color.dynamic(0xA44A22, 0xE9A07E)
    /// For filled buttons with a white label (4.5:1 in both modes).
    static let accentFill = Color.dynamic(0xB5562D, 0xB5562D)
    static let accentSoft = Color.dynamic(0xF6EAE3, 0x3D2B22)

    // Status
    static let success = Color.dynamic(0x1C7945, 0x5FD38F)
    static let warning = Color.dynamic(0x9A5B00, 0xF2B24C)
    static let danger = Color.dynamic(0xC2352D, 0xFF8178)

    /// Spacing scale.
    enum S {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    }

    /// Corner radii: concentric, Liquid Glass style (controls are capsules).
    enum R {
        static let control: CGFloat = 9, card: CGFloat = 14, panel: CGFloat = 24
    }

    /// 150 ms ease-out, or no animation at all with Reduce Motion.
    static func motion(_ reduce: Bool) -> Animation? { reduce ? nil : .easeOut(duration: 0.15) }

    /// A quick, playful spring for things that appear or react (the wheel, the voice orb, chips).
    static func spring(_ reduce: Bool) -> Animation? { reduce ? nil : .spring(response: 0.3, dampingFraction: 0.72) }
}

// MARK: - Control surface (one recipe, Luminare-style)

/// The fill every control on glass uses: soft at rest, deeper on hover and press, with a hairline.
/// System hierarchical styles, so it stays legible on Liquid Glass and on solid windows alike.
enum SurfaceState { case rest, hover, pressed }

extension View {
    func dsSurface<S: InsettableShape>(_ shape: S, _ state: SurfaceState = .rest, border: Bool = false) -> some View {
        self
            .background(shape.fill(state == .rest ? AnyShapeStyle(.quinary) : AnyShapeStyle(.quaternary)))
            .overlay { if border { shape.strokeBorder(.quaternary, lineWidth: 0.5) } }
    }
}

// MARK: - Liquid Glass

/// Set by `Shapr --render`: offscreen snapshots can't sample what's behind a window, so they draw
/// a stand-in instead of real glass.
enum GlassSettings {
    nonisolated(unsafe) static var snapshotFallback = false
}

extension View {
    /// Liquid Glass for Shapr's floating layer. Solid (with a hairline) when Reduce Transparency is on.
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: AnyShape(shape), tint: tint, interactive: interactive))
    }
}

private struct GlassSurface: ViewModifier {
    let shape: AnyShape
    let tint: Color?
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(DS.panel, in: shape).overlay(shape.stroke(DS.line, lineWidth: 0.5))
        } else if GlassSettings.snapshotFallback {
            content
                .background(DS.panel.opacity(0.82), in: shape)
                .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        } else {
            content.glassEffect(glass, in: shape)
        }
    }

    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension Font {
    /// Panel and window titles: the one place with a serif, for a calmer, more defined voice.
    static let dsTitle = Font.system(size: 17, weight: .semibold, design: .serif)
    /// Welcome and empty-state headings.
    static let dsDisplay = Font.system(size: 22, weight: .semibold, design: .serif)
    static let dsHeadline = Font.system(size: 13, weight: .semibold)
    static let dsBody = Font.system(size: 13)
    static let dsCallout = Font.system(size: 12)
    /// Metadata: sources, times, counts. Never smaller than 11 pt.
    static let dsMeta = Font.system(size: 11)
}

// MARK: - Pack identity

/// One color per pack, used as a cue (dot, icon tile, wheel slot), never as a surface.
/// Mid-tones that carry a white label and read on both light and dark backgrounds.
enum PackStyle {
    static let palette: [Color] = [
        .dynamic(0xD9573F, 0xEC6E56), // coral
        .dynamic(0xB8790F, 0xE0A12E), // amber
        .dynamic(0x2E9461, 0x48B57D), // green
        .dynamic(0x1C8BA0, 0x35A9BE), // teal
        .dynamic(0x3A72D8, 0x5A8FEE), // blue
        .dynamic(0x7F55D9, 0x9C78EC), // violet
        .dynamic(0xCC3F7E, 0xE45E98), // pink
        .dynamic(0x5E6B80, 0x8391A7), // slate
        .dynamic(0xD06A12, 0xF08A30), // orange
        .dynamic(0x9B4BA0, 0xC46FC9), // plum
    ]

    /// Deeper versions of the same hues for filled areas that carry a white label (4.5:1 or better),
    /// like the hovered slot on the wheel. The same in light and dark.
    static let deepHex: [UInt32] = [0xC54F39, 0xA0690D, 0x288356, 0x197F93, 0x3970D5,
                                    0x7F55D9, 0xC93E7C, 0x5E6B80, 0xB45C0F, 0x9B4BA0]

    /// Stable for a pack's whole life: picked when the pack is made (see PackStore.assignHues).
    static func color(_ id: UUID?) -> Color {
        guard let id else { return DS.accent }
        return palette[index(id)]
    }

    static func deep(_ id: UUID?) -> Color {
        guard let id else { return DS.accentFill }
        return Color(nsColor: NSColor(hex: deepHex[index(id)]))
    }

    /// A pack's initials for its orb: "Japan Trip" → "JT", "MAT223" → "M", "Bug #42" → "B".
    static func initials(_ name: String) -> String {
        let words = name.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        guard let first = words.first?.first else { return "" }
        var out = String(first).uppercased()
        if words.count > 1, let second = words[1].first, second.isLetter { out += String(second).uppercased() }
        return out
    }

    /// Each pack's color as PackStore assigned it. A pack it hasn't seen uses the one its id suggests.
    nonisolated(unsafe) private static var assigned: [UUID: Int] = [:]
    private static let lock = NSLock()

    static func assign(_ hue: Int, to id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        assigned[id] = hue
    }

    static func index(_ id: UUID) -> Int {
        lock.lock()
        let hue = assigned[id]
        lock.unlock()
        if let hue, palette.indices.contains(hue) { return hue }
        return hashIndex(id)
    }

    /// The color a pack's id suggests, used first when it's free.
    static func hashIndex(_ id: UUID) -> Int {
        var h: UInt64 = 1_469_598_103_934_665_603
        withUnsafeBytes(of: id.uuid) { for b in $0 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 } }
        return Int(h % UInt64(palette.count))
    }

    /// The color fewest packs have, looking from `start` round the palette.
    static func leastUsed(_ counts: [Int], from start: Int) -> Int {
        let fewest = counts.min() ?? 0
        return (0..<counts.count).lazy.map { (start + $0) % counts.count }.first { counts[$0] == fewest } ?? start
    }
}

/// A pack's orb: its initials on a flat circle of its color. No emoji, no gloss, the same everywhere.
struct PackIcon: View {
    let initials: String
    let color: Color
    var size: CGFloat = 24
    var symbol: String?

    init(pack: Pack?, size: CGFloat = 24) {
        initials = pack.map { PackStyle.initials($0.name) } ?? ""
        color = pack.map { PackStyle.deep($0.id) } ?? DS.accentFill
        self.size = size
        symbol = pack == nil ? "sparkles" : nil
    }

    /// A symbol on the same orb (Auto-sort, new pack).
    init(symbol: String, color: Color = DS.accentFill, size: CGFloat = 24) {
        initials = ""
        self.color = color
        self.size = size
        self.symbol = symbol
    }

    var body: some View {
        ZStack {
            Circle().fill(color)
            if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
            } else {
                Text(initials)
                    .font(.system(size: size * (initials.count > 1 ? 0.36 : 0.44), weight: .semibold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "◉ Cars": the pack's orb and name in a quiet capsule. Optional chevron when it opens a menu.
struct PackChip: View {
    let pack: Pack?
    var chevron = false
    var placeholder = "No pack"

    var body: some View {
        HStack(spacing: 6) {
            PackIcon(pack: pack, size: 16)
            Text(pack?.name ?? placeholder).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            if chevron {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(DS.text3)
            }
        }
        .foregroundStyle(DS.text)
        .padding(.leading, 4).padding(.trailing, 9).padding(.vertical, 3)
        .dsSurface(Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pack.map { "Pack: \($0.name)" } ?? placeholder)
    }
}

// MARK: - Controls

/// A keyboard hint like ⌘↩.
struct Keycap: View {
    let keys: String
    var onAccent = false

    var body: some View {
        Text(keys)
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(onAccent ? AnyShapeStyle(Color.white.opacity(0.22)) : AnyShapeStyle(.quaternary)))
            .foregroundStyle(onAccent ? Color.white.opacity(0.92) : DS.text2)
            .accessibilityHidden(true)
    }
}

/// Shapr's buttons, as flat capsules: primary (accent), secondary (a see-through fill), plain
/// (text only), destructive.
struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain, destructive }
    var kind: Kind = .secondary
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, kind: kind, small: small)
    }

    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let small: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: small ? 11.5 : 12.5, weight: kind == .primary ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, small ? 10 : 13)
                .frame(minHeight: small ? 24 : 30)
                .foregroundStyle(foreground)
                .background(Capsule().fill(fill))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }

        private var foreground: Color {
            switch kind {
            case .primary: return .white
            case .destructive: return DS.danger
            case .plain: return hovering && enabled ? DS.text : DS.text2
            case .secondary: return DS.text
            }
        }

        private var fill: AnyShapeStyle {
            let pressed = configuration.isPressed
            switch kind {
            case .primary: return AnyShapeStyle(DS.accentFill.opacity(pressed ? 0.8 : (hovering && enabled ? 0.92 : 1)))
            case .secondary: return pressed || (hovering && enabled) ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary)
            case .plain, .destructive: return pressed || (hovering && enabled) ? AnyShapeStyle(.quinary) : AnyShapeStyle(Color.clear)
            }
        }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsSecondary: DSButtonStyle { DSButtonStyle(kind: .secondary) }
    static var dsPlain: DSButtonStyle { DSButtonStyle(kind: .plain) }
}

/// A footer action with its shortcut, Raycast-style: "Insert ⌘↩".
struct HintButton: View {
    let title: String
    let keys: String
    var primary = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Keycap(keys: keys, onAccent: primary)
            }
        }
        .buttonStyle(DSButtonStyle(kind: primary ? .primary : .secondary))
        .fixedSize()
        .accessibilityHint("Shortcut \(keys)")
    }
}

/// A square icon button for toolbars and card actions.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 26
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.46, weight: .medium)).frame(width: size, height: size)
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A list row that lights up under the pointer (Raycast-style results).
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isPressed ? AnyShapeStyle(.quaternary) : (hovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(Color.clear))))
                .onHover { hovering = $0 }
        }
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? DS.text : DS.text2)
                .background(Circle().fill(configuration.isPressed ? AnyShapeStyle(.quaternary) : (hovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(Color.clear))))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Panels

extension View {
    /// The surface for Shapr's floating panels: Liquid Glass with 24 pt corners.
    func dsPanel(width: CGFloat) -> some View {
        self
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: DS.R.panel, style: .continuous))
            .glassSurface(RoundedRectangle(cornerRadius: DS.R.panel, style: .continuous))
            .padding(1) // room for the glass edge
    }

    /// A card on the canvas: panel color, 10 pt corners, hairline border.
    func dsCard(padding: CGFloat = DS.S.m, selected: Bool = false) -> some View {
        self
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous).fill(DS.panel))
            .overlay(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous)
                .strokeBorder(selected ? DS.accent : DS.line, lineWidth: selected ? 2 : 0.5))
    }
}

/// Top of a floating panel: what it's for and where it goes.
struct PanelHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    /// The destination app's icon when we know it, otherwise an SF Symbol on a quiet tile.
    var appIcon: NSImage?
    var symbol: String = "sparkles"
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().frame(width: 26, height: 26)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DS.text2)
                        .frame(width: 26, height: 26)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text).lineLimit(1)
                if let subtitle = subtitle?.nonEmpty {
                    Text(subtitle).font(.dsMeta).foregroundStyle(DS.text2).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, DS.S.l).padding(.top, 14).padding(.bottom, DS.S.m)
    }
}

/// Bottom of a floating panel, Raycast-style: status on the left, actions with their keys on the right.
struct PanelFooter<Leading: View, Actions: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: DS.S.s) {
            leading
            Spacer(minLength: DS.S.s)
            actions
        }
        .padding(.horizontal, DS.S.m).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(DS.line).frame(height: 0.5) }
    }
}

/// One line of state: working, a warning, an error, or done. Never relies on color alone.
struct StatusLine: View {
    enum Tone { case info, working, warning, error, success }
    let tone: Tone
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            switch tone {
            case .working: ProgressView().controlSize(.mini)
            case .info: Image(systemName: "info.circle")
            case .warning: Image(systemName: "exclamationmark.triangle.fill")
            case .error: Image(systemName: "xmark.octagon.fill")
            case .success: Image(systemName: "checkmark.circle.fill")
            }
            Text(text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .font(.dsMeta)
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tone {
        case .info, .working: return DS.text2
        case .warning: return DS.warning
        case .error: return DS.danger
        case .success: return DS.success
        }
    }
}

/// A section label inside a panel or inspector.
struct SectionLabel: View {
    let title: String
    var symbol: String?
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .medium)) }
            Text(title).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(DS.text2)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Empty, no-results and permission states: one clear message and at most one action.
struct EmptyState<Action: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: DS.S.s) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(DS.text3)
            Text(title).font(.dsTitle).foregroundStyle(DS.text)
            Text(message).font(.dsCallout).foregroundStyle(DS.text2).multilineTextAlignment(.center)
                .frame(maxWidth: 360).fixedSize(horizontal: false, vertical: true)
            action.padding(.top, DS.S.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

extension EmptyState where Action == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Capture previews

/// What a capture looks like at a glance: its screenshot, its file, or a quote of its text.
enum CapturePreview {
    case image(NSImage)
    case file(name: String, ext: String)
    case quote(String)

    @MainActor
    static func of(_ c: Capture, store: PackStore) -> CapturePreview {
        if let url = store.imageURL(for: c), let img = NSImage(contentsOf: url) { return .image(img) }
        if let f = c.file { return .file(name: c.title ?? f, ext: (f as NSString).pathExtension.lowercased()) }
        return .quote(c.text.singleLine.truncated(220))
    }

    static func fileSymbol(_ ext: String) -> String {
        switch ext {
        case "pdf": return "doc.richtext"
        case "xlsx", "csv", "tsv", "numbers": return "tablecells"
        case "pptx", "key": return "rectangle.on.rectangle.angled"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "sql", "py", "js", "ts", "swift", "go", "rs", "java", "c", "cpp", "rb", "php", "json", "sh", "html", "css":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc.text"
        }
    }
}

/// A screenshot shown whole, letterboxed on a quiet backdrop: never cropped, never stretched.
struct FittedImage: View {
    let image: NSImage
    var height: CGFloat
    var corner: CGFloat = 8

    var body: some View {
        ZStack {
            DS.well
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(4)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .accessibilityLabel("Screenshot")
    }
}

/// A file's type at a glance: symbol plus extension.
struct FileBadge: View {
    let ext: String
    var size: CGFloat = 40
    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: CapturePreview.fileSymbol(ext)).font(.system(size: size * 0.38, weight: .regular))
            Text(ext.uppercased().prefix(4)).font(.system(size: max(8.5, size * 0.2), weight: .semibold))
        }
        .foregroundStyle(DS.text2)
        .frame(width: size, height: size * 1.15)
        .background(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(DS.well))
        .overlay(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).strokeBorder(DS.line, lineWidth: 0.5))
        .accessibilityLabel("\(ext.uppercased()) file")
    }
}

/// The site or app a capture came from: a site's initial on a neutral tile, or a camera for screenshots.
struct SourceBadge: View {
    let capture: Capture
    var size: CGFloat = 18

    var body: some View {
        let key = capture.host ?? capture.appName ?? "?"
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(DS.well)
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(DS.line, lineWidth: 0.5)
            if capture.image != nil {
                Image(systemName: "camera.viewfinder").font(.system(size: size * 0.5, weight: .medium))
            } else if capture.file != nil {
                Image(systemName: "doc").font(.system(size: size * 0.5, weight: .medium))
            } else {
                Text(String(key.prefix(1)).uppercased()).font(.system(size: size * 0.52, weight: .semibold))
            }
        }
        .foregroundStyle(DS.text2)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension Capture {
    /// "caranddriver.com · Safari", "Screenshot · Preview", "report.pdf".
    var sourceSummary: String {
        var parts: [String] = []
        if let h = host { parts.append(h) }
        if let a = appName, a != host { parts.append(a) }
        if parts.isEmpty { parts.append(image != nil ? "Screenshot" : "Shapr") }
        return parts.joined(separator: " · ")
    }

    var kindLabel: String {
        if image != nil { return "Screenshot" }
        if file != nil { return "File" }
        return "Text"
    }
}
