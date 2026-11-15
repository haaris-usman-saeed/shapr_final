import AppKit
import Carbon
import SwiftUI

struct WheelSlot: Hashable {
    var packID: UUID?
    var badge: String
    var name: String
    var count: Int
    var color: Color = .gray
    var isEmoji = true
    /// The fill when hovered: deep enough for a white label.
    var deep: Color = .gray
    /// The pack's latest capture.
    var latest: String? = nil
}

@MainActor
final class WheelModel: ObservableObject {
    static let autoIndex = 6

    @Published var slots: [WheelSlot] = Array(repeating: WheelSlot(packID: nil, badge: "", name: "", count: 0), count: 6)
    /// 0–5 = a slot, 6 = the center, nil = nothing yet. Moving it sweeps the wedge the short way round.
    @Published var highlighted: Int? {
        didSet {
            guard let h = highlighted, h < 6 else { return }
            var delta = (Double(h) * 60 - 90 - wedgeAngle).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
            wedgeAngle += delta
        }
    }
    /// Where the wedge points, in degrees (SwiftUI's: 0 = 3 o'clock, clockwise).
    @Published var wedgeAngle: Double = -90
    /// Which slot is currently equipped (6 = Auto-sort).
    @Published var equipped: Int = WheelModel.autoIndex
    /// Opened with a tap: stays up for clicks and keys. Otherwise it's held and picks on release.
    @Published var sticky = false
    @Published var appeared = false
}

// MARK: - View

struct AnnularSector: Shape {
    var start: Angle
    var end: Angle
    var inner: CGFloat
    var outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        p.closeSubpath()
        return p
    }
}

/// The lit place on the dial. Animates its angle, so it sweeps from pack to pack rather than jumping.
struct WheelWedge: Shape {
    var angle: Double
    var spread: Double
    var inner: CGFloat
    var outer: CGFloat
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    /// Softens the corners. The slice and its rounded outline are one shape, so it fills evenly on glass.
    var corner: CGFloat = 3
    func path(in rect: CGRect) -> Path {
        let slice = AnnularSector(start: .degrees(angle - spread), end: .degrees(angle + spread), inner: inner, outer: outer).path(in: rect)
        let outline = slice.strokedPath(StrokeStyle(lineWidth: corner * 2, lineJoin: .round))
        return Path(slice.cgPath.union(outline.cgPath))
    }
}

/// The pack wheel: one quiet glass dial at your pointer. Six places round the edge, each a dot of the
/// pack's color over its name. The place you point at lights up and the middle says what you'd get.
/// Nothing bounces and nothing shines: it's a dial, not a toy.
struct WheelView: View {
    @ObservedObject var model: WheelModel
    var onPick: (Int) -> Void = { _ in }
    var onAsk: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size: CGFloat = 360
    /// The dial's radius, and the radius of its middle (Auto-sort, and the neutral spot while you hold).
    static let ringRadius: CGFloat = 150
    static let centerRadius: CGFloat = 58
    private var labelRadius: CGFloat { (Self.ringRadius + Self.centerRadius) / 2 + 1 }
    private let center = CGPoint(x: WheelView.size / 2, y: WheelView.size / 2 - 14)

    private var hovered: Int? { model.highlighted }
    private var hoveredSlot: WheelSlot? { hovered.flatMap { $0 < 6 ? model.slots[$0] : nil } }

