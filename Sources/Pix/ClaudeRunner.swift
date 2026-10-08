import AppKit
import Foundation

enum PixPaths {
    static let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pix")
    static let runs = home.appendingPathComponent("runs")
}

/// Runs Claude Code headless (`claude -p`) and speaks its stream-json protocol:
/// status from tool calls, questions and permission asks routed back to us, and
/// the final result with token usage.
final class ClaudeRunner {
    enum Prompt {
        case text(String)
        case image(Data, mediaType: String, text: String)
    }

    struct Usage {
        var model: String
        var fresh: Int    // new input, including cache writes
        var cached: Int   // cache reads (cheap)
        var output: Int
        var cost: Double
        var total: Int { fresh + cached + output }
    }

    struct Result {
        var text: String
        var isError: Bool
        var tokens: Int
        var cost: Double
        var structured: [String: Any]?
        var usage: [Usage] = []
        // Timing, for benchmarks (seconds unless noted)
        var startup = 0.0      // process launch → Claude Code ready (init message)
        var firstReply = 0.0   // launch → first model output
        var total = 0.0        // launch → result
        var apiMs = 0          // time spent waiting on the model, per Claude Code
        var turns = 0
        var searches = 0
        var toolsCalled: [String] = []  // every tool the model actually called, in order
        var subtype = ""                 // "success", "error_max_turns", …
    }

    enum Event {
        case ready(apps: [String: String])  // Claude Code is up; each app (MCP server) "connected" or "failed"
        case status(String)
        case stage(String, String?)  // "research"/"evaluate"/"build" and what it's doing, from a "Stage: x — …" line
        case ask(id: String, input: [String: Any])
        case permission(id: String, tool: String, input: [String: Any])
        case unsupportedControl(id: String)
        case result(Result)
        case failed(String)
    }

    enum RunError: Error { case notInstalled }

    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let queue = DispatchQueue(label: "pix.runner")
    private var buffer = Data()
    private var errorTail = Data()
    private var finished = false
    private var stopped = false
    private var launchedAt = Date()
    private var readyAt: Date?
    private var repliedAt: Date?
    private var toolsCalled: [String] = []
    /// Always called on the main thread, in order. Can be set after init.
    var onEvent: ((Event) -> Void)?

    /// `provider` points Claude Code at a model other than Claude (see Provider).
    init(arguments: [String], provider: [String: String] = [:], onEvent: ((Event) -> Void)? = nil) throws {
        guard let claude = ClaudeRunner.claudeURL() else { throw RunError.notInstalled }
        process.executableURL = claude
        process.arguments = arguments
        try? FileManager.default.createDirectory(at: PixPaths.runs, withIntermediateDirectories: true)
        process.currentDirectoryURL = PixPaths.home
        process.environment = ClaudeRunner.environment().merging(provider) { $1 }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        self.onEvent = onEvent
    }

