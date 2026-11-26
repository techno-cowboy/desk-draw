import AppKit

// MARK: - Shell

struct ShellError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs short helper commands (git, lsof) to completion. Not for the agent, which streams.
enum Shell {
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(_ executable: String, _ arguments: [String], in directory: URL? = nil,
                    environment: [String: String] = [:]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read both pipes at once, so a full stderr buffer can't stall the process.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Output(status: process.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }

    /// PATH for agents started from a menu bar app, which doesn't get the user's shell PATH.
    /// The login shell adds its own on top.
    static var agentPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin",
                     "\(home)/.npm-global/bin", "\(home)/.cargo/bin", "\(home)/.volta/bin"]
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return (extra + [current]).joined(separator: ":")
    }
}

// MARK: - Git

/// Lets Imagine undo exactly what the agent changed, and nothing the user had going.
///
/// A snapshot is the whole working tree (staged, unstaged and untracked files, minus
/// ignored ones) written as a git tree through a throwaway index, so the user's index,
/// branches and stash are never touched.
enum Git {
    struct Change: Equatable {
        /// `A`dded, `M`odified, `D`eleted or `T`ype changed, from the snapshot's point of view.
        let status: Character
        let path: String
    }

    private static let git = "/usr/bin/git"

    static func run(_ arguments: [String], in repo: URL, environment: [String: String] = [:]) throws -> String {
        let output = try Shell.run(git, arguments, in: repo, environment: environment)
        guard output.status == 0 else {
            throw ShellError(message: "git \(arguments.first ?? ""): \(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output.stdout
    }

    /// The repository's top folder, or nil when `folder` is not inside a git work tree.
    static func topLevel(of folder: URL) -> URL? {
        guard let out = try? run(["rev-parse", "--show-toplevel"], in: folder) else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Writes the working tree as a tree object and returns its id.
    static func snapshot(_ repo: URL) throws -> String {
        let indexPath = try run(["rev-parse", "--git-path", "index"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let index = URL(fileURLWithPath: indexPath, relativeTo: repo).standardizedFileURL
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("deskdraw-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        // Starting from the real index keeps `add -A` fast: unchanged files aren't rehashed.
        if FileManager.default.fileExists(atPath: index.path) {
            try FileManager.default.copyItem(at: index, to: temp)
        }
        let env = ["GIT_INDEX_FILE": temp.path]
        _ = try run(["add", "-A", "--", "."], in: repo, environment: env)
        return try run(["write-tree"], in: repo, environment: env).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func changes(in repo: URL, from before: String, to after: String) throws -> [Change] {
        let out = try run(["diff", "--name-status", "--no-renames", "-z", before, after], in: repo)
        let fields = out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var changes: [Change] = []
        var i = 0
        while i + 1 < fields.count {
            if let status = fields[i].first { changes.append(Change(status: status, path: fields[i + 1])) }
            i += 2
        }
        return changes
    }

    static func diff(in repo: URL, from before: String, to after: String) throws -> String {
        try run(["diff", "--no-renames", before, after], in: repo)
    }

    /// Puts the files in `changes` back the way they were in `before`. Other files, and the
    /// index, stay as they are.
    static func revert(_ changes: [Change], in repo: URL, to before: String) throws {
        let restore = changes.filter { $0.status != "A" }.map(\.path)
        if !restore.isEmpty {
            _ = try run(["restore", "--source=\(before)", "--worktree", "--"] + restore, in: repo)
        }
        for change in changes where change.status == "A" {
            let url = repo.appendingPathComponent(change.path)
            try? FileManager.default.removeItem(at: url)
            removeEmptyParents(of: url, upTo: repo)
        }
    }

    private static func removeEmptyParents(of url: URL, upTo root: URL) {
        var dir = url.deletingLastPathComponent().standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        while dir.path.hasPrefix(rootPath + "/"),
              let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path), items.isEmpty {
            try? FileManager.default.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
    }
}

// MARK: - Finding the project

/// Works out which source folder belongs to the app being drawn on.
enum ProjectLocator {
    /// What a chosen project folder is remembered under: the local web address for a
    /// browser tab on this machine, otherwise the app.
    static func key(app: NSRunningApplication?, appName: String, tabURL: String?) -> String {
        if let tabURL, let origin = localOrigin(tabURL) { return "web:\(origin)" }
        if let id = app?.bundleIdentifier { return "app:\(id)" }
        return "app:\(appName)"
    }

    /// `http://localhost:3000` for a page served from this Mac, else nil.
    static func localOrigin(_ url: String) -> String? {
        guard let components = URLComponents(string: url), let host = components.host?.lowercased(),
              ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(host) || host.hasSuffix(".localhost")
        else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(components.scheme ?? "http")://\(host)\(port)"
    }

    /// The port of a page served from this Mac.
    static func localPort(_ url: String) -> Int? {
        guard localOrigin(url) != nil, let components = URLComponents(string: url) else { return nil }
        return components.port ?? (components.scheme == "https" ? 443 : 80)
    }

    /// A best guess, without asking: the folder of the dev server behind a local page, or the
    /// repository an app was built in. Slow (runs lsof), so call it off the main thread.
    static func guess(port: Int?, executable: URL?) -> URL? {
        if let port, let folder = serverFolder(port: port), let root = Git.topLevel(of: folder) {
            return root
        }
        if let executable {
            let folder = executable.deletingLastPathComponent()
            // Apps installed normally aren't inside a repository; only local builds are.
            if !folder.path.hasPrefix("/Applications/"), !folder.path.hasPrefix("/System/"),
               let root = Git.topLevel(of: folder) {
                return root
            }
        }
        return nil
    }

    /// The working folder of the process listening on `port`.
    static func serverFolder(port: Int) -> URL? {
        guard let pids = try? Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]),
              let pid = pids.stdout.split(separator: "\n").first,
              let cwd = try? Shell.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
        else { return nil }
        guard let line = cwd.stdout.split(separator: "\n").first(where: { $0.hasPrefix("n/") }) else { return nil }
        return URL(fileURLWithPath: String(line.dropFirst()), isDirectory: true)
    }
}

// MARK: - Images

extension CGImage {
    /// The image scaled down so its longer side is at most `maxSide` pixels.
    func limited(to maxSide: Int) -> CGImage {
        let longest = max(width, height)
        guard longest > maxSide else { return self }
        let factor = CGFloat(maxSide) / CGFloat(longest)
        let w = Int((CGFloat(width) * factor).rounded()), h = Int((CGFloat(height) * factor).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? self
    }
}

// MARK: - Preview snippets

/// The HTML preview an agent replies with: a short note, then one ```html block.
enum PreviewSnippet {
    struct Reply: Equatable {
        var html: String
        /// What the agent said about it, without the code.
        var note: String
    }

    /// The last HTML code block in `reply`, or a bare document if the agent left out the
    /// fence. Nil when there is no HTML.
    static func extract(from reply: String) -> Reply? {
        let fence = try! NSRegularExpression(pattern: "```[ \\t]*([A-Za-z0-9_-]*)[^\\n]*\\n(.*?)(?:\\n[ \\t]*```|\\z)",
                                             options: [.dotMatchesLineSeparators])
        let ns = reply as NSString
        let blocks = fence.matches(in: reply, range: NSRange(location: 0, length: ns.length)).compactMap { m -> (NSRange, String)? in
            let language = ns.substring(with: m.range(at: 1)).lowercased()
            let code = ns.substring(with: m.range(at: 2))
            guard ["html", "htm", "xml", ""].contains(language), code.contains("<") else { return nil }
            return (m.range, code)
        }
        if let (range, code) = blocks.last {
            let note = ns.replacingCharacters(in: range, with: "")
            return Reply(html: code.trimmingCharacters(in: .whitespacesAndNewlines), note: tidy(note))
        }
        guard let start = reply.range(of: "<!doctype", options: .caseInsensitive)
                ?? reply.range(of: "<html", options: .caseInsensitive) else { return nil }
        let index = start.lowerBound
        return Reply(html: String(reply[index...]).trimmingCharacters(in: .whitespacesAndNewlines),
                     note: tidy(String(reply[..<index])))
    }

    private static func tidy(_ note: String) -> String {
        note.replacingOccurrences(of: "```", with: "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A complete page for the web view: a fragment gets wrapped, and every page gets
    /// UTF-8 and the size of the box.
    static func document(_ html: String, size: CGSize) -> String {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        let base = #"<meta charset="utf-8"><style>html,body{margin:0;width:\#(w)px;height:\#(h)px;overflow:hidden}</style>"#
        // Whole tags, so <header> isn't taken for <head>.
        func find(_ tag: String) -> Range<String.Index>? {
            html.range(of: "<\(tag)(\\s[^>]*)?>", options: [.regularExpression, .caseInsensitive])
        }
        guard find("html") != nil || find("body") != nil || find("head") != nil else {
            return "<!doctype html><html><head>\(base)</head><body>\(html)</body></html>"
        }
        // The base styles go first, so the agent's own styles win.
        if let head = find("head") {
            return String(html[..<head.upperBound]) + base + String(html[head.upperBound...])
        }
        if let root = find("html") {
            return String(html[..<root.upperBound]) + "<head>\(base)</head>" + String(html[root.upperBound...])
        }
        if let body = find("body") {
            return String(html[..<body.lowerBound]) + base + String(html[body.lowerBound...])
        }
        return base + html
    }
}
