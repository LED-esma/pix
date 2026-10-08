import AppKit
import WebKit

/// Pix's own browser: a window you can watch while Pix reads, scrolls, clicks and fills in fields.
/// It never types passwords or payment details (you do, right in the window), and anything that
/// submits, buys, sends, signs in or deletes asks you first (see `risk`). Sign-ins you make here
/// stay, like any browser.
@MainActor
final class PixBrowser: NSObject, WKNavigationDelegate {
    static let shared = PixBrowser()

    private var panel: NSPanel?
    private var web: WKWebView!
    private var loading: CheckedContinuation<Void, Never>?

    private func ensureWindow() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                        styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "Pix Browser"
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.level = .floating
        p.setFrameAutosaveName("PixBrowser")
        if p.frame.origin == .zero { p.center() }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // sign-ins you make here are remembered
        web = WKWebView(frame: p.contentView!.bounds, configuration: config)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        p.contentView!.addSubview(web)
        panel = p
    }

    /// Shows the window without stealing focus from what you're doing.
    private func show() {
        ensureWindow()
        if panel?.isVisible != true { panel?.orderFrontRegardless() }
    }

    // MARK: - Actions (each returns what the page looks like afterwards)

    func go(_ address: String) async -> (String, Bool) {
        var a = address.trimmingCharacters(in: .whitespaces)
        if !a.contains("://") { a = "https://" + a }
        guard let url = URL(string: a), ["http", "https"].contains(url.scheme ?? "") else { return ("Give a web address.", true) }
        show()
        web.load(URLRequest(url: url))
        await settle(navigating: true)
        return (await look(), false)
    }

    func back() async -> (String, Bool) {
        guard panel != nil, web.canGoBack else { return ("There's no page to go back to.", true) }
        web.goBack()
        await settle(navigating: true)
        return (await look(), false)
    }

    func scroll(_ direction: String) async -> (String, Bool) {
        guard panel != nil else { return ("Pix's browser isn't open. Use browser_go first.", true) }
        let dy = direction == "up" ? "-0.85" : "0.85"
        _ = try? await web.evaluateJavaScript("window.scrollBy(0, window.innerHeight * \(dy)); 1")
        await settle(navigating: false)
        return (await look(), false)
    }

    func click(_ n: Int) async -> (String, Bool) {
        guard panel != nil else { return ("Pix's browser isn't open. Use browser_go first.", true) }
        let before = web.url
        let ok = (try? await web.evaluateJavaScript(Self.js + "pixClick(\(n))")) as? Bool ?? false
        guard ok else { return ("There's no element \(n) on the page now. Look again with browser_look.", true) }
        await settle(navigating: false)
        if web.url != before { await settle(navigating: true) }
        return (await look(), false)
    }

    func type(_ n: Int, _ text: String, submit: Bool) async -> (String, Bool) {
        guard panel != nil else { return ("Pix's browser isn't open. Use browser_go first.", true) }
        let info = await element(n)
        if info["secret"] as? Bool == true {
            return ("Pix doesn't type passwords or payment details. The user can type it in the Pix Browser window.", true)
        }
        let arg = (try? JSONSerialization.data(withJSONObject: [text])).map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        let ok = (try? await web.evaluateJavaScript(Self.js + "pixType(\(n), \(arg)[0], \(submit))")) as? Bool ?? false
        guard ok else { return ("Element \(n) isn't something to type into.", true) }
        await settle(navigating: false)
        if submit { await settle(navigating: true) }
        return (await look(), false)
    }

    /// The page as Pix sees it: address, title, numbered things to click or type into, and the text.
    func look() async -> String {
        guard panel != nil else { return "Pix's browser isn't open. Use browser_go first." }
        let r = (try? await web.evaluateJavaScript(Self.js + "pixLook()")) as? String ?? ""
        return "\(web.title ?? "") — \(web.url?.absoluteString ?? "")\n\(r)"
    }

    /// What element `n` is, for deciding whether to ask first.
    func element(_ n: Int) async -> [String: Any] {
        guard panel != nil, let s = (try? await web.evaluateJavaScript(Self.js + "pixInfo(\(n))")) as? String else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    /// Plain words for an action that should ask first ("Click “Place your order” on amazon.com?"), or nil.
    func risk(tool: String, input: [String: Any]) async -> String? {
        let n = (input["n"] as? NSNumber)?.intValue ?? Int(input["n"] as? String ?? "") ?? -1
        let info = await element(n)
        let label = (info["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let host = web?.url?.host ?? "this site"
        let words = #"\b(buy|purchase|order|pay|checkout|check out|subscribe|sign in|log in|login|sign up|register|send|submit|post|publish|delete|remove|cancel|confirm|book|reserve|donate|transfer|apply|place|unsubscribe)\b"#
        let wordy = label.range(of: words, options: [.regularExpression, .caseInsensitive]) != nil
        // Searching a site is harmless: search boxes and their buttons go ahead.
        let search = info["search"] as? Bool ?? false
        let submits = (info["submits"] as? Bool ?? false) && !search
        if tool.hasSuffix("browser_type") {
            return input["submit"] as? Bool == true && !search ? "Type and submit “\(label.isEmpty ? "the form" : String(label.prefix(40)))” on \(host)?" : nil
        }
        return wordy || submits ? "Click “\(label.isEmpty ? "that button" : String(label.prefix(50)))” on \(host)?" : nil
    }

    // MARK: - Waiting for pages

    private func settle(navigating: Bool) async {
        if navigating {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                loading?.resume()
                loading = c
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.finishLoading() }  // never wait forever
            }
        }
        try? await Task.sleep(for: .milliseconds(navigating ? 600 : 450))  // let scripts draw the page
    }

    private func finishLoading() { loading?.resume(); loading = nil }
    nonisolated func webView(_ w: WKWebView, didFinish n: WKNavigation!) { Task { @MainActor in finishLoading() } }
    nonisolated func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { Task { @MainActor in finishLoading() } }
    nonisolated func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { Task { @MainActor in finishLoading() } }

    // MARK: - Page script

    /// The page script (Plugins/core/browser.js): finds what can be clicked or typed into, numbers it,
    /// reports the text, clicks and types.
    static let js: String = {
        let url = Bundle.main.resourceURL?.appendingPathComponent("Plugins/core/browser.js")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map { $0 + "\n" } ?? ""
    }()
}
