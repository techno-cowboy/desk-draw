import AppKit
import Sparkle

/// Owns Sparkle for the lifetime of the menu bar app. Sparkle persists update preferences.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate, NSMenuItemValidation {
    private var controller: SPUStandardUpdaterController?
    private var pendingInstallation: (() -> Void)?
    var isDrawing: () -> Bool = { false }

    var isAvailable: Bool { controller != nil }
    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates == true && !isDrawing() }
    var automaticallyChecksForUpdates: Bool { controller?.updater.automaticallyChecksForUpdates == true }
    var automaticallyDownloadsUpdates: Bool { controller?.updater.automaticallyDownloadsUpdates == true }

    func start() {
        // swift run, rendering tools, and tests aren't installed apps and must never start an updater.
        guard Bundle.main.bundleURL.pathExtension == "app", controller == nil else { return }
        let candidate = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try candidate.updater.start()
            controller = candidate
        } catch {
            NSLog("Desk Draw: could not start the updater: %@", error.localizedDescription)
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(sender)
    }

    @objc func toggleAutomaticChecks(_ sender: Any?) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates.toggle()
    }

    @objc func toggleAutomaticDownloads(_ sender: Any?) {
        guard let updater = controller?.updater, updater.automaticallyChecksForUpdates else { return }
        updater.automaticallyDownloadsUpdates.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(checkForUpdates(_:)): return canCheckForUpdates
        case #selector(toggleAutomaticChecks(_:)): return isAvailable
        case #selector(toggleAutomaticDownloads(_:)): return isAvailable && automaticallyChecksForUpdates
        default: return false
        }
    }

    // A scheduled installation must not discard annotations in an active drawing session.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallationIfDrawing(installHandler)
    }

    func postponeInstallationIfDrawing(_ installHandler: @escaping () -> Void) -> Bool {
        guard isDrawing() else { return false }
        pendingInstallation = installHandler
        return true
    }

    func drawingDidEnd() {
        let install = pendingInstallation
        pendingInstallation = nil
        install?()
    }
}
