import AppKit
import SwiftUI

/// Matches `Capturer.imagineBoxColor`.
private let cyan = Color(.sRGB, red: 0.10, green: 0.75, blue: 0.95)

// MARK: - Prompt

struct ImaginePromptView: View {
    @Bindable var imagine: Imagine
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(cyan)
                Text("Imagine").font(.system(size: 13, weight: .semibold))
                Text(imagine.agentLabel).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { ImagineSettingsWindow.show() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Imagine Settings: agent and connection")
            }

            TextField("What should change here?", text: $imagine.request, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(2...4)
                .focused($focused)
                .padding(8)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .onSubmit { imagine.send() }
                .disabled(imagine.isSending)

            HStack(spacing: 6) {
                Image(systemName: imagine.project == nil ? "photo" : "folder").foregroundStyle(.secondary)
                Group {
                    if let project = imagine.project {
                        Text("Matches the code in \((project.path as NSString).abbreviatingWithTildeInPath)")
                            .truncationMode(.head)
                            .help("The agent reads this code to match the app. It changes nothing unless you choose Apply to Code.")
                    } else if imagine.isFindingProject {
                        Text("Looking for the code of \(imagine.targetName)…")
                    } else {
                        Text("Uses the screenshot. Add code to match the app.")
                            .help("Works from the screenshot alone. Add the app's code so previews match its styles and can be applied.")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if imagine.project != nil {
                    Button { imagine.clearProject() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Work from the screenshot alone")
                        .disabled(imagine.isSending)
                }
                Button(imagine.project == nil ? "Add Code…" : "Change…") { imagine.chooseProject() }
                    .controlSize(.small)
                    .disabled(imagine.isSending)
            }

            HStack {
                if let error = imagine.promptError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                } else {
                    Text("Return to send · Esc to cancel · fn fn to dictate")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                if imagine.isSending { ProgressView().controlSize(.small) }
                Button("Cancel") { imagine.cancelPrompt() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(imagine.isSending)
                Button("Imagine") { imagine.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(cyan)
                    .disabled(imagine.isSending || imagine.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(cyan.opacity(0.55), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { focused = true }
        .onExitCommand { imagine.cancelPrompt() }
    }
}

// MARK: - Box

/// The frame of the imagine box. Frosted while the agent works; the preview shows inside
/// it, in its own view.
struct ImagineBoxView: View {
    let imagine: Imagine
    @State private var sweep = false

    var body: some View {
        let dimmed = imagine.isDimmed
        let borderColor = dimmed ? cyan.opacity(imagine.isHoveringBox ? 0.55 : 0.18) : cyan
        let borderWidth: CGFloat = dimmed ? (imagine.isHoveringBox ? 1.5 : 1) : 2
        ZStack {
            if imagine.isWorking {
                Blur()
                    .overlay(
                        LinearGradient(colors: [.clear, cyan.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 160)
                            .offset(x: sweep ? 600 : -600)
                            .blendMode(.plusLighter)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .transition(.opacity)
                    .onAppear {
                        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { sweep = true }
                    }
            }
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(borderColor, style: StrokeStyle(lineWidth: borderWidth, dash: imagine.isWorking ? [6, 4] : []))
        }
        .animation(.easeOut(duration: 0.35), value: imagine.phase)
        .animation(.easeOut(duration: 0.2), value: imagine.isDimmed)
        .animation(.easeOut(duration: 0.15), value: imagine.isHoveringBox)
    }

    private struct Blur: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .hudWindow
            view.blendingMode = .behindWindow
            view.state = .active
            return view
        }
        func updateNSView(_ view: NSVisualEffectView, context: Context) {}
    }
}

// MARK: - Status pill

struct ImaginePillView: View {
    @Bindable var imagine: Imagine
    @FocusState private var followUpFocused: Bool

    var body: some View {
        let alignment: VerticalAlignment = imagine.pillAbove ? .bottom : .top
        VStack {
            if alignment == .bottom { Spacer(minLength: 0) }
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
                .fixedSize(horizontal: false, vertical: true)
            if alignment == .top { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.2), value: imagine.phase)
        .onChange(of: imagine.focusFollowUpTrigger) { followUpFocused = true }
        .onExitCommand {
            if imagine.phase == .preview, imagine.snippet != nil {
                imagine.hidePill()
            } else if imagine.phase == .preview {
                imagine.close()
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch imagine.phase {
        case .imagining:
            working(imagine.snippet == nil ? "Imagining…" : "Revising…",
                    stopHelp: "Stop the agent")
        case .applying:
            working("Applying to code…", stopHelp: "Stop the agent; you can still keep or discard what it changed")
        case .preview: preview
        case .applied: applied
        default: EmptyView()
        }
    }

    private func working(_ title: String, stopHelp: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(cyan).symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    TimelineView(.periodic(from: imagine.startedAt, by: 1)) { context in
                        Text("\(Int(context.date.timeIntervalSince(imagine.startedAt)))s")
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Text(imagine.activity).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            PillButton(symbol: "stop.fill", title: "Stop", help: stopHelp) {
                imagine.stop()
            }
        }
    }

    private var preview: some View {
        let hasPreview = imagine.snippet != nil
        let text = imagine.problem ?? (imagine.note.isEmpty ? "Here's the preview." : imagine.note)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: imagine.problem == nil ? "sparkles" : "exclamationmark.triangle.fill")
                    .foregroundStyle(imagine.problem == nil ? cyan : .orange)
                Text(text).font(.system(size: 12, weight: .medium)).lineLimit(2).help(text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if hasPreview {
                    HStack(spacing: 6) {
                        PillButton(symbol: "trash", title: nil, help: "Remove the preview") { imagine.close() }
                        PillButton(symbol: "xmark", title: nil, help: "Hide controls and keep the preview on screen") {
                            imagine.hidePill()
                        }
                    }
                } else {
                    PillButton(symbol: "xmark", title: nil, help: "Close") { imagine.close() }
                }
            }
            HStack(spacing: 6) {
                TextField(hasPreview ? "Change something…" : "Add to the request…", text: $imagine.followUp)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($followUpFocused)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(.white.opacity(0.1), in: Capsule())
                    .onSubmit { imagine.revise() }
                let revising = !imagine.followUp.trimmingCharacters(in: .whitespaces).isEmpty
                PillButton(symbol: "arrow.clockwise", title: revising ? "Revise" : "Again",
                           help: revising ? "Make a new version with this change" : "Make another preview") { imagine.revise() }
                if hasPreview {
                    PillButton(symbol: imagine.showsPreview ? "eye.slash" : "eye", title: nil,
                               help: imagine.showsPreview ? "Hide the preview to compare with the app" : "Show the preview") {
                        imagine.showsPreview.toggle()
                    }
                    PillButton(symbol: imagine.copied ? "checkmark" : "doc.on.doc", title: imagine.copied ? "Copied" : "Copy",
                               help: "Copy a screenshot of the preview with app context and implementation instructions for your coding AI") {
                        imagine.copy()
                    }
                    PillButton(symbol: "hammer", title: "Apply to Code", prominent: true,
                               help: imagine.project.map { "Have the agent change the code in \($0.lastPathComponent) to match" }
                                   ?? "Choose the app's project folder, and have the agent change its code to match") {
                        imagine.applyToCode()
                    }
                }
            }
        }
    }

    private var applied: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: imagine.problem == nil ? "sparkles" : "exclamationmark.triangle.fill")
                .foregroundStyle(imagine.problem == nil ? cyan : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                let detail = imagine.problem ?? imagine.agentMessage
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        .help(detail)
                }
            }
            Spacer(minLength: 8)
            if imagine.changes.isEmpty {
                PillButton(symbol: "xmark", title: "Dismiss", help: "Close") { imagine.keep() }
            } else {
                PillButton(symbol: "doc.text.magnifyingglass", title: nil, help: "Show the changes as a diff") { imagine.showDiff() }
                PillButton(symbol: "arrow.uturn.backward", title: "Discard", help: "Undo the code change and go back to the preview") { imagine.discard() }
                PillButton(symbol: "checkmark", title: "Keep", prominent: true, help: "Keep the changes in your project") { imagine.keep() }
            }
        }
    }

    private var summary: String {
        let files = imagine.changes.map { ($0.path as NSString).lastPathComponent }
        switch files.count {
        case 0: return "No change"
        case 1: return "Changed \(files[0])"
        default: return "Changed \(files[0]) and \(files.count - 1) more"
        }
    }

    private struct PillButton: View {
        let symbol: String
        let title: String?
        var prominent = false
        let help: String
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                    if let title { Text(title) }
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, title == nil ? 8 : 10)
                .frame(height: 26)
                .background(prominent ? cyan : Color.white.opacity(0.12), in: Capsule())
                .foregroundStyle(prominent ? Color.black : Color.white)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }
}

// MARK: - Settings

@MainActor
@Observable
final class ImagineSettingsModel {
    var connection: AgentConnection = Settings.imagineConnection {
        didSet { Settings.imagineConnection = connection; testResult = nil }
    }
    var command: String = Settings.imagineCommand {
        didSet { Settings.imagineCommand = command; testResult = nil }
    }
    var applyCommand: String = Settings.imagineApplyCommand {
        didSet { Settings.imagineApplyCommand = applyCommand }
    }
    var allowCommands: Bool = Settings.imagineAllowCommands {
        didSet { Settings.imagineAllowCommands = allowCommands }
    }
    private(set) var projects: [(key: String, path: String)] = []
    private(set) var testResult: String?
    private(set) var isTesting = false
    @ObservationIgnored private var probe: AgentRun?

    init() { reloadProjects() }

    var preset: AgentPreset? { AgentPreset.matching(connection: connection, command: command, applyCommand: applyCommand) }

    func apply(_ preset: AgentPreset) {
        connection = preset.connection
        command = preset.command
        applyCommand = preset.applyCommand
    }

    func reloadProjects() {
        projects = Settings.imagineProjects.map { (key: $0.key, path: $0.value) }.sorted { $0.key < $1.key }
    }

    func forget(_ key: String) {
        var all = Settings.imagineProjects
        all.removeValue(forKey: key)
        Settings.imagineProjects = all
        reloadProjects()
    }

    /// Checks that the command can be found, and for ACP that the agent answers.
    func test() {
        let program = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard !program.isEmpty else { testResult = "Enter a command."; return }
        isTesting = true
        testResult = nil
        let connection = self.connection
        Task {
            let found = await Task.detached { () -> String? in
                let out = try? Shell.run("/bin/zsh", ["-lc", "command -v \(program)"], environment: ["PATH": Shell.agentPath])
                let path = out?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return out?.status == 0 && !path.isEmpty ? path : nil
            }.value
            guard let found else {
                isTesting = false
                testResult = "✗ \(program) wasn't found."
                return
            }
            guard connection == .acp else {
                isTesting = false
                testResult = "✓ Found \(found)"
                return
            }
            let run = AgentRun(connection: .acp, command: command, allowCommands: false)
            probe = run
            run.onEnd = { [weak run] outcome in
                self.isTesting = false
                self.probe = nil
                switch outcome {
                case .finished: self.testResult = "✓ Connected to \(run?.agentName ?? "the agent")"
                case .failed(let message): self.testResult = "✗ \(message)"
                case .cancelled: self.testResult = "✗ The agent didn't answer within 20 seconds."
                }
            }
            run.probe(in: FileManager.default.homeDirectoryForCurrentUser)
            try? await Task.sleep(for: .seconds(20))
            if probe === run { run.cancel() }
        }
    }
}

struct ImagineSettingsView: View {
    @Bindable var model: ImagineSettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Agent", selection: Binding(
                    get: { model.preset?.id ?? "custom" },
                    set: { id in if let preset = AgentPreset.all.first(where: { $0.id == id }) { model.apply(preset) } }
                )) {
                    ForEach(AgentPreset.all) { Text("\($0.title) (\($0.connection.title))").tag($0.id) }
                    Text("Custom").tag("custom")
                }
                Picker("Connection", selection: $model.connection) {
                    ForEach(AgentConnection.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.connection == .cli ? "Preview command" : "Command")
                    commandEditor($model.command)
                    if model.connection == .cli {
                        Text("Apply to Code command").padding(.top, 4)
                        commandEditor($model.applyCommand)
                    }
                    Text(help).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if model.connection == .acp {
                    Toggle("Let the agent run terminal commands when applying to code", isOn: $model.allowCommands)
                    Text("The agent may always read the project and the screenshots. When applying to code, it may also edit files inside the project. Everything else it asks for is declined.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Test Connection") { model.test() }.disabled(model.isTesting)
                    if model.isTesting { ProgressView().controlSize(.small) }
                    if let result = model.testResult {
                        Text(result).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } header: {
                Text("Coding agent")
            }

            Section {
                if model.projects.isEmpty {
                    Text("None yet. Imagine works without them. Add an app's code from the Imagine panel, so previews match it and can be applied to it. Dev servers on localhost are found by themselves.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.projects, id: \.key) { project in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.key.replacingOccurrences(of: "web:", with: "").replacingOccurrences(of: "app:", with: ""))
                            Text((project.path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 11)).foregroundStyle(.secondary).truncationMode(.head)
                        }
                        .lineLimit(1)
                        Spacer()
                        Button("Forget") { model.forget(project.key) }.controlSize(.small)
                    }
                }
            } header: {
                Text("Project folders")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func commandEditor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12, design: .monospaced))
            .frame(height: 52)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private var help: String {
        switch model.connection {
        case .cli:
            "Both run in your login shell, in the app's project folder or else the screenshots' folder. They get the request in $DESKDRAW_PROMPT, the screenshots' folder in $DESKDRAW_ATTACHMENTS, their paths in $DESKDRAW_IMAGES, the working folder in $DESKDRAW_PROJECT, and $DESKDRAW_MODE (preview or apply). The preview command must not change files; it replies with the preview's HTML. The apply command must edit files without asking. Both exit when done. Stream JSON output from Claude Code or Antigravity shows progress."
        case .acp:
            "Starts an Agent Client Protocol server on stdin and stdout, such as “agy acp”. Desk Draw opens a session in the app's project folder, or else the screenshots' folder, and sends the request with the screenshots. It approves edits only when applying to code."
        }
    }
}

@MainActor
enum ImagineSettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let model = ImagineSettingsModel()
            let hosting = NSHostingController(rootView: ImagineSettingsView(model: model))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Imagine Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            window = w
            w.center()
        } else if let model = (window?.contentViewController as? NSHostingController<ImagineSettingsView>)?.rootView.model {
            model.reloadProjects()
        }
        // In front of the overlay when opened while drawing.
        window?.level = Imagine.shared.phase == .prompting ? Levels.alert : .normal
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
