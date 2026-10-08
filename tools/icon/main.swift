// Draws the app icon: the blob exactly as it sits on screen (BlobView at rest), same shape, colors,
// glow, sheen and eyes, scaled from its 64-point window. Eyes look straight ahead.
// Usage: draw <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ c: (r: Double, g: Double, b: Double), _ a: Double = 1) -> CGColor {
    CGColor(red: c.r, green: c.g, blue: c.b, alpha: a)
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px), k = s / 64  // BlobView draws in a 64×64 window
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let c = CGPoint(x: s / 2, y: s / 2)
    let r = 20 * k  // BlobView.radius

    // The same wobbly outline, flipped to match SwiftUI's y-down drawing.
    var flip = CGAffineTransform(translationX: 0, y: 2 * c.y).scaledBy(x: 1, y: -1)
    let blob = Blob.path(center: c, radius: r, time: 0, wobble: 1).copy(using: &flip)!

    // Glow: a radial fade of the bottom color, from just inside the edge to 8 points out.
    let glowR = r + 8 * k
    let glow = CGGradient(colorsSpace: space, colors: [color(Blob.bottom, 0.4), color(Blob.bottom, 0)] as CFArray,
                          locations: [r / glowR * 0.82, 1])!
    ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: glowR, options: [])

    // Body: top color to bottom color.
    ctx.saveGState()
    ctx.addPath(blob)
    ctx.clip()
    let body = CGGradient(colorsSpace: space, colors: [color(Blob.top), color(Blob.bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(body, start: CGPoint(x: c.x, y: c.y + r), end: CGPoint(x: c.x, y: c.y - r), options: [])

    // Sheen: a soft white highlight up and to the left.
    let sc = CGPoint(x: c.x - r * 0.3, y: c.y + r * 0.62)
    let sheen = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.38), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(sheen, startCenter: sc, startRadius: 0, endCenter: sc, endRadius: r * 0.62, options: [])
    ctx.restoreGState()

    // Eyes: 5 × 8 rounded bars, 7 points either side of center, 2 points above it.
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    for side in [-1.0, 1.0] {
        let e = CGRect(x: c.x + CGFloat(side) * 7 * k - 2.5 * k, y: c.y + 2 * k - 4 * k, width: 5 * k, height: 8 * k)
        ctx.addPath(CGPath(roundedRect: e, cornerWidth: 2.5 * k, cornerHeight: 2.5 * k, transform: nil))
    }
    ctx.fillPath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
