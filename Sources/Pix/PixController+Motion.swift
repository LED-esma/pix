import AppKit

/// One feel for every move: quick to start, gentle to land (like macOS's own window animations).
enum Motion {
    static let smooth = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
    /// Reduce Motion (System Settings > Accessibility): no stretching, jiggling or overshoot.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Easing curves for the blob's own drawing; x runs 0...1.
enum Ease {
    static func out(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func inOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    /// Quick start, a small overshoot (about 8%), settles at 1: a soft jelly.
    static func spring(_ x: Double) -> Double { x >= 1 ? 1 : 1 - exp(-7.5 * x) * cos(8 * x) }
}

/// Docking in the bezel, gliding, and the blob's own input.
extension PixController {
    // MARK: - Bezel docking

    func loadDock() {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        dockY = vf.minY + vf.height * 0.3
        if let d = UserDefaults.standard.array(forKey: "dock") as? [Double], d.count == 2 {
            dockRight = d[0] != 0
            dockY = d[1]
        }
    }

    /// The screen whose outer edge Pix is docked to.
    var dockScreen: NSScreen {
        let p = CGPoint(x: dockRight ? 1e9 : -1e9, y: dockY + 32)
        let level = NSScreen.screens.filter { $0.frame.minY <= p.y && $0.frame.maxY >= p.y }
        let pick = dockRight ? level.max { $0.frame.maxX < $1.frame.maxX } : level.min { $0.frame.minX < $1.frame.minX }
        return pick ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func dockOrigin(_ state: Placement.Dock) -> CGPoint {
        let s = homeScreen
        return Placement.home(state, style: hideStyle, right: dockRight, y: dockY, screen: s.frame, visible: s.visibleFrame,
                              notchX: Hiding.notchRight(s), statusX: statusX)
    }

    func slide(_ state: Placement.Dock, then done: (() -> Void)? = nil) {
        guard !roaming else { done?(); return }
        if state != .out { model.look = CGVector(dx: dockRight ? -1 : 1, dy: 0) }
        setTucked(state == .tucked)  // the shape morphs while it slides in
        if hideStyle == .menuBar, state != .tucked, !hiddenForPresenting { buddy.orderFrontRegardless() }
        buddy.level = hideStyle == .notch && state != .out ? .statusBar : pixLevel  // tucked into the menu bar, beside the notch
        move(to: dockOrigin(state), duration: state == .out ? 0.28 : 0.22) { [weak self] in
            if state == .tucked, let self {
                if self.hideStyle == .menuBar, !self.bubbleOpen { self.buddy.orderOut(nil) }  // the menu bar face stands in
            }
            done?()
        }
    }

    /// Tucked in: the blob turns into its hiding shape (BlobView cross-fades over a quarter second).
    func setTucked(_ t: Bool) {
        guard model.tucked != t else { return }
        model.morphFrom = min(1, max(0, model.morph()))
        model.tuckedAt = Date()
        model.animate(for: t ? 0.5 : 0.25)
        model.tucked = t
    }

    func slideHome() {
        slide(bubbleOpen ? .out : hovering ? .peek : .tucked)
    }

    func redock() {
        guard !roaming, !dragging else { return }
        slideHome()
        layoutBubble()
    }

    func move(to origin: CGPoint, duration: TimeInterval, then done: (() -> Void)? = nil) {
        let target = NSRect(origin: origin, size: BlobView.size)
        moveToken += 1
        let token = moveToken
        guard buddy.frame != target else { model.moving = false; done?(); return }
        let from = buddy.frame.origin, d = max(1, hypot(origin.x - from.x, origin.y - from.y))
        model.moveStart = Date()
        model.moveDuration = duration
        model.moveDir = CGVector(dx: (origin.x - from.x) / d, dy: -(origin.y - from.y) / d)  // the canvas's y points down
        model.moving = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = Motion.smooth
            buddy.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A newer move took over (say, the next tour step started mid-glide): ignore this one.
                guard let self, token == self.moveToken else { return }
                self.model.landedAt = Date()
                self.model.animate(for: 0.55)  // the landing jiggle
                self.model.moving = false
                done?()
            }
        })
    }

    /// Off the bezel and across the screen to a spot, eyes leading the way.
    func glide(to origin: CGPoint, then done: @escaping () -> Void) {
        let from = buddy.frame.origin
        let d = hypot(origin.x - from.x, origin.y - from.y)
        if d > 1 { model.look = CGVector(dx: (origin.x - from.x) / d, dy: -(origin.y - from.y) / d) }
        move(to: origin, duration: min(max(d / 1100, 0.3), 0.9), then: done)
    }

    // MARK: - Buddy input

    func buddyClicked() {
        noteActivity()
        if model.keysHint { model.keysHint = false; summon(); return }
        if bubbleOpen && !roaming { escape() } else { senseProject(); openBubble() }
    }

    func hover(_ inside: Bool) {
        hovering = inside
        if inside { noteActivity() }
        guard !bubbleOpen, !roaming, !dragging else { return }
        if !inside && approachNear { return }  // the cursor's still close: stay peeking
        slide(inside ? .peek : .tucked)
    }

    func buddyMoved() {
        if !dragging {
            dragging = true
            bubble.orderOut(nil)
        }
    }

    func buddyDropped() {
        dragging = false
        guard !roaming else { layoutBubble(); return }
        // Snap into whichever side bezel is closer.
        let f = buddy.frame
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: f.midX, y: f.midY)) } ?? dockScreen
        dockRight = f.midX > screen.frame.midX
        model.dockRight = dockRight
        dockY = f.minY
        UserDefaults.standard.set([dockRight ? 1 : 0, Double(dockY)], forKey: "dock")
        slide(bubbleOpen ? .out : .tucked) { [weak self] in self?.layoutBubble() }
    }

    /// Every way a tour or answer ends comes through here: highlight off, no more pointing, Pix home.
    func tearDownTour() {
        overlay.hide()
        avoid = nil
        if roaming { endRoaming() }
        model.look = CGVector(dx: dockRight ? -1 : 1, dy: 0)
    }

    func endRoaming() {
        guard roaming else { return }
        let home = dockOrigin(bubbleOpen ? .out : .tucked)
        glide(to: home) { [weak self] in
            guard let self else { return }
            self.roaming = false
            self.model.look = CGVector(dx: self.dockRight ? -1 : 1, dy: 0)
            if !self.bubbleOpen { self.slideHome() }  // tucks in properly (shape, menu bar face)
            self.layoutBubble()
        }
    }
}
