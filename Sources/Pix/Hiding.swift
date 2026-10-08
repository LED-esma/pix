import AppKit

/// How Pix looks while it waits: the blob tucked in the bezel (the default), or something quieter.
enum HideStyle: String, CaseIterable {
    case blob, pill, eyes, sliver, corner, menuBar, notch

    var title: String {
        switch self {
        case .blob: "Blob"
        case .pill: "Edge Pill"
        case .eyes: "Just Eyes"
        case .sliver: "Glow Sliver"
        case .corner: "Corner"
        case .menuBar: "Menu Bar"
        case .notch: "Notch"
        }
    }

    /// Lives on the side bezel (and can be dragged up and down it), rather than a fixed spot.
    var onEdge: Bool { [.blob, .pill, .eyes, .sliver].contains(self) }

    /// How much of the window shows past the bezel when tucked, for the edge styles.
    var shown: CGFloat {
        switch self {
        case .pill, .eyes: 13
        case .sliver: 4
        default: 16
        }
    }

    static var current: HideStyle {
        get { UserDefaults.standard.string(forKey: "hideStyle").flatMap(HideStyle.init) ?? .blob }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hideStyle") }
    }
}

/// The three hiding behaviors, each its own switch in the right-click menu.
enum Hiding {
    static var sleepWhenIdle: Bool {
        get { UserDefaults.standard.bool(forKey: "hide.sleep") }
        set { UserDefaults.standard.set(newValue, forKey: "hide.sleep") }
    }
    /// On unless turned off: nobody wants a blob over their slides or a movie.
    static var vanishWhenPresenting: Bool {
        get { UserDefaults.standard.object(forKey: "hide.present") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hide.present") }
    }
    static var peekOnApproach: Bool {
        get { UserDefaults.standard.bool(forKey: "hide.approach") }
        set { UserDefaults.standard.set(newValue, forKey: "hide.approach") }
    }

    static let sleepAfter: TimeInterval = 10 * 60
    static let approachDistance: CGFloat = 90

    /// The right edge of the MacBook notch on `screen`, or nil on a screen without one.
    static func notchRight(_ screen: NSScreen) -> CGFloat? {
        screen.auxiliaryTopRightArea.map(\.minX)
    }

    /// An app filling the whole screen (a full-screen video, a slideshow, a full-screen app): its
    /// window covers the screen's full frame, menu bar included. Window bounds need no permission.
    static func presenting(on screen: NSScreen) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              front != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let f = screen.frame
        let target = CGRect(x: f.minX, y: primaryTop - f.maxY, width: f.width, height: f.height)  // CG uses top-left origin
        return list.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == front, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            return abs(r.width - target.width) < 2 && abs(r.height - target.height) < 2
                && abs(r.minX - target.minX) < 2 && abs(r.minY - target.minY) < 2
        }
    }

    /// The face in the menu bar: a small purple pill with two eyes (closed while asleep).
    static func menuBarImage(asleep: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 22, height: 14), flipped: false) { rect in
            let body = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            NSGradient(starting: NSColor(red: Blob.top.r, green: Blob.top.g, blue: Blob.top.b, alpha: 1),
                       ending: NSColor(red: Blob.bottom.r, green: Blob.bottom.g, blue: Blob.bottom.b, alpha: 1))?
                .draw(in: body, angle: -90)
            NSColor.white.setFill()
            for x in [8.0, 14.0] {
                let eye = asleep ? NSRect(x: x - 1.5, y: 6, width: 3, height: 1.2) : NSRect(x: x - 1.2, y: 4.5, width: 2.4, height: 5)
                NSBezierPath(roundedRect: eye, xRadius: 1.2, yRadius: 1.2).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}

extension Placement {
    /// Where the blob's window goes for a hiding style. Edge styles sit on the side bezel at `y`;
    /// Corner tucks into the bottom corner on that side; Notch tucks into the menu bar beside the
    /// notch (`notchX`, or the top middle without one); Menu Bar comes out under its menu bar face.
    static func home(_ state: Dock, style: HideStyle, right: Bool, y: CGFloat, screen: CGRect, visible: CGRect,
                     notchX: CGFloat? = nil, statusX: CGFloat? = nil) -> CGPoint {
        let size = BlobView.size
        let inset = (size.width - 2 * BlobView.radius) / 2
        let below = visible.maxY - size.height - 2  // just under the menu bar
        switch style {
        case .blob, .pill, .eyes, .sliver:
            let shown: CGFloat = switch state { case .tucked: style.shown; case .peek: 28; case .out: 2 * BlobView.radius + 10 }
            let x = right ? screen.maxX - shown - inset : screen.minX + shown - (size.width - inset)
            return CGPoint(x: x, y: min(max(y, visible.minY + 4), visible.maxY - size.height - 4))
        case .corner:
            let cx = right ? screen.maxX : screen.minX, sx: CGFloat = right ? -1 : 1
            switch state {
            case .tucked: return CGPoint(x: cx - size.width / 2, y: screen.minY - size.height / 2)
            case .peek: return CGPoint(x: cx - size.width / 2 + sx * 8, y: screen.minY - size.height / 2 + 8)
            case .out:
                let x = right ? screen.maxX - (2 * BlobView.radius + 10) - inset : screen.minX + (2 * BlobView.radius + 10) - (size.width - inset)
                return CGPoint(x: x, y: visible.minY + 4)
            }
        case .notch:
            let cx = (notchX ?? screen.midX + 60) + 18
            let bar = max(screen.maxY - visible.maxY, 24)
            switch state {
            case .tucked: return CGPoint(x: cx - size.width / 2, y: screen.maxY - bar / 2 - size.height / 2)
            case .peek: return CGPoint(x: cx - size.width / 2, y: screen.maxY - bar / 2 - size.height / 2 - 8)
            case .out: return CGPoint(x: cx - size.width / 2, y: below)
            }
        case .menuBar:
            let cx = statusX ?? screen.maxX - 160  // menu bar items live on the right
            return CGPoint(x: min(max(cx - size.width / 2, screen.minX + 4), screen.maxX - size.width - 4), y: below)
        }
    }
}

/// Hiding styles and behaviors: where Pix tucks, the menu bar face, sleeping, vanishing, peeking.
extension PixController {
    var hideStyle: HideStyle { model.hideStyle }

    /// The screen Pix tucks into for its style.
    var homeScreen: NSScreen {
        switch hideStyle {
        case .notch: NSScreen.screens.first { $0.auxiliaryTopRightArea != nil } ?? NSScreen.screens[0]
        case .menuBar: NSScreen.screens.first ?? dockScreen
        default: dockScreen
        }
    }

    func setHideStyle(_ style: HideStyle) {
        HideStyle.current = style
        model.hideStyle = style
        model.dockRight = dockRight
        applyHideStyle()
        if !bubbleOpen && !roaming { slide(.tucked) }
        // Show where it went: a quick peek and back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.bubbleOpen, !self.roaming, style != .menuBar else { return }
            self.slide(.peek) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.slideHome() } }
        }
    }

    /// Sets up what the style needs: the menu bar face, and the window level for the notch.
    func applyHideStyle() {
        if hideStyle == .menuBar {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.image = Hiding.menuBarImage(asleep: model.sleeping)
                item.button?.setAccessibilityLabel("Pix")
                item.button?.target = MenuTarget.shared
                item.button?.action = #selector(MenuTarget.statusClicked)
                item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
                MenuTarget.shared.controller = self
                statusItem = item
            }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            if !hiddenForPresenting { buddy.orderFrontRegardless() }
        }
        startHidingWatch()
    }

    func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = statusItem?.button {
            menu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            return
        }
        if bubbleOpen && !roaming { escape() } else { summon() }
    }

    /// Where the menu bar face is, so Pix comes out right under it.
    var statusX: CGFloat? {
        // Right after launch macOS hasn't placed the face yet (its window sits at 0): use the default spot.
        guard let w = statusItem?.button?.window, w.frame.width > 0, w.frame.minX > 1 else { return nil }
        return w.frame.midX
    }

    /// Something happened: wake up, and start the idle clock again.
    func noteActivity() {
        lastActivity = Date()
        if model.sleeping {
            model.sleeping = false
            statusItem?.button?.image = Hiding.menuBarImage(asleep: false)
        }
    }

    /// One light timer for the three behaviors, running only while one of them is on.
    func startHidingWatch() {
        hidingTimer?.invalidate()
        hidingTimer = nil
        if !Hiding.sleepWhenIdle, model.sleeping { noteActivity() }
        if !Hiding.vanishWhenPresenting, hiddenForPresenting { showAfterPresenting() }
        guard Hiding.sleepWhenIdle || Hiding.vanishWhenPresenting || Hiding.peekOnApproach else { return }
        // Fast enough to feel the cursor coming (Peek on Approach); otherwise twice a second is plenty.
        let every = Hiding.peekOnApproach ? 0.1 : 0.5
        hidingTimer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidingTick() }
        }
    }

    private var resting: Bool { !bubbleOpen && !roaming && !dragging && !model.isBusy && !model.moving }

    private func hidingTick() {
        hidingTicks += 1
        // Vanish when presenting: checked every second or so.
        if Hiding.vanishWhenPresenting, hidingTicks % (Hiding.peekOnApproach ? 10 : 2) == 0 {
            let presenting = resting && Hiding.presenting(on: homeScreen)
            if presenting && !hiddenForPresenting {
                hiddenForPresenting = true
                NSAnimationContext.runAnimationGroup { $0.duration = 0.3; buddy.animator().alphaValue = 0 }
                buddy.ignoresMouseEvents = true
            } else if !presenting && hiddenForPresenting {
                showAfterPresenting()
            }
        }
        guard resting, !hiddenForPresenting else { return }
        // Peek on approach: slides out as the cursor nears where Pix is tucked.
        if Hiding.peekOnApproach, hideStyle != .menuBar {
            let home = NSRect(origin: dockOrigin(.tucked), size: BlobView.size)
            let m = NSEvent.mouseLocation
            let dx = max(home.minX - m.x, 0, m.x - home.maxX), dy = max(home.minY - m.y, 0, m.y - home.maxY)
            let near = hypot(dx, dy) < Hiding.approachDistance
            if near != approachNear {
                approachNear = near
                if near { noteActivity() }
                if !hovering { slide(near ? .peek : .tucked) }
            }
        }
        // Sleep when idle: eyes close and it dims; anything at all wakes it.
        if Hiding.sleepWhenIdle, !model.sleeping, model.timers.isEmpty, !approachNear, !hovering,
           Date().timeIntervalSince(lastActivity) > Hiding.sleepAfter {
            model.sleeping = true
            statusItem?.button?.image = Hiding.menuBarImage(asleep: true)
        }
    }

    func showAfterPresenting() {
        hiddenForPresenting = false
        buddy.ignoresMouseEvents = false
        if hideStyle != .menuBar || bubbleOpen { buddy.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; buddy.animator().alphaValue = 1 }
    }
}
