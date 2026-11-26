import Foundation

/// How Desk Draw talks to the local coding agent.
enum AgentConnection: String, CaseIterable, Identifiable {
    /// A one-shot command that gets the request in `$DESKDRAW_PROMPT` and exits when done.
    case cli
    /// A command that starts an Agent Client Protocol server on stdin/stdout.
    case acp

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cli: "Command line"
        case .acp: "ACP"
        }
    }
}

struct AgentPreset: Identifiable, Equatable {
    let title: String
    let connection: AgentConnection
    /// Makes the preview. The agent may read, but not change anything.
    let command: String
    /// Applies a preview to the code. Command line only; an ACP agent asks Desk Draw
    /// before it edits, so one command serves both.
    let applyCommand: String
    var id: String { title }

    static let claudeCode = AgentPreset(
        title: "Claude Code",
        connection: .cli,
        command: #"claude -p "$DESKDRAW_PROMPT" --permission-mode default --disallowedTools "Edit Write NotebookEdit Bash" --add-dir "$DESKDRAW_ATTACHMENTS" --output-format stream-json --verbose"#,
        applyCommand: #"claude -p "$DESKDRAW_PROMPT" --permission-mode acceptEdits --add-dir "$DESKDRAW_ATTACHMENTS" --output-format stream-json --verbose"#
    )
    static let antigravity = AgentPreset(title: "Antigravity", connection: .acp, command: "agy acp", applyCommand: "agy acp")
    static let all = [claudeCode, antigravity]
    static let `default` = claudeCode

    /// The preset these settings match, or nil for a custom command.
    static func matching(connection: AgentConnection, command: String, applyCommand: String) -> AgentPreset? {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return all.first {
            $0.connection == connection && $0.command == clean(command)
                && (connection == .acp || $0.applyCommand == clean(applyCommand))
        }
    }
}

/// Everything the agent gets for one Imagine change.
struct AgentRequest {
    /// The folder the agent works in: the project, or the screenshots' folder without one.
    var project: URL
    var prompt: String
    /// Applying to code. Otherwise the agent only reads and replies with a preview.
    var mayEdit = false
    /// Holds the screenshots; the agent may read it.
    var attachments: URL
    var images: [URL]
}

/// One run of the agent. Reports what it is doing, and how it ended, on the main actor.
@MainActor
final class AgentRun {
    enum Outcome: Equatable {
        case finished
        case cancelled
        case failed(String)
    }

