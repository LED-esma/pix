import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Pix using your Mac's apps: it reads the front app's buttons, fields and menus through
/// Accessibility (text, so it's cheap and works on a model on this Mac, no screenshots), then either
/// does the steps itself (Do It: screen_click, screen_type, screen_key) or rings each thing for you to
/// click and waits until you do (Show Me: screen_show). Lives in the app, so Accessibility is Pix's
/// own permission; the tools reach it through the Bridge.
@MainActor
final class ScreenControl {
    static let shared = ScreenControl()
    weak var controller: PixController?

    private var elements: [AXUIElement] = []
    private var labels: [String] = []
    private var texts: [String] = []  // what the window shows (a calculator's display, a status line)
    private var window: AXUIElement?
    private var pid: pid_t = 0
    /// The last app you used other than Pix: what "the screen" means while Pix's card has the focus.
    private var lastApp: NSRunningApplication?
    /// The last screen_see: where its pixel (0, 0) sits on screen (Accessibility's top-left points) and
    /// how many points one pixel is, so "x, y in the screenshot" becomes a spot on screen.
    var seen: (origin: CGPoint, pointsPerPixel: CGFloat, size: CGSize)?
    /// Chromium and Electron apps only build their page's accessibility tree once asked to.
    private var awakened: Set<pid_t> = []
    /// The window being read: things scrolled out of it (most of a long web page) aren't listed.
    private var visibleArea: CGRect?
    private var emptyPage = false
    private var justAwakened = false

