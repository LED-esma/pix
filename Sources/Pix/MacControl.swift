import AppKit
import ApplicationServices

/// Real hands for Mac settings and windows, each change with Undo, instead of scripts a model has to
/// get right. Settings macOS doesn't let an app flip directly (Bluetooth, Focus, brightness) say so and
/// point at the user's Shortcuts rather than pretending.
enum MacControl {
    typealias Reply = (text: String, error: Bool)
    static func ok(_ s: String) -> Reply { (s, false) }
    static func fail(_ s: String) -> Reply { (s, true) }
    static var run: String { ProcessInfo.processInfo.environment["PIX_RUN"] ?? "" }

    // MARK: Settings

    static func wifiDevice() -> String? {
        guard let out = BuiltIn.run("/usr/sbin/networksetup", ["-listallhardwareports"], timeout: 10) else { return nil }
        let lines = out.components(separatedBy: "\n")
        for (i, l) in lines.enumerated() where l.contains("Wi-Fi") || l.contains("AirPort") {
            if i + 1 < lines.count, lines[i + 1].hasPrefix("Device: ") { return String(lines[i + 1].dropFirst("Device: ".count)) }
        }
        return nil
    }

    static func setting(_ name: String, _ value: String) -> Reply {
        let on = ["on", "true", "yes", "1", "dark", "enable", "enabled"].contains(value.lowercased())
        switch name {
        case "dark_mode":
            let was = BuiltIn.osascript("tell application \"System Events\" to tell appearance preferences to get dark mode") == "true"
            guard BuiltIn.osascript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)") != nil else {
                return fail("Pix couldn't change the appearance (macOS may be asking to let Pix control System Events).")
            }
            Actions.log("mac_setting", "Turned dark mode \(on ? "on" : "off")", undo: ["type": "mac_setting", "name": name, "value": was ? "on" : "off"], run: run)
            return ok("Dark mode is \(on ? "on" : "off").")
        case "wifi":
            guard let dev = wifiDevice() else { return fail("This Mac has no Wi-Fi.") }
            let was = BuiltIn.run("/usr/sbin/networksetup", ["-getairportpower", dev], timeout: 10)?.hasSuffix("On") ?? true
            guard BuiltIn.run("/usr/sbin/networksetup", ["-setairportpower", dev, on ? "on" : "off"], timeout: 15) != nil else { return fail("Wi-Fi didn't change.") }
            Actions.log("mac_setting", "Turned Wi-Fi \(on ? "on" : "off")", undo: ["type": "mac_setting", "name": name, "value": was ? "on" : "off"], run: run)
            return ok("Wi-Fi is \(on ? "on" : "off").")
        case "mute":
            let was = BuiltIn.osascript("output muted of (get volume settings)") == "true"
            guard BuiltIn.osascript("set volume output muted \(on)") != nil else { return fail("The sound didn't change.") }
            Actions.log("mac_setting", on ? "Muted the sound" : "Unmuted the sound", undo: ["type": "mac_setting", "name": name, "value": was ? "on" : "off"], run: run)
            return ok(on ? "Muted." : "Unmuted.")
        case "wallpaper":
            guard let u = FileTools.url(value), FileManager.default.fileExists(atPath: u.path) else { return fail("No picture at \(value).") }
            let was = BuiltIn.osascript("tell application \"System Events\" to get picture of desktop 1") ?? ""
            let script = "on run argv\ntell application \"System Events\" to tell every desktop to set picture to (item 1 of argv)\nend run"
            guard BuiltIn.osascript(script, [u.path]) != nil else { return fail("The wallpaper didn't change.") }
            Actions.log("mac_setting", "Set the wallpaper to \(u.lastPathComponent)", undo: was.isEmpty ? nil : ["type": "mac_setting", "name": name, "value": was], run: run)
            return ok("Wallpaper set to \(u.lastPathComponent).")
        case "bluetooth", "focus", "do_not_disturb", "brightness", "night_shift":
            return fail("macOS doesn't let apps switch \(name.replacingOccurrences(of: "_", with: " ")) directly. If the user has a Shortcut for it, run that with shortcut_run (shortcuts_list shows them); otherwise say so.")
        default:
            return fail("Pix can change dark_mode, wifi, mute and wallpaper (volume has its own tool).")
        }
    }

    // MARK: Windows and apps

    static func app(_ name: String) -> NSRunningApplication? {
        let n = name.lowercased()
        return NSWorkspace.shared.runningApplications.first { $0.activationPolicy == .regular && ($0.localizedName?.lowercased() == n || $0.bundleIdentifier?.lowercased() == n) }
            ?? NSWorkspace.shared.runningApplications.first { $0.activationPolicy == .regular && ($0.localizedName?.lowercased().contains(n) ?? false) }
    }

    static func mainWindow(_ a: NSRunningApplication) -> AXUIElement? {
        let root = AXUIElementCreateApplication(a.processIdentifier)
        var w: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &w) == .success, let w { return (w as! AXUIElement) }
        var ws: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &ws) == .success else { return nil }
        return (ws as? [AXUIElement])?.first
    }

    /// Top-left (Accessibility) frame of a window.
    static func frame(_ w: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success, let p, let s else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    static func setFrame(_ w: AXUIElement, _ r: CGRect) {
        var pt = r.origin, sz = r.size
        if let p = AXValueCreate(.cgPoint, &pt) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, p) }
        if let s = AXValueCreate(.cgSize, &sz) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, s) }
    }

    /// A screen's usable area in Accessibility's top-left coordinates.
    static func axVisible(_ screen: NSScreen) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0, v = screen.visibleFrame
        return CGRect(x: v.minX, y: top - v.maxY, width: v.width, height: v.height)
    }

    static func screen(of r: CGRect) -> NSScreen {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let center = CGPoint(x: r.midX, y: top - r.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func window(_ appName: String, _ action: String) -> Reply {
        guard AXIsProcessTrusted() else { return fail("Pix needs Accessibility to arrange windows.") }
        guard let a = app(appName) else { return fail("\(appName) isn't open.") }
        let name = a.localizedName ?? appName
        switch action {
        case "quit":
            guard let url = a.bundleURL, a.terminate() else { return fail("\(name) didn't quit.") }
            Actions.log("app_window", "Quit \(name)", undo: ["type": "app_open", "path": url.path], run: run)
            return ok("Quit \(name).")
        case "hide":
            a.hide()
            Actions.log("app_window", "Hid \(name)", undo: ["type": "app_unhide", "app": name], run: run)
            return ok("Hid \(name).")
        case "show":
            a.unhide(); a.activate()
            return ok("\(name) is in front.")
        case "full_screen", "exit_full_screen", "minimize":
            guard let w = mainWindow(a) else { return fail("\(name) has no window.") }
            let attr = action == "minimize" ? kAXMinimizedAttribute : "AXFullScreen"
            let value = action != "exit_full_screen"
            AXUIElementSetAttributeValue(w, attr as CFString, value as CFTypeRef)
            Actions.log("app_window", action == "minimize" ? "Minimized \(name)" : "\(value ? "Made" : "Took") \(name) \(value ? "full screen" : "out of full screen")",
                        undo: ["type": "window_attr", "app": name, "attr": attr, "value": !value], run: run)
            return ok("Done: \(name) \(action.replacingOccurrences(of: "_", with: " ")).")
        case "other_display":
            guard NSScreen.screens.count > 1, let w = mainWindow(a), let f = frame(w) else { return fail("There's only one display.") }
            let here = screen(of: f)
            guard let there = NSScreen.screens.first(where: { $0 != here }) else { return fail("There's only one display.") }
            let v = axVisible(there)
            setFrame(w, CGRect(x: v.minX + 40, y: v.minY + 40, width: min(f.width, v.width - 80), height: min(f.height, v.height - 80)))
            Actions.log("app_window", "Moved \(name) to the other display", undo: ["type": "window_frame", "app": name, "frame": [f.minX, f.minY, f.width, f.height]], run: run)
            return ok("Moved \(name) to the other display.")
        default:
            return fail("Use quit, hide, show, full_screen, exit_full_screen, minimize or other_display.")
        }
    }

    static func sideBySide(_ left: String, _ right: String) -> Reply {
        guard AXIsProcessTrusted() else { return fail("Pix needs Accessibility to arrange windows.") }
        guard let l = app(left), let r = app(right) else { return fail("Open both apps first (\(left), \(right)).") }
        guard let lw = mainWindow(l), let rw = mainWindow(r), let lf = frame(lw), let rf = frame(rw) else { return fail("Both apps need a window.") }
        l.unhide(); r.unhide()
        let v = axVisible(screen(of: lf))
        setFrame(lw, CGRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height))
        setFrame(rw, CGRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height))
        Actions.log("app_window", "Put \(l.localizedName ?? left) and \(r.localizedName ?? right) side by side",
                    undo: ["type": "window_frames", "frames": [[l.localizedName ?? left, lf.minX, lf.minY, lf.width, lf.height],
                                                              [r.localizedName ?? right, rf.minX, rf.minY, rf.width, rf.height]]], run: run)
        return ok("\(l.localizedName ?? left) on the left, \(r.localizedName ?? right) on the right.")
    }

    // MARK: Undo (runs in the app)

    static func undo(_ u: [String: Any]) -> Bool {
        switch u["type"] as? String {
        case "mac_setting": return !setting(u["name"] as? String ?? "", u["value"] as? String ?? "").error
        case "app_open":
            guard let p = u["path"] as? String else { return false }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: p), configuration: NSWorkspace.OpenConfiguration())
            return true
        case "app_unhide": app(u["app"] as? String ?? "")?.unhide(); return true
        case "window_attr":
            guard let a = app(u["app"] as? String ?? ""), let w = mainWindow(a) else { return false }
            AXUIElementSetAttributeValue(w, (u["attr"] as? String ?? "") as CFString, (u["value"] as? Bool ?? false) as CFTypeRef)
            return true
        case "window_frame":
            guard let a = app(u["app"] as? String ?? ""), let w = mainWindow(a), let f = u["frame"] as? [Double], f.count == 4 else { return false }
            setFrame(w, CGRect(x: f[0], y: f[1], width: f[2], height: f[3]))
            return true
        case "window_frames":
            for row in u["frames"] as? [[Any]] ?? [] where row.count == 5 {
                guard let n = row[0] as? String, let a = app(n), let w = mainWindow(a) else { continue }
                let d = row.dropFirst().compactMap { ($0 as? NSNumber)?.doubleValue }
                if d.count == 4 { setFrame(w, CGRect(x: d[0], y: d[1], width: d[2], height: d[3])) }
            }
            return true
        default: return false
        }
    }
}
