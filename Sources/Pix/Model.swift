import Foundation
import SwiftUI

enum Mode: String, CaseIterable, Identifiable {
    case lite = "Lite", standard = "Standard", deep = "Deep"
    var id: String { rawValue }

    /// What the empty field says: what Pix is for, in a line (like Claude's), not a sample question.
    static let placeholder = "Ask anything or tell Pix what to do"
}

struct Question {
    struct Option: Identifiable { var label: String; var detail: String; var id: String { label } }
    var header: String
    var text: String
    var options: [Option]
    var multiSelect: Bool
}

struct QuestionFlow {
    var requestID: String
    var input: [String: Any]
    var questions: [Question]
    var index = 0
    var answers: [String: String] = [:]
    var current: Question { questions[index] }
}

struct PermissionAsk {
    var requestID: String
    var tool: String
    var input: [String: Any]
    var question: String?  // set when the app knows better words ("Click “Place your order” on amazon.com?")

    var title: String {
        if let question { return question }
        switch tool {
        case "Bash": return "Run a command?"
        case "Write", "Edit", "NotebookEdit": return "Change a file?"
        case "Read", "Glob", "Grep": return "Look at a file?"
        case "WebFetch": return "Open a web page?"
        case BuiltIn.prefix + "shortcut_run": return "Run the “\(input["name"] as? String ?? "")” shortcut?"
        case BuiltIn.prefix + "applescript_run": return (input["why"] as? String).map { "Run this AppleScript? \($0)" } ?? "Run this AppleScript?"
        case BuiltIn.prefix + "shell_run": return (input["why"] as? String).map { "Run this command? \($0)" } ?? "Run this command?"
        default: return Self.question(tool)
        }
    }

    /// "mcp__semester__mark_done" → "Mark done in Semester?"
    nonisolated static func question(_ tool: String) -> String {
        let parts = tool.components(separatedBy: "__")
        guard parts.count >= 3 else { return "Use \(tool)?" }
        let action = parts.last!.replacingOccurrences(of: "_", with: " ")
        let app = Toolbox.label(parts[1].replacingOccurrences(of: "_", with: " "))
        return action.prefix(1).uppercased() + action.dropFirst() + " in \(app)?"
    }

    var detail: String {
        for key in ["script", "command", "file_path", "url", "path", "pattern"] {
            if let v = input[key] as? String { return v }
        }
        // An app's request reads as plain lines, not JSON.
        let lines = input.keys.sorted().compactMap { k -> String? in
            let v = input[k]
            var s = v as? String
            if let n = v as? NSNumber {  // JSON true/false arrive as numbers; say yes/no
                s = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "yes" : "no") : n.stringValue
            }
            guard let s, !s.isEmpty else { return nil }
            return "\(k.replacingOccurrences(of: "_", with: " ")): \(s.count > 80 ? s.prefix(77) + "…" : s)"
        }
        if !lines.isEmpty { return lines.joined(separator: "\n") }
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

struct Guide {
    var answer: String
    var steps: [Screen.Step]
    var path: String?
    var index = 0
    var isLast: Bool { index >= steps.count - 1 }
}

/// The blob's color says what it's doing. The card's status dot uses the same color.
enum Tint: Equatable {
    case base, look, research, evaluate, build

    typealias RGB = (r: Double, g: Double, b: Double)
    var colors: (top: RGB, bottom: RGB) {
        switch self {
        case .base: return (Blob.top, Blob.bottom)
        case .look: return ((0.48, 0.90, 0.93), (0.10, 0.62, 0.74))
        case .research: return ((0.52, 0.76, 1.00), (0.17, 0.44, 0.95))
        case .evaluate: return ((1.00, 0.83, 0.45), (0.95, 0.55, 0.14))
        case .build: return ((0.56, 0.92, 0.66), (0.13, 0.66, 0.41))
        }
    }

    var label: String? {
        switch self {
        case .base: return nil
        case .look: return "Looking at your screen"
        case .research: return "Researching"
        case .evaluate: return "Evaluating"
        case .build: return "Building"
        }
    }

