import AppKit

/// One-click updates from GitHub Releases. Off until a repo is set (Info.plist PixUpdateRepo, e.g.
/// "LED-esma/pix"): then Pix checks once a day, and Update downloads the release's DMG, makes sure
/// the new Pix is signed by the same developer team as this one, swaps it in and relaunches.
/// Feedback: a new GitHub issue on Pix's repo, filled in with what helps sort a report (Pix's version,
/// macOS, which AI) and nothing personal. Hidden until a repo is set (PixUpdateRepo).
enum Feedback {
    nonisolated static var available: Bool { !Updater.repo.isEmpty }

    nonisolated static func body(ai: String) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "**What happened**\n\n\n**What you expected**\n\n\n---\nPix \(Updater.current) (\(build)) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            + (ai.isEmpty ? "" : " · \(ai)") + (Auto.on ? " · Auto Mode" : "")
    }

    nonisolated static func issue(ai: String, repo: String = Updater.repo) -> URL? {
        guard !repo.isEmpty else { return nil }
        var c = URLComponents(string: "https://github.com/\(repo)/issues/new")!
        c.queryItems = [URLQueryItem(name: "body", value: body(ai: ai))]
        return c.url
    }
}

@MainActor
enum Updater {
    struct Release: Equatable { var version: String; var dmg: URL }

    nonisolated static var repo: String { (Bundle.main.object(forInfoDictionaryKey: "PixUpdateRepo") as? String ?? "").trimmingCharacters(in: .whitespaces) }
    nonisolated static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// "0.10.0" is newer than "0.9.2"; a leading "v" is fine.
    nonisolated static func newer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Once a day (or now, from Settings). Sets model.update when there's a newer version.
    static func check(_ model: PixModel, force: Bool = false) async {
        guard !repo.isEmpty else { return }
        let d = UserDefaults.standard
        if !force, let last = d.object(forKey: "update.checked") as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        d.set(Date(), forKey: "update.checked")
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest"),
              let (data, resp) = try? await URLSession.shared.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = j["tag_name"] as? String, newer(tag, than: current),
              let dmg = (j["assets"] as? [[String: Any]] ?? []).compactMap({ $0["browser_download_url"] as? String }).first(where: { $0.hasSuffix(".dmg") }),
              let dmgURL = URL(string: dmg) else { return }
        model.update = Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), dmg: dmgURL)
    }

    /// The developer team that signed an app ("7MX978TCBY"), or nil if it isn't validly signed.
    nonisolated static func team(of app: String) -> String? {
        guard BuiltIn.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app], timeout: 60) != nil else { return nil }
        let p = Process(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-dv", app]
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let out = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) }
    }

    /// Updates install by themselves (downloaded and checked in the background, swapped in while Pix is
    /// idle). Off in Settings: Pix then says a new version is out and waits for Update.
    nonisolated static var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "update.auto") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "update.auto") }
    }

    nonisolated static func notes(_ version: String) -> URL? {
        repo.isEmpty ? nil : URL(string: "https://github.com/\(repo)/releases/tag/v\(version)")
    }

    /// Downloads the release and checks it's signed by the same developer as this Pix. Returns the
    /// ready-to-swap app, or what went wrong. Kept in ~/Pix/work so a ready update survives a relaunch.
    static func prepare(_ r: Release, model: PixModel) async -> Result<String, UpdateProblem> {
        model.updating = true
        defer { model.updating = false }
        let fm = FileManager.default
        let work = PixPaths.home.appendingPathComponent("work/update-\(r.version)")
        let staged = work.appendingPathComponent("Pix.app").path
        if fm.fileExists(atPath: staged), let mine = team(of: Bundle.main.bundlePath), team(of: staged) == mine { return .success(staged) }
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        guard let (tmp, resp) = try? await URLSession.shared.download(from: r.dmg), (resp as? HTTPURLResponse)?.statusCode == 200 else {
            return .failure(.init("The update didn't download."))
        }
        let dmg = work.appendingPathComponent("Pix.dmg")
        try? fm.moveItem(at: tmp, to: dmg)
        let mount = work.appendingPathComponent("mount").path
        guard BuiltIn.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount], timeout: 120) != nil else {
            return .failure(.init("The update wouldn't open."))
        }
        _ = BuiltIn.run("/usr/bin/ditto", ["\(mount)/Pix.app", staged], timeout: 300)
        _ = BuiltIn.run("/usr/bin/hdiutil", ["detach", mount, "-quiet"], timeout: 60)
        try? fm.removeItem(at: dmg)
        // Only an app signed by the same developer as this one replaces it.
        guard let mine = team(of: Bundle.main.bundlePath), let theirs = team(of: staged), mine == theirs else {
            try? fm.removeItem(at: work)
            return .failure(.init("The update isn't signed by Pix's developer, so it wasn't installed."))
        }
        return .success(staged)
    }

    /// The swap, run after Pix quits: the old app is kept until the new one is in place, and comes back
    /// if anything fails, so a failed update never leaves you without Pix.
    nonisolated static func swapScript(staged: String, target: String, pid: Int32, work: String, relaunch: Bool = true) -> String {
        """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        T="\(target)"
        rm -rf "$T.new" "$T.old"
        if /usr/bin/ditto "\(staged)" "$T.new" && mv "$T" "$T.old" && mv "$T.new" "$T"; then rm -rf "$T.old" "\(work)"
        else [ -d "$T.old" ] && [ ! -d "$T" ] && mv "$T.old" "$T"; rm -rf "$T.new"; fi
        \(relaunch ? "open \"$T\"" : "")
        """
    }

    /// Quits and swaps in the ready update; the new Pix says "Updated to …" once.
    static func apply(staged: String, version: String) {
        UserDefaults.standard.set(version, forKey: "update.installed")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", swapScript(staged: staged, target: Bundle.main.bundlePath, pid: ProcessInfo.processInfo.processIdentifier,
                                        work: (staged as NSString).deletingLastPathComponent)]
        guard (try? p.run()) != nil else { UserDefaults.standard.removeObject(forKey: "update.installed"); return }
        NSApp.terminate(nil)
    }

    /// Update now (the menu, Settings, the card): download if needed, then swap. Returns what went wrong.
    static func install(_ r: Release, model: PixModel) async -> String? {
        switch await prepare(r, model: model) {
        case .success(let staged): apply(staged: staged, version: r.version); return nil
        case .failure(let p): return p.message
        }
    }
}

