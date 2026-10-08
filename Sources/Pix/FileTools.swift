import AppKit
import PDFKit

/// Real hands for files, so a model never has to write shell commands to move things around (a small
/// model's one-line `mkdir && mv *.md … && mv *.pdf …` stops at the first type it doesn't have and then
/// says it's done). Every change is one batch with one Undo, nothing is ever overwritten, and each tool
/// reports exactly what happened. Runs in the tools' process (Pix --mcp).
enum FileTools {
    typealias Reply = (text: String, error: Bool)
    static func ok(_ s: String) -> Reply { (s, false) }
    static func fail(_ s: String) -> Reply { (s, true) }

    /// A path in the user's home folder ("~/Downloads", "Downloads/Math", "/Users/…"), or nil.
    static func url(_ path: String, base: URL? = nil) -> URL? {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        var u: URL
        if p.hasPrefix("~") || p.hasPrefix("/") { u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        else if let base { u = base.appendingPathComponent(p) }
        else { u = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(p) }
        u = u.standardizedFileURL
        return u.path.hasPrefix(NSHomeDirectory() + "/") ? u : nil
    }

    /// Never moved or trashed, Undo or not: the folders right in your home folder (Documents, Desktop,
    /// a project like ~/obsidian), anything in Library, and hidden folders (.ssh, .config).
    static func guarded(_ u: URL) -> Bool {
        let home = NSHomeDirectory(), p = u.standardizedFileURL.path
        guard p.hasPrefix(home + "/") else { return true }
        let parts = p.dropFirst(home.count + 1).split(separator: "/")
        if parts.first == "Library" || parts.contains(where: { $0.hasPrefix(".") }) { return true }
        let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        return parts.count == 1 && isDir
    }

    /// A folder's total size, so "what's taking up space" can be answered from one listing. Gives up
    /// (nil) past 20,000 files or half a second, rather than stall on a huge folder.
    static func folderSize(_ u: URL) -> Int64? {
        let started = Date()
        var total: Int64 = 0, count = 0
        let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey], options: [])
        while let f = e?.nextObject() as? URL {
            count += 1
            if count > 20_000 || (count % 500 == 0 && Date().timeIntervalSince(started) > 0.5) { return nil }
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }

    // MARK: Looking

