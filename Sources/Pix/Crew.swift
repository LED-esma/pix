import Foundation

/// Standard and Deep, coordinated by the app itself: every agent is one lean `claude -p`
/// call with a short prompt and only its own tools. Stages run in parallel, agents hand
/// each other ~200-word summaries, one debate round, then Opus writes the final answer.
/// No coordinator model, so nothing re-reads Claude Code's full setup on every turn.
@MainActor
final class Crew {
    enum Role: String, CaseIterable {
        case researcher, scout, builder

        var model: String { self == .builder ? "sonnet" : "haiku" }
        /// Benchmarked: at higher effort Haiku spends a minute or more thinking on search-and-summarize work.
        var effort: String { self == .builder ? "medium" : "low" }
        var tools: String { self == .builder ? "" : "WebSearch,WebFetch" }
        var label: String { rawValue.capitalized }
        var tint: Tint { switch self { case .researcher: return .research; case .scout: return .evaluate; case .builder: return .build } }
        var status: String { switch self { case .researcher: return "Researching"; case .scout: return "Scouting"; case .builder: return "Building" } }
        var verb: String { switch self { case .researcher: return "digging in"; case .scout: return "finding real uses"; case .builder: return "drafting" } }

        /// Different angles so redundant members cross-check instead of repeating each other.
        var angles: [String] {
            switch self {
            case .researcher: return ["official and primary sources", "independent reviews and real-world experience",
                                      "the most recent news and changes", "numbers, specs, and prices"]
            case .scout: return ["the cheapest practical options", "the best-quality options", "the quickest way to start",
                                 "what experienced people actually do"]
            case .builder: return ["the simplest version that fully works", "the most thorough version",
                                   "the version easiest to follow", "the most robust version"]
            }
        }

        var job: String {
            switch self {
            case .researcher:
                return "Find the key facts and best sources for the goal. At most 5 web searches; stop as soon as you can answer well. Prefer primary sources."
            case .scout:
                return "Using the research summaries, find the most practical, realistic ways to apply them to the goal: real examples, tools, costs, constraints. At most 5 web searches, only to fill gaps."
            case .builder:
                return "Using the research and scout summaries, produce the concrete deliverable the goal calls for: a step-by-step plan, a draft, or working code. Make it usable as-is. Their facts come from today's web searches, so trust sourced facts over your own memory."
            }
        }

        var summaryAsk: String {
            switch self {
            case .researcher: return "key findings, top sources, confidence, open questions"
            case .scout: return "top 3 applications ranked, why, key constraints"
            case .builder: return "what you built, key choices, known gaps"
            }
        }
    }

    struct Member {
        var role: Role
        var index: Int
        var summary = ""
        var body = ""  // full notes or draft
        var critique = ""
        var name: String { "\(role.label) \(index + 1)" }
    }

    // Wired by the controller.
    var onStage: (Tint, String) -> Void = { _, _ in }
    var onStatus: (String) -> Void = { _ in }
    var onAsk: (ClaudeRunner, String, [String: Any]) -> Void = { r, id, input in r.allow(id, input: input) }
    var onPermission: (ClaudeRunner, String, String, [String: Any]) -> Void = { r, id, _, _ in r.deny(id, message: "Not available.") }
    /// Toolbox servers this request uses (researchers, scouts, builders only), and all known servers.
    var tools: [String] = []
    var allTools: [String] = []

    private(set) var usage: [ClaudeRunner.Usage] = []
    /// One entry per call, for benchmarks: who, model, how long, tokens, searches.
    private(set) var timeline: [[String: Any]] = []
    /// Members who didn't finish ("1 of 3 researchers"): the team carries on, and the card says so.
    private(set) var shortfall: [String] = []
    private var label = ""
    private var calls: [Call] = []
    private var cancelled = false
    private let today = Solo.today()

    // MARK: - Run

