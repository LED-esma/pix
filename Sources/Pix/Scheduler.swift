import Foundation

/// Timers and scheduled Pix runs, kept in ~/Pix/schedules.json. Pix's built-in tools add them
/// (from inside a run, as a separate process), and the app fires them: a timer taps you, a
/// scheduled run asks Pix the saved question and shows the answer.
enum Schedules {
    static let file = PixPaths.home.appendingPathComponent("schedules.json")

    enum Repeat: String, CaseIterable { case none, daily, weekdays, weekly }

    struct Entry: Equatable {
        var id: String
        var kind: String          // "timer" or "run"
        var text: String          // a timer's label, or the question a run asks
        var at: Date
        var repeats: Repeat = .none
        var start = Date()        // when it was set: a timer's ring shows how much is left

        var json: [String: Any] {
            ["id": id, "kind": kind, "text": text, "at": iso.string(from: at), "repeat": repeats.rawValue, "start": iso.string(from: start)]
        }
        init(id: String = String(UUID().uuidString.prefix(8)).lowercased(), kind: String, text: String, at: Date, repeats: Repeat = .none) {
            self.id = id; self.kind = kind; self.text = text; self.at = at; self.repeats = repeats
        }
        init?(_ d: [String: Any]) {
            guard let id = d["id"] as? String, let kind = d["kind"] as? String,
                  let at = (d["at"] as? String).flatMap(iso.date(from:)) else { return nil }
            self.init(id: id, kind: kind, text: d["text"] as? String ?? "", at: at,
                      repeats: Repeat(rawValue: d["repeat"] as? String ?? "") ?? .none)
            start = (d["start"] as? String).flatMap(iso.date(from:)) ?? at
        }

        /// How much of a timer is left, 1 → 0.
        func left(at now: Date = Date()) -> Double {
            let total = at.timeIntervalSince(start)
            return total > 0 ? min(1, max(0, at.timeIntervalSince(now) / total)) : 0
        }

        /// "Pizza · 4:30 PM", "every weekday at 8:00 AM: what's due today?"
        var summary: String {
            let time = at.formatted(date: Calendar.current.isDateInToday(at) ? .omitted : .abbreviated, time: .shortened)
            if kind == "timer" { return (text.isEmpty ? "Timer" : text) + " · " + time }
            let when: String
            switch repeats {
            case .none: when = time
            case .daily: when = "every day at " + at.formatted(date: .omitted, time: .shortened)
            case .weekdays: when = "every weekday at " + at.formatted(date: .omitted, time: .shortened)
            case .weekly: when = "every " + at.formatted(.dateTime.weekday(.wide)) + " at " + at.formatted(date: .omitted, time: .shortened)
            }
            return "\(when): \(text)"
        }
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func all(in file: URL = file) -> [Entry] {
        let raw = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [[String: Any]] ?? []
        return raw.compactMap(Entry.init).sorted { $0.at < $1.at }
    }

    static func save(_ entries: [Entry], to file: URL = file) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: entries.map(\.json), options: [.prettyPrinted]) {
            try? data.write(to: file, options: .atomic)
        }
    }

    static func add(_ e: Entry, in file: URL = file) { save(all(in: file).filter { $0.id != e.id } + [e], to: file) }

    @discardableResult
    static func remove(_ id: String, in file: URL = file) -> Entry? {
        let entries = all(in: file)
        guard let gone = entries.first(where: { $0.id == id }) else { return nil }
        save(entries.filter { $0.id != id }, to: file)
        return gone
    }

    /// When a repeating entry fires next, after `date`. Nil for one-offs.
    static func next(after date: Date, from e: Entry, calendar: Calendar = .current) -> Date? {
        var at = e.at
        func step(_ d: Date) -> Date {
            switch e.repeats {
            case .none: return d
            case .daily: return calendar.date(byAdding: .day, value: 1, to: d)!
            case .weekly: return calendar.date(byAdding: .day, value: 7, to: d)!
            case .weekdays:
                var n = calendar.date(byAdding: .day, value: 1, to: d)!
                while calendar.isDateInWeekend(n) { n = calendar.date(byAdding: .day, value: 1, to: n)! }
                return n
            }
        }
        guard e.repeats != .none else { return nil }
        while at <= date { at = step(at) }
        return at
    }

    // MARK: - Dates the model writes

    /// "2026-10-04T17:00", "2026-10-04 17:00:30", "2026-10-04T17:00:00-07:00", "…Z", or a bare
    /// "2026-10-04" (all-day). No time zone means this Mac's.
    static func parse(_ s: String) -> (date: Date, hasTime: Bool)? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "T")
        if let d = iso.date(from: t) { return (d, true) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for (format, timed) in [("yyyy-MM-dd'T'HH:mm:ss", true), ("yyyy-MM-dd'T'HH:mm", true), ("yyyy-MM-dd", false)] {
            f.dateFormat = format
            if let d = f.date(from: t) { return (d, timed) }
        }
        return nil
    }
}
