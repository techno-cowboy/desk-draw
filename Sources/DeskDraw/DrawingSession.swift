import AppKit

/// One drawing session: from the hotkey to Esc. Everything drawn lives only
/// here and is thrown away when the session ends.
@MainActor
final class DrawingSession {
    let state: DrawingState
    private(set) var context: SessionContext
    private var overlays: [OverlayWindow] = []
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
            self?.overlays.forEach { $0.canvas.needsDisplay = true }
        }

        let mouse = NSEvent.mouseLocation
        let mouseScreen = Geometry.screen(containing: mouse) ?? NSScreen.main ?? NSScreen.screens[0]
        overlays = NSScreen.screens.map { OverlayWindow(screen: $0, session: self) }
        overlays.forEach { $0.orderFrontRegardless() }

        let toolbar = ToolbarPanel(session: self, on: mouseScreen)
        toolbar.orderFrontRegardless()
        self.toolbar = toolbar

        NSApp.activate(ignoringOtherApps: true)
        if let main = overlays.first(where: { $0.frame.contains(mouse) }) ?? overlays.first {
            main.makeKey()
            main.makeFirstResponder(main.canvas)
            main.canvas.updateCursor()
        }

        // Display layout changed: the overlays no longer fit, so stop.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard !overlays.isEmpty else { return }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        overlays.forEach { $0.orderOut(nil); $0.close() }
        overlays = []
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
        overlays.forEach { $0.canvas.commitText() }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                let saved = try await Capturer.capture(session: self)
                overlays.forEach { $0.canvas.flash() }
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
