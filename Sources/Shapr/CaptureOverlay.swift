import AppKit
import Carbon

/// Full-screen overlay for picking what to capture.
///  - hover: no clicking. Move the pointer around something; a short glowing trail follows and fades.
///           Pause, and the loop you drew is captured (double-tap ⌘).
///  - rect:  drag a rectangle (⌥⇧X).
final class CaptureOverlayView: NSView {
    enum Mode { case hover, rect }

    var mode: Mode = .hover
    var hint = ""
    var accent: NSColor = NSColor(hex: 0x5B5FEF)
    var onComplete: (CGRect) -> Void = { _ in }
    var onCancel: () -> Void = {}

    // Hover state
    private struct TrailPoint { let p: CGPoint; let t: TimeInterval }
    private var trail: [TrailPoint] = []
    private var stroke: [CGPoint] = []
    private var pen: CGPoint?
    private var lastMove: TimeInterval = 0
    private let opened = ProcessInfo.processInfo.systemUptime
    private var locked: [CGPoint]?

    // Rect state
    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?

    private var finished = false
    private var phase: Double = 0
    private var timer: Timer?

    static let trailLife: TimeInterval = 0.55
    static let dwell: TimeInterval = 0.32
    static let giveUp: TimeInterval = 20

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate() }

    // MARK: Hover tracking

    private func tick() {
        phase = (phase + 0.004).truncatingRemainder(dividingBy: 1)
        let now = ProcessInfo.processInfo.systemUptime
        if mode == .hover, !finished, let window {
            let m = NSEvent.mouseLocation
            let p = CGPoint(x: m.x - window.frame.minX, y: m.y - window.frame.minY)
            if let last = pen, hypot(p.x - last.x, p.y - last.y) > 1.5 {
                trail.append(TrailPoint(p: p, t: now))
                stroke.append(p)
                lastMove = now
            } else if pen == nil {
                lastMove = now // the pointer's starting spot isn't part of the drawing
            }
            pen = p
            trail.removeAll { now - $0.t > Self.trailLife }

            let idle = now - lastMove
            if !stroke.isEmpty, idle > Self.dwell {
                if let loop = Self.findLoop(stroke) {
                    lock(loop)
                } else if idle > 1.2 {
                    stroke.removeAll() // paused without circling anything: start over
                }
            }
            if now - opened > Self.giveUp && stroke.isEmpty { onCancel() }
        }
        needsDisplay = true
    }

    private func lock(_ loop: [CGPoint]) {
        locked = loop
        finished = true
        let rect = Self.bounds(of: loop).insetBy(dx: -8, dy: -8).intersection(bounds)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in self?.onComplete(rect) }
    }

    /// The most recent closed loop in a pointer path, ignoring the path taken to get there.
    /// Walks back from the end, growing the candidate loop, and keeps the largest one that both
    /// goes around something (path ≥ 1.2 × width+height) and comes back near where it started.
    static func findLoop(_ pts: [CGPoint], minSize: CGFloat = 24) -> [CGPoint]? {
        let n = pts.count
        guard n >= 10 else { return nil }
        let end = pts[n - 1]
        var length: CGFloat = 0
        var minX = end.x, maxX = end.x, minY = end.y, maxY = end.y
        var best: Int?
        var i = n - 2
        while i >= 0 {
            let a = pts[i], b = pts[i + 1]
            length += hypot(b.x - a.x, b.y - a.y)
            minX = min(minX, a.x); maxX = max(maxX, a.x); minY = min(minY, a.y); maxY = max(maxY, a.y)
            let w = maxX - minX, h = maxY - minY
            if w >= minSize, h >= minSize, length >= 1.2 * (w + h),
               hypot(a.x - end.x, a.y - end.y) <= max(20, 0.3 * max(w, h)) {
                best = i
            }
            i -= 1
        }
        return best.map { Array(pts[$0...]) }
    }

    static func bounds(of pts: [CGPoint]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude, minY = minX, maxX = -minX, maxY = -minX
        for p in pts { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// For snapshots: a trail with ages in seconds, or a locked loop.
    func preview(trail pts: [CGPoint], ages: [TimeInterval]) {
        let now = ProcessInfo.processInfo.systemUptime
        trail = zip(pts, ages).map { TrailPoint(p: $0, t: now - $1) }
        pen = pts.last
    }

    func previewLocked(_ loop: [CGPoint]) {
        locked = loop
        finished = true
    }

    // MARK: Rect input (⌥⇧X)

    override func mouseDown(with e: NSEvent) {
        guard mode == .rect, !finished else { return }
        let p = convert(e.locationInWindow, from: nil)
        dragStart = p
        dragEnd = p
    }

    override func mouseDragged(with e: NSEvent) {
        guard mode == .rect, !finished else { return }
        dragEnd = convert(e.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard mode == .rect, !finished, let a = dragStart, let b = dragEnd else { return }
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).intersection(bounds)
        guard rect.width > 10, rect.height > 10 else { onCancel(); return }
        finished = true
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in self?.onComplete(rect) }
    }

    override func rightMouseDown(with e: NSEvent) { onCancel() }

    override func keyDown(with e: NSEvent) {
        if Int(e.keyCode) == kVK_Escape { onCancel() } else { super.keyDown(with: e) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // A light veil while circling; once locked, everything outside the loop dims more.
        let veil = CGMutablePath()
        veil.addRect(bounds)
        if finished, let sel = selectionPath() { veil.addPath(sel) }
        ctx.addPath(veil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(finished ? 0.32 : (mode == .hover ? 0.08 : 0.18)).cgColor)
        ctx.fillPath(using: .evenOdd)

        switch mode {
        case .hover: finished ? drawLocked(ctx) : drawTrail(ctx)
        case .rect: drawRect(ctx)
        }
        drawHint()
    }

    private func selectionPath() -> CGPath? {
        if let loop = locked, loop.count > 2 {
            let p = CGMutablePath()
            p.addLines(between: smooth(loop))
            p.closeSubpath()
            return p
        }
        guard let a = dragStart, let b = dragEnd else { return nil }
        return CGPath(roundedRect: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)),
                      cornerWidth: 6, cornerHeight: 6, transform: nil)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The trail shifts gently around the pack's color (a narrow band, not a rainbow).
    /// With Reduce Motion it stays one steady color.
    private func color(_ shift: Double, alpha: CGFloat = 1) -> CGColor {
        let base = accent.usingColorSpace(.deviceRGB) ?? accent
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        let wobble = reduceMotion ? 0 : 0.06 * sin(shift * 2 * .pi)
        var hue = Double(h) + wobble
        hue -= floor(hue)
        return NSColor(hue: hue, saturation: max(sat, 0.55), brightness: max(b, 0.85), alpha: alpha).cgColor
    }

    /// A short comet: newest points bright and thick, older ones thin and fading to nothing.
    private func drawTrail(_ ctx: CGContext) {
        let now = ProcessInfo.processInfo.systemUptime
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let pts = trail
        if pts.count > 1 {
            // A thin light halo under the colored stroke keeps it visible on dark and busy backgrounds.
            for pass in 0..<2 {
                for i in 1..<pts.count {
                    let age = now - pts[i].t
                    let life = max(0, 1 - age / Self.trailLife)          // 1 = brand new, 0 = gone
                    let width = 2.5 + 4.5 * life
                    ctx.saveGState()
                    if pass == 0 {
                        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55 * CGFloat(life)).cgColor)
                        ctx.setLineWidth(width + 2.5)
                    } else {
                        ctx.setShadow(offset: .zero, blur: 6 * life, color: color(phase + Double(i) * 0.01, alpha: 0.5 * life))
                        ctx.setStrokeColor(color(phase + Double(i) * 0.01, alpha: CGFloat(life)))
                        ctx.setLineWidth(width)
                    }
                    ctx.move(to: pts[i - 1].p)
                    ctx.addLine(to: pts[i].p)
                    ctx.strokePath()
                    ctx.restoreGState()
                }
            }
        }
        // The pen: a small dot ringed in the pack's color, so you know circle mode is on.
        // It breathes slightly unless Reduce Motion is on.
        if let p = pen {
            let pulse = reduceMotion ? 1 : 1 + 0.12 * sin(phase * .pi * 2 * 4)
            let r = 4.5 * pulse
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 4, color: NSColor.black.withAlphaComponent(0.25).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - r - 2, y: p.y - r - 2, width: (r + 2) * 2, height: (r + 2) * 2))
            ctx.restoreGState()
            ctx.setFillColor(color(phase))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
    }

    private func drawLocked(_ ctx: CGContext) {
        guard let loop = locked, loop.count > 2 else { return }
        let path = CGMutablePath()
        path.addLines(between: smooth(loop))
        path.closeSubpath()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(5.5)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setShadow(offset: .zero, blur: 8, color: accent.withAlphaComponent(0.6).cgColor)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(3)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawRect(_ ctx: CGContext) {
        guard let a = dragStart, let b = dragEnd else { return }
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 12, color: accent.withAlphaComponent(0.8).cgColor)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(2.5)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
        let label = "\(Int(r.width)) × \(Int(r.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                                                    .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attrs)
        let origin = CGPoint(x: r.midX - size.width / 2, y: max(r.minY - size.height - 10, 8))
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: CGRect(origin: origin, size: size).insetBy(dx: -6, dy: -3), xRadius: 6, yRadius: 6).fill()
        label.draw(at: origin, withAttributes: attrs)
    }

    private func drawHint() {
        guard !hint.isEmpty, !finished else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                                                    .foregroundColor: dark ? NSColor(hex: 0xF3F5F8) : NSColor(hex: 0x20242C)]
        let s = hint as NSString
        let size = s.size(withAttributes: attrs)
        let pill = CGRect(x: bounds.midX - size.width / 2 - 16 - 8, y: bounds.maxY - size.height - 64,
                          width: size.width + 32 + 8, height: size.height + 14)
        let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.set()
        (dark ? NSColor(hex: 0x242730) : NSColor.white).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        (dark ? NSColor(hex: 0x363A46) : NSColor(hex: 0xE1E4EA)).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        accent.setFill()
        NSBezierPath(ovalIn: CGRect(x: pill.minX + 14, y: pill.midY - 3.5, width: 7, height: 7)).fill()
        s.draw(at: CGPoint(x: pill.minX + 16 + 12, y: pill.minY + 7), withAttributes: attrs)
    }

    /// Light smoothing so the locked outline looks drawn, not jagged.
    private func smooth(_ pts: [CGPoint]) -> [CGPoint] {
        guard pts.count > 4 else { return pts }
        return pts.indices.map { i in
            let a = pts[max(0, i - 2)], b = pts[i], c = pts[min(pts.count - 1, i + 2)]
            return CGPoint(x: (a.x + 2 * b.x + c.x) / 4, y: (a.y + 2 * b.y + c.y) / 4)
        }
    }
}