struct UpdateProblem: Error { let message: String; init(_ m: String) { message = m } }

extension PixController {
    /// Checks daily while Pix runs (it opens at login and stays up for days), gets a new version ready in
    /// the background, and swaps it in when Pix is idle. With automatic updates off, it says a new
    /// version is out instead: the blob peeks out once, and the card offers Update.
    func startUpdateWatch() {
        let d = UserDefaults.standard
        if let v = d.string(forKey: "update.installed") {
            if v == Updater.current { model.justUpdated = v }
            d.removeObject(forKey: "update.installed")
        }
        updateTick()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTick() }
        }
    }

    func updateTick() {
        Task { @MainActor in
            let had = model.update
            await Updater.check(model)
            guard let r = model.update else { return }
            guard Updater.automatic else {
                if had == nil, !bubbleOpen { slide(.peek) { [weak self] in DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self?.slideHome() } } }
                return
            }
            if model.updateReady == nil, !model.updating {
                let failed = UserDefaults.standard.object(forKey: "update.failed") as? Date
                guard failed.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true else { return }
                switch await Updater.prepare(r, model: model) {
                case .success(let staged): model.updateReady = staged
                case .failure(let p):
                    Log.app.error("update: \(p.message, privacy: .public)")
                    UserDefaults.standard.set(Date(), forKey: "update.failed")
                }
            }
            if let staged = model.updateReady, quietForUpdate { Updater.apply(staged: staged, version: r.version) }
        }
    }

    /// Nobody's using Pix: nothing running, the card closed, no timer about to ring, untouched for 5 minutes.
    var quietForUpdate: Bool {
        guard case .idle = model.phase, !bubbleOpen, runner == nil, !model.listening else { return false }
        return Date().timeIntervalSince(lastActivity) > 300 && model.timers.allSatisfy { $0.at.timeIntervalSinceNow > 120 }
    }

    /// The card's Update / Restart to Update.
    func updateNow() {
        guard let r = model.update else { return }
        if let staged = model.updateReady { Updater.apply(staged: staged, version: r.version); return }
        Task { @MainActor in _ = await Updater.install(r, model: model) }
    }
}
