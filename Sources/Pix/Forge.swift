import AppKit
import JavaScriptCore
import WebKit

/// Pix building its own canvas tools, safely.
///
/// A tool Pix writes is just a plugin in ~/Pix/plugins. Before it's kept it must pass checks
/// (name, size, syntax) and its own test in a hidden, offline page with a time limit. Tools
/// can't touch the app, the built-in plugins, your files, or the internet; a broken one only
/// fails its own script. Every change is backed up, so Undo and Remove are always there.
@MainActor
enum Forge {
    static let backups = Plugin.userDir.appendingPathComponent(".backups")
    static let staging = Plugin.userDir.appendingPathComponent(".staging")

    enum Outcome { case installed(String, version: Int), rejected(String, reason: String) }

    // MARK: - Checks (pure, covered by the self-check)

    static func validate(_ spec: [String: Any]) -> String? {
        let name = spec["name"] as? String ?? ""
        guard name.range(of: #"^[a-z][a-z0-9-]{1,30}$"#, options: .regularExpression) != nil else {
            return "name must be lowercase letters, digits, or dashes"
        }
        if Plugin.all().contains(where: { $0.builtIn && $0.name == name }) { return "\(name) is a built-in tool" }
        if let m = manifest(name), m["by"] as? String != "pix" { return "you already have your own tool named \(name)" }
        let js = spec["js"] as? String ?? ""
        guard !js.isEmpty, js.utf8.count <= 150_000 else { return "code must be 1 byte to 150 KB" }
        guard (spec["css"] as? String ?? "").utf8.count <= 30_000 else { return "styles over 30 KB" }
        let api = spec["api"] as? [String] ?? []
        guard (1...3).contains(api.count), api.allSatisfy({ $0.count <= 240 }) else { return "api needs 1–3 short lines" }
        guard (spec["about"] as? String ?? "").count <= 140 else { return "about is too long" }
        let ctx = JSContext()!
        ctx.setObject(js, forKeyedSubscript: "src" as NSString)
        ctx.evaluateScript("new Function(src)")  // parses without running
        if let e = ctx.exception { return "code doesn't parse: \(e)" }
        return nil
    }

    // MARK: - Test, then install

    static func install(_ spec: [String: Any]) async -> Outcome {
        let name = spec["name"] as? String ?? "tool"
        if let problem = validate(spec) { return .rejected(name, reason: problem) }
        let fm = FileManager.default
        let stage = staging.appendingPathComponent(name)
        try? fm.removeItem(at: stage)
        try? fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let js = spec["js"] as? String ?? "", css = spec["css"] as? String ?? ""
        try? js.write(to: stage.appendingPathComponent("plugin.js"), atomically: true, encoding: .utf8)
        if !css.isEmpty { try? css.write(to: stage.appendingPathComponent("plugin.css"), atomically: true, encoding: .utf8) }

        if let failure = await test(stageName: ".staging/\(name)", hasCSS: !css.isEmpty, test: spec["test"] as? String ?? "") {
            Log.forge.notice("rejected \(name, privacy: .public): \(failure, privacy: .public)")
            return .rejected(name, reason: failure)
        }

        // Passed: back up whatever was there, then move it into place.
        let dest = Plugin.userDir.appendingPathComponent(name)
        var version = 1
        if let old = manifest(name) {
            version = (old["version"] as? Int ?? 1) + 1
            let backup = backups.appendingPathComponent(name).appendingPathComponent("\(Int(Date().timeIntervalSince1970))")
            try? fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: dest, to: backup)
        }
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try? js.write(to: dest.appendingPathComponent("plugin.js"), atomically: true, encoding: .utf8)
        if !css.isEmpty { try? css.write(to: dest.appendingPathComponent("plugin.css"), atomically: true, encoding: .utf8) }
        let m: [String: Any] = [
            "name": name, "about": spec["about"] as? String ?? "", "api": spec["api"] as? [String] ?? [],
            "scripts": ["plugin.js"], "styles": css.isEmpty ? [] : ["plugin.css"],
            "uses": (spec["uses"] as? [String] ?? []).filter { $0.count >= 3 }, "by": "pix", "version": version,
            "verified": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dest.appendingPathComponent("plugin.json"))
        }
        Log.forge.notice("installed \(name, privacy: .public) v\(version)")
        return .installed(name, version: version)
    }

    /// Runs the tool's test in a hidden, offline canvas. Returns what went wrong, or nil if it passed.
    private static func test(stageName: String, hasCSS: Bool, test: String) async -> String? {
        let staged = Plugin(name: stageName, about: "", api: [], scripts: ["plugin.js"], styles: hasCSS ? ["plugin.css"] : [],
                            uses: [], importmap: [:], builtIn: false)
        let body = """
        <div id="t"></div>
        <script>try { \(test.isEmpty ? "/* no test */" : test)
        window.__pixTest = "ok"; } catch (e) { window.__pixTest = "error: " + e.message; }</script>
        """
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let web = CanvasWebView()
        web.frame = window.contentView!.bounds
        window.contentView!.addSubview(web)
        window.orderFrontRegardless()
        defer { web.stopLoading(); window.orderOut(nil) }
        web.showPage(Plugin.page(body, plugins: Plugin.all() + [staged], extra: [stageName]))

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            let probe = #"JSON.stringify({ result: window.__pixTest || null, errors: [...document.querySelectorAll(".pix-out.err")].map(e => e.textContent) })"#
            guard let json = await evaluate(web, probe, timeout: 1.5),
                  let d = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
                return "the tool froze its page"
            }
            let errors = d["errors"] as? [String] ?? []
            if let e = errors.first { return e }
            if let r = d["result"] as? String { return r == "ok" ? nil : r }
        }
        return "the test never finished"
    }

    /// Asks the page a question but stops waiting after `timeout`: a frozen page can't hang Pix.
    private static func evaluate(_ web: WKWebView, _ js: String, timeout: Double) async -> String? {
        await withCheckedContinuation { cont in
            var answered = false
            web.evaluateJavaScript(js) { value, _ in
                guard !answered else { return }
                answered = true
                cont.resume(returning: value as? String)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !answered else { return }
                answered = true
                cont.resume(returning: nil)
            }
        }
    }

    // MARK: - Your tools, undo, remove

    static func manifest(_ name: String) -> [String: Any]? {
        let url = Plugin.userDir.appendingPathComponent(name).appendingPathComponent("plugin.json")
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]
    }

    /// Tools Pix built for itself.
    static func built() -> [String] {
        Plugin.all().filter { !$0.builtIn && manifest($0.name)?["by"] as? String == "pix" }.map(\.name)
    }

    static func canUndo(_ name: String) -> Bool { !(versions(name).isEmpty) }

    private static func versions(_ name: String) -> [URL] {
        let dir = backups.appendingPathComponent(name)
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Puts the previous version back.
    static func undo(_ name: String) {
        guard let last = versions(name).last else { return }
        let fm = FileManager.default, dest = Plugin.userDir.appendingPathComponent(name)
        try? fm.removeItem(at: dest)
        try? fm.moveItem(at: last, to: dest)
    }

    /// Takes the tool away (kept in backups, so Undo brings it back).
    static func remove(_ name: String) {
        let fm = FileManager.default
        let backup = backups.appendingPathComponent(name).appendingPathComponent("\(Int(Date().timeIntervalSince1970))")
        try? fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: Plugin.userDir.appendingPathComponent(name), to: backup)
    }
}
