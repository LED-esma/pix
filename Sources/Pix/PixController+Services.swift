import AppKit

/// Adding another AI: pick a service, paste a key, pick a model. Pix checks the key with a one-word
/// message before keeping it (in the Keychain).
extension PixController {
    func startAdding(_ id: String? = nil) {
        if case .setup = model.phase { model.phase = .idle }
        model.adding = true
        let first = id ?? { if case .service(let current, _) = model.provider { return current }; return "gemini" }()  // Gemini's free key is the easiest
        pickService(first)
        openBubble()
    }

    func pickService(_ id: String) {
        model.addID = id
        model.addProblem = nil
        model.addModels = []
        model.addKey = id == "custom" ? "" : Services.key(id) ?? ""
        if case .service(let current, let m) = model.provider, current == id { model.addModel = m }
        else { model.addModel = Services.find(id)?.model ?? "" }
        if id == "custom" { model.addName = ""; model.addURL = "" }
        fetchModels()
    }

    /// The model menu fills in once there's a key (OpenRouter lists its models without one).
    func fetchModels() {
        guard let s = addingService else { return }
        let key = model.addKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty || s.id == "openrouter" || s.local else { return }
        let id = s.id
        Task { @MainActor in
            let found = await Services.models(s, key: key)
            guard model.addID == id else { return }  // picked another one meanwhile
            model.addModels = found
        }
    }

    /// The service the card describes (for Other…, built from the name and address typed in).
    var addingService: Service? {
        if model.addID == "custom" {
            let name = model.addName.trimmingCharacters(in: .whitespaces), url = model.addURL.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, url.hasPrefix("http") else { return nil }
            let id = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            return Service(id: id, name: name, url: url, model: model.addModel, api: model.addOpenAI ? .openai : .anthropic)
        }
        return Services.find(model.addID)
    }

    func addService() {
        guard var s = addingService else { model.addProblem = "Add a name and an address starting with https://."; return }
        let key = model.addKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = model.addModel.trimmingCharacters(in: .whitespaces).isEmpty ? s.model : model.addModel.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty || s.local else { model.addProblem = "\(s.name) needs a key."; return }
        model.addChecking = true
        model.addProblem = nil
        Task { @MainActor in
            let problem = await Services.check(s, key: key, model: chosen)
            model.addChecking = false
            if let problem { model.addProblem = problem; return }
            if model.addID == "custom" { s.model = chosen; Services.saveCustom(s) }
            if !key.isEmpty { Services.setKey(key, for: s.id) }
            Services.remember(model: chosen, for: s.id)
            model.addKey = ""
            model.adding = false
            use(.service(id: s.id, model: chosen))
            model.phase = .idle
            Log.app.notice("added \(s.name, privacy: .public)")
        }
    }

    /// Forgets the key; Lite goes back to Claude if it was using this one.
    func removeService() {
        let id = model.addID
        Services.removeKey(id)
        if case .service(let current, _) = model.provider, current == id { model.provider = .claude }
        model.addKey = ""
        model.addProblem = nil
    }
}
