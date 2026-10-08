import Foundation

/// Every answer is also kept as data (~/Pix/runs/.data/<run>.json) so it can be reopened
/// with its board and walkthrough, not just read as Markdown.
enum History {
    struct Saved { var goal: String; var mode: String; var date: Date; var title: String; var output: [String: Any]; var runPath: String? }

    static func dataDir(_ runs: URL = PixPaths.runs) -> URL { runs.appendingPathComponent(".data") }

    static func record(_ out: [String: Any], goal: String, mode: String, runPath: String) {
        let runURL = URL(fileURLWithPath: runPath)
        let dir = dataDir(runURL.deletingLastPathComponent())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var output = out
        output.removeValue(forKey: "plugin")  // tools are installed, not replayed
        let record: [String: Any] = ["goal": goal, "mode": mode, "date": Date().timeIntervalSince1970,
                                     "title": out["title"] as? String ?? "Pix", "output": output, "run": runPath]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        try? data.write(to: dir.appendingPathComponent(runURL.deletingPathExtension().lastPathComponent + ".json"))
    }

    static func load(_ path: String) -> Saved? {
        guard let d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any],
              let output = d["output"] as? [String: Any] else { return nil }
        let run = d["run"] as? String
        return Saved(goal: d["goal"] as? String ?? "", mode: d["mode"] as? String ?? "lite",
                     date: Date(timeIntervalSince1970: (d["date"] as? NSNumber)?.doubleValue ?? 0),
                     title: d["title"] as? String ?? "Pix", output: output,
                     runPath: run.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil })
    }

    /// Newest first.
    static func recent(_ limit: Int = 10, in runs: URL = PixPaths.runs) -> [(title: String, date: Date, path: String)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dataDir(runs), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in load(url.path).map { (title: $0.title, date: $0.date, path: url.path) } }
            .sorted { $0.date > $1.date }
            .prefix(limit).map { $0 }
    }
}

/// Keeps ~/Pix from growing forever. Your saved answers (runs) are never touched.
enum Housekeeping {
    static let workDays = 14.0, backupDays = 60.0

    /// Deletes scratch notes older than two weeks, tool backups older than two months (always
    /// keeping each tool's newest backup), and leftovers from tool tests.
    @discardableResult
    static func sweep(home: URL = PixPaths.home, now: Date = Date()) -> Int {
        let fm = FileManager.default
        var removed = 0
        func age(_ url: URL) -> Double {
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            return now.timeIntervalSince(d) / 86_400
        }
        func children(_ url: URL) -> [URL] { (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }

        for w in children(home.appendingPathComponent("work")) where age(w) > workDays {
            if (try? fm.removeItem(at: w)) != nil { removed += 1 }
        }
        for tool in children(home.appendingPathComponent("plugins/.backups")) {
            let versions = children(tool).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for v in versions.dropLast() where age(v) > backupDays {
                if (try? fm.removeItem(at: v)) != nil { removed += 1 }
            }
        }
        for s in children(home.appendingPathComponent("plugins/.staging")) {
            if (try? fm.removeItem(at: s)) != nil { removed += 1 }
        }
        if removed > 0 { Log.app.info("housekeeping removed \(removed) old items") }
        return removed
    }
}
