import AppKit
import Observation
import SwiftUI

// MARK: - Circled areas

extension Annotation {
    /// A mark that circles part of the screen: a rectangle, an ellipse, or a pen or
    /// highlighter loop that ends near where it started.
    var circlesArea: Bool {
        let r = shapeBounds
        guard !r.isNull, r.width >= 16, r.height >= 16 else { return false }
        switch tool {
        case .rectangle, .ellipse:
            return true
        case .pen, .highlighter:
            guard points.count >= 8, let first = points.first, let last = points.last else { return false }
            let gap = hypot(first.x - last.x, first.y - last.y)
            var length: CGFloat = 0
            for (a, b) in zip(points, points.dropFirst()) { length += hypot(b.x - a.x, b.y - a.y) }
            // Closed, and long enough to go around the box rather than across it.
            return gap <= max(40, 0.35 * max(r.width, r.height)) && length >= 1.2 * (r.width + r.height)
        default:
            return false
        }
    }

    /// The imagine box for a circling mark: its outline, with room for the stroke.
    var imagineBox: CGRect {
        let pad = effectiveLineWidth / 2 + 6
        return shapeBounds.insetBy(dx: -pad, dy: -pad).integral
    }
}

extension DrawingState {
    /// The mark Imagine would use: the selected one if it circles an area, else the most
    /// recent one that does. Never on the whiteboard, which has no app under it.
    var imagineCandidate: Annotation? {
        guard !whiteboard else { return nil }
        if let selection, selection.circlesArea { return selection }
        return annotations.last { $0.circlesArea }
    }

