import Foundation

/// Tools Pix can pop up on its board. Parsed from the agent's JSON, never executed.
enum Visual: Identifiable {
    struct Point { var x: Double; var y: Double; var label: String }
    struct Shape {
        var type: String  // rect, circle, triangle, line, arrow, text
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0, x2 = 0.0, y2 = 0.0, x3 = 0.0, y3 = 0.0
        var label = ""
    }

    case graph(title: String, functions: [String], points: [Point], xmin: Double?, xmax: Double?)
    case diagram(title: String, shapes: [Shape])
    case table(title: String, columns: [String], rows: [[String]])
    case checklist(title: String, items: [String])
    case code(title: String, language: String, text: String)
    case notes(title: String, text: String)
    case canvas(title: String, html: String, plugins: [String])

    var id: String { title + kind }

    var title: String {
        switch self {
        case .graph(let t, _, _, _, _), .diagram(let t, _), .table(let t, _, _), .checklist(let t, _),
             .code(let t, _, _), .notes(let t, _), .canvas(let t, _, _): return t
        }
    }

    var kind: String {
        switch self {
        case .graph: return "graph"
        case .diagram: return "diagram"
        case .table: return "table"
        case .checklist: return "checklist"
        case .code: return "code"
        case .notes: return "notes"
        case .canvas: return "canvas"
        }
    }

    var symbol: String {
        switch self {
        case .graph: return "chart.xyaxis.line"
        case .diagram: return "square.on.circle"
        case .table: return "tablecells"
        case .checklist: return "checklist"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .notes: return "text.alignleft"
        case .canvas: return "sparkles.rectangle.stack"
        }
    }

    // MARK: - From the agent's JSON

    static func all(from output: [String: Any]) -> [Visual] {
        (output["visuals"] as? [[String: Any]] ?? []).compactMap(Visual.init)
    }

    init?(_ d: [String: Any]) {
        func n(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func str(_ k: String) -> String { d[k] as? String ?? "" }
        let title = str("title").isEmpty ? (d["kind"] as? String ?? "").capitalized : str("title")
        switch d["kind"] as? String {
        case "graph":
            let fns = (d["functions"] as? [String] ?? []).filter { Expr.parse($0) != nil }
            let pts = (d["points"] as? [[String: Any]] ?? []).compactMap { p -> Point? in
                guard let x = n(p["x"]), let y = n(p["y"]) else { return nil }
                return Point(x: x, y: y, label: p["label"] as? String ?? "")
            }
            guard !fns.isEmpty || !pts.isEmpty else { return nil }
            self = .graph(title: title, functions: fns, points: pts, xmin: n(d["xmin"]), xmax: n(d["xmax"]))
        case "diagram":
            let shapes = (d["shapes"] as? [[String: Any]] ?? []).compactMap { s -> Shape? in
                guard let type = s["type"] as? String else { return nil }
                return Shape(type: type, x: n(s["x"]) ?? 0, y: n(s["y"]) ?? 0, w: n(s["w"]) ?? 0, h: n(s["h"]) ?? 0,
                             x2: n(s["x2"]) ?? 0, y2: n(s["y2"]) ?? 0, x3: n(s["x3"]) ?? 0, y3: n(s["y3"]) ?? 0,
                             label: s["label"] as? String ?? "")
            }
            guard !shapes.isEmpty else { return nil }
            self = .diagram(title: title, shapes: shapes)
        case "table":
            let cols = d["columns"] as? [String] ?? []
            let rows = (d["rows"] as? [[Any]] ?? []).map { $0.map { "\($0)" } }
            guard !cols.isEmpty || !rows.isEmpty else { return nil }
            self = .table(title: title, columns: cols, rows: rows)
        case "checklist":
            let items = d["items"] as? [String] ?? []
            guard !items.isEmpty else { return nil }
            self = .checklist(title: title, items: items)
        case "code":
            guard !str("text").isEmpty else { return nil }
            self = .code(title: title, language: str("language"), text: str("text"))
        case "notes":
            guard !str("text").isEmpty else { return nil }
            self = .notes(title: title, text: str("text"))
        case "canvas":
            guard !str("html").isEmpty else { return nil }
            self = .canvas(title: title, html: str("html"), plugins: d["plugins"] as? [String] ?? [])
        default:
            return nil
        }
    }

    // MARK: - For the run file

    var markdown: String {
        switch self {
        case .graph(let t, let fns, let pts, _, _):
            var s = "### \(t)\n"
            for f in fns { s += "- y = \(f)\n" }
            for p in pts { s += "- point (\(Self.num(p.x)), \(Self.num(p.y)))\(p.label.isEmpty ? "" : " — \(p.label)")\n" }
            return s
        case .diagram(let t, let shapes):
            let labels = shapes.map(\.label).filter { !$0.isEmpty }
            return "### \(t)\n" + (labels.isEmpty ? "" : "Labels: " + labels.joined(separator: ", ") + "\n")
        case .table(let t, let cols, let rows):
            let width = max(cols.count, rows.map(\.count).max() ?? 0)
            func row(_ r: [String]) -> String {
                "| " + (r + Array(repeating: "", count: max(0, width - r.count))).joined(separator: " | ") + " |"
            }
            return "### \(t)\n" + row(cols) + "\n|" + String(repeating: "---|", count: width) + "\n"
                + rows.map(row).joined(separator: "\n") + "\n"
        case .checklist(let t, let items):
            return "### \(t)\n" + items.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n"
        case .code(let t, let lang, let text):
            return "### \(t)\n```\(lang)\n\(text)\n```\n"
        case .notes(let t, let text):
            return "### \(t)\n\(text)\n"
        case .canvas(let t, _, _):
            return "### \(t)\nAn interactive canvas, shown in Pix's board.\n"
        }
    }

    static func num(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(format: "%.3g", v)
    }
}