    func start(_ prompt: Prompt) throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; return }
            self.queue.async { self.consume(d) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; return }
            self.queue.async {
                self.errorTail.append(d)
                if self.errorTail.count > 4000 { self.errorTail = self.errorTail.suffix(4000) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            // Let any last output drain before deciding it died early.
            self.queue.asyncAfter(deadline: .now() + 0.3) {
                guard !self.finished, !self.stopped else { return }
                self.finished = true
                let err = String(decoding: self.errorTail, as: UTF8.self)
                    .split(separator: "\n").last.map(String.init) ?? ""
                Log.runner.error("exited early: \(err, privacy: .public)")
                self.emit(.failed(err.isEmpty ? "Pix stopped unexpectedly." : "Pix stopped unexpectedly: \(err)"))
            }
        }
        launchedAt = Date()
        let model = process.arguments?.firstIndex(of: "--model").map { process.arguments![$0 + 1] } ?? "?"
        Log.runner.info("launch \(model, privacy: .public)")
        try process.run()
        send(["type": "control_request", "request_id": "init", "request": ["subtype": "initialize"]])

        let content: Any
        switch prompt {
        case .text(let t):
            content = t
        case .image(let data, let type, let text):
            content = [
                ["type": "image", "source": ["type": "base64", "media_type": type,
                                             "data": data.base64EncodedString()]],
                ["type": "text", "text": text],
            ]
        }
        send(["type": "user", "message": ["role": "user", "content": content]])
    }

    func allow(_ id: String, input: [String: Any]) {
        reply(id, ["behavior": "allow", "updatedInput": input])
    }

    func deny(_ id: String, message: String) {
        reply(id, ["behavior": "deny", "message": message])
    }

    /// Done listening: lets Claude Code exit once it's idle.
    func finish() {
        queue.async { [input] in try? input.fileHandleForWriting.close() }
    }

    /// Stops the run. Nothing more is delivered after this (`stopped` is only touched on `queue`).
    func stop() {
        queue.sync { stopped = true }
        if process.isRunning { process.terminate() }
        Log.runner.info("stopped")
    }

    // MARK: - Protocol

    private func reply(_ id: String, _ response: [String: Any]) {
        send(["type": "control_response",
              "response": ["subtype": "success", "request_id": id, "response": response]])
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        queue.async { [input] in
            try? input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if readyAt == nil, line.range(of: Data(#""subtype":"init""#.utf8)) != nil { readyAt = Date() }
            if repliedAt == nil, line.range(of: Data(#""type":"assistant""#.utf8)) != nil { repliedAt = Date() }
            if line.range(of: Data(#""tool_use""#.utf8)) != nil { toolsCalled += ClaudeRunner.toolCalls(in: Data(line)) }
            if let raw = ProcessInfo.processInfo.environment["PIX_RAW"], let h = FileHandle(forWritingAtPath: raw) {  // debugging: every line Claude Code sends
                h.seekToEndOfFile(); h.write(Data(line) + Data("\n".utf8)); try? h.close()
            }
            for var event in ClaudeRunner.events(from: Data(line)) {
                if case .result(var r) = event {
                    let now = Date()
                    r.startup = (readyAt ?? now).timeIntervalSince(launchedAt)
                    r.firstReply = (repliedAt ?? now).timeIntervalSince(launchedAt)
                    r.total = now.timeIntervalSince(launchedAt)
                    r.toolsCalled = toolsCalled
                    event = .result(r)
                    Log.runner.info("result \(r.isError ? "error" : "ok", privacy: .public) in \(r.total, format: .fixed(precision: 1))s, \(r.tokens) tokens, \(r.turns) turns")
                }
                switch event {
                case .unsupportedControl(let id):
                    send(["type": "control_response",
                          "response": ["subtype": "error", "request_id": id, "error": "Not supported by Pix"]])
                case .result:
                    // A run can report a result while background work continues, so the
                    // controller decides when it's really over and calls finish().
                    finished = true
                    emit(event)
                default:
                    emit(event)
                }
            }
        }
    }

    private func emit(_ event: Event) {
        guard !stopped else { return }
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    // MARK: - Parsing (pure, covered by the self-check)

    static func events(from line: Data) -> [Event] {
        guard let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return [] }
        switch d["type"] as? String {
        case "system" where d["subtype"] as? String == "init":
            var apps: [String: String] = [:]
            for s in d["mcp_servers"] as? [[String: Any]] ?? [] {
                if let name = s["name"] as? String { apps[name] = s["status"] as? String ?? "" }
            }
            return [.ready(apps: apps)]
        case "control_request":
            guard let id = d["request_id"] as? String, let req = d["request"] as? [String: Any] else { return [] }
            guard req["subtype"] as? String == "can_use_tool" else { return [.unsupportedControl(id: id)] }
            let tool = req["tool_name"] as? String ?? ""
            let input = req["input"] as? [String: Any] ?? [:]
            return tool == "AskUserQuestion" ? [.ask(id: id, input: input)]
                                             : [.permission(id: id, tool: tool, input: input)]
        case "assistant":
            let blocks = (d["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return blocks.compactMap { b in
                if b["type"] as? String == "text", let (stage, detail) = stage(in: b["text"] as? String ?? "") {
                    return .stage(stage, detail)
                }
                guard b["type"] as? String == "tool_use", let name = b["name"] as? String,
                      let s = status(tool: name, input: b["input"] as? [String: Any] ?? [:]) else { return nil }
                return .status(s)
            }
        case "result":
            func n(_ u: [String: Any], _ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
            let usage = (d["modelUsage"] as? [String: Any] ?? [:]).compactMap { model, value -> Usage? in
                guard let u = value as? [String: Any] else { return nil }
                return Usage(model: model, fresh: n(u, "inputTokens") + n(u, "cacheCreationInputTokens"),
                             cached: n(u, "cacheReadInputTokens"), output: n(u, "outputTokens"),
                             cost: (u["costUSD"] as? NSNumber)?.doubleValue ?? 0)
            }.sorted { $0.total > $1.total }
            let isError = (d["is_error"] as? Bool ?? false) || (d["subtype"] as? String ?? "success") != "success"
            var r = Result(text: d["result"] as? String ?? "", isError: isError,
                           tokens: usage.reduce(0) { $0 + $1.total },
                           cost: (d["total_cost_usd"] as? NSNumber)?.doubleValue ?? 0,
                           structured: d["structured_output"] as? [String: Any], usage: usage)
            r.apiMs = (d["duration_api_ms"] as? NSNumber)?.intValue ?? 0
            r.subtype = d["subtype"] as? String ?? ""
            r.turns = (d["num_turns"] as? NSNumber)?.intValue ?? 0
            r.searches = (d["modelUsage"] as? [String: Any] ?? [:]).values
                .reduce(0) { $0 + ((($1 as? [String: Any])?["webSearchRequests"] as? NSNumber)?.intValue ?? 0) }
            return [.result(r)]
        default:
            return []
        }
    }

    /// Names of the tools an assistant message really called (not text that only looks like a call).
    static func toolCalls(in line: Data) -> [String] {
        guard let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], d["type"] as? String == "assistant" else { return [] }
        let blocks = (d["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { $0["type"] as? String == "tool_use" ? $0["name"] as? String : nil }
    }

    /// The last "Stage: x — what I'm doing" marker in a block of text.
    static func stage(in text: String) -> (String, String?)? {
        var found: (String, String?)?
        for line in text.split(separator: "\n") {
            let raw = line.trimmingCharacters(in: .whitespaces)
            guard raw.lowercased().hasPrefix("stage:") else { continue }
            let rest = raw.dropFirst(6).trimmingCharacters(in: .whitespaces)
            let word = rest.prefix { $0.isLetter }.lowercased()
            guard ["research", "evaluate", "build"].contains(word) else { continue }
            var detail = rest.dropFirst(word.count).trimmingCharacters(in: CharacterSet(charactersIn: " —–-:·."))
            detail = detail.replacingOccurrences(of: "*", with: "")
            found = (word, detail.isEmpty ? nil : String(detail.prefix(48)))
        }
        return found
    }

    static func status(tool: String, input: [String: Any]) -> String? {
        switch tool {
        case "WebSearch":
            let q = input["query"] as? String ?? ""
            return q.isEmpty ? "Searching" : "Searching “\(q.prefix(40))”"
        case "WebFetch":
            let host = URL(string: input["url"] as? String ?? "")?.host ?? ""
            return host.isEmpty ? "Reading a page" : "Reading \(host)"
        case "Write", "Edit":
            return "Writing"
        case "StructuredOutput":
            return "Writing the answer"
        case BuiltIn.prefix + "shell_run", BuiltIn.prefix + "applescript_run":
            let what = tool.hasSuffix("shell_run") ? "Running a command" : "Running AppleScript"
            return (input["why"] as? String).map { "\(what) · \($0.prefix(40))" } ?? what
        case BuiltIn.prefix + "screen_look": return "Looking at the screen"
        case BuiltIn.prefix + "folder_list": return "Looking through the folder"
        case BuiltIn.prefix + "files_organize": return "Organizing"
        case BuiltIn.prefix + "files_move": return "Moving files"
        case BuiltIn.prefix + "screen_click", BuiltIn.prefix + "screen_type", BuiltIn.prefix + "screen_key": return "Working in the app"
        case BuiltIn.prefix + "screen_show": return "Showing you"
        case let t where t.hasPrefix(BuiltIn.prefix + "use_"):
            return "Using a saved tool"
        case BuiltIn.prefix + "tool_save":
            return "Saving the tool"
        default:
            return tool.hasPrefix("mcp__") ? humanize(tool) : nil
        }
    }

    /// "mcp__semester__whats_due" → "Checking what's due"; "mcp__claude_ai_Google_Calendar__list_events" → "Checking events".
    static func humanize(_ tool: String) -> String {
        let parts = tool.components(separatedBy: "__")
        var words = (parts.last ?? tool).split(separator: "_").map { $0.lowercased() }
        let server = parts.count > 2 ? parts[1].replacingOccurrences(of: "claude_ai_", with: "").replacingOccurrences(of: "_", with: " ") : ""
        if words.first == "whats" { words[0] = "what's" }
        guard let verb = words.first else { return "Using \(server)" }
        let rest = words.dropFirst().joined(separator: " ")
        switch verb {
        case "get", "list", "search", "read", "query", "find", "fetch", "view", "what's":
            return "Checking " + (verb == "what's" ? "what's " : "") + (rest.isEmpty ? server : rest)
        case "refresh", "sync": return "Refreshing " + (rest.isEmpty ? server : rest)
        case "create", "add", "new": return "Creating " + rest
        case "update", "edit", "set", "mark", "respond": return "Updating " + (rest.isEmpty ? server : rest)
        case "delete", "remove": return "Removing " + rest
        default: return (verb.prefix(1).uppercased() + verb.dropFirst()) + (rest.isEmpty ? "" : " " + rest)
        }
    }

    /// Splits the skill's final reply into the gist and the saved file path.
    static func splitReply(_ text: String) -> (gist: String, path: String?) {
        var gist: [String] = []
        var path: String?
        for line in text.components(separatedBy: "\n") {
            // Code blocks and tables stay: the card renders them (they were once dropped, which flattened code
            // into unindented prose and cut answers off at their first table).
            let t = line.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Saved:") {
                let p = t.dropFirst("Saved:".count).trimmingCharacters(in: .whitespaces)
                path = (p as NSString).expandingTildeInPath
                break
            }
            gist.append(line)
        }
        return (gist.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), path)
    }

    // MARK: - Setup: installed and signed in?

    enum Readiness { case missing, signedOut, ready }

    /// Pix runs on Claude Code; a new Mac may not have it yet, or not be signed in.
    static func readiness() async -> Readiness {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                guard let claude = claudeURL() else { cont.resume(returning: .missing); return }
                let p = Process(), out = Pipe()
                p.executableURL = claude
                p.arguments = ["auth", "status"]
                p.environment = environment()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice  // never the terminal's input (it gets frozen there)
                guard (try? p.run()) != nil else { cont.resume(returning: .missing); return }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                cont.resume(returning: (d?["loggedIn"] as? Bool ?? (p.terminationStatus == 0)) ? .ready : .signedOut)
            }
        }
    }

    /// Installs Claude Code with its official installer (no admin password; it goes in ~/.local/bin).
    /// `done` runs on the main thread with whether it worked.
    static func install(done: @escaping (Bool) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "curl -fsSL https://claude.ai/install.sh | bash"]
        p.environment = environment()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let ok = proc.terminationStatus == 0
            Log.runner.notice("installer finished: \(ok ? "ok" : "failed", privacy: .public)")
            DispatchQueue.main.async { done(ok) }
        }
        do { try p.run() } catch { DispatchQueue.main.async { done(false) } }
    }

    /// Opens Claude's sign-in page in the browser. Falls back to a Terminal window if the
    /// sign-in needs one (it can ask to paste a code).
    /// Straight to the Claude plan sign-in in the browser: without --claudeai, Claude Code first asks
    /// in a Terminal menu whether it's a Claude plan or API billing, which a new user can't make sense of.
    static let signInArguments = ["auth", "login", "--claudeai"]

    static func signIn() {
        guard let claude = claudeURL() else { return }
        let p = Process()
        p.executableURL = claude
        p.arguments = signInArguments
        p.environment = environment()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            guard proc.terminationStatus != 0 else { return }
            let script = PixPaths.home.appendingPathComponent(".sign-in.command")
            try? "#!/bin/zsh\n'\(claude.path)' \(signInArguments.joined(separator: " "))\n".write(to: script, atomically: true, encoding: .utf8)
            chmod(script.path, 0o755)
            DispatchQueue.main.async { NSWorkspace.shared.open(script) }
        }
        try? p.run()
    }

    // MARK: - Finding Claude Code

    /// The environment your Terminal gets (login + interactive shell), read once. Apps opened from
    /// the Dock get a bare one, so tools like Python MCP servers wouldn't start without this.
    static let shellEnvironment: [String: String] = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // An interactive shell grabs the terminal when there is one (Pix run from Terminal) and gets
        // frozen, so it runs in its own session with no terminal, and is given up on after 5 s.
        // It starts from a clean slate, as when Pix opens from the Dock: inheriting a terminal's
        // already-set-up shell (conda active, say) made its startup files skip their setup.
        let home = NSHomeDirectory(), me = NSUserName()
        let clean = ["HOME=\(home)", "USER=\(me)", "LOGNAME=\(me)", "SHELL=\(shell)", "TMPDIR=\(NSTemporaryDirectory())",
                     "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=\(ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8")"]
        let data = detachedOutput(shell, ["-lic", "env -0"], environment: clean, timeout: 5)
        var env: [String: String] = [:]
        for entry in data.split(separator: 0) {
            let s = String(decoding: entry, as: UTF8.self)
            if let eq = s.firstIndex(of: "=") { env[String(s[..<eq])] = String(s[s.index(after: eq)...]) }
        }
        return env
    }()

    /// Runs a command in a new session (no controlling terminal) and returns what it printed,
    /// killing it after `timeout` seconds. For shells that would otherwise fight the terminal.
    static func detachedOutput(_ path: String, _ args: [String], environment env: [String]? = nil, timeout: Double) -> Data {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return Data() }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?]? = env.map { $0.map { strdup($0) } + [nil] }
        defer {
            argv.forEach { free($0) }; envp?.forEach { free($0) }
            posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr)
        }
        let spawned = envp.map { posix_spawn(&pid, path, &actions, &attr, argv, $0) } ?? posix_spawn(&pid, path, &actions, &attr, argv, environ)
        close(fds[1])
        guard spawned == 0 else { close(fds[0]); return Data() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { kill(pid, SIGKILL) }
        let data = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true).readDataToEndOfFile()
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return data
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment.merging(shellEnvironment) { _, shell in shell }
        let home = NSHomeDirectory()
        let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = (path + extra.filter { !path.contains($0) }).joined(separator: ":")
        for k in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "SHLVL", "_", "PWD", "OLDPWD"] { env.removeValue(forKey: k) }
        return env
    }

    nonisolated(unsafe) private static var foundClaude: URL?

    /// Where Claude Code is installed. Remembered once found; looked up again until then (setup may install it).
    static func claudeURL() -> URL? {
        if let found = foundClaude, FileManager.default.isExecutableFile(atPath: found.path) { return found }
        let url = locateClaude()
        foundClaude = url
        return url
    }

    private static func locateClaude() -> URL? {
        let home = NSHomeDirectory()
        for p in ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                  "\(home)/.claude/local/claude"] where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        let shell = Process()
        let pipe = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        shell.standardOutput = pipe
        shell.standardInput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        try? shell.run()
        shell.waitUntilExit()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}

