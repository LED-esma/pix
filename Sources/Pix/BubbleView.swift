import SwiftUI

/// The card beside the blob. One view per phase, one primary action each.
struct BubbleView: View {
    @ObservedObject var model: PixModel
    let controller: PixController
    static let width: CGFloat = 300

    /// A long answer, a table, or code gets a wider card; everything else stays compact.
    private var width: CGFloat {
        if case .idle = model.phase, !model.adding, !model.keysHint, model.permissions || model.welcome || model.pickingAI { return 380 }  // each line and Try fit
        if case .idle = model.phase, model.keysHint { return 190 }
        guard case .done(let d) = model.phase else { return Self.width }
        let wide = d.gist.count > 420 || d.gist.contains("|") || d.gist.contains("```")
        return wide ? 460 : Self.width
    }

    /// Which kind of card is showing, so changing kinds cross-fades instead of snapping.
    private var kind: String {
        switch model.phase {
        case .setup: "setup"
        case .idle: model.adding ? "adding" : model.listening ? "listening" : model.keysHint ? "keys" : model.welcome ? "welcome" : model.permissions ? "permissions" : "idle"
        case .working: "working"
        case .question: "question"
        case .permission: "permission"
        case .guide: "guide"
        case .done: "done"
        case .failed: "failed"
        }
    }

    var body: some View {
        content
            .id(kind)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.18), value: kind)
            .frame(width: width - 32, alignment: .leading)
            .padding(16)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))  // readable over bright pages
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .fixedSize()
            .onExitCommand { controller.escape() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .setup(let state, let waiting): SetupView(model: model, controller: controller, state: state, waiting: waiting)
        case .idle:
            if model.adding { AddServiceView(model: model, controller: controller) }
            else if model.listening { ListeningView(model: model) }
            else if model.keysHint { KeysView() }
            else if model.pickingAI { PickAIView(model: model, controller: controller) }
            else if model.welcome { WelcomeView(model: model, controller: controller) }
            else if model.permissions { PermissionsView(model: model, controller: controller) }
            else { InputView(model: model, controller: controller) }
        case .working(let status): WorkingView(model: model, controller: controller, status: status)
        case .question(let flow): QuestionView(model: model, controller: controller, flow: flow)
        case .permission(let ask): PermissionView(controller: controller, ask: ask)
        case .guide(let guide): GuideView(controller: controller, guide: guide)
        case .done(let done): DoneView(controller: controller, done: done, model: model)
        case .failed(let failure): FailedView(controller: controller, failure: failure)
        }
    }
}

private struct Row: View {
    var title: String
    var detail = ""
    var checked = false

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if checked { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.tint) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

// MARK: - Phases

private struct InputView: View {
    @ObservedObject var model: PixModel
    let controller: PixController
    @FocusState private var focused: Bool

