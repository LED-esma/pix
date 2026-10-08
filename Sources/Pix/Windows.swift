import AppKit
import QuartzCore
import SwiftUI

// Board (floating) < highlight (floating + 1) < blob and card (floating + 2).
let pixLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)

/// Borderless, transparent, floats on every Space, never activates the app,
/// so whatever you were using stays frontmost.
class FloatingPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = pixLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }
}

// MARK: - Buddy

final class BuddyPanel: FloatingPanel {
    init(model: PixModel, controller: PixController) {
        super.init(size: BlobView.size)
        hasShadow = false
        let view = BuddyEventView(controller: controller)
        view.frame = NSRect(origin: .zero, size: BlobView.size)
        let host = NSHostingView(rootView: BlobView(model: model))
        host.frame = view.bounds
        view.addSubview(host)
        contentView = view
    }
    override var canBecomeKey: Bool { false }
}

/// Catches every click on the buddy: click toggles the card, drag moves it,
/// hover lets it peek out of the bezel, right-click opens the menu.
final class BuddyEventView: NSView {
    private weak var controller: PixController?
    private var startMouse = CGPoint.zero
    private var startOrigin = CGPoint.zero
    private var dragged = false

    init(controller: PixController) {
        self.controller = controller
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Pix")
        setAccessibilityHelp("Opens Pix")
    }