    let connection: AgentConnection
    let command: String
    let allowCommands: Bool
    /// What the agent is doing right now, in a few words.
    var onActivity: ((String) -> Void)?
    /// The agent's reply so far.
    var onMessage: ((String) -> Void)?
    var onEnd: ((Outcome) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var stderrTail: [String] = []
    private var stdoutTail: [String] = []
    private var message = ""
    private var finalMessage: String?
    private var cliError: String?
    private var ended = false
    private var cancelled = false
    private var request: AgentRequest?

    // ACP
    private var nextID = 1
    private var pendingMethods: [Int: String] = [:]
    private var sessionID: String?
    private var agentTakesImages = false
    private var probeOnly = false
    private(set) var agentName: String?

    init(connection: AgentConnection, command: String, allowCommands: Bool) {
        self.connection = connection
        self.command = command
        self.allowCommands = allowCommands
    }

    // MARK: Starting and stopping

    func start(_ request: AgentRequest) {
        self.request = request
        launch(in: request.project, environment: [
            "DESKDRAW_PROMPT": request.prompt,
            "DESKDRAW_ATTACHMENTS": request.attachments.path,
            "DESKDRAW_PROJECT": request.project.path,
            "DESKDRAW_IMAGES": request.images.map(\.path).joined(separator: "\n"),
            "DESKDRAW_MODE": request.mayEdit ? "apply" : "preview",
        ])
        if connection == .acp { sendInitialize() }
    }

    /// ACP only: connects, reads the agent's name, and stops.
    func probe(in folder: URL) {
        probeOnly = true
        launch(in: folder, environment: [:])
        sendInitialize()
    }

    func cancel() {
        guard !ended else { return }
        cancelled = true
        if connection == .acp, let sessionID {
            notify("session/cancel", ["sessionId": sessionID])
        }
        process?.terminate()
    }

    private func launch(in folder: URL, environment: [String: String]) {
        // Writing to an agent that already quit must fail, not kill Desk Draw.
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // A login shell, so the agent finds what the user's own terminal would.
        process.arguments = ["-lc", "exec \(command)"]
        process.currentDirectoryURL = folder
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Shell.agentPath
        env.merge(environment) { $1 }
        process.environment = env

        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = connection == .acp ? input : FileHandle.nullDevice
        stdin = connection == .acp ? input.fileHandleForWriting : nil

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if data.isEmpty { self?.outputClosed() } else { self?.receive(data) }
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receiveError(data) } }
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(status: status) } }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            finish(.failed("Could not start the agent: \(error.localizedDescription)"))
        }
    }

    private var exitStatus: Int32?
    private var isOutputClosed = false

    private func outputClosed() {
        isOutputClosed = true
        if let exitStatus { processExited(status: exitStatus) }
    }

    /// Waits for the last output before judging the run; a child process that keeps the
    /// pipe open gets two seconds.
    private func exited(status: Int32) {
        exitStatus = status
        if isOutputClosed { return processExited(status: status) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.processExited(status: status) }
        }
    }

    private func processExited(status: Int32) {
        guard !ended else { return }
        if !buffer.isEmpty {
            handleLine(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
        if cancelled { return finish(.cancelled) }
        if connection == .acp {
            // A finished prompt ends the run before the process exits.
            return finish(.failed(failureText(status: status, fallback: "The agent stopped before it finished.")))
        }
        if let cliError { return finish(.failed(cliError)) }
        if status != 0 {
            return finish(.failed(failureText(status: status, fallback: "The agent exited with status \(status).")))
        }
        if let finalMessage, !finalMessage.isEmpty { onMessage?(finalMessage) }
        finish(.finished)
    }

    private func failureText(status: Int32, fallback: String) -> String {
        if status == 127 {
            return "Command not found: \(command.split(separator: " ").first ?? ""). Check Imagine Settings."
        }
        let tail = (stderrTail.isEmpty ? stdoutTail : stderrTail).suffix(3).joined(separator: " ")
        return tail.isEmpty ? fallback : String(tail.prefix(400))
    }

    private func finish(_ outcome: Outcome) {
        guard !ended else { return }
        ended = true
        if process?.isRunning == true { process?.terminate() }
        try? stdin?.close()
        onEnd?(outcome)
    }

    // MARK: Output

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            handleLine(line)
        }
    }

    private func receiveError(_ data: Data) {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        stderrTail = Array((stderrTail + lines).suffix(6))
    }

    private func handleLine(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            stdoutTail = Array((stdoutTail + [line]).suffix(6))
            if connection == .cli { onActivity?(String(line.prefix(120))) }
            return
        }
        switch connection {
        case .cli: handleCLIEvent(json)
        case .acp: handleACPMessage(json)
        }
    }

    // MARK: Command line

    private func handleCLIEvent(_ json: [String: Any]) {
        let event = CLIStream.parse(json)
        if let activity = event.activity { onActivity?(activity) }
        if let text = event.text {
            message = text
            onMessage?(text)
        }
        if let final = event.final { finalMessage = final }
        if let error = event.error { cliError = error }
    }

    // MARK: ACP

    private func sendInitialize() {
        call("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
            "clientInfo": ["name": "Desk Draw", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"],
        ])
    }

    private func call(_ method: String, _ params: [String: Any]) {
        let id = nextID
        nextID += 1
        pendingMethods[id] = method
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func respond(_ id: Any, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func respond(_ id: Any, errorCode: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": errorCode, "message": message]])
    }

    private func write(_ object: [String: Any]) {
        guard let stdin, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        do { try stdin.write(contentsOf: data) } catch {}
    }

    private func handleACPMessage(_ json: [String: Any]) {
        let method = json["method"] as? String
        let id = json["id"]
        if let method, let id {
            handleACPRequest(method: method, id: id, params: json["params"] as? [String: Any] ?? [:])
        } else if let method {
            if method == "session/update", let params = json["params"] as? [String: Any] {
                handleSessionUpdate(params["update"] as? [String: Any] ?? [:])
            }
        } else if let id = (id as? Int) ?? (id as? String).flatMap(Int.init), let sent = pendingMethods.removeValue(forKey: id) {
            if let error = json["error"] as? [String: Any] {
                let text = error["message"] as? String ?? "Unknown error"
                return finish(.failed(sent == "initialize" || sent == "session/new"
                                      ? "The agent didn't start a session: \(text)" : text))
            }
            handleACPResult(of: sent, json["result"] as? [String: Any] ?? [:])
        }
    }

    private func handleACPResult(of method: String, _ result: [String: Any]) {
        switch method {
        case "initialize":
            let info = result["agentInfo"] as? [String: Any]
            agentName = (info?["title"] as? String) ?? (info?["name"] as? String) ?? "ACP agent"
            let capabilities = result["agentCapabilities"] as? [String: Any]
            agentTakesImages = (capabilities?["promptCapabilities"] as? [String: Any])?["image"] as? Bool ?? false
            if probeOnly { return finish(.finished) }
            guard let request else { return }
            call("session/new", ["cwd": request.project.path, "mcpServers": [Any]()])
        case "session/new":
            guard let request, let id = result["sessionId"] as? String else {
                return finish(.failed("The agent didn't start a session."))
            }
            sessionID = id
            onActivity?("Thinking…")
            var prompt: [[String: Any]] = [["type": "text", "text": request.prompt]]
            if agentTakesImages {
                for url in request.images {
                    if let data = try? Data(contentsOf: url) {
                        prompt.append(["type": "image", "mimeType": "image/png", "data": data.base64EncodedString()])
                    }
                }
            }
            call("session/prompt", ["sessionId": id, "prompt": prompt])
        case "session/prompt":
            let reason = result["stopReason"] as? String ?? "end_turn"
            if !message.isEmpty { onMessage?(message) }
            switch reason {
            case "cancelled": finish(.cancelled)
            case "refusal": finish(.failed(message.isEmpty ? "The agent declined the request." : message))
            default: finish(.finished)
            }
        default:
            break
        }
    }

    private func handleSessionUpdate(_ update: [String: Any]) {
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            if let text = (update["content"] as? [String: Any])?["text"] as? String {
                message += text
                onMessage?(message)
            }
        case "tool_call":
            onActivity?(ACPPolicy.describe(update))
        default:
            break
        }
    }

    private func handleACPRequest(method: String, id: Any, params: [String: Any]) {
        guard method == "session/request_permission" else {
            // Desk Draw offers no file system or terminal of its own; the agent uses its own tools.
            return respond(id, errorCode: -32601, message: "Desk Draw does not support \(method)")
        }
        let toolCall = params["toolCall"] as? [String: Any] ?? [:]
        let options = params["options"] as? [[String: Any]] ?? []
        let allow = ACPPolicy.allows(toolCall, project: request?.project, attachments: request?.attachments,
                                     mayEdit: request?.mayEdit ?? false, allowCommands: allowCommands)
        if !allow { onActivity?("Declined: \(ACPPolicy.describe(toolCall))") }
        if let option = ACPPolicy.option(allow: allow, from: options) {
            respond(id, result: ["outcome": ["outcome": "selected", "optionId": option]])
        } else {
            respond(id, result: ["outcome": ["outcome": "cancelled"]])
        }
    }
}

