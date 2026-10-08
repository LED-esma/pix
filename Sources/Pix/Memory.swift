import Foundation

/// What Pix remembers about you across chats: short facts it picked up (your classes, projects,
/// gear, how you like answers), kept in ~/Pix/memory.json. They ride along with every question,
/// the card says when a new one is learned, and right-click → Memory shows or forgets them.
enum Memory {
    static let file = PixPaths.home.appendingPathComponent("memory.json")
    static let limit = 60

    static func all(in file: URL = file) -> [String] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String] ?? []
    }

    /// Adds new facts, skipping repeats and anything that looks secret. Returns what was actually added.
    @discardableResult
    static func add(_ raw: Any?, in file: URL = file) -> [String] {
        let facts = (raw as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var kept = all(in: file)
        var added: [String] = []
        for f in facts where (4...160).contains(f.count) && !looksSecret(f) {
            let key = f.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            guard !kept.contains(where: { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) == key }) else { continue }
            kept.append(f)
            added.append(f)
        }
        guard !added.isEmpty else { return [] }
        save(Array(kept.suffix(limit)), to: file)  // oldest go first
        return added
    }

    static func forget(_ fact: String, in file: URL = file) {
        save(all(in: file).filter { $0 != fact }, to: file)
        UserDefaults.standard.set([fact], forKey: "memory.forgotten")
    }

    static func forgetAll(in file: URL = file) {
        UserDefaults.standard.set(all(in: file), forKey: "memory.forgotten")
        save([], to: file)
    }

    /// Whatever was last forgotten, so a slip is one click to undo.
    static var forgotten: [String] { UserDefaults.standard.stringArray(forKey: "memory.forgotten") ?? [] }

    static func undoForget(in file: URL = file) {
        save(Array((all(in: file) + forgotten).suffix(limit)), to: file)
        UserDefaults.standard.removeObject(forKey: "memory.forgotten")
    }

    /// The lines that go in front of a question. Empty when Pix knows nothing yet.
    static func prompt(_ facts: [String] = all()) -> String {
        facts.isEmpty ? "" : "What you know about the user from earlier chats:\n" + facts.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Facts you state about yourself ("I'm taking Calc 3 at City College"), turned into notes about you
    /// ("They're taking Calc 3 at City College"). For models that don't save memories themselves.
    static func selfFacts(from text: String) -> [String] {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).map { $0.trimmingCharacters(in: .whitespaces) }
        let starts = #"^(i'm|i am|i have|i've got|i own|i drive|i work|i study|i take|i play|i build|i run|i live|my )"#
        return sentences.compactMap { s -> String? in
            let l = s.lowercased()
            guard (8...160).contains(s.count), l.range(of: starts, options: .regularExpression) != nil, !looksSecret(s),
                  !l.contains("want"), !l.contains("need"), !l.contains("trying to") else { return nil }  // wishes and requests aren't facts
            var f = " " + s + " "
            for (a, b) in [(" I'm ", " They're "), (" I am ", " They are "), (" I've ", " They've "), (" I ", " They "), (" my ", " their "), (" My ", " Their "), (" me ", " them ")] {
                f = f.replacingOccurrences(of: a, with: b)
            }
            return f.trimmingCharacters(in: .whitespaces)
        }.prefix(2).map { $0 }
    }

    static func looksSecret(_ s: String) -> Bool {
        let t = s.lowercased()
        if ["password", "passcode", "api key", "token", "ssn", "social security", "credit card", "card number", "bank account", "pin "]
            .contains(where: t.contains) { return true }
        return t.range(of: #"\d{6,}"#, options: .regularExpression) != nil  // long numbers: accounts, cards, phones
    }

    private static func save(_ facts: [String], to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted]) { try? data.write(to: file) }
    }
}
