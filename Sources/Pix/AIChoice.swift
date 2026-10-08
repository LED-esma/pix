import Foundation

/// The "Pick your AI" step on a new Mac: each AI this Mac can use, in plain words (what it's best at,
/// what it costs, where your words go, how fast), with the best one already picked: Claude when
/// you're signed in, then the built-in AI, then a model on this Mac, then an AI you added.
struct AIChoice: Identifiable, Equatable {
    var provider: Provider
    var title: String
    var bestAt: String
    var cost: String
    var privacy: String
    var speed: String
    var ready = true       // Claude needs a sign-in (or Claude Code) first
    var badge: String?     // what it needs first, in plain words
    var id: String { provider.key }

    /// The four facts for an AI, as one line each choice shows.
    static func describe(_ p: Provider, claudeReady: Bool = true, claudeInstalled: Bool = true) -> AIChoice {
        switch p {
        case .claude:
            return AIChoice(provider: p, title: "Claude", bestAt: "Best at doing things in your apps and on the web",
                            cost: "Your plan", privacy: "Sent to Anthropic", speed: "Seconds", ready: claudeReady,
                            badge: claudeReady ? nil : claudeInstalled ? "Needs sign-in" : "Pix sets it up")
        case .local(let m) where m == AppleModel.id:
            return AIChoice(provider: p, title: "Built-in", bestAt: "Quick questions, explaining, reminders and timers",
                            cost: "Free", privacy: "Stays on this Mac", speed: "Instant")
        case .local(let m):
            return AIChoice(provider: p, title: "This Mac · \(Ollama.shortName(m))", bestAt: "Answers and explains; slower at long tasks",
                            cost: "Free", privacy: "Stays on this Mac", speed: FreeAI.isIntel ? "Slow on this Mac" : "5 to 20 seconds")
        case .cloud:
            return AIChoice(provider: p, title: "Ollama Cloud", bestAt: "Big open models",
                            cost: "Free tier", privacy: "Sent to Ollama", speed: "Seconds")
        case .service:
            return AIChoice(provider: p, title: p.serviceName, bestAt: "Answers, explaining and the web",
                            cost: "Your account", privacy: "Sent to \(p.serviceName)", speed: "Seconds")
        case .gateway:
            return AIChoice(provider: p, title: p.short, bestAt: "The models your gateway routes to",
                            cost: "Your gateway", privacy: "Sent via your gateway", speed: "Seconds")
        }
    }

    /// What this Mac can use, best first. Claude is always offered: signed in, or one step away.
    static func available(claudeReady: Bool, claudeInstalled: Bool = true, apple: Bool, local: [String], services: [Provider]) -> [AIChoice] {
        var out = [describe(.claude, claudeReady: claudeReady, claudeInstalled: claudeInstalled)]
        if apple { out.append(describe(.local(model: AppleModel.id))) }
        if let m = local.first(where: { $0 != AppleModel.id }) { out.append(describe(.local(model: m))) }
        out += services.prefix(2).map { describe($0) }
        return out
    }

    /// The one picked to start with: Claude when it's ready, else the first free one, else Claude (to set up).
    static func preselect(_ choices: [AIChoice]) -> AIChoice? {
        if let c = choices.first(where: { $0.provider.isClaude && $0.ready }) { return c }
        return choices.first(where: { !$0.provider.isClaude }) ?? choices.first
    }
}

extension PixController {
    /// First open: pick an AI before the welcome card.
    func showPickAI() {
        let choices = AIChoice.available(claudeReady: claudeReady, claudeInstalled: ClaudeRunner.claudeURL() != nil,
                                         apple: AppleModel.available, local: Ollama.installed(),
                                         services: Services.ready.map { .service(id: $0.id, model: $0.model) })
        model.aiChoices = choices
        model.aiPicked = AIChoice.preselect(choices)?.provider
        model.pickingAI = true
        openBubble()
    }

    /// Continue: use the picked AI and go on to the welcome card. Claude that isn't ready yet goes to its
    /// setup (install or sign in) first, and Pix stays on it rather than switching to a free AI.
    func confirmPickAI() {
        guard let p = model.aiPicked else { return }
        model.pickingAI = false
        model.welcome = true
        if p.isClaude, !claudeReady {
            model.wantsClaude = true
            model.provider = .claude
            Task { @MainActor in
                let r = await ClaudeRunner.readiness()
                model.phase = .setup(r, waiting: false)
                setUp()
            }
            return
        }
        use(p)
        openBubble()
    }
}
