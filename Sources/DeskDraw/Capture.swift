import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

struct CaptureError: Error {
    let message: String
}

/// Saved alongside each screenshot as `<name>.json`, and summarized in the PNG's
/// description field. Image rects use pixels with a top-left origin; screen
/// rects use points with a top-left origin of the main display.
struct CaptureRecord: Codable {
    struct App: Codable {
        var name: String?
        var bundleID: String?
    }
    struct Window: Codable {
        var title: String?
        var frame: Rect
    }
    struct Tab: Codable {
        var url: String
        var title: String?
    }
    struct Rect: Codable {
        var x, y, width, height: Double
    }
    struct Mark: Codable {
        var kind: String
        var color: String
        var rect: Rect
        var text: String?
    }

    var capturedAt: String
    var target: String
    var image: String
    var imageWidth: Int
    var imageHeight: Int
    var captionHeight: Int
    var scale: Double
    var app: App?
    var window: Window?
    var browserTab: Tab?
    var frontmostApp: App?
    var display: String
    var region: Rect
    var annotations: [Mark]
}

@MainActor
enum Capturer {
    static func capture(session: DrawingSession) async throws -> URL {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw CaptureError(message: "Needs Screen Recording permission: System Settings → Privacy & Security, then restart Desk Draw.")
        }

        let state = session.state
        let context = session.context
        let annotations = state.annotations
        let drawing = state.drawingBounds
        let window = context.contextWindow(for: drawing)
        let fallbackScreen = Geometry.screen(containing: NSEvent.mouseLocation) ?? NSScreen.screens[0]

        // 1. Decide what to capture, in global AppKit coordinates.
        var target = state.captureTarget
        var wanted: CGRect?
        switch target {
        case .window:
            if let window {
                // Keep marks that start inside the window but stick out of it.
                wanted = annotations
                    .map(\.bounds)
                    .filter { $0.intersects(window.frame) }
                    .reduce(window.frame) { $0.union($1) }
            }
        case .area:
            wanted = drawing?.insetBy(dx: -48, dy: -48)
        case .screen:
            break
        }
        if wanted == nil { target = .screen }

        let screen = session.screen ?? largestOverlap(with: wanted ?? drawing) ?? fallbackScreen
        let region = (wanted ?? screen.frame).intersection(screen.frame).integral
        guard !region.isEmpty, let displayID = screen.displayID else {
            throw CaptureError(message: "Nothing to capture on this display.")
        }

