import AppKit
import CryptoKit
import Foundation
import Network

/// One-click ways to a free AI, for people who've never seen an API key: sign in with OpenRouter
/// (Pix gets a key of the user's own, nothing to copy), or set up a model on this Mac (Pix installs
/// Ollama if needed and downloads a model that fits, with progress). Both only start on the user's click.
@MainActor
enum FreeAI {
    struct Progress: Equatable { var text: String; var fraction: Double? }

    // MARK: Sign in with OpenRouter (OAuth PKCE)

    nonisolated static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// The code and state from the browser's return trip ("GET /openrouter?code=…&state=… HTTP/1.1").
    nonisolated static func callback(_ request: String) -> (code: String, state: String)? {
        guard let line = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first,
              let path = line.split(separator: " ").dropFirst().first,
              let items = URLComponents(string: "http://localhost" + path)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        return (code, items.first(where: { $0.name == "state" })?.value ?? "")
    }

    /// A free OpenRouter model that can use tools, preferring families that handle Pix well. The free list
    /// changes, so it's read at sign-in.
    nonisolated static func pickFree(_ models: [[String: Any]]) -> String? {
        let usable = models.compactMap { m -> String? in
            guard let id = m["id"] as? String, id.hasSuffix(":free"), (m["supported_parameters"] as? [String] ?? []).contains("tools") else { return nil }
            return id
        }
        for family in ["gemma-4-31b", "nemotron-3-super", "nemotron-3-ultra", "gemma-4", "qwen3", "llama-4", "deepseek", "gpt-oss"] {
            if let hit = usable.first(where: { $0.contains(family) }) { return hit }
        }
        return usable.first
    }

