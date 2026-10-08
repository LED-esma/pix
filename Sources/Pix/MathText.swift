import SwiftUI
import WebKit

/// Text with LaTeX math ($…$ inline, $$…$$ display) and Markdown (Plugins/core/markdown.js), typeset
/// with the bundled KaTeX. Short text without math stays a plain SwiftUI Text, so only it pays for a web view.
struct MathText: View {
    let text: String
    var size: CGFloat = 14
    var weight: Font.Weight = .regular
    var secondary = false
    /// The whole text is LaTeX, one display line per line (a step's math).
    var latexLines = false
    /// Full formatting even without math (answers: headings, lists, tables, code).
    var rich = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if latexLines || rich || Self.hasMath(text) {
            MathWeb(html: Self.html(text, size: size, bold: [.semibold, .bold, .heavy, .black].contains(weight), secondary: secondary,
                                    latexLines: latexLines, dark: scheme == .dark))
        } else {
            Text(DoneView.markdown(text))
                .font(.system(size: size, weight: weight))
                .foregroundStyle(secondary ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    static var systemIsDark: Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func hasMath(_ s: String) -> Bool {
        s.contains("$") || s.contains("\\(") || s.contains("\\[")
    }

    /// The page gets the card's own light/dark colors. Left to itself a web view assumes light mode,
    /// which put near-black text on the dark card.
    static func html(_ text: String, size: CGFloat, bold: Bool, secondary: Bool, latexLines: Bool, dark: Bool = systemIsDark) -> String {
        let ink = dark ? (secondary ? "rgba(255,255,255,.62)" : "rgba(255,255,255,.92)")
                       : (secondary ? "rgba(0,0,0,.55)" : "rgba(0,0,0,.86)")
        let line = dark ? "rgba(255,255,255,.14)" : "rgba(0,0,0,.12)"
        let wash = dark ? "rgba(255,255,255,.07)" : "rgba(0,0,0,.05)"
        let source = (try? JSONSerialization.data(withJSONObject: [text], options: [])).map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <link rel="stylesheet" href="pix://local/plugins/math/katex.min.css">
        <script src="pix://local/plugins/math/katex.min.js"></script>
        <script src="pix://local/plugins/core/markdown.js"></script>
        <style>
          html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
          :root { color-scheme: \(dark ? "dark" : "light"); }
          body { font: \(bold ? 600 : 400) \(size)px/1.4 -apple-system, sans-serif; -webkit-user-select: text; color: \(ink); }
          p { margin: 0 0 .45em; } p:last-child { margin-bottom: 0; }
          ul, ol { margin: 0 0 .45em; padding-left: 1.3em; }
          code { font: 12.5px ui-monospace, Menlo, monospace; }
          h2 { font-size: 1.35em; margin: 0 0 .5em; } h3 { font-size: 1.08em; margin: 1.1em 0 .35em; }
          h2:first-child, h3:first-child { margin-top: 0; }
          a { color: -apple-system-control-accent; text-decoration: none; } a:hover { text-decoration: underline; }
          li { margin: .12em 0; }
          hr { border: 0; border-top: 1px solid \(line); margin: .7em 0; }
          blockquote { margin: 0 0 .45em; padding-left: .75em; border-left: 3px solid \(line); opacity: .8; }
          pre { margin: .2em 0 .55em; padding: 8px 10px; border-radius: 8px; background: \(wash); overflow-x: auto; }
          pre code { font-size: 12px; line-height: 1.45; }
          .table { overflow-x: auto; margin: .2em 0 .6em; }
          table { border-collapse: collapse; font-size: .94em; }
          th, td { padding: 5px 10px 5px 0; border-bottom: 1px solid \(line); text-align: left; vertical-align: top; }
          th { font-weight: 600; }
          /* Math in the same typeface as the words around it; KaTeX's own fonts only for big symbols. */
          .katex { font-family: -apple-system, "SF Pro Text", sans-serif; font-size: 1em; }
          .katex .mathnormal, .katex .mathit, .katex .boldsymbol { font-family: -apple-system, "SF Pro Text", sans-serif; font-style: italic; }
          .katex .mathrm, .katex .textrm, .katex .mop, .katex .mord.text, .katex .mathbf { font-family: -apple-system, "SF Pro Text", sans-serif; }
          .katex-display { margin: .2em 0; overflow-x: auto; overflow-y: hidden; }
          .lines .katex-display { text-align: left; } .lines .katex-display > .katex { text-align: left; }
        </style></head><body><div id="out"></div>
        <script>
        const src = \(source)[0], lines = \(latexLines);
        const tex = (t, d) => PixMarkdown.tex(t, d);
        const out = document.getElementById("out");
        if (lines) { out.className = "lines"; out.innerHTML = src.split(/\\n|\\\\\\\\/).filter((l) => l.trim()).map((l) => tex(l.replace(/^\\$+|\\$+$/g, ""), true)).join(""); }
        else out.innerHTML = PixMarkdown.render(src);
        const report = () => window.webkit && webkit.messageHandlers.size && webkit.messageHandlers.size.postMessage(Math.ceil(out.getBoundingClientRect().height));
        new ResizeObserver(report).observe(out); report();
        document.fonts && document.fonts.ready.then(report);
        </script></body></html>
        """
    }
}

/// A transparent, non-scrolling web view that sizes itself to its content.
private struct MathWeb: View {
    let html: String
    @State private var height: CGFloat = 18

    var body: some View {
        Representable(html: html, height: $height).frame(height: height)
    }

    private struct Representable: NSViewRepresentable {
        let html: String
        @Binding var height: CGFloat

        func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

        func makeNSView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.setURLSchemeHandler(context.coordinator.scheme, forURLScheme: "pix")
            config.userContentController.add(context.coordinator, name: "size")
            let web = WKWebView(frame: .zero, configuration: config)
            web.setValue(false, forKey: "drawsBackground")
            web.navigationDelegate = context.coordinator
            load(web, context.coordinator)
            return web
        }

        func updateNSView(_ web: WKWebView, context: Context) {
            if context.coordinator.loaded != html { load(web, context.coordinator) }
        }

        private func load(_ web: WKWebView, _ c: Coordinator) {
            c.loaded = html
            c.scheme.page = html
            web.load(URLRequest(url: URL(string: "pix://local/page")!))
        }

        final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
            let scheme = PixScheme()
            var loaded = ""
            var height: Binding<CGFloat>
            init(height: Binding<CGFloat>) { self.height = height }

            func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
                if let h = m.body as? NSNumber, abs(CGFloat(truncating: h) - height.wrappedValue) > 0.5 {
                    height.wrappedValue = max(CGFloat(truncating: h), 10)
                }
            }

            /// Links (sources) open in your browser; the text itself never navigates away.
            func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction,
                         decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
                if action.navigationType == .linkActivated, let url = action.request.url {
                    if ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
                    decisionHandler(.cancel)
                    return
                }
                decisionHandler(.allow)
            }
        }
    }
}