    private var empty: Bool { model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func providerButton(_ p: Provider) -> some View {
        Button { controller.use(p) } label: {
            if p == model.provider { Image(systemName: "checkmark") }
            Text(p.menuLabel)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UpdateNotice(model: model, controller: controller)
            TextField(Mode.placeholder, text: $model.goal, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit { controller.go() }
            if !model.timers.isEmpty {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(spacing: 4) {
                        ForEach(model.timers, id: \.id) { t in
                            let s = max(0, Int(t.at.timeIntervalSince(ctx.date).rounded(.up)))
                            HStack(spacing: 6) {
                                Image(systemName: "timer").font(.system(size: 11)).foregroundStyle(.secondary)
                                Text(t.text.isEmpty ? "Timer" : t.text).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                Text(s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60))
                                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                                Button { controller.cancelSchedule(t.id) } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Cancel timer")
                            }
                        }
                    }
                }
            }
            // Only what changes what gets sent: your screen, and a connected app. Project and follow-up
            // context are worked out quietly (a new question here starts fresh; follow-ups live on the answer).
            if model.screenOn || !model.activeTools.isEmpty {
                HStack(spacing: 6) {
                    if model.screenOn {
                        Chip(label: "Screen", symbol: "rectangle.dashed", color: tintColor(.look)) { model.screenOverride = false }
                    }
                    ForEach(model.activeTools, id: \.self) { server in
                        Chip(label: Toolbox.label(server), symbol: "wrench.and.screwdriver", color: tintColor(.base)) {
                            model.toolOverride[server] = false
                        }
                    }
                }
                .transition(.opacity)
            }
            HStack {
                // The one choice left in the card: which AI answers. Everything else Pix works out itself.
                Menu {
                    providerButton(.claude)
                    ForEach(model.localModels, id: \.self) { providerButton(.local(model: $0)) }
                    if model.ollamaInstalled {
                        if case .cloud(let m) = model.provider { providerButton(.cloud(model: m)) }
                        else { providerButton(.cloud(model: Ollama.cloudDefault)) }
                    }
                    ForEach(Services.ready, id: \.id) { s in
                        if case .service(let id, let m) = model.provider, id == s.id { providerButton(.service(id: id, model: m)) }
                        else { providerButton(.service(id: s.id, model: s.model)) }
                    }
                    if model.gatewayFound { providerButton(.gateway(url: Provider.omniRouteURL, model: "auto")) }
                    Divider()
                    Button("Add an AI…") { controller.startAdding() }
                } label: {
                    Text(model.provider.short)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 12, weight: .medium))
                .accessibilityLabel("Answers from")
                Spacer()
                Button { controller.startListening(stopsOnSilence: true) } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Talk")
                .help("Talk")
                Button { controller.go() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(empty ? Color.secondary.opacity(0.35) : Color.accentColor))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(empty)
                .accessibilityLabel("Start")
            }
        }
        .onAppear { focused = true }
        .onChange(of: model.focusTick) { focused = true }
    }
}

/// First run on a new Mac: get Claude Code, then sign in (or use a model already on this Mac).
/// Pix checks again on its own.
private struct SetupView: View {
    @ObservedObject var model: PixModel
    let controller: PixController
    let state: ClaudeRunner.Readiness
    let waiting: Bool

    var body: some View {
        if state == .missing { noAI } else { signedOut }
    }

