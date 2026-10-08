import AppKit
import SwiftUI

/// Pix's own graphing canvas. Drag or two-finger scroll to pan, pinch or mouse wheel to zoom,
/// double-click to fit, hover to read values.
final class GraphNSView: NSView {
    struct Curve { var expr: Expr; var color: NSColor }

    var curves: [Curve] = [] { didSet { needsDisplay = true } }
    var points: [Visual.Point] = [] { didSet { needsDisplay = true } }
    private(set) var xRange = -10.0...10.0
    private(set) var yRange = -10.0...10.0
    private var hover: CGPoint?
    private var dragStart: (CGPoint, ClosedRange<Double>, ClosedRange<Double>)?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways,
                                                               .inVisibleRect], owner: self))
    }

    // MARK: - Viewport

    /// Fits x to the given range (or −10…10) and y to what the curves and points actually do there.
    func fit(xmin: Double?, xmax: Double?) {
        var lo = xmin ?? -10, hi = xmax ?? 10
        if !points.isEmpty && xmin == nil && xmax == nil {
            let xs = points.map(\.x)
            lo = min(lo, xs.min()! - 2); hi = max(hi, xs.max()! + 2)
        }
        if hi <= lo { hi = lo + 1 }
        xRange = lo...hi
        yRange = GraphNSView.niceY(curves: curves.map(\.expr), points: points, x: xRange)
        keepAspect()
        needsDisplay = true
    }

    static func niceY(curves: [Expr], points: [Visual.Point], x: ClosedRange<Double>) -> ClosedRange<Double> {
        var ys = points.map(\.y)
        for e in curves {
            for i in 0...200 {
                let v = e.eval(x.lowerBound + (x.upperBound - x.lowerBound) * Double(i) / 200)
                if v.isFinite { ys.append(v) }
            }
        }
        guard !ys.isEmpty else { return -10...10 }
        ys.sort()
        // Ignore the wild ends (asymptotes) so the interesting part fills the view.
        let lo = ys[Int(Double(ys.count - 1) * 0.04)], hi = ys[Int(Double(ys.count - 1) * 0.96)]
        let pad: Double = max((hi - lo) * 0.15, 1)
        let bottom: Double = min(lo - pad, -pad * 0.3)  // keep the x-axis in view when it's close
        let top: Double = max(hi + pad, pad * 0.3)
        return bottom...top
    }

    /// Loosely keep 1:1 units when the ranges are similar, so circles look round.
    private func keepAspect() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let xs = xRange.upperBound - xRange.lowerBound, ys = yRange.upperBound - yRange.lowerBound
        let want = xs * Double(bounds.height / bounds.width)
        guard ys < want * 1.6, ys > want / 1.6 else { return }
        let mid = (yRange.lowerBound + yRange.upperBound) / 2
        yRange = (mid - want / 2)...(mid + want / 2)
    }

    private func px(_ x: Double) -> CGFloat {
        CGFloat((x - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound)) * bounds.width
    }
    private func py(_ y: Double) -> CGFloat {
        CGFloat((y - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound)) * bounds.height
    }
    private func vx(_ p: CGFloat) -> Double {
        xRange.lowerBound + Double(p / bounds.width) * (xRange.upperBound - xRange.lowerBound)
    }
    private func vy(_ p: CGFloat) -> Double {
        yRange.lowerBound + Double(p / bounds.height) * (yRange.upperBound - yRange.lowerBound)
    }

    private func zoom(by factor: Double, at p: CGPoint) {
        let cx = vx(p.x), cy = vy(p.y)
        xRange = (cx - (cx - xRange.lowerBound) * factor)...(cx + (xRange.upperBound - cx) * factor)
        yRange = (cy - (cy - yRange.lowerBound) * factor)...(cy + (yRange.upperBound - cy) * factor)
        needsDisplay = true
    }

    private func pan(dx: CGFloat, dy: CGFloat) {
        let ux = Double(dx / bounds.width) * (xRange.upperBound - xRange.lowerBound)
        let uy = Double(dy / bounds.height) * (yRange.upperBound - yRange.lowerBound)
        xRange = (xRange.lowerBound - ux)...(xRange.upperBound - ux)
        yRange = (yRange.lowerBound - uy)...(yRange.upperBound - uy)
        needsDisplay = true
    }

    /// Screen rect of a labeled point, for walkthroughs.
    func focusRect(_ target: String) -> NSRect? {
        let q = target.lowercased()
        guard let p = points.first(where: { !$0.label.isEmpty && ($0.label.lowercased().contains(q) || q.contains($0.label.lowercased())) }),
              let window else { return nil }
        let r = NSRect(x: px(p.x) - 13, y: py(p.y) - 13, width: 26, height: 26)
        return window.convertToScreen(convert(r, to: nil))
    }

    // MARK: - Input

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { fit(xmin: nil, xmax: nil); return }
        dragStart = (convert(e.locationInWindow, from: nil), xRange, yRange)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let (start, x0, y0) = dragStart else { return }
        let p = convert(e.locationInWindow, from: nil)
        xRange = x0; yRange = y0
        pan(dx: p.x - start.x, dy: p.y - start.y)
        hover = nil
    }

    override func mouseUp(with e: NSEvent) { dragStart = nil }

    override func scrollWheel(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if e.hasPreciseScrollingDeltas {
            pan(dx: e.scrollingDeltaX, dy: -e.scrollingDeltaY)  // trackpad: two fingers move the view
        } else {
            zoom(by: e.scrollingDeltaY > 0 ? 0.88 : 1 / 0.88, at: p)  // mouse wheel zooms
        }
    }

    override func magnify(with e: NSEvent) {
        zoom(by: 1 / (1 + e.magnification), at: convert(e.locationInWindow, from: nil))
    }

    override func mouseMoved(with e: NSEvent) {
        hover = convert(e.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with e: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        needsDisplay = true
    }

    // MARK: - Drawing

    static func step(for span: Double, pixels: CGFloat) -> Double {
        let raw = span / Double(max(pixels / 70, 1))  // a gridline every ~70 pt
        let mag = pow(10, floor(log10(raw)))
        for m in [1.0, 2, 5, 10] where m * mag >= raw { return m * mag }
        return 10 * mag
    }

    override func draw(_ dirty: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let xs = GraphNSView.step(for: xRange.upperBound - xRange.lowerBound, pixels: bounds.width)
        let ys = GraphNSView.step(for: yRange.upperBound - yRange.lowerBound, pixels: bounds.height)
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                    .foregroundColor: NSColor.secondaryLabelColor]

        // Grid: faint lines every step, fainter halves between.
        g.setLineWidth(1)
        for (step, alpha) in [(xs / 2, 0.05), (xs, 0.11)] {
            g.setStrokeColor(NSColor.labelColor.withAlphaComponent(alpha).cgColor)
            var x = (xRange.lowerBound / step).rounded(.up) * step
            while x <= xRange.upperBound { g.move(to: CGPoint(x: px(x), y: 0)); g.addLine(to: CGPoint(x: px(x), y: bounds.height)); x += step }
            g.strokePath()
        }
        for (step, alpha) in [(ys / 2, 0.05), (ys, 0.11)] {
            g.setStrokeColor(NSColor.labelColor.withAlphaComponent(alpha).cgColor)
            var y = (yRange.lowerBound / step).rounded(.up) * step
            while y <= yRange.upperBound { g.move(to: CGPoint(x: 0, y: py(y))); g.addLine(to: CGPoint(x: bounds.width, y: py(y))); y += step }
            g.strokePath()
        }

        // Axes, with tick labels kept on screen.
        let ax = min(max(px(0), 0), bounds.width), ay = min(max(py(0), 0), bounds.height)
        g.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.55).cgColor)
        g.setLineWidth(1.2)
        g.move(to: CGPoint(x: ax, y: 0)); g.addLine(to: CGPoint(x: ax, y: bounds.height))
        g.move(to: CGPoint(x: 0, y: ay)); g.addLine(to: CGPoint(x: bounds.width, y: ay))
        g.strokePath()
        var x = (xRange.lowerBound / xs).rounded(.up) * xs
        while x <= xRange.upperBound {
            if abs(x) > xs / 1000 {
                let s = Visual.num(x) as NSString
                let w = s.size(withAttributes: label).width
                let lx = min(max(px(x) - w / 2, 2), bounds.width - w - 2)  // never clip "−1" into "1"
                s.draw(at: CGPoint(x: lx, y: min(max(ay - 14, 2), bounds.height - 14)), withAttributes: label)
            }
            x += xs
        }
        var y = (yRange.lowerBound / ys).rounded(.up) * ys
        while y <= yRange.upperBound {
            if abs(y) > ys / 1000 {
                let s = Visual.num(y) as NSString
                let w = s.size(withAttributes: label).width
                s.draw(at: CGPoint(x: min(max(ax - w - 4, 2), bounds.width - w - 2), y: py(y) - 6), withAttributes: label)
            }
            y += ys
        }

        // Curves: one sample per point of width; break at gaps and asymptotes.
        g.setLineWidth(2.2)
        g.setLineJoin(.round)
        g.setLineCap(.round)
        for c in curves {
            g.setStrokeColor(c.color.cgColor)
            var drawing = false
            var last: CGFloat?
            var sx: CGFloat = 0
            while sx <= bounds.width {
                let v = c.expr.eval(vx(sx))
                let p = CGPoint(x: sx, y: py(v))
                if v.isFinite, let l = last, abs(p.y - l) < bounds.height * 1.5, drawing {
                    g.addLine(to: p)
                } else if v.isFinite {
                    g.move(to: p)
                    drawing = true
                } else {
                    drawing = false
                }
                last = v.isFinite ? p.y : nil
                sx += 1
            }
            g.strokePath()
        }

        // Points with labels.
        let pointLabel: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                         .foregroundColor: NSColor.labelColor]
        for p in points {
            let c = CGPoint(x: px(p.x), y: py(p.y))
            g.setFillColor(NSColor(red: 1, green: 0.36, blue: 0.55, alpha: 1).cgColor)
            g.fillEllipse(in: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
            let text = (p.label.isEmpty ? "" : p.label + " ") + "(\(Visual.num(p.x)), \(Visual.num(p.y)))"
            (text as NSString).draw(at: CGPoint(x: c.x + 7, y: c.y + 4), withAttributes: pointLabel)
        }

        // Hover: a guide line and each curve's value there.
        if let h = hover, dragStart == nil {
            let hx = vx(h.x)
            g.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.4).cgColor)
            g.setLineWidth(1)
            g.setLineDash(phase: 0, lengths: [3, 3])
            g.move(to: CGPoint(x: h.x, y: 0)); g.addLine(to: CGPoint(x: h.x, y: bounds.height))
            g.strokePath()
            g.setLineDash(phase: 0, lengths: [])
            for c in curves {
                let v = c.expr.eval(hx)
                guard v.isFinite else { continue }
                let p = CGPoint(x: h.x, y: py(v))
                g.setFillColor(c.color.cgColor)
                g.fillEllipse(in: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
                let s = "(\(Visual.num(hx)), \(Visual.num(v)))" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                            .foregroundColor: c.color]
                let w = s.size(withAttributes: attrs).width
                s.draw(at: CGPoint(x: h.x + 8 + w > bounds.width ? h.x - w - 8 : h.x + 8, y: p.y + 4), withAttributes: attrs)
            }
        }
    }
}

