import AppKit

/// One drawing session: from the hotkey to Esc. Everything drawn lives only
/// here and is thrown away when the session ends.
@MainActor
final class DrawingSession {
    let state: DrawingState
    private(set) var context: SessionContext
    private(set) var screen: NSScreen?
    private var overlay: OverlayWindow?
    private var toolbar: ToolbarPanel?
    private var isCapturing = false
    private var isConfirming = false
    private var screenObserver: NSObjectProtocol?
    /// The display's frame and pixel scale when the session started, which the whiteboard keeps.
    private var boardFrame: CGRect = .zero
    private var boardScale: CGFloat = 2
    private var boardDisplay = ""
    /// `state.revision` when the whiteboard was last saved.
    private var savedRevision: Int?
    var onEnd: (() -> Void)?

    enum DiscardChoice { case save, discard, cancel }
    /// Asks whether to throw away an unsaved whiteboard. Tests replace it.
    var confirmDiscard: () -> DiscardChoice = DrawingSession.askToDiscard

    init(state: DrawingState) {
        self.state = state
        context = SessionContext.snapshot(includeBrowser: Settings.browserURL)
    }

    func start() {
        state.reset()
        state.onChange = { [weak self] in
            self?.overlay?.canvas.needsDisplay = true
        }

        let mouse = NSEvent.mouseLocation
        let mouseScreen = Geometry.screen(containing: mouse) ?? NSScreen.main ?? NSScreen.screens[0]
        screen = mouseScreen
        boardFrame = mouseScreen.frame
        boardScale = mouseScreen.backingScaleFactor
        boardDisplay = mouseScreen.localizedName
        let overlay = OverlayWindow(screen: mouseScreen, session: self)
        self.overlay = overlay
        overlay.orderFrontRegardless()

        let toolbar = ToolbarPanel(session: self, on: mouseScreen)
        toolbar.orderFrontRegardless()
        self.toolbar = toolbar

        NSApp.activate(ignoringOtherApps: true)
        overlay.makeKey()
        overlay.makeFirstResponder(overlay.canvas)
        overlay.canvas.updateCursor()

        // Display layout changed: the overlay no longer fits, so stop. An unsaved
        // whiteboard is saved first, because there is no time to ask.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.hasUnsavedWhiteboard { _ = try? self.saveWhiteboard() }
                self.end()
            }
        }
    }

    /// The whiteboard is on and has marks that were changed since it was last saved.
    var hasUnsavedWhiteboard: Bool {
        state.whiteboard && !state.annotations.isEmpty && savedRevision != state.revision
    }

    /// Stops drawing, as Esc, the close button, the hotkey and Quit do. An unsaved
    /// whiteboard is only discarded after the user agrees. Returns whether the session
    /// ended. Everything happens before it returns, which Quit relies on.
    @discardableResult
    func requestEnd() -> Bool {
        guard !isConfirming else { return false }
        overlay?.canvas.commitText()
        guard hasUnsavedWhiteboard else {
            end()
            return true
        }
        isConfirming = true
        let choice = confirmDiscard()
        isConfirming = false
        overlay?.makeKey()
        overlay?.canvas.updateCursor()
        switch choice {
        case .save:
            do {
                _ = try saveWhiteboard()
            } catch {
                state.showToast((error as? CaptureError)?.message ?? "Save failed: \(error.localizedDescription)", seconds: 6)
                return false
            }
            end()
            return true
        case .discard:
            end()
            return true
        case .cancel:
            return false
        }
    }

    func end() {
        guard let overlay else { return }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        overlay.orderOut(nil)
        overlay.close()
        self.overlay = nil
        screen = nil
        toolbar?.orderOut(nil)
        toolbar?.close()
        toolbar = nil
        state.onChange = nil
        state.reset()
        savedRevision = nil
        NSCursor.arrow.set()
        // Hand focus back to the app the user was drawing on.
        NSApp.hide(nil)
        onEnd?()
    }

    /// Saves a screenshot, or the whiteboard while it is on.
    func capture() {
        guard !isCapturing else { return }
        overlay?.canvas.commitText()
        isCapturing = true
        let whiteboard = state.whiteboard
        Task {
            defer { isCapturing = false }
            do {
                let saved = whiteboard ? try saveWhiteboard() : try await Capturer.capture(session: self)
                overlay?.canvas.flash()
                let copied = Settings.clipboard ? " · copied to clipboard" : ""
                state.showToast("Saved “\(saved.lastPathComponent)”\(copied)", seconds: 4)
            } catch let error as CaptureError {
                state.showToast(error.message, seconds: 6)
            } catch {
                state.showToast("Capture failed: \(error.localizedDescription)", seconds: 6)
            }
        }
    }

    private func saveWhiteboard() throws -> URL {
        let revision = state.revision
        let url = try Capturer.saveWhiteboard(annotations: state.annotations, frame: boardFrame,
                                              scale: boardScale, display: boardDisplay)
        savedRevision = revision
        return url
    }

    private static func askToDiscard() -> DiscardChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard the whiteboard?"
        alert.informativeText = "Your whiteboard drawing hasn't been saved. If you close it now, it's gone."
        alert.addButton(withTitle: "Save and Close")
        let discard = alert.addButton(withTitle: "Discard")
        discard.hasDestructiveAction = true
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        // Above the overlay and the toolbar, which would otherwise hide it.
        alert.window.level = Levels.alert
        NSCursor.arrow.set()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
}
