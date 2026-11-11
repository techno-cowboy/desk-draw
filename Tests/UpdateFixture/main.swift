// Standalone, invisible test app used by scripts/test-updates.py. Never shipped.
import AppKit
import Sparkle

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private var updater: SPUUpdater?
    private var timeout: Timer?

    func record(_ value: String) {
        let path = Bundle.main.object(forInfoDictionaryKey: "DeskDrawTestOutput") as! String
        try! value.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "2" {
            record("installed")
            exit(0)
        }
        let bundle = Bundle.main
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
        self.updater = updater
        do {
            try updater.start()
            updater.checkForUpdatesInBackground()
        } catch {
            record("startup error: \(error)")
            exit(1)
        }
        timeout = Timer.scheduledTimer(withTimeInterval: 40, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.record("timeout")
                exit(1)
            }
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock installHandler: @escaping () -> Void) -> Bool {
        // Test-only: accept the verified update immediately without any windows or user input.
        DispatchQueue.main.async { installHandler() }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        record("rejected: \(error)")
        exit(0)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    if let mode = CommandLine.arguments.dropFirst().first {
        // Exercise the production wrapper in a real .app, including Sparkle's persisted preferences.
        let updater = AppUpdater()
        updater.start()
        precondition(updater.isAvailable && updater.canCheckForUpdates)
        if mode == "--smoke-updater" {
            precondition(updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates)
            updater.isDrawing = { true }
            precondition(!updater.canCheckForUpdates)
            updater.toggleAutomaticDownloads(nil)
            updater.toggleAutomaticChecks(nil)
            precondition(!updater.automaticallyChecksForUpdates)
        } else if mode == "--smoke-opt-out" {
            precondition(!updater.automaticallyChecksForUpdates)
            updater.toggleAutomaticChecks(nil)
            precondition(!updater.automaticallyDownloadsUpdates)
            updater.toggleAutomaticDownloads(nil)
        } else {
            fatalError("Unknown fixture mode")
        }
        UserDefaults.standard.synchronize()
        print("PASS \(mode)")
        exit(0)
    }
    let delegate = FixtureDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
