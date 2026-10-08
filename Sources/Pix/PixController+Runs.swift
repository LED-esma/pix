import AppKit
import ApplicationServices
import ServiceManagement

/// Starting work, events from Claude Code, questions and permissions, finishing.
extension PixController {
    /// Shows the setup card until Pix has an AI to answer with, then gets out of the way. Free AIs run on
    /// Pix's own engine, so a model on this Mac, a free key or a gateway is enough: Claude Code is only
    /// needed for Claude. A new Mac with a free AI and no Claude Code starts on that AI, with no card.
    func checkSetup() async {
        guard !checkingSetup else { return }  // a slow check is still running
        checkingSetup = true
        defer { checkingSetup = false }
        let r = await ClaudeRunner.readiness()
        claudeReady = r == .ready
        guard !model.adding else { return }  // adding an AI: the next check, after it's saved, decides (it once yanked the key field away)
        if r != .ready, model.provider.isClaude, Engine.on, !model.wantsClaude, let free = await firstFreeAI() {
            Log.app.notice("no Claude Code sign-in; starting on \(free.label, privacy: .public)")
            model.provider = free
        }
        if r == .ready || (!model.provider.isClaude && (r == .signedOut || Engine.on)) {
            setupPoll?.invalidate()
            setupPoll = nil
            if case .setup = model.phase {
                model.phase = .idle
                celebrate()
                firstRunWelcome()
                openBubble()
            }
            return
        }
        let waiting: Bool = { if case .setup(let s, true) = model.phase { return s == r }; return false }()
        model.phase = .setup(r, waiting: waiting)
        openBubble()
        if setupPoll == nil {
            setupPoll = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.checkSetup() }
            }
        }
    }

    /// A free AI that can answer right now: a model on this Mac, an AI added with a key, or a gateway.
    /// In the chosen order (2026-10-07): the built-in model, Gemini, OpenRouter, a model on this Mac, then the rest.
    func firstFreeAI() async -> Provider? {
        if AppleModel.available { return .local(model: AppleModel.id) }
        for id in ["gemini", "openrouter"] { if let s = Services.ready.first(where: { $0.id == id }) { return .service(id: s.id, model: s.model) } }
        if let m = Ollama.installed().first { return .local(model: m) }
        if let s = Services.ready.first { return .service(id: s.id, model: s.model) }
        if await Provider.gatewayRunning() { return .gateway(url: Provider.omniRouteURL, model: "auto") }
        return nil
    }

    func setUp() {
        guard case .setup(let state, _) = model.phase else { return }
        if state == .missing {
            // Claude Code's own installer: no admin password, lands in ~/.local/bin.
            if model.installFailed {  // the installer already failed once: the website has other ways
                NSWorkspace.shared.open(URL(string: "https://code.claude.com/docs/en/setup")!)
            } else {
                ClaudeRunner.install { [weak self] ok in
                    guard let self else { return }
                    self.model.installFailed = !ok
                    if !ok { self.model.phase = .setup(.missing, waiting: false); return }
                    Task { @MainActor in await self.checkSetup() }
                }
            }
        } else {
            ClaudeRunner.signIn()
        }
        model.phase = .setup(state, waiting: true)
    }

    /// Runs Lite on `p` from now on.
    func use(_ p: Provider) {
        model.provider = p
        AIOrder.promote(p, available: availableAIs)
        Log.app.info("provider: \(p.label, privacy: .public)")
        // Ollama Cloud needs an ollama.com account: if this Mac isn't connected yet, say so now
        // rather than at the first question.
        if case .cloud = p {
            Task { @MainActor in
                if case .signedOut(let url) = await Ollama.account() {
                    lastRequest = nil
                    model.phase = .failed(Failure(message: "Ollama isn't signed in, and its cloud models need an ollama.com account.", fix: .ollamaSignIn(url)))
                    openBubble()
                } else if case .setup = model.phase {
                    model.phase = .idle
                    openBubble()
                }
            }
            return
        }
        // Signed out but Claude Code is here: a free model needs nothing more, so no wait.
        if case .setup(.signedOut, _) = model.phase, !p.isClaude {
            setupPoll?.invalidate()
            setupPoll = nil
            model.phase = .idle
            openBubble()
        } else if case .setup = model.phase {
            Task { @MainActor in await checkSetup() }
        }
    }

    /// Finds the free options on this Mac: installed Ollama models (from disk, instant) and a
    /// running gateway. At most every 10 seconds, when the card opens.
    func refreshProviders() {
        guard Date().timeIntervalSince(providersChecked) > 10 else { return }
        providersChecked = Date()
        let models = (AppleModel.available ? [AppleModel.id] : []) + Ollama.installed()  // the built-in model first
        if models != model.localModels { model.localModels = models }
        Task { @MainActor in await Services.detectLocal() }  // LM Studio, llama.cpp
        let ollama = Ollama.isInstalled
        if ollama != model.ollamaInstalled { model.ollamaInstalled = ollama }
        // A model you removed from Ollama: switch to another one, or back to Claude.
        if case .local(let m) = model.provider, !models.contains(m) {
            model.provider = models.first.map { .local(model: $0) } ?? .claude
        }
        Task { @MainActor in
            let found = await Provider.gatewayRunning()
            if found != model.gatewayFound { model.gatewayFound = found }
            if !model.provider.isClaude { claudeReady = await ClaudeRunner.readiness() == .ready }
        }
    }

    func go() {
        guard case .idle = model.phase else { return }
        let goal = model.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        model.cameFrom = nil
        tried = []
        if model.welcome { Welcome.save(name: model.nameDraft) }
        model.welcome = false
        model.permissions = false
        let modeName = model.mode.rawValue
        Log.app.info("ask (\(modeName, privacy: .public)): \(goal, privacy: .private)")
        lastRequest = (goal, model.mode)
        retried = false
        recovered = false
        nudged = false
        runProject = model.projectOn ? model.project : nil
        let routine = model.mode == .lite ? Routines.match(goal) : nil  // "morning brief" runs the saved recipe
        let prompt = (runProject.map { $0.context(for: goal) + "\n\n" } ?? "") + model.prompt(for: routine?.steps ?? goal)
        lastPrompt = prompt
        model.mode == .lite ? startSolo(goal, prompt: prompt, screen: model.screenOn) : startTeam(goal, prompt: prompt, mode: model.mode)
        if let routine { model.note = .init(text: "Tool · \(routine.name)", symbol: "bolt") }
        model.goal = ""  // the field is for what's next; Stop puts the question back
    }

    func retry() {
        guard let r = lastRequest else { reset(); return }
        model.phase = .idle
        model.goal = r.goal
        model.mode = r.mode
        go()
    }

    /// The same question in another mode, just this once.
    func retry(as mode: Mode) {
        guard let r = lastRequest else { reset(); return }
        let usual = model.mode
        model.phase = .idle
        model.goal = r.goal
        model.mode = mode
        go()
        model.mode = usual
    }

    func begin(_ goal: String, mode: Mode, status: String) {
        runID += 1
        noteActivity()
        tearDownTour()
        model.note = nil
        model.answeredBy = nil
        runMode = mode
        model.runningMode = mode
        model.runningGoal = goal
        model.startedAt = Date()
        lastStatus = status
        model.phase = .working(status)
        model.activity = .thinking
        model.setTint(.base)
        shot = nil
        if bubble.isKeyWindow { bubble.resignKey() }
    }

    /// Standard and Deep: the app coordinates the crew itself (see Crew).
    /// Asks a follow-up right from the answer card.
    func followUp() {
        guard !model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.followUp = true
        tearDownTour()
        model.phase = .idle
        go()
    }

    func startTeam(_ goal: String, prompt: String? = nil, mode: Mode) {
        // Teams always run on Claude: they need web search and strong models at every step.
        if !model.provider.isClaude && !claudeReady {
            begin(goal, mode: mode, status: "Getting ready")
            fail("Standard and Deep run on Claude, and Pix isn't signed in.", fix: .signInOrLite)
            return
        }
        begin(goal, mode: mode, status: "Getting ready")
        if !model.provider.isClaude { model.note = .init(text: "Teams run on Claude", symbol: "person.3") }
        let c = Crew()
        crew = c
        c.tools = model.activeTools
        c.allTools = model.servers
        c.onStage = { [weak self] tint, s in self?.model.setTint(tint); self?.statusText(s) }
        c.onStatus = { [weak self] s in self?.statusText(s) }
        c.onAsk = { [weak self] r, id, input in self?.ask(from: r, id: id, input: input) }
        c.onPermission = { [weak self] r, id, tool, input in self?.permission(from: r, id: id, tool: tool, input: input) }
        let work = PixPaths.home.appendingPathComponent("work/\(Solo.today())-\(Solo.slug(goal))")
        let members = mode == .deep ? model.deepMembers : 1
        Task { @MainActor in
            do {
                let out = try await c.run(goal: prompt ?? goal, members: members, work: work)
                guard crew === c else { return }
                crew = nil
                finish(out, usage: c.usage, mode: mode)
                if !c.shortfall.isEmpty, model.note == nil {
                    model.note = .init(text: "The team finished without " + c.shortfall.joined(separator: " and "), symbol: "person.3")
                }
            } catch Crew.CrewError.cancelled {
            } catch {
                guard crew === c else { return }
                crew = nil
                fail(Self.friendly("\(error)", team: true), fix: .retry)
            }
        }
    }

    func startSolo(_ goal: String, prompt: String? = nil, screen: Bool, on chosen: Provider? = nil) {
        let ask = prompt ?? goal
        // The first question that needs Reminders or Calendar asks macOS for access, then carries on.
        if BuiltIn.needed(goal), Access.undetermined {
            begin(goal, mode: .lite, status: "Thinking")
            let id = runID
            Task { @MainActor in
                await Access.request()
                guard runID == id, case .working = model.phase else { return }
                startSolo(goal, prompt: prompt, screen: screen, on: chosen)
            }
            return
        }
        var p = chosen ?? model.provider
        // The built-in model slips on arithmetic: math with numbers goes to the next AI in your order, if there is one.
        if chosen == nil, case .local(let m) = p, m == AppleModel.id, AppleModel.tooHard(goal),
           let better = availableAIs.first(where: { $0 != p && (!$0.isClaude || claudeReady) }) {
            p = better
            handOffNote = "\(better.short) did this one; the built-in model slips on arithmetic"
        }
        // Auto: quick questions stay on your AI; doing things goes to Claude, which is much faster at it.
        if Auto.on, chosen == nil, p.isLocal || p.isCloud, claudeReady, Auto.needsDoer(goal) {
            p = .claude
            handOffNote = "Claude did this one; it's quicker at doing things"
        }
        // A model on this Mac can't see your screen or use your tools. Claude can, if you're signed in.
        var handOff: String?
        // Your apps come along; if a free model skips them, its answer is dropped (see finishSolo).
        if (p.isLocal || p.isCloud), claudeReady, screen {
            handOff = "it needed your screen"
            p = .claude
        }
        runProvider = p
        runApps = model.activeTools
        appsChecked = []
        toolsUsed = []
        runToken = UUID().uuidString
        runApps0 = [:]
        RunLog.record("started", run: runToken, ["provider": p.label, "mode": "lite", "apps": runApps, "project": runProject?.name ?? ""])
        // Every model gets Pix's tools. Guessing from keywords when a small model needed them missed
        // plain asks ("hardware store deals") and left it saying it couldn't browse.
        runBuiltIn = true
        if case .local(let name) = p {
            startLocal(goal, ask: ask, model: name)
            if let n = handOffNote { model.note = .init(text: n, symbol: "sparkles"); handOffNote = nil }
            return
        }
        if case .cloud(let name) = p {
            startCloud(goal, ask: ask, model: name)
            if let n = handOffNote { model.note = .init(text: n, symbol: "sparkles"); handOffNote = nil }
            return
        }
        begin(goal, mode: .lite, status: screen ? "Looking at your screen" : "Thinking")
        if let handOff { model.note = .init(text: "Claude answered this one; \(handOff)", symbol: "arrow.uturn.forward") }
        else if let n = handOffNote { model.note = .init(text: n, symbol: "sparkles") }
        handOffNote = nil
        let folder = runProject?.root
        let claudeModel = Solo.claudeModel(for: goal, screen: screen, project: folder != nil, tools: model.activeTools)
        let args = p.isClaude ? Solo.args(today: Solo.today(), tools: model.activeTools, allTools: model.servers, run: runToken, project: folder, model: claudeModel)
                              : Solo.gatewayArgs(today: Solo.today(), tools: model.activeTools, allTools: model.servers, run: runToken, project: folder)
        let env = p.environment()
        guard screen else {
            launch(args, prompt: .text(ask), provider: env)
            return
        }
        model.setTint(.look)
        if !UserDefaults.standard.bool(forKey: "askedAX") {
            UserDefaults.standard.set(true, forKey: "askedAX")
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        let display = buddy.screen ?? dockScreen
        Task { @MainActor in
            do {
                let s = try await Screen.capture(display)
                guard case .working = model.phase else { return }  // stopped meanwhile
                shot = s
                statusText("Reading your screen")
                launch(args, prompt: .image(s.jpeg, mediaType: "image/jpeg", text: Screen.context(s) + "\n\n" + ask), provider: env)
            } catch Screen.GrabError.denied {
                fail("Pix can't see your screen yet.", fix: .screenSettings)
            } catch {
                fail("Pix couldn't take a screenshot.", fix: .retry)
            }
        }
    }

    /// Lite on a model on this Mac: start Ollama if needed, then a lean run. Anything that goes
    /// wrong hands the question to Claude.
    func startLocal(_ goal: String, ask: String, model name: String) {
        begin(goal, mode: .lite, status: "Thinking on this Mac")
        let id = runID
        Task { @MainActor in
            do {
                if name != AppleModel.id, !(await Ollama.running()) { statusText("Starting the model on this Mac") }
                let alias = name == AppleModel.id ? name : try await Ollama.prepare(name)  // the built-in model needs no starting
                guard runID == id, case .working = model.phase else { return }  // stopped or replaced meanwhile
                launch(Solo.localArgs(today: Solo.today(), model: alias, tools: runApps, allTools: model.servers,
                                      builtIn: runBuiltIn, run: runToken, project: runProject?.root), prompt: .text(ask),
                       provider: runProvider.environment(alias: alias), timeout: 420)
            } catch {
                guard runID == id, case .working = model.phase else { return }
                Log.app.error("local model: \(String(describing: error), privacy: .public)")
                fallBack("the model on this Mac didn't start")
            }
        }
    }

    /// Lite on Ollama Cloud: big open models on Ollama's servers, through the Ollama on this Mac.
    /// Strong enough for the full Lite (board, walkthroughs); WebSearch is Anthropic-only, so it's left out.
    func startCloud(_ goal: String, ask: String, model name: String) {
        begin(goal, mode: .lite, status: "Thinking on Ollama Cloud")
        let id = runID
        Task { @MainActor in
            do {
                try await Ollama.prepareCloud(name)
                guard runID == id, case .working = model.phase else { return }
                launch(Solo.gatewayArgs(today: Solo.today(), tools: runApps, allTools: model.servers, run: runToken, project: runProject?.root),
                       prompt: .text(ask), provider: runProvider.environment(), timeout: 300)
            } catch Ollama.Problem.signedOut(let url) {
                guard runID == id else { return }
                fail("Ollama isn't signed in, and its cloud models need an ollama.com account.", fix: .ollamaSignIn(url))
            } catch {
                guard runID == id, case .working = model.phase else { return }
                Log.app.error("cloud model: \(String(describing: error), privacy: .public)")
                fallBack("Ollama Cloud didn't start")
            }
        }
    }

    /// Opens ollama.com's page that connects this Mac, then carries on by itself once it's done.
    func signInToOllama(_ url: URL?) {
        if let url { NSWorkspace.shared.open(url) }
        else if let cli = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"].first(where: FileManager.default.isExecutableFile) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["signin"]
            p.standardInput = FileHandle.nullDevice
            try? p.run()
        }
        let pending = lastRequest
        begin(pending?.goal ?? "Ollama Cloud", mode: .lite, status: "Waiting for Ollama sign-in")
        let id = runID
        Task { @MainActor in
            for _ in 0..<90 {  // three minutes
                try? await Task.sleep(for: .seconds(2))
                guard runID == id, case .working = model.phase else { return }  // stopped meanwhile
                if await Ollama.account() == .signedIn {
                    Log.app.notice("ollama signed in")
                    if pending != nil { retry() } else { reset(); openBubble() }
                    return
                }
            }
            guard runID == id else { return }
            fail("Ollama still isn't signed in.", fix: .ollamaSignIn(url))
        }
    }

    /// A free model couldn't answer: Claude takes over if you're signed in.
    /// What could answer right now, in your failover order (the card's AI first).
    var availableAIs: [Provider] {
        // Unless you've arranged them: Claude (when you have it), then free in the chosen order: built-in,
        // Gemini, OpenRouter, other services, models on this Mac, Ollama Cloud.
        var list: [Provider] = []
        if claudeReady || model.provider.isClaude { list.append(.claude) }
        if model.localModels.contains(AppleModel.id) { list.append(.local(model: AppleModel.id)) }
        let services = Services.ready.sorted { a, b in
            let rank = { (id: String) in ["gemini": 0, "openrouter": 1][id] ?? 2 }
            return rank(a.id) < rank(b.id)
        }
        for s in services {
            if case .service(let id, let m) = model.provider, id == s.id { list.append(.service(id: id, model: m)) }
            else { list.append(.service(id: s.id, model: s.model)) }
        }
        list += model.localModels.filter { $0 != AppleModel.id }.map { .local(model: $0) }
        if model.ollamaInstalled {
            if case .cloud(let m) = model.provider { list.append(.cloud(model: m)) } else { list.append(.cloud(model: Ollama.cloudDefault)) }
        }
        return AIOrder.arrange(list, first: model.provider)
    }

    /// The next AI in your order that hasn't tried this question yet.
    var nextAI: Provider? {
        availableAIs.first { p in !tried.contains(p.key) && (!p.isClaude || claudeReady) }
    }

    func fallBack(_ why: String) {
        runner?.stop()
        runner = nil
        let from = runProvider
        tried.insert(from.key)
        if let next = nextAI, !next.isClaude || claudeReady, let req = lastRequest {
            // Your failover order: the next AI takes over, and the card says who and why.
            Log.app.notice("failing over to \(next.label, privacy: .public): \(why, privacy: .public)")
            startSolo(req.goal, prompt: lastPrompt, screen: false, on: next)
            model.note = .init(text: "\(next.short) answered this one; \(why)", symbol: "arrow.uturn.forward")
            return
        }
        guard claudeReady, let req = lastRequest, !tried.contains("claude") else {
            let message = why.contains("web")
                ? "That one needs the web, which \(from.who) can't reach."
                : "\(from.who.prefix(1).uppercased() + from.who.dropFirst()) couldn't answer that one."
            fail(message, fix: ClaudeRunner.claudeURL() == nil ? .retry : .signIn)
            return
        }
        Log.app.notice("handing off to Claude: \(why, privacy: .public)")
        startSolo(req.goal, prompt: lastPrompt, screen: false, on: .claude)
        model.note = .init(text: "Claude answered this one; \(why)", symbol: "arrow.uturn.forward")
    }

    func launch(_ args: [String], prompt: ClaudeRunner.Prompt, provider: [String: String] = [:], timeout baseTimeout: Double = 180) {
        let timeout = Auto.on ? max(baseTimeout, 1800) : baseTimeout  // Auto keeps going until done; Stop is always there
        do {
            var current: AgentRun?
            // Claude runs on Claude Code; every other AI on Pix's own engine (nothing else to install).
            let r = try Engine.runner(arguments: args, provider: provider) { [weak self] event in
                MainActor.assumeIsolated {
                    // Events from a run you stopped (or one that was replaced) are ignored.
                    guard let self, let current, self.runner === current else { return }
                    self.handle(event)
                }
            }
            current = r
            runner = r
            try r.start(prompt)
            // A stuck call (say, a web search that never returns) shouldn't leave Pix "working" forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self, weak r] in
                guard let self, let r, self.runner === r else { return }
                if self.runProvider.isClaude { self.fail(Self.friendly("timed out"), fix: .retry) }
                else { self.fallBack("\(self.runProvider.who) took too long") }
            }
        } catch ClaudeRunner.RunError.notInstalled {
            Task { @MainActor in await checkSetup() }
        } catch {
            fail("Pix couldn't start Claude Code.", fix: .retry)
        }
    }

    // MARK: - Events from Claude Code

    func handle(_ event: ClaudeRunner.Event) {
        switch event {
        case .ready(let apps):
            runApps0 = apps
            RunLog.record("ready", run: runToken, ["apps": apps])
        case .status(let s):
            status(s)
        case .stage(let s, let detail):
            if let t = Tint.from(s) {
                model.setTint(t)
                // "Evaluating · checking the factoring": the stage plus what Pix says it's doing.
                if let label = t.label { statusText(detail.map { "\(label) · \($0)" } ?? label) }
            }
        case .ask(let id, let input):
            if let runner { ask(from: runner, id: id, input: input) }
        case .permission(let id, let tool, let input):
            if let runner { permission(from: runner, id: id, tool: tool, input: input) }
        case .unsupportedControl:
            break
        case .result(let r):
            runner?.finish()
            runner = nil
            if r.isError {
                let trouble = Trouble.classify(r.text, subtype: r.subtype)
                if recoverOnce(trouble) { return }
                RunLog.record("failed", run: runToken, ["trouble": trouble.rawValue, "detail": String(r.text.prefix(200))])
                if !runProvider.isClaude {
                    fallBack("\(runProvider.who) couldn't answer")
                } else if [.usageLimit, .overloaded, .rateLimit, .offline, .timeout].contains(trouble), nextAI != nil {
                    fallBack(trouble == .usageLimit ? "Claude hit its limit" : "Claude couldn't answer")  // your failover order
                } else if trouble == .signedOut {
                    Task { @MainActor in await checkSetup() }
                } else if trouble == .tooManySteps {
                    fail("Pix took too many steps on that one.", fix: .retry)
                } else {
                    fail(Self.friendly(r.text), fix: .retry)
                }
            } else {
                finishSolo(r)  // only Lite runs through `runner`; teams go through Crew
            }
        case .failed(let msg):
            runner = nil
            let trouble = Trouble.classify(msg)
            if recoverOnce(trouble) { return }
            RunLog.record("failed", run: runToken, ["trouble": trouble.rawValue, "detail": String(msg.prefix(200))])
            if runProvider.isClaude, nextAI == nil { fail(msg, fix: .retry) } else { fallBack("\(runProvider.who) stopped") }
        }
    }

    /// A passing hiccup (busy, rate limited, briefly offline) gets one quiet retry after a short
    /// pause before you see an error. Returns true if it's retrying.
    func recoverOnce(_ trouble: Trouble) -> Bool {
        guard trouble.transient, !recovered, let req = lastRequest, req.mode == .lite else { return false }
        recovered = true
        RunLog.record("recovered", run: runToken, ["trouble": trouble.rawValue])
        runner?.stop()
        runner = nil
        statusText(trouble == .offline ? "Reconnecting · trying again" : "Claude is busy · trying again")
        let id = runID, provider = runProvider
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.runID == id, case .working = self.model.phase else { return }  // stopped meanwhile
            self.startSolo(req.goal, prompt: self.lastPrompt, screen: false, on: provider)
        }
        return true
    }

    /// Plain-English versions of what Claude Code reports when something goes wrong.
    nonisolated static func friendly(_ raw: String, team: Bool = false) -> String {
        let t = raw.lowercased()
        if t.contains("usage limit") || t.contains("limit reached") || t.contains("quota") || t.contains("session limit") || t.contains("weekly limit") {
            // "… · resets 2:10pm (America/Los_Angeles)" → "It resets at 2:10pm."
            if let r = raw.range(of: #"resets [0-9:]+ ?[ap]m"#, options: [.regularExpression, .caseInsensitive]) {
                return "You've hit your Claude limit. It " + raw[r].lowercased() + "."
            }
            return "You've hit your Claude usage limit. It resets on its own."
        }
        if t.contains("rate limit") || t.contains("429") { return "Claude is getting a lot of requests right now." }
        if t.contains("overloaded") || t.contains("529") || t.contains("503") { return "Claude is busy right now." }
        if t.contains("timed out") { return team ? "Part of the team took too long to answer." : "Claude took too long to answer." }
        if t.contains("network") || t.contains("offline") || t.contains("connection") { return "Pix can't reach Claude. This Mac looks offline." }
        return (team ? "The team hit a problem: " : "Pix hit a problem: ") + String(raw.prefix(140))
    }

    func ask(from r: AgentRun, id: String, input: [String: Any]) {
        if askingYou { queuedAsks.append { [weak self, weak r] in if let r { self?.ask(from: r, id: id, input: input) } }; return }
        let qs = PixModel.questions(from: input)
        guard !qs.isEmpty else { r.allow(id, input: input); return }
        if Auto.on {  // no questions in Auto: the recommended (first) choice, named on the card
            r.allow(id, input: Headless.autoAnswer(input))
            model.note = .init(text: "Picked " + qs.compactMap { $0.options.first?.label }.joined(separator: ", "), symbol: "sparkles")
            return
        }
        asker = r
        model.otherAnswer = ""
        model.picked = []
        model.phase = .question(QuestionFlow(requestID: id, input: input, questions: qs))
        needsYou()
    }

    func permission(from r: AgentRun, id: String, tool: String, input: [String: Any]) {
        // Clicking or typing in Pix's browser: asks only for what submits, buys, sends, signs in or deletes.
        if BuiltIn.browserActs.contains(tool.replacingOccurrences(of: BuiltIn.prefix, with: "")) {
            Task { @MainActor [weak self, weak r] in
                guard let self, let r else { return }
                if let q = await PixBrowser.shared.risk(tool: tool, input: input) { self.askPermission(from: r, id: id, tool: tool, input: input, question: q) }
                else { r.allow(id, input: input) }
            }
            return
        }
        // Clicking and typing in your apps: asks only for what sends, buys, deletes or signs in.
        if ScreenControl.acts.contains(tool.replacingOccurrences(of: BuiltIn.prefix, with: "")) {
            if let q = ScreenControl.shared.risk(tool: tool, input: input) { askPermission(from: r, id: id, tool: tool, input: input, question: q) }
            else { r.allow(id, input: input) }
            return
        }
        // Tools are saved when you ask for one (or tap Save as Tool), never on a model's own initiative.
        if tool == BuiltIn.prefix + "tool_save", !Self.askedForTool(model.runningGoal) {
            r.deny(id, message: "Only save a tool when the user asks for one. Answer without saving.")
            return
        }
        // Reading your data never asks; Pix's own changes don't either (they come with Undo).
        if Toolbox.isReadOnly(tool) || BuiltIn.allowedWithoutAsking(tool) { r.allow(id, input: input); return }
        // Edits inside the project you called Pix from: done at once, with Undo.
        if ProjectEdits.allow(tool: tool, input: input, project: runProject?.root, run: runToken) { r.allow(id, input: input); return }
        // A script you approved before runs again without asking (the exact same text only).
        if Scripts.approved(tool: tool, input: input) { r.allow(id, input: input); return }
        // Auto: no Allow cards, except for what can't be taken back.
        if Auto.on, let ok = Self.autoAllows(tool: tool, input: input) {
            if ok { r.allow(id, input: input); return }
        }
        askPermission(from: r, id: id, tool: tool, input: input)
    }

    nonisolated static func askedForTool(_ goal: String) -> Bool {
        let g = goal.lowercased()
        return ["tool", "save this", "save that", "save it", "remember how", "routine"].contains { g.contains($0) }
    }

    /// In Auto: true = go ahead, false = still ask, nil = the usual rules decide.
    nonisolated static func autoAllows(tool: String, input: [String: Any]) -> Bool? {
        let name = tool.replacingOccurrences(of: BuiltIn.prefix, with: "")
        switch name {
        // A Shortcut can do anything; one whose name sounds like it can't be taken back still asks.
        case "shortcut_run": return !Auto.destructive(" " + (input["name"] as? String ?? "") + " ")
            && !["delete", "remove", "send", "post", "pay", "buy", "clear", "erase", "trash", "text ", "message", "email"].contains { (input["name"] as? String ?? "").lowercased().contains($0) }
        case "applescript_run", "shell_run": return !Auto.destructive((input["script"] ?? input["command"]) as? String ?? "")
        default:
            guard tool.hasPrefix("mcp__") else { return nil }  // Claude Code's own (file changes, commands) keep asking
            let risky = ["delete", "remove", "trash", "send", "post", "publish", "pay", "purchase", "buy", "transfer", "cancel", "erase"]
            return risky.contains { name.lowercased().contains($0) } ? false : true
        }
    }

    func askPermission(from r: AgentRun, id: String, tool: String, input: [String: Any], question: String? = nil) {
        if askingYou { queuedAsks.append { [weak self, weak r] in if let r { self?.askPermission(from: r, id: id, tool: tool, input: input, question: question) } }; return }
        asker = r
        model.phase = .permission(PermissionAsk(requestID: id, tool: tool, input: input, question: question))
        needsYou()
    }

    /// Status line only; the crew sets colors per stage itself.
    func statusText(_ s: String) {
        lastStatus = s
        if case .working = model.phase { model.phase = .working(s) }
    }

    func status(_ s: String) {
        lastStatus = s
        if let t = Tint.from(s) { model.setTint(t) }
        if case .working = model.phase { model.phase = .working(s) }
    }

    func needsYou() {
        model.activity = .alert
        openBubble()
    }

    func answer(_ text: String) {
        guard case .question(var flow) = model.phase else { return }
        let a = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        flow.answers[flow.current.text] = a
        model.otherAnswer = ""
        model.picked = []
        if flow.index + 1 < flow.questions.count {
            flow.index += 1
            model.phase = .question(flow)
            return
        }
        var input = flow.input
        input["answers"] = flow.answers
        (asker ?? runner)?.allow(flow.requestID, input: input)
        backToWork()
    }

    func permit(_ yes: Bool, always: Bool = false) {
        guard case .permission(let ask) = model.phase else { return }
        if yes && always { Toolbox.alwaysAllow(ask.tool) }
        if yes { Scripts.approve(tool: ask.tool, input: ask.input) }
        if yes { (asker ?? runner)?.allow(ask.requestID, input: ask.input) }
        else { (asker ?? runner)?.deny(ask.requestID, message: "The user said no. Continue without it.") }
        backToWork()
    }

    func backToWork() {
        if !queuedAsks.isEmpty {
            model.phase = .working(lastStatus)
            queuedAsks.removeFirst()()
            return
        }
        model.phase = .working(lastStatus)
        model.activity = .thinking
        if bubble.isKeyWindow { bubble.resignKey() }
    }

    func stop() {
        stepCancel?()
        stepCancel = nil
        Clipboard.restore(run: runToken)
        queuedAsks.removeAll()
        runner?.stop()
        runner = nil
        crew?.cancel()
        crew = nil
        tearDownTour()
        model.phase = .idle
        model.activity = .idle
        model.setTint(.base)
        model.goal = model.runningGoal  // nothing lost: the goal is back in the field
        openBubble()
    }

    func finishSolo(_ r: ClaudeRunner.Result) {
        appsChecked = runApps.filter { app in r.toolsCalled.contains { $0.hasPrefix(Toolbox.prefix(app) + "__") } }
        toolsUsed = r.toolsCalled.compactMap(BuiltIn.label(forTool:)).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        // Auto doesn't take "I couldn't find it" for an answer the first time: one push to dig another way.
        if Auto.on, !nudged, Auto.gaveUp(r.text), let req = lastRequest {
            nudged = true
            RunLog.record("nudged", run: runToken, ["hint": "dig"])
            statusText("Trying another way")
            startSolo(req.goal, prompt: Auto.digHint + "\n\n" + (lastPrompt ?? req.goal), screen: false, on: runProvider)
            return
        }
        // A free model that skipped the tools the question needed gets one nudge, then Claude takes over.
        switch Judge.verdict(goal: model.runningGoal, claude: runProvider.isClaude, toolsCalled: r.toolsCalled, apps: runApps, nudged: nudged,
                             project: runProject != nil) {
        case .accept: break
        case .nudge(let hint):
            nudged = true
            RunLog.record("nudged", run: runToken, ["hint": hint])
            statusText("Looking it up")
            if let req = lastRequest { startSolo(req.goal, prompt: hint + "\n\n" + (lastPrompt ?? req.goal), screen: false, on: runProvider) }
            return
        case .handOff(let why):
            Log.app.notice("dropped a free answer: \(why, privacy: .public)")
            fallBack(why.replacingOccurrences(of: "it didn't", with: "\(runProvider.who) didn't"))
            return
        }
        // Small models skip `remember`; things you say about yourself are kept by Pix itself (shown with Undo).
        if !runProvider.isClaude, !r.toolsCalled.contains(where: { $0.hasSuffix("__remember") }) {
            for fact in Memory.add(Memory.selfFacts(from: model.runningGoal)) {
                Actions.log("remember", "Remembered: \(fact)", undo: ["type": "memory_forget", "fact": fact], run: runToken)
            }
        }
        if !runProvider.isClaude {
            // A free model: the full answer format if it managed it, else its plain reply. Otherwise Claude takes over.
            let out = runProvider.isLocal ? Provider.plainAnswer(r.text, goal: model.runningGoal) : (Solo.output(r) ?? Provider.plainAnswer(r.text, goal: model.runningGoal))
            if let out { finish(out, usage: Provider.free(r.usage), mode: .lite) }
            else { fallBack(Provider.needsClaude(r.text) ? "it needed the web" : "\(runProvider.who) couldn't answer") }
            return
        }
        guard let out = Solo.output(r) else {
            // Models occasionally return an empty answer; one quiet retry fixes nearly all of them.
            if !retried, let req = lastRequest {
                retried = true
                startSolo(req.goal, prompt: lastPrompt, screen: shot != nil)
                return
            }
            fail("Pix couldn't finish that one.", fix: .retry)
            return
        }
        retried = false
        finish(out, usage: r.usage, mode: .lite)
    }

    /// Lite and teams end the same way: save the run, open the board, then the walkthrough or the answer.
    func finish(_ out: [String: Any], usage: [ClaudeRunner.Usage], mode: Mode) {
        // A tool Pix built for itself gets tested and installed first, so the canvas can use it.
        if let spec = out["plugin"] as? [String: Any], !(spec["js"] as? String ?? "").isEmpty {
            statusText("Testing a new tool")
            var rest = out
            rest.removeValue(forKey: "plugin")
            Task { @MainActor in
                switch await Forge.install(spec) {
                case .installed(let name, let version):
                    model.note = .init(text: version > 1 ? "Improved its \(name) tool" : "Built itself a new tool: \(name)", symbol: "hammer")
                case .rejected(let name, let reason):
                    Log.forge.notice("not kept: \(reason, privacy: .public)")
                    model.note = .init(text: "Built a \(name) tool, but it failed its test, so it wasn't kept", symbol: "hammer")
                }
                finish(rest, usage: usage, mode: mode)
            }
            return
        }
        let steps = Screen.steps(from: out, shot: shot, snap: true)
        let path = Solo.save(out, goal: model.runningGoal, steps: steps, mode: mode.rawValue.lowercased())
        lastRunPath = path
        model.actions = mode == .lite ? Actions.forRun(runToken) : []
        model.undone = []
        refreshSchedules()
        if model.goal == model.runningGoal { model.goal = "" }  // the field is for what's next, not what you just asked
        model.context = PixModel.Context(goal: model.runningGoal, summary: PixModel.recap(out), at: Date())
        model.followUp = true
        if let path, !usage.isEmpty { TokenReport.apply(file: path, ledger: ledger, mode: mode.rawValue.lowercased(), usage: usage) }
        // Learn what a team costs next to a quick Claude answer (app work has many turns, so it isn't "quick").
        if mode != .lite || (runProvider.isClaude && !toolsUsed.contains("your screen")) {
            TeamCost.record(mode, seconds: Date().timeIntervalSince(model.startedAt), cost: usage.reduce(0) { $0 + $1.cost })
        }
        let answer = ClaudeRunner.splitReply(out["answer"] as? String ?? "").gist
        Clipboard.restore(run: runToken)
        speakIfWanted(answer)
        overlay.unsay()  // "Clicking …" is over once the answer is in
        celebrate()
        NSSound(named: "Glass")?.play()
        showBoard(Visual.all(from: out))
        let next = mode == .lite ? Next.from(out["next"], servers: model.servers) : nil
        // Offer to keep it as a tool: the same mix of tools asked for twice, or a script that worked.
        let mix = Set(toolsUsed + appsChecked.map(Toolbox.label))
        let earlier = RunLog.recent(400).filter { $0["type"] as? String == "finished" && $0["run"] as? String != runToken }
            .contains { Set($0["tools"] as? [String] ?? []) == mix }
        let scripts = model.actions.filter { $0.kind == "applescript_run" || $0.kind == "shell_run" }
        let worked = scripts.compactMap { a in a.detail.map { "```\(a.kind == "shell_run" ? "sh" : "applescript")\n\($0)\n```" } }
        let offer: (name: String, steps: String)? = mode == .lite && (mix.count >= 2 && earlier || !worked.isEmpty) && Routines.match(model.runningGoal) == nil
            ? ((out["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "My Tool",
               model.runningGoal + (worked.isEmpty ? "" : "\n\nWhat worked last time (run it the same way):\n" + worked.joined(separator: "\n"))) : nil
        // Partial success is first-class: an app that failed to start is named, not silently missing.
        let wanted = Set((mode == .lite ? runApps : []) + [BuiltIn.server])
        let downApps = runApps0.filter { wanted.contains($0.key) && $0.value == "failed" }.map(\.key).sorted()
        if !downApps.isEmpty { RunLog.record("degraded", run: runToken, ["apps": downApps]) }
        RunLog.record("finished", run: runToken, ["tools": toolsUsed + appsChecked, "mode": mode.rawValue.lowercased()])
        // Check what actually ran against what you picked, from Claude Code's own usage report.
        let ran: Provider = mode == .lite ? runProvider : .claude
        // Who answered is shown only when it says something: another model, or an app it checked.
        let apps = mode == .lite ? appsChecked.map(Toolbox.label) + toolsUsed : []
        model.answeredBy = ran.isClaude && apps.isEmpty ? nil : Provider.answeredBy(usage, ran: ran).map { who in
            apps.isEmpty ? who : who + " · checked " + apps.joined(separator: ", ")
        }
        let learned = Memory.add(out["remember"])
        if let down = downApps.first {
            let name = down == BuiltIn.server ? "Pix's own tools" : Toolbox.label(down)
            model.note = .init(text: "\(name) didn't start, so Pix answered without \(down == BuiltIn.server ? "them" : "it")", symbol: "exclamationmark.triangle")
        } else if let off = Provider.mismatch(usage, ran: ran) {
            Log.app.error("provider check: \(off, privacy: .public)")
            model.note = .init(text: off, symbol: "exclamationmark.triangle")
        } else if model.note == nil, !learned.isEmpty {
            model.note = .init(text: "Remembered: " + learned.joined(separator: "; "), symbol: "brain")
        }
        if !Screen.walkthrough(steps) {  // one step that only restates the answer reads twice; show the answer
            model.phase = .done(Done(gist: Solo.cardText(out), path: path, next: next, routine: offer))
            openBubble()
        } else {
            model.phase = .guide(Guide(answer: Solo.headline(answer), steps: steps, path: path))
            present(0)
        }
    }

    /// Asks the same question the way Pix suggested: a team, with your screen, or with one of your apps.
    func take(_ next: Next) {
        let goal = model.runningGoal, mode = model.mode
        tearDownTour()
        model.phase = .idle
        model.goal = goal
        model.followUp = false
        switch next {
        case .team(let m): model.mode = m
        case .screen: model.mode = .lite; model.screenOverride = true
        case .use(let server): model.mode = .lite; model.toolOverride[server] = true
        }
        go()
        model.mode = mode  // a one-off; your usual mode stays
        model.screenOverride = nil
        model.toolOverride = [:]
    }

    func celebrate() {
        model.setTint(.build)
        model.activity = .happy
        happyTimer?.invalidate()
        happyTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.model.activity == .happy { self?.model.activity = .idle }
                if case .working = self?.model.phase {} else { self?.model.setTint(.base) }
            }
        }
    }

    func fail(_ message: String, fix: Failure.Fix) {
        Log.app.error("failed: \(message, privacy: .public)")
        Clipboard.restore(run: runToken)
        speakIfWanted(message)
        overlay.unsay()  // "Clicking …" is over
        runner?.stop()
        runner = nil
        tearDownTour()
        model.phase = .failed(Failure(message: message, fix: fix))
        model.activity = .idle
        model.setTint(.base)
        if roaming { endRoaming() }
        openBubble()
    }

    func reset() {
        defer { runPending() }  // a scheduled question that waited for you
        let answered: Bool = { if case .done = model.phase { return true }; return false }()
        tearDownTour()
        model.phase = .idle
        model.activity = .idle
        model.setTint(.base)
        model.screenOverride = nil
        model.toolOverride = [:]
        if model.goal == model.runningGoal { model.goal = "" }
        model.followUp = false  // the next question in the main field starts fresh
        spokenRun = false
        closeBubble()
        if answered { teachSummon() }
    }


    func openScreenSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        reset()
    }

    // MARK: - History

    /// Reopens a saved answer with its board and walkthrough; follow-ups pick up from it.
    func reopen(_ dataPath: String) {
        guard let saved = History.load(dataPath) else { return }
        if case .working = model.phase { return }
        tearDownTour()
        shot = nil
        model.note = nil
        model.runningGoal = saved.goal
        lastRunPath = saved.runPath
        model.answeredBy = nil
        model.context = PixModel.Context(goal: saved.goal, summary: PixModel.recap(saved.output), at: Date())
        model.followUp = true
        let steps = Screen.steps(from: saved.output, shot: nil, snap: false)
        let answer = ClaudeRunner.splitReply(saved.output["answer"] as? String ?? "").gist
        showBoard(Visual.all(from: saved.output))
        if !Screen.walkthrough(steps) {
            model.phase = .done(Done(gist: Solo.cardText(saved.output), path: saved.runPath))
            openBubble()
        } else {
            model.phase = .guide(Guide(answer: Solo.headline(answer), steps: steps, path: saved.runPath))
            present(0)
        }
    }
}
