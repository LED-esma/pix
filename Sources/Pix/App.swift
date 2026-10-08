import SwiftUI
import AVFoundation
import AppKit
import JavaScriptCore

@main
enum Main {
    static func main() {
        // Writing to a Claude Code process that just exited raises SIGPIPE, which would kill Pix.
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--mcp") { BuiltIn.serve() }  // Pix's own tools, for Claude Code
        if CommandLine.arguments.contains("--selfcheck") { exit(SelfCheck.run() ? 0 : 1) }
        if let i = CommandLine.arguments.firstIndex(of: "--render-graph"), i + 1 < CommandLine.arguments.count {
            // Offscreen check of the graph canvas: the parabola with its roots and vertex.
            let v = GraphNSView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
            v.curves = [.init(expr: Expr.parse("2x^2 - 8x + 6")!, color: GraphTool.palette[0]),
                        .init(expr: Expr.parse("1/(x-4)")!, color: GraphTool.palette[1])]
            v.points = [.init(x: 1, y: 0, label: "root"), .init(x: 3, y: 0, label: "root"), .init(x: 2, y: -2, label: "vertex")]
            v.fit(xmin: -1, xmax: 5)
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        }
        let argv = CommandLine.arguments
        if argv.contains("--auto") { Auto.forced = true }
        if let i = argv.firstIndex(of: "--screen-click"), i + 2 < argv.count, let n = Int(argv[i + 2]) {  // tests: Do It's click on [n] in an app
            MainActor.assumeIsolated {
                _ = NSApplication.shared
                _ = ScreenControl.shared.look(app: argv[i + 1])
                let done = DispatchSemaphore(value: 0)
                Task { @MainActor in print(await ScreenControl.shared.click(n).0); done.signal() }
                while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            }
            exit(0)
        }
        if argv.contains("--voices") {  // which voices Pix can speak with, most natural first
            for v in AVSpeechSynthesisVoice.speechVoices() where v.language.hasPrefix("en") { print(v.quality.rawValue, v.identifier) }
            print("chosen:", Voice.choices.prefix(5).map(Voice.label))
            exit(0)
        }
        if let i = argv.firstIndex(of: "--screen-text"), i + 1 < argv.count {  // tests: what an app's window shows, as Pix reads it
            MainActor.assumeIsolated {
                _ = NSApplication.shared
                print(ScreenControl.shared.look(app: argv[i + 1]).0)
            }
            exit(0)
        }
        if let i = argv.firstIndex(of: "--ask"), i + 2 < argv.count {
            let image = argv.firstIndex(of: "--image").flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil }
            let use = argv.firstIndex(of: "--use").flatMap { $0 + 1 < argv.count ? argv[$0 + 1].components(separatedBy: ",") : nil } ?? []
            MainActor.assumeIsolated {
                let after = argv.firstIndex(of: "--after").flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil }
                let on = argv.firstIndex(of: "--on").flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil }
                if let folder = argv.firstIndex(of: "--project").flatMap({ $0 + 1 < argv.count ? argv[$0 + 1] : nil }),
                   let root = Project.root(from: URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)) {
                    var p = Project(root: root, app: "Terminal", isTerminal: true)
                    p.look()
                    Headless.project = p
                }
                let provider: Provider = on == "apple" ? .local(model: AppleModel.id)
                    : on == "local" ? Ollama.installed().first.map { .local(model: $0) } ?? .claude
                    : on == "gateway" ? .gateway(url: Provider.omniRouteURL, model: "auto")
                    : on == "cloud" ? .cloud(model: Ollama.cloudDefault)
                    : on.flatMap(Services.find).map { .service(id: $0.id, model: $0.model) } ?? .claude  // --on openrouter, deepseek…
                Headless.ask(goal: argv[i + 1], out: argv[i + 2], members: i + 3 < argv.count ? Int(argv[i + 3]) ?? 0 : 0,
                             image: image, use: use, after: after, on: provider)
            }
        }
        if let i = argv.firstIndex(of: "--forge"), i + 1 < argv.count {  // test-install a tool spec (JSON file)
            MainActor.assumeIsolated {
                _ = NSApplication.shared
                NSApp.setActivationPolicy(.prohibited)
                let spec = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: argv[i + 1])))) as? [String: Any] ?? [:]
                Task { @MainActor in
                    switch await Forge.install(spec) {
                    case .installed(let n, let v): print("installed \(n) v\(v)")
                    case .rejected(let n, let why): print("rejected \(n): \(why)")
                    }
                    exit(0)
                }
            }
            RunLoop.main.run()
        }
        if let i = argv.firstIndex(of: "--detect-project"), i + 1 < argv.count {  // what Pix would see from that app
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: argv[i + 1]).first
            if let p = Project.detect(app) { print(p.context + "\n\nSuggestions: " + p.suggestions.joined(separator: " | ")) } else { print("no project found") }
            exit(0)
        }
        if let i = argv.firstIndex(of: "--check-service"), i + 2 < argv.count {  // does this key work? (prints why not)
            let s = Services.find(argv[i + 1])
            Task { print(s == nil ? "no such service" : await Services.check(s!, key: argv[i + 2], model: s!.model) ?? "ok"); exit(0) }
            RunLoop.main.run()
        }
        if argv.contains("--doctor") {  // is everything Pix depends on working?
            Task { print(await Doctor.report()); exit(0) }
            RunLoop.main.run()
        }
        if argv.contains("--discover") {  // prints the toolbox servers Pix can see
            Task { print(await Toolbox.discover()); exit(0) }
            RunLoop.main.run()
        }
        if let i = argv.firstIndex(of: "--focus-canvas"), i + 3 < argv.count {
            MainActor.assumeIsolated { Headless.focusCanvas(argv[i + 1], targets: Array(argv[(i + 3)...]), out: argv[i + 2]) }
        }
        if let i = argv.firstIndex(of: "--time-canvas"), i + 1 < argv.count {
            MainActor.assumeIsolated { Headless.timeCanvas(argv[i + 1]) }
        }
        if let i = argv.firstIndex(of: "--render-math"), i + 2 < argv.count {
            MainActor.assumeIsolated { Headless.renderMath(argv[i + 1], out: argv[i + 2], lines: argv.contains("lines")) }
        }
        if let i = argv.firstIndex(of: "--render-setup"), i + 1 < argv.count {  // tests: the "needs an AI" card, as a picture
            MainActor.assumeIsolated {
                _ = NSApplication.shared
                let m = PixModel()
                if argv.contains("progress") { m.freeSetup = .init(text: "Downloading the model", fraction: 0.42) }
                let r = ImageRenderer(content: SetupPreview.card(model: m, controller: PixController()).frame(width: 340).padding(16)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: argv[i + 1])); print("rendered → \(argv[i + 1])")
                }
            }
            exit(0)
        }
        if let i = argv.firstIndex(of: "--render-canvas"), i + 2 < argv.count {
            MainActor.assumeIsolated { Headless.renderCanvas(input: argv[i + 1], out: argv[i + 2]) }
        }
        if CommandLine.arguments.contains("--print-args") {  // for bench/bench.py: the exact command lines Pix runs
            let args: [String: Any] = ["solo": Solo.args(today: Solo.today()), "claude": ClaudeRunner.claudeURL()?.path ?? ""]
            let data = try! JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted])
            print(String(decoding: data, as: UTF8.self))
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let pix = PixController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened from the Dock: come out ready to type. Opened at login: just tuck into the bezel.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        pix.start(openNow: !atLogin)
    }

    /// Clicking the Dock icon calls Pix over.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        pix.summon()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { pix.shutdown() }
}
