import Foundation

/// What went wrong with a run, as a type rather than a guess from wording. Decides what Pix does
/// next: hiccups get one quiet retry before you see anything ("recovery before escalation").
enum Trouble: String {
    case usageLimit, rateLimit, overloaded, offline, timeout, tooManySteps, signedOut, unknown

    /// Passing problems that usually clear on their own within seconds.
    var transient: Bool { [.rateLimit, .overloaded, .offline].contains(self) }

    static func classify(_ raw: String, subtype: String = "") -> Trouble {
        let t = raw.lowercased()
        if subtype == "error_max_turns" || t.contains("max turns") || t.contains("maximum number of turns") { return .tooManySteps }
        if t.contains("not logged in") || t.contains("/login") || t.contains("invalid api key") || t.contains("authentication") { return .signedOut }
        if t.contains("usage limit") || t.contains("limit reached") || t.contains("quota") || t.contains("session limit") || t.contains("weekly limit") { return .usageLimit }
        if t.contains("rate limit") || t.contains("429") { return .rateLimit }
        if t.contains("overloaded") || t.contains("529") || t.contains("503") || t.contains("502") { return .overloaded }
        if t.contains("timed out") || t.contains("timeout") { return .timeout }
        if t.contains("network") || t.contains("offline") || t.contains("connection") || t.contains("enotfound") || t.contains("econnrefused") { return .offline }
        return .unknown
    }
}

/// Every run's life as typed events in ~/Pix/runs/events.jsonl (started → ready → finished, or
/// failed / recovered / handed off), so what happened is never something to dig out of text.
/// `Pix --doctor` reads it.
enum RunLog {
    static let file = PixPaths.runs.appendingPathComponent("events.jsonl")
    static let version = 1

    static func record(_ type: String, run: String, _ detail: [String: Any] = [:], in file: URL = file) {
        var row: [String: Any] = ["v": version, "at": Schedules.iso.string(from: Date()), "run": run, "type": type]
        for (k, v) in detail { row[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(data + Data("\n".utf8)); try? h.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: file)
        }
        trim(file)
    }

    static func recent(_ n: Int = 200, in file: URL = file) -> [[String: Any]] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(n).compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    /// Keeps the log small: past 1 MB, the older half goes.
    private static func trim(_ file: URL) {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 1_000_000,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n")
        try? (lines.suffix(lines.count / 2).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}

/// `Pix --doctor`: is everything Pix depends on working, and what's gone wrong lately?
enum Doctor {
    static func report() async -> String {
        var lines: [String] = []
        func row(_ ok: Bool?, _ what: String, _ detail: String) {
            lines.append("\(ok == nil ? "  -  " : ok! ? "  ok " : "  !! ") \(what): \(detail)")
        }
        let claude = ClaudeRunner.claudeURL()
        let version = claude.flatMap { BuiltIn.run($0.path, ["--version"], timeout: 10) } ?? ""
        row(claude != nil, "Claude Code", claude.map { "\($0.path) \(version)" } ?? "not installed")
        let shellVars = ClaudeRunner.shellEnvironment.count
        let path = ClaudeRunner.environment()["PATH"] ?? ""
        let python = path.split(separator: ":").map { "\($0)/python3" }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "none"
        row(shellVars > 0, "Shell settings", shellVars > 0 ? "\(shellVars) read · python3 → \(python)" : "couldn't read your shell's settings, so apps that need them may not start")
        let ready = await ClaudeRunner.readiness()
        row(ready == .ready, "Claude account", ready == .ready ? "signed in" : ready == .signedOut ? "not signed in" : "Claude Code missing")
        let p = Provider.current
        var providerOK = true
        if case .service(let id, _) = p { providerOK = Services.key(id) != nil }
        row(providerOK, "Lite runs on", p.label + (providerOK ? "" : " (no key saved)"))
        let models = Ollama.installed()
        row(nil, "Ollama", Ollama.isInstalled ? (await Ollama.running() ? "running" : "installed, not running") + (models.isEmpty ? "" : " · " + models.joined(separator: ", ")) : "not installed")
        let services = Services.ready.map(\.name)
        row(nil, "Other AIs", services.isEmpty ? "none added" : services.joined(separator: ", "))
        let apps = await Toolbox.discover()
        row(nil, "Connected apps", apps.isEmpty ? "none" : apps.map(Toolbox.label).joined(separator: ", "))
        row(nil, "Scheduled", "\(Schedules.all().count) timers and schedules")

        let events = RunLog.recent()
        let runs = Set(events.compactMap { $0["run"] as? String }).count
        let failed = events.filter { $0["type"] as? String == "failed" }
        let recovered = events.filter { $0["type"] as? String == "recovered" }.count
        let partial = events.filter { $0["type"] as? String == "degraded" }.count
        var kinds: [String: Int] = [:]
        for f in failed { kinds[f["trouble"] as? String ?? "unknown", default: 0] += 1 }
        row(failed.isEmpty, "Recent runs", "\(runs) runs · \(failed.count) failed" + (kinds.isEmpty ? "" : " (" + kinds.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")")
            + " · \(recovered) recovered on their own · \(partial) ran without an app")
        return "Pix health\n" + lines.joined(separator: "\n")
    }
}