/// Records Claude Code's own billed totals in the ledger (~/Pix/runs/ledger.csv) and keeps
/// token counts out of the run file itself.
enum TokenReport {
    static func apply(file: String, ledger: String, mode: String, usage: [ClaudeRunner.Usage]) {
        if var text = try? String(contentsOfFile: file, encoding: .utf8), let r = text.range(of: "\n## Tokens") {
            text = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            try? text.write(toFile: file, atomically: true, encoding: .utf8)
        }
        let name = (file as NSString).lastPathComponent
        let fresh = usage.reduce(0) { $0 + $1.fresh }, cached = usage.reduce(0) { $0 + $1.cached }
        let out = usage.reduce(0) { $0 + $1.output }
        let row = [String(ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: .withFullDate)),
                   mode, name, "\(fresh + cached + out)", "\(fresh)", "\(cached)", "\(out)"].joined(separator: ",")
        var rows = ((try? String(contentsOfFile: ledger, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        if rows.isEmpty { rows = ["date,mode,run,total,new_input,cached_input,output"] }
        if let i = rows.firstIndex(where: { $0.split(separator: ",").dropFirst(2).first.map(String.init) == name }) {
            rows[i] = row
        } else {
            rows.append(row)
        }
        try? (rows.joined(separator: "\n") + "\n").write(toFile: ledger, atomically: true, encoding: .utf8)
    }
}
