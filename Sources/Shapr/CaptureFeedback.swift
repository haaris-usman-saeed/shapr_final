import AppKit
import SwiftUI

/// Makes a capture feel physical, and honest about it:
/// 1. the moment you press the shortcut, what you captured lights up (feedback in well under 100 ms);
/// 2. only once the capture is actually saved does a small card fly from there into the menu bar icon;
/// 3. if it fails, the highlight just fades and the card explains why.
/// With Reduce Motion on, the card fades in place instead of flying.
@MainActor
final class CaptureFeedback {
    private var highlightPanel: NSPanel?
    private var lastRect: CGRect?
    /// Where the pack lives on screen: the menu bar icon.
    var target: () -> CGRect? = { nil }
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Lights up `rect` (global AppKit coordinates) in the pack's color.
    func highlight(_ rect: CGRect, color: NSColor) {
        clearHighlight()
        let frame = rect.insetBy(dx: -5, dy: -4)
        let p = overlayPanel(frame)
        let v = NSView(frame: CGRect(origin: .zero, size: frame.size))
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        v.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        v.layer?.borderColor = color.withAlphaComponent(0.85).cgColor
        v.layer?.borderWidth = 2
        p.contentView = v
        p.alphaValue = 1
        p.orderFrontRegardless()
        highlightPanel = p
        lastRect = rect
    }

    /// The capture failed or was cancelled: fade the highlight without flying anything.
    func fadeHighlight() {
        guard let p = highlightPanel else { return }
        highlightPanel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }

    private func clearHighlight() {
        highlightPanel?.orderOut(nil)
        highlightPanel = nil
    }

    /// The capture was saved: a card with what it is and where it went flies to the menu bar.
    func landed(title: String, pack: Pack?, image: NSImage?, from rect: CGRect? = nil) {
        let start = rect ?? lastRect ?? CGRect(origin: NSEvent.mouseLocation, size: .zero).insetBy(dx: -40, dy: -12)
        fadeHighlight()
        let chip = NSHostingView(rootView: FlyingChip(title: title, pack: pack, image: image))
        chip.layoutSubtreeIfNeeded()
        let size = chip.fittingSize
        let from = CGRect(x: start.midX - size.width / 2, y: start.midY - size.height / 2, width: size.width, height: size.height)
        let p = overlayPanel(from)
        p.contentView = chip
        p.alphaValue = 0
        p.orderFrontRegardless()
        let end = target().map { CGRect(x: $0.midX - 10, y: $0.midY - 10, width: 20, height: 20) }
        if reduceMotion || end == nil {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 1 }, completionHandler: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
                }
            })
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 1
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.45
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.2, 1)
                p.animator().setFrame(end!, display: true)
                p.animator().alphaValue = 0.15
            }, completionHandler: {
                p.orderOut(nil)
                self.pulseTarget?()
            })
        })
    }

    /// Called when a card arrives, to make the menu bar icon react.
    var pulseTarget: (() -> Void)?

    private func overlayPanel(_ frame: CGRect) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isReleasedWhenClosed = false
        return p
    }
}

private struct FlyingChip: View {
    let title: String
    let pack: Pack?
    let image: NSImage?
    var body: some View {
        HStack(spacing: 6) {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                PackIcon(pack: pack, size: 20)
            }
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.text).lineLimit(1).frame(maxWidth: 200)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Capsule().fill(DS.panel))
        .overlay(Capsule().strokeBorder(PackStyle.color(pack?.id).opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .padding(8)
    }
}