    var body: some View {
        ZStack {
            dial.position(center)
            ForEach(0..<6, id: \.self) { i in place(i) }
            middle.position(center)
            ForEach(0..<6, id: \.self) { i in hitArea(i) }
            if model.sticky {
                Text("1–6 equip  ·  A auto  ·  N new  ·  ? ask")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.text2)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .glassSurface(Capsule())
                    .position(x: Self.size / 2, y: center.y + Self.ringRadius + 24)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .scaleEffect(model.appeared || reduceMotion ? 1 : 0.97)
        .opacity(model.appeared ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.appeared)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.highlighted)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.wedgeAngle)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.sticky)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pack wheel")
    }

    // MARK: Dial

    /// One piece of glass with hairlines between the places, and a soft neutral wedge under the pointer.
    private var dial: some View {
        let d = Self.ringRadius * 2
        let onPlace = hovered.map { $0 < 6 } ?? false
        let wedge = WheelWedge(angle: model.wedgeAngle, spread: 26.5, inner: Self.centerRadius + 8, outer: Self.ringRadius - 8)
        return ZStack {
            wedge.fill(Color.primary.opacity(onPlace ? 0.09 : 0))
            ForEach(0..<6, id: \.self) { i in
                Rectangle()
                    .fill(DS.line)
                    .frame(width: 0.5, height: Self.ringRadius - Self.centerRadius - 30)
                    .offset(y: -(Self.ringRadius + Self.centerRadius) / 2)
                    .rotationEffect(.degrees(Double(i) * 60 + 30))
            }
            Circle()
                .fill(Color.primary.opacity(hovered == WheelModel.autoIndex ? 0.07 : 0))
                .overlay(Circle().strokeBorder(DS.line, lineWidth: 0.5))
                .frame(width: Self.centerRadius * 2, height: Self.centerRadius * 2)
        }
        .frame(width: d, height: d)
        .glassSurface(Circle())
    }

    private func point(_ i: Int) -> CGPoint {
        let a = (Double(i) * 60 - 90) * .pi / 180
        return CGPoint(x: center.x + labelRadius * cos(a), y: center.y + labelRadius * sin(a))
    }

    /// A pack's place: a dot of its color (ringed when it's the equipped one) over its name.
    private func place(_ i: Int) -> some View {
        let slot = model.slots[i]
        let isHi = hovered == i
        let isEquipped = model.equipped == i && slot.packID != nil
        return VStack(spacing: 5) {
            if slot.packID == nil {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isHi ? DS.text : DS.text3)
                    .frame(width: 18, height: 18)
                Text("New pack")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.text2)
                    .opacity(isHi ? 1 : 0)
            } else {
                ZStack {
                    Circle().fill(slot.deep).frame(width: 10, height: 10)
                    if isEquipped { Circle().strokeBorder(DS.text, lineWidth: 1.5).frame(width: 18, height: 18) }
                }
                .frame(width: 18, height: 18)
                Text(slot.name)
                    .font(.system(size: 11.5, weight: isEquipped ? .semibold : .medium))
                    .foregroundStyle(isHi || isEquipped ? DS.text : DS.text2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 82)
            }
        }
        .frame(width: 88, height: 60, alignment: .top)
        .position(point(i))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The whole slice is the button, not just the label.
    private func hitArea(_ i: Int) -> some View {
        let slot = model.slots[i]
        let isEquipped = model.equipped == i && slot.packID != nil
        let mid = Double(i) * 60 - 90
        let d = Self.ringRadius * 2
        return Color.clear
            .frame(width: d, height: d)
            .contentShape(AnnularSector(start: .degrees(mid - 30), end: .degrees(mid + 30), inner: Self.centerRadius, outer: Self.ringRadius))
            .onTapGesture { onPick(i) }
            .position(center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(slot.packID == nil ? "Slot \(i + 1), new pack"
                                                    : "Slot \(i + 1), \(slot.name), \(slot.count) captures\(isEquipped ? ", equipped" : "")")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onPick(i) }
    }

    /// What you'd get: the pack you point at, or what's equipped now.
    private var middle: some View {
        let d = Self.centerRadius * 2
        let equippedSlot = model.equipped < 6 ? model.slots[model.equipped] : nil
        let autoOn = model.equipped == WheelModel.autoIndex
        let title: String
        let detail: String
        if let slot = hoveredSlot, slot.packID != nil {
            title = slot.name
            detail = hovered == model.equipped ? "Equipped" : "\(slot.count) capture\(slot.count == 1 ? "" : "s")"
        } else if hoveredSlot != nil {
            title = "New pack"
            detail = "Starts empty"
        } else if hovered == WheelModel.autoIndex {
            title = "Auto-sort"
            detail = model.sticky ? "Shapr picks the pack" : "Let go to cancel"
        } else if !autoOn, let eq = equippedSlot, eq.packID != nil {
            title = eq.name
            detail = "Equipped"
        } else {
            title = "Auto-sort"
            detail = "On"
        }
        return VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.text)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(DS.text2)
                .lineLimit(2)
        }
        .multilineTextAlignment(.center)
        .frame(width: d - 18)
        .frame(width: d, height: d)
        .contentShape(Circle())
        .onTapGesture { if model.sticky { onPick(WheelModel.autoIndex) } }
        .contentTransition(.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(autoOn ? "Auto-sort is on" : "Equipped: \(equippedSlot?.name ?? "")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Auto-sort") { onPick(WheelModel.autoIndex) }
    }
}