    /// Stage from a status line or a "Stage: x" marker.
    static func from(_ s: String) -> Tint? {
        let t = s.lowercased()
        if t.hasPrefix("research") || t.hasPrefix("searching") || t.hasPrefix("reading") { return .research }
        if t.hasPrefix("evaluat") || t.hasPrefix("scouting") || t.hasPrefix("debating") { return .evaluate }
        if t.hasPrefix("build") || t.hasPrefix("writing") { return .build }
        if t.hasPrefix("looking") { return .look }
        return nil
    }
}

struct Done {
    var gist: String
    var path: String?
    var next: Next?
    var routine: (name: String, steps: String)?  // "Save as Tool": a repeat of the same tools, or a script that worked
}

/// A better way to ask the same question, suggested by Pix itself.
enum Next: Equatable {
    /// For the team buttons: how many agents, how long, and how much of your Claude limit.
    func costHint(members: Int) -> String? {
        if case .team(let m) = self { return TeamCost.hint(m, members: members) }
        return nil
    }

    case team(Mode), screen, use(String)  // use: a connected app's server name

    /// Reads the answer's `next`; apps must be ones you've actually connected.
    static func from(_ raw: Any?, servers: [String]) -> Next? {
        let s = (raw as? String ?? "").trimmingCharacters(in: .whitespaces)
        switch s.lowercased() {
        case "standard": return .team(.standard)
        case "deep": return .team(.deep)
        case "screen": return .screen
        default:
            guard s.lowercased().hasPrefix("use:") else { return nil }
            let name = s.dropFirst(4).trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { return nil }
            return servers.first { Toolbox.label($0).lowercased() == name || $0.lowercased().contains(name) }.map(Next.use)
        }
    }

    var symbol: String {
        switch self {
        case .team: return "person.3"
        case .screen: return "rectangle.dashed"
        case .use: return "wrench.and.screwdriver"
        }
    }

    var label: String {
        switch self {
        case .team(let m): return m == .deep ? "Ask a Bigger Team" : "Ask the Team"
        case .screen: return "Show My Screen"
        case .use(let server): return "Use \(Toolbox.label(server))"
        }
    }
}

struct Failure {
    enum Fix { case retry, screenSettings, signIn, signInOrLite, ollamaSignIn(URL?), none }
    var message: String
    var fix: Fix
}

enum Phase {
    case setup(ClaudeRunner.Readiness, waiting: Bool)
    case idle
    case working(String)
    case question(QuestionFlow)
    case permission(PermissionAsk)
    case guide(Guide)
    case done(Done)
    case failed(Failure)
}

enum Activity { case idle, thinking, alert, happy }

@MainActor
final class PixModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var activity: Activity = .idle {
        didSet { if activity == .happy && oldValue != .happy { happyAt = Date(); animate(for: 1.2) } }
    }
    @Published var goal = ""
    @Published var mode: Mode = .lite
    @Published var deepMembers = 2
    @Published var otherAnswer = ""
    @Published var picked: Set<String> = []
    @Published var startedAt = Date()
    /// A short line under the answer, e.g. a tool Pix built for itself.
    struct Note: Equatable { var text: String; var symbol: String }
    @Published var note: Note?
    /// Who actually answered, checked against Claude Code's usage report ("Answered on this Mac by deepseek-r1:8b").
    @Published var answeredBy: String?
    @Published var installFailed = false
    @Published var freeSetup: FreeAI.Progress?  // signing in to OpenRouter or downloading a model: what's happening
    /// What Pix's tools changed in the last answer (each can be undone), and which were undone.
    @Published var actions: [Actions.Action] = []
    @Published var undone: Set<String> = []
    /// Timers counting down, for the card and the ring around the blob.
    @Published var timers: [Schedules.Entry] = []
    /// The Add an AI card (shown in place of the question field).
    @Published var adding = false
    /// The permissions list (shown in place of the question field), and the one waiting on System Settings.
    @Published var permissions = false
    @Published var waitingFor: Permission?
    /// The current answer came from a try (permissions list or welcome card): its card leads back there.
    @Published var cameFrom: TryOrigin?
    /// The welcome card on a new Mac, the name typed into it, and the one-time "here's how to call Pix" keys.
    @Published var welcome = false
    @Published var pickingAI = false            // the first-run "Pick your AI" step
    @Published var aiChoices: [AIChoice] = []
    @Published var aiPicked: Provider?
    var wantsClaude = false                     // picked Claude before it was set up: don't switch to a free AI meanwhile
    @Published var nameDraft = Welcome.name
    @Published var keysHint = false
    /// How Pix hides (see HideStyle), which bezel it's on, whether it's tucked in now (and since when,
    /// for the change of shape), and asleep (Sleep When Idle).
    @Published var hideStyle = HideStyle.current
    @Published var dockRight = true
    @Published var tucked = false
    var tuckedAt = Date.distantPast
    /// How far into its hiding shape the blob was when `tucked` last changed, so a quick pass of the
    /// mouse reverses the morph from where it is instead of jumping.
    var morphFrom = 0.0
    /// How far the window is from its tucked spot right now (canvas points, y down). Hiding shapes
    /// subtract it so they stay on the bezel while the window slides.
    var offTuck: () -> CGVector = { .zero }

