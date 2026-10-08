import AppKit
import ApplicationServices
import Combine
import ServiceManagement

@MainActor
final class PixController {
    let model = PixModel()
    var buddy: BuddyPanel!
    var bubble: BubblePanel!
    let overlay = HighlightOverlay()
    var hotKey: HotKey?
    var runner: AgentRun?
    var runMode: Mode = .lite
    var runProvider: Provider = .claude  // what the current Lite run is on
    var runApps: [String] = []           // your apps loaded for the current Lite run
    var appsChecked: [String] = []       // ...and the ones the model actually used
    var runToken = ""                    // tags what Pix's own tools change in this run, for Undo
    var runBuiltIn = false               // Pix's own tools were loaded for this run
    var toolsUsed: [String] = []         // Pix's own tools the model called ("Reminders", "Calendar")
    var scheduleTimer: Timer?
    var schedulePoll: Timer?
    var pendingRuns: [Schedules.Entry] = []
    var runProject: Project?             // the project this run brings along
    var cardToken = 0                    // the latest show/hide of the card wins
    var recovered = false                // this question already had its one quiet retry
    var nudged = false                   // a free model already got its one "use your tools" nudge
    var runApps0: [String: String] = [:] // apps as Claude Code reported them at start
    var cardFading = false
    var runID = 0                        // bumps each run, so late work from an old one is ignored
    var claudeReady = false              // signed in to Claude, so a free model can hand off to it
    var providersChecked = Date.distantPast
    var lastRequest: (goal: String, mode: Mode)?
    var lastPrompt: String?
    var lastRunPath: String?
    var lastStatus = "Working"
    var shot: Screen.Shot?
    var bag = Set<AnyCancellable>()

    var bubbleOpen = false
    var roaming = false     // off the bezel, pointing at something
    var hovering = false
    var dragging = false
    var avoid: CGRect?
    var happyTimer: Timer?

    // Hiding (see Hiding.swift): the menu bar face, the behaviors' timer and their state.
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    var stepCancel: (() -> Void)?  // ends a Show Me step that's waiting for your click
    var holdTimer: Timer?          // holding the shortcut past this starts listening
    var updateTimer: Timer?        // the daily update check, while Pix runs
    var userContinue: (() -> Void)?  // the card's Continue, while Pix waits for you
    var spokenRun = false          // the question was spoken
    var wakeRun = false            // "Hey Pix" was heard and Pix is taking the question
    var heardAt = Date.distantPast // when the wake listener last heard a word
    var handOffNote: String?       // Auto sent this one to Claude
    var tried: Set<String> = []    // AIs that already tried this question (failover skips them)
    var hidingTimer: Timer?
    var hidingTicks = 0
    var hiddenForPresenting = false
    var approachNear = false
    var lastActivity = Date()

    // Which bezel Pix lives in, and how high.
    var dockRight = true
    var dockY: CGFloat = 0

    // MARK: - Lifecycle