        // 2. Grab the display without Desk Draw's own windows.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError(message: "Could not find the display to capture.")
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let own = content.windows.filter { $0.owningApplication?.processID == pid }
        let filter = SCContentFilter(display: display, excludingWindows: own)
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.width = Int(screen.frame.width * scale)
        config.height = Int(screen.frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        let shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        // 3. Describe the context.
        let app = window?.app ?? context.frontApp
        let appName = app?.localizedName ?? window?.ownerName ?? "Unknown app"
        let sameAppAsFront = window == nil || window?.pid == context.frontApp?.processIdentifier
        let tab = sameAppAsFront ? context.browserTab : nil
        let now = Date()

        let caption = Settings.caption ? Caption(
            icon: app?.icon ?? app?.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) },
            title: [appName, window?.title ?? tab?.title].compactMap { $0 }.joined(separator: " — "),
            detail: [tab?.url, now.formatted(date: .abbreviated, time: .standard)].compactMap { $0 }.joined(separator: "  ·  ")
        ) : nil

        // 4. Compose screenshot, annotations and caption.
        guard let image = compose(shot, screenFrame: screen.frame, region: region, annotations: annotations, caption: caption) else {
            throw CaptureError(message: "Could not compose the screenshot.")
        }

        // 5. Save PNG (+ JSON) and copy.
        let folder = Settings.screenshotFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(in: folder, base: fileBase(date: now, app: appName, title: window?.title ?? tab?.title))

        let pixelScale = CGFloat(shot.width) / screen.frame.width
        let marks: [CaptureRecord.Mark] = annotations.compactMap { a in
            let r = a.shapeBounds.intersection(region)
            guard !r.isNull else { return nil }
            return CaptureRecord.Mark(
                kind: a.tool.rawValue,
                color: a.colorName.lowercased(),
                rect: .init(
                    x: Double(((r.minX - region.minX) * pixelScale).rounded()),
                    y: Double(((region.maxY - r.maxY) * pixelScale).rounded()),
                    width: Double((r.width * pixelScale).rounded()),
                    height: Double((r.height * pixelScale).rounded())
                ),
                text: a.tool == .text ? a.text : nil
            )
        }
        let record = CaptureRecord(
            capturedAt: ISO8601DateFormatter().string(from: now),
            target: target.rawValue,
            image: url.lastPathComponent,
            imageWidth: image.width,
            imageHeight: image.height,
            captionHeight: caption == nil ? 0 : Int((Caption.height * pixelScale).rounded()),
            scale: Double(pixelScale),
            app: app.map { .init(name: $0.localizedName, bundleID: $0.bundleIdentifier) }
                ?? window.map { .init(name: $0.ownerName, bundleID: nil) },
            window: window.map { .init(title: $0.title, frame: cgRect(Geometry.flip($0.frame))) },
            browserTab: tab.map { .init(url: $0.url, title: $0.title) },
            frontmostApp: context.frontApp.map { .init(name: $0.localizedName, bundleID: $0.bundleIdentifier) },
            display: screen.localizedName,
            region: cgRect(Geometry.flip(region)),
            annotations: marks
        )

        guard let png = pngData(image, scale: pixelScale, title: caption?.title ?? appName, description: summary(record)) else {
            throw CaptureError(message: "Could not encode the PNG.")
        }
        try png.write(to: url)

        if Settings.jsonSidecar {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(record).write(to: url.deletingPathExtension().appendingPathExtension("json"))
        }

        if Settings.clipboard {
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([item])
        }
        return url
    }

    // MARK: - Composition

    struct Caption {
        static let height: CGFloat = 48
        let icon: NSImage?
        let title: String
        let detail: String
    }

    static func compose(
        _ shot: CGImage, screenFrame: CGRect, region: CGRect, annotations: [Annotation], caption: Caption?
    ) -> CGImage? {
        let scale = CGFloat(shot.width) / screenFrame.width
        let width = Int((region.width * scale).rounded())
        let height = Int((region.height * scale).rounded())
        let footer = caption == nil ? 0 : Int((Caption.height * scale).rounded())
        let space = shot.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: width, height: height + footer, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        // Screenshot, positioned so `region` fills the canvas above the footer.
        let local = region.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        ctx.draw(shot, in: CGRect(
            x: -local.minX * scale, y: CGFloat(footer) - local.minY * scale,
            width: CGFloat(shot.width), height: CGFloat(shot.height)
        ))

        // Annotations, in global coordinates.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(footer))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -region.minX, y: -region.minY)
        ctx.clip(to: region)
        for annotation in annotations where annotation.bounds.intersects(region) {
            Renderer.draw(annotation, in: ctx)
        }
        ctx.restoreGState()

        if let caption {
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            drawCaption(caption, width: CGFloat(width) / scale, in: ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    private static func drawCaption(_ caption: Caption, width: CGFloat, in ctx: CGContext) {
        let h = Caption.height
        ctx.setFillColor(NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: h))
        ctx.setFillColor(CanvasView.accent.cgColor)
        ctx.fill(CGRect(x: 0, y: h - 2, width: width, height: 2))

        var x: CGFloat = 12
        if let icon = caption.icon {
            icon.draw(in: CGRect(x: x, y: (h - 2 - 28) / 2, width: 28, height: 28))
            x += 28 + 10
        }
        let textWidth = max(0, width - x - 12)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]

        (caption.title as NSString).draw(
            with: CGRect(x: x, y: h / 2 - 1, width: textWidth, height: 18), options: options,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: style]
        )
        (caption.detail as NSString).draw(
            with: CGRect(x: x, y: h / 2 - 17, width: textWidth, height: 15), options: options,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.65, alpha: 1), .paragraphStyle: style]
        )
    }

    // MARK: - Output

    static func pngData(_ image: CGImage, scale: CGFloat, title: String, description: String) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGTitle: title,
                kCGImagePropertyPNGDescription: description,
                kCGImagePropertyPNGSoftware: "Desk Draw",
            ],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func summary(_ r: CaptureRecord) -> String {
        var lines: [String] = []
        if let app = r.app { lines.append("App: \(app.name ?? "?")\(app.bundleID.map { " (\($0))" } ?? "")") }
        if let title = r.window?.title { lines.append("Window: \(title)") }
        if let tab = r.browserTab { lines.append("URL: \(tab.url)") }
        lines.append("Captured: \(r.capturedAt) (\(r.target), \(r.display))")
        for mark in r.annotations {
            let text = mark.text.map { " “\($0)”" } ?? ""
            lines.append("Mark: \(mark.color) \(mark.kind)\(text) at x=\(Int(mark.rect.x)) y=\(Int(mark.rect.y)) w=\(Int(mark.rect.width)) h=\(Int(mark.rect.height)) px")
        }
        return lines.joined(separator: "\n")
    }

    private static func fileBase(date: Date, app: String, title: String?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var parts = ["Desk Draw \(formatter.string(from: date))", sanitize(app)]
        if let title, !title.isEmpty { parts.append(String(sanitize(title).prefix(60))) }
        return parts.joined(separator: " – ")
    }

    private static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\n\r\t")
        return s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    }

    private static func uniqueURL(in folder: URL, base: String) -> URL {
        var url = folder.appendingPathComponent(base).appendingPathExtension("png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension("png")
            n += 1
        }
        return url
    }

    private static func largestOverlap(with rect: CGRect?) -> NSScreen? {
        guard let rect else { return nil }
        return NSScreen.screens
            .map { ($0, $0.frame.intersection(rect)) }
            .filter { !$0.1.isNull }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
    }

    private static func cgRect(_ r: CGRect) -> CaptureRecord.Rect {
        .init(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height))
    }
}
