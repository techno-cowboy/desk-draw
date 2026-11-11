import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = DrawingState()
    private var session: DrawingSession?
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private let updater = AppUpdater()

    static let hotKeyLabel = "⌥⇧D"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        NSApp.mainMenu = makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "Desk Draw")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updater.isDrawing = { [weak self] in self?.session != nil }
        updater.start()

        hotKey = HotKey(keyCode: kVK_ANSI_D, modifiers: optionKey | shiftKey) { [weak self] in
            self?.toggleDrawing()
        }
        if hotKey == nil {
            NSLog("Desk Draw: could not register \(Self.hotKeyLabel); another app may own it.")
        }

        // Ask up front, not mid-drawing, where the overlay would cover the prompt.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    @objc func toggleDrawing() {
        if session != nil {
            session?.end()
            return
        }
        let session = DrawingSession(state: state)
        session.onEnd = { [weak self] in
            self?.session = nil
            self?.updater.drawingDidEnd()
        }
        self.session = session
        session.start()
    }

    // MARK: Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let draw = NSMenuItem(title: session == nil ? "Start Drawing" : "Stop Drawing", action: #selector(toggleDrawing), keyEquivalent: "d")
        draw.keyEquivalentModifierMask = [.option, .shift]
        menu.addItem(draw)
        menu.addItem(.separator())

        menu.addItem(sectionHeader("Screenshots"))
        menu.addItem(toggle("Add App & Window Caption", Settings.caption, #selector(toggleCaption)))
        menu.addItem(toggle("Save Context JSON Next to Image", Settings.jsonSidecar, #selector(toggleJSON)))
        menu.addItem(toggle("Include Browser Tab URL", Settings.browserURL, #selector(toggleBrowser)))
        menu.addItem(toggle("Copy to Clipboard", Settings.clipboard, #selector(toggleClipboard)))
        menu.addItem(item("Open Screenshots Folder", #selector(openFolder)))
        if !CGPreflightScreenCaptureAccess() {
            menu.addItem(item("Allow Screen Recording…", #selector(openScreenRecordingSettings)))
        }

        menu.addItem(.separator())
        menu.addItem(sectionHeader("Updates"))
        let checkUpdates = item("Check for Updates…", #selector(AppUpdater.checkForUpdates(_:)))
        checkUpdates.target = updater
        checkUpdates.isEnabled = updater.canCheckForUpdates
        menu.addItem(checkUpdates)
        let autoChecks = toggle("Check for Updates Automatically", updater.automaticallyChecksForUpdates,
                                #selector(AppUpdater.toggleAutomaticChecks(_:)))
        autoChecks.target = updater
        autoChecks.isEnabled = updater.isAvailable
        menu.addItem(autoChecks)
        let autoInstall = toggle("Download and Install Updates Automatically", updater.automaticallyDownloadsUpdates,
                                 #selector(AppUpdater.toggleAutomaticDownloads(_:)))
        autoInstall.target = updater
        autoInstall.isEnabled = updater.isAvailable && updater.automaticallyChecksForUpdates
        menu.addItem(autoInstall)
        menu.addItem(.separator())
        menu.addItem(item("Shortcuts…", #selector(showShortcuts)))
        menu.addItem(NSMenuItem(title: "Quit Desk Draw", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let item = item(title, action)
        item.state = on ? .on : .off
        return item
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleCaption() { Settings.caption.toggle() }
    @objc private func toggleJSON() { Settings.jsonSidecar.toggle() }
    @objc private func toggleBrowser() { Settings.browserURL.toggle() }
    @objc private func toggleClipboard() { Settings.clipboard.toggle() }

    @objc private func openFolder() {
        let folder = Settings.screenshotFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showShortcuts() {
        let alert = NSAlert()
        alert.messageText = "Desk Draw Shortcuts"
        alert.informativeText = """
        \(Self.hotKeyLabel)   Start / stop drawing (anywhere)
        Esc   Stop drawing (the drawing is discarded)

        P Pen · H Highlighter · L Line · A Arrow
        R Rectangle · O Ellipse · T Text
        Shift while dragging: straight angles, squares, circles
        1–8   Colors      [ ]  or  - +   Size      F   Fill shapes

        ⌘Z / ⇧⌘Z   Undo / Redo      ⌫   Remove last
        ⌘⌫   Clear all

        W / D / S   Capture window / drawing area / screen
        ⌘S   Save screenshot with context (and copy it)
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Main menu (gives the text tool copy/paste and routes ⌘Z)

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Desk Draw", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
