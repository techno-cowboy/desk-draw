import Foundation

/// App preferences. These persist; drawings never do.
enum Settings {
    private static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: [
            Key.caption: true,
            Key.jsonSidecar: true,
            Key.browserURL: true,
            Key.clipboard: true,
        ])
    }

    enum Key {
        static let caption = "captionEnabled"
        static let jsonSidecar = "jsonSidecarEnabled"
        static let browserURL = "browserURLEnabled"
        static let clipboard = "copyToClipboardEnabled"
    }

    static var caption: Bool {
        get { defaults.bool(forKey: Key.caption) }
        set { defaults.set(newValue, forKey: Key.caption) }
    }

    static var jsonSidecar: Bool {
        get { defaults.bool(forKey: Key.jsonSidecar) }
        set { defaults.set(newValue, forKey: Key.jsonSidecar) }
    }

    static var browserURL: Bool {
        get { defaults.bool(forKey: Key.browserURL) }
        set { defaults.set(newValue, forKey: Key.browserURL) }
    }

    static var clipboard: Bool {
        get { defaults.bool(forKey: Key.clipboard) }
        set { defaults.set(newValue, forKey: Key.clipboard) }
    }

    static var screenshotFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("Desk Draw", isDirectory: true)
    }
}