// MARK: - Controller

/// Hold ⌥S: the wheel opens at the pointer. Point (or scroll) at a pack and let go to equip it.
/// Tap ⌥S: the wheel stays open; click a slot or press 1–6 (0 or A = Auto-sort, Esc = cancel).
/// The center is neutral while held: letting go there cancels, so nothing changes by accident.
@MainActor
final class WheelController {
    private let store: PackStore
    private let onEquip: (UUID?) -> Void
    /// Make a new empty pack and equip it. The Int is the empty slot picked, or nil for "any slot".
    private let onNewPack: (Int?) -> Void
    /// Ask a pack a question: the one pointed at, else the equipped one (nil = every pack).
    var onAsk: (UUID?) -> Void = { _ in }
    private let model = WheelModel()
    private let panel = FloatingPanel(size: NSSize(width: WheelView.size, height: WheelView.size), level: .popUpMenu)

    private var shownAt = Date.distantPast
    private var timer: Timer?
    private var monitors: [Any] = []
    private var lastMouse = CGPoint.zero
    private var scrollAccum: CGFloat = 0

    var isVisible: Bool { panel.isVisible }

    init(store: PackStore, onEquip: @escaping (UUID?) -> Void, onNewPack: @escaping (Int?) -> Void) {
        self.store = store
        self.onEquip = onEquip
        self.onNewPack = onNewPack
        panel.hasShadow = false
        panel.contentView = FirstMouseHostingView(rootView: WheelView(model: model, onPick: { [weak self] i in
            MainActor.assumeIsolated { self?.commit(i) }
        }, onAsk: { [weak self] in
            MainActor.assumeIsolated { self?.ask() }
        }))
    }

    /// Opens the wheel to click or type a number (from the ⌥⇧Space panel).
    func openSticky() {
        guard !isVisible else { return }
        show()
        model.sticky = true
    }

    func hotkeyDown() {
        if isVisible {
            if model.sticky { cancel() }
            return
        }
        show()
    }

    enum Release: Equatable { case commit(Int), stayOpen, cancel }

    /// What letting go of ⌥S does. A quick tap keeps the wheel open for clicks and keys; letting go
    /// over a slot picks it; letting go over the center (or before pointing anywhere) changes nothing.
    nonisolated static func release(highlighted: Int?, heldFor: TimeInterval) -> Release {
        if highlighted == nil && heldFor < 0.35 { return .stayOpen }
        if let h = highlighted, h != 6 { return .commit(h) } // 6 = the center
        return .cancel
    }

    func hotkeyUp() {
        guard isVisible, !model.sticky else { return }
        switch Self.release(highlighted: model.highlighted, heldFor: Date().timeIntervalSince(shownAt)) {
        case .stayOpen: model.sticky = true
        case .commit(let h): commit(h)
        case .cancel: cancel()
        }
    }

