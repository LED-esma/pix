import AppKit
import Foundation

/// What Pix runs on: your Claude account, a model on this Mac (Ollama), big open models on
/// Ollama's own servers (Ollama Cloud's free tier), another AI service with your key (OpenRouter,
/// DeepSeek, Kimi… see Services), or a local gateway you run yourself. Every run still goes through
/// Claude Code; only where it sends requests changes. Teams run on Claude (they need its web search).
enum Provider: Equatable {
    case claude
    case local(model: String)                // an installed Ollama model, e.g. "deepseek-r1:8b"
    case gateway(url: String, model: String)  // anything that speaks the Anthropic API
    case cloud(model: String)                 // an Ollama Cloud model, e.g. "glm-5.3:cloud", through local Ollama
    case service(id: String, model: String)   // another AI with your key (Services), e.g. OpenRouter + "openai/gpt-6.1-sol"

    static let ollamaURL = "http://localhost:11434"
    static let omniRouteURL = "http://localhost:20128"

    /// The saved choice. Claude unless you picked something else.
    static var current: Provider {
        get {
            let d = UserDefaults.standard
            switch d.string(forKey: "provider") {
            case "local":
                if let m = d.string(forKey: "provider.model") { return .local(model: m) }
            case "gateway":
                return .gateway(url: d.string(forKey: "provider.url") ?? omniRouteURL,
                                model: d.string(forKey: "provider.model") ?? "auto")
            case "cloud":
                return .cloud(model: d.string(forKey: "provider.model") ?? Ollama.cloudDefault)
            case "service":
                if let id = d.string(forKey: "provider.service"), let s = Services.find(id) {
                    return .service(id: id, model: d.string(forKey: "provider.model") ?? s.model)
                }
            default: break
            }
            return .claude
        }
        set {
            let d = UserDefaults.standard
            switch newValue {
            case .claude:
                d.set("claude", forKey: "provider")
            case .local(let m):
                d.set("local", forKey: "provider"); d.set(m, forKey: "provider.model")
            case .gateway(let url, let m):
                d.set("gateway", forKey: "provider"); d.set(url, forKey: "provider.url"); d.set(m, forKey: "provider.model")
            case .cloud(let m):
                d.set("cloud", forKey: "provider"); d.set(m, forKey: "provider.model")
            case .service(let id, let m):
                d.set("service", forKey: "provider"); d.set(id, forKey: "provider.service"); d.set(m, forKey: "provider.model")
            }
        }
    }

    /// A stable name for the failover list: "claude", "local:qwen3:8b", "service:groq:llama-…".
    var key: String {
        switch self {
        case .claude: return "claude"
        case .local(let m): return "local:" + m
        case .cloud(let m): return "cloud:" + m
        case .service(let id, let m): return "service:\(id):" + m
        case .gateway(let url, let m): return "gateway:\(url)|" + m
        }
    }

