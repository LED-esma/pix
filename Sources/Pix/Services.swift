import Foundation
import Security

/// Other AIs Pix can run on. Claude Code stays the engine (tools, questions, permissions); it just
/// talks to a different service. Like OpenClaw, a service speaks one of two dialects: Claude's
/// (Claude Code talks to it directly) or OpenAI's (Pix's Translator sits in between). Adding one is a
/// single entry: here for the built-in catalog, or in ~/Pix/services.json for your own:
///
///     [{"id": "mine", "name": "My AI", "url": "https://example.com/v1", "model": "model-name", "api": "openai"}]
///
/// Keys live in the macOS Keychain, never in a file. Servers on this Mac (LM Studio, llama.cpp) need none.
struct Service: Equatable {
    enum API: String { case anthropic, openai }

    var id: String
    var name: String
    var url: String        // Claude-style: Claude Code's ANTHROPIC_BASE_URL. OpenAI-style: the base before /chat/completions
    var model: String      // what it starts on ("" = pick one once the key is in)
    var keyPage = ""       // where to get a key
    var about = ""         // the menu's words for it
    var api = API.anthropic
    var local = false      // a server on this Mac: no key, found on its own

    var json: [String: Any] { ["id": id, "name": name, "url": url, "model": model, "keyPage": keyPage, "about": about, "api": api.rawValue, "local": local] }

    init(id: String, name: String, url: String, model: String, keyPage: String = "", about: String = "", api: API = .anthropic, local: Bool = false) {
        self.id = id; self.name = name; self.url = url; self.model = model; self.keyPage = keyPage; self.about = about; self.api = api; self.local = local
    }

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let name = d["name"] as? String, let url = d["url"] as? String,
              let model = d["model"] as? String, !id.isEmpty, url.hasPrefix("http") else { return nil }
        self.init(id: id, name: name, url: url, model: model, keyPage: d["keyPage"] as? String ?? "", about: d["about"] as? String ?? "",
                  api: API(rawValue: d["api"] as? String ?? "") ?? .anthropic, local: d["local"] as? Bool ?? false)
    }
}

enum Services {
    /// The one-click catalog: paste a key, pick a model. (Kimi, GLM, MiniMax and anything else still work
    /// through Other… or services.json.)
    static let builtIn: [Service] = [
        // Big labs
        Service(id: "openai", name: "OpenAI", url: "https://api.openai.com/v1", model: "",
                keyPage: "https://platform.openai.com/api-keys", about: "GPT models", api: .openai),
        Service(id: "gemini", name: "Google Gemini", url: "https://generativelanguage.googleapis.com/v1beta/openai", model: "",
                keyPage: "https://aistudio.google.com/apikey", about: "Gemini models", api: .openai),
        Service(id: "xai", name: "xAI", url: "https://api.x.ai/v1", model: "",
                keyPage: "https://console.x.ai", about: "Grok models", api: .openai),
        Service(id: "mistral", name: "Mistral", url: "https://api.mistral.ai/v1", model: "",
                keyPage: "https://console.mistral.ai/api-keys", about: "Mistral models", api: .openai),
        // Fast and cheap
        Service(id: "groq", name: "Groq", url: "https://api.groq.com/openai/v1", model: "",
                keyPage: "https://console.groq.com/keys", about: "very fast open models", api: .openai),
        Service(id: "cerebras", name: "Cerebras", url: "https://api.cerebras.ai/v1", model: "",
                keyPage: "https://cloud.cerebras.ai", about: "very fast open models", api: .openai),
        Service(id: "deepseek", name: "DeepSeek", url: "https://api.deepseek.com/anthropic", model: "deepseek-chat",
                keyPage: "https://platform.deepseek.com/api_keys", about: "strong and inexpensive"),
        Service(id: "openrouter", name: "OpenRouter", url: "https://openrouter.ai/api", model: "",
                keyPage: "https://openrouter.ai/keys", about: "hundreds of models, one key"),
        // On this Mac (found on their own, no key)
        Service(id: "lmstudio", name: "LM Studio", url: "http://localhost:1234/v1", model: "", about: "a model on this Mac", api: .openai, local: true),
        Service(id: "llamacpp", name: "llama.cpp", url: "http://localhost:8080/v1", model: "", about: "a model on this Mac", api: .openai, local: true),
    ]

    /// Models the local servers have loaded right now (filled by `detectLocal`).
    nonisolated(unsafe) static var detected: [String: [String]] = [:]