    private func show() {
        model.slots = store.wheelSlots.map { id in
            guard let p = store.pack(id) else { return WheelSlot(packID: nil, badge: "", name: "", count: 0) }
            return WheelSlot(packID: p.id, badge: PackStyle.initials(p.name), name: p.name, count: p.captures.count,
                             color: PackStyle.color(p.id), isEmoji: false, deep: PackStyle.deep(p.id),
                             latest: p.captures.last?.displayTitle.singleLine.truncated(48))
        }
        model.equipped = store.equippedPackID.flatMap { store.wheelSlots.firstIndex(of: $0) } ?? WheelModel.autoIndex
        model.highlighted = nil
        model.wedgeAngle = Double(model.equipped < 6 ? model.equipped : 0) * 60 - 90
        model.sticky = false
        model.appeared = false
        scrollAccum = 0

        let m = NSEvent.mouseLocation
        lastMouse = m
        // The ring (not the panel) is centered on the pointer; the ring sits 14 pt above the panel's middle.
        var origin = CGPoint(x: m.x - WheelView.size / 2, y: m.y - WheelView.size / 2 - 14)
        if let vf = NSScreen.underMouse?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX), vf.maxX - WheelView.size)
            origin.y = min(max(origin.y, vf.minY), vf.maxY - WheelView.size)
        }
        panel.setFrameOrigin(origin)
        panel.allowsKey = true
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        shownAt = Date()
        DispatchQueue.main.async { self.model.appeared = true }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        installMonitors()
    }

    private func hide() {
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.allowsKey = false
        panel.orderOut(nil)
        model.appeared = false
    }

    private func cancel() { hide() }

    private func commit(_ index: Int) {
        if index == WheelModel.autoIndex {
            hide()
            onEquip(nil)
        } else if let id = model.slots[index].packID {
            hide()
            onEquip(id)
        } else {
            // Empty "＋" slot: start a new pack there and equip it.
            hide()
            onNewPack(index)
        }
    }

    private func ask() {
        let pointed = model.highlighted.flatMap { $0 < 6 ? model.slots[$0].packID : nil }
        hide()
        onAsk(pointed ?? store.equippedPackID)
    }

    private func tick() {
        let m = NSEvent.mouseLocation
        if hypot(m.x - lastMouse.x, m.y - lastMouse.y) > 1.5 {
            lastMouse = m
            // The ring sits 14 pt above the panel's middle (room for the preview line under it).
            let c = CGPoint(x: panel.frame.midX, y: panel.frame.midY + 14)
            let dx = m.x - c.x, dy = m.y - c.y
            let dist = hypot(dx, dy)
            if dist < WheelView.centerRadius + 4 {
                model.highlighted = WheelModel.autoIndex
            } else {
                // Clockwise from 12 o'clock (screen y points up).
                var deg = 90 - atan2(dy, dx) * 180 / .pi
                if deg < 0 { deg += 360 }
                model.highlighted = Int((deg + 30) / 60) % 6
            }
        }
        // Backup for the hotkey release event: if S is no longer held, treat it as a release.
        if !model.sticky, Date().timeIntervalSince(shownAt) > 0.12,
           !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_S)) {
            hotkeyUp()
        }
    }

    private func installMonitors() {
        let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            MainActor.assumeIsolated { self?.key(e) == true ? nil : e }
        }
        let scroll = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] e in
            MainActor.assumeIsolated { self?.scroll(e) }
            return nil
        }
        let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        monitors = [keys, scroll, outside].compactMap { $0 }
    }

    private func key(_ e: NSEvent) -> Bool {
        let digits: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5] // number row 1–6
        if let i = digits[e.keyCode] { commit(i); return true }
        switch Int(e.keyCode) {
        case kVK_ANSI_0, kVK_ANSI_A: commit(WheelModel.autoIndex)
        case kVK_ANSI_N: hide(); onNewPack(nil)
        case kVK_ANSI_Slash: ask()
        case kVK_Escape: cancel()
        case kVK_Return, kVK_Space: if let h = model.highlighted { commit(h) } else { cancel() }
        case kVK_RightArrow, kVK_DownArrow: step(1)
        case kVK_LeftArrow, kVK_UpArrow: step(-1)
        default: return e.keyCode == UInt16(kVK_ANSI_S) // swallow autorepeat of S
        }
        return true
    }

    private func scroll(_ e: NSEvent) {
        scrollAccum += e.scrollingDeltaY != 0 ? e.scrollingDeltaY : e.scrollingDeltaX
        let threshold: CGFloat = e.hasPreciseScrollingDeltas ? 24 : 1
        while abs(scrollAccum) >= threshold {
            step(scrollAccum > 0 ? -1 : 1)
            scrollAccum -= scrollAccum > 0 ? threshold : -threshold
        }
    }

    /// Cycles Auto → 1 → … → 6 → Auto.
    private func step(_ d: Int) {
        let order = [WheelModel.autoIndex, 0, 1, 2, 3, 4, 5]
        let cur = order.firstIndex(of: model.highlighted ?? model.equipped) ?? 0
        model.highlighted = order[(cur + d + order.count) % order.count]
    }
}
