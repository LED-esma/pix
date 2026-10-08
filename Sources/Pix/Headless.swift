import AppKit
import WebKit

/// Command-line modes for testing and benchmarks, no UI:
///   Pix --ask "<goal>" <out.json> [members]   members 0 = Lite (default), 1 = Standard, 2+ = Deep
///       --on local|cloud|gateway   run Lite on the newest model on this Mac, Ollama Cloud, or OmniRoute
///   Pix --render-canvas <answer.json | page.html> <out.png>
/// Questions get the first (recommended) option; read-only tool use is allowed, anything else denied.
@MainActor
enum Headless {
    static func ask(goal: String, out: String, members: Int, image: String? = nil, use: [String] = [], after: String? = nil,
                    on provider: Provider = .claude) -> Never {
        // --after <previous answer.json>: ask as a follow-up, the way the app does.
        let asked = goal  // the question as typed, for the judge
        Headless.asked = goal
        let steps = Routines.match(goal)?.steps ?? goal  // a routine's name runs its saved steps, as in the app
        var goal = after == nil ? PixModel.withMemory(steps) : steps  // what the app sends: your memory, then the question
        if let after, let d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: after)))) as? [String: Any],
           let prev = d["output"] as? [String: Any] {
            let m = PixModel()
            m.context = PixModel.Context(goal: d["goal"] as? String ?? "", summary: PixModel.recap(prev), at: Date())
            goal = m.prompt(for: goal)
        }
        _ = NSApplication.shared  // Pix's browser window needs an app, even without a Dock icon
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            await Bridge.start()
            await Translator.start()
            let t0 = Date()
            var record: [String: Any] = ["goal": goal, "members": members]
            do {
                var tools: [String] = [], all: [String] = []
                if !use.isEmpty {
                    let t = Date()
                    all = await Toolbox.discover()
                    tools = all.filter { s in use.contains { s.lowercased().contains($0.lowercased()) } }
                    record["discoverSeconds"] = Date().timeIntervalSince(t)
                    record["tools"] = tools
                }
                if members == 0 {
                    var r = try await solo(projectContext + goal, image: image, tools: tools, all: all, on: provider)
                    // Same policy as the app: a free model that skipped the tools it needed gets one nudge.
                    var verdict = Judge.verdict(goal: asked, claude: provider.isClaude, toolsCalled: r.toolsCalled, apps: tools, nudged: false, project: project != nil)
                    // Auto: an answer that gave up gets one push to dig another way, as in the app.
                    if Auto.on, Auto.gaveUp(r.text), case .accept = verdict {
                        print("  · pushed to dig another way")
                        record["nudged"] = "dig"
                        let first = r.toolsCalled
                        r = try await solo(Auto.digHint + "\n\n" + projectContext + goal, image: image, tools: tools, all: all, on: provider)
                        r.toolsCalled = first + r.toolsCalled
                    }
                    if case .nudge(let hint) = verdict {
                        print("  · nudged: \(hint.prefix(60))…")
                        record["nudged"] = hint
                        let first = r.toolsCalled
                        r = try await solo(hint + "\n\n" + projectContext + goal, image: image, tools: tools, all: all, on: provider)
                        r.toolsCalled = first + r.toolsCalled
                        verdict = Judge.verdict(goal: asked, claude: provider.isClaude, toolsCalled: r.toolsCalled, apps: tools, nudged: true, project: project != nil)
                    }
                    record["provider"] = provider.label
                    let parsed = provider.isLocal ? Provider.plainAnswer(r.text, goal: goal)
                        : provider.isClaude ? Solo.output(r) : (Solo.output(r) ?? Provider.plainAnswer(r.text, goal: goal))
                    record["output"] = parsed ?? ["raw": r.text]
                    if !provider.isClaude && parsed == nil { record["handOff"] = Provider.needsClaude(r.text) ? "needs web" : "no answer" }
                    record["answeredBy"] = Provider.answeredBy(r.usage, ran: provider) ?? "unknown"
                    record["check"] = Provider.mismatch(r.usage, ran: provider) ?? "ok"
                    record["toolsCalled"] = r.toolsCalled
                    record["actions"] = Actions.forRun(run).map(\.summary)
                    if case .handOff(let why) = verdict { record["handOff"] = why }
                    if !provider.isClaude, !r.toolsCalled.contains(where: { $0.hasSuffix("__remember") }) {
                        record["selfFacts"] = Memory.selfFacts(from: asked)  // what the app would keep (not saved in a test run)
                    }
                    if let o = parsed { record["next"] = o["next"] ?? ""; record["remember"] = o["remember"] ?? [] }
                    if let spec = (record["output"] as? [String: Any])?["plugin"] as? [String: Any] {
                        switch await Forge.install(spec) {
                        case .installed(let n, let v): record["forge"] = "installed \(n) v\(v)"
                        case .rejected(let n, let why): record["forge"] = "rejected \(n): \(why)"
                        }
                        print("  forge: \(record["forge"]!)")
                    }
                    record["usage"] = json(provider.isClaude ? r.usage : Provider.free(r.usage))
                    record["timing"] = ["startup": r.startup, "firstReply": r.firstReply, "total": r.total,
                                        "apiSeconds": Double(r.apiMs) / 1000, "turns": r.turns, "searches": r.searches]
                } else {
                    let c = Crew()
                    c.onAsk = { r, id, input in r.allow(id, input: autoAnswer(input)) }
                    c.onPermission = { r, id, tool, input in
                        Toolbox.isReadOnly(tool) ? r.allow(id, input: input) : r.deny(id, message: "Denied in a headless run.")
                    }
                    c.onStage = { _, s in print("  \(s)…") }
                    c.onStatus = { s in print("    · \(s)") }
                    let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pix-headless")
                    do {
                        record["output"] = try await c.run(goal: goal, members: members, work: work)
                    } catch {
                        record["timeline"] = c.timeline
                        throw error
                    }
                    record["usage"] = json(c.usage)
                    record["timeline"] = c.timeline
                }
            } catch {
                record["error"] = "\(error)"
            }
            record["seconds"] = (Date().timeIntervalSince(t0) * 10).rounded() / 10
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: out))
            }
            let total = (record["usage"] as? [[String: Any]] ?? []).reduce(0) { $0 + ($1["total"] as? Int ?? 0) }
            print("\(record["error"] == nil ? "done" : "error: \(record["error"]!)") in \(record["seconds"]!)s, \(total) tokens → \(out)")
            exit(record["error"] == nil ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    static let run = "headless-" + UUID().uuidString
    nonisolated(unsafe) static var asked = ""  // the question as typed (picks Haiku or Sonnet)
    /// `--project <folder>`: ask as if called from a terminal in that folder.
    nonisolated(unsafe) static var project: Project?
    static var projectContext: String { project.map { $0.context(for: asked) + "\n\n" } ?? "" }

    private static func solo(_ goal: String, image: String?, tools: [String], all: [String], on provider: Provider) async throws -> ClaudeRunner.Result {
        var args = Solo.args(today: Solo.today(), tools: tools, allTools: all, run: run, project: project?.root,
                             model: Solo.claudeModel(for: Headless.asked, screen: image != nil, project: project != nil, tools: tools)), env: [String: String] = [:]
        switch provider {
        case .claude: break
        case .local(let m):
            let alias = m == AppleModel.id ? m : try await Ollama.prepare(m)
            args = Solo.localArgs(today: Solo.today(), model: alias, tools: tools, allTools: all, builtIn: true, run: run, project: project?.root)
            env = provider.environment(alias: alias)
        case .gateway, .service:
            args = Solo.gatewayArgs(today: Solo.today(), tools: tools, allTools: all, run: run, project: project?.root)
            env = provider.environment()
        case .cloud(let m):
            try await Ollama.prepareCloud(m)
            args = Solo.gatewayArgs(today: Solo.today(), tools: tools, allTools: all, run: run)
            env = provider.environment()
        }
        let runner = try Engine.runner(arguments: args, provider: env)
        return try await withCheckedThrowingContinuation { cont in
            var done = false
            runner.onEvent = { event in
                switch event {
                case .result(let r): runner.finish(); if !done { done = true; cont.resume(returning: r) }
                case .failed(let m): if !done { done = true; cont.resume(throwing: Crew.CrewError.failed(m)) }
                case .status(let st): print("  · \(st)")
                case .stage(let st, let d): print("  · \(st)\(d.map { " — \($0)" } ?? "")")
                case .ask(let id, let input): runner.allow(id, input: autoAnswer(input))
                case .permission(let id, let tool, let input):
                    if BuiltIn.browserActs.contains(tool.replacingOccurrences(of: BuiltIn.prefix, with: "")) {
                        // No one to ask in a headless run: safe clicks go ahead, risky ones are refused.
                        Task { @MainActor in
                            let q = await PixBrowser.shared.risk(tool: tool, input: input)
                            if let q { print("  · refused: \(q)"); runner.deny(id, message: "The user didn't allow that.") } else { runner.allow(id, input: input) }
                        }
                    } else if tool == BuiltIn.prefix + "tool_save", !PixController.askedForTool(goal) {
                        runner.deny(id, message: "Only save a tool when the user asks for one. Answer without saving.")
                    } else if ScreenControl.acts.contains(tool.replacingOccurrences(of: BuiltIn.prefix, with: "")) {
                        Task { @MainActor in
                            if let q = ScreenControl.shared.risk(tool: tool, input: input) { print("  · refused: \(q)"); runner.deny(id, message: "The user didn't allow that.") }
                            else { runner.allow(id, input: input) }
                        }
                    } else if ProjectEdits.allow(tool: tool, input: input, project: project?.root, run: run) {
                        runner.allow(id, input: input)
                    } else if Auto.on, let ok = PixController.autoAllows(tool: tool, input: input) {
                        if ok { runner.allow(id, input: input) } else { print("  · refused (can't be undone): \(tool)"); runner.deny(id, message: Auto.refusal) }
                    } else {
                        Toolbox.isReadOnly(tool) || BuiltIn.allowedWithoutAsking(tool) || Scripts.approved(tool: tool, input: input)
                            ? runner.allow(id, input: input) : runner.deny(id, message: "Denied.")
                    }
                default: break
                }
            }
            var prompt = ClaudeRunner.Prompt.text(goal)
            if let image, let data = FileManager.default.contents(atPath: image), let rep = NSBitmapImageRep(data: data) {
                prompt = .image(data, mediaType: image.hasSuffix(".png") ? "image/png" : "image/jpeg",
                                text: "Screenshot: \(rep.pixelsWide)x\(rep.pixelsHigh) pixels. Frontmost app: Preview.\n\n" + goal)
            }
            do { try runner.start(prompt) } catch { done = true; cont.resume(throwing: error) }
            // Same time limits as the app (local 7 min, cloud and services 5, Claude 3), so a stuck run ends.
            let limit: Double = Auto.on ? 1200 : provider.isLocal ? 420 : provider.isClaude ? 180 : 300
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
                guard !done else { return }
                done = true
                runner.stop()
                cont.resume(throwing: Crew.CrewError.failed("timed out after \(Int(limit)) s"))
            }
        }
    }

    static func autoAnswer(_ input: [String: Any]) -> [String: Any] {
        var i = input
        var answers: [String: String] = [:]
        for q in PixModel.questions(from: input) {
            answers[q.text] = q.options.first?.label ?? ""
            print("  ? \(q.text)  [\(q.options.map(\.label).joined(separator: " | "))] → \(q.options.first?.label ?? "")")
        }
        i["answers"] = answers
        return i
    }

    private static func json(_ usage: [ClaudeRunner.Usage]) -> [[String: Any]] {
        var byModel: [String: ClaudeRunner.Usage] = [:]
        for u in usage {
            var m = byModel[u.model] ?? ClaudeRunner.Usage(model: u.model, fresh: 0, cached: 0, output: 0, cost: 0)
            m.fresh += u.fresh; m.cached += u.cached; m.output += u.output; m.cost += u.cost
            byModel[u.model] = m
        }
        return byModel.values.map { ["model": $0.model, "fresh": $0.fresh, "cached": $0.cached, "output": $0.output,
                                     "total": $0.total, "cost": $0.cost] }
    }

    // MARK: - Canvas timing

    /// Pix --time-canvas <page.html>: prints how long a canvas takes to load its plugins and finish drawing.
    static func timeCanvas(_ input: String) -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let html = (try? String(contentsOfFile: input, encoding: .utf8)) ?? ""
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        let window = NSWindow(contentRect: NSRect(x: origin.x, y: origin.y, width: 900, height: 640),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        let web = CanvasWebView()
        web.frame = window.contentView!.bounds
        window.contentView!.addSubview(web)
        window.orderFrontRegardless()
        let t0 = Date()
        var loaded: Double?
        web.onLoaded = { loaded = Date().timeIntervalSince(t0) }
        web.show(html)
        let ready = #"(() => { const out = [...document.querySelectorAll(".pix-out")].map(e => e.textContent).join(""); return document.querySelectorAll("canvas, svg, .katex, .pix-out").length > 0 && !out.includes("Starting Python") && !(document.querySelector(".pix-out") && out === ""); })()"#
        func poll() {
            web.evaluateJavaScript(ready) { value, _ in
                let elapsed = Date().timeIntervalSince(t0)
                if (value as? Bool) == true || elapsed > 30 {
                    print(String(format: "{\"load\": %.3f, \"ready\": %.3f}", loaded ?? -1, elapsed))
                    exit(0)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { poll() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
        RunLoop.main.run()
        exit(0)
    }

    /// Pix --focus-canvas <page.html> <target> [target…]: where each walkthrough target is, then a snapshot.
    static func focusCanvas(_ input: String, targets: [String], out: String) -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let html = (try? String(contentsOfFile: input, encoding: .utf8)) ?? ""
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        let window = NSWindow(contentRect: NSRect(x: origin.x, y: origin.y, width: 900, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        let web = CanvasWebView()
        web.frame = window.contentView!.bounds
        window.contentView!.addSubview(web)
        window.orderFrontRegardless()
        web.show(html)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            for t in targets {
                let r = await web.focusRect(t)
                print("\(t): \(r.map { "x \(Int($0.minX - window.frame.minX)) y \(Int(window.frame.maxY - $0.maxY)) w \(Int($0.width)) h \(Int($0.height))" } ?? "not found")")
            }
            try? await Task.sleep(for: .seconds(3.2))
            web.takeSnapshot(with: nil) { image, _ in
                if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                exit(0)
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    // MARK: - Canvas snapshots

    /// Pix --render-math "<text>" <out.png> [lines]: the card's math typesetting, for checking.
    /// `text` can also be a saved answer (~/Pix/runs/.data/*.json): renders its full page.
    static func renderMath(_ text: String, out: String, lines: Bool) -> Never {
        var text = text
        if text.hasSuffix(".json"), let saved = History.load(text) {
            text = Solo.page(saved.output, steps: Screen.steps(from: saved.output, shot: nil, snap: false))
        }
        let file = NSTemporaryDirectory() + "pix-math.html"
        try? MathText.html(text, size: 15, bold: false, secondary: false, latexLines: lines)
            .write(toFile: file, atomically: true, encoding: .utf8)
        renderCanvas(input: file, out: out)
    }

    static func renderCanvas(input: String, out: String) -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var html = (try? String(contentsOfFile: input, encoding: .utf8)) ?? ""
        var plugins: [String] = []
        if input.hasSuffix(".json"),
           let d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: input)))) as? [String: Any] {
            let answer = d["output"] as? [String: Any] ?? d
            for v in Visual.all(from: answer) { if case .canvas(_, let h, let p) = v { html = h; plugins = p; break } }
        }
        // A nearly invisible on-screen window: WebKit pauses animation frames in off-screen ones.
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        let window = NSWindow(contentRect: NSRect(x: origin.x, y: origin.y, width: 900, height: 640),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        let web = CanvasWebView()
        web.frame = window.contentView!.bounds
        window.contentView!.addSubview(web)
        window.orderFrontRegardless()
        web.show(html, plugins: plugins)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            web.takeSnapshot(with: nil) { image, error in
                if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    print("rendered → \(out)")
                    exit(0)
                }
                print("render failed: \(error.map { "\($0)" } ?? "no image")")
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }
}
