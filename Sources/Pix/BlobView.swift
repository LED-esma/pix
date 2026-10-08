import SwiftUI

/// The buddy: a soft gradient blob with two eyes. 64×64 window, 40pt blob in the middle.
struct BlobView: View {
    @ObservedObject var model: PixModel
    static let size = CGSize(width: 64, height: 64)
    static let radius: CGFloat = 20

    /// At rest the blob holds still and only redraws to blink, which keeps idle CPU near zero
    /// (each SwiftUI redraw costs ~9 ms; a steady 4 fps alone was ~4% CPU). Any motion it draws
    /// for itself (a morph, a jiggle, eyes gliding) asks for frames until it's done (PixModel.animate).
    private var resting: Bool {
        _ = model.motionTick  // re-checked when a motion ends
        return model.activity == .idle && !model.moving && Date() >= model.motionUntil
    }

    var body: some View {
        Group {
            if resting && !model.timers.isEmpty {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in canvas(ctx.date) }  // the timer ring ticks once a second
            } else if resting {
                TimelineView(BlinkSchedule()) { ctx in canvas(ctx.date) }
            } else {
                // In step with the display (up to 60 fps) rather than a fixed 40, which juddered on 120 Hz screens.
                TimelineView(.animation(minimumInterval: 1 / 60)) { ctx in canvas(ctx.date) }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .opacity(model.sleeping ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.6), value: model.sleeping)
        .accessibilityLabel("Pix")
    }

    private func canvas(_ date: Date) -> some View {
        let t = date.timeIntervalSinceReferenceDate
        let still = resting
        return Canvas(rendersAsynchronously: true) { g, size in draw(g, size: size, t: still ? 0 : t, clock: t, now: date) }
    }

    /// The blob, or (tucked in, with a hiding style) its quieter shape. Between the two it really
    /// morphs: the body squeezes into the shape with a little spring, the eyes slide into place.
    private func draw(_ g: GraphicsContext, size: CGSize, t: Double, clock: Double, now: Date) {
        let style = model.hideStyle
        let shaped = style != .blob && style != .menuBar
        let m = shaped ? model.morph(now) : 0
        if m <= 0.001 { drawBlob(g, size: size, t: t, clock: clock, now: now); return }
        let closed = eyesClosed(clock: clock, now: now)
        // The shape belongs on the bezel: while the window is still sliding, keep it there.
        let off = model.offTuck()
        let from = blobFigure(closed: closed, now: now), to = shapeFigure(style, closed: closed).offset(by: off)
        drawFigure(g, Figure.mix(from, to, m), glow: max(0, 1 - m), sliverGlow: style == .sliver ? min(1, m) : 0)
    }

    /// How shut the eyes are: 0 open, 1 closed. Blinks snap; falling asleep is slow, waking quick.
    private func eyesClosed(clock: Double, now: Date) -> Double {
        let blink = clock.truncatingRemainder(dividingBy: BlinkSchedule.period) < BlinkSchedule.length ? 1.0 : 0
        let a = now.timeIntervalSince(model.sleepChangedAt)
        let sleep = model.sleeping ? Ease.inOut(min(1, a / 0.7)) : 1 - Ease.out(min(1, a / 0.25))
        return max(blink, sleep)
    }

    // MARK: Figures (what a morph moves between)

    struct Figure {
        var body: CGRect
        var radius: CGFloat
        var bodyAlpha: Double = 1
        var eyes: [CGRect]          // left to right
        var halo: Double = 0        // purple rim around the eyes (Just Eyes)

        func offset(by v: CGVector) -> Figure {
            var f = self
            f.body = body.offsetBy(dx: v.dx, dy: v.dy)
            f.eyes = eyes.map { $0.offsetBy(dx: v.dx, dy: v.dy) }
            return f
        }

        static func mix(_ a: Figure, _ b: Figure, _ t: Double) -> Figure {
            let k = CGFloat(t)
            func l(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * k }
            func r(_ x: CGRect, _ y: CGRect) -> CGRect {
                CGRect(x: l(x.minX, y.minX), y: l(x.minY, y.minY), width: max(0, l(x.width, y.width)), height: max(0, l(x.height, y.height)))
            }
            return Figure(body: r(a.body, b.body), radius: max(0, l(a.radius, b.radius)),
                          bodyAlpha: min(1, max(0, a.bodyAlpha + (b.bodyAlpha - a.bodyAlpha) * t)),
                          eyes: zip(a.eyes, b.eyes).map { r($0, $1) }, halo: min(1, max(0, a.halo + (b.halo - a.halo) * t)))
        }
    }