/// The graph tool: the canvas plus an editable list of functions, so you can add your own.
struct GraphTool: View {
    let functions: [String]
    let points: [Visual.Point]
    let xmin: Double?
    let xmax: Double?
    @State private var rows: [String] = []
    @State private var fresh = ""

    static let palette: [NSColor] = [
        NSColor(red: 0.39, green: 0.27, blue: 0.93, alpha: 1), NSColor(red: 0.95, green: 0.45, blue: 0.15, alpha: 1),
        NSColor(red: 0.13, green: 0.62, blue: 0.40, alpha: 1), NSColor(red: 0.17, green: 0.44, blue: 0.95, alpha: 1),
        NSColor(red: 0.85, green: 0.25, blue: 0.50, alpha: 1),
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        Circle().fill(Color(nsColor: Self.palette[i % Self.palette.count])).frame(width: 9, height: 9)
                        TextField("", text: $rows[i])
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Expr.parse(rows[i]) == nil ? Color.red : Color.primary)
                        Button { rows.remove(at: i) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                TextField("Add an equation", text: $fresh)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .onSubmit {
                        if Expr.parse(fresh) != nil { rows.append(fresh); fresh = "" }
                    }
                Spacer()
            }
            .frame(width: 170)
            .padding(10)
            GraphCanvas(rows: rows, points: points, xmin: xmin, xmax: xmax)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding([.vertical, .trailing], 10)
        }
        .onAppear { if rows.isEmpty { rows = functions } }
    }
}

private struct GraphCanvas: NSViewRepresentable {
    let rows: [String]
    let points: [Visual.Point]
    let xmin: Double?
    let xmax: Double?

    func makeNSView(context: Context) -> GraphNSView {
        let v = GraphNSView()
        update(v)
        BoardFocus.graph = v
        DispatchQueue.main.async { v.fit(xmin: xmin, xmax: xmax) }  // once it has a size
        return v
    }

    func updateNSView(_ v: GraphNSView, context: Context) { update(v) }

    private func update(_ v: GraphNSView) {
        v.curves = rows.enumerated().compactMap { i, s in
            Expr.parse(s).map { GraphNSView.Curve(expr: $0, color: GraphTool.palette[i % GraphTool.palette.count]) }
        }
        v.points = points
    }
}
