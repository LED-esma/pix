import AppKit
import ServiceManagement
import SwiftUI

/// Pix's Settings window (⌘, or right-click > Settings): everything that used to live only in the
/// right-click menu, where new people never look. The menu keeps working the same.
extension PixController {
    func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(model: model, controller: self))
            let w = NSWindow(contentViewController: host)
            w.title = "Pix Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("PixSettings")
            if UserDefaults.standard.string(forKey: "NSWindow Frame PixSettings") == nil { w.center() }
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// A standard app menu, so ⌘, opens Settings and ⌘Q quits like any Mac app.
    func installMainMenu() {
        let main = NSMenu()
        let appItem = main.addItem(withTitle: "Pix", action: nil, keyEquivalent: "")
        let app = NSMenu(title: "Pix")
        app.addItem(withTitle: "Settings…", action: #selector(MenuTarget.settings), keyEquivalent: ",").target = MenuTarget.shared
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Pix", action: #selector(MenuTarget.hide), keyEquivalent: "h").target = MenuTarget.shared
        app.addItem(withTitle: "Quit Pix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        let editItem = main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        MenuTarget.shared.controller = self
        NSApp.mainMenu = main
    }
}

struct SettingsView: View {
    @ObservedObject var model: PixModel
    let controller: PixController

    var body: some View {
        TabView {
            GeneralPane(model: model, controller: controller).tabItem { Label("General", systemImage: "gearshape") }
            AIPane(model: model, controller: controller).tabItem { Label("AI", systemImage: "sparkles") }
            HidingPane(model: model, controller: controller).tabItem { Label("Hiding", systemImage: "eye.slash") }
            PermissionsPane(controller: controller).tabItem { Label("Permissions", systemImage: "lock.shield") }
            ToolsPane(model: model, controller: controller).tabItem { Label("Tools", systemImage: "bolt") }
        }
        .frame(width: 500, height: 430)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var model: PixModel
    let controller: PixController
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginProblem = false
    @State private var updateProblem: String?

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $model.nameDraft)
                    .onSubmit { Welcome.save(name: model.nameDraft) }
                    .onDisappear { Welcome.save(name: model.nameDraft) }
                Toggle("Auto Mode", isOn: Binding(get: { Auto.on }, set: { Auto.on = $0; model.objectWillChange.send() }))
                LabeledContent("Call Pix") { ShortcutRecorder(controller: controller) }
                Picker("In your apps", selection: Binding(get: { ScreenControl.mode }, set: { ScreenControl.mode = $0; model.objectWillChange.send() })) {
                    Text("Show Me How").tag("show")
                    Text("Do It for Me").tag("do")
                }
                Toggle("Open at Login", isOn: $login)
                    .onChange(of: login) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginProblem = false }
                        catch { loginProblem = true; login = SMAppService.mainApp.status == .enabled }
                    }
                if loginProblem {
                    Text("macOS didn't allow that change.").font(.caption).foregroundStyle(.secondary)
                }
            }
            VoiceSection(model: model, controller: controller)
            if !Updater.repo.isEmpty {
                Section {
                    HStack {
                        Text("Pix \(Updater.current)")
                        Spacer()
                        if model.updating { ProgressView().controlSize(.small) }
                        else if let u = model.update {
                            Button("Update to \(u.version)") {
                                Task { @MainActor in if let problem = await Updater.install(u, model: model) { updateProblem = problem } }
                            }
                        } else {
                            Button("Check for Updates") { Task { @MainActor in await Updater.check(model, force: true) } }
                        }
                    }
                    if let p = updateProblem { Text(p).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Memory") {
                LabeledContent("Things Pix knows about you", value: "\(Memory.all().count)")
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Memory.file]) }
                    Spacer()
                    if !Memory.forgotten.isEmpty { Button("Undo Forget") { Memory.undoForget(); model.objectWillChange.send() } }
                    Button("Forget Everything") { Memory.forgetAll(); model.objectWillChange.send() }.disabled(Memory.all().isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Spoken answers, which voice, and "Hey Pix".
private struct VoiceSection: View {
    @ObservedObject var model: PixModel
    let controller: PixController
    @State private var speak = Voice.speakAnswers
    @State private var voice = Voice.chosen
    @State private var wake = WakeWord.on
    private let voices = Voice.choices

    var body: some View {
        Section("Voice") {
            Toggle("Listen for \u{201C}Hey Pix\u{201D}", isOn: $wake)
                .onChange(of: wake) { _, on in controller.setWakeWord(on) }
                .disabled(!WakeWord.shared.available && !wake)
            Toggle("Spoken Answers", isOn: $speak)
                .onChange(of: speak) { _, on in Voice.speakAnswers = on; if on { Voice.shared.say(sample) } }
            if speak {
                HStack {
                    Picker("Voice", selection: $voice) {
                        Text(voices.first.map { "Best Available (\(Voice.label($0)))" } ?? "Best Available").tag("")
                        ForEach(voices, id: \.identifier) { Text(Voice.label($0)).tag($0.identifier) }
                    }
                    .onChange(of: voice) { _, id in Voice.chosen = id; Voice.shared.say(sample) }
                    Button("Play") { Voice.shared.say(sample) }
                }
                // Natural voices (Premium, Enhanced) are free downloads macOS keeps in Spoken Content; Pix uses one as soon as it's there.
                if !Voice.hasNatural {
                    Button("More Voices\u{2026}") { NSWorkspace.shared.open(Voice.moreVoicesURL) }
                }
            }
        }
    }

    private var sample: String {
        let name = Welcome.name
        return name.isEmpty ? "Hi, I'm Pix. Ask me anything." : "Hi \(name), I'm Pix. Ask me anything."
    }
}

/// Click, then press the new keys. Escape keeps the old ones.
private struct ShortcutRecorder: View {
    let controller: PixController
    @State private var combo = HotKey.Combo.saved
    @State private var recording = false
    @State private var taken = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            if taken { Text("Already in use").font(.caption).foregroundStyle(.secondary) }
            Button { recording ? stop() : start() } label: {
                HStack(spacing: 3) {
                    ForEach(recording ? ["\u{2026}"] : combo.symbols, id: \.self) { k in
                        Text(k).font(.system(size: 12, weight: .medium, design: .rounded))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                    }
                }
                .padding(.horizontal, 4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(recording ? Color.accentColor : .clear, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recording ? "Recording a new shortcut" : "Shortcut \(combo.label)")
            if combo != .standard && !recording {
                Button("Reset") { set(.standard) }.controlSize(.small)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        taken = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if Int(e.keyCode) == 53 { stop(); return nil }  // Escape keeps the old shortcut
            guard let c = HotKey.Combo.from(e) else { return nil }
            set(c)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func set(_ c: HotKey.Combo) {
        if controller.hotKey?.rebind(c) == true { combo = c; taken = false } else { taken = true }
    }
}

// MARK: - AI

private struct AIPane: View {
    @ObservedObject var model: PixModel
    let controller: PixController
    @State private var order: [Provider] = []
    @State private var removed: (id: String, key: String)?

    private func refresh() { order = controller.availableAIs }

    private func move(_ i: Int, by d: Int) {
        let j = i + d
        guard order.indices.contains(j) else { return }
        order.swapAt(i, j)
        AIOrder.save(order)
        if order.first != model.provider, let first = order.first { controller.use(first) }
    }

    var body: some View {
        Form {
            Section {
                ForEach(Array(order.enumerated()), id: \.element.key) { i, p in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.menuLabel)
                            if i == 0 { Text("Answers first").font(.caption).foregroundStyle(.secondary) }
                            else { Text("If the ones above can't answer").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button { move(i, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(i == 0).accessibilityLabel("Move Up")
                        Button { move(i, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(i == order.count - 1).accessibilityLabel("Move Down")
                        if case .service(let id, _) = p, let key = Services.key(id) {
                            Button("Remove") {
                                Services.removeKey(id)
                                removed = (id, key)
                                if model.provider == p { controller.use(.claude) }
                                refresh()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                if let r = removed {
                    HStack {
                        Text("Removed \(Services.find(r.id)?.name ?? r.id)").foregroundStyle(.secondary)
                        Spacer()
                        Button("Undo") { Services.setKey(r.key, for: r.id); removed = nil; refresh() }
                    }
                }
                HStack {
                    Button("Add an AI…") { controller.startAdding() }
                    Button("Sign In with OpenRouter") { controller.signInToOpenRouter() }
                    Button("Get Free AI on This Mac") { controller.downloadFreeModel() }
                }
                .disabled(model.freeSetup?.fraction != nil)
                if let p = model.freeSetup {
                    HStack {
                        Text(p.text).foregroundStyle(.secondary)
                        if let f = p.fraction { ProgressView(value: f) }
                    }
                }
            }
            Section {
                Toggle("Quick answers on Haiku", isOn: Binding(get: { Solo.quickOnHaiku }, set: { Solo.quickOnHaiku = $0; model.objectWillChange.send() }))
            }
            Section("Teams") {
                LabeledContent("Ask the Team", value: TeamCost.hint(.standard))
                LabeledContent("Ask a Bigger Team", value: TeamCost.hint(.deep, members: model.deepMembers))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            controller.refreshProviders()
            refresh()
            Task { @MainActor in await Services.detectLocal(); refresh() }
        }
        .onChange(of: model.provider) { refresh() }
    }
}

// MARK: - Hiding

private struct HidingPane: View {
    @ObservedObject var model: PixModel
    let controller: PixController
    @State private var sleep = Hiding.sleepWhenIdle
    @State private var vanish = Hiding.vanishWhenPresenting
    @State private var approach = Hiding.peekOnApproach

    var body: some View {
        Form {
            Section {
                Picker("Hide as", selection: Binding(get: { model.hideStyle }, set: { controller.setHideStyle($0) })) {
                    ForEach(HideStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            }
            Section {
                Toggle("Sleep When Idle", isOn: $sleep).onChange(of: sleep) { _, v in Hiding.sleepWhenIdle = v; controller.startHidingWatch() }
                Toggle("Vanish When Presenting", isOn: $vanish).onChange(of: vanish) { _, v in Hiding.vanishWhenPresenting = v; controller.startHidingWatch() }
                Toggle("Peek on Approach", isOn: $approach).onChange(of: approach) { _, v in Hiding.peekOnApproach = v; controller.startHidingWatch() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Permissions

private struct PermissionsPane: View {
    let controller: PixController
    @State private var states: [Permission: Permission.State] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(Permission.allCases) { p in
                    HStack(spacing: 10) {
                        Image(systemName: p.symbol).foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title)
                            Text(p.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        switch states[p] {
                        case .on: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("On")
                        case .denied: Button("Open Settings") { NSWorkspace.shared.open(p.settings) }
                        default: Button("Allow") { Task { _ = await p.request() } }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                let now = await Permission.states()
                if now != states { states = now }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

// MARK: - Tools

private struct ToolsPane: View {
    @ObservedObject var model: PixModel
    let controller: PixController
    @State private var tools = Routines.all()
    @State private var removed: Routines.Routine?

    var body: some View {
        Form {
            Section {
                if tools.isEmpty {
                    Text("Make a tool that counts the files in my Downloads folder").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(tools, id: \.name) { t in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name)
                            Text(t.about.isEmpty ? t.steps : t.about).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("Run") { controller.summon(); controller.runRoutine(t.name) }
                        Button("Remove") { removed = Routines.remove(t.name); tools = Routines.all() }
                    }
                }
                if let r = removed {
                    HStack {
                        Text("Removed \(r.name)").foregroundStyle(.secondary)
                        Spacer()
                        Button("Undo") { Routines.save(name: r.name, steps: r.steps, about: r.about); removed = nil; tools = Routines.all() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { tools = Routines.all() }
    }
}