    init?(key: String) {
        if key == "claude" { self = .claude; return }
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "local": self = .local(model: parts[1])
        case "cloud": self = .cloud(model: parts[1])
        case "service":
            let rest = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
            guard rest.count == 2 else { return nil }
            self = .service(id: rest[0], model: rest[1])
        case "gateway":
            let rest = parts[1].split(separator: "|", maxSplits: 1).map(String.init)
            guard rest.count == 2 else { return nil }
            self = .gateway(url: rest[0], model: rest[1])
        default: return nil
        }
    }

    var isClaude: Bool { self == .claude }
    var isLocal: Bool { if case .local = self { return true }; return false }
    var isCloud: Bool { if case .cloud = self { return true }; return false }
    var serviceName: String { if case .service(let id, _) = self { return Services.find(id)?.name ?? id }; return "" }

    /// Short name for the card and menu.
    var label: String {
        switch self {
        case .claude: return "Claude"
        case .local(let m): return m == AppleModel.id ? AppleModel.label : "This Mac · \(m)"
        case .gateway(let url, _): return url == Provider.omniRouteURL ? "OmniRoute" : "Gateway"
        case .cloud(let m): return "Ollama Cloud · \(Ollama.shortName(m))"
        case .service(_, let m): return "\(serviceName) · \(m)"
        }
    }

    /// The provider menu's own words for each option.
    var menuLabel: String {
        switch self {
        case .claude: return "Claude — best at doing things, uses your plan"
        case .local(let m): return m == AppleModel.id ? "Built-in — free and private, nothing to set up" : "This Mac — \(m), free and private"
        case .gateway: return "\(short) — free models"
        case .cloud(let m): return "Ollama Cloud — \(Ollama.shortName(m)), free tier"
        case .service(_, let m): return "\(serviceName) — \(m)"
        }
    }

    /// Who answered, in a sentence: "the model on this Mac couldn't answer".
    var who: String {
        switch self {
        case .claude: return "Claude"
        case .local(let m): return m == AppleModel.id ? "the built-in model" : "the model on this Mac"
        case .gateway(let url, _): return url == Provider.omniRouteURL ? "OmniRoute" : "the gateway"
        case .cloud: return "Ollama Cloud"
        case .service: return serviceName
        }
    }

    /// The card's mode label: "Lite · This Mac".
    var short: String {
        switch self {
        case .claude: return "Claude"
        case .local(let m): return m == AppleModel.id ? AppleModel.label : "This Mac"
        case .gateway(let url, _): return url == Provider.omniRouteURL ? "OmniRoute" : "Gateway"
        case .cloud: return "Ollama Cloud"
        case .service: return serviceName
        }
    }

    /// What Claude Code needs to talk to this provider instead of Anthropic.
    func environment(alias: String? = nil) -> [String: String] {
        func pointed(_ url: String, token: String, model: String) -> [String: String] {
            ["ANTHROPIC_BASE_URL": url, "ANTHROPIC_AUTH_TOKEN": token, "ANTHROPIC_API_KEY": "",
             "ANTHROPIC_MODEL": model, "ANTHROPIC_DEFAULT_OPUS_MODEL": model, "ANTHROPIC_DEFAULT_SONNET_MODEL": model,
             "ANTHROPIC_DEFAULT_HAIKU_MODEL": model, "ANTHROPIC_SMALL_FAST_MODEL": model,
             "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"]
        }
        switch self {
        case .claude:
            return [:]
        case .local(let m) where m == AppleModel.id:
            return ["ANTHROPIC_BASE_URL": AppleModel.marker, "ANTHROPIC_MODEL": AppleModel.id, "MAX_THINKING_TOKENS": "0"]  // runs in Pix's engine
        case .local(let m):
            // Thinking off: small reasoning models otherwise think for minutes before answering.
            return pointed(Provider.ollamaURL, token: "ollama", model: alias ?? Ollama.alias(for: m))
                .merging(["MAX_THINKING_TOKENS": "0"]) { $1 }
        case .cloud(let m):
            // Same local Ollama; it forwards cloud models to Ollama's servers under your Ollama account.
            return pointed(Provider.ollamaURL, token: "ollama", model: m)
        case .service(let id, let m):
            guard let s = Services.find(id) else { return [:] }
            let e = Services.endpoint(s)  // OpenAI-style services go through Pix's Translator
            return pointed(e.url, token: e.token, model: m)
        case .gateway(let url, let m):
            // OmniRoute answers without a key out of the box; if you set one up, it's read from your shell.
            let key = ClaudeRunner.shellEnvironment["OMNIROUTE_API_KEY"] ?? "omniroute"
            return pointed(url, token: key, model: m)
        }
    }

    // MARK: - Answers from free models

    /// A free model's reply as a Pix answer, or nil if it handed the question back.
    /// Reasoning models wrap their thinking in <think>…</think>; that's dropped.
    static func plainAnswer(_ text: String, goal: String = "") -> [String: Any]? {
        var t = text
        while let open = t.range(of: "<think>") {
            let close = t.range(of: "</think>", range: open.upperBound..<t.endIndex)
            t.removeSubrange(open.lowerBound..<(close?.upperBound ?? t.endIndex))
        }
        // "\n" written out as text becomes a line break; \nabla, \neq and other LaTeX (lowercase after \n) stay.
        t = tidyMath(t.replacingOccurrences(of: #"\\n(?![a-z])"#, with: "\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines))
        guard t.count > 1, !needsClaude(t) else { return nil }
        t = dropFakeButtons(t)
        return ["answer": t, "title": title(answer: t, goal: goal)]
    }

    /// The answer's own heading if it has one; otherwise the question, so Recent reads "Best deals on
    /// Home Depot tools", not "Since I can't browse the web" or "Result".
    static func title(answer: String, goal: String) -> String {
        func words(_ s: String) -> String {
            s.split(separator: " ").prefix(6).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ":.,?!$\\ "))
        }
        if let first = answer.split(separator: "\n").first, first.hasPrefix("#") {
            let h = words(Solo.headline(String(first)))
            if !h.isEmpty { return h }
        }
        var g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["please ", "can you ", "could you ", "give me ", "tell me ", "show me ", "help me "] where g.lowercased().hasPrefix(p) { g = String(g.dropFirst(p.count)) }
        let q = words(g)
        if !q.isEmpty { return q.prefix(1).uppercased() + q.dropFirst() }
        let h = words(Solo.headline(answer))
        return h.isEmpty ? "Pix" : h
    }

    /// Small models promise buttons that don't exist ("Tap to set one.", "Click here to…"). Those sentences go.
    static func dropFakeButtons(_ text: String) -> String {
        let pattern = #"(?m)(^|(?<=[.!?]) )(Tap|Click|Press) (here |the button |below )?(to|for) [^.!?\n]*[.!?]?"#
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Small models often write math as code ("`x^3`", "u * v") instead of LaTeX, which shows up in a
    /// typewriter font. When there's no LaTeX at all, that becomes ordinary text: x³, u · v.
    static func tidyMath(_ text: String) -> String {
        guard !text.contains("$"), !text.contains("\\("), !text.contains("\\[") else { return text }
        var t = text
        // Inline code that's really math loses its backticks; real code (no math signs) keeps them.
        t = t.replacingOccurrences(of: #"`([^`\n]*[=^][^`\n]*)`"#, with: "$1", options: .regularExpression)
        // Indented lines are code blocks in Markdown; math lines lose the indent.
        t = t.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = line.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("    ") && (s.contains("=") || s.contains("^")) ? s : String(line)
        }.joined(separator: "\n")
        let sup: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "-": "⁻"]
        while let r = t.range(of: #"\^\(?-?\d+\)?"#, options: .regularExpression) {
            let digits = t[r].filter { $0.isNumber || $0 == "-" }
            t.replaceSubrange(r, with: String(digits.compactMap { sup[$0] }))
        }
        return t.replacingOccurrences(of: " * ", with: " · ")
    }

    static func needsClaude(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("NEEDS_CLAUDE") || (t.count < 40 && t.contains("NEEDS_CLAUDE"))
    }

    /// Free runs cost nothing; Claude Code still prices them as if they were Claude.
    static func free(_ usage: [ClaudeRunner.Usage]) -> [ClaudeRunner.Usage] {
        usage.map { var u = $0; u.cost = 0; return u }
    }

    // MARK: - Checking what actually ran

    /// Claude Code's own report of which models answered, minus ones that did no work.
    private static func used(_ usage: [ClaudeRunner.Usage]) -> [String] {
        usage.filter { $0.total > 0 }.map(\.model)
    }

    /// "claude-sonnet-4-5-20250929" → "Sonnet"; "pix-deepseek-r1-8b" → the model you picked.
    static func name(_ model: String, ran p: Provider) -> String {
        let m = model.lowercased()
        if case .local(let picked) = p, m == Ollama.alias(for: picked) { return picked }
        if case .cloud = p, m.contains("cloud") { return Ollama.shortName(model) }
        guard m.contains("claude") else { return model }
        return ["opus", "sonnet", "haiku", "fable"].first(where: m.contains).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Claude"
    }

    /// One line for the card: who answered, confirmed from the usage report.
    static func answeredBy(_ usage: [ClaudeRunner.Usage], ran p: Provider) -> String? {
        var names: [String] = []
        for n in used(usage).map({ name($0, ran: p) }) where !names.contains(n) { names.append(n) }
        guard !names.isEmpty else { return nil }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        switch p {
        case .claude: return "Answered by Claude \(list)"
        case .local: return "Answered on this Mac by \(list)"
        case .cloud: return "Answered on Ollama Cloud by \(list)"
        case .service: return "Answered through \(p.serviceName) by \(list)"
        case .gateway: return "Answered through \(p.short) by \(list)"
        }
    }

    /// What ran when it isn't what you picked, e.g. Claude sneaking into a "This Mac" run, or a
    /// shell setting quietly sending "Claude" runs somewhere else. Nil when it all checks out.
    static func mismatch(_ usage: [ClaudeRunner.Usage], ran p: Provider) -> String? {
        let models = used(usage)
        guard !models.isEmpty else { return p.isClaude ? nil : "Pix couldn't confirm which model answered" }
        switch p {
        case .claude:
            let off = models.filter { !$0.lowercased().contains("claude") }
            return off.isEmpty ? nil : "Expected Claude, but \(off.joined(separator: ", ")) answered"
        case .local:
            let off = models.filter { !$0.lowercased().hasPrefix("pix-") }
            return off.isEmpty ? nil : "Expected only this Mac, but \(off.map { name($0, ran: p) }.joined(separator: ", ")) also answered"
        case .service(_, let picked):
            let off = models.filter { $0 != picked }
            return off.isEmpty ? nil : "Expected only \(p.serviceName), but \(off.joined(separator: ", ")) also answered"
        case .cloud(let picked):
            let off = models.filter { $0 != picked }
            return off.isEmpty ? nil : "Expected only Ollama Cloud, but \(off.map { name($0, ran: p) }.joined(separator: ", ")) also answered"
        case .gateway:
            return nil  // a gateway may route to any model, Claude included
        }
    }

    // MARK: - Finding a gateway

    /// True if something at `url` answers like an Anthropic-compatible gateway.
    static func gatewayRunning(_ url: String = omniRouteURL) async -> Bool {
        guard let u = URL(string: url + "/v1/models") else { return false }
        var req = URLRequest(url: u, timeoutInterval: 0.8)
        req.setValue("Bearer " + (ClaudeRunner.shellEnvironment["OMNIROUTE_API_KEY"] ?? "omniroute"), forHTTPHeaderField: "Authorization")
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse).map { (200..<500).contains($0.statusCode) } ?? false
    }
}