    init() {
        NotificationCenter.default.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { ScreenControl.shared.lastApp = app }
            }
        }
    }

    /// What a run lets the model choose when the user's words don't say: point (Show Me) or do it.
    nonisolated static var mode: String {
        get { UserDefaults.standard.string(forKey: "screen.mode") ?? "show" }
        set { UserDefaults.standard.set(newValue, forKey: "screen.mode") }
    }

    // MARK: Look

    private static let actionable: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXTextArea",
        "AXComboBox", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXSlider", "AXIncrementor", "AXDisclosureTriangle",
        "AXSecureTextField", "AXSearchField", "AXRow", "AXCell", "AXTab", "AXSwitch", "AXToggle", "AXColorWell", "AXDockItem"]
    private static let roleWords: [String: String] = [
        "AXButton": "button", "AXCheckBox": "checkbox", "AXRadioButton": "option", "AXPopUpButton": "pop-up", "AXMenuButton": "menu button",
        "AXTextField": "text field", "AXTextArea": "text area", "AXComboBox": "combo box", "AXLink": "link", "AXMenuItem": "menu item",
        "AXMenuBarItem": "menu", "AXSlider": "slider", "AXIncrementor": "stepper", "AXDisclosureTriangle": "disclosure",
        "AXSecureTextField": "password field", "AXSearchField": "search field", "AXRow": "row", "AXCell": "cell", "AXTab": "tab",
        "AXSwitch": "switch", "AXToggle": "switch", "AXColorWell": "color well", "AXDockItem": "dock item"]

    private func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    private func string(_ e: AXUIElement, _ name: String) -> String? {
        (attr(e, name) as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }
    private func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

    /// Top-left screen coordinates, as Accessibility reports them.
    private func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    /// What a person would call it: its title, description, value, placeholder, or the text inside it.
    private func name(_ e: AXUIElement, role: String) -> String {
        if let t = string(e, kAXTitleAttribute) ?? string(e, kAXDescriptionAttribute) { return t }
        if role != "AXTextField" && role != "AXTextArea", let v = string(e, kAXValueAttribute) { return v }
        if let p = string(e, kAXPlaceholderValueAttribute) ?? string(e, kAXHelpAttribute) { return p }
        for c in children(e).prefix(6) {
            if let t = string(c, kAXValueAttribute) ?? string(c, kAXTitleAttribute) ?? string(c, kAXDescriptionAttribute) { return t }
        }
        return ""
    }

    /// The window to read: the focused one, else the main one, else the first (an app in the background
    /// often reports no focused window).
    private func frontWindow(_ root: AXUIElement) -> AXUIElement? {
        for key in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let w = attr(root, key) { return (w as! AXUIElement) }
        }
        return (attr(root, kAXWindowsAttribute) as? [AXUIElement])?.first { (attr($0, kAXMinimizedAttribute) as? Bool) != true }
    }

    private var target: NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != me { return f }
        return lastApp
    }

    /// `vision`: this run's AI can see screenshots (Claude), so an app with nothing to read gets screen_see.
    func look(app named: String? = nil, vision: Bool = true, retry: Bool = true) -> (String, Bool) {
        guard AXIsProcessTrusted() else {
            return ("Pix doesn't have Accessibility yet, so it can't see the screen's buttons. ACCESS_NEEDED:accessibility", true)
        }
        let byPid = named.flatMap { $0.hasPrefix("pid:") ? pid_t($0.dropFirst(4)) : nil }.flatMap { NSRunningApplication(processIdentifier: $0) }  // tests
        let app = byPid ?? named.flatMap { n in NSWorkspace.shared.runningApplications.first { $0.localizedName?.localizedCaseInsensitiveCompare(n) == .orderedSame } } ?? target
        guard let app else { return ("No app is in front.", true) }
        pid = app.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        // Web pages in Chrome, Edge, Brave, Arc and Electron apps: ask for the page's tree (Safari always has it).
        if !awakened.contains(pid) {
            awakened.insert(pid)
            let manual = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            let enhanced = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            Log.app.info("web accessibility: manual \(manual.rawValue) enhanced \(enhanced.rawValue)")
            if ProcessInfo.processInfo.environment["PIX_AXDEBUG"] != nil { FileHandle.standardError.write(Data("manual \(manual.rawValue) enhanced \(enhanced.rawValue)\n".utf8)) }
            if manual == .success || enhanced == .success {
                Thread.sleep(forTimeInterval: 0.8)  // the page's tree takes a moment to build the first time
                justAwakened = true
            }
        }
        visibleArea = frontWindow(root).flatMap { frame($0) }
        elements = []
        emptyPage = false
        labels = []
        texts = []
        var lines: [String] = []
        let window = frontWindow(root)
        lines.append("App: \(app.localizedName ?? "?")" + (window.flatMap { string($0, kAXTitleAttribute) }.map { " · window “\($0)”" } ?? ""))

        func add(_ e: AXUIElement, role: String) {
            guard elements.count < 150, let f = frame(e), f.width > 1, f.height > 1 else { return }
            if let v = visibleArea, role != "AXMenuItem", role != "AXMenuBarItem", !f.intersects(v) { return }  // scrolled out of view
            let label = name(e, role: role)
            let word = Self.roleWords[role] ?? role
            if label.isEmpty && (role == "AXRow" || role == "AXCell") { return }
            elements.append(e)
            labels.append(label)
            var line = "[\(elements.count)] \(word)" + (label.isEmpty ? "" : " “\(label.prefix(80))”")
            if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" || role == "AXSearchField",
               let v = string(e, kAXValueAttribute) { line += " = “\(v.prefix(60))”" }
            if role == "AXCheckBox" || role == "AXSwitch" || role == "AXToggle", let v = attr(e, kAXValueAttribute) as? NSNumber { line += v.boolValue ? " (on)" : " (off)" }
            if (attr(e, kAXEnabledAttribute) as? Bool) == false { line += " (dimmed)" }
            lines.append(line)
        }
        // An open menu comes first: that's where the next click goes.
        var open: [AXUIElement] = []
        if let bar = attr(root, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) {
            for item in children(bar) {
                for menu in children(item) where (attr(menu, kAXRoleAttribute) as? String) == "AXMenu" && !children(menu).isEmpty
                    && (frame(menu)?.width ?? 0) > 1 { open.append(menu) }
            }
            if !open.isEmpty { lines.append("Open menu:") }
            for menu in open { walk(menu, depth: 0, add: add) }
            lines.append("Menu bar:")
            for item in children(bar).dropFirst() { add(item, role: "AXMenuBarItem") }  // the Apple menu is skipped
        }
        self.window = window
        if let window {
            cueWindow(window)
            lines.append("Window:")
            walk(window, depth: 0, add: add)
            if !texts.isEmpty { lines.append("Text on screen: " + texts.map { "“\($0)”" }.joined(separator: " · ")) }
        }
        // A browser that hasn't built its page tree yet (Chrome does once it notices a reader): one more try.
        let inWindow = elements.count - lines.prefix { $0 != "Window:" }.filter { $0.hasPrefix("[") }.count
        if (emptyPage || (justAwakened && inWindow < 6)), retry {
            justAwakened = false
            emptyPage = false
            Thread.sleep(forTimeInterval: 1.0)
            return look(app: named, vision: vision, retry: false)
        }
        if elements.count < 3 {  // a canvas, game or drawing app: nothing to read as text
            let next = !vision
                ?"This app doesn't show its controls as text, so it needs Claude: reply with exactly NEEDS_CLAUDE."
                : "This app doesn't show its controls as text: call screen_see to look at it, then screen_click_at or screen_show_at."
            return (lines.joined(separator: "\n") + "\n" + next, false)
        }
        if elements.count >= 150 { lines.append("(more not listed)") }
        return (lines.joined(separator: "\n"), false)
    }

    private func walk(_ e: AXUIElement, depth: Int, add: (AXUIElement, String) -> Void) {
        guard depth < 30, elements.count < 150 else { return }
        let role = attr(e, kAXRoleAttribute) as? String ?? ""
        if ProcessInfo.processInfo.environment["PIX_AXDEBUG"] != nil {
            FileHandle.standardError.write(Data((String(repeating: " ", count: depth) + role + " " + String((string(e, kAXTitleAttribute) ?? string(e, kAXDescriptionAttribute) ?? "").prefix(30)) + " children \(children(e).count) frame \(frame(e).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none") area \(visibleArea.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none")\n").utf8))
        }
        var r = role
        if let sub = attr(e, kAXSubroleAttribute) as? String {
            if sub == "AXSearchField" { r = "AXSearchField" }
            if sub == "AXSwitch" || sub == "AXToggle" { r = "AXSwitch" }
            if sub == "AXTabButton" { r = "AXTab" }
        }
        if Self.actionable.contains(r) { add(e, r) }
        if role == "AXWebArea", children(e).isEmpty { emptyPage = true }
        if role == "AXStaticText", texts.count < 15, let v = string(e, kAXValueAttribute), v.count <= 80 { texts.append(v) }
        if role == "AXMenuItem" { return }  // a submenu's items show once it's open
        for c in children(e) { walk(c, depth: depth + 1, add: add) }
    }

    private func element(_ n: Int) -> AXUIElement? { elements.indices.contains(n - 1) ? elements[n - 1] : nil }

    /// After acting: just what the window shows now, not the whole list again (each full list costs
    /// the model a turn's worth of reading). The numbers stay valid until screen_look.
    private func now() -> String {
        guard let window else { return look().0 }
        var shown: [String] = []
        func collect(_ e: AXUIElement, _ depth: Int) {
            guard depth < 30, shown.count < 15 else { return }
            if (attr(e, kAXRoleAttribute) as? String) == "AXStaticText", let v = string(e, kAXValueAttribute), v.count <= 80 { shown.append(v) }
            for c in children(e) { collect(c, depth + 1) }
        }
        collect(window, 0)
        let title = string(window, kAXTitleAttribute).map { "Window “\($0)”. " } ?? ""
        return title + (shown.isEmpty ? "Call screen_look to see what changed." : "Text on screen: " + shown.map { "“\($0)”" }.joined(separator: " · ")
            + ". Numbers from the last look still work; call screen_look if a new window or menu opened.")
    }

    /// Accessibility's top-left rect as AppKit's bottom-left one.
    private func appKitRect(_ f: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height)
    }

    /// So you can see where Pix is working: the blob glides beside the thing and rings it first.
    private func cue(_ e: AXUIElement, label: String? = nil) async {
        guard let f = frame(e), let controller else { return }
        controller.workHere(appKitRect(f).insetBy(dx: -4, dy: -4), label: label)
        try? await Task.sleep(for: .milliseconds(controller.roaming ? 350 : 650))  // a beat to see it before it happens
    }

    /// Reading a window: a ring around it for a moment.
    private func cueWindow(_ w: AXUIElement) {
        guard let f = frame(w), let controller else { return }
        controller.readHere(appKitRect(f))
    }
    func label(_ n: Int) -> String { labels.indices.contains(n - 1) ? labels[n - 1] : "" }

    // MARK: Do It

    /// Clicks [n], then each of `then` in order (one turn for "4, 5, +, 1, 7, =").
    func click(_ n: Int, then more: [Int] = []) async -> (String, Bool) {
        var done: [String] = []
        for i in [n] + more {
            guard let e = element(i) else { return ((done.isEmpty ? "" : "Clicked " + done.joined(separator: ", ") + ". ") + "No [\(i)] on the screen; look again.", true) }
            let name = label(i)
            await cue(e, label: name.isEmpty ? nil : "Clicking “\(name)”")
            if AXUIElementPerformAction(e, kAXPressAction as CFString) != .success {
                guard let f = frame(e) else { return ("Couldn't click “\(name)”.", true) }
                let c = CGPoint(x: f.midX, y: f.midY)
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            done.append("“\(name)”")
            try? await Task.sleep(for: .milliseconds(more.isEmpty ? 450 : 200))
        }
        return ("Clicked " + done.joined(separator: ", ") + ". " + now(), false)
    }

    func type(_ n: Int, _ text: String, submit: Bool) async -> (String, Bool) {
        guard let e = element(n) else { return ("No [\(n)] on the screen; look again.", true) }
        let role = attr(e, kAXRoleAttribute) as? String ?? "", sub = attr(e, kAXSubroleAttribute) as? String ?? ""
        if role == "AXSecureTextField" || sub == "AXSecureTextField" { return ("That's a password field: the user types passwords themselves.", true) }
        await cue(e, label: "Typing")
        AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, text as CFTypeRef) != .success { typeKeys(text) }
        if submit { press(keyCode: 36, flags: []) }
        try? await Task.sleep(for: .milliseconds(350))
        return ("Typed into “\(label(n))”." + (submit ? " Pressed Return. " + now() : ""), false)
    }

    private func typeKeys(_ text: String) {
        for ch in text.utf16 {
            var c = ch
            for down in [true, false] {
                let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                ev?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                ev?.post(tap: .cghidEventTap)
            }
        }
    }

    nonisolated private static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, ",": 43, ".": 47, "/": 44]

    /// "cmd+shift+s" → (code, flags)
    nonisolated static func parse(_ keys: String) -> (CGKeyCode, CGEventFlags)? {
        var flags: CGEventFlags = []
        var code: CGKeyCode?
        for part in keys.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: code = keyCodes[part]
            }
        }
        return code.map { ($0, flags) }
    }

    private func press(keyCode: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
            ev?.flags = flags
            ev?.post(tap: .cghidEventTap)
        }
    }

    func key(_ keys: String) async -> (String, Bool) {
        guard let (code, flags) = Self.parse(keys) else { return ("Unknown keys “\(keys)”. Use e.g. cmd+s, return, escape, down.", true) }
        if let app = target { app.activate() }
        try? await Task.sleep(for: .milliseconds(120))
        press(keyCode: code, flags: flags)
        try? await Task.sleep(for: .milliseconds(400))
        return ("Pressed \(keys). " + now(), false)
    }

    // MARK: Show Me

    /// Rings [n], says what to do on the card, and waits for the user to click it (or 90 seconds).
    func show(_ n: Int, say: String) async -> (String, Bool) {
        guard let e = element(n), let f = frame(e), let controller else { return ("No [\(n)] on the screen; look again.", true) }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let rect = CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height)  // AppKit's bottom-left origin
        let clicked = await controller.showStep(rect, say: say.isEmpty ? "Click “\(label(n))”" : say)
        guard clicked else { return ("The user didn't click it within 90 seconds (or stopped). Ask whether they want you to do it instead.", false) }
        try? await Task.sleep(for: .milliseconds(450))
        return ("The user clicked it. Now:\n" + look().0, false)
    }

    // MARK: Asking first

    private static let risky = ["send", "buy", "purchase", "pay", "order", "checkout", "check out", "delete", "remove", "erase",
                                "empty trash", "trash", "sign in", "log in", "sign out", "submit", "post", "publish", "transfer", "confirm",
                                "subscribe", "unsubscribe", "uninstall", "format", "reset", "discard", "don't save", "replace"]

    /// The question to ask before a click or keys that can't be taken back, or nil when it's safe.
    func risk(tool: String, input: [String: Any]) -> String? {
        let name = tool.replacingOccurrences(of: BuiltIn.prefix, with: "")
        let n = (input["n"] as? NSNumber)?.intValue ?? -1
        switch name {
        case "screen_click", "screen_type":
            let all = [n] + ((input["then"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            let l = all.map { label($0).lowercased() }.joined(separator: " | ")
            let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "this app"
            if name == "screen_type", (input["submit"] as? Bool) != true { return nil }
            guard Self.risky.contains(where: { l.contains($0) }) else { return nil }
            let hit = all.first { i in Self.risky.contains { label(i).lowercased().contains($0) } } ?? n
            return "Click “\(label(hit))” in \(app)?"
        case "screen_click_at":
            // By position: what the AI says it's clicking, and the control the app reports there.
            let x = (input["x"] as? NSNumber)?.doubleValue ?? -1, y = (input["y"] as? NSNumber)?.doubleValue ?? -1
            let what = input["what"] as? String ?? ""
            let l = (what + " | " + label(atX: x, y: y)).lowercased()
            guard Self.risky.contains(where: { l.contains($0) }) else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "this app"
            return "Click “\(what.isEmpty ? label(atX: x, y: y) : what)” in \(app)?"
        case "screen_key":
            let k = (input["keys"] as? String ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            return ["cmd+delete", "cmd+backspace", "cmd+q", "cmd+shift+delete", "cmd+option+escape"].contains(k) ? "Press \(k)?" : nil
        default: return nil
        }
    }

    nonisolated static let acts: Set<String> = ["screen_click", "screen_type", "screen_key", "screen_click_at", "screen_drag", "screen_scroll"]
}

extension PixController {
    /// Something only the user can do (sign in, an "are you human" check): the card says what, with
    /// Continue, and Pix waits (10 minutes at most; Stop ends it).
    func waitForUser(_ say: String) async -> Bool {
        model.liveStep = say
        model.waitingUser = true
        speakIfWanted(say)
        needsYou()
        defer { model.liveStep = nil; model.waitingUser = false; model.activity = .thinking; userContinue = nil }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            var finished = false
            func finish(_ v: Bool) {
                guard !finished else { return }
                finished = true
                c.resume(returning: v)
            }
            userContinue = { finish(true) }
            stepCancel = { finish(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) { finish(false) }
        }
    }

    /// Do It: glide beside what's about to be clicked or typed into, and ring it.
    func workHere(_ rect: CGRect, label: String? = nil) {
        guard model.isBusy else { return }
        point(at: rect)
        overlay.say(label, at: rect, on: NSScreen.screens.first { $0.frame.intersects(rect) } ?? dockScreen)
    }

    /// Reading a window: ring it briefly (the blob stays put; it's only looking).
    func readHere(_ rect: CGRect) {
        guard model.isBusy, !roaming else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? dockScreen
        overlay.show(rect, on: screen)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, !self.roaming else { return }
            self.overlay.hide()
        }
    }

    /// Show Me: ring the thing, put the step on the card, and wait until it's clicked.
    func showStep(_ rect: CGRect, say: String) async -> Bool {
        point(at: rect.insetBy(dx: -4, dy: -4))  // the blob goes there and rings it; the hand and label say the step
        overlay.say(say, at: rect.insetBy(dx: -4, dy: -4), on: NSScreen.screens.first { $0.frame.intersects(rect) } ?? dockScreen)
        model.liveStep = say
        defer { model.liveStep = nil }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            var finished = false
            var monitor: Any?
            func finish(_ v: Bool) {
                guard !finished else { return }
                finished = true
                if let monitor { NSEvent.removeMonitor(monitor) }
                c.resume(returning: v)
            }
            // A click anywhere inside the ring counts (clicks in other apps arrive here as global events).
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
                let p = NSEvent.mouseLocation
                MainActor.assumeIsolated { if rect.insetBy(dx: -6, dy: -6).contains(p) { finish(true) } }
            }
            stepCancel = { finish(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { finish(false) }
        }
    }
}

// MARK: - Seeing (Claude only): a screenshot, and acting by position in it


extension ScreenControl {
    /// A picture of the window in front (a little around it, so a menu or pop-up it opened shows too),
    /// at most 1,280 pixels on its long side to keep each look cheap.
    func see(app named: String? = nil) async -> (String, Bool, Data?) {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return ("Pix needs Screen Recording to see the screen. ACCESS_NEEDED:screen", true, nil)
        }
        let app = named.flatMap { n in NSWorkspace.shared.runningApplications.first { $0.localizedName?.localizedCaseInsensitiveCompare(n) == .orderedSame } } ?? target
        guard let app else { return ("No app is in front.", true, nil) }
        pid = app.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        window = frontWindow(root)
        var displays = [CGDirectDisplayID](repeating: 0, count: 8), count: UInt32 = 0
        CGGetActiveDisplayList(8, &displays, &count)
        let main = CGMainDisplayID()
        var area = window.flatMap { frame($0) }?.insetBy(dx: -30, dy: -30) ?? CGDisplayBounds(main)
        let id = displays.prefix(Int(count)).first { CGDisplayBounds($0).contains(CGPoint(x: area.midX, y: area.midY)) } ?? main
        let bounds = CGDisplayBounds(id)
        area = area.intersection(bounds)
        guard area.width > 20, area.height > 20,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == id }) else { return ("Pix couldn't take the picture.", true, nil) }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }  // not Pix's own ring and blob
        let config = SCStreamConfiguration()
        config.sourceRect = area.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        let scale = min(1, 1280 / max(area.width, area.height))
        config.width = Int(area.width * scale)
        config.height = Int(area.height * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []),
                                                                       configuration: config),
              let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.75])
        else { return ("Pix couldn't take the picture.", true, nil) }
        seen = (area.origin, 1 / scale, CGSize(width: config.width, height: config.height))
        if let window { cueWindow(window) }
        return ("\(app.localizedName ?? "The app"), \(config.width)x\(config.height) pixels. Point with x, y in these pixels: screen_click_at to do it, screen_show_at to show the user.", false, jpeg)
    }

    /// A spot in the last picture, in Accessibility's top-left screen points.
    func spot(_ x: Double, _ y: Double) -> CGPoint? {
        guard let s = seen, x >= 0, y >= 0, x <= s.size.width + 2, y <= s.size.height + 2 else { return nil }
        return CGPoint(x: s.origin.x + x * s.pointsPerPixel, y: s.origin.y + y * s.pointsPerPixel)
    }

    /// The control at a spot, if the app has one there (so it can be pressed without moving the mouse).
    private func control(at p: CGPoint) -> (AXUIElement, String)? {
        var e: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &e) == .success, let e else { return nil }
        let role = attr(e, kAXRoleAttribute) as? String ?? ""
        return (e, name(e, role: role))
    }

    private func pressable(_ e: AXUIElement) -> Bool {
        let role = attr(e, kAXRoleAttribute) as? String ?? ""
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        return ["AXButton", "AXCheckBox", "AXRadioButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXTab", "AXDisclosureTriangle", "AXCell", "AXRow"].contains(role)
            && ((names as? [String]) ?? []).contains(kAXPressAction)
    }

    /// Where a spot is, for the blob to fly beside and the ring to circle (AppKit coordinates).
    private func ringRect(_ p: CGPoint, w: Double = 0, h: Double = 0) -> CGRect {
        let ppp = seen?.pointsPerPixel ?? 1
        let width = max(28, w * ppp), height = max(24, h * ppp)
        return appKitRect(CGRect(x: p.x - width / 2, y: p.y - height / 2, width: width, height: height))
    }

    /// The mouse goes back where the user left it after a real click or drag.
    private func realMouse(_ body: () -> Void) {
        let home = CGEvent(source: nil)?.location
        body()
        if let home { CGWarpMouseCursorPosition(home); CGAssociateMouseAndMouseCursorPosition(1) }
    }

    private func post(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1) {
        let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        ev?.setIntegerValueField(.mouseEventClickState, value: clicks)
        ev?.post(tap: .cghidEventTap)
    }

    func clickAt(x: Double, y: Double, what: String, double: Bool, right: Bool) async -> (String, Bool) {
        guard let p = spot(x, y) else { return ("Call screen_see first, then give x, y inside that picture.", true) }
        let found = control(at: p)
        let label = what.isEmpty ? (found?.1 ?? "") : what
        controller?.workHere(ringRect(p), label: label.isEmpty ? nil : "Clicking \(label)")
        try? await Task.sleep(for: .milliseconds(controller?.roaming == true ? 350 : 650))
        // In the background when the spot is a real control; a real click (mouse put back after) when it isn't.
        if !double, !right, let (e, _) = found, pressable(e), AXUIElementPerformAction(e, kAXPressAction as CFString) == .success {
        } else {
            NSRunningApplication(processIdentifier: pid)?.activate()
            try? await Task.sleep(for: .milliseconds(120))
            realMouse {
                let (down, up): (CGEventType, CGEventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
                for n in 1...(double ? 2 : 1) {
                    post(down, p, button: right ? .right : .left, clicks: Int64(n))
                    post(up, p, button: right ? .right : .left, clicks: Int64(n))
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(450))
        return ("Clicked\(label.isEmpty ? "" : " “\(label)”"). Call screen_see to check what changed.", false)
    }

    /// Show Me by position: fly there, point with the step, wait for the user's click, then look again.
    func showAt(x: Double, y: Double, w: Double, h: Double, say: String) async -> (String, Bool, Data?) {
        guard let p = spot(x, y), let controller else { return ("Call screen_see first, then give x, y inside that picture.", true, nil) }
        let clicked = await controller.showStep(ringRect(p, w: w, h: h).insetBy(dx: -4, dy: -4), say: say.isEmpty ? "Click here" : say)
        guard clicked else { return ("The user didn't click it within 90 seconds (or stopped). Ask whether they want you to do it instead.", false, nil) }
        try? await Task.sleep(for: .milliseconds(500))
        let (text, error, jpeg) = await see()
        return ("The user clicked it. Now: " + text, error, jpeg)
    }

    func drag(from a: (Double, Double), to b: (Double, Double)) async -> (String, Bool) {
        guard let p = spot(a.0, a.1), let q = spot(b.0, b.1) else { return ("Call screen_see first, then give positions inside that picture.", true) }
        controller?.workHere(ringRect(p), label: "Dragging")
        try? await Task.sleep(for: .milliseconds(500))
        NSRunningApplication(processIdentifier: pid)?.activate()
        try? await Task.sleep(for: .milliseconds(120))
        realMouse {
            post(.leftMouseDown, p)
            for i in 1...14 {
                let t = CGFloat(i) / 14
                post(.leftMouseDragged, CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))
                usleep(12_000)
            }
            post(.leftMouseUp, q)
        }
        try? await Task.sleep(for: .milliseconds(400))
        return ("Dragged. Call screen_see to check.", false)
    }

    func scroll(x: Double, y: Double, direction: String, amount: Int) async -> (String, Bool) {
        guard let p = spot(x, y) else { return ("Call screen_see first, then give x, y inside that picture.", true) }
        let n = Int32(max(1, min(amount, 30)))
        let (dy, dx): (Int32, Int32) = switch direction { case "up": (n, 0); case "left": (0, n); case "right": (0, -n); default: (-n, 0) }
        realMouse {
            CGWarpMouseCursorPosition(p)
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?.post(tap: .cghidEventTap)
            usleep(120_000)
        }
        try? await Task.sleep(for: .milliseconds(300))
        return ("Scrolled \(direction). Call screen_see to look again.", false)
    }

    /// What's at a spot, for the ask-first check on clicks by position.
    func label(atX x: Double, y: Double) -> String {
        spot(x, y).flatMap { control(at: $0)?.1 } ?? ""
    }
}
