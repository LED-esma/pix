import AppKit
import ApplicationServices

/// The project you're working on: when Pix is called over a terminal or code editor, it finds that
/// window's folder, walks up to the project root, and takes a quick look (git state, top-level
/// files, the terminal's last lines). Questions then carry that, and Pix can read the project's
/// files itself (read-only, inside that folder).
struct Project: Equatable {
    var root: URL
    var app: String               // "Terminal", "Cursor"…
    var isTerminal: Bool
    var branch = ""
    var changes: [String] = []    // `git status --short`
    var commits: [String] = []    // `git log --oneline`
    var diff = ""                 // `git diff HEAD`, first 4,000 characters (sent only when asked about changes)
    var behind = 0                // commits the branch is behind its upstream (as of the last fetch)
    var files: [String] = []      // top level
    var terminalTail = ""         // the terminal's last lines, when it's a terminal
    /// Read straight from a terminal or editor window (sure), or guessed from a coding app's
    /// sessions (a suggestion you tap to include). Other projects found there, to switch to.
    var confident = true
    var others: [URL] = []

    var name: String { root.lastPathComponent }

    /// What the question carries about the project.
    var context: String {
        var s = "The user called you from \(app), working on the project \"\(name)\" at \(root.path)."
        if !branch.isEmpty { s += "\nGit branch: \(branch)." }
        if behind > 0 { s += " It's \(behind) commit\(behind == 1 ? "" : "s") behind its upstream (as of the last fetch): before calling something a new bug, consider that it may already be fixed there." }
        if !changes.isEmpty { s += "\nUncommitted changes:\n" + changes.joined(separator: "\n") }
        if !commits.isEmpty { s += "\nRecent commits:\n" + commits.joined(separator: "\n") }
        if !files.isEmpty { s += "\nTop level: " + files.joined(separator: ", ") }
        if !terminalTail.isEmpty { s += "\nTheir terminal's last lines:\n```\n\(terminalTail)\n```" }
        s += "\nWhen the question is about this project, read its files with Read, Glob and Grep (start with CLAUDE.md or README if there is one) instead of guessing. If what they want is unclear, ask up to 2 short questions with AskUserQuestion."
        return s
    }

    /// The context, plus the uncommitted diff when the question is about changes (a commit message, a review):
    /// models without a shell otherwise guess what changed. Left out otherwise, to keep runs cheap.
    func context(for goal: String) -> String {
        let g = goal.lowercased()
        guard !diff.isEmpty, ["commit", "diff", "change", "review", "what did i", "staged", "pr ", "pull request"].contains(where: g.contains) else { return context }
        return context + "\nThe uncommitted diff:\n```diff\n\(diff)\n```"
    }

    /// One-tap questions that fit what Pix sees, shown while the field is empty.
    var suggestions: [String] {
        var out: [String] = []
        let tail = terminalTail.lowercased()
        if ["error", "failed", "fatal", "exception", "traceback", "panic", "not found"].contains(where: tail.contains) { out.append("Explain this error") }
        if !changes.isEmpty { out.append("Review my changes") }
        out.append("What does \(name) do?")
        if out.count < 3, !commits.isEmpty { out.append("What changed recently?") }
        return Array(out.prefix(3))
    }

    // MARK: - Finding it

