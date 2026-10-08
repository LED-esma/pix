import Foundation

/// Your MCP tools, loaded only when a request needs them. Loading every server costs
/// ~69k tokens per call, so each request gets just the ones it matches, or the ones
/// you add from the toolbox menu. Benchmarked 2026-10-02 (bench/BENCHMARK.md).
enum Toolbox {
    /// What each known server is called on the card, and the words that call it in.
    /// Unknown servers never auto-load; add them from the menu.
    static let known: [(match: String, label: String, words: Set<String>)] = [
        ("semester", "Semester", ["homework", "assignment", "assignments", "due", "grade", "grades", "class", "classes",
                                  "canvas", "course", "courses", "discussion", "discussions", "announcement",
                                  "announcements", "quiz", "exam", "semester", "syllabus"]),
        ("calendar", "Calendar", ["calendar", "meeting", "meetings", "schedule", "event", "events", "busy",
                                  "appointment", "reschedule"]),
        ("docs", "Docs", ["doc", "docs", "document"]),
        ("roblox", "Roblox", ["roblox", "luau"]),
    ]

    static func label(_ server: String) -> String {
        let s = server.lowercased()
        if let k = known.first(where: { s.contains($0.match) }) { return k.label }
        return server.replacingOccurrences(of: "claude.ai ", with: "").split(separator: ":").last.map(String.init) ?? server
    }

    static func matches(_ goal: String, _ server: String) -> Bool {
        let s = server.lowercased()
        guard let k = known.first(where: { s.contains($0.match) }) else { return false }
        let words = Set(goal.lowercased().split { !$0.isLetter }.map(String.init))
        return !words.isDisjoint(with: k.words)
    }

    /// The name Claude Code uses in tool names: "claude.ai Google Calendar" → mcp__claude_ai_Google_Calendar
    static func prefix(_ server: String) -> String {
        "mcp__" + String(server.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
    }

    /// Changes a lean command line so only `use` servers load. Nothing to use: stays strict (no MCP at all).
    static func apply(_ args: [String], use: [String], all: [String]) -> [String] {
        guard !use.isEmpty else { return args }
        var a = args.filter { $0 != "--strict-mcp-config" }
        let off = all.filter { !use.contains($0) }.map(prefix)
        if !off.isEmpty {
            let at = a.firstIndex(of: "--allowedTools") ?? a.endIndex  // keep variadic --allowedTools last
            a.insert(contentsOf: ["--disallowedTools"] + off, at: at)
        }
        return a
    }

    /// Words that mean a tool changes something, anywhere in its name ("get_and_delete" still asks).
    static let changeWords = ["delete", "remove", "create", "send", "mark", "update", "set", "write", "post", "add",
                              "edit", "move", "cancel", "respond", "submit", "upload", "rename", "archive", "trash", "pay"]

    /// Reading is fine without asking; anything that changes something asks first.
    /// Claude Code doesn't pass MCP read-only hints along (checked 2026-10-02), so this reads the
    /// tool's name, plus tools you chose "Always Allow" for.
    static func isReadOnly(_ tool: String) -> Bool {
        if alwaysAllowed.contains(tool) { return true }
        guard tool.hasPrefix("mcp__"), let name = tool.components(separatedBy: "__").last?.lowercased() else { return false }
        let words = name.split(separator: "_").map(String.init)
        guard !words.contains(where: { changeWords.contains($0) }) else { return false }
        return ["get", "list", "search", "read", "query", "find", "whats", "what", "data_age", "suggest", "fetch", "view", "refresh"]
            .contains { name.hasPrefix($0) }
    }

    static var alwaysAllowed: Set<String> { Set(UserDefaults.standard.stringArray(forKey: "toolbox.alwaysAllow") ?? []) }

    static func alwaysAllow(_ tool: String) {
        UserDefaults.standard.set(Array(alwaysAllowed.union([tool])).sorted(), forKey: "toolbox.alwaysAllow")
    }

    /// Your connected servers, read from Claude Code's startup message. Blocks every MCP tool
    /// and stops before the model answers, so it costs next to nothing. ~1–2 s.
    static func discover() async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                guard let claude = ClaudeRunner.claudeURL() else { cont.resume(returning: []); return }
                let p = Process(), inPipe = Pipe(), outPipe = Pipe()
                p.executableURL = claude
                p.arguments = ["-p", "--model", "haiku", "--tools", "", "--disallowedTools", "mcp__*",
                               "--no-session-persistence", "--output-format", "stream-json", "--verbose",
                               "--input-format", "stream-json"]
                p.currentDirectoryURL = PixPaths.home
                p.environment = ClaudeRunner.environment()
                p.standardInput = inPipe
                p.standardOutput = outPipe
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { cont.resume(returning: []); return }
                let hello = #"{"type":"user","message":{"role":"user","content":"OK"}}"# + "\n"
                try? inPipe.fileHandleForWriting.write(contentsOf: Data(hello.utf8))
                var names: [String] = []
                var buffer = Data()
                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline {
                    let d = outPipe.fileHandleForReading.availableData
                    if ProcessInfo.processInfo.environment["PIX_DEBUG"] != nil {
                        FileHandle.standardError.write("read \(d.count) bytes: \(String(decoding: d.prefix(160), as: UTF8.self))\n".data(using: .utf8)!)
                    }
                    if d.isEmpty { break }
                    buffer.append(d)
                    if let line = String(decoding: buffer, as: UTF8.self).split(separator: "\n")
                        .first(where: { $0.contains(#""subtype":"init""#) }),
                       let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                        // At startup most servers are still "pending"; only failed or signed-out ones are unusable.
                        names = (obj["mcp_servers"] as? [[String: Any]] ?? [])
                            .filter { !["failed", "disabled", "needs-auth"].contains($0["status"] as? String ?? "") }
                            .compactMap { $0["name"] as? String }
                        break
                    }
                }
                p.terminate()
                cont.resume(returning: names)
            }
        }
    }
}