    override func accessibilityPerformPress() -> Bool {
        controller?.buddyClicked()
        return true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { controller?.hover(true) }
    override func mouseExited(with event: NSEvent) { controller?.hover(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let dx = now.x - startMouse.x, dy = now.y - startMouse.y
        if !dragged && hypot(dx, dy) < 3 { return }
        dragged = true
        window?.setFrameOrigin(CGPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        controller?.buddyMoved()
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { controller?.buddyDropped() } else { controller?.buddyClicked() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = controller?.menu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

// MARK: - Bubble

final class SizingHost<V: View>: NSHostingView<V> {
    var onResize: (() -> Void)?
    private var pending = false
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard !pending else { return }  // coalesce bursts into one layout pass
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.onResize?()
        }
    }
}

final class BubblePanel: FloatingPanel {
    let host: SizingHost<BubbleView>
    private weak var controller: PixController?

    init(model: PixModel, controller: PixController) {
        host = SizingHost(rootView: BubbleView(model: model, controller: controller))
        self.controller = controller
        super.init(size: CGSize(width: BubbleView.width, height: 100))
        hasShadow = true
        contentView = host
        host.onResize = { [weak controller] in controller?.layoutBubble() }
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { controller?.escape() }

    /// Standard edit shortcuts, which a menu-less floating panel doesn't get for free.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers else { return super.performKeyEquivalent(with: event) }
        let action: Selector? = switch key {
        case "v": #selector(NSText.paste(_:))
        case "c": #selector(NSText.copy(_:))
        case "x": #selector(NSText.cut(_:))
        case "a": #selector(NSText.selectAll(_:))
        case "z": Selector(("undo:"))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Highlight

/// Dims the screen a touch and rings the thing Pix is pointing at. Clicks pass through.
final class HighlightOverlay {
    private var window: NSWindow?
    private let dim = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let pointer = CALayer()
    private let tag = CALayer()
    static let purple = NSColor(red: 0.48, green: 0.36, blue: 0.94, alpha: 1)

    func show(_ rect: CGRect, on screen: NSScreen) {
        if window?.screen != screen || window == nil { build(on: screen) }
        guard let window else { return }
        let local = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let hole = CGPath(roundedRect: local, cornerWidth: 10, cornerHeight: 10, transform: nil)
        let full = CGMutablePath()
        full.addRect(CGRect(origin: .zero, size: screen.frame.size))
        full.addPath(hole)
        animate(dim, to: full)
        animate(ring, to: hole)
        if window.alphaValue < 1 || !window.isVisible {
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; window.animator().alphaValue = 1 }
        }
    }

    /// A hand pointing at the ring and a short label beside it ("Click Export"); nil takes them away.
    func say(_ text: String?, at rect: CGRect, on screen: NSScreen) {
        guard let window, let layer = window.contentView?.layer else { return }
        pointer.removeFromSuperlayer()
        tag.removeFromSuperlayer()
        guard let text, !text.isEmpty else { return }
        let local = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let size = screen.frame.size
        // The hand sits just below-right of the ring, its fingertip on the ring's corner.
        let hand: CGFloat = 30
        let config = NSImage.SymbolConfiguration(pointSize: hand, weight: .regular).applying(.init(paletteColors: [.white, Self.purple]))
        if let img = NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            pointer.contents = img
            pointer.frame = CGRect(x: min(local.maxX - 6, size.width - hand - 4), y: max(local.minY - hand + 6, 4), width: hand, height: hand)
            pointer.shadowColor = NSColor.black.cgColor
            pointer.shadowOpacity = 0.35
            pointer.shadowRadius = 3
            pointer.shadowOffset = CGSize(width: 0, height: -1)
            let tap = CABasicAnimation(keyPath: "transform.translation")
            tap.fromValue = NSValue(size: .zero)
            tap.toValue = NSValue(size: CGSize(width: -4, height: 4))
            tap.duration = 0.55
            tap.autoreverses = true
            tap.repeatCount = .infinity
            tap.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pointer.add(tap, forKey: "tap")
            layer.addSublayer(pointer)
        }
        // The label: a purple capsule under the ring (above it when there's no room below).
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let line = String(text.prefix(60))
        let width = ceil((line as NSString).size(withAttributes: [.font: font]).width) + 22
        let below = local.minY - 34 > 4
        let x = min(max(local.midX - width / 2, 6), size.width - width - 6)
        tag.frame = CGRect(x: x, y: below ? local.minY - 34 : local.maxY + 8, width: width, height: 26)
        tag.backgroundColor = Self.purple.cgColor
        tag.cornerRadius = 13
        tag.shadowColor = NSColor.black.cgColor
        tag.shadowOpacity = 0.25
        tag.shadowRadius = 4
        tag.shadowOffset = CGSize(width: 0, height: -1)
        let words = CATextLayer()
        words.string = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor.white])
        words.alignmentMode = .center
        words.contentsScale = screen.backingScaleFactor
        words.truncationMode = .end
        words.frame = CGRect(x: 8, y: (26 - 17) / 2, width: width - 16, height: 17)
        tag.sublayers = [words]
        layer.addSublayer(tag)
    }

    /// Takes the hand and label away and leaves the ring.
    func unsay() {
        pointer.removeFromSuperlayer()
        tag.removeFromSuperlayer()
    }

    func hide() {
        pointer.removeFromSuperlayer()
        tag.removeFromSuperlayer()
        guard let window, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; window.animator().alphaValue = 0 },
                                             completionHandler: { window.orderOut(nil) })
    }

    private func animate(_ layer: CAShapeLayer, to path: CGPath) {
        if let old = layer.path {
            let a = CABasicAnimation(keyPath: "path")
            a.fromValue = old
            a.toValue = path
            a.duration = 0.35
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(a, forKey: "path")
        }
        layer.path = path
    }

    private func build(on screen: NSScreen) {
        window?.orderOut(nil)
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.setFrame(screen.frame, display: false)

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.16).cgColor
        let purple = NSColor(red: 0.48, green: 0.36, blue: 0.94, alpha: 1).cgColor
        ring.fillColor = nil
        ring.strokeColor = purple
        ring.lineWidth = 3
        ring.shadowColor = purple
        ring.shadowOpacity = 0.9
        ring.shadowRadius = 8
        ring.shadowOffset = .zero
        dim.path = nil
        ring.path = nil
        view.layer?.addSublayer(dim)
        view.layer?.addSublayer(ring)
        w.contentView = view
        window = w
    }
}