    /// Nothing to answer with yet (no built-in model on this Mac: Intel, older macOS, or Apple Intelligence
    /// off). One click to a free private model, or their Claude plan. Nothing to copy, nothing to sign up for.
    private var noAI: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(waiting ? "Installing Claude Code" : model.installFailed ? "Claude Code didn't install" : "Pix needs an AI to answer with")
                .font(.system(size: 14, weight: .semibold))
            if let p = model.freeSetup {
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.text).font(.system(size: 12)).foregroundStyle(.secondary)
                    if let f = p.fraction { ProgressView(value: f) } else if !p.text.hasPrefix("The") && !p.text.hasPrefix("Ollama") { ProgressView().controlSize(.small) }
                }
            }
            // No keys and no sign-ups here (2026-10-07): keys and OpenRouter live in Settings > AI.
            VStack(spacing: 6) {
                SetupChoice(title: "Get Free AI", detail: "Runs on this Mac: private, no account (\(FreeAI.localModel().size) download)", primary: true) { controller.downloadFreeModel() }
                SetupChoice(title: model.installFailed ? "Get Claude Code" : "Use Claude", detail: "With your Claude plan") { controller.setUp() }
            }
            .disabled(waiting || (model.freeSetup?.fraction != nil))
        }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Not signed in to Claude")
                .font(.system(size: 14, weight: .semibold))
            HStack {
                if waiting {
                    ProgressView().controlSize(.small)
                    Text(state == .missing ? "Installing Claude Code" : "Waiting for sign-in")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if state == .signedOut, let local = model.localModels.first {
                    Button("Use This Mac") { controller.use(.local(model: local)) }
                } else if state == .signedOut, model.ollamaInstalled {
                    Button("Use Ollama Cloud") { controller.use(.cloud(model: Ollama.cloudDefault)) }
                } else if state == .signedOut, !model.gatewayFound {
                    Button("Add an AI") { controller.startAdding() }
                } else if state == .signedOut, model.gatewayFound {
                    Button("Use OmniRoute") { controller.use(.gateway(url: Provider.omniRouteURL, model: "auto")) }
                }
                Button(state == .signedOut ? "Sign In" : model.installFailed ? "Get It from claude.com" : "Install Claude Code") { controller.setUp() }
                    .buttonStyle(.borderedProminent)
                    .disabled(waiting && state == .missing)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The setup card on its own, for `Pix --render-setup` (a Mac with the built-in model never shows it).
enum SetupPreview {
    @MainActor static func card(model: PixModel, controller: PixController) -> some View {
        SetupView(model: model, controller: controller, state: .missing, waiting: false)
    }
    @MainActor static func pick(model: PixModel, controller: PixController) -> some View {
        PickAIView(model: model, controller: controller)
    }
}

/// "Pick your AI": each AI this Mac can use, with what it's best at, cost, privacy and speed; the best
/// one is already picked, so Continue is all it takes.
struct PickAIView: View {
    @ObservedObject var model: PixModel
    let controller: PixController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hi, I'm Pix. Pick your AI.").font(.system(size: 17, weight: .semibold))
            VStack(spacing: 6) {
                ForEach(model.aiChoices) { c in
                    AIChoiceRow(choice: c, picked: model.aiPicked == c.provider) { model.aiPicked = c.provider }
                }
            }
            HStack {
                Spacer()
                Button(model.aiPicked.map { p in model.aiChoices.first { $0.provider == p }.map { $0.ready ? "Continue" : ($0.provider.isClaude ? "Set Up Claude" : "Continue") } ?? "Continue" } ?? "Continue") {
                    controller.confirmPickAI()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.aiPicked == nil)
            }
        }
    }
}

private struct AIChoiceRow: View {
    let choice: AIChoice
    let picked: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15)).foregroundStyle(picked ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(choice.title).font(.system(size: 13.5, weight: .semibold))
                        if let badge = choice.badge { Text(badge).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.primary.opacity(0.08))) }
                    }
                    Text(choice.bestAt).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    // One line when it fits, stacked when it doesn't (never cut off).
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { facts }
                        VStack(alignment: .leading, spacing: 2) { facts }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(picked ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(picked ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.title): \(choice.bestAt). \(choice.cost), \(choice.privacy), \(choice.speed)")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    @ViewBuilder private var facts: some View {
        Fact(symbol: "dollarsign.circle", text: choice.cost)
        Fact(symbol: choice.privacy.hasPrefix("Stays") ? "lock" : "arrow.up.right", text: choice.privacy)
        Fact(symbol: "bolt", text: choice.speed)
    }

    private struct Fact: View {
        let symbol: String, text: String
        var body: some View {
            Label(text, systemImage: symbol).font(.system(size: 10.5)).foregroundStyle(.secondary).labelStyle(.titleAndIcon).lineLimit(1).fixedSize()
        }
    }
}

/// One quiet line at the top of the card about updates: "Updated to Pix 0.1.2" (once, with What's New),
/// or, with automatic updates off, "Pix 0.1.2 is out" with Update.
private struct UpdateNotice: View {
    @ObservedObject var model: PixModel
    let controller: PixController

    var body: some View {
        if let v = model.justUpdated {
            row(symbol: "checkmark.seal", text: "Updated to Pix \(v)") {
                if let url = Updater.notes(v) { Button("What's New") { NSWorkspace.shared.open(url); model.justUpdated = nil } }
                CloseButton { model.justUpdated = nil }
            }
        } else if let u = model.update, !Updater.automatic || model.updateReady != nil {
            row(symbol: "arrow.down.circle", text: model.updateReady != nil ? "Pix \(u.version) is ready" : "Pix \(u.version) is out") {
                if model.updating { ProgressView().controlSize(.small) }
                else { Button(model.updateReady != nil ? "Restart to Update" : "Update") { controller.updateNow() } }
            }
        }
    }