// MARK: - Parsing

/// Reads the JSON lines that `claude -p --output-format stream-json` and
/// `agy -p --output-format stream-json` print.
enum CLIStream {
    struct Event: Equatable {
        var activity: String?
        var text: String?
        var final: String?
        var error: String?
    }

    static func parse(_ json: [String: Any]) -> Event {
        var event = Event()
        switch json["type"] as? String {
        case "assistant":
            let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for item in content {
                switch item["type"] as? String {
                case "tool_use":
                    let input = item["input"] as? [String: Any] ?? [:]
                    event.activity = describeTool(item["name"] as? String ?? "", input: input)
                case "text":
                    if let text = item["text"] as? String, !text.isEmpty { event.text = text }
                default: break
                }
            }
        case "result":
            if let result = json["result"] as? String { event.final = result }
            if json["is_error"] as? Bool == true {
                event.error = (json["result"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "The agent reported an error."
            }
        default:
            break
        }
        switch json["event"] as? String {
        case "step_update":
            let step = json["step_update"] as? [String: Any] ?? [:]
            if step["step_type"] as? String == "tool", step["state"] as? String == "ACTIVE" {
                let info = step["tool_info"] as? [String: Any] ?? [:]
                event.activity = describeTool(step["tool_name"] as? String ?? "", input: info["parameters"] as? [String: Any] ?? [:])
            }
        case "result":
            let result = json["result"] as? [String: Any] ?? [:]
            if let response = result["response"] as? String, !response.isEmpty { event.final = response }
            let denied = (result["denied_actions"] as? [[String: Any]] ?? []).compactMap { $0["display_name"] as? String ?? $0["action"] as? String }
            if !denied.isEmpty {
                event.error = "The agent wasn't allowed to \(denied.joined(separator: ", ")). In Imagine Settings, use the ACP connection, or a command that allows edits."
            }
        default:
            break
        }
        return event
    }

    static func describeTool(_ name: String, input: [String: Any]) -> String {
        let path = ["file_path", "path", "Path", "notebook_path", "TargetFile", "AbsolutePath"]
            .lazy.compactMap { input[$0] as? String }.first
        let file = path.map { ($0 as NSString).lastPathComponent }
        switch name.lowercased() {
        case "edit", "multiedit", "write", "edit_file", "write_file", "replace_file_content", "write_to_file", "notebookedit":
            return file.map { "Editing \($0)" } ?? "Editing"
        case "read", "read_file", "view_file":
            return file.map { "Reading \($0)" } ?? "Reading"
        case "grep", "glob", "grep_search", "find_by_name", "codebase_search", "list_dir", "ls":
            return "Searching the code"
        case "bash", "run_command", "shell":
            return "Running a command"
        default:
            return name.isEmpty ? "Working…" : name
        }
    }
}

/// What Desk Draw approves when an ACP agent asks.
enum ACPPolicy {
    /// Reads anywhere in the project or the screenshots. When applying to code, also edits
    /// inside the project and, if the user allows it, commands. Everything else, such as
    /// network access, is declined.
    static func allows(_ toolCall: [String: Any], project: URL?, attachments: URL?, mayEdit: Bool, allowCommands: Bool) -> Bool {
        let kind = toolCall["kind"] as? String ?? "other"
        let paths = (toolCall["locations"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        func inside(_ folder: URL?) -> (String) -> Bool {
            guard let folder else { return { _ in false } }
            let roots = Set([folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().path])
            return { path in
                let candidates = [URL(fileURLWithPath: path).standardizedFileURL.path,
                                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path]
                return candidates.contains { p in roots.contains { p == $0 || p.hasPrefix($0 + "/") } }
            }
        }
        let inProject = inside(project), inAttachments = inside(attachments)
        switch kind {
        case "read", "search", "think":
            return paths.allSatisfy { inProject($0) || inAttachments($0) }
        case "edit", "delete", "move":
            return mayEdit && !paths.isEmpty && paths.allSatisfy(inProject)
        case "execute":
            return mayEdit && allowCommands
        default:
            return false
        }
    }

    static func option(allow: Bool, from options: [[String: Any]]) -> String? {
        let kinds = allow ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
        for kind in kinds {
            if let id = options.first(where: { $0["kind"] as? String == kind })?["optionId"] as? String { return id }
        }
        return nil
    }

    static func describe(_ toolCall: [String: Any]) -> String {
        let file = (toolCall["locations"] as? [[String: Any]])?.first?["path"] as? String
        let name = file.map { ($0 as NSString).lastPathComponent }
        switch toolCall["kind"] as? String {
        case "edit": return name.map { "Editing \($0)" } ?? "Editing"
        case "read": return name.map { "Reading \($0)" } ?? "Reading"
        case "search": return "Searching the code"
        case "execute": return "Running a command"
        case "delete": return name.map { "Deleting \($0)" } ?? "Deleting a file"
        default: return toolCall["title"] as? String ?? "Working…"
        }
    }
}
