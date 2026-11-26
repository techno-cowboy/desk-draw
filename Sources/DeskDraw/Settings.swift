import Foundation

/// App preferences. These persist; drawings never do.
enum Settings {
    private static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: [
            Key.caption: true,
            Key.jsonSidecar: true,
            Key.browserURL: true,
            Key.clipboard: true,
            Key.imagineConnection: AgentPreset.default.connection.rawValue,
            Key.imagineCommand: AgentPreset.default.command,
            Key.imagineApplyCommand: AgentPreset.default.applyCommand,
            Key.imagineAllowCommands: false,
        ])
        // Before previews, the one command edited files. It now applies previews to code.
        let editingClaude = #"claude -p "$DESKDRAW_PROMPT" --permission-mode acceptEdits --add-dir "$DESKDRAW_ATTACHMENTS" --output-format stream-json --verbose"#
        if defaults.string(forKey: Key.imagineCommand) == editingClaude {
            defaults.removeObject(forKey: Key.imagineCommand)
            defaults.removeObject(forKey: Key.imagineApplyCommand)
        }
    }

    enum Key {
        static let caption = "captionEnabled"
        static let jsonSidecar = "jsonSidecarEnabled"
        static let browserURL = "browserURLEnabled"
        static let clipboard = "copyToClipboardEnabled"
        static let imagineConnection = "imagineConnection"
        static let imagineCommand = "imagineCommand"
        static let imagineApplyCommand = "imagineApplyCommand"
        static let imagineAllowCommands = "imagineAllowCommands"
        static let imagineProjects = "imagineProjectFolders"
    }

    // MARK: Imagine

    /// How Desk Draw talks to the coding agent that makes Imagine changes.
    static var imagineConnection: AgentConnection {
        get { AgentConnection(rawValue: defaults.string(forKey: Key.imagineConnection) ?? "") ?? .cli }
        set { defaults.set(newValue.rawValue, forKey: Key.imagineConnection) }
    }

    /// The shell command that starts the agent for a preview, which must not change files.
    /// For ACP it serves both steps. See `AgentConnection` for what it gets.
    static var imagineCommand: String {
        get { defaults.string(forKey: Key.imagineCommand) ?? AgentPreset.default.command }
        set { defaults.set(newValue, forKey: Key.imagineCommand) }
    }

    /// Command line only: the command that applies a preview to the code, editing files.
    static var imagineApplyCommand: String {
        get { defaults.string(forKey: Key.imagineApplyCommand) ?? AgentPreset.default.applyCommand }
        set { defaults.set(newValue, forKey: Key.imagineApplyCommand) }
    }

    /// ACP only: when applying to code, approve the agent's requests to run terminal
    /// commands. Reads, and edits inside the project while applying, are always approved;
    /// everything else is declined.
    static var imagineAllowCommands: Bool {
        get { defaults.bool(forKey: Key.imagineAllowCommands) }
        set { defaults.set(newValue, forKey: Key.imagineAllowCommands) }
    }

    /// Project folder per app or local web address, as chosen by the user. Optional: the
    /// agent reads it to match the app, and applies previews to it.
    static var imagineProjects: [String: String] {
        get { defaults.dictionary(forKey: Key.imagineProjects) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.imagineProjects) }
    }

    static var caption: Bool {
        get { defaults.bool(forKey: Key.caption) }
        set { defaults.set(newValue, forKey: Key.caption) }
    }

    static var jsonSidecar: Bool {
        get { defaults.bool(forKey: Key.jsonSidecar) }
        set { defaults.set(newValue, forKey: Key.jsonSidecar) }
    }

    static var browserURL: Bool {
        get { defaults.bool(forKey: Key.browserURL) }
        set { defaults.set(newValue, forKey: Key.browserURL) }
    }

    static var clipboard: Bool {
        get { defaults.bool(forKey: Key.clipboard) }
        set { defaults.set(newValue, forKey: Key.clipboard) }
    }

    static var screenshotFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("Desk Draw", isDirectory: true)
    }
}