@MainActor
final class CaptureOverlayController {
    private var panel: FloatingPanel?
    private var view: CaptureOverlayView?
    private var clickMonitor: Any?

    var isVisible: Bool { panel?.isVisible == true }

    /// Covers the screen under the pointer. `onComplete` gets the picked region in global coordinates.
    func show(mode: CaptureOverlayView.Mode, hint: String, accent: NSColor,
              onComplete: @escaping (CGRect, NSScreen) -> Void) {
        hide()
        guard let screen = NSScreen.underMouse else { return }
        let p = FloatingPanel(size: screen.frame.size, level: .screenSaver)
        p.hasShadow = false
        p.setFrame(screen.frame, display: false)
        // Hover mode never takes the mouse: you circle with the pointer, no clicking.
        p.ignoresMouseEvents = mode == .hover
        let v = CaptureOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        v.mode = mode
        v.hint = hint
        v.accent = accent
        v.onCancel = { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        v.onComplete = { [weak self] local in
            MainActor.assumeIsolated {
                self?.hide()
                let global = local.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                // Give the window server a moment to remove the overlay before capturing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { onComplete(global, screen) }
            }
        }
        p.contentView = v
        p.allowsKey = true
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
        p.makeFirstResponder(v)
        if mode == .rect { NSCursor.crosshair.push() }
        if mode == .hover {
            // A click while circling means "never mind".
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
        panel = p
        view = v
    }

    func hide() {
        guard let panel else { return }
        view?.stop()
        if view?.mode == .rect { NSCursor.pop() }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        panel.orderOut(nil)
        self.panel = nil
        self.view = nil
    }
}