    /// Opens OpenRouter's sign-in, waits for it to come back to Pix (up to 5 minutes), and returns the
    /// key and a free model, or a sentence saying what went wrong.
    static func signInToOpenRouter() async -> Result<(key: String, model: String), FreeAIProblem> {
        let verifier = base64url(Data((0..<48).map { _ in UInt8.random(in: 0...255) }))
        let state = UUID().uuidString
        let params = NWParameters.tcp
        params.acceptLocalOnly = true  // only this Mac's browser can answer
        guard let listener = try? NWListener(using: params) else { return .failure(.init("Pix couldn't get ready for the sign-in.")) }
        defer { listener.cancel() }
        let code: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            var done = false
            func finish(_ v: String?) { guard !done else { return }; done = true; c.resume(returning: v) }
            listener.newConnectionHandler = { conn in
                conn.start(queue: .main)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let request = String(decoding: data ?? Data(), as: UTF8.self)
                    let got = callback(request)
                    let ok = got != nil && got?.state == state
                    let page = ok ? "Pix is connected to OpenRouter. You can close this tab." : "That sign-in didn't come from Pix. Try again from Pix."
                    let body = "<!doctype html><meta charset=utf-8><title>Pix</title><body style=\"font:16px -apple-system;margin:40px\">\(page)</body>"
                    let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                    conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in conn.cancel() })
                    if ok { MainActor.assumeIsolated { finish(got?.code) } }
                }
            }
            listener.stateUpdateHandler = { s in
                MainActor.assumeIsolated {
                    switch s {
                    case .ready:
                        let port = listener.port?.rawValue ?? 0
                        var c = URLComponents(string: "https://openrouter.ai/auth")!
                        c.queryItems = [.init(name: "callback_url", value: "http://localhost:\(port)/openrouter"),
                                        .init(name: "code_challenge", value: challenge(for: verifier)),
                                        .init(name: "code_challenge_method", value: "S256"),
                                        .init(name: "key_label", value: "Pix"), .init(name: "state", value: state)]
                        if let url = c.url { NSWorkspace.shared.open(url) }
                    case .failed: finish(nil)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { finish(nil) }
        }
        guard let code else { return .failure(.init("The OpenRouter sign-in didn't finish.")) }
        // Swap the code for a key that belongs to the user.
        var r = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!, timeoutInterval: 30)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": verifier, "code_challenge_method": "S256"])
        guard let (data, _) = try? await URLSession.shared.data(for: r),
              let key = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["key"] as? String, !key.isEmpty else {
            return .failure(.init("OpenRouter didn't hand back a key."))
        }
        guard let (list, _) = try? await URLSession.shared.data(from: URL(string: "https://openrouter.ai/api/v1/models")!),
              let models = ((try? JSONSerialization.jsonObject(with: list)) as? [String: Any])?["data"] as? [[String: Any]],
              let model = pickFree(models) else {
            return .failure(.init("OpenRouter has no free model that can use Pix's tools right now."))
        }
        return .success((key, model))
    }

    // MARK: A model on this Mac

    /// qwen3:8b on Macs with 16 GB or more (about 5 GB), qwen3:4b below that (about 2.6 GB).
    /// Intel Macs get the small one too: they run models on the processor alone, several times slower.
    nonisolated static func localModel(memory: UInt64 = ProcessInfo.processInfo.physicalMemory, intel: Bool = isIntel) -> (name: String, size: String) {
        memory >= 15 * 1_073_741_824 && !intel ? ("qwen3:8b", "5 GB") : ("qwen3:4b", "2.6 GB")
    }

    nonisolated static var isIntel: Bool {
        #if arch(x86_64)
        return true
        #else
        return false
        #endif
    }

    /// One line of Ollama's download stream ("pulling …", completed/total) as progress.
    nonisolated static func pullProgress(_ line: String) -> Progress? {
        guard let d = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        if let error = d["error"] as? String { return Progress(text: "Error: " + error, fraction: nil) }
        let status = d["status"] as? String ?? ""
        if let total = (d["total"] as? NSNumber)?.doubleValue, total > 0, let done = (d["completed"] as? NSNumber)?.doubleValue {
            return Progress(text: "Downloading the model", fraction: min(1, done / total))
        }
        return Progress(text: status == "success" ? "Ready" : status.prefix(1).uppercased() + status.dropFirst(), fraction: nil)
    }

    /// Installs Ollama if it's missing, then downloads the model that fits this Mac. Returns the model's
    /// name, or what went wrong. `progress` is called on the main thread.
    static func setUpLocalModel(progress: @escaping (Progress) -> Void) async -> Result<String, FreeAIProblem> {
        if !Ollama.isInstalled {
            progress(Progress(text: "Downloading Ollama", fraction: 0))
            let zip = FileManager.default.temporaryDirectory.appendingPathComponent("Ollama-darwin.zip")
            guard await download(URL(string: "https://ollama.com/download/Ollama-darwin.zip")!, to: zip, progress: { progress(Progress(text: "Downloading Ollama", fraction: $0)) }) else {
                return .failure(.init("Ollama didn't download."))
            }
            progress(Progress(text: "Installing Ollama", fraction: nil))
            let apps = FileManager.default.isWritableFile(atPath: "/Applications") ? "/Applications" : NSHomeDirectory() + "/Applications"
            try? FileManager.default.createDirectory(atPath: apps, withIntermediateDirectories: true)
            guard BuiltIn.run("/usr/bin/ditto", ["-x", "-k", zip.path, apps], timeout: 120) != nil,
                  FileManager.default.fileExists(atPath: apps + "/Ollama.app") else { return .failure(.init("Ollama didn't install.")) }
        }
        if !(await Ollama.running()) {
            progress(Progress(text: "Starting Ollama", fraction: nil))
            try? Ollama.start()
            for _ in 0..<60 where !(await Ollama.running()) { try? await Task.sleep(for: .seconds(1)) }
            guard await Ollama.running() else { return .failure(.init("Ollama didn't start.")) }
        }
        let model = localModel().name
        progress(Progress(text: "Downloading the model", fraction: 0))
        var r = URLRequest(url: URL(string: Provider.ollamaURL + "/api/pull")!, timeoutInterval: 3600)
        r.httpMethod = "POST"
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: r)
            var last = Date.distantPast
            for try await line in bytes.lines {
                guard let p = pullProgress(line) else { continue }
                if p.text.hasPrefix("Error") { return .failure(.init("The model didn't download (\(p.text.dropFirst(7))).")) }
                if Date().timeIntervalSince(last) > 0.25 || p.fraction == nil { last = Date(); progress(p) }
            }
        } catch {
            return .failure(.init("The model didn't download."))
        }
        return Ollama.installed().contains(where: { $0.hasPrefix(model.split(separator: ":").first.map(String.init) ?? model) })
            ? .success(model) : .failure(.init("The model didn't finish downloading."))
    }

    private static func download(_ url: URL, to file: URL, progress: @escaping (Double) -> Void) async -> Bool {
        let watcher = DownloadWatcher(progress: progress)
        let session = URLSession(configuration: .default, delegate: watcher, delegateQueue: .main)
        defer { session.finishTasksAndInvalidate() }
        guard let (tmp, response) = try? await session.download(from: url), (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        try? FileManager.default.removeItem(at: file)
        return (try? FileManager.default.moveItem(at: tmp, to: file)) != nil
    }

    private final class DownloadWatcher: NSObject, URLSessionDownloadDelegate {
        let progress: (Double) -> Void
        init(progress: @escaping (Double) -> Void) { self.progress = progress }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}

struct FreeAIProblem: Error { let message: String; init(_ m: String) { message = m } }

extension PixController {
    /// "Sign In with OpenRouter": a key of the user's own, a free model, and Pix switches to it.
    func signInToOpenRouter() {
        model.freeSetup = .init(text: "Waiting for OpenRouter sign-in", fraction: nil)
        Task { @MainActor in
            switch await FreeAI.signInToOpenRouter() {
            case .success(let (key, chosen)):
                Services.setKey(key, for: "openrouter")
                Services.remember(model: chosen, for: "openrouter")
                model.freeSetup = nil
                use(.service(id: "openrouter", model: chosen))
                await checkSetup()
                Log.app.notice("signed in to OpenRouter, \(chosen, privacy: .public)")
            case .failure(let p):
                model.freeSetup = .init(text: p.message, fraction: nil)
            }
        }
    }

    /// "Download a Free Model": Ollama (if needed) and a model that fits this Mac, then Pix switches to it.
    func downloadFreeModel() {
        model.freeSetup = .init(text: "Getting ready", fraction: nil)
        Task { @MainActor in
            switch await FreeAI.setUpLocalModel(progress: { [weak self] p in self?.model.freeSetup = p }) {
            case .success(let name):
                model.freeSetup = nil
                providersChecked = .distantPast
                refreshProviders()
                use(.local(model: Ollama.installed().first { $0.hasPrefix(name.split(separator: ":").first.map(String.init) ?? name) } ?? name))
                await checkSetup()
            case .failure(let p):
                model.freeSetup = .init(text: p.message, fraction: nil)
            }
        }
    }
}
