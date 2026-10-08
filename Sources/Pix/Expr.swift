import Foundation

/// A small, safe math expression parser for graphs: numbers, x, + − * / ^, parentheses,
/// implicit multiplication (2x, 3(x+1)), π and e, and common functions.
/// Bad input becomes nil instead of crashing.
indirect enum Expr {
    case num(Double)
    case x
    case neg(Expr)
    case bin(Character, Expr, Expr)
    case fn(String, Expr)

    static let functions: [String: (Double) -> Double] = [
        "sin": sin, "cos": cos, "tan": tan, "asin": asin, "acos": acos, "atan": atan,
        "sqrt": { $0.squareRoot() }, "abs": { Swift.abs($0) }, "ln": log, "log": log10, "exp": exp,
    ]

    static let names = (Array(functions.keys) + ["pi", "x", "e"]).sorted { $0.count > $1.count }

    func eval(_ x: Double) -> Double {
        switch self {
        case .num(let v): return v
        case .x: return x
        case .neg(let e): return -e.eval(x)
        case .fn(let name, let e): return Expr.functions[name].map { $0(e.eval(x)) } ?? .nan
        case .bin(let op, let a, let b):
            let l = a.eval(x), r = b.eval(x)
            switch op {
            case "+": return l + r
            case "-": return l - r
            case "*": return l * r
            case "/": return r == 0 ? .nan : l / r
            case "^": return pow(l, r)
            default: return .nan
            }
        }
    }

    /// Parses "2x^2 - 8x + 6", "y = sin(x)/x", "3(x+1)²" and similar.
    static func parse(_ text: String) -> Expr? {
        var s = text.lowercased()
        if let eq = s.firstIndex(of: "=") { s = String(s[s.index(after: eq)...]) }  // drop "y =" / "f(x) ="
        let swaps = ["−": "-", "–": "-", "×": "*", "·": "*", "÷": "/", "²": "^2", "³": "^3", "π": "pi", "√": "sqrt"]
        for (a, b) in swaps { s = s.replacingOccurrences(of: a, with: b) }
        var p = Parser(chars: Array(s.filter { !$0.isWhitespace }))
        guard let e = p.sum(), p.i == p.chars.count else { return nil }
        return e
    }

    private struct Parser {
        let chars: [Character]
        var i = 0

        var peek: Character? { i < chars.count ? chars[i] : nil }

        mutating func sum() -> Expr? {
            guard var l = product() else { return nil }
            while let c = peek, c == "+" || c == "-" {
                i += 1
                guard let r = product() else { return nil }
                l = .bin(c, l, r)
            }
            return l
        }

        mutating func product() -> Expr? {
            guard var l = unary() else { return nil }
            while let c = peek {
                if c == "*" || c == "/" {
                    i += 1
                    guard let r = unary() else { return nil }
                    l = .bin(c, l, r)
                } else if c.isLetter || c == "(" || c.isNumber || c == "." {
                    guard let r = power() else { return nil }  // implicit: 2x, x(x+1), 2sin(x)
                    l = .bin("*", l, r)
                } else {
                    break
                }
            }
            return l
        }

        mutating func unary() -> Expr? {
            if peek == "-" { i += 1; return unary().map { .neg($0) } }
            if peek == "+" { i += 1; return unary() }
            return power()
        }

        mutating func power() -> Expr? {
            guard let base = atom() else { return nil }
            if peek == "^" {
                i += 1
                guard let exp = unary() else { return nil }  // right-associative, allows x^-1
                return .bin("^", base, exp)
            }
            return base
        }

        mutating func atom() -> Expr? {
            guard let c = peek else { return nil }
            if c == "(" {
                i += 1
                let e = sum()
                guard peek == ")" else { return nil }
                i += 1
                return e
            }
            if c.isNumber || c == "." {
                var t = ""
                while let d = peek, d.isNumber || d == "." { t.append(d); i += 1 }
                return Double(t).map { .num($0) }
            }
            if c.isLetter {
                // Split letter runs into known names, longest first: "pix" → pi·x, "sqrtx" → sqrt(x).
                let rest = String(chars[i...])
                guard let name = Expr.names.first(where: { rest.hasPrefix($0) }) else { return nil }
                i += name.count
                switch name {
                case "x": return .x
                case "pi": return .num(.pi)
                case "e": return .num(M_E)
                default:
                    guard let arg = peek == "(" ? atom() : power() else { return nil }  // sqrt(x) or sqrt x
                    return .fn(name, arg)
                }
            }
            return nil
        }
    }
}