    /// Text written in or right next to `box`, top to bottom, to start the request with.
    func notes(near box: CGRect) -> String {
        let reach = box.insetBy(dx: -80, dy: -80)
        return annotations
            .filter { $0.tool == .text && $0.textRect.intersects(reach) }
            .sorted { $0.textRect.maxY > $1.textRect.maxY }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

// MARK: - Imagine

/// Circle part of any app and say what should change. A local coding agent replies with an
/// HTML preview of the area, which shows in place. Revise it, copy it, or, when the app's
/// code is at hand, have the agent apply it to the code, then keep or discard that change.
@MainActor
@Observable
final class Imagine {
    static let shared = Imagine()

    enum Phase: Equatable {
        case idle
        /// Asking what should change, while drawing.
        case prompting
        /// The agent is making a preview.
        case imagining
        /// Showing the preview.
        case preview
        /// The agent is changing the code to match the preview.
        case applying
        /// The code changed; the user keeps or discards it.
        case applied
    }

    private(set) var phase: Phase = .idle {
        didSet { updateBox() }
    }
    /// A preview is underway or on screen.
    var isBusy: Bool { phase != .idle && phase != .prompting }
    var isWorking: Bool { phase == .imagining || phase == .applying }

    // Prompt
    var request = ""
    /// The app's code, if known. The agent reads it to match the app; Apply uses it.
    private(set) var project: URL?
    private(set) var isFindingProject = false
    private(set) var isSending = false
    var promptError: String?
    private(set) var targetName = ""

    // Job
    private(set) var activity = ""
    private(set) var agentMessage = ""
    private(set) var startedAt = Date()
    /// The preview's HTML, and what the agent said about it.
    private(set) var snippet: String? {
        didSet { updateBox() }
    }
    private(set) var note = ""
    /// Hidden to compare with the app underneath.
    var showsPreview = true {
        didSet { updateBox() }
    }
    /// Whether the floating prompt/controls pill is currently shown. Closing the pill while
    /// a preview is on screen hides it and dims the border so the preview stays immersive.
    private(set) var isPillVisible = true {
        didSet { updateBox() }
    }
    /// True while the pointer is over the preview frame.
    private(set) var isHoveringBox = false {
        didSet { updateBox() }
    }
    /// Dimmed immersive state: a preview is showing with the prompt/controls pill hidden.
    var isDimmed: Bool { phase == .preview && snippet != nil && showsPreview && !isPillVisible }
    /// Whether the pill is positioned above the frame (updates dynamically as the frame moves).
    private(set) var pillAbove = true
    /// Incremented to focus the follow-up prompt input when reopening the pill.
    private(set) var focusFollowUpTrigger = 0
    /// What to change in the preview next.
    var followUp = ""
    private(set) var copied = false
    private(set) var changes: [Git.Change] = []
    /// Why the run didn't end with a preview or a change, or how it went wrong.
    private(set) var problem: String?

    var agentLabel: String {
        let connection = Settings.imagineConnection
        let name = AgentPreset.matching(connection: connection, command: Settings.imagineCommand,
                                        applyCommand: Settings.imagineApplyCommand)?.title ?? "Custom agent"
        return "\(name) · \(connection.title)"
    }

    @ObservationIgnored private weak var session: DrawingSession?
    @ObservationIgnored private var box: CGRect = .zero
    @ObservationIgnored private var originalBox: CGRect = .zero
    @ObservationIgnored private var screen: NSScreen?
    @ObservationIgnored private var projectKey = ""
    @ObservationIgnored private var promptPanel: ImaginePanel?
    @ObservationIgnored private var boxWindow: NSWindow?
    @ObservationIgnored private var dragView: ImagineDragView?
    @ObservationIgnored private var pillPanel: ImaginePanel?
    @ObservationIgnored private var preview: ImaginePreview?
    @ObservationIgnored private var run: AgentRun?
    @ObservationIgnored private var shot: Capturer.ImagineShot?
    @ObservationIgnored private var asked = ""
    @ObservationIgnored private var revisions: [String] = []
    @ObservationIgnored private var attachments: URL?
    @ObservationIgnored private var pages = 0
    @ObservationIgnored private var repo: URL?
    @ObservationIgnored private var before: String?
    @ObservationIgnored private var after: String?
    @ObservationIgnored private var guessTask: Task<Void, Never>?
    @ObservationIgnored private var isCopying = false

    // MARK: Prompt

    func openPrompt(session: DrawingSession, box: CGRect, note: String) {
        guard phase == .idle || phase == .prompting else { return }
        closePromptPanel()
        self.session = session
        self.box = box
        self.originalBox = box
        screen = session.screen
        request = note
        promptError = nil
        isSending = false
        phase = .prompting

        // Which app this is, and where its code might be.
        let context = session.context
        let window = context.contextWindow(for: box)
        let app = window?.app ?? context.frontApp
        let sameAppAsFront = window == nil || window?.pid == context.frontApp?.processIdentifier
        let tab: BrowserTab? = if sameAppAsFront, let existing = context.browserTab {
            existing
        } else if let app, Settings.browserURL {
            Browser.currentTab(of: app)
        } else {
            nil
        }
        let tabURL = tab?.url
        let appName = app?.localizedName ?? window?.ownerName ?? "this app"
        targetName = tabURL.flatMap(ProjectLocator.localOrigin) ?? appName
        projectKey = ProjectLocator.key(app: app, appName: appName, tabURL: tabURL)
        project = Settings.imagineProjects[projectKey].map { URL(fileURLWithPath: $0, isDirectory: true) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        if project == nil {
            isFindingProject = true
            let port = tabURL.flatMap(ProjectLocator.localPort)
            let executable = app?.executableURL
            guessTask = Task { [weak self] in
                let guess = await Task.detached { ProjectLocator.guess(port: port, executable: executable) }.value
                guard let self, !Task.isCancelled, self.phase == .prompting else { return }
                self.isFindingProject = false
                if self.project == nil { self.project = guess }
            }
        }

        let panel = ImaginePanel(size: CGSize(width: 420, height: 196), activates: true)
        panel.level = Levels.alert
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: ImaginePromptView(imagine: self))
        place(panel, near: box, on: screen)
        promptPanel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// Updates the Imagine box while prompting (when the user drags it on the overlay).
    func updatePromptBox(_ newBox: CGRect) {
        guard phase == .prompting else { return }
        box = newBox
        originalBox = newBox
        if let promptPanel { place(promptPanel, near: newBox, on: screen) }
    }

    func cancelPrompt() {
        guard phase == .prompting, !isSending else { return }
        phase = .idle
        closePromptPanel()
        session?.imaginePromptClosed()
    }

    /// The drawing ended some other way, such as the hotkey.
    func sessionDidEnd(_ ended: DrawingSession) {
        guard phase == .prompting, session === ended else { return }
        phase = .idle
        closePromptPanel()
    }

    private func closePromptPanel() {
        guessTask?.cancel()
        guessTask = nil
        isFindingProject = false
        promptPanel?.orderOut(nil)
        promptPanel?.close()
        promptPanel = nil
    }

    func chooseProject() {
        if let url = pickFolder() {
            project = url
            isFindingProject = false
            promptError = nil
            remember(url)
        }
        promptPanel?.makeKey()
    }

    /// Works from the screenshots alone this time, and forgets the folder for this app.
    func clearProject() {
        guessTask?.cancel()
        isFindingProject = false
        project = nil
        var projects = Settings.imagineProjects
        projects.removeValue(forKey: projectKey)
        Settings.imagineProjects = projects
    }

    private func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose the project folder with the code of \(targetName)."
        if let project { panel.directoryURL = project }
        // Above the overlay and Imagine's windows, like Desk Draw's other questions.
        RunLoop.current.perform(inModes: [.modalPanel]) {
            panel.level = Levels.alert + 1
            panel.orderFrontRegardless()
        }
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func remember(_ folder: URL) {
        var projects = Settings.imagineProjects
        projects[projectKey] = folder.path
        Settings.imagineProjects = projects
    }

    func send() {
        guard phase == .prompting, !isSending, let session else { return }
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { promptError = "Say what should change."; return }
        isSending = true
        promptError = nil
        let box = self.box
        Task {
            do {
                let shot = try await Capturer.imagineShot(session: session, box: box)
                let folder = try Self.writeAttachments(shot)
                if let project { remember(project) }
                self.shot = shot
                asked = text
                revisions = []
                attachments = folder
                pages = 0
                snippet = nil
                note = ""
                followUp = ""
                showsPreview = true
                isPillVisible = true
                isHoveringBox = false
                isSending = false
                closePromptPanel()
                // Stop drawing, so the preview and the app can be seen and compared.
                session.end()
                imagine(change: nil)
            } catch {
                isSending = false
                promptError = (error as? CaptureError)?.message ?? error.localizedDescription
            }
        }
    }

    // MARK: Preview

    /// Asks for a preview; with `change`, for a new version of the current one.
    private func imagine(change: String?) {
        guard let shot, let attachments else { return closeJob() }
        let prompt = Self.previewPrompt(request: asked, shot: shot, box: box.size, folder: attachments, project: project,
                                        previous: change == nil ? nil : snippet, change: change)
        let request = AgentRequest(project: project ?? attachments, prompt: prompt, mayEdit: false,
                                   attachments: attachments, images: Self.images(in: attachments))
        begin(.imagining, request, command: Settings.imagineCommand)
    }

    /// A new version of the preview, changed as the user says; or another take without.
    func revise() {
        guard phase == .preview, !isSending else { return }
        let change = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        if snippet == nil, !change.isEmpty {
            // No preview to change yet: the words add to the request.
            asked += "\n\(change)"
            followUp = ""
            return imagine(change: nil)
        }
        if !change.isEmpty { revisions.append(change) }
        imagine(change: change.isEmpty ? nil : change)
    }

    /// Captures a screenshot of the implemented preview change, reads live app/browser context,
    /// saves the PNG to the screenshots folder, and copies both the screenshot and full
    /// implementation instructions for the project's coding AI to the clipboard.
    func copy() {
        guard let snippet, let shot, !isCopying else { return }
        isCopying = true
        let requestText = fullRequest
        let noteText = note
        let projectFolder = project
        let boxSize = box.size
        Task {
            defer { isCopying = false }
            let liveTab: BrowserTab? = if let app = shot.app, Browser.isSupported(app), Settings.browserURL {
                Browser.currentTab(of: app)
            } else {
                nil
            }
            let tabURL = liveTab?.url ?? shot.tabURL
            let tabTitle = liveTab?.title ?? shot.tabTitle
            let previewImage = await preview?.snapshotImage()
            let now = Date()
            let composite = Capturer.composeImaginePreview(
                shot: shot, preview: previewImage, tabURL: tabURL, tabTitle: tabTitle,
                includeCaption: Settings.caption, date: now
            )
            let saved = composite.map {
                Capturer.saveImaginePreview($0, shot: shot, tabURL: tabURL, tabTitle: tabTitle, date: now)
            }
            let text = Self.handoff(
                request: requestText, shot: shot, box: boxSize, html: snippet, note: noteText,
                project: projectFolder, tabURL: tabURL, tabTitle: tabTitle, screenshot: saved?.url
            )
            Self.writeToPasteboard(.general, text: text, png: saved?.png, image: composite)
            copied = true
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// Writes both the handoff instructions text and preview screenshot image to `pasteboard`.
    static func writeToPasteboard(_ pasteboard: NSPasteboard, text: String, png: Data?, image: CGImage?) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if let png { item.setData(png, forType: .png) }
        if let image, let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// The initial request plus any follow-up revisions the user made.
    private var fullRequest: String {
        guard !revisions.isEmpty else { return asked }
        let steps = revisions.map { "- \($0)" }.joined(separator: "\n")
        return "\(asked)\n\nFollow-up refinements:\n\(steps)"
    }

    /// Hides the prompt/controls window while keeping the preview on screen with a dimmed border.
    func hidePill() {
        guard phase == .preview, snippet != nil else { return close() }
        showsPreview = true
        isPillVisible = false
        pillPanel?.orderOut(nil)
    }

    /// Shows the prompt/controls window next to the Imagine frame and optionally focuses its input.
    func showPill(focusInput: Bool = true) {
        guard isBusy else { return }
        isPillVisible = true
        isHoveringBox = false
        if let pillPanel {
            pillAbove = place(pillPanel, near: box, on: screen)
            pillPanel.orderFrontRegardless()
            if focusInput {
                NSApp.activate()
                pillPanel.makeKey()
                focusFollowUpTrigger += 1
            }
        }
    }

    /// Moves the floating Imagine frame (and its pill, when shown) to a new global origin.
    func moveBox(to origin: CGPoint) {
        let moved = CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: box.size)
        box = moved
        screen = Geometry.screen(containing: CGPoint(x: moved.midX, y: moved.midY)) ?? screen
        boxWindow?.setFrameOrigin(CGPoint(x: moved.minX - 3, y: moved.minY - 3))
        if isPillVisible, let pillPanel {
            pillAbove = place(pillPanel, near: moved, on: screen)
        }
    }

    /// Returns the floating Imagine frame to where the user originally circled.
    func resetBoxPosition() {
        guard box != originalBox else { return }
        moveBox(to: originalBox.origin)
    }

    func setHoveringBox(_ hovering: Bool) {
        guard isHoveringBox != hovering else { return }
        isHoveringBox = hovering
    }

    private func showPreview(_ reply: PreviewSnippet.Reply) {
        guard let attachments else { return }
        pages += 1
        // A new name each time, so the web view never shows an old version.
        let page = attachments.appendingPathComponent("preview-\(pages).html")
        let html = PreviewSnippet.document(reply.html, size: box.size)
        do {
            try html.write(to: page, atomically: true, encoding: .utf8)
        } catch {
            problem = "Couldn't show the preview: \(error.localizedDescription)"
            return
        }
        snippet = reply.html
        note = reply.note
        followUp = ""
        showsPreview = true
        preview?.show(page)
    }

    // MARK: Apply

    /// Has the agent change the app's code to match the preview.
    func applyToCode() {
        guard phase == .preview, !isSending, let snippet, let shot, let attachments else { return }
        problem = nil
        guard let folder = project ?? pickFolder() else { return }
        guard let root = Git.topLevel(of: folder) else {
            problem = "\(folder.lastPathComponent) isn't a git repository. Imagine uses git to undo changes."
            return
        }
        project = folder
        remember(folder)
        isSending = true
        Task {
            defer { isSending = false }
            let shown = attachments.appendingPathComponent("preview.png")
            if let png = await preview?.snapshot() { try? png.write(to: shown) }
            let html = attachments.appendingPathComponent("preview.html")
            try? PreviewSnippet.document(snippet, size: box.size).write(to: html, atomically: true, encoding: .utf8)
            let snapshot: String
            do {
                snapshot = try await Task.detached { try Git.snapshot(root) }.value
            } catch {
                problem = "Couldn't take a git snapshot: \(error.localizedDescription)"
                return
            }
            guard phase == .preview, self.attachments == attachments else { return }
            before = snapshot
            repo = root
            after = nil
            changes = []
            let hasShot = FileManager.default.fileExists(atPath: shown.path)
            let prompt = Self.applyPrompt(request: fullRequest, shot: shot, folder: attachments,
                                          rendered: hasShot ? shown : nil, html: html)
            let request = AgentRequest(project: root, prompt: prompt, mayEdit: true, attachments: attachments,
                                       images: Self.images(in: attachments) + (hasShot ? [shown] : []))
            let command = Settings.imagineConnection == .acp ? Settings.imagineCommand : Settings.imagineApplyCommand
            begin(.applying, request, command: command)
        }
    }

    func keep() {
        guard phase == .applied else { return }
        closeJob()
    }

    /// Undoes the agent's code changes and goes back to the preview.
    func discard() {
        guard phase == .applied, let repo, let before else { return backToPreview() }
        let changes = self.changes
        Task {
            do {
                try await Task.detached { try Git.revert(changes, in: repo, to: before) }.value
                backToPreview()
            } catch {
                problem = "Couldn't undo the change: \(error.localizedDescription)"
            }
        }
    }

    private func backToPreview() {
        changes = []
        repo = nil
        before = nil
        after = nil
        problem = nil
        agentMessage = ""
        phase = snippet == nil ? .idle : .preview
        if phase == .idle { closeJob() }
    }

    func showDiff() {
        guard let repo, let before, let attachments else { return }
        let after = self.after
        Task {
            let text = await Task.detached { () -> String in
                let target = after ?? (try? Git.snapshot(repo))
                guard let target else { return "" }
                return (try? Git.diff(in: repo, from: before, to: target)) ?? ""
            }.value
            let url = attachments.appendingPathComponent("changes.diff")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            if !NSWorkspace.shared.open(url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    // MARK: Running

    private func begin(_ phase: Phase, _ request: AgentRequest, command: String) {
        activity = "Starting \(agentLabel)…"
        agentMessage = ""
        problem = nil
        startedAt = Date()
        isPillVisible = true
        isHoveringBox = false
        self.phase = phase
        showJobWindows()
        if let pillPanel {
            pillAbove = place(pillPanel, near: box, on: screen)
            pillPanel.orderFrontRegardless()
        }

        let run = AgentRun(connection: Settings.imagineConnection, command: command,
                           allowCommands: Settings.imagineAllowCommands)
        run.onActivity = { [weak self] in self?.activity = $0 }
        run.onMessage = { [weak self] in self?.agentMessage = $0 }
        run.onEnd = { [weak self] outcome in
            guard let self else { return }
            if phase == .applying { self.applyEnded(outcome) } else { self.previewEnded(outcome) }
        }
        self.run = run
        run.start(request)
    }

    func stop() {
        run?.cancel()
    }

    func close() {
        closeJob()
    }

    private func previewEnded(_ outcome: AgentRun.Outcome) {
        run = nil
        switch outcome {
        case .finished:
            if let reply = PreviewSnippet.extract(from: agentMessage) {
                showPreview(reply)
            } else {
                problem = agentMessage.isEmpty ? "The agent didn't reply with a preview."
                    : "No preview in the reply: \(agentMessage.prefix(300))"
            }
        case .cancelled:
            // Back to the last preview, if there is one.
            if snippet == nil { return closeJob() }
        case .failed(let message):
            problem = message
        }
        phase = .preview
    }

    private func applyEnded(_ outcome: AgentRun.Outcome) {
        run = nil
        guard let repo, let before else { return backToPreview() }
        Task {
            let result = await Task.detached { () -> (String, [Git.Change])? in
                guard let after = try? Git.snapshot(repo),
                      let changes = try? Git.changes(in: repo, from: before, to: after) else { return nil }
                return (after, changes)
            }.value
            after = result?.0
            changes = result?.1 ?? []
            switch outcome {
            case .finished:
                problem = changes.isEmpty ? "The agent didn't change any files." : nil
            case .cancelled:
                if changes.isEmpty { return backToPreview() }
                problem = "Stopped. Some files were already changed."
            case .failed(let message):
                problem = message
            }
            if changes.isEmpty, snippet != nil {
                // Nothing to keep or discard; the preview is still there.
                let problem = self.problem
                backToPreview()
                self.problem = problem
                return
            }
            phase = .applied
        }
    }

    private func closeJob() {
        run?.cancel()
        run = nil
        boxWindow?.orderOut(nil)
        boxWindow?.close()
        boxWindow = nil
        dragView = nil
        pillPanel?.orderOut(nil)
        pillPanel?.close()
        pillPanel = nil
        preview?.clear()
        preview = nil
        if let attachments { try? FileManager.default.removeItem(at: attachments) }
        attachments = nil
        shot = nil
        revisions = []
        snippet = nil
        note = ""
        followUp = ""
        isPillVisible = true
        isHoveringBox = false
        repo = nil
        before = nil
        after = nil
        changes = []
        problem = nil
        phase = .idle
    }

    // MARK: Windows

    private func showJobWindows() {
        guard boxWindow == nil else { return updateBox() }
        let frame = box.insetBy(dx: -3, dy: -3)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.canHide = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        let frameView = NSHostingView(rootView: ImagineBoxView(imagine: self))
        frameView.frame = container.bounds
        frameView.autoresizingMask = [.width, .height]
        container.addSubview(frameView)
        let preview = ImaginePreview()
        preview.webView.frame = container.bounds.insetBy(dx: 3, dy: 3)
        preview.webView.autoresizingMask = [.width, .height]
        container.addSubview(preview.webView)
        let dragView = ImagineDragView(frame: container.bounds)
        dragView.autoresizingMask = [.width, .height]
        dragView.onDragStart = { [weak self] in self?.box.origin ?? .zero }
        dragView.onDragTo = { [weak self] origin in self?.moveBox(to: origin) }
        dragView.onDoubleClick = { [weak self] in self?.resetBoxPosition() }
        dragView.onHover = { [weak self] hovering in self?.setHoveringBox(hovering) }
        dragView.onImagineClick = { [weak self] in self?.showPill(focusInput: true) }
        container.addSubview(dragView)
        self.dragView = dragView
        self.preview = preview
        window.contentView = container
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        boxWindow = window

        let pill = ImaginePanel(size: CGSize(width: 560, height: 132), activates: false)
        pill.level = .floating
        pill.canHide = false
        pill.isMovableByWindowBackground = true
        pillAbove = place(pill, near: box, on: screen)
        pill.contentView = FirstClickHostingView(rootView: ImaginePillView(imagine: self))
        pill.orderFrontRegardless()
        pillPanel = pill
        updateBox()
    }

    /// The preview shows while there is one to look at. The frame accepts mouse events for
    /// dragging (and hover-to-reopen when dimmed) while imagining or showing a preview; when
    /// hidden or applying/applied, clicks pass through to the app underneath.
    private func updateBox() {
        let showing = phase == .preview && snippet != nil && showsPreview
        let movable = showing || phase == .imagining
        preview?.webView.isHidden = !showing
        dragView?.isHidden = !movable
        dragView?.setChipVisible(isDimmed && isHoveringBox)
        boxWindow?.ignoresMouseEvents = !movable
    }

    /// Puts `panel` centered above `box`, or below it when there is no room. Returns
    /// whether it went above.
    @discardableResult
    private func place(_ panel: NSWindow, near box: CGRect, on screen: NSScreen?) -> Bool {
        let size = panel.frame.size
        let visible = (screen ?? Geometry.screen(containing: CGPoint(x: box.midX, y: box.midY)) ?? NSScreen.screens[0]).visibleFrame
        var origin = CGPoint(x: box.midX - size.width / 2, y: box.maxY + 6)
        var above = true
        if origin.y + size.height > visible.maxY {
            origin.y = box.minY - 6 - size.height
            above = false
            if origin.y < visible.minY { origin.y = visible.maxY - size.height; above = true }
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(CGPoint(x: origin.x.rounded(), y: origin.y.rounded()))
        return above
    }

    // MARK: Requests

    /// Longest side of the screenshots the agent gets, in pixels.
    static let markedMaxSide = 2400
    static let areaMaxSide = 1600

    private static func writeAttachments(_ shot: Capturer.ImagineShot) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Desk Draw Imagine", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, image) in [("marked.png", shot.marked.limited(to: markedMaxSide)), ("area.png", shot.area.limited(to: areaMaxSide))] {
            guard let png = Capturer.pngData(image, scale: 1, title: name, description: "Desk Draw Imagine") else {
                throw CaptureError(message: "Could not encode the screenshot.")
            }
            try png.write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    private static func images(in folder: URL) -> [URL] {
        [folder.appendingPathComponent("marked.png"), folder.appendingPathComponent("area.png")]
    }

    /// The app, the screenshots and the marks, for both kinds of request.
    private static func whereLines(shot: Capturer.ImagineShot, folder: URL) -> String {
        var lines = ["- App: \(shot.appName)\(shot.app?.bundleIdentifier.map { " (\($0))" } ?? "")"]
        if let title = shot.windowTitle { lines.append("- Window: \(title)") }
        if let url = shot.tabURL { lines.append("- Page: \(url)") }
        // Positions in the saved image, which may be smaller than the capture.
        let f = min(1, Double(markedMaxSide) / Double(max(shot.marked.width, shot.marked.height, 1)))
        let b = shot.boxInImage
        let marks = shot.marks.map { m in
            let text = m.text.map { " saying “\($0)”" } ?? ""
            return "  - \(m.color) \(m.kind)\(text) at x=\(Int(m.rect.x * f)) y=\(Int(m.rect.y * f)) w=\(Int(m.rect.width * f)) h=\(Int(m.rect.height * f))"
        }
        lines.append("""
        - Screenshot of the window with my marks: \(folder.appendingPathComponent("marked.png").path)
          The cyan box (x=\(Int(b.minX * f)) y=\(Int(b.minY * f)) w=\(Int(b.width * f)) h=\(Int(b.height * f)) px) is the area.
        - The area alone, without marks, as it looks now: \(folder.appendingPathComponent("area.png").path)
        - My marks, in screenshot pixels:
        \(marks.isEmpty ? "  - none" : marks.joined(separator: "\n"))
        """)
        return lines.joined(separator: "\n")
    }

    static func previewPrompt(request: String, shot: Capturer.ImagineShot, box: CGSize, folder: URL, project: URL?,
                              previous: String?, change: String?) -> String {
        let w = Int(box.width.rounded()), h = Int(box.height.rounded())
        let f = min(1, Double(areaMaxSide) / Double(max(shot.area.width, shot.area.height, 1)))
        let aw = Int((Double(shot.area.width) * f).rounded()), ah = Int((Double(shot.area.height) * f).rounded())
        let code = project.map { "- The app's code is in \($0.path). Read it to match the app's real colors, fonts, spacing, text and components, but don't change anything there." }
            ?? "- I don't have the app's code at hand. Work from the screenshots."
        var prompt = """
        I'm looking at an app on my screen and want to see what a change would look like before anyone changes the real app. I circled the part on screen. Make a preview: HTML and CSS that show the circled area as it would look with the change. Desk Draw shows your preview on top of the app, exactly over that area.

        What I want:
        \(request)

        Where:
        \(whereLines(shot: shot, folder: folder))
        \(code)

        How:
        - Look at both screenshots first (open them with your file reading tool if they aren't attached).
        - Rebuild the area as it looks now, as faithfully as you can: same layout, sizes, spacing, colors, fonts and text. Then change only what I asked for.
        - The preview is exactly \(w)×\(h) CSS pixels, one CSS pixel per screen point. Fill all of it; nothing behind it shows through.
        - HTML and CSS only. No JavaScript, and nothing from the network: no web fonts, remote images, stylesheets or scripts. Use system fonts (-apple-system, system-ui) unless the app clearly uses another font that's installed on a Mac. Draw icons with inline SVG.
        - area.png sits next to your HTML, so you may use it (src="area.png" or url(area.png)) for parts that stay the same. It's \(aw)×\(ah) pixels; scale it to \(w)×\(h) with CSS.
        - Don't create, change or delete any files, and don't run commands. Your reply is the preview.
        - Reply with one short sentence saying what the preview shows, then the complete HTML document in a single ```html code block, and nothing after it.
        """
        if let previous, let change {
            prompt += """


            Your last preview was:
            ```html
            \(previous)
            ```

            Change it like this: \(change)
            Reply the same way, with the complete new HTML.
            """
        }
        return prompt
    }

    static func applyPrompt(request: String, shot: Capturer.ImagineShot, folder: URL, rendered: URL?, html: URL) -> String {
        """
        I'm looking at my running app. I circled part of it, asked for a change, and liked the preview of it. Now make the real change in this project's source code, so the app looks like the preview.

        What I asked for:
        \(request)

        Where:
        \(whereLines(shot: shot, folder: folder))
        \(rendered.map { "- The preview, as it showed on screen: \($0.path)\n" } ?? "")- The preview's HTML: \(html.path)
          It's a mock-up of the area, not code to paste in. Make the app look like it, using the app's own code, components and styles.

        How:
        - Look at the screenshots and the preview first (open them with your file reading tool if they aren't attached).
        - Find the code that draws the circled part and change it. Keep the change small and limited to what the preview shows; don't refactor or touch unrelated code.
        - Don't start, build, restart or install anything, don't run git commands, and don't commit. If the app needs a rebuild to show the change, say so.
        - When you're done, reply with one or two plain sentences saying what you changed.
        """
    }

    /// What Copy puts on the clipboard: full app/browser context, saved preview screenshot
    /// path, instructions to implement using the project's design system and guardrails, and
    /// the reference preview HTML/CSS.
    static func handoff(
        request: String, shot: Capturer.ImagineShot, box: CGSize, html: String,
        note: String = "", project: URL? = nil, tabURL: String? = nil, tabTitle: String? = nil,
        screenshot: URL? = nil
    ) -> String {
        let w = Int(box.width.rounded()), h = Int(box.height.rounded())
        let resolvedURL = tabURL ?? shot.tabURL
        let resolvedTabTitle = tabTitle ?? shot.tabTitle
        var contextLines = ["- App: \(shot.appName)\(shot.app?.bundleIdentifier.map { " (\($0))" } ?? "")"]
        if let title = shot.windowTitle, !title.isEmpty { contextLines.append("- Window: \(title)") }
        if let resolvedTabTitle, !resolvedTabTitle.isEmpty, resolvedTabTitle != shot.windowTitle {
            contextLines.append("- Browser Tab: \(resolvedTabTitle)")
        }
        if let resolvedURL, !resolvedURL.isEmpty { contextLines.append("- URL: \(resolvedURL)") }
        if let project { contextLines.append("- Project: \(project.path)") }
        contextLines.append("- Preview Area: \(w)×\(h) pt")
        if let screenshot { contextLines.append("- Preview Screenshot: \(screenshot.path)") }

        var sections: [String] = [
            "Implement this UI change in the real project based on the Desk Draw Imagine preview.",
            "## Request\n\(request)",
            "## App Context\n\(contextLines.joined(separator: "\n"))",
        ]
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("## Preview Summary\n\(note)")
        }
        sections.append("""
        ## Instructions for Implementation
        - Inspect the preview screenshot (attached / at the path above) and the reference HTML/CSS below to understand the intended visual change.
        - Treat the HTML/CSS strictly as a visual mock-up—do not copy or paste it verbatim into the codebase.
        - Implement the change using the project's existing design system and UI primitives (components, design tokens, theme variables, spacing, typography, colors, icons, light/dark mode, and accessibility conventions).
        - Follow all project guardrails and conventions (e.g., AGENTS.md, CLAUDE.md, architecture boundaries, lint/type rules, state management, and responsive/interactive behavior).
        - Keep the change focused on the targeted UI area; avoid refactoring unrelated code.
        """)
        sections.append("""
        ## Reference Preview HTML/CSS (\(w)×\(h) pt)
        ```html
        \(html)
        ```
        """)
        return sections.joined(separator: "\n\n")
    }
}

/// Transparent overlay on the floating Imagine frame: drags move the frame on first click
/// (double-click returns it to where it started), tracks hover, and displays the `✦ Imagine`
/// button when the prompt pill is hidden so the user can reopen it.
final class ImagineDragView: NSView {
    var onDragStart: (() -> CGPoint)?
    var onDragTo: ((CGPoint) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onImagineClick: (() -> Void)?

    private var dragStartMouse: CGPoint?
    private var dragStartOrigin: CGPoint?
    private var didDrag = false
    private let chipButton = ImagineChipButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        chipButton.isHidden = true
        chipButton.alphaValue = 0
        chipButton.onClick = { [weak self] in self?.onImagineClick?() }
        addSubview(chipButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let compact = bounds.width < 108
        chipButton.compact = compact
        let size = CGSize(width: compact ? 36 : 94, height: 26)
        let pad: CGFloat = 8
        let x = bounds.width >= size.width + pad * 2 ? bounds.maxX - size.width - pad : (bounds.width - size.width) / 2
        let y = bounds.height >= size.height + pad * 2 ? bounds.maxY - size.height - pad : (bounds.height - size.height) / 2
        chipButton.frame = CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
    }

    func setChipVisible(_ visible: Bool) {
        if visible {
            needsLayout = true
            chipButton.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                chipButton.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                chipButton.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    if self?.chipButton.alphaValue == 0 { self?.chipButton.isHidden = true }
                }
            })
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragStartMouse = nil
            onDoubleClick?()
            return
        }
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = onDragStart?()
        didDrag = false
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse = dragStartMouse, let startOrigin = dragStartOrigin else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - startMouse.x
        let dy = current.y - startMouse.y
        if !didDrag, hypot(dx, dy) < 2 { return }
        didDrag = true
        onDragTo?(CGPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if dragStartMouse != nil {
            dragStartMouse = nil
            dragStartOrigin = nil
            NSCursor.openHand.set()
        }
    }
}

/// Sleek hover chip (`✦ Imagine`) shown over a dimmed preview frame to bring back the prompt input.
private final class ImagineChipButton: NSView {
    var onClick: (() -> Void)?
    var compact = false { didSet { if compact != oldValue { needsDisplay = true } } }
    private var pressed = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Show Imagine prompt and controls"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor(white: pressed ? 0.18 : 0.08, alpha: 0.90).setFill()
        shape.fill()
        Capturer.imagineBoxColor.withAlphaComponent(0.9).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let text = compact ? "✦" : "✦ Imagine"
        let title = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        title.addAttribute(.foregroundColor, value: Capturer.imagineBoxColor, range: NSRange(location: 0, length: 1))
        let size = title.size()
        title.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onClick?() }
    }
}

/// A borderless panel for Imagine's prompt and status. The status panel doesn't activate
/// Desk Draw, so the app being changed stays in front.
final class ImaginePanel: NSPanel {
    init(size: CGSize, activates: Bool) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: activates ? [.borderless] : [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        becomesKeyOnlyIfNeeded = !activates
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Buttons respond to the first click, even while another app is active.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