    /// 0 = the blob, 1 = the hiding shape; a spring going in, a quick ease coming out.
    func morph(_ now: Date = Date()) -> Double {
        let age = now.timeIntervalSince(tuckedAt)
        if tucked {
            let p = Motion.reduced ? Ease.out(min(1, age / 0.25)) : Ease.spring(min(1, age / 0.45))
            return morphFrom + (1 - morphFrom) * p
        }
        return morphFrom * (1 - Ease.out(min(1, age / 0.2)))
    }
    @Published var sleeping = false {
        didSet { if sleeping != oldValue { sleepChangedAt = Date(); animate(for: 0.75) } }
    }
    @Published var addID = "openrouter"
    @Published var addKey = ""
    @Published var addModel = ""
    @Published var addName = ""
    @Published var addURL = ""
    @Published var addOpenAI = true  // Other…: OpenAI-style (most services) or Claude-style
    @Published var addModels: [String] = []
    @Published var addProblem: String?
    @Published var addChecking = false

    /// The project behind the terminal or editor you called Pix from (a chip; × leaves it out).
    @Published var project: Project?
    @Published var projectOverride: Bool?
    var projectOn: Bool { project != nil && (projectOverride ?? project!.confident) }

    /// What Lite runs on, and the free options found on this Mac (see Provider).
    @Published var provider = Provider.current { didSet { Provider.current = provider } }
    @Published var localModels: [String] = []
    @Published var gatewayFound = false
    @Published var ollamaInstalled = false

    // Follow-ups: the last answer rides along with your next question (for 30 minutes, or until you drop the chip).
    struct Context { var goal: String; var summary: String; var at: Date }
    @Published var context: Context?
    @Published var followUp = true
    var followingUp: Bool { followUp && (context.map { Date().timeIntervalSince($0.at) < 1800 } ?? false) }

    /// What the next question is sent as: on its own, or after a short recap of the last answer.
    /// "Now: Saturday, October 4, 2026 at 3:42 PM (America/Los_Angeles)". In the question, not the
    /// system prompt, so the cached prompt stays the same all day.
    nonisolated static func now(_ date: Date = Date()) -> String {
        "Now: " + date.formatted(date: .complete, time: .shortened) + " (\(TimeZone.current.identifier))"
    }

    /// Saved tool names ride with the question (not the cached system prompt), so saving one doesn't
    /// make the next run pay to re-read everything.
    nonisolated static var savedToolsLine: String {
        let names = Routines.all().map(\.name)
        return names.isEmpty ? "" : "Saved tools (use_tool): " + names.joined(separator: ", ") + "\n"
    }

    nonisolated static func withMemory(_ goal: String) -> String {
        let known = Memory.prompt()
        return (known.isEmpty ? "" : known + "\n\n") + savedToolsLine + (Auto.on ? Auto.promptLine + "\n" : "") + now() + "\nTheir request: " + goal
    }

    func prompt(for goal: String) -> String {
        let known = Memory.prompt()
        let ask = followingUp && context != nil
            ? "Earlier the user asked: \(context!.goal)\nYou answered:\n\(context!.summary)\n\nTheir follow-up: \(goal)" : "Their request: " + goal
        return (known.isEmpty ? "" : known + "\n\n") + Self.savedToolsLine + (Auto.on ? Auto.promptLine + "\n" : "") + Self.now() + "\n" + ask
    }

