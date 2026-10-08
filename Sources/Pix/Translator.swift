import Foundation
import Network

/// Lets Pix run on any OpenAI-style AI (OpenAI, Gemini, Groq, Mistral, xAI, Cerebras, LM Studio,
/// llama.cpp, vLLM…), the way OpenClaw does. Claude Code only speaks Claude's message format, so it
/// talks to this tiny server on 127.0.0.1 instead; each request is turned into an OpenAI-style
/// chat completion (tools included), sent to the service with the key from the Keychain, and the
/// streamed answer is turned back into Claude's events. Keys never leave the app.
///
///   Claude Code ──/s/<service>/v1/messages──▶ Translator ──/chat/completions──▶ the service
@MainActor
enum Translator {
    nonisolated(unsafe) private(set) static var port: UInt16 = 0
    nonisolated static let token = UUID().uuidString
    private static var listener: NWListener?

    /// Claude Code's ANTHROPIC_BASE_URL for an OpenAI-style service.
    nonisolated static func baseURL(for id: String) -> String { "http://127.0.0.1:\(port)/s/\(id)" }

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
            l.newConnectionHandler = { conn in Task { @MainActor in conn.start(queue: .main); receive(conn, Data()) } }
            l.start(queue: .main)
        }
        Log.app.info("translator on \(port)")
    }

    // MARK: Serving

    private static func receive(_ conn: NWConnection, _ sofar: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 22) { data, _, done, _ in
            Task { @MainActor in
                var buf = sofar
                if let data { buf.append(data) }
                guard let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                    if done { conn.cancel() } else { receive(conn, buf) }
                    return
                }
                let head = String(decoding: buf[..<headEnd.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                let length = lines.first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buf[headEnd.upperBound...]
                guard body.count >= length else { receive(conn, buf); return }
                let parts = (lines.first ?? "").split(separator: " ")
                let path = parts.count > 1 ? String(parts[1]) : "/"
                let lower = head.lowercased()
                guard lower.contains("x-api-key: \(token.lowercased())") || lower.contains("authorization: bearer \(token.lowercased())") else {
                    send(conn, status: 401, json: error("authentication_error", "Not allowed."))
                    return
                }
                let request = (try? JSONSerialization.jsonObject(with: body.prefix(length))) as? [String: Any] ?? [:]
                await route(conn, path: path, request: request)
            }
        }
    }

    private static func route(_ conn: NWConnection, path: String, request: [String: Any]) async {
        // /s/<id>/v1/messages[/count_tokens][?beta=true]
        let clean = path.split(separator: "?").first.map(String.init) ?? path
        let bits = clean.split(separator: "/").map(String.init)
        guard bits.count >= 4, bits[0] == "s", let s = Services.find(bits[1]), s.api == .openai else {
            send(conn, status: 404, json: error("not_found_error", "No such service."))
            return
        }
        if clean.hasSuffix("/count_tokens") {
            let chars = ((try? JSONSerialization.data(withJSONObject: request)) ?? Data()).count
            send(conn, status: 200, json: ["input_tokens": chars / 4])
            return
        }
        let streaming = request["stream"] as? Bool ?? false
        var outgoing = toOpenAI(request, maxTokensKey: s.url.contains("api.openai.com") ? "max_completion_tokens" : "max_tokens")
        if streaming { outgoing["stream"] = true; outgoing["stream_options"] = ["include_usage": true] }
        guard let url = URL(string: s.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            send(conn, status: 400, json: error("invalid_request_error", "\(s.name)'s address doesn't look right."))
            return
        }
        var r = URLRequest(url: url, timeoutInterval: 600)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = Services.key(s.id), !key.isEmpty { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        r.httpBody = try? JSONSerialization.data(withJSONObject: outgoing)
        let model = request["model"] as? String ?? s.model

        guard streaming else {
            guard let (data, resp) = try? await URLSession.shared.data(for: r), let code = (resp as? HTTPURLResponse)?.statusCode else {
                send(conn, status: 502, json: error("api_error", "Pix couldn't reach \(s.name).")); return
            }
            guard (200..<300).contains(code), let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                send(conn, status: code, json: upstreamError(code, data, s.name)); return
            }
            send(conn, status: 200, json: fromOpenAI(d, model: model))
            return
        }

        guard let (bytes, resp) = try? await URLSession.shared.bytes(for: r), let code = (resp as? HTTPURLResponse)?.statusCode else {
            send(conn, status: 502, json: error("api_error", "Pix couldn't reach \(s.name).")); return
        }
        guard (200..<300).contains(code) else {
            var data = Data()
            do { for try await b in bytes { data.append(b); if data.count > 100_000 { break } } } catch {}
            send(conn, status: code, json: upstreamError(code, data, s.name))
            return
        }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        let converter = StreamConverter(model: model)
        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let chunk = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
                let events = converter.feed(chunk)
                if !events.isEmpty { conn.send(content: Data(events.joined().utf8), completion: .contentProcessed { _ in }) }
            }
        } catch {
            Log.app.error("translator stream: \(String(describing: error), privacy: .public)")
        }
        conn.send(content: Data(converter.finish().joined().utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func send(_ conn: NWConnection, status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    nonisolated static func error(_ type: String, _ message: String) -> [String: Any] {
        ["type": "error", "error": ["type": type, "message": message]]
    }

    nonisolated static func upstreamError(_ code: Int, _ data: Data, _ name: String) -> [String: Any] {
        let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = ((d?["error"] as? [String: Any])?["message"] as? String) ?? (d?["message"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
        let type = code == 401 || code == 403 ? "authentication_error" : code == 429 ? "rate_limit_error" : code == 404 ? "not_found_error"
            : (500..<600).contains(code) ? "api_error" : "invalid_request_error"
        return error(type, "\(name): \(detail.isEmpty ? "error \(code)" : detail)")
    }

    // MARK: Claude's format → OpenAI's (pure, covered by the self-check)

    nonisolated static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        return (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }

    nonisolated static func toOpenAI(_ req: [String: Any], maxTokensKey: String = "max_tokens") -> [String: Any] {
        var messages: [[String: Any]] = []
        let system = text(of: req["system"])
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        for m in req["messages"] as? [[String: Any]] ?? [] {
            let role = m["role"] as? String ?? "user"
            if let s = m["content"] as? String { messages.append(["role": role, "content": s]); continue }
            let blocks = m["content"] as? [[String: Any]] ?? []
            if role == "assistant" {
                var out: [String: Any] = ["role": "assistant"]
                let words = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                out["content"] = words.isEmpty ? NSNull() : words
                let calls: [[String: Any]] = blocks.filter { $0["type"] as? String == "tool_use" }.map { b in
                    let args = (try? JSONSerialization.data(withJSONObject: b["input"] ?? [:])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                    return ["id": b["id"] as? String ?? UUID().uuidString, "type": "function",
                            "function": ["name": b["name"] as? String ?? "", "arguments": args]]
                }
                if !calls.isEmpty { out["tool_calls"] = calls }
                messages.append(out)
                continue
            }
            // A user turn: tool results become "tool" messages first, then whatever the user said.
            for b in blocks where b["type"] as? String == "tool_result" {
                var t = text(of: b["content"])
                if b["is_error"] as? Bool == true { t = "Error: " + t }
                messages.append(["role": "tool", "tool_call_id": b["tool_use_id"] as? String ?? "", "content": t.isEmpty ? "(no output)" : t])
            }
            var parts: [[String: Any]] = []
            for b in blocks {
                switch b["type"] as? String {
                case "text": parts.append(["type": "text", "text": b["text"] as? String ?? ""])
                case "image":
                    if let src = b["source"] as? [String: Any], let data = src["data"] as? String {
                        parts.append(["type": "image_url", "image_url": ["url": "data:\(src["media_type"] as? String ?? "image/jpeg");base64,\(data)"]])
                    }
                default: break
                }
            }
            if parts.isEmpty { continue }
            let onlyText = parts.allSatisfy { $0["type"] as? String == "text" }
            messages.append(["role": "user", "content": onlyText ? parts.compactMap { $0["text"] as? String }.joined(separator: "\n") : parts])
        }
        var out: [String: Any] = ["model": req["model"] as? String ?? "", "messages": messages]
        if let n = req["max_tokens"] { out[maxTokensKey] = n }
        if let t = req["temperature"] { out["temperature"] = t }
        if let stops = req["stop_sequences"] as? [String], !stops.isEmpty { out["stop"] = stops }
        let tools: [[String: Any]] = (req["tools"] as? [[String: Any]] ?? []).compactMap { t in
            guard let name = t["name"] as? String else { return nil }  // Anthropic server tools (no name/schema) are skipped
            var schema = t["input_schema"] as? [String: Any] ?? ["type": "object", "properties": [:]]
            schema.removeValue(forKey: "$schema")
            return ["type": "function", "function": ["name": name, "description": t["description"] as? String ?? "", "parameters": schema]]
        }
        if !tools.isEmpty {
            out["tools"] = tools
            if let choice = req["tool_choice"] as? [String: Any] {
                switch choice["type"] as? String {
                case "any": out["tool_choice"] = "required"
                case "tool": out["tool_choice"] = ["type": "function", "function": ["name": choice["name"] as? String ?? ""]]
                case "none": out["tool_choice"] = "none"
                default: out["tool_choice"] = "auto"
                }
            }
        }
        return out
    }

    nonisolated static func stopReason(_ finish: String?) -> String {
        switch finish {
        case "tool_calls", "function_call": return "tool_use"
        case "length": return "max_tokens"
        default: return "end_turn"
        }
    }

    /// A whole (non-streamed) OpenAI answer as Claude's message.
    nonisolated static func fromOpenAI(_ d: [String: Any], model: String) -> [String: Any] {
        let choice = (d["choices"] as? [[String: Any]])?.first ?? [:]
        let msg = choice["message"] as? [String: Any] ?? [:]
        var content: [[String: Any]] = []
        if let t = msg["content"] as? String, !t.isEmpty { content.append(["type": "text", "text": t]) }
        for c in msg["tool_calls"] as? [[String: Any]] ?? [] {
            let f = c["function"] as? [String: Any] ?? [:]
            let args = (f["arguments"] as? String).flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] } ?? [:]
            content.append(["type": "tool_use", "id": c["id"] as? String ?? "toolu_\(UUID().uuidString.prefix(12))", "name": f["name"] as? String ?? "", "input": args])
        }
        let u = d["usage"] as? [String: Any] ?? [:]
        return ["id": d["id"] as? String ?? "msg_\(UUID().uuidString.prefix(12))", "type": "message", "role": "assistant", "model": model,
                "content": content, "stop_reason": stopReason(choice["finish_reason"] as? String), "stop_sequence": NSNull(),
                "usage": ["input_tokens": u["prompt_tokens"] as? Int ?? 0, "output_tokens": u["completion_tokens"] as? Int ?? 0]]
    }

    /// OpenAI's streamed chunks → Claude's streamed events, one chunk at a time.
    final class StreamConverter {
        private let model: String
        private var started = false
        private var next = 0                 // the next content block index
        private var textBlock: Int?          // the open text block, if any
        private var tools: [Int: Int] = [:]  // OpenAI tool-call index → our block index
        private var pending: [Int: (id: String?, name: String?, args: String)] = [:]
        private var stop = "end_turn"
        private var inputTokens = 0, outputTokens = 0

        init(model: String) { self.model = model }

        private func event(_ type: String, _ body: [String: Any]) -> String {
            var b = body
            b["type"] = type
            let json = (try? JSONSerialization.data(withJSONObject: b)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return "event: \(type)\ndata: \(json)\n\n"
        }

        private func start() -> [String] {
            guard !started else { return [] }
            started = true
            return [event("message_start", ["message": ["id": "msg_\(UUID().uuidString.prefix(16))", "type": "message", "role": "assistant",
                                                        "model": model, "content": [], "stop_reason": NSNull(), "stop_sequence": NSNull(),
                                                        "usage": ["input_tokens": 0, "output_tokens": 0]]])]
        }

        private func closeText() -> [String] {
            guard let i = textBlock else { return [] }
            textBlock = nil
            return [event("content_block_stop", ["index": i])]
        }

        func feed(_ chunk: [String: Any]) -> [String] {
            var out = start()
            if let u = chunk["usage"] as? [String: Any] {
                inputTokens = u["prompt_tokens"] as? Int ?? inputTokens
                outputTokens = u["completion_tokens"] as? Int ?? outputTokens
            }
            guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { return out }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            if let t = delta["content"] as? String, !t.isEmpty {
                if textBlock == nil {
                    textBlock = next
                    next += 1
                    out.append(event("content_block_start", ["index": textBlock!, "content_block": ["type": "text", "text": ""]]))
                }
                out.append(event("content_block_delta", ["index": textBlock!, "delta": ["type": "text_delta", "text": t]]))
            }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let i = call["index"] as? Int ?? 0
                let f = call["function"] as? [String: Any] ?? [:]
                var p = pending[i] ?? (nil, nil, "")
                if let id = call["id"] as? String, !id.isEmpty { p.id = id }
                if let n = f["name"] as? String, !n.isEmpty { p.name = n }
                p.args += f["arguments"] as? String ?? ""
                if tools[i] == nil, let name = p.name {
                    out += closeText()
                    tools[i] = next
                    next += 1
                    out.append(event("content_block_start", ["index": tools[i]!, "content_block": ["type": "tool_use", "id": p.id ?? "toolu_\(UUID().uuidString.prefix(12))",
                                                                                                    "name": name, "input": [:]]]))
                }
                if let block = tools[i], !p.args.isEmpty {
                    out.append(event("content_block_delta", ["index": block, "delta": ["type": "input_json_delta", "partial_json": p.args]]))
                    p.args = ""
                }
                pending[i] = p
            }
            if let f = choice["finish_reason"] as? String { stop = Translator.stopReason(f) }
            return out
        }

        func finish() -> [String] {
            var out = start() + closeText()
            for block in tools.values.sorted() { out.append(event("content_block_stop", ["index": block])) }
            tools = [:]
            out.append(event("message_delta", ["delta": ["stop_reason": stop, "stop_sequence": NSNull()],
                                               "usage": ["input_tokens": inputTokens, "output_tokens": outputTokens]]))
            out.append(event("message_stop", [:]))
            return out
        }
    }
}
