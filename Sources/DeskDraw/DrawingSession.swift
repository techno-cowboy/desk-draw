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
    private var screenObserver: NSObjectProtocol?
    var onEnd: (() -> Void)?

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

        // Display layout changed: the overlay no longer fits, so stop.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
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
        NSCursor.arrow.set()
        // Hand focus back to the app the user was drawing on.
        NSApp.hide(nil)
        onEnd?()
    }

    func capture() {
        guard !isCapturing else { return }
        overlay?.canvas.commitText()
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                let saved = try await Capturer.capture(session: self)
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
}
