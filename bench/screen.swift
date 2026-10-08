// Renders a stand-in 1512x982 screen: a desktop with a document window showing homework.
import AppKit
let W = 1512.0, H = 982.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(red: 0.30, green: 0.42, blue: 0.62, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
NSColor(white: 0.95, alpha: 1).setFill(); NSRect(x: 0, y: H - 33, width: W, height: 33).fill()
let win = NSRect(x: 220, y: 120, width: 1000, height: 760)
NSColor.white.setFill(); NSBezierPath(roundedRect: win, xRadius: 10, yRadius: 10).fill()
NSColor(white: 0.92, alpha: 1).setFill(); NSRect(x: win.minX, y: win.maxY - 52, width: win.width, height: 52).fill()
func text(_ s: String, _ x: Double, _ yTop: Double, _ size: Double, bold: Bool = false) {
    let f = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    (s as NSString).draw(at: NSPoint(x: x, y: H - yTop - size * 1.2), withAttributes: [.font: f, .foregroundColor: NSColor.black])
}
text("Homework 4.pdf", 640, 118, 15, bold: true)
text("Homework 4 — Algebra II", 270, 200, 24, bold: true)
text("Problem 3. Solve for x:", 270, 290, 20)
text("2x² − 8x + 6 = 0", 520, 360, 34)
text("Problem 4. A rectangle's length is 3 more than its width. Its area is 40 m². Find the width.", 270, 500, 18)
NSGraphicsContext.current = nil
try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