    /// Asks LM Studio and llama.cpp (if they're running) what they have. Quick, and silent when they aren't.
    static func detectLocal() async {
        for s in all where s.local {
            var r = URLRequest(url: URL(string: s.url + "/models")!, timeoutInterval: 0.8)
            r.httpMethod = "GET"
            if let (data, _) = try? await URLSession.shared.data(for: r),
               let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                detected[s.id] = (d["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.filter { !$0.contains("embed") }
            } else {
                detected[s.id] = nil
            }
        }
    }

    static let file = PixPaths.home.appendingPathComponent("services.json")

    static func custom(in file: URL = file) -> [Service] {
        ((try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [[String: Any]] ?? []).compactMap(Service.init)
    }

    static func saveCustom(_ s: Service, in file: URL = file) {
        let list = custom(in: file).filter { $0.id != s.id } + [s]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: list.map(\.json), options: [.prettyPrinted]) { try? data.write(to: file) }
    }

    /// Built-in ones first; your own replace a built-in with the same id. A catalog entry with no
    /// default model starts on the one picked when it was added.
    static var all: [Service] {
        let mine = custom()
        return builtIn.filter { b in !mine.contains { $0.id == b.id } }.map { b in
            var s = b
            if s.model.isEmpty { s.model = UserDefaults.standard.string(forKey: "service.model.\(b.id)") ?? "" }
            return s
        } + mine
    }

    static func remember(model: String, for id: String) { UserDefaults.standard.set(model, forKey: "service.model.\(id)") }

    static func find(_ id: String) -> Service? { all.first { $0.id == id } }

    /// The ones ready to use: a key saved, or a server on this Mac that's running (on its first model).
    static var ready: [Service] {
        all.compactMap { s in
            if s.local {
                guard let first = detected[s.id]?.first else { return nil }
                var l = s
                if l.model.isEmpty { l.model = first }
                return l
            }
            return key(s.id) != nil ? s : nil
        }
    }

    /// Claude Code's address for a service: its own for Claude-style, Pix's Translator for OpenAI-style.
    static func endpoint(_ s: Service) -> (url: String, token: String) {
        s.api == .openai ? (Translator.baseURL(for: s.id), Translator.token) : (s.url, key(s.id) ?? "")
    }

    // MARK: - Keys, in the Keychain

    private static let keychain = "com.ramonledesma.pix.ai"

    static func key(_ id: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychain,
                                kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setKey(_ key: String, for id: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychain, kSecAttrAccount as String: id]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrLabel as String] = "Pix · \(find(id)?.name ?? id)"
        SecItemAdd(add as CFDictionary, nil)
    }

    static func removeKey(_ id: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychain, kSecAttrAccount as String: id] as CFDictionary)
    }

    // MARK: - Checking a key, and the models a service has

    private static func request(_ s: Service, path: String, key: String, body: [String: Any]? = nil) -> URLRequest? {
        guard let url = URL(string: s.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "content-type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    /// Sends a one-word message. Nil means it worked; otherwise what went wrong, in plain words.
    static func check(_ s: Service, key: String, model: String) async -> String? {
        guard !model.isEmpty else { return "Pick one of \(s.name)'s models." }
        let openai = s.api == .openai
        let body: [String: Any] = openai
            ? ["model": model, (s.url.contains("api.openai.com") ? "max_completion_tokens" : "max_tokens"): 16, "messages": [["role": "user", "content": "hi"]]]
            : ["model": model, "max_tokens": 1, "messages": [["role": "user", "content": "hi"]]]
        guard let r = request(s, path: openai ? "/chat/completions" : "/v1/messages", key: key, body: body) else { return "That address doesn't look right." }
        guard let (data, resp) = try? await URLSession.shared.data(for: r), let code = (resp as? HTTPURLResponse)?.statusCode else {
            return "Pix couldn't reach \(s.name)."
        }
        if (200..<300).contains(code) { return nil }
        let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = ((d?["error"] as? [String: Any])?["message"] as? String) ?? (d?["message"] as? String) ?? ""
        switch code {
        case 401, 403: return "\(s.name) didn't accept that key."
        case 402: return "That \(s.name) account is out of credit."
        case 404, 400 where detail.lowercased().contains("model"): return "\(s.name) doesn't have the model \(model)."
        default: return "\(s.name) said: " + (detail.isEmpty ? "error \(code)" : String(detail.prefix(120)))
        }
    }

    /// The models a service offers (most list them at /v1/models), for the model menu.
    static func models(_ s: Service, key: String) async -> [String] {
        guard let r = request(s, path: s.api == .openai ? "/models" : "/v1/models", key: key),
              let (data, _) = try? await URLSession.shared.data(for: r),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let ids = (d["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.filter { !$0.hasSuffix(":batch") }
        return Array(ids.sorted().prefix(400))
    }
}