    /// A compact recap of an answer (~1–2k tokens at most), for follow-ups.
    nonisolated static func recap(_ out: [String: Any]) -> String {
        var s = (out["title"] as? String).map { "# \($0)\n" } ?? ""
        s += String((out["answer"] as? String ?? "").prefix(1500))
        let steps = (out["steps"] as? [[String: Any]] ?? []).prefix(8).enumerated()
            .map { "\($0.offset + 1). \($0.element["say"] as? String ?? "")" }
        if !steps.isEmpty { s += "\nSteps:\n" + steps.joined(separator: "\n") }
        let board = (out["visuals"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
        if !board.isEmpty { s += "\nOn the board: " + board.joined(separator: ", ") }
        return s
    }
    @Published var runningGoal = ""
    @Published var runningMode: Mode = .lite
    /// Hold to talk: listening now, and what's been heard so far.
    /// A newer Pix on GitHub Releases (Updater), and an install in progress.
    @Published var update: Updater.Release?
    @Published var updating = false
    @Published var updateReady: String?   // downloaded and checked, waiting for a quiet moment
    @Published var justUpdated: String?   // "Updated to Pix …", shown once after an update
    @Published var listening = false
    @Published var heard = ""
    /// Show Me: the step on the card while Pix waits for you to click what it ringed.
    @Published var liveStep: String?
    /// Waiting for you to do something only you can (sign in): the card shows Continue.
    @Published var waitingUser = false

    // Lite can see the screen. On when the goal mentions it ("this", "here"…), unless toggled.
    @Published var screenOverride: Bool?

    // Toolbox: your MCP servers, loaded only when the goal calls for them or you add them.
    @Published var servers: [String] = []
    @Published var toolOverride: [String: Bool] = [:]
    var activeTools: [String] { servers.filter { toolOverride[$0] ?? Toolbox.matches(goal, $0) } }

    // The board: pop-up tools for the current answer.
    @Published var board: [Visual] = []
    @Published var boardIndex = 0
    var screenOn: Bool { mode == .lite && (screenOverride ?? Self.mentionsScreen(goal)) }

    @Published private(set) var tint: Tint = .base
    private(set) var previousTint: Tint = .base
    private(set) var tintChangedAt = Date.distantPast

    func setTint(_ t: Tint) {
        guard t != tint else { return }
        previousTint = tint
        tintChangedAt = Date()
        animate(for: 0.65)
        tint = t
    }

    nonisolated static func mentionsScreen(_ goal: String) -> Bool {
        let words = Set(goal.lowercased().split { !$0.isLetter }.map(String.init))
        return !words.isDisjoint(with: ["this", "here", "screen", "these", "shown", "showing", "page", "window", "highlighted"])
    }

    // Driven by the controller: where the eyes point, and whether Pix is gliding.
    // Eyes glide to a new direction instead of jumping (see shownLook).
    @Published var look = CGVector(dx: -1, dy: 0) {
        willSet { lookFrom = shownLook(); lookAt = Date(); animate(for: 0.22) }
    }
    private var lookFrom = CGVector(dx: -1, dy: 0)
    private var lookAt = Date.distantPast
    @Published var moving = false

    /// The eyes' direction right now, partway between the old look and the new one.
    func shownLook(_ now: Date = Date()) -> CGVector {
        let p = Ease.out(min(1, now.timeIntervalSince(lookAt) / 0.2))
        return CGVector(dx: lookFrom.dx + (look.dx - lookFrom.dx) * p, dy: lookFrom.dy + (look.dy - lookFrom.dy) * p)
    }

    // Motion the blob draws for itself: stretching along a slide, a jiggle on landing, a hop when happy,
    // eyes closing into sleep. The canvas animates until `motionUntil`, then goes back to resting.
    var moveStart = Date.distantPast, moveDuration = 0.25, moveDir = CGVector(dx: 1, dy: 0)
    var landedAt = Date.distantPast
    var happyAt = Date.distantPast
    var sleepChangedAt = Date.distantPast
    private(set) var motionUntil = Date.distantPast
    @Published private(set) var motionTick = 0

    /// Keeps the blob drawing every frame for `seconds`, then lets it rest (a publish at the end
    /// re-evaluates its timeline, so idle CPU goes back to near zero).
    func animate(for seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        guard until > motionUntil else { return }
        motionUntil = until
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in self?.motionTick += 1 }
    }
    @Published var focusTick = 0

    var isBusy: Bool {
        switch phase {
        case .working, .question, .permission: return true
        default: return false
        }
    }

    nonisolated static func k(_ n: Int) -> String {
        n >= 10_000 ? "\(n / 1000)k" : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    nonisolated static func questions(from input: [String: Any]) -> [Question] {
        (input["questions"] as? [[String: Any]] ?? []).map { q in
            Question(
                header: q["header"] as? String ?? "",
                text: q["question"] as? String ?? "",
                options: (q["options"] as? [[String: Any]] ?? []).map {
                    .init(label: $0["label"] as? String ?? "", detail: $0["description"] as? String ?? "")
                },
                multiSelect: q["multiSelect"] as? Bool ?? false)
        }
    }
}
