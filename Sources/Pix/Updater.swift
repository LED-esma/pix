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

    /// Download, check the signature, swap, relaunch. Returns what went wrong, or nil (Pix quits to relaunch).
    static func install(_ r: Release, model: PixModel) async -> String? {
        model.updating = true
        defer { model.updating = false }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pix-update-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        guard let (tmp, resp) = try? await URLSession.shared.download(from: r.dmg), (resp as? HTTPURLResponse)?.statusCode == 200 else {
            return "The update didn't download."
        }
        let dmg = work.appendingPathComponent("Pix.dmg")
        try? FileManager.default.moveItem(at: tmp, to: dmg)
        let mount = work.appendingPathComponent("mount").path
        guard BuiltIn.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount], timeout: 120) != nil else {
            return "The update wouldn't open."
        }
        let staged = work.appendingPathComponent("Pix.app").path
        _ = BuiltIn.run("/usr/bin/ditto", ["\(mount)/Pix.app", staged], timeout: 300)
        _ = BuiltIn.run("/usr/bin/hdiutil", ["detach", mount, "-quiet"], timeout: 60)
        // Only an app signed by the same developer as this one replaces it.
        guard let mine = team(of: Bundle.main.bundlePath), let theirs = team(of: staged), mine == theirs else {
            return "The update isn't signed by Pix's developer, so it wasn't installed."
        }
        let target = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        /usr/bin/ditto "\(staged)" "\(target).new" && rm -rf "\(target)" && mv "\(target).new" "\(target)" && open "\(target)"
        rm -rf "\(work.path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        guard (try? p.run()) != nil else { return "The update couldn't start." }
        NSApp.terminate(nil)
        return nil
    }
}
