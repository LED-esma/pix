import Foundation

/// JSON schemas for Pix's structured answers, built as checked Swift values instead of
/// hand-written JSON (a typo there silently broke every answer).
enum Schema {
    typealias Node = [String: Any]

    static let string: Node = ["type": "string"]
    static let integer: Node = ["type": "integer"]
    static let number: Node = ["type": "number"]
    static func array(_ items: Node, max: Int? = nil) -> Node {
        var n: Node = ["type": "array", "items": items]
        if let max { n["maxItems"] = max }
        return n
    }
    static func oneOf(_ values: [String]) -> Node { ["enum": values] }
    static func object(_ properties: [String: Node], required: [String] = []) -> Node {
        var n: Node = ["type": "object", "properties": properties]
        if !required.isEmpty { n["required"] = required }
        return n
    }

    static func json(_ node: Node) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: node, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Pix's answer (Lite, and the team's final answer)

    static let step = object([
        "say": string, "work": string, "why": string, "source": string,
        "visual": integer, "focus": string,                              // point at something on the board
        "x": integer, "y": integer, "w": integer, "h": integer,          // or at a box on the screenshot
    ], required: ["say"])

    static let visual = object([
        "kind": oneOf(["graph", "diagram", "table", "checklist", "code", "notes", "canvas"]),
        "title": string,
        "html": string, "plugins": array(string),                                         // canvas
        "functions": array(string), "xmin": number, "xmax": number,                       // graph
        "points": array(object(["x": number, "y": number, "label": string], required: ["x", "y"])),
        "shapes": array(object([                                                          // diagram
            "type": oneOf(["rect", "circle", "triangle", "line", "arrow", "text"]),
            "x": number, "y": number, "w": number, "h": number,
            "x2": number, "y2": number, "x3": number, "y3": number, "label": string,
        ], required: ["type"])),
        "columns": array(string), "rows": array(array(string)),                           // table
        "items": array(string),                                                           // checklist
        "language": string, "text": string,                                               // code, notes
    ], required: ["kind", "title"])

    static let tool = object([                                                            // a tool Pix builds itself
        "name": string, "about": string, "api": array(string), "js": string, "css": string,
        "uses": array(string), "test": string,
    ], required: ["name", "about", "api", "js", "test"])

    static let answerProperties: [String: Node] = [
        "title": string, "answer": string,
        "steps": array(step, max: 10),
        "visuals": array(visual, max: 3),
        "sources": array(object(["title": string, "url": string], required: ["title", "url"])),
        "plugin": tool,
        "next": string,
        "remember": array(string, max: 3),  // new facts about the user for next time  // a better way to ask: "standard", "deep", "screen", or "use:<app>"
    ]
    static let answerRequired = ["title", "answer", "steps", "sources"]

    static let answer = json(object(answerProperties, required: answerRequired))

    /// The team's final answer: Lite's shape plus how disagreements were settled.
    static let teamAnswer: String = {
        var props = answerProperties
        props["disagreements"] = array(object(["point": string, "resolution": string], required: ["point", "resolution"]))
        props["uncertain"] = array(string)  // (remember and next ride along from answerProperties)
        return json(object(props, required: answerRequired))
    }()

    // MARK: - Team members

    static let brief = json(object(["brief": string], required: ["brief"]))
    static let critique = json(object(["critique": string], required: ["critique"]))
    static func member(body: String) -> String { json(object(["summary": string, body: string], required: ["summary", body])) }
}