    static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                                         "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty", "com.github.wez.wezterm"]
    static let editors: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.google.antigravity",
                                       "com.apple.dt.Xcode", "dev.zed.Zed", "com.sublimetext.4", "com.exafunction.windsurf", "com.panic.Nova",
                                       "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.WebStorm", "com.jetbrains.CLion", "com.google.android.studio"]

    /// Apps that run coding sessions or terminals inside them (Claude's desktop app).
    static let hosts: Set<String> = ["com.anthropic.claudefordesktop", "com.openai.codex"]

    /// The project behind the app you were just in, if it's a terminal, editor, or coding app.
    static func detect(_ app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> Project? {
        guard let app, let id = app.bundleIdentifier, terminals.contains(id) || editors.contains(id) || hosts.contains(id) else { return nil }
        let isTerminal = terminals.contains(id)
        var folders: [URL], confident = true
        if let f = windowFolder(app) ?? (isTerminal ? terminalFolder(id) : nil) { folders = [f] }
        else { folders = sessionFolders(app); confident = false }
        var roots: [URL] = []
        for f in folders { if let r = root(from: f), !roots.contains(where: { $0.path == r.path }) { roots.append(r) } }
        guard let first = roots.first else { return nil }
        var p = Project(root: first, app: app.localizedName ?? "your editor", isTerminal: isTerminal)
        p.confident = confident
        p.others = Array(roots.dropFirst().prefix(5))
        p.look(terminal: isTerminal ? id : nil)
        return p
    }

    /// Most terminals and editors tell macOS which file or folder a window shows (its title-bar icon);
    /// Accessibility reads it. Terminal reports the shell's current folder this way.
    static func windowFolder(_ app: NSRunningApplication) -> URL? {
        guard AXIsProcessTrusted() else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success, let win else { return nil }
        var doc: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, kAXDocumentAttribute as CFString, &doc) == .success,
              let s = doc as? String, let url = URL(string: s), url.isFileURL else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        return isDir.boolValue ? url : url.deletingLastPathComponent()
    }

    /// Terminal and iTerm without Accessibility: the front tab's tty → its shell → that shell's folder.
    static func terminalFolder(_ id: String) -> URL? {
        let script = id == "com.googlecode.iterm2"
            ? "tell application \"iTerm2\" to tty of current session of current window"
            : "tell application \"Terminal\" to tty of selected tab of front window"
        guard id == "com.apple.Terminal" || id == "com.googlecode.iterm2",
              let tty = BuiltIn.osascript(script), !tty.isEmpty,
              let ps = BuiltIn.run("/bin/ps", ["-t", tty.replacingOccurrences(of: "/dev/", with: ""), "-o", "pid=,stat="]) else { return nil }
        // The foreground process group (stat has "+"); the last one is the newest.
        var pid: String?
        for row in ps.split(separator: "\n") {
            let cols = row.split(separator: " ", omittingEmptySubsequences: true)
            if cols.count >= 2 && cols[1].contains("+") { pid = String(cols[0]) }
        }
        guard let pid, let out = BuiltIn.run("/usr/sbin/lsof", ["-a", "-p", pid, "-d", "cwd", "-Fn"]),
              let line = out.split(separator: "\n").first(where: { $0.hasPrefix("n") }) else { return nil }
        return URL(fileURLWithPath: String(line.dropFirst()))
    }

    /// Folders of the shells and Claude Code sessions an app started, the one you used most recently
    /// first (by its Claude Code transcript), for Claude's desktop app and terminals that don't report
    /// their folder (Warp, kitty, Alacritty).
    static func sessionFolders(_ app: NSRunningApplication) -> [URL] {
        guard let ps = BuiltIn.run("/bin/ps", ["-axo", "pid=,ppid=,comm="], timeout: 3) else { return [] }
        var children: [Int32: [Int32]] = [:], names: [Int32: String] = [:]
        for row in ps.split(separator: "\n") {
            let cols = row.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard cols.count == 3, let pid = Int32(cols[0]), let ppid = Int32(cols[1]) else { continue }
            children[ppid, default: []].append(pid)
            names[pid] = (String(cols[2]) as NSString).lastPathComponent
        }
        let wanted: Set<String> = ["zsh", "bash", "fish", "sh", "nu", "claude", "-zsh", "-bash"]
        var queue = [app.processIdentifier], found: [Int32] = []
        while let pid = queue.popLast(), found.count < 40 {
            for c in children[pid] ?? [] {
                queue.append(c)
                if wanted.contains(names[c] ?? "") { found.append(c) }
            }
        }
        guard !found.isEmpty, let out = BuiltIn.run("/usr/sbin/lsof", ["-a", "-p", found.map(String.init).joined(separator: ","), "-d", "cwd", "-Fpn"], timeout: 5) else { return [] }
        let home = NSHomeDirectory(), skip: Set<String> = [home, home + "/Pix", "/"]
        var seen: [String: Int32] = [:]  // folder → newest pid
        var pid: Int32 = 0
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
            if line.hasPrefix("n") {
                let path = String(line.dropFirst())
                if !skip.contains(path), path.hasPrefix(home + "/") { seen[path] = max(seen[path] ?? 0, pid) }
            }
        }
        let used = { (path: String) -> Date in lastUsed(path) ?? .distantPast }
        return seen.keys.sorted { a, b in
            let (ua, ub) = (used(a), used(b))
            return ua != ub ? ua > ub : (seen[a] ?? 0) > (seen[b] ?? 0)
        }.map { URL(fileURLWithPath: $0) }
    }

    /// When a Claude Code session in `folder` last wrote to its transcript (~/.claude/projects/<folder with - for / and .>).
    static func lastUsed(_ folder: String) -> Date? {
        let name = folder.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects/\(name)")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "jsonl" }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    static let markers = [".git", "Package.swift", "project.yml", "package.json", "pyproject.toml", "Cargo.toml", "go.mod",
                          "build.gradle", "build.gradle.kts", "pom.xml", "CLAUDE.md", "Makefile", "requirements.txt", "Gemfile"]

    /// The nearest folder up from `folder` that looks like a project root; else the folder itself.
    /// Never your whole home folder.
    static func root(from folder: URL) -> URL? {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        var dir = folder.standardizedFileURL
        let fm = FileManager.default
        while dir.path.hasPrefix(home + "/") {
            if markers.contains(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) })
                || ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).contains(where: { $0.hasSuffix(".xcodeproj") }) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        let f = folder.standardizedFileURL
        return f.path.hasPrefix(home + "/") ? f : nil
    }

    /// A quick, local look: no model, no tokens.
    mutating func look(terminal: String? = nil) {
        let git = "/usr/bin/git"
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
            branch = BuiltIn.run(git, ["-C", root.path, "rev-parse", "--abbrev-ref", "HEAD"], timeout: 3) ?? ""
            changes = Array((BuiltIn.run(git, ["-C", root.path, "status", "--short"], timeout: 3) ?? "").split(separator: "\n").prefix(15).map(String.init))
            commits = Array((BuiltIn.run(git, ["-C", root.path, "log", "--oneline", "-5"], timeout: 3) ?? "").split(separator: "\n").map(String.init))
            if !changes.isEmpty { diff = String((BuiltIn.run(git, ["-C", root.path, "diff", "HEAD"], timeout: 3) ?? "").prefix(4000)) }
            behind = Int(BuiltIn.run(git, ["-C", root.path, "rev-list", "--count", "HEAD..@{upstream}"], timeout: 3) ?? "") ?? 0
        }
        let skip: Set<String> = ["node_modules", "build", "dist", "DerivedData", ".build", "__pycache__", "venv", ".venv"]
        files = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") && !skip.contains($0) }.sorted().prefix(40).map { $0 }
        if let terminal { terminalTail = Self.tail(terminal) }
    }

    /// The front terminal tab's last lines (Terminal and iTerm can say; others can't).
    static func tail(_ id: String, lines: Int = 40) -> String {
        let script: String
        switch id {
        case "com.apple.Terminal": script = "tell application \"Terminal\" to history of selected tab of front window"
        case "com.googlecode.iterm2": script = "tell application \"iTerm2\" to contents of current session of current window"
        default: return ""
        }
        guard let text = BuiltIn.osascript(script) else { return "" }
        let clean = text.replacingOccurrences(of: #"\u001B\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
        let rows = clean.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        var end = rows.count
        while end > 0 && rows[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return rows[max(0, end - lines)..<end].map { String($0.prefix(240)) }.joined(separator: "\n")
    }
}
