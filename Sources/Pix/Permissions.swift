import AppKit
import ApplicationServices
import EventKit
import ServiceManagement

/// What Pix can be allowed to use on this Mac. Each one is shown with a real ask that uses it;
/// tapping the ask asks macOS (if it hasn't yet), then runs it.
enum Permission: String, CaseIterable, Identifiable {
    case reminders, calendar, notes, music, screen, accessibility, voice

    enum State: Equatable { case on, off, denied }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reminders: "Reminders"
        case .calendar: "Calendar"
        case .notes: "Notes"
        case .music: "Music"
        case .screen: "Screen Recording"
        case .accessibility: "Accessibility"
        case .voice: "Microphone and Speech"
        }
    }

    var symbol: String {
        switch self {
        case .reminders: "checklist"
        case .calendar: "calendar"
        case .notes: "note.text"
        case .music: "music.note"
        case .screen: "rectangle.dashed"
        case .accessibility: "accessibility"
        case .voice: "mic"
        }
    }

    /// What Pix does with it, in a line.
    var detail: String {
        switch self {
        case .reminders: "Reads your reminders and adds new ones."
        case .calendar: "Reads your calendar and adds events."
        case .notes: "Finds your notes and starts new ones."
        case .music: "Plays, pauses and skips songs in Music."
        case .screen: "Sees your screen when you ask about it."
        case .accessibility: "Sees which app and project you're working in, and uses its buttons."
        case .voice: "Hears you while you hold the shortcut, and understands it on this Mac."
        }
    }

    /// A real ask that needs this permission. Changes it makes come with Undo.
    var example: String {
        switch self {
        case .reminders: "Remind me to stretch at 5 PM"
        case .calendar: "What's on my calendar tomorrow?"
        case .notes: "Start a note called Weekend plans"
        case .music: "What's playing in Music?"
        case .screen: "What's on my screen?"
        case .accessibility: "What am I working on?"
        case .voice: "Talk to Pix"
        }
    }

    /// The app Pix drives with Apple Events (Notes and Music).
    var bundle: String? {
        switch self {
        case .notes: "com.apple.Notes"
        case .music: "com.apple.Music"
        default: nil
        }
    }

    /// Screen Recording and Accessibility are granted in System Settings, not in a dialog.
    var grantedInSettings: Bool { self == .screen || self == .accessibility }

    var settings: URL {
        let pane = switch self {
        case .reminders: "Privacy_Reminders"
        case .calendar: "Privacy_Calendars"
        case .notes, .music: "Privacy_Automation"
        case .screen: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        case .voice: "Privacy_Microphone"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    private var askedKey: String { rawValue == "accessibility" ? "askedAX" : "asked.\(rawValue)" }  // askedAX predates this list
    private var onKey: String { "permission.\(rawValue)" }

    /// Where things stand now. Can block for a moment (Apple Events), so call it off the main thread.
    var state: State {
        switch self {
        case .reminders: return Self.state(EKEventStore.authorizationStatus(for: .reminder))
        case .calendar: return Self.state(EKEventStore.authorizationStatus(for: .event))
        case .screen, .accessibility:
            let on = self == .screen ? CGPreflightScreenCaptureAccess() : AXIsProcessTrusted()
            return on ? .on : UserDefaults.standard.bool(forKey: askedKey) ? .denied : .off
        case .voice:
            let m = Voice.micState, s = Voice.speechState
            return m == .on && s == .on ? .on : (m == .denied || s == .denied) ? .denied : .off
        case .notes, .music:
            switch Self.automation(bundle!, ask: false) {
            case noErr: UserDefaults.standard.set(true, forKey: onKey); return .on
            case OSStatus(errAEEventNotPermitted): UserDefaults.standard.set(false, forKey: onKey); return .denied
            case OSStatus(errAEEventWouldRequireUserConsent): UserDefaults.standard.set(false, forKey: onKey); return .off
            default: return UserDefaults.standard.bool(forKey: onKey) ? .on : .off  // app not open: last thing macOS said
            }
        }
    }

    static func state(_ s: EKAuthorizationStatus) -> State {
        switch s {
        case .fullAccess, .authorized, .writeOnly: .on
        case .notDetermined: .off
        default: .denied
        }
    }

    /// Asks macOS. Reminders, Calendar, Notes and Music answer in a dialog; Screen Recording and
    /// Accessibility send you to System Settings, so they come back `.off` until you switch them on there.
    func request() async -> State {
        UserDefaults.standard.set(true, forKey: askedKey)
        switch self {
        case .reminders: _ = try? await EKEventStore().requestFullAccessToReminders()
        case .calendar: _ = try? await EKEventStore().requestFullAccessToEvents()
        case .screen: CGRequestScreenCaptureAccess()
        case .accessibility: _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        case .voice: _ = await Voice.requestAccess()
        case .notes, .music:
            // macOS only asks about an app that's open: open it out of the way first.
            let id = bundle!
            if NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                config.hides = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
                try? await Task.sleep(for: .milliseconds(600))
            }
            _ = await Task.detached { Self.automation(id, ask: true) }.value
        }
        return await Task.detached { self.state }.value
    }

    static func automation(_ bundle: String, ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let id = Array(bundle.utf8)
        guard AECreateDesc(typeApplicationBundleID, id, id.count, &target) == noErr else { return OSStatus(procNotFound) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
    }

    static func states() async -> [Permission: State] {
        await Task.detached {
            Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, $0.state) })
        }.value
    }
}

