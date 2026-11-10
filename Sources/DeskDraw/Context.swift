import AppKit

/// A visible window from the system window list, in AppKit coordinates.
struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let ownerName: String
    let title: String?
    let frame: CGRect

    var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
}

struct BrowserTab {
    let url: String
    let title: String?
}

/// What was on screen when drawing started. Taken before the overlay appears,
/// so it describes the app and window the user is drawing on.
@MainActor
struct SessionContext {
    let startedAt: Date
    let frontApp: NSRunningApplication?
    /// Front to back.
    let windows: [WindowInfo]
    let mouseLocation: CGPoint
    let browserTab: BrowserTab?

    static func snapshot(includeBrowser: Bool) -> SessionContext {
        let front = NSWorkspace.shared.frontmostApplication
        let tab = includeBrowser ? front.flatMap { Browser.currentTab(of: $0) } : nil
        return SessionContext(
            startedAt: Date(),
            frontApp: front,
            windows: visibleWindows(),
            mouseLocation: NSEvent.mouseLocation,
            browserTab: tab
        )
    }

    private static func visibleWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard
                (info[kCGWindowLayer as String] as? Int) == 0,
                (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                let number = info[kCGWindowNumber as String] as? CGWindowID,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let cgBounds = CGRect(dictionaryRepresentation: boundsDict),
                cgBounds.width > 40, cgBounds.height > 40
            else { return nil }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return WindowInfo(
                id: number,
                pid: pid,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "Unknown",
                title: title,
                frame: Geometry.flip(cgBounds)
            )
        }
    }

    /// The window the drawing is on: the topmost window under the drawing's
    /// center, else the front app's top window, else the window under the mouse.
    func contextWindow(for drawing: CGRect?) -> WindowInfo? {
        if let drawing {
            let center = CGPoint(x: drawing.midX, y: drawing.midY)
            if let hit = windows.first(where: { $0.frame.contains(center) }) { return hit }
            if let hit = windows.first(where: { $0.frame.intersects(drawing) }) { return hit }
        }
        if let pid = frontApp?.processIdentifier, let top = windows.first(where: { $0.pid == pid }) {
            return top
        }
        return windows.first { $0.frame.contains(mouseLocation) }
    }
}

/// Reads the active tab of common scriptable browsers. The first use asks the
/// user to allow Desk Draw to control that browser (Automation permission).
enum Browser {
    private static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "org.chromium.Chromium",
    ]

    @MainActor
    static func currentTab(of app: NSRunningApplication) -> BrowserTab? {
        guard let id = app.bundleIdentifier else { return nil }
        let tab: String, titleKey: String
        if safari.contains(id) {
            tab = "current tab of front window"; titleKey = "name"
        } else if chromium.contains(id) {
            tab = "active tab of front window"; titleKey = "title"
        } else {
            return nil
        }
        let source = """
        tell application id "\(id)"
            with timeout of 2 seconds
                set t to \(tab)
                return {URL of t, \(titleKey) of t}
            end timeout
        end tell
        """
        var error: NSDictionary?
        guard
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error),
            let url = result.atIndex(1)?.stringValue, !url.isEmpty
        else { return nil }
        return BrowserTab(url: url, title: result.atIndex(2)?.stringValue)
    }
}
