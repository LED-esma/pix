import CryptoKit
import Foundation

/// Tools Pix makes (called routines in code): named recipes you run in one tap or by typing the name
/// ("Morning Brief": the weather, what's due, today's calendar), and that any model can call by name
/// in the middle of another question (BuiltIn.saved). Steps use Pix's tools, AppleScript or shell
/// commands (those ask you the first time). Kept in ~/Pix/routines.json. Saved by asking ("make a tool
/// that…"), or from the answer card after a repeat or a script that worked.
enum Routines {
    static let file = PixPaths.home.appendingPathComponent("routines.json")

    struct Routine: Equatable {
        var name: String
        var steps: String   // what Pix is asked when it runs
        var about = ""      // one line: what it does
        var json: [String: Any] { ["name": name, "steps": steps, "about": about] }
    }

    /// "Morning Brief" → "morning_brief", the name a model calls it by.
    static func slug(_ name: String) -> String {
        String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }).split(separator: "_").joined(separator: "_")
    }

    static func all(in file: URL = file) -> [Routine] {
        ((try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [[String: Any]] ?? []).compactMap { d in
            guard let n = d["name"] as? String, let s = d["steps"] as? String, !n.isEmpty, !s.isEmpty else { return nil }
            return Routine(name: n, steps: s, about: d["about"] as? String ?? "")
        }
    }

    /// Saves (or replaces one with the same name). Returns the cleaned-up name.
    @discardableResult
    static func save(name: String, steps: String, about: String = "", in file: URL = file) -> String {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)).capitalized
        let list = all(in: file).filter { $0.name.lowercased() != n.lowercased() }
            + [Routine(name: n, steps: steps.trimmingCharacters(in: .whitespacesAndNewlines), about: about.trimmingCharacters(in: .whitespacesAndNewlines))]
        write(list, to: file)
        return n
    }

    @discardableResult
    static func remove(_ name: String, in file: URL = file) -> Routine? {
        let list = all(in: file)
        guard let gone = list.first(where: { $0.name.lowercased() == name.lowercased() }) else { return nil }
        write(list.filter { $0 != gone }, to: file)
        return gone
    }

    /// The routine a request names: "morning brief", "run my morning brief", "do the morning brief".
    static func match(_ goal: String, in file: URL = file) -> Routine? {
        var g = goal.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for p in ["please ", "run my ", "run the ", "run ", "do my ", "do the ", "start my ", "my "] where g.hasPrefix(p) { g = String(g.dropFirst(p.count)) }
        for s in [" routine", " please"] where g.hasSuffix(s) { g = String(g.dropLast(s.count)) }
        return all(in: file).first { $0.name.lowercased() == g }
    }

    private static func write(_ list: [Routine], to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: list.map(\.json), options: [.prettyPrinted]) { try? data.write(to: file) }
    }
}

/// AppleScript and shell commands you've said yes to. The exact same script runs again without
/// asking (a saved tool doing its job); anything different asks again.
enum Scripts {
    static let key = "approvedScripts"

    static func fingerprint(tool: String, input: [String: Any]) -> String? {
        let name = tool.replacingOccurrences(of: BuiltIn.prefix, with: "")
        guard name == "applescript_run" || name == "shell_run",
              let text = (input["script"] ?? input["command"]) as? String else { return nil }
        let digest = SHA256.hash(data: Data((name + "\n" + text.trimmingCharacters(in: .whitespacesAndNewlines)).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func approved(tool: String, input: [String: Any], in d: UserDefaults = .standard) -> Bool {
        fingerprint(tool: tool, input: input).map { (d.stringArray(forKey: key) ?? []).contains($0) } ?? false
    }

    static func approve(tool: String, input: [String: Any], in d: UserDefaults = .standard) {
        guard let f = fingerprint(tool: tool, input: input) else { return }
        let list = (d.stringArray(forKey: key) ?? []).filter { $0 != f } + [f]
        d.set(Array(list.suffix(500)), forKey: key)
    }
}