/// Where a tried ask came from, so its answer card can lead back there.
enum TryOrigin { case permissions, welcome }

/// The first card on a new Mac: hello, your name, and four asks that show what Pix can do.
/// Permissions are asked by the ask that needs them, not up front.
enum Welcome {
    struct Try: Hashable { var text: String; var needs: Permission? }

    /// Boards (graphs, simulations) need a model that follows Pix's answer format; a model on this Mac
    /// answers in plain text, so it gets a try it can do well instead.
    static func tries(boards: Bool) -> [Try] {
        [Try(text: Permission.calendar.example, needs: .calendar),
         Try(text: Permission.screen.example, needs: .screen),
         Try(text: Permission.reminders.example, needs: .reminders),
         boards ? Try(text: "Graph sin(x) and its derivative", needs: nil) : Try(text: Permission.notes.example, needs: .notes)]
    }

    static var name: String { UserDefaults.standard.string(forKey: "userName") ?? "" }

    /// Keeps the name for greetings, and as a memory so every answer can use it.
    static func save(name raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != self.name, name.count <= 40 else { return }
        UserDefaults.standard.set(name, forKey: "userName")
        Memory.add(["Their name is \(name)."])
    }
}

extension PixController {
    /// The list of permissions, each with an ask that uses it. From the right-click menu.
    func showPermissions() {
        guard !model.isBusy else { return }
        if case .guide = model.phase { endGuide() }
        tearDownTour()
        model.phase = .idle
        model.adding = false
        model.welcome = false
        model.permissions = true
        openBubble()
    }

    func showWelcome() {
        guard !model.isBusy else { return }
        tearDownTour()
        model.phase = .idle
        model.adding = false
        model.permissions = false
        model.welcome = true
        openBubble()
    }

    /// First open on a new Mac (after Claude setup): the welcome card, once. Pix also starts at
    /// login from now on (one click in the right-click menu turns that off).
    func firstRunWelcome() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "shownWelcome"), case .idle = model.phase, !model.adding else { return }
        d.set(true, forKey: "shownWelcome")
        model.welcome = true
        openBubble()
    }

    /// Pix opens at login unless you turned that off: done once per Mac, only for the copy in
    /// /Applications (a build in a project folder shouldn't register itself).
    func defaultOpenAtLogin() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "loginDefaulted"), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        d.set(true, forKey: "loginDefaulted")
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
    }

    /// Leaving the welcome card: keep the name if one was typed.
    func closeWelcome() {
        Welcome.save(name: model.nameDraft)
        model.welcome = false
        if bubbleOpen { bubble.makeKey(); model.focusTick += 1 }
    }

    /// A try from the welcome card: asks macOS first when it needs a permission, then runs.
    func tryWelcome(_ t: Welcome.Try) {
        Welcome.save(name: model.nameDraft)
        if let p = t.needs { tryPermission(p, from: .welcome) } else { runTry(t.text, from: .welcome) }
    }

    /// Asks macOS for `p` if it hasn't yet, then runs its example. Off in Settings: opens that pane.
    func tryPermission(_ p: Permission, from origin: TryOrigin = .permissions) {
        Task { @MainActor in
            var state = await Task.detached { p.state }.value
            if state == .denied {
                NSWorkspace.shared.open(p.settings)
                await waitThenRun(p, origin)
                return
            }
            if state == .off { state = await p.request() }
            if state == .on { runExample(p, origin) } else if p.grantedInSettings { await waitThenRun(p, origin) }
        }
    }

    /// Switched on in System Settings within a few minutes: run the example then.
    private func waitThenRun(_ p: Permission, _ origin: TryOrigin) async {
        model.waitingFor = p
        defer { if model.waitingFor == p { model.waitingFor = nil } }
        for _ in 0..<180 {
            try? await Task.sleep(for: .seconds(1))
            guard model.waitingFor == p else { return }  // you tapped another one
            if await Task.detached(operation: { p.state }).value == .on { runExample(p, origin); return }
        }
    }

    func runExample(_ p: Permission, _ origin: TryOrigin = .permissions) {
        if p == .voice { model.permissions = false; startListening(stopsOnSilence: true); return }
        guard p == .accessibility else { runTry(p.example, screen: p == .screen, from: origin); return }
        // The app you were in: what Accessibility lets Pix see.
        nonisolated(unsafe) let front = NSWorkspace.shared.frontmostApplication
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = Project.detect(front)
            await MainActor.run {
                guard let self else { return }
                if let found { self.model.project = found; self.model.projectOverride = true }
                self.runTry(p.example, from: origin)
            }
        }
    }

    func runTry(_ text: String, screen: Bool = false, from origin: TryOrigin) {
        guard case .idle = model.phase else { return }
        model.adding = false
        model.goal = text
        model.screenOverride = screen ? true : nil
        openBubble()
        go()
        model.cameFrom = origin
    }
}