    func start(openNow: Bool) {
        try? FileManager.default.createDirectory(at: PixPaths.runs, withIntermediateDirectories: true)
        buddy = BuddyPanel(model: model, controller: self)
        bubble = BubblePanel(model: model, controller: self)
        loadDock()
        model.dockRight = dockRight
        model.look = CGVector(dx: dockRight ? -1 : 1, dy: 0)
        buddy.setFrameOrigin(dockOrigin(.tucked))
        model.tucked = true
        model.morphFrom = 1
        model.offTuck = { [weak self] in
            guard let self, let buddy = self.buddy else { return .zero }
            let home = self.dockOrigin(.tucked), now = buddy.frame.origin
            return CGVector(dx: home.x - now.x, dy: now.y - home.y)
        }
        buddy.level = hideStyle == .notch ? .statusBar : pixLevel
        if hideStyle != .menuBar || openNow { buddy.orderFrontRegardless() }
        applyHideStyle()
        defaultOpenAtLogin()
        installMainMenu()
        ScreenControl.shared.controller = self
        hotKey = HotKey { [weak self] down in MainActor.assumeIsolated { down ? self?.hotKeyDown() : self?.hotKeyUp() } }
        Plugin.ensureUserDir()
        DispatchQueue.global(qos: .utility).async { Housekeeping.sweep() }
        DispatchQueue.global(qos: .userInitiated).async { _ = ClaudeRunner.shellEnvironment }  // slow .zshrc never stalls the UI
        refreshToolbox()
        startSchedules()
        Task { @MainActor in await Bridge.start() }  // so Pix's tools can reach its browser window
        Task { @MainActor in await Translator.start() }  // so OpenAI-style AIs work
        startUpdateWatch()  // daily while running; installs quietly when idle
        if WakeWord.on { startWakeWord() }  // "Hey Pix", if turned on  // once a day; off until a release repo is set

        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.layoutBubble() } }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: bubble)
            .sink { [weak self] _ in
                // Clicking away from the prompt tucks Pix back in. Typed text is kept.
                // First-run steps (picking an AI, the welcome, adding an AI) stay put: losing them lost people.
                guard let self, case .idle = self.model.phase, !self.roaming,
                      !self.model.pickingAI, !self.model.welcome, !self.model.adding else { return }
                self.closeBubble()
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.redock() }
            .store(in: &bag)

        // The welcome waits for the setup check (about a second), so a Mac with no AI yet goes straight
        // to "Pix needs an AI" instead of flashing the welcome first.
        Task { @MainActor in
            await checkSetup()
            if openNow, case .idle = model.phase { openBubble(); firstRunWelcome() }
        }
        if !openNow {
            // Launched at login: a quick peek so you know it's there, then tuck in.
            slide(.peek) { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.slideHome() }
            }
        }
    }

    /// Finds your connected MCP servers about once a day (no tokens; see Toolbox.discover).
    func refreshToolbox() {
        let d = UserDefaults.standard
        model.servers = d.stringArray(forKey: "toolbox.servers") ?? []
        let last = d.object(forKey: "toolbox.checked") as? Date ?? .distantPast
        guard model.servers.isEmpty || Date().timeIntervalSince(last) > 86_400 else { return }
        Task { @MainActor in
            let found = await Toolbox.discover()
            guard !found.isEmpty else { return }
            model.servers = found
            d.set(found, forKey: "toolbox.servers")
            d.set(Date(), forKey: "toolbox.checked")
        }
    }

    func summon() {
        noteActivity()
        if hiddenForPresenting { showAfterPresenting() }
        senseProject()
        buddy.orderFrontRegardless()
        openBubble()
    }

    /// Looks at the app you were just in: a terminal or code editor means a project to bring along.
    /// Off the main thread (it reads git and the terminal), so the card opens at once.
    /// Switches the card's project to another one Pix found.
    func switchProject(to root: URL) {
        guard let current = model.project else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            var p = Project(root: root, app: current.app, isTerminal: current.isTerminal)
            p.confident = current.confident
            p.others = ([current.root] + current.others).filter { $0.path != root.path }
            p.look()
            await MainActor.run { self?.model.project = p; self?.model.projectOverride = true }
        }
    }

    func senseProject() {
        guard case .idle = model.phase else { return }
        nonisolated(unsafe) let app = NSWorkspace.shared.frontmostApplication
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = Project.detect(app)
            await MainActor.run {
                guard let self else { return }
                if found?.root != self.model.project?.root { self.model.projectOverride = nil }
                if found != self.model.project { self.model.project = found }
            }
        }
    }

    func shutdown() { runner?.stop() }

    func hotKeyPressed() {
        if model.keysHint { model.keysHint = false; summon(); return }  // they just used the keys it showed
        if bubbleOpen && !roaming { escape() } else { summon() }
    }

    var moveToken = 0

    // MARK: - Starting work

    // MARK: - Setup (new Macs)

    var setupPoll: Timer?
    var checkingSetup = false

    var crew: Crew?

    /// Questions and permission asks can come from Lite or from any crew member.
    weak var asker: AgentRun?

    /// Asks that arrive while you're answering another wait their turn instead of replacing it.
    var queuedAsks: [() -> Void] = []

    var askingYou: Bool {
        switch model.phase {
        case .question, .permission: return true
        default: return false
        }
    }

    // MARK: - Finishing

    var ledger: String { PixPaths.runs.appendingPathComponent("ledger.csv").path }

    var retried = false

    // MARK: - Board

    var board: BoardPanel?

}

/// Objective-C target for the buddy's right-click menu.
final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    weak var controller: PixController?

    @objc func call() { MainActor.assumeIsolated { controller?.summon() } }

    @objc func openRuns() { NSWorkspace.shared.open(PixPaths.runs) }
    @objc func feedback() { MainActor.assumeIsolated { if let u = Feedback.issue(ai: controller?.model.provider.short ?? "") { NSWorkspace.shared.open(u) } } }

    @objc func reopen(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { MainActor.assumeIsolated { controller?.reopen(path) } }
    }

    @objc func undoTool(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { MainActor.assumeIsolated { Forge.undo(name) } }
    }

    @objc func removeTool(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { MainActor.assumeIsolated { Forge.remove(name) } }
    }

    @objc func forgetFact(_ sender: NSMenuItem) {
        if let fact = sender.representedObject as? String { Memory.forget(fact) }
    }
    @objc func forgetAll() { Memory.forgetAll() }
    @objc func runRoutine(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { MainActor.assumeIsolated { controller?.summon(); controller?.runRoutine(name) } }
    }
    @objc func removeRoutine(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { Routines.remove(name) }
    }
    @objc func cancelSchedule(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { MainActor.assumeIsolated { controller?.cancelSchedule(id) } }
    }
    @objc func undoForget() { Memory.undoForget() }

    @objc func toggleLogin() {
        let app = SMAppService.mainApp
        if app.status == .enabled { try? app.unregister() } else { try? app.register() }
    }

    @objc func toggleAuto() { Auto.on.toggle() }
    @objc func update() {
        MainActor.assumeIsolated {
            guard let c = controller, c.model.update != nil else { return }
            c.updateNow()
        }
    }
    @objc func settings() { MainActor.assumeIsolated { controller?.showSettings() } }
    @objc func permissions() { MainActor.assumeIsolated { controller?.showPermissions() } }

    @objc func statusClicked() { MainActor.assumeIsolated { controller?.statusClicked() } }
    @objc func setHideStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let s = HideStyle(rawValue: raw) { MainActor.assumeIsolated { controller?.setHideStyle(s) } }
    }
    @objc func toggleSleep() { Hiding.sleepWhenIdle.toggle(); MainActor.assumeIsolated { controller?.startHidingWatch() } }
    @objc func togglePresenting() { Hiding.vanishWhenPresenting.toggle(); MainActor.assumeIsolated { controller?.startHidingWatch() } }
    @objc func toggleApproach() { Hiding.peekOnApproach.toggle(); MainActor.assumeIsolated { controller?.startHidingWatch() } }

    @objc func hide() { MainActor.assumeIsolated { controller?.hide() } }
}