    /// What's in a folder, with a peek inside each file (a PDF's title and first words, a document's
    /// first lines) so it can be sorted by subject, not just by type.
    static func list(_ path: String, peek: Bool = true, inside: Bool = false) -> Reply {
        guard let dir = url(path), (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return fail("No folder at \(path) (only folders in your home folder).")
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let items = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !items.isEmpty else { return ok("\(dir.path) is empty.") }
        let files = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true }
        let budget = max(40, min(200, 9_000 / max(files.count, 1)))  // bigger folders get shorter peeks
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        var lines = ["\(dir.path): \(files.count) files, \(items.count - files.count) folders"]
        for (i, u) in items.prefix(300).enumerated() {
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                let kids = ((try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                let total = folderSize(u).map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
                lines.append("[\(i + 1)] \(u.lastPathComponent)/ · folder, \(kids.count) items\(total)")
                // Re-organizing: what's already in a folder is listed too (as "Folder/name"), so it can be moved again.
                if inside, !isProject(u, kids) {
                    for k in kids.prefix(120) where (try? k.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true {
                        var line = "    \(u.lastPathComponent)/\(k.lastPathComponent)"
                        if peek, let p = Self.peek(k, limit: min(budget, 120)), !p.isEmpty { line += " · " + p }
                        lines.append(line)
                    }
                }
                continue
            }
            let size = ByteCountFormatter.string(fromByteCount: Int64(v?.fileSize ?? 0), countStyle: .file)
            var line = "[\(i + 1)] \(u.lastPathComponent) · \(size) · \(v?.contentModificationDate.map(date.string) ?? "")"
            if peek, let p = Self.peek(u, limit: budget), !p.isEmpty { line += " · " + p }
            lines.append(line)
        }
        if items.count > 300 { lines.append("(\(items.count - 300) more not listed)") }
        return ok(lines.joined(separator: "\n"))
    }

    /// A folder that's one thing, not a pile: an app or bundle, or a project (code, KiCad, Xcode…).
    /// Its insides stay together; only plain folders are opened up for re-sorting.
    static func isProject(_ u: URL, _ kids: [URL]) -> Bool {
        if !u.pathExtension.isEmpty { return true }  // Pix.app, x.dSYM, y.xcodeproj, z.bundle
        let names = Set(kids.map { $0.lastPathComponent.lowercased() })
        let markers = [".git", "package.json", "makefile", "cmakelists.txt", "build.gradle", "pom.xml", "cargo.toml", "pyproject.toml", "readme.md"]
        if markers.contains(where: names.contains) { return true }
        let exts = Set(kids.map { $0.pathExtension.lowercased() })
        return !exts.isDisjoint(with: ["kicad_pro", "kicad_pcb", "xcodeproj", "sln", "uproject", "rbxl", "ino"])
    }

    /// The first words that say what a file is about.
    static func peek(_ u: URL, limit: Int) -> String? {
        let ext = u.pathExtension.lowercased()
        func clip(_ s: String) -> String {
            String(s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces).prefix(limit))
        }
        switch ext {
        case "pdf":
            guard let doc = PDFDocument(url: u) else { return nil }
            let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) ?? ""
            let text = doc.page(at: 0)?.string ?? ""
            return clip((title.isEmpty ? "" : "title: \(title). ") + text)
        case "ipynb":
            guard let d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: u))) as? [String: Any] else { return nil }
            let cells = (d["cells"] as? [[String: Any]] ?? []).prefix(3).map { c -> String in
                ((c["source"] as? [String]) ?? [(c["source"] as? String) ?? ""]).joined()
            }
            return clip(cells.joined(separator: " "))
        case "txt", "md", "py", "swift", "java", "c", "cpp", "h", "js", "ts", "html", "css", "csv", "json", "tex", "rtf", "m", "r", "kt", "go", "rs":
            guard let h = try? FileHandle(forReadingFrom: u) else { return nil }
            defer { try? h.close() }
            let data = (try? h.read(upToCount: 4_000)) ?? Data()
            return clip(String(decoding: data, as: UTF8.self))
        default:
            return nil  // images, videos, installers, archives: the name and type say enough
        }
    }

    // MARK: Moving (one batch, one Undo)

    /// A free name in `folder`: "Lab 2.pdf", then "Lab 2 2.pdf"… Nothing is ever overwritten.
    static func free(_ name: String, in folder: URL) -> URL {
        var u = folder.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return u
    }

    /// Moves (and renames) many files at once. Each move: `name` (in `base`, or a full path), and a
    /// `folder` to put it in (made if needed, relative to `base`) and/or a new `rename`.
    static func move(base: String?, moves: [[String: Any]], run: String = ProcessInfo.processInfo.environment["PIX_RUN"] ?? "") -> Reply {
        let baseURL = base.flatMap { url($0) }
        var done: [[String]] = [], made: [String] = [], skipped: [String] = []
        var perFolder: [String: Int] = [:]
        for m in moves {
            guard let name = m["name"] as? String, let from = url(name, base: baseURL) else { skipped.append("\(m["name"] ?? "?") (outside your home folder)"); continue }
            guard FileManager.default.fileExists(atPath: from.path) else { skipped.append("\(from.lastPathComponent) (not found)"); continue }
            guard !guarded(from) else { skipped.append("\(from.lastPathComponent) (Pix doesn't move that folder)"); continue }
            let folderName = (m["folder"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let dest = folderName.map({ url($0, base: baseURL ?? from.deletingLastPathComponent()) }) ?? from.deletingLastPathComponent() else {
                skipped.append("\(from.lastPathComponent) (folder outside your home folder)"); continue
            }
            if !FileManager.default.fileExists(atPath: dest.path) {
                do { try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true); made.append(dest.path) }
                catch { skipped.append("\(from.lastPathComponent) (couldn't make \(dest.lastPathComponent))"); continue }
            }
            let newName = (m["rename"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? from.lastPathComponent
            let to = free(newName, in: dest)
            if to.path == from.path { continue }
            do {
                try FileManager.default.moveItem(at: from, to: to)
                done.append([to.path, from.path])
                perFolder[dest.lastPathComponent, default: 0] += 1
            } catch {
                skipped.append("\(from.lastPathComponent) (\(error.localizedDescription))")
            }
        }
        if !done.isEmpty {
            let summary = "Moved \(done.count) file\(done.count == 1 ? "" : "s")" + (perFolder.count > 1 || made.count > 0 ? " into \(perFolder.count) folder\(perFolder.count == 1 ? "" : "s")" : "")
            Actions.log("files_move", summary, undo: ["type": "files_unmove", "moves": done, "made": made], run: run)
        }
        let breakdown = perFolder.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        var text = done.isEmpty ? "Nothing was moved." : "Moved \(done.count): \(breakdown)."
        if !skipped.isEmpty { text += " Skipped \(skipped.count): " + skipped.prefix(20).joined(separator: "; ") }
        return (text, done.isEmpty && !moves.isEmpty)
    }

    /// Undo for a batch: everything goes back where it was, and folders the batch made are removed if empty.
    static func unmove(_ u: [String: Any]) -> Bool {
        var ok = true
        for pair in (u["moves"] as? [[String]] ?? []).reversed() where pair.count == 2 {
            let now = URL(fileURLWithPath: pair[0]), was = URL(fileURLWithPath: pair[1])
            guard FileManager.default.fileExists(atPath: now.path), !FileManager.default.fileExists(atPath: was.path) else { ok = false; continue }
            try? FileManager.default.createDirectory(at: was.deletingLastPathComponent(), withIntermediateDirectories: true)  // its old folder may be gone
            do { try FileManager.default.moveItem(at: now, to: was) } catch { ok = false }
        }
        for folder in (u["made"] as? [String] ?? []).reversed() {
            if (try? FileManager.default.contentsOfDirectory(atPath: folder).filter { !$0.hasPrefix(".") }.isEmpty) == true {
                try? FileManager.default.removeItem(atPath: folder)
            }
        }
        return ok
    }

    // MARK: Trash (asks first), zip, unzip, duplicates, show

    static func trash(_ paths: [String], run: String = ProcessInfo.processInfo.environment["PIX_RUN"] ?? "") -> Reply {
        var done: [[String]] = []
        for p in paths {
            guard let u = url(p), FileManager.default.fileExists(atPath: u.path), !guarded(u) else { continue }
            var out: NSURL?
            if (try? FileManager.default.trashItem(at: u, resultingItemURL: &out)) != nil, let t = out?.path { done.append([t, u.path]) }
        }
        guard !done.isEmpty else { return fail("Nothing was moved to the Trash.") }
        Actions.log("files_trash", "Moved \(done.count) to the Trash", undo: ["type": "files_unmove", "moves": done, "made": []], run: run)
        return ok("Moved \(done.count) to the Trash (Undo puts them back).")
    }

    static func zip(_ paths: [String], name: String, run: String = ProcessInfo.processInfo.environment["PIX_RUN"] ?? "") -> Reply {
        let items = paths.compactMap { url($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let first = items.first else { return fail("Nothing to zip.") }
        let folder = first.deletingLastPathComponent()
        let out = free((name.hasSuffix(".zip") ? name : name + ".zip"), in: folder)
        // One item: ditto zips it directly. Several: they're staged in a folder of that name first.
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("pix-zip-\(UUID().uuidString)").appendingPathComponent((out.lastPathComponent as NSString).deletingPathExtension)
        try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        for i in items { _ = BuiltIn.run("/usr/bin/ditto", [i.path, stage.appendingPathComponent(i.lastPathComponent).path], timeout: 300) }
        guard BuiltIn.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", stage.path, out.path], timeout: 600) != nil else { return fail("Couldn't make the zip.") }
        try? FileManager.default.removeItem(at: stage.deletingLastPathComponent())
        Actions.log("files_zip", "Made \(out.lastPathComponent)", undo: ["type": "files_remove", "path": out.path], run: run)
        return ok("Made \(out.path) with \(items.count) item\(items.count == 1 ? "" : "s").")
    }

    static func unzip(_ path: String, run: String = ProcessInfo.processInfo.environment["PIX_RUN"] ?? "") -> Reply {
        guard let z = url(path), FileManager.default.fileExists(atPath: z.path) else { return fail("No zip at \(path).") }
        let dest = free((z.lastPathComponent as NSString).deletingPathExtension, in: z.deletingLastPathComponent())
        guard BuiltIn.run("/usr/bin/ditto", ["-x", "-k", z.path, dest.path], timeout: 600) != nil else { return fail("Couldn't open \(z.lastPathComponent).") }
        Actions.log("files_unzip", "Unzipped \(z.lastPathComponent)", undo: ["type": "files_remove", "path": dest.path], run: run)
        return ok("Unzipped into \(dest.path).")
    }

    /// Same size and same bytes = duplicates. Read-only: nothing is removed.
    static func duplicates(_ path: String) -> Reply {
        guard let dir = url(path) else { return fail("No folder at \(path).") }
        var bySize: [Int: [URL]] = [:]
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])
        var count = 0
        while let u = e?.nextObject() as? URL, count < 20_000 {
            count += 1
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true, let s = v.fileSize, s > 0 else { continue }
            bySize[s, default: []].append(u)
        }
        var groups: [[URL]] = []
        for (_, same) in bySize where same.count > 1 {
            var byHash: [String: [URL]] = [:]
            for u in same { if let h = BuiltIn.run("/sbin/md5", ["-q", u.path], timeout: 60) { byHash[h, default: []].append(u) } }
            groups += byHash.values.filter { $0.count > 1 }
        }
        guard !groups.isEmpty else { return ok("No duplicates in \(dir.path).") }
        return ok("\(groups.count) sets of duplicates:\n" + groups.prefix(40).map { g in g.map(\.path).joined(separator: "\n  = ") }.joined(separator: "\n"))
    }

    static func reveal(_ path: String) -> Reply {
        guard let u = url(path), FileManager.default.fileExists(atPath: u.path) else { return fail("Nothing at \(path).") }
        NSWorkspace.shared.activateFileViewerSelecting([u])
        return ok("Showing \(u.lastPathComponent) in Finder.")
    }
}

/// Organizing a whole folder in one call, done by Pix itself instead of a model deciding file by file
/// (an 8B model took 20 minutes and invented folders like "Academic Papers"). By subject it reads each
/// file's name and first words (course codes like PHYS-130, words like derivative or titration), keeps
/// numbered sets together, and leaves anything it isn't sure of in place, saying which. One batch, one Undo.
enum Organizer {
    /// Subject → words that point to it. Course codes are checked separately.
    static let subjects: [(String, [String])] = [
        ("Math", ["calculus", "derivative", "integral", "algebra", "geometry", "trigonometry", "matrix", "matrices", "linear algebra", "stewart",
                  "differential equation", "theorem", "polynomial", "limit definition", "precalc", "statistics", "probability", "math",
                  "limits", "continuity", "epsilon", "quadratic", "logarithm", "integration", "eigen", "vector calc"]),
        ("Physics", ["physics", "velocity", "acceleration", "kinematics", "projectile", "newton", "force", "momentum", "air resistance", "terminal velocity",
                     "measuring g", "friction", "torque", "circuit lab", "phys"]),
        ("Chemistry", ["chemistry", "chem", "beer's law", "beers law", "titration", "molar", "molecule", "stoichiometry", "density measurement",
                       "mass and density", "periodic table", "reaction", "solution concentration"]),
        ("Programming", ["comsc", "programming", "#include", "def ", "import ", "public class", "function", "algorithm", "linked list", "jupyter",
                         "python", "java", "c++", "swift", "javascript", "roblox", "plugin", "mcp"]),
        ("Engineering", ["kicad", "schematic", "pcb", "frc", "robot", "cad", "arduino", "solidworks", "onshape", "datasheet"]),
        ("English", ["essay", "thesis", "prompt", "paragraph", "rhetoric", "literature", "novel", "poem", "mla", "works cited", "english", "csw",
                     "convenience store woman", "reading response", "poetry", "sonnet", "shakespeare", "pentameter", "stanza", "gatsby",
                     "annotation", "rhetorical"]),
        ("Personal", ["resume", "résumé", "cover letter", "receipt", "invoice", "order confirmation", "boarding pass", "ticket", "statement", "manual",
                      "warranty", "service manual", "insurance", "calcentral", "transcript", "academic summary", "score report", "financial aid", "id card"]),
    ]
    static let codes: [(String, String)] = [("MATH", "Math"), ("PHYS", "Physics"), ("CHEM", "Chemistry"), ("COMSC", "Programming"), ("CS", "Programming"),
                                            ("CIS", "Programming"), ("ENGL", "English"), ("ENGR", "Engineering"), ("BIOL", "Biology"), ("HIST", "History")]
    static let byType: [(String, Set<String>)] = [
        ("Images", ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg"]), ("Videos", ["mp4", "mov", "m4v", "avi", "mkv", "webm"]),
        ("Audio", ["mp3", "m4a", "wav", "aac", "flac"]), ("Installers", ["dmg", "pkg", "exe", "msi", "iso"]), ("Archives", ["zip", "tar", "gz", "rar", "7z"]),
        ("Documents", ["pdf", "doc", "docx", "pages", "rtf", "txt", "md", "odt", "key", "pptx", "ppt"]), ("Spreadsheets", ["xlsx", "xls", "csv", "numbers"]),
        ("Code", ["py", "swift", "java", "c", "cpp", "h", "js", "ts", "ipynb", "rb", "go", "rs", "kt", "rbxmx", "lua"]),
    ]
    static let codeExts: Set<String> = ["py", "swift", "java", "c", "cpp", "h", "js", "ts", "ipynb", "rb", "go", "rs", "kt", "rbxmx", "lua", "dsym"]
    static let installerExts: Set<String> = ["dmg", "pkg", "exe", "msi", "iso"]
    /// Unsure files of these kinds still get a home by type; unsure documents stay where they are.
    static let fallbackTypes: Set<String> = ["Images", "Videos", "Audio", "Installers", "Archives"]

    /// Folders that are piles to sort (a past "Other", "Classes", "Misc"…), as opposed to the user's own
    /// folders (a project, a class library), which move as one piece and are never pulled apart.
    static let bins: Set<String> = ["other", "others", "misc", "miscellaneous", "unsorted", "uncategorized", "classes", "academic papers",
                                    "lab data", "lab reports", "data files", "new folder", "untitled folder", "stuff", "random", "downloads"]
    static func isBin(_ name: String) -> Bool { bins.contains(name.lowercased()) || name.lowercased().hasPrefix("untitled folder") }
    static var sortedFolders: Set<String> { Set(subjects.map(\.0) + byType.map(\.0) + ["Installers", "Biology", "History", "Folders"]) }

    /// The subject a file is about, or nil when it isn't clear.
    static func subject(name: String, text: String) -> String? {
        let hay = (name + " " + text).lowercased()
        var score: [String: Int] = [:]
        for (code, subj) in codes where hay.range(of: "\\b\(code.lowercased())[ -]?\\d{2,3}", options: .regularExpression) != nil { score[subj, default: 0] += 5 }
        for (subj, words) in subjects { for w in words where hay.contains(w) { score[subj, default: 0] += name.lowercased().contains(w) ? 3 : 1 } }
        let ext = (name as NSString).pathExtension.lowercased()
        if codeExts.contains(ext) { score["Programming", default: 0] += 3 }
        guard let best = score.max(by: { $0.value < $1.value }), best.value >= 2 else { return nil }
        let ties = score.values.filter { $0 == best.value }.count
        return ties > 1 ? nil : best.key
    }

    static func typeFolder(_ name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        return byType.first { $0.1.contains(ext) }?.0
    }

    /// "1 filter.csv", "2 filter.csv" → "filter.csv": numbered copies and sets go together.
    static func family(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: #"[\d_\-\(\) ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+\."#, with: ".", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static func organize(_ path: String, by: String = "subject", includeFolders: Bool = true,
                         run: String = ProcessInfo.processInfo.environment["PIX_RUN"] ?? "") -> FileTools.Reply {
        guard let dir = FileTools.url(path) else { return FileTools.fail("No folder at \(path) in your home folder.") }
        let rel = dir.path.dropFirst(NSHomeDirectory().count + 1)
        guard !rel.hasPrefix("Library"), !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
            return FileTools.fail("Pix doesn't reorganize Library or hidden folders.")
        }
        let fm = FileManager.default
        let top = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
        // Everything to place: loose files, project folders (as one unit), and files inside plain folders.
        var items: [(url: URL, rel: String, unit: Bool)] = []
        var plainFolders: [URL] = []
        for u in top {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if !isDir { items.append((u, u.lastPathComponent, false)); continue }
            let kids = ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            if sortedFolders.contains(u.lastPathComponent) { continue }  // already a subject or type folder: leave its contents be
            if !isBin(u.lastPathComponent) || FileTools.isProject(u, kids) { items.append((u, u.lastPathComponent, true)); continue }
            plainFolders.append(u)
            guard includeFolders else { continue }
            for k in kids {
                let kDir = (try? k.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                let grand = kDir ? ((try? fm.contentsOfDirectory(at: k, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []) : []
                if !kDir || FileTools.isProject(k, grand) { items.append((k, u.lastPathComponent + "/" + k.lastPathComponent, kDir)) }
            }
        }
        // Decide each one, then let numbered sets vote so they stay together.
        var pick: [String: String] = [:]
        for it in items {
            let name = it.url.lastPathComponent
            var text = ""
            if it.unit, by == "subject" {
                // A folder goes where most of what's inside it goes (a folder of .java files is Programming).
                let kids = ((try? fm.contentsOfDirectory(atPath: it.url.path)) ?? []).filter { !$0.hasPrefix(".") }
                let votes = kids.prefix(60).compactMap { subject(name: $0, text: "") }
                let counts = Dictionary(grouping: votes, by: { $0 }).mapValues(\.count)
                if let top = counts.max(by: { $0.value < $1.value }), counts.values.filter({ $0 == top.value }).count == 1 {
                    pick[it.rel] = top.key
                    continue
                }
                text = kids.prefix(30).joined(separator: " ")
            } else if by == "subject" {
                text = FileTools.peek(it.url, limit: 600) ?? ""
            }
            switch by {
            case "type": pick[it.rel] = it.unit ? "Folders" : typeFolder(name)
            case "date":
                let d = (try? it.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                let f = DateFormatter(); f.dateFormat = "yyyy-MM"
                pick[it.rel] = f.string(from: d)
            default:
                let ext = (name as NSString).pathExtension.lowercased()
                if installerExts.contains(ext) { pick[it.rel] = "Installers"; break }  // an installer is an installer, whatever it installs
                pick[it.rel] = subject(name: name, text: text) ?? typeFolder(name).flatMap { fallbackTypes.contains($0) ? $0 : nil }
            }
        }
        if by == "subject" {
            var families: [String: [String]] = [:]
            for it in items { families[family(it.url.lastPathComponent), default: []].append(it.rel) }
            for (_, members) in families where members.count > 1 {
                let counts = Dictionary(grouping: members.compactMap { pick[$0] }, by: { $0 }).mapValues(\.count)
                guard let top = counts.values.max() else { continue }
                let leaders = counts.filter { $0.value == top }.map(\.key)
                let winner: String? = leaders.count == 1 ? leaders[0] : nil  // a split vote: the set stays together, where it is
                for m in members { pick[m] = winner }
            }
        }
        // Build one batch: only files whose place changes.
        var moves: [[String: Any]] = []
        var unsure: [String] = []
        for it in items {
            guard let folder = pick[it.rel] else { unsure.append(it.rel); continue }
            let currentFolder = it.rel.contains("/") ? String(it.rel.split(separator: "/").first!) : ""
            if currentFolder == folder || it.url.lastPathComponent == folder { continue }
            moves.append(["name": it.rel, "folder": folder])
        }
        guard !moves.isEmpty else {
            return FileTools.ok("Already organized" + (unsure.isEmpty ? "." : ". Not sure where these go, so they stayed: " + unsure.prefix(30).joined(separator: ", ")))
        }
        let result = FileTools.move(base: dir.path, moves: moves, run: run)
        // Folders left empty by the move (like an old "Other") go away; Undo brings them back.
        var removed: [String] = []
        for f in plainFolders where (try? fm.contentsOfDirectory(atPath: f.path).filter { !$0.hasPrefix(".") }.isEmpty) == true {
            if (try? fm.removeItem(at: f)) != nil { removed.append(f.path) }
        }
        if !removed.isEmpty { Actions.log("files_move", "Removed \(removed.count) empty folder\(removed.count == 1 ? "" : "s")", undo: ["type": "folders_restore", "paths": removed], run: run) }
        var text = result.text
        if !removed.isEmpty { text += " Removed empty folders: " + removed.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") + "." }
        if !unsure.isEmpty { text += " Not sure where these go, so they stayed: " + unsure.prefix(30).joined(separator: ", ") + (unsure.count > 30 ? " and \(unsure.count - 30) more" : "") + "." }
        return (text, result.error)
    }
}

/// Claude Code's own file edits inside the project Pix was called from go ahead, each with Undo (the old
/// file is kept in ~/Pix/backups until then); edits anywhere else still ask. Found by the day-to-day
/// audit: "find the bug and fix it" stopped at an Allow card for every edit.
enum ProjectEdits {
    static let tools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    /// The file an edit would change, if it's inside the project (and not in .git).
    static func target(tool: String, input: [String: Any], project: URL?) -> (url: URL, name: String)? {
        guard tools.contains(tool), let project, let raw = (input["file_path"] ?? input["notebook_path"]) as? String, raw.hasPrefix("/") else { return nil }
        let root = project.resolvingSymlinksInPath().standardizedFileURL.path
        guard root != NSHomeDirectory(), root != "/", root.split(separator: "/").count >= 3 else { return nil }
        let given = URL(fileURLWithPath: raw).standardizedFileURL
        let url = given.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(given.lastPathComponent)
        guard url.path.hasPrefix(root + "/"), !url.path.contains("/.git/") else { return nil }
        return (url, String(url.path.dropFirst(root.count + 1)))
    }

    /// True when the edit may go ahead; its Undo is logged first.
    static func allow(tool: String, input: [String: Any], project: URL?, run: String) -> Bool {
        guard let (url, name) = target(tool: tool, input: input, project: project) else { return false }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let backup = PixPaths.home.appendingPathComponent("backups/\(run.isEmpty ? "run" : run)/\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
            try? fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? fm.copyItem(at: url, to: backup)) != nil else { return false }
            Actions.log("file_edit", "Edited \(name)", undo: ["type": "file_restore", "path": url.path, "backup": backup.path], run: run)
        } else {
            Actions.log("file_edit", "Created \(name)", undo: ["type": "files_remove", "path": url.path], run: run)
        }
        return true
    }

    static func restore(_ u: [String: Any]) -> Bool {
        guard let p = u["path"] as? String, let b = u["backup"] as? String, FileManager.default.fileExists(atPath: b) else { return false }
        let fm = FileManager.default
        try? fm.removeItem(atPath: p)
        return (try? fm.copyItem(atPath: b, toPath: p)) != nil
    }
}
