import CoreGraphics
import Foundation

// The buddy's shape and colors. CoreGraphics only, so the icon tool can share it.
enum Blob {
    static let top = (r: 0.67, g: 0.58, b: 1.00)
    static let bottom = (r: 0.39, g: 0.27, b: 0.93)

    /// A soft circle whose edge drifts slowly. `wobble` 0 is a perfect circle.
    static func path(center c: CGPoint, radius r: CGFloat, time t: Double, wobble: CGFloat = 1) -> CGPath {
        let p = CGMutablePath()
        let n = 72
        for i in 0...n {
            let a = Double(i) / Double(n) * 2 * .pi
            let k = 1 + wobble * CGFloat(0.035 * sin(3 * a + t * 1.3) + 0.025 * sin(5 * a - t * 0.9)
                                         + 0.02 * sin(2 * a + t * 0.7))
            let pt = CGPoint(x: c.x + r * k * CGFloat(cos(a)), y: c.y + r * k * CGFloat(sin(a)))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }
}