    /// Runs the whole crew and returns the synthesis (same shape as Lite's answer, plus
    /// disagreements and uncertain). Saves each agent's full notes under `work`.
    func run(goal: String, members n: Int, work: URL) async throws -> [String: Any] {
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        onStage(.base, "Understanding the question")
        label = "brief"
        var brief = goal
        do {
            brief = try await call(model: "haiku", system: Self.briefPrompt, tools: "AskUserQuestion",
                                   schema: Self.briefSchema, prompt: goal, effort: "low")["brief"] as? String ?? goal
        } catch CrewError.cancelled {
            throw CrewError.cancelled  // Stop means stop, even during the brief
        } catch {
            // No brief: the goal as typed works fine.
        }

        var team: [Member] = []
        for role in Role.allCases {
            onStage(role.tint, n > 1 ? "\(n) \(role.rawValue)s \(role.verb)" : "\(role.label) \(role.verb)")
            var finished = 0
            let before = team
            let done = try await parallel((0..<n).map { i in
                { [self] () async throws -> Member? in
                    // One retry, then the team carries on without this member.
                    guard let out = try await attempt(twice: true, {
                        try await self.call(name: "\(role.rawValue) \(i + 1)", model: role.model, system: Self.agentPrompt(role, angle: n > 1 ? role.angles[i % role.angles.count] : nil, today: self.today),
                                            tools: role.tools, schema: Self.agentSchema(role),
                                            prompt: Self.agentInput(brief: brief, team: before, role: role),
                                            effort: role.effort, toolbox: true)
                    }) else { return nil }
                    finished += 1
                    if n > 1 && finished < n { self.onStatus("\(role.label)s · \(finished) of \(n) done") }
                    return Member(role: role, index: i, summary: out["summary"] as? String ?? "",
                                  body: out[role == .builder ? "draft" : "notes"] as? String ?? "")
                }
            }).compactMap { $0 }
            guard !done.isEmpty else { throw CrewError.failed("every \(role.rawValue) failed") }
            Log.crew.info("\(role.rawValue, privacy: .public)s: \(done.count) of \(n) finished")
            if done.count < n { shortfall.append("\(n - done.count) of \(n) \(role.rawValue.lowercased())\(n == 1 ? "" : "s")") }
            for m in done {
                try? m.body.write(to: work.appendingPathComponent("\(m.role.rawValue)-\(m.index + 1).md"), atomically: true, encoding: .utf8)
            }
            team += done
        }

        onStage(.evaluate, "Team critiquing each other")
        var critiqued = 0
        let critiques = try await parallel(team.indices.map { i in
            { [self] in
                let m = team[i]
                // Sonnet at low effort writes a tight critique in ~5 s; Haiku took up to a minute (benchmark).
                let out = try await attempt(twice: false, {
                    try await self.call(name: "critique: \(m.name)", model: "sonnet", system: Self.critiquePrompt, tools: "",
                                        schema: Self.critiqueSchema, prompt: Self.critiqueInput(brief: brief, team: team, me: i),
                                        effort: "low", timeout: 90)
                }) ?? [:]  // a missing critique isn't worth failing the run over
                critiqued += 1
                if critiqued < team.count { self.onStatus("Critiques · \(critiqued) of \(team.count) in") }
                return (i, out["critique"] as? String ?? "")
            }
        })
        for (i, c) in critiques { team[i].critique = c }

        // Benchmarked: Opus was ~70 s of a Standard run. Standard gets Sonnet; Deep keeps the strongest model.
        let writer = n > 1 ? "opus" : "sonnet"
        onStage(.build, n > 1 ? "Opus writing the final answer" : "Writing the final answer")
        guard let answer = try await attempt(twice: true, {
            try await self.call(name: "synth", model: writer, system: Self.synthPrompt(today: self.today), tools: "",
                                schema: Self.synthSchema, prompt: Self.synthInput(brief: brief, team: team), timeout: 360)
        }) else { throw CrewError.failed("the final answer couldn't be written") }
        return answer
    }

    func cancel() {
        cancelled = true
        for c in calls { c.cancel() }
        calls.removeAll()
    }

    /// Runs a call, optionally retrying once. Returns nil on failure; cancellation always propagates.
    private func attempt(twice: Bool, _ work: @MainActor () async throws -> [String: Any]) async throws -> [String: Any]? {
        for round in 0..<(twice ? 2 : 1) {
            do {
                return try await work()
            } catch CrewError.cancelled {
                throw CrewError.cancelled
            } catch {
                Log.crew.error("call failed (round \(round + 1)): \(String(describing: error), privacy: .public)")
                if round == 0 && twice { onStatus("Retrying a teammate") }
            }
        }
        return nil
    }

    // MARK: - Calls

    enum CrewError: Error { case failed(String), cancelled, noAnswer }

