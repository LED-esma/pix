import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Canvas plugins: built in (Pix.app/Contents/Resources/Plugins) plus your own (~/Pix/plugins).
/// Each is a folder with plugin.json: name, about, api (lines Pix learns), scripts, styles, uses.
/// A page loads only the plugins its code actually uses.
struct Plugin {
    var name: String
    var about: String
    var api: [String]
    var scripts: [String]
    var styles: [String]
    var uses: [String]       // strings in a page that mean it needs this plugin
    var importmap: [String: String]
    var builtIn: Bool

    static let builtInDir = Bundle.main.resourceURL?.appendingPathComponent("Plugins")
    static let userDir = PixPaths.home.appendingPathComponent("plugins")

    static func all() -> [Plugin] {
        var out: [Plugin] = []
        for (dir, builtIn) in [(builtInDir, true), (userDir, false)] {
            guard let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for n in names.sorted() {
                let url = dir.appendingPathComponent(n).appendingPathComponent("plugin.json")
                guard let d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any],
                      builtIn || !out.contains(where: { $0.name == n }) else { continue }  // yours can't replace a built-in
                out.append(Plugin(name: n, about: d["about"] as? String ?? "", api: d["api"] as? [String] ?? [],
                                  scripts: d["scripts"] as? [String] ?? [], styles: d["styles"] as? [String] ?? [],
                                  uses: d["uses"] as? [String] ?? ["Pix.\(n)"], importmap: d["importmap"] as? [String: String] ?? [:],
                                  builtIn: builtIn))
            }
        }
        return out
    }

    /// What Pix is told about its canvas plugins (core first).
    static func cheatSheet(_ plugins: [Plugin] = all()) -> String {
        // Your own and Pix-built tools are capped so they can't bloat every request.
        let mine = plugins.filter { !$0.builtIn }.prefix(12).map { p -> Plugin in
            var q = p
            q.about = String(q.about.prefix(140))
            q.api = q.api.prefix(3).map { String($0.prefix(240)) }
            return q
        }
        let sorted = (plugins.filter(\.builtIn) + mine).sorted { ($0.name == "core" ? 0 : 1, $0.name) < ($1.name == "core" ? 0 : 1, $1.name) }
        return "Canvas plugins (each loads automatically when your code uses it):\n" + sorted.map { p in
            "- \(p.name): \(p.about)\n" + p.api.map { "  \($0)" }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// A full page for the canvas: theme, the plugins the code uses, error display, then the code.
    static func page(_ html: String, plugins: [Plugin] = all(), extra: [String] = []) -> String {
        let needed = plugins.filter { p in p.name == "core" || extra.contains(p.name) || p.uses.contains { html.contains($0) } }
        let base = "pix://local/plugins/"
        var imports: [String: String] = [:]
        for p in plugins { for (k, v) in p.importmap { imports[k] = base + p.name + "/" + v } }  // cheap; lets any page import
        let map = (try? JSONSerialization.data(withJSONObject: ["imports": imports])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var head = #"<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">"#
        head += #"<script type="importmap">\#(map)</script>"#
        head += #"<script>window.addEventListener("error", e => { const d = document.createElement("div"); d.className = "pix-out err"; d.textContent = "Couldn't draw this: " + e.message; document.body && document.body.appendChild(d); });</script>"#
        // Core goes last so its helpers can see the libraries.
        for p in needed.sorted(by: { ($0.name == "core" ? 1 : 0) < ($1.name == "core" ? 1 : 0) }) {
            for s in p.styles { head += #"<link rel="stylesheet" href="\#(base)\#(p.name)/\#(s)">"# }
            for s in p.scripts { head += #"<script src="\#(base)\#(p.name)/\#(s)"></script>"# }
        }
        head += "<script>window.Pix && Object.freeze(window.Pix);</script>"  // other tools can use Pix's helpers, not replace them
        if let r = html.range(of: "<head>", options: .caseInsensitive) {
            var h = html
            h.insert(contentsOf: head, at: r.upperBound)
            return h
        }
        return "<!doctype html><html><head>\(head)</head><body>\(html)</body></html>"
    }

    /// Everything over http(s) is blocked: canvases run offline on bundled plugins.
    static let offlineRules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#

    static func ensureUserDir() {
        let fm = FileManager.default
        try? fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        let readme = userDir.appendingPathComponent("README.md")
        guard !fm.fileExists(atPath: readme.path) else { return }
        try? """
        # Your Pix canvas plugins

        One folder per plugin. Pix finds them automatically and uses them when they fit.

            ~/Pix/plugins/stopwatch/
              plugin.json
              stopwatch.js

        plugin.json:

            {
              "about": "A stopwatch with laps",
              "api": ["Stopwatch.start(el, {laps: true})"],
              "scripts": ["stopwatch.js"],
              "styles": [],
              "uses": ["Stopwatch."]
            }

        - api: the lines Pix reads to learn your plugin. Keep them short; they're sent with every request.
        - uses: text that, when it appears in a canvas, loads your plugin.
        - Pages run offline: load everything from your folder, not the internet.
        """.write(to: readme, atomically: true, encoding: .utf8)
    }
}

/// Serves pix://local/page (the current canvas) and pix://local/plugins/<name>/<file>.
final class PixScheme: NSObject, WKURLSchemeHandler {
    var page = ""

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let parts = url.path.split(separator: "/").map(String.init)
        var data: Data?
        var mime = "text/html"
        if parts.first == "page" {
            data = Data(page.utf8)
        } else if parts.first == "plugins", parts.count >= 3, !parts.contains("..") {
            let rel = parts.dropFirst().joined(separator: "/")
            for dir in [Plugin.builtInDir, Plugin.userDir].compactMap({ $0 }) {
                let file = dir.appendingPathComponent(rel)
                guard file.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path),
                      let d = try? Data(contentsOf: file) else { continue }
                data = d
                let ext = file.pathExtension.lowercased()
                mime = ["js": "text/javascript", "mjs": "text/javascript", "css": "text/css", "wasm": "application/wasm",
                        "json": "application/json", "zip": "application/zip", "woff2": "font/woff2", "svg": "image/svg+xml",
                        "png": "image/png", "html": "text/html"][ext] ?? UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
                break
            }
        }
        guard let data else {
            task.didFailWithError(NSError(domain: "Pix", code: 404))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Access-Control-Allow-Origin": "*",
                                                      "Content-Length": "\(data.count)"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// A canvas page in a sandboxed, offline web view. Links open in your browser.
final class CanvasWebView: WKWebView, WKNavigationDelegate, WKUIDelegate {
    private let scheme = PixScheme()
    var onLoaded: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoaded?() }

    init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(scheme, forURLScheme: "pix")
        super.init(frame: .zero, configuration: config)
        navigationDelegate = self
        uiDelegate = self
        isInspectable = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Where `target` is on screen (see PixFocus in pix.js); the part also reacts (reveals, pulses, plays).
    func focusRect(_ target: String) async -> NSRect? {
        let arg = (try? JSONSerialization.data(withJSONObject: [target])).map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        guard let json = try? await evaluateJavaScript("JSON.stringify(window.PixFocus ? PixFocus(\(arg)[0]) : null)") as? String,
              let d = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Double],
              let x = d["x"], let y = d["y"], let w = d["w"], let h = d["h"], let window else { return nil }
        var r = NSRect(x: x, y: y, width: w, height: h)
        if !isFlipped { r.origin.y = bounds.height - y - h }
        let visible = visibleRect
        guard r.intersects(visible) else { return nil }
        return window.convertToScreen(convert(r.intersection(visible), to: nil))
    }

    func show(_ html: String, plugins extra: [String] = []) {
        showPage(Plugin.page(html, extra: extra))
    }

    /// Loads an already-built page (used by Forge's tests).
    func showPage(_ page: String) {
        scheme.page = page
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "PixOffline",
                                                                 encodedContentRuleList: Plugin.offlineRules) { [weak self] list, _ in
            guard let self else { return }
            guard let list else {
                // Without the offline rule a canvas could reach the internet, so it doesn't load at all.
                self.loadHTMLString("<p style='font:13px -apple-system;color:gray'>This canvas couldn't be secured, so it wasn't shown.</p>", baseURL: nil)
                return
            }
            self.configuration.userContentController.add(list)
            self.load(URLRequest(url: URL(string: "pix://local/page")!))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "pix" || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" {
            decisionHandler(.allow)
        } else {
            if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
        return nil
    }
}

struct CanvasTool: NSViewRepresentable {
    let html: String
    let plugins: [String]

    func makeNSView(context: Context) -> CanvasWebView {
        let v = CanvasWebView()
        v.show(html, plugins: plugins)
        BoardFocus.canvas = v
        return v
    }

    func updateNSView(_ v: CanvasWebView, context: Context) {}
}

/// The board tool on screen right now, so a walkthrough step can point into it.
@MainActor
enum BoardFocus {
    static weak var canvas: CanvasWebView?
    static weak var graph: GraphNSView?

    static func rect(for target: String) async -> NSRect? {
        if let c = canvas, c.window?.isVisible == true, let r = await c.focusRect(target) { return r }
        if let g = graph, g.window?.isVisible == true { return g.focusRect(target) }
        return nil
    }
}