/// Models already on this Mac through Ollama. Pix never downloads one; it uses what's there.
enum Ollama {
    static let manifests = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ollama/models/manifests")

    /// Installed chat models, newest first. Read from disk, so Ollama needn't be running.
    static func installed(in root: URL = manifests) -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) else { return [] }
        var found: [(String, Date)] = []
        for case let file as URL in walker {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let name = modelName(manifest: file, root: root) else { continue }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            found.append((name, date))
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// ".../manifests/registry.ollama.ai/library/deepseek-r1/8b" → "deepseek-r1:8b".
    /// Pix's own aliases and embedding models aren't chat models, so they're skipped.
    static func modelName(manifest: URL, root: URL) -> String? {
        let parts = manifest.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count)
        guard parts.count == 4 else { return nil }
        let p = Array(parts)
        let (host, space, model, tag) = (p[0], p[1], p[2], p[3])
        guard !model.hasPrefix("pix-"), !model.contains("embed"), !tag.contains("cloud") else { return nil }  // cloud models run elsewhere
        let base = host == "registry.ollama.ai" ? (space == "library" ? model : "\(space)/\(model)") : "\(host)/\(space)/\(model)"
        return tag == "latest" ? base : "\(base):\(tag)"
    }

    /// Pix's copy of a model with room for a real conversation (Ollama defaults to a 4k context,
    /// too small for Claude Code). Only a few bytes: it points at the same weights.
    static func alias(for model: String) -> String {
        "pix-" + model.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "-" }.joined()
    }

    enum Problem: Error { case notInstalled, notRunning, missing(String), signedOut(URL?) }

    // MARK: - Ollama Cloud

    /// Strong at agent work and built with Claude Code in mind.
    static let cloudDefault = "glm-5.3:cloud"

    /// "glm-5.3:cloud" → "glm-5.3"; "gpt-oss:120b-cloud" → "gpt-oss:120b".
    static func shortName(_ model: String) -> String {
        model.replacingOccurrences(of: ":cloud", with: "").replacingOccurrences(of: "-cloud", with: "")
    }

    /// Ollama is on this Mac (app or command line), running or not.
    static var isInstalled: Bool {
        let fm = FileManager.default
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama") != nil
            || ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"].contains(where: fm.isExecutableFile)
    }

    enum Account: Equatable { case signedIn, signedOut(URL?), unknown }

    /// Whether Ollama is signed in to an ollama.com account (cloud models need one). When it
    /// isn't, Ollama hands back the page that connects this Mac.
    static func account() async -> Account {
        guard let url = URL(string: Provider.ollamaURL + "/api/me") else { return .unknown }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "POST"
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return .unknown }
        if code == 200 { return .signedIn }
        let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return code == 401 ? .signedOut((d?["signin_url"] as? String).flatMap(URL.init(string:))) : .unknown
    }

    /// Starts Ollama, checks the account, and fetches the cloud model's small pointer file if
    /// it isn't here yet (no weights: the model runs on Ollama's servers).
    static func prepareCloud(_ model: String) async throws {
        if !(await running()) {
            try start()
            for _ in 0..<40 where !(await running()) { try? await Task.sleep(for: .milliseconds(250)) }
            guard await running() else { throw Problem.notRunning }
        }
        if case .signedOut(let url) = await account() { throw Problem.signedOut(url) }
        if (try? await post("/api/show", ["model": model])) != nil { return }
        _ = try await post("/api/pull", ["model": model, "stream": false])
        Log.app.info("fetched \(model, privacy: .public)")
    }

    /// Starts Ollama if it isn't running and makes sure the model's alias exists. Returns the alias.
    static func prepare(_ model: String) async throws -> String {
        if !(await running()) {
            try start()
            for _ in 0..<40 where !(await running()) { try? await Task.sleep(for: .milliseconds(250)) }
            guard await running() else { throw Problem.notRunning }
        }
        let alias = alias(for: model)
        if (try? await post("/api/show", ["model": alias])) != nil { return alias }
        guard (try? await post("/api/show", ["model": model])) != nil else { throw Problem.missing(model) }
        _ = try await post("/api/create", ["model": alias, "from": model, "parameters": ["num_ctx": 32768], "stream": false])
        Log.app.info("created \(alias, privacy: .public)")
        return alias
    }

    static func running() async -> Bool {
        guard let url = URL(string: Provider.ollamaURL + "/api/version") else { return false }
        return (try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 0.6))) != nil
    }

    static func start() throws {
        let fm = FileManager.default
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama")
            ?? ["/Applications/Ollama.app", NSHomeDirectory() + "/Applications/Ollama.app"].first(where: fm.fileExists).map(URL.init(fileURLWithPath:)) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            NSWorkspace.shared.openApplication(at: app, configuration: config)
            return
        }
        guard let cli = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"].first(where: fm.isExecutableFile) else {
            throw Problem.notInstalled
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["serve"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    private static func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: URL(string: Provider.ollamaURL + path)!, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Problem.missing(path) }
        return data
    }
}


/// Failover, like OpenClaw: your AIs in the order you want them tried. The first answers; when it
/// errors or hits its limit, the next one that's available takes over and the card says so.
enum AIOrder {
    static var keys: [String] {
        get { UserDefaults.standard.stringArray(forKey: "ai.order") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "ai.order") }
    }

    /// Your order, limited to what's available now, with anything new added at the end.
    static func arrange(_ available: [Provider], first: Provider) -> [Provider] {
        var order = keys.compactMap(Provider.init(key:)).filter { available.contains($0) }
        if let i = order.firstIndex(of: first) { order.remove(at: i) }
        order.insert(first, at: 0)
        for p in available where !order.contains(p) { order.append(p) }
        return order
    }

    static func save(_ order: [Provider]) { keys = order.map(\.key) }

    /// Puts `p` first (picking an AI in the card does this).
    static func promote(_ p: Provider, available: [Provider]) {
        var o = arrange(available, first: p)
        o.removeAll { $0 == p }
        save([p] + o)
    }
}
