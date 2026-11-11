import AppKit
import Testing
@testable import DeskDraw

@Suite(.serialized)
@MainActor
struct AppUpdaterTests {
    @Test func commandLineAndTestProcessesNeverStartAnUpdater() {
        let updater = AppUpdater()
        updater.start()
        #expect(!updater.isAvailable)
        #expect(!updater.canCheckForUpdates)
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(AppUpdater.checkForUpdates(_:)), keyEquivalent: "")
        #expect(!updater.validateMenuItem(item))
    }

    @Test func installationWaitsUntilDrawingEndsAndResumesOnlyOnce() {
        let updater = AppUpdater()
        #expect(updater.responds(to: NSSelectorFromString("updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:")))
        var drawing = true
        updater.isDrawing = { drawing }
        var installations = 0
        #expect(updater.postponeInstallationIfDrawing { installations += 1 })
        #expect(installations == 0)
        drawing = false
        updater.drawingDidEnd()
        #expect(installations == 1)
        updater.drawingDidEnd()
        #expect(installations == 1)
    }

    @Test func installationWithoutDrawingRemainsUnderSparklesControl() {
        let updater = AppUpdater()
        var invoked = false
        #expect(!updater.postponeInstallationIfDrawing { invoked = true })
        updater.drawingDidEnd()
        #expect(!invoked)
    }
}
