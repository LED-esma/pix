import AppKit

/// Did a free model really do what it was asked? Small models answer from memory, or say "Done!",
/// without touching a tool, and present it as real (a stress test caught qwen3 inventing today's
/// weather). One policy, used by the app and by headless runs alike: accept the answer, nudge the
/// model once ("look it up first"), or hand the question to Claude.
enum Judge {
    enum Verdict: Equatable {
        case accept
        case nudge(String)     // ask again once, with this said first
        case handOff(String)   // why, for the card ("it needed the web")
    }

    static let webTools = ["web_search", "web_read", "browser_tab", "browser_go", "browser_look", "WebSearch", "WebFetch"]

    /// Words that mean the answer depends on what's true right now, or on a page.
    static func needsWeb(_ goal: String) -> Bool {
        let g = goal.lowercased()
        if g.range(of: #"https?://|www\.|\b[a-z0-9-]+\.(com|org|net|edu|io|gov|co)\b"#, options: .regularExpression) != nil { return true }
        return ["weather", "forecast", "temperature", "today", "tonight", "right now", "currently", "latest", "news", "price", "cost",
                "deal", "on sale", "score", "who won", "stock", "this week", "open now", "hours", "release date", "traffic", "election"]
            .contains { g.contains($0) }
    }

    /// A question about what's in the user's own Reminders, Calendar, Notes or Music, which only Pix's tools can see.
    static func asksAboutMac(_ goal: String) -> Bool {
        let g = " " + goal.lowercased() + " "
        return ["calendar", "reminder", "my notes", " note ", " notes ", "playing", "this song", "music", "my schedule", "my day",
                "meetings", "events"].contains { g.contains($0) }
    }

    static var savedTool: (String) -> Bool = { Routines.match($0) != nil }

    /// Asked to show or do something in an app on screen ("show me how to…", "do it for me", "in Calculator…").
    static func asksScreen(_ goal: String, apps: [String] = runningApps()) -> Bool {
        let g = " " + goal.lowercased() + " "
        if ["show me how", "do it for me", "for me:", " click ", "where is the", "where do i"].contains(where: { g.contains($0) }) { return true }
        let inApp = apps.contains { g.contains(" in \($0.lowercased()) ") || g.contains(" in \($0.lowercased()),") || g.contains(" in \($0.lowercased()):") }
        return inApp && ["how do i", "how to", "turn on", "turn off", "change", "set ", "open ", "do ", "make ", "work out", "find "].contains { g.contains($0) }
    }

    /// "on citycollege.edu", "github.com", "their website": about a site, not a Mac app.
    static func namesSite(_ goal: String) -> Bool {
        let g = goal.lowercased()
        return g.range(of: #"\b[a-z0-9-]+\.(com|edu|org|net|gov|io|dev|app|co|us|ai)\b"#, options: .regularExpression) != nil
            || ["website", " site", "web page", "webpage", "online"].contains { g.contains($0) }
    }

    static func runningApps() -> [String] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
    }

    /// A question about the project's code, which only reading its files can answer honestly.
    static func asksAboutCode(_ goal: String) -> Bool {
        let g = goal.lowercased()
        return ["which file", "what file", "where is", "where's", "where does", "how does", "function", "class ", "method", "code",
                "bug", "error", "implement", "defined", "line "].contains { g.contains($0) }
    }

    static func verdict(goal: String, claude: Bool, toolsCalled: [String], apps: [String], nudged: Bool, project: Bool = false) -> Verdict {
        guard !claude else { return .accept }  // Claude follows its tools reliably; this is for everyone else
        let short = toolsCalled.map { $0.replacingOccurrences(of: BuiltIn.prefix, with: "") }
        let usedApp = apps.contains { app in toolsCalled.contains { $0.hasPrefix(Toolbox.prefix(app) + "__") } }
        let usedPix = toolsCalled.contains { $0.hasPrefix(BuiltIn.prefix) && !$0.hasSuffix("remember") }
        let usedWeb = short.contains { t in webTools.contains(t) }
        if let app = apps.first, !usedApp {
            return nudged ? .handOff("it didn't check \(Toolbox.label(app))")
                          : .nudge("Answer this with the user's \(Toolbox.label(app)) tools: call the most direct one first, then answer only from what it returns.")
        }
        // Running a saved tool is doing something, even when its name doesn't sound like a command.
        let usedWork = toolsCalled.contains { $0.hasPrefix(BuiltIn.prefix) && !$0.hasSuffix("remember") && !$0.contains("__use_") && !$0.hasSuffix("tools_list") }
        if savedTool(goal), !usedWork {
            return nudged ? .handOff("it didn't run the tool")
                          : .nudge("This runs the user's saved tool: do its steps now by calling the tools they name (shell_run, applescript_run, reminder_add…). Never report a result no tool gave you.")
        }
        // A website: Pix's browser (or the user's, through screen_*) both show the way.
        if asksScreen(goal), namesSite(goal), !short.contains(where: { $0.hasPrefix("screen_") || $0.hasPrefix("browser_") }) {
            return nudged ? .handOff("it didn't open the site")
                          : .nudge("Open the site with browser_go, find the way with browser_look and browser_click, then tell the user each click in order (the link names exactly as on the page). Don't just describe it from memory.")
        }
        if asksScreen(goal), !namesSite(goal), !short.contains(where: { $0.hasPrefix("screen_") }) {
            let g = " " + goal.lowercased() + " "
            let app = runningApps().first { g.contains(" in \($0.lowercased()) ") || g.contains(" \($0.lowercased()) app") }
            let first = app.map { "Call screen_look with app \"\($0)\" right now" } ?? "Call screen_look right now"
            return nudged ? .handOff("it didn't use the app")
                          : .nudge("\(first), then do it with screen_click (add then: [more numbers] to press several) / screen_type / screen_key, or show each step with screen_show. Don't just describe the steps.")
        }
        // Organizing files means files really moved: a listing (or a failed command) isn't it.
        // As a verb: "organize my Downloads", not "what does Organizer.family do".
        let organizing = goal.lowercased().range(of: #"\borgani[sz]e\b|\bsort\s|\btidy\b|clean up|move (my|the|all)|put all|file them|into folders"#,
                                                 options: .regularExpression) != nil
        if organizing, !short.contains(where: { ["files_move", "files_organize", "shell_run", "applescript_run", "files_trash"].contains($0) }) {
            return nudged ? .handOff("it didn't move anything")
                          : .nudge("Call files_organize with the folder's path (by subject unless they said otherwise) and report what it returns. Don't say it's organized unless it moved them.")
        }
        if BuiltIn.actionAsked(goal), !usedPix {
            return nudged ? .handOff("it didn't actually do it")
                          : .nudge("Do this with your tools now (timer_start, reminder_add, event_add, schedule_add, browser_go…). Never say it's done unless a tool did it.")
        }
        if asksAboutMac(goal), !usedPix {
            return nudged ? .handOff("it didn't check your Mac")
                          : .nudge("This is about the user's own Reminders, Calendar, Notes or Music: call the matching tool first (reminders_list, events_list, notes_search, music with now_playing), then answer only from what it returns. Never guess.")
        }
        let readFiles = short.contains { ["Read", "Glob", "Grep", "file_read", "files_find"].contains($0) }
        if project, asksAboutCode(goal), !readFiles {
            return nudged ? .handOff("it didn't look at the project's files")
                          : .nudge("Look in the project's files first (Glob to find them, Grep to search, Read to open), then answer only from what you find. Never name a file you haven't seen.")
        }
        if needsWeb(goal), !usedWeb, !usedApp {  // "what's due this week?" answered from Canvas needs no web
            return nudged ? .handOff("it needed the web")
                          : .nudge("This needs current information or a page's contents: call web_search (or web_read for a link) first, then answer only from what it returns. Don't answer from memory.")
        }
        return .accept
    }
}