    private func row<Trailing: View>(symbol: String, text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Color.accentColor)
            Text(text).font(.system(size: 12, weight: .medium))
            Spacer()
            trailing().controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.1)))
    }
}

/// One way to get an AI on the setup card: what it is, and what it takes.
private struct SetupChoice: View {
    let title: String, detail: String
    var primary = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(primary ? Color.white.opacity(0.85) : .secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(primary ? Color.white.opacity(0.8) : Color.secondary.opacity(0.6))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(primary ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(primary ? Color.accentColor : Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A new Mac's first card: hello, your name, four asks that show what Pix can do, and the question field.
private struct WelcomeView: View {
    @ObservedObject var model: PixModel
    let controller: PixController
    private enum Field { case name, ask }
    @FocusState private var focus: Field?
    @State private var states: [Permission: Permission.State] = [:]

    private var name: String { model.nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(name.isEmpty ? "Hi, I'm Pix." : "Hi \(name), I'm Pix.")
                .font(.system(size: 17, weight: .semibold))
                .animation(.easeOut(duration: 0.15), value: name)
            TextField("Your name", text: $model.nameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .focused($focus, equals: .name)
                .onSubmit { Welcome.save(name: model.nameDraft); focus = .ask }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Welcome.tries(boards: !model.provider.isLocal), id: \.self) { t in
                    HStack(spacing: 8) {
                        Button { controller.tryWelcome(t) } label: {
                            Label(t.text, systemImage: t.needs?.symbol ?? "function").font(.system(size: 12.5, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        if let p = t.needs, model.waitingFor == p { ProgressView().controlSize(.small) }
                        else if let p = t.needs, states[p] == .denied {
                            Button("Open Settings") { NSWorkspace.shared.open(p.settings) }.controlSize(.small)
                        }
                    }
                }
            }
            TextField(Mode.placeholder, text: $model.goal, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...4)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .focused($focus, equals: .ask)
                .onSubmit { controller.go() }
        }
        .overlay(alignment: .topTrailing) { CloseButton { controller.closeWelcome() } }
        .onChange(of: model.focusTick) { focus = name.isEmpty ? .name : .ask }
        .onAppear { focus = name.isEmpty ? .name : .ask }
        .task {
            while !Task.isCancelled {
                let now = await Permission.states()
                if now != states { states = now }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// Hold to talk: what Pix is hearing, live, with a mic that pulses while it listens.
private struct ListeningView: View {
    @ObservedObject var model: PixModel
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                Image(systemName: "mic.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(tintColor(.look)))
                    .overlay(Circle().stroke(tintColor(.look).opacity(0.35), lineWidth: 6).scaleEffect(1 + 0.18 * (1 + sin(t * 5)) / 2))
            }
            Text(model.heard.isEmpty ? "Listening" : model.heard)
                .font(.system(size: 15, weight: model.heard.isEmpty ? .regular : .medium))
                .foregroundStyle(model.heard.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 5)
                .animation(.easeOut(duration: 0.12), value: model.heard)
        }
        .accessibilityLabel(model.heard.isEmpty ? "Listening" : "Heard: \(model.heard)")
    }
}

/// Shown once, after the first answer closes: how to call Pix back. Status, not a tip.
private struct KeysView: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(HotKey.Combo.saved.symbols, id: \.self) { k in
                Text(k).font(.system(size: 14, weight: .medium, design: .rounded))
                    .lineLimit(1).fixedSize()
                    .frame(minWidth: 26).padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("\(HotKey.Combo.saved.label) calls Pix")
    }
}

/// What Pix can use, each with a real ask that uses it. Tapping the ask asks macOS, then runs it.
private struct PermissionsView: View {
    @ObservedObject var model: PixModel
    let controller: PixController
    @State private var states: [Permission: Permission.State] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Permissions").font(.system(size: 14, weight: .semibold)).padding(.bottom, 2)
            ForEach(Permission.allCases) { p in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: p.symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.title).font(.system(size: 12.5, weight: .medium))
                        Text(p.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { controller.tryPermission(p) } label: {
                            Text("Try: \(p.example)").font(.system(size: 11.5, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                    if model.waitingFor == p {
                        ProgressView().controlSize(.small)
                    } else if states[p] == .on {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("On")
                    } else if states[p] == .denied {
                        Button("Open Settings") { NSWorkspace.shared.open(p.settings) }.controlSize(.small)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .overlay(alignment: .topTrailing) { CloseButton { controller.closePermissions() } }
        .task {
            // Live: a switch flipped in System Settings shows here within a second.
            while !Task.isCancelled {
                let now = await Permission.states()
                if now != states { states = now }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// Another AI: pick a service, paste a key, pick a model.
private struct AddServiceView: View {
    @ObservedObject var model: PixModel
    let controller: PixController

    private var service: Service? { Services.find(model.addID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add an AI").font(.system(size: 14, weight: .semibold))
            Picker("Service", selection: Binding(get: { model.addID }, set: { controller.pickService($0) })) {
                ForEach(Services.all, id: \.id) { s in Text(s.about.isEmpty ? s.name : "\(s.name) — \(s.about)").tag(s.id) }
                Divider()
                Text("Other…").tag("custom")
            }
            .labelsHidden()
            if model.addID == "custom" {
                field("My AI", text: $model.addName)
                field(model.addOpenAI ? "https://example.com/v1" : "https://example.com/anthropic", text: $model.addURL)
                Picker("Speaks", selection: $model.addOpenAI) {
                    Text("OpenAI-style").tag(true)
                    Text("Claude-style").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            if !(service?.local ?? false) {
            SecureField("sk-…", text: $model.addKey)
                .textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onSubmit { controller.addService() }
                .onChange(of: model.addKey) { controller.fetchModels() }
            }
            HStack(spacing: 4) {
                field(service?.model ?? "model-name", text: $model.addModel)
                if !model.addModels.isEmpty {
                    Menu {
                        ForEach(model.addModels, id: \.self) { m in Button(m) { model.addModel = m } }
                    } label: { Image(systemName: "chevron.up.chevron.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Models")
                }
            }
            if let problem = model.addProblem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let page = service?.keyPage, !page.isEmpty, let url = URL(string: page) {
                    Button("Get a Key") { NSWorkspace.shared.open(url) }
                }
                if model.addID != "custom", Services.key(model.addID) != nil {
                    Button("Remove") { controller.removeService() }
                }
                Spacer()
                if model.addChecking { ProgressView().controlSize(.small) }
                Button("Add") { controller.addService() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.addChecking || (model.addKey.trimmingCharacters(in: .whitespaces).isEmpty && !(service?.local ?? false)))
            }
        }
        .overlay(alignment: .topTrailing) { CloseButton { model.adding = false; model.addProblem = nil } }
    }

    private func field(_ sample: String, text: Binding<String>) -> some View {
        TextField(sample, text: text)
            .textFieldStyle(.plain).font(.system(size: 13))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct WorkingView: View {
    @ObservedObject var model: PixModel
    let controller: PixController
    let status: String

    var body: some View {
        HStack(spacing: 10) {
            StageDot(color: tintColor(model.tint))
            VStack(alignment: .leading, spacing: 2) {
                if let step = model.liveStep {  // Show Me: the one thing to do now
                    Text(step).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(status).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                }
                Text(model.runningGoal).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.waitingUser {
                Button("Continue") { controller.userContinue?() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let s = max(0, Int(ctx.date.timeIntervalSince(model.startedAt)))
                // A team takes minutes: say how many, so the wait isn't a mystery.
                Text(String(format: "%d:%02d", s / 60, s % 60) + (model.runningMode == .lite ? "" : " of " + TeamCost.minutes(TeamCost.estimate(model.runningMode).seconds)))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
            }
            Button { controller.stop() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .accessibilityLabel("Stop")
        }
    }
}

private struct QuestionView: View {
    @ObservedObject var model: PixModel
    let controller: PixController
    let flow: QuestionFlow

    var body: some View {
        let q = flow.current
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(q.text).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if flow.questions.count > 1 {
                    Text("\(flow.index + 1)/\(flow.questions.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            ForEach(q.options) { opt in
                Button {
                    if q.multiSelect {
                        if model.picked.contains(opt.label) { model.picked.remove(opt.label) } else { model.picked.insert(opt.label) }
                    } else {
                        controller.answer(opt.label)
                    }
                } label: {
                    Row(title: opt.label, detail: opt.detail, checked: q.multiSelect && model.picked.contains(opt.label))
                }
                .buttonStyle(.plain)
            }
            TextField("something else", text: $model.otherAnswer)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onSubmit { controller.answer(model.otherAnswer) }
            if q.multiSelect {
                HStack {
                    Spacer()
                    Button("Continue") { controller.answer(model.picked.sorted().joined(separator: ", ")) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.picked.isEmpty)
                }
            }
        }
    }
}

private struct PermissionView: View {
    let controller: PixController
    let ask: PermissionAsk

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ask.title).font(.system(size: 14, weight: .semibold))
            Text(ask.detail)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(6)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Spacer()
                Button("Deny") { controller.permit(false) }
                // Scripts: Allow already remembers this exact one; "always" would let any script run unasked.
                if ask.tool.hasPrefix("mcp__") && Scripts.fingerprint(tool: ask.tool, input: ask.input) == nil {
                    Button("Always Allow") { controller.permit(true, always: true) }
                }
                Button("Allow") { controller.permit(true) }.buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct GuideView: View {
    let controller: PixController
    let guide: Guide

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if guide.index == 0 && !guide.answer.isEmpty {
                MathText(text: guide.answer, size: 14, weight: .semibold)
            }
            if guide.index < guide.steps.count {
                let step = guide.steps[guide.index]
                MathText(text: step.say, size: 14)
                if !step.work.isEmpty {
                    MathText(text: step.work, size: 14, latexLines: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if !step.why.isEmpty {
                    MathText(text: step.why, size: 12.5, secondary: true)
                }
                if !step.source.isEmpty {  // may hold math ("$\\int u\\,dv$"), so it's typeset like the rest
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 11)).foregroundStyle(.secondary)
                        MathText(text: step.source, size: 11.5, secondary: true)
                    }
                }
            }
            HStack {
                if guide.steps.count > 1 {
                    Text("\(guide.index + 1)/\(guide.steps.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                if guide.index > 0 { Button("Back") { controller.step(-1) } }
                Button(guide.isLast ? "Done" : "Next") { controller.step(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .overlay(alignment: .topTrailing) { CloseButton { controller.endGuide() } }
    }
}

struct DoneView: View {
    let controller: PixController
    let done: Done
    @ObservedObject var model: PixModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The whole answer, formatted; the card grows to fit and only scrolls past the screen's height.
            // Every change on the card undone: the answer ("the timer is running") no longer holds, so say so.
            if !model.actions.isEmpty, model.actions.allSatisfy({ model.undone.contains($0.id) }) {
                Label("Undone", systemImage: "arrow.uturn.backward").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            ScrollView {
                MathText(text: done.gist, size: 13.5, rich: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(!model.actions.isEmpty && model.actions.allSatisfy({ model.undone.contains($0.id) }) ? 0.45 : 1)
            }
            .frame(maxHeight: max(320, (NSScreen.main?.visibleFrame.height ?? 900) - 200))
            .fixedSize(horizontal: false, vertical: true)
            if done.next != nil || done.routine != nil || model.cameFrom != nil {
                HStack(spacing: 6) {
                    if let from = model.cameFrom {
                        Button { from == .welcome ? controller.showWelcome() : controller.showPermissions() } label: {
                            Label(from == .welcome ? "More to Try" : "Back to Permissions", systemImage: "chevron.left")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                    }
                    if let next = done.next {
                        Button { controller.take(next) } label: {
                            Label(next.label, systemImage: next.symbol).font(.system(size: 12.5, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                    }
                    if let r = done.routine {
                        Button { controller.saveRoutine(r) } label: {
                            Label("Save as Tool", systemImage: "bolt").font(.system(size: 12.5, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            if let hint = done.next?.costHint(members: model.deepMembers) {
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(model.actions) { a in
                HStack(spacing: 6) {
                    Image(systemName: a.symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                    Text(a.summary).font(.system(size: 12))
                        .strikethrough(model.undone.contains(a.id))
                        .foregroundStyle(model.undone.contains(a.id) ? .tertiary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if a.undo != nil {
                        Button(model.undone.contains(a.id) ? "Undone" : "Undo") { controller.undo(a) }
                            .controlSize(.small)
                            .disabled(model.undone.contains(a.id))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if let note = controller.model.note {
                Label(note.text, systemImage: note.symbol).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let who = model.answeredBy {
                Label(who, systemImage: "checkmark.seal").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    TextField("Ask a follow-up", text: $model.goal)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onSubmit { controller.followUp() }
                    if !model.goal.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button { controller.followUp() } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 17)).foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Ask")
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: Capsule())
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(done.gist, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12))
                        .foregroundStyle(copied ? Color.green : Color.secondary).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied" : "Copy Answer")
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
        .overlay(alignment: .topTrailing) { CloseButton { controller.reset() } }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

private struct FailedView: View {
    let controller: PixController
    let failure: Failure

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(failure.message).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                switch failure.fix {
                case .retry:
                    Button("Try Again") { controller.retry() }.buttonStyle(.borderedProminent)
                case .screenSettings:
                    Button("Open Settings") { controller.openScreenSettings() }.buttonStyle(.borderedProminent)
                case .signIn:
                    Button("Sign In") { ClaudeRunner.signIn(); controller.reset() }.buttonStyle(.borderedProminent)
                case .ollamaSignIn(let url):
                    Button("Sign In to Ollama") { controller.signInToOllama(url) }.buttonStyle(.borderedProminent)
                case .signInOrLite:
                    Button("Ask with Lite") { controller.retry(as: .lite) }
                    Button("Sign In") { ClaudeRunner.signIn(); controller.reset() }.buttonStyle(.borderedProminent)
                case .none:
                    Button("OK") { controller.reset() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .overlay(alignment: .topTrailing) { CloseButton { controller.reset() } }
    }
}

/// The way out of a card that stays up (an answer, a walkthrough, a problem). Esc does the same.
private struct CloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: 8, y: -8)
        .accessibilityLabel("Close")
    }
}

func tintColor(_ t: Tint) -> Color {
    let c = t.colors.bottom
    return Color(red: c.r, green: c.g, blue: c.b)
}

/// A softly pulsing dot in the blob's current color.
private struct StageDot: View {
    let color: Color
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .scaleEffect(on ? 1 : 0.7)
            .opacity(on ? 1 : 0.6)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .animation(.easeOut(duration: 0.4), value: color)
            .onAppear { on = true }
    }
}

/// Something Pix will use for this request. Click to leave it out.
private struct Chip: View {
    let label: String
    let symbol: String
    let color: Color
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Label(label, systemImage: symbol)
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).opacity(0.75)
            }
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(.white)
                .background(Capsule().fill(color))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(label)")
    }
}