    /// One lean Claude Code call that returns structured JSON.
    private func call(name: String? = nil, model: String, system: String, tools: String, schema: String, prompt: String,
                      effort: String = "medium", toolbox: Bool = false, timeout: TimeInterval = 240) async throws -> [String: Any] {
        if cancelled { throw CrewError.cancelled }
        var args = ["-p", "--model", model, "--effort", effort, "--strict-mcp-config", "--tools", tools,
                    "--no-session-persistence", "--system-prompt", system, "--json-schema", schema,
                    "--permission-prompt-tool", "stdio", "--permission-mode", "manual", "--output-format", "stream-json", "--verbose",
                    "--input-format", "stream-json"]
        let allowed = tools.split(separator: ",").map(String.init).filter { $0 != "AskUserQuestion" }
        if !allowed.isEmpty { args += ["--allowedTools"] + allowed }  // variadic, so last
        if toolbox { args = Toolbox.apply(args, use: self.tools, all: allTools) }
        let runner = try ClaudeRunner(arguments: args)
        let c = Call(runner: runner)
        calls.append(c)
        defer { calls.removeAll { $0 === c } }
        let result: ClaudeRunner.Result = try await withCheckedThrowingContinuation { cont in
            c.continuation = cont
            runner.onEvent = { [weak self, weak runner] event in
                guard let runner else { return }
                switch event {
                case .result(let r):
                    runner.finish()
                    r.isError ? c.resume(throwing: CrewError.failed(String(r.text.prefix(160)))) : c.resume(returning: r)
                case .failed(let m):
                    c.resume(throwing: CrewError.failed(m))
                case .ask(let id, let input):
                    self?.onAsk(runner, id, input)
                case .permission(let id, let tool, let input):
                    if let self { self.onPermission(runner, id, tool, input) } else { runner.deny(id, message: "Not available.") }
                case .status(let s):
                    // "Researcher 2 · searching “M4 battery test”"
                    if let who = name, !who.hasPrefix("critique"), s != "Writing the answer" {
                        self?.onStatus(who.prefix(1).uppercased() + who.dropFirst() + " · " + s.prefix(1).lowercased() + s.dropFirst())
                    }
                default:
                    break
                }
            }
            do { try runner.start(.text(prompt)) } catch { c.resume(throwing: error) }
            // A stuck call (say, a web search that never returns) can't stall the whole team.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak runner] in
                guard c.continuation != nil else { return }
                runner?.stop()
                c.resume(throwing: CrewError.failed("timed out"))
            }
        }
        usage += result.usage
        timeline.append(["call": name ?? label, "model": model, "seconds": (result.total * 10).rounded() / 10,
                         "startup": (result.startup * 10).rounded() / 10, "firstReply": (result.firstReply * 10).rounded() / 10,
                         "apiSeconds": Double(result.apiMs / 100) / 10, "turns": result.turns, "searches": result.searches,
                         "tokens": result.tokens, "output": result.usage.reduce(0) { $0 + $1.output }])
        guard let out = Solo.output(result) else { throw CrewError.noAnswer }
        return out
    }

    /// Runs jobs at the same time and returns their results in order.
    private func parallel<T>(_ jobs: [() async throws -> T]) async throws -> [T] {
        try await withThrowingTaskGroup(of: (Int, T).self) { group in
            for (i, job) in jobs.enumerated() { group.addTask { @MainActor in (i, try await job()) } }
            var out: [(Int, T)] = []
            for try await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Resumes its continuation exactly once, even when stopped midway.
    private final class Call {
        let runner: ClaudeRunner
        var continuation: CheckedContinuation<ClaudeRunner.Result, Error>?
        init(runner: ClaudeRunner) { self.runner = runner }

        func resume(returning r: ClaudeRunner.Result) { continuation?.resume(returning: r); continuation = nil }
        func resume(throwing e: Error) { continuation?.resume(throwing: e); continuation = nil }
        func cancel() { runner.stop(); resume(throwing: CrewError.cancelled) }
    }

    // MARK: - Prompts (pure, covered by the self-check)

    static let briefPrompt = """
    You prepare a brief for a small team. \(Solo.askRule) \
    brief: the goal restated with any answers and constraints, 1 to 3 sentences.
    """
    static let briefSchema = Schema.brief

    static func agentPrompt(_ role: Role, angle: String?, today: String) -> String {
        "You are the \(role.label) on a Pix team working on one goal. Today is \(today). \(role.job)"
            + (role == .builder ? "" : " Name your sources in the summary so teammates can trust current facts.")
            + (angle.map { " Focus on \($0); teammates cover other angles." } ?? "")
            + " Return \(role == .builder ? "draft = the complete deliverable in Markdown" : "notes = full findings with numbers and source URLs")"
            + "; summary = about 200 words: \(role.summaryAsk)."
    }

    static func agentSchema(_ role: Role) -> String { Schema.member(body: role == .builder ? "draft" : "notes") }

    static func agentInput(brief: String, team: [Member], role: Role) -> String {
        var s = "Goal: \(brief)"
        if !team.isEmpty {
            s += "\n\nTeam summaries so far:\n" + team.map { "[\($0.name)]\n\($0.summary)" }.joined(separator: "\n\n")
        }
        return s
    }

    static let critiquePrompt = """
    You are on a Pix team. Read your teammates' summaries and write ONE critique under 120 words: weak spots, unsupported \
    claims, impractical ideas, and disagreements. If teammates share your role, say exactly where your answers differ. \
    Researchers and scouts searched the web today, so facts they back with a source are current even if they postdate \
    your own training; question them only when sources conflict or are missing. One round only: no replies.
    """
    static let critiqueSchema = Schema.critique

    static func critiqueInput(brief: String, team: [Member], me: Int) -> String {
        "Goal: \(brief)\n\nYou are \(team[me].name).\n\n"
            + team.enumerated().map { i, m in "[\(m.name)\(i == me ? " (you)" : "")]\n\(m.summary)" }.joined(separator: "\n\n")
    }

    static func synthPrompt(today: String) -> String {
        """
        You write the final answer for a Pix team. Today is \(today). You get the goal, every agent's summary, every critique, \
        and the builder draft(s). Produce ONE solution: start from the best draft and fix the weak spots the critiques found. \
        Researchers and scouts searched the web today: facts they back with a source are current, so use them confidently \
        even if they postdate your own training, and cite them. Doubt only facts with no source or with conflicting sources.
        """ + "\n" + Solo.explainRules() + """

        disagreements: each main disagreement and, in one line, how you resolved it. uncertain: what nobody could confirm and how to check it.
        """
    }

    static let synthSchema = Schema.teamAnswer

    static func synthInput(brief: String, team: [Member]) -> String {
        var s = "Goal: \(brief)\n\n## Summaries\n" + team.map { "[\($0.name)]\n\($0.summary)" }.joined(separator: "\n\n")
        s += "\n\n## Critiques\n" + team.map { "[\($0.name)]\n\($0.critique)" }.joined(separator: "\n\n")
        for b in team where b.role == .builder { s += "\n\n## Draft from \(b.name)\n\(b.body)" }
        return s
    }
}

/// What a team costs, learned from your own runs (starting from the benchmark): how long it takes,
/// and how much of your Claude limit it uses, counted in quick answers.
enum TeamCost {
    /// Benchmark starting points (bench/BENCHMARK.md): seconds and API-equivalent dollars.
    static let start: [Mode: (seconds: Double, cost: Double)] = [.lite: (12, 0.02), .standard: (153, 0.35), .deep: (328, 1.02)]

    /// Agents that work on the question: one per role (or two in Deep) plus the writer.
    static func agents(_ mode: Mode, members: Int = 2) -> Int { mode == .deep ? 3 * members + 1 : mode == .standard ? 4 : 1 }

    static func estimate(_ mode: Mode, in d: UserDefaults = .standard) -> (seconds: Double, cost: Double) {
        let s = start[mode] ?? (12, 0.02)
        return (d.object(forKey: "cost.\(mode.rawValue).s") as? Double ?? s.seconds, d.object(forKey: "cost.\(mode.rawValue).c") as? Double ?? s.cost)
    }

    /// Folds a finished run in (a moving average, so recent runs count most).
    static func record(_ mode: Mode, seconds: Double, cost: Double, in d: UserDefaults = .standard) {
        guard seconds > 0, cost > 0 else { return }
        let e = estimate(mode, in: d)
        d.set(e.seconds * 0.7 + seconds * 0.3, forKey: "cost.\(mode.rawValue).s")
        d.set(e.cost * 0.7 + cost * 0.3, forKey: "cost.\(mode.rawValue).c")
    }

    /// "about 2½ min"
    static func minutes(_ seconds: Double) -> String {
        let halves = max(1, (seconds / 30).rounded())
        let whole = Int(halves) / 2
        return "about " + (whole == 0 ? "½" : "\(whole)" + (Int(halves) % 2 == 1 ? "½" : "")) + " min"
    }

    /// "4 agents · about 2½ min · about 18 quick answers' worth"
    static func hint(_ mode: Mode, members: Int = 2, in d: UserDefaults = .standard) -> String {
        let e = estimate(mode, in: d), lite = estimate(.lite, in: d)
        let worth = max(2, Int((e.cost / max(lite.cost, 0.001)).rounded()))
        return "\(agents(mode, members: members)) agents · \(minutes(e.seconds)) · about \(worth) quick answers' worth"
    }
}
