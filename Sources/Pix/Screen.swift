import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Lite's eyes: screenshot the screen Pix is on, and turn the boxes Claude
/// returns into highlight rects in screen coordinates.
enum Screen {
    struct Shot {
        var jpeg: Data
        var imageSize: CGSize
        var pointsPerPixel: CGFloat
        var screenFrame: CGRect  // AppKit global coordinates
    }

    struct Step {
        var say: String
        var work = ""
        var why = ""
        var source = ""
        var visual: Int?  // board tool this step uses
        var focus = ""    // what to point at on that tool: a point label, "step 2", a slider name…
        var rect: CGRect?  // AppKit global coordinates, when the step points at something
    }

    enum GrabError: Error { case denied, failed }

    /// Worth stepping through: more than one step, or a step that points at something (on screen or the board).
    /// A lone step that only restates the answer showed the same words twice.
    static func walkthrough(_ steps: [Step]) -> Bool {
        steps.count > 1 || steps.contains { $0.rect != nil || $0.visual != nil || !$0.focus.isEmpty }
    }

    // MARK: - Capture

    static func capture(_ screen: NSScreen) async throws -> Shot {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw GrabError.denied
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw GrabError.denied
        }
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first
        else { throw GrabError.failed }
        // Leave Pix itself out of the picture.
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let pts = screen.frame.size
        let scale = min(1, 1568 / max(pts.width, pts.height))  // API's preferred max edge
        let config = SCStreamConfiguration()
        config.width = Int(pts.width * scale)
        config.height = Int(pts.height * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let jpeg = NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { throw GrabError.failed }
        return Shot(jpeg: jpeg, imageSize: CGSize(width: config.width, height: config.height),
                    pointsPerPixel: 1 / scale, screenFrame: screen.frame)
    }

    static func context(_ shot: Shot) -> String {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        return "Screenshot: \(Int(shot.imageSize.width))x\(Int(shot.imageSize.height)) pixels. Frontmost app: \(app)."
    }

    // MARK: - Answer → steps

    static func steps(from output: [String: Any], shot: Shot?, snap: Bool) -> [Step] {
        (output["steps"] as? [[String: Any]] ?? []).compactMap { s in
            guard let say = s["say"] as? String else { return nil }
            var step = Step(say: say, work: s["work"] as? String ?? "", why: s["why"] as? String ?? "",
                            source: s["source"] as? String ?? "", visual: (s["visual"] as? NSNumber)?.intValue,
                            focus: s["focus"] as? String ?? "")
            func n(_ k: String) -> Double? { (s[k] as? NSNumber)?.doubleValue }
            if let shot, let x = n("x"), let y = n("y") {
                let box = rect(x: x, y: y, w: n("w") ?? 60, h: n("h") ?? 24, shot: shot)
                step.rect = snap ? snapped(box) : box
            }
            return step
        }
    }

    /// Screenshot box (top-left x,y + size, in pixels) → AppKit global rect, padded a little.
    static func rect(x: Double, y: Double, w: Double, h: Double, shot: Shot) -> CGRect {
        let k = shot.pointsPerPixel
        let pw = max(CGFloat(w) * k, 16), ph = max(CGFloat(h) * k, 14)
        let minX = shot.screenFrame.minX + CGFloat(x) * k
        let maxY = shot.screenFrame.maxY - CGFloat(y) * k
        return CGRect(x: minX, y: maxY - ph, width: pw, height: ph).insetBy(dx: -5, dy: -4)
    }

    /// Swap Claude's box for the real element's frame when Accessibility allows it
    /// and the element is about the same size (so a box around text in a page stays put).
    static func snapped(_ guess: CGRect) -> CGRect {
        guard AXIsProcessTrusted(), let primary = NSScreen.screens.first else { return guess }
        let flip = primary.frame.maxY
        let center = CGPoint(x: guess.midX, y: flip - guess.midY)  // AX uses top-left origin
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(center.x), Float(center.y),
                                               &element) == .success, let element else { return guess }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier, let frame = axFrame(element) else { return guess }
        let r = CGRect(x: frame.minX, y: flip - frame.maxY, width: frame.width, height: frame.height)
        let ratio = (r.width * r.height) / max(guess.width * guess.height, 1)
        guard r.width >= 10, r.height >= 10, (0.25...4).contains(ratio),
              r.insetBy(dx: -4, dy: -4).contains(CGPoint(x: guess.midX, y: guess.midY)) else { return guess }
        return r.insetBy(dx: -3, dy: -3)
    }

    private static func axFrame(_ e: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }
}

/// Where the card and the buddy go, kept pure so the self-check can test it.
enum Placement {
    static let gap: CGFloat = 6

    /// Beside the blob, on the side facing into the screen first, slid if needed
    /// to stay clear of a highlight. Always stays level with or next to the blob.
    static func card(size: CGSize, anchor a: CGRect, screen: CGRect, avoid: CGRect?) -> CGPoint {
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, screen.minX + 8), screen.maxX - size.width - 8) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, screen.minY + 8), screen.maxY - size.height - 8) }
        let ys = [a.midY - size.height / 2, a.maxY - size.height] + (avoid.map { [$0.maxY + gap, $0.minY - gap - size.height] } ?? [])
        let xs = [a.midX - size.width / 2] + (avoid.map { [$0.maxX + gap, $0.minX - gap - size.width] } ?? [])
        let left = a.minX - gap - size.width, right = a.maxX + gap
        let sides = a.midX > screen.midX ? [left, right] : [right, left]

        var options: [CGPoint] = []
        for x in sides {
            for y in ys where y <= a.maxY && y + size.height >= a.minY { options.append(CGPoint(x: x, y: clampY(y))) }
        }
        for x in xs where x <= a.maxX && x + size.width >= a.minX {
            options.append(CGPoint(x: clampX(x), y: a.maxY + gap))
            options.append(CGPoint(x: clampX(x), y: a.minY - gap - size.height))
        }
        func fits(_ o: CGPoint) -> Bool { screen.contains(CGRect(origin: o, size: size).insetBy(dx: 1, dy: 1)) }
        func clear(_ o: CGPoint) -> Bool { avoid.map { !$0.intersects(CGRect(origin: o, size: size)) } ?? true }
        return options.first { fits($0) && clear($0) } ?? options.first(where: fits)
            ?? CGPoint(x: clampX(sides[0]), y: clampY(ys[0]))
    }

    /// A spot for the buddy right beside a highlighted rect, fully on screen.
    static func buddySpot(beside r: CGRect, buddy size: CGSize, screen: CGRect) -> CGPoint {
        let options = [
            CGPoint(x: r.maxX + 4, y: r.midY - size.height / 2),
            CGPoint(x: r.minX - 4 - size.width, y: r.midY - size.height / 2),
            CGPoint(x: r.midX - size.width / 2, y: r.minY - 2 - size.height),
            CGPoint(x: r.midX - size.width / 2, y: r.maxY + 2),
        ]
        let ok = options.first { screen.contains(CGRect(origin: $0, size: size)) } ?? options[0]
        return CGPoint(x: min(max(ok.x, screen.minX), screen.maxX - size.width),
                       y: min(max(ok.y, screen.minY), screen.maxY - size.height))
    }

    /// Where the blob's window sits on a screen edge: tucked into the bezel, peeking, or out.
    enum Dock { case tucked, peek, out }

}
