import Foundation
import Network

/// How Pix's tools (a separate process Claude Code starts) reach things that live in the app,
/// like the browser window: a tiny HTTP endpoint on 127.0.0.1, on a port picked at launch, that
/// only answers requests carrying this launch's random token.
@MainActor
enum Bridge {
    nonisolated(unsafe) private(set) static var port: UInt16 = 0
    nonisolated static let token = UUID().uuidString
    private static var listener: NWListener?
    /// A screenshot the current request produced (one tool call at a time per run).
    private static var image: Data?

    /// Starts listening (once). Returns when the port is known, so runs launched right after can use it.
    static func start() async {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else { return }
        listener = l
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            var resumed = false
            l.stateUpdateHandler = { state in
                Task { @MainActor in
                    if case .ready = state, !resumed { port = l.port?.rawValue ?? 0; resumed = true; c.resume() }
                    if case .failed = state, !resumed { resumed = true; c.resume() }
                }
            }
            l.newConnectionHandler = { conn in Task { @MainActor in serve(conn) } }
            l.start(queue: .main)
        }
        Log.app.info("bridge on \(port)")
    }

    private static func serve(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, Data())
    }

    private static func receive(_ conn: NWConnection, _ sofar: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, _ in
            Task { @MainActor in
                var buf = sofar
                if let data { buf.append(data) }
                guard let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                    if done { conn.cancel() } else { receive(conn, buf) }
                    return
                }
                let head = String(decoding: buf[..<headEnd.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buf[headEnd.upperBound...]
                guard body.count >= length else { receive(conn, buf); return }
                let authorized = head.lowercased().contains("x-pix-token: \(token.lowercased())")
                let request = (try? JSONSerialization.jsonObject(with: body.prefix(length))) as? [String: Any] ?? [:]
                let (text, error) = authorized ? await handle(request) : ("Not allowed.", true)
                var out: [String: Any] = ["text": text, "error": error]
                if let image { out["image"] = image.base64EncodedString() }  // screen_see's screenshot, for the AI to look at
                image = nil
                let reply = (try? JSONSerialization.data(withJSONObject: out)) ?? Data()
                let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(reply.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(header.utf8) + reply, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    private static func num(_ r: [String: Any], _ k: String, _ fallback: Double = -1) -> Double {
        (r[k] as? NSNumber)?.doubleValue ?? fallback
    }

    private static func handle(_ r: [String: Any]) async -> (String, Bool) {
        let b = PixBrowser.shared
        let n = (r["n"] as? NSNumber)?.intValue ?? -1
        let sc = ScreenControl.shared
        switch r["action"] as? String ?? "" {
        case "screen_look": return sc.look(app: (r["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }, vision: r["vision"] as? Bool ?? true)
        case "screen_see":
            let (text, error, jpeg) = await sc.see(app: (r["app"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            image = jpeg
            return (text, error)
        case "screen_click_at":
            let what = r["what"] as? String ?? ""
            let double = r["double"] as? Bool ?? false, right = r["right"] as? Bool ?? false
            return await sc.clickAt(x: num(r, "x"), y: num(r, "y"), what: what, double: double, right: right)
        case "screen_show_at":
            let say = r["say"] as? String ?? ""
            let (text, error, jpeg) = await sc.showAt(x: num(r, "x"), y: num(r, "y"), w: num(r, "w", 0), h: num(r, "h", 0), say: say)
            image = jpeg
            return (text, error)
        case "screen_drag":
            return await sc.drag(from: (num(r, "x"), num(r, "y")), to: (num(r, "to_x"), num(r, "to_y")))
        case "screen_scroll":
            let direction = r["direction"] as? String ?? "down"
            return await sc.scroll(x: num(r, "x"), y: num(r, "y"), direction: direction, amount: Int(num(r, "amount", 3)))
        case "wait_for_user":
            guard let c = sc.controller else { return ("Pix isn't open.", true) }
            return await c.waitForUser(r["say"] as? String ?? "Your turn") ? ("The user is done. Carry on.", false)
                : ("The user didn't continue (stopped, or 10 minutes passed). Say what's left for them to do.", false)
        case "screen_click": return await sc.click(n, then: (r["then"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue })
        case "screen_type": return await sc.type(n, r["text"] as? String ?? "", submit: r["submit"] as? Bool ?? false)
        case "screen_key": return await sc.key(r["keys"] as? String ?? "")
        case "screen_show": return await sc.show(n, say: r["say"] as? String ?? "")
        case "go": return await b.go(r["url"] as? String ?? "")
        case "look": return (await b.look(), false)
        case "click": return await b.click(n)
        case "type": return await b.type(n, r["text"] as? String ?? "", submit: r["submit"] as? Bool ?? false)
        case "scroll": return await b.scroll(r["direction"] as? String ?? "down")
        case "back": return await b.back()
        default: return ("Unknown browser action.", true)
        }
    }

    // MARK: - From the tools' side (the `Pix --mcp` process)

    /// The screenshot (base64 JPEG) the last call brought back, if any. The tool server handles one call at a time.
    nonisolated(unsafe) static var lastImage: String?

    /// Sends one browser action to the app and waits for the page it ends on.
    nonisolated static func call(_ request: [String: Any], timeout: Double = 45) -> (text: String, error: Bool) {
        let env = ProcessInfo.processInfo.environment
        guard let p = env["PIX_BRIDGE"], let t = env["PIX_TOKEN"], let url = URL(string: "http://127.0.0.1:\(p)/browser") else {
            return ("Pix's browser only works while the Pix app is running.", true)
        }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue(t, forHTTPHeaderField: "X-Pix-Token")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: request)
        let sem = DispatchSemaphore(value: 0)
        lastImage = nil
        nonisolated(unsafe) var out: (String, Bool) = ("Pix's browser didn't answer.", true)
        URLSession.shared.dataTask(with: r) { data, _, _ in
            if let data, let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                out = (d["text"] as? String ?? "", d["error"] as? Bool ?? false)
                lastImage = d["image"] as? String  // base64 JPEG; the tool server attaches it to its reply
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return out
    }
}