    private func eye(_ center: CGPoint, w: CGFloat, h: CGFloat, closed: Double) -> CGRect {
        let hh = h + (1.4 - h) * CGFloat(closed)
        return CGRect(x: center.x - w / 2, y: center.y - hh / 2, width: w, height: hh)
    }

    /// The blob as a plain circle with its eyes: where a morph starts.
    private func blobFigure(closed: Double, now: Date) -> Figure {
        let c = CGPoint(x: Self.size.width / 2, y: Self.size.height / 2), r = Self.radius
        let look = model.shownLook(now)
        let ex = look.dx * 3.5, ey = look.dy * 2.5
        return Figure(body: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), radius: r,
                      eyes: [-1.0, 1.0].map { eye(CGPoint(x: c.x + $0 * 7 + ex, y: c.y - 2 + ey), w: 5, h: 8, closed: closed) })
    }

    /// Edge Pill, Just Eyes, Glow Sliver, Corner and Notch. The screen edge runs through the window
    /// where Placement.home put it, so each shape sits against that line.
    private func shapeFigure(_ style: HideStyle, closed: Double) -> Figure {
        let w = Self.size.width, c = CGPoint(x: w / 2, y: Self.size.height / 2)
        let right = model.dockRight, s: CGFloat = right ? -1 : 1  // s points into the screen
        let inset = (w - 2 * Self.radius) / 2
        let edge = right ? inset + style.shown : w - inset - style.shown
        func eyes(_ xs: [CGFloat], y: CGFloat, w ew: CGFloat = 2.6, h: CGFloat = 6) -> [CGRect] {
            xs.sorted().map { eye(CGPoint(x: $0, y: y), w: ew, h: h, closed: closed) }
        }
        switch style {
        case .pill:
            return Figure(body: CGRect(x: right ? edge - style.shown : edge - 8, y: c.y - 22, width: style.shown + 8, height: 44), radius: 7,
                          eyes: eyes([edge + s * 9, edge + s * 4], y: c.y - 1))
        case .eyes:
            let mid = CGPoint(x: edge + s * 6.25, y: c.y)
            return Figure(body: CGRect(origin: mid, size: .zero), radius: 0, bodyAlpha: 0,
                          eyes: eyes([edge + s * 9, edge + s * 3.5], y: c.y, w: 3.2, h: 8), halo: 1)
        case .sliver:
            return Figure(body: CGRect(x: edge - 4, y: c.y - 27, width: 8, height: 54), radius: 4,
                          eyes: [CGRect(x: edge, y: c.y - 6, width: 0, height: 0), CGRect(x: edge, y: c.y + 6, width: 0, height: 0)])
        case .corner:
            return Figure(body: CGRect(x: c.x - 24, y: c.y - 24, width: 48, height: 48), radius: 24,
                          eyes: eyes([c.x + s * 8, c.x + s * 14], y: c.y - 10))
        case .notch:
            return Figure(body: CGRect(x: c.x - 11, y: c.y - 7, width: 22, height: 14), radius: 7,
                          eyes: eyes([c.x - 3.5, c.x + 3.5], y: c.y, w: 2.4, h: 5))
        case .blob, .menuBar:
            return blobFigure(closed: closed, now: Date())
        }
    }

    private func drawFigure(_ g: GraphicsContext, _ f: Figure, glow: Double, sliverGlow: Double) {
        let colors = model.tint.colors
        let top = Color(red: colors.top.r, green: colors.top.g, blue: colors.top.b)
        let bottom = Color(red: colors.bottom.r, green: colors.bottom.g, blue: colors.bottom.b)
        let b = f.body
        if glow > 0.01 {  // the blob's glow fades as it squeezes in
            let gr = max(b.width, b.height) / 2 + 8, c = CGPoint(x: b.midX, y: b.midY)
            g.fill(Path(ellipseIn: CGRect(x: c.x - gr, y: c.y - gr, width: gr * 2, height: gr * 2)),
                   with: .radialGradient(Gradient(colors: [bottom.opacity(0.4 * glow), bottom.opacity(0)]), center: c, startRadius: 0, endRadius: gr))
        }
        if sliverGlow > 0.01 {  // Glow Sliver: a soft light around the line, brighter while a timer runs
            let k = model.timers.isEmpty ? 0.25 : 0.4
            g.fill(Path(roundedRect: b.insetBy(dx: -3, dy: -3), cornerRadius: f.radius + 3), with: .color(bottom.opacity(k * sliverGlow)))
        }
        if f.bodyAlpha > 0.01, b.width > 0.5, b.height > 0.5 {
            g.fill(Path(roundedRect: b, cornerRadius: min(f.radius, b.width / 2, b.height / 2)),
                   with: .linearGradient(Gradient(colors: [top.opacity(f.bodyAlpha), bottom.opacity(f.bodyAlpha)]),
                                         startPoint: CGPoint(x: b.midX, y: b.minY), endPoint: CGPoint(x: b.midX, y: b.maxY)))
        }
        for e in f.eyes where e.width > 0.3 && e.height > 0.3 {
            if f.halo > 0.01 {  // no body to sit on: a purple rim keeps the eyes visible on white pages
                let h = e.insetBy(dx: -1.5, dy: -1.5)
                g.fill(Path(roundedRect: h, cornerRadius: h.width / 2), with: .color(bottom.opacity(f.halo)))
            }
            g.fill(Path(roundedRect: e, cornerRadius: min(e.width, e.height) / 2), with: .color(.white))
        }
    }

    // MARK: The blob

    /// Stretch along a slide and a jiggle when it lands: (how much, which way). Zero with Reduce Motion.
    private func squash(_ now: Date) -> (CGFloat, CGVector) {
        guard !Motion.reduced else { return (0, model.moveDir) }
        if model.moving {
            let p = min(1, max(0, now.timeIntervalSince(model.moveStart) / max(model.moveDuration, 0.01)))
            return (CGFloat(0.09 * sin(.pi * p)), model.moveDir)
        }
        let a = now.timeIntervalSince(model.landedAt)
        guard a < 0.55 else { return (0, model.moveDir) }
        return (CGFloat(-0.07 * exp(-7 * a) * cos(18 * a)), model.moveDir)  // squashes against where it stopped, then settles
    }

    private func drawBlob(_ g: GraphicsContext, size: CGSize, t: Double, clock: Double, now: Date) {
        var g = g
        let thinking = model.activity == .thinking
        var c = CGPoint(x: size.width / 2, y: size.height / 2)
        // A happy hop when an answer lands.
        let ha = now.timeIntervalSince(model.happyAt)
        if model.activity == .happy, ha < 1.2, !Motion.reduced { c.y -= CGFloat(4 * abs(sin(ha * 7.5)) * exp(-2.8 * ha)) }
        let (k, dir) = squash(now)
        if abs(k) > 0.001 {
            let angle = atan2(dir.dy, dir.dx)
            g.translateBy(x: c.x, y: c.y)
            g.rotate(by: .radians(angle))
            g.scaleBy(x: 1 + k, y: 1 - k * 0.8)
            g.rotate(by: .radians(-angle))
            g.translateBy(x: -c.x, y: -c.y)
        }
        let breathe = 1 + 0.025 * sin(t * (thinking ? 4 : 1.8))
        let r = Self.radius * breathe
        let blob = Path(Blob.path(center: c, radius: r, time: t * (thinking ? 2.2 : 1), wobble: thinking ? 1.8 : 1))
        // Color follows the stage, cross-fading over 0.6 s.
        let f = min(1, max(0, now.timeIntervalSince(model.tintChangedAt) / 0.6))
        func mix(_ a: Tint.RGB, _ b: Tint.RGB) -> Color {
            Color(red: a.r + (b.r - a.r) * f, green: a.g + (b.g - a.g) * f, blue: a.b + (b.b - a.b) * f)
        }
        let from = model.previousTint.colors, to = model.tint.colors
        let top = mix(from.top, to.top)
        let bottom = mix(from.bottom, to.bottom)

        // Glow, body, sheen. Radial gradients instead of blur filters: same look, a fraction of the
        // drawing cost (blurs forced an offscreen pass every frame and kept idle CPU at ~4%).
        let glowAlpha = thinking ? 0.55 + 0.2 * sin(t * 4) : 0.4
        let glowR = r + (thinking ? 11 : 8)
        g.fill(Path(ellipseIn: CGRect(x: c.x - glowR, y: c.y - glowR, width: glowR * 2, height: glowR * 2)),
               with: .radialGradient(Gradient(stops: [.init(color: bottom.opacity(glowAlpha), location: r / glowR * 0.82),
                                                      .init(color: bottom.opacity(0), location: 1)]),
                                     center: c, startRadius: 0, endRadius: glowR))
        g.fill(blob, with: .linearGradient(Gradient(colors: [top, bottom]),
                                           startPoint: CGPoint(x: c.x, y: c.y - r), endPoint: CGPoint(x: c.x, y: c.y + r)))
        if let timer = model.timers.first {
            // What's left of the nearest timer, as a ring that empties clockwise.
            let left = timer.left()
            let ringR = r + 5
            var track = Path()
            track.addArc(center: c, radius: ringR, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            g.stroke(track, with: .color(bottom.opacity(0.18)), lineWidth: 2.5)
            var arc = Path()
            arc.addArc(center: c, radius: ringR, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * left), clockwise: false)
            g.stroke(arc, with: .color(bottom), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        var sheen = g
        sheen.clip(to: blob)
        let sc = CGPoint(x: c.x - r * 0.3, y: c.y - r * 0.62)
        sheen.fill(Path(ellipseIn: CGRect(x: sc.x - r * 0.62, y: sc.y - r * 0.42, width: r * 1.24, height: r * 0.84)),
                   with: .radialGradient(Gradient(colors: [.white.opacity(0.38), .white.opacity(0)]),
                                         center: sc, startRadius: 0, endRadius: r * 0.62))

        // Eyes look where Pix is headed (gliding there, not jumping), or up while thinking.
        var look = model.shownLook(now)
        if thinking { look = CGVector(dx: 0.4 * sin(t * 1.5), dy: -0.8) }
        let ex = look.dx * 3.5, ey = look.dy * 2.5
        let closed = thinking ? 0 : eyesClosed(clock: clock, now: now)
        for side in [-1.0, 1.0] {
            let center = CGPoint(x: c.x + CGFloat(side) * 7 + ex, y: c.y - 2 + ey)
            if model.activity == .happy {
                var arc = Path()
                arc.addArc(center: CGPoint(x: center.x, y: center.y + 2), radius: 3,
                           startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
                g.stroke(arc, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            } else {
                g.fill(Path(roundedRect: eye(center, w: 5, h: 8, closed: closed), cornerRadius: 2.5), with: .color(.white))
            }
        }

        // Needs you: a small dot that pulses.
        if model.activity == .alert {
            let d = 8 + 1.5 * sin(t * 6)
            let side: CGFloat = model.look.dx < 0 ? -1 : 1  // on the side facing the screen
            let dot = CGRect(x: c.x + side * r * 0.62 - d / 2, y: c.y - r * 0.95, width: d, height: d)
            g.fill(Path(ellipseIn: dot.insetBy(dx: -1.5, dy: -1.5)), with: .color(.white))
            g.fill(Path(ellipseIn: dot), with: .color(Color(red: 1, green: 0.36, blue: 0.55)))
        }
    }
}

/// Redraw moments for a resting blob: the start and end of each blink.
struct BlinkSchedule: TimelineSchedule {
    static let period = 4.6, length = 0.15

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let base = (start.timeIntervalSinceReferenceDate / Self.period).rounded(.down) * Self.period
        var n = 0
        return AnyIterator {
            defer { n += 1 }
            let cycle = Double(n / 2) + 1
            // Redraw a little inside the blink and a little after it, so rounding never leaves the eyes shut.
            return Date(timeIntervalSinceReferenceDate: base + cycle * Self.period + (n % 2 == 1 ? Self.length + 0.08 : 0.02))
        }
    }
}
