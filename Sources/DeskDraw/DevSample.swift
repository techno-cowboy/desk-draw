import AppKit

/// `DeskDraw --render-sample <out.png>`: runs the screenshot composer on a
/// synthetic display, so rendering and coordinate math can be checked without
/// Screen Recording permission. Marks should line up with the black targets.
@MainActor
enum DevSample {
    static func render(to path: String) {
        // A secondary display to the right of the main one, so offsets matter.
        let screenFrame = CGRect(x: 1512, y: -200, width: 1200, height: 800)
        let scale: CGFloat = 2
        let window = CGRect(x: 1612, y: -100, width: 800, height: 520)
        let targetA = CGRect(x: 1700, y: 200, width: 160, height: 60)
        let targetB = CGRect(x: 2100, y: 0, width: 120, height: 120)

        let shot = fakeScreenshot(screenFrame: screenFrame, scale: scale, window: window, targets: [targetA, targetB])
        let red = Palette.colors[0], yellow = Palette.colors[2], blue = Palette.colors[4]
        func mark(_ tool: Tool, _ c: PaletteColor, _ pts: [CGPoint], width: CGFloat = 6, filled: Bool = false) -> Annotation {
            Annotation(tool: tool, color: c.color, colorName: c.name, lineWidth: width, filled: filled, points: pts)
        }
        var text = Annotation(tool: .text, color: red.color, colorName: red.name, lineWidth: 0, filled: false,
                              text: "Fix this label", fontSize: 28)
        let attrs = Renderer.textAttributes(color: red.color, fontSize: 28)
        text.textRect = CGRect(origin: CGPoint(x: 1700, y: 300), size: ("Fix this label" as NSString).size(withAttributes: attrs))

        let squiggle = stride(from: 0.0, through: 1.0, by: 0.02).map { t in
            CGPoint(x: 1680 + t * 300, y: 120 + sin(t * .pi * 6) * 14)
        }
        let annotations = [
            mark(.rectangle, red, [CGPoint(x: targetA.minX - 8, y: targetA.minY - 8), CGPoint(x: targetA.maxX + 8, y: targetA.maxY + 8)]),
            mark(.ellipse, blue, [CGPoint(x: targetB.minX - 10, y: targetB.minY - 10), CGPoint(x: targetB.maxX + 10, y: targetB.maxY + 10)], filled: true),
            mark(.arrow, red, [CGPoint(x: 1950, y: 330), CGPoint(x: targetA.maxX + 14, y: targetA.midY + 4)]),
            mark(.highlighter, yellow, [CGPoint(x: 1680, y: 40), CGPoint(x: 2000, y: 40)], width: 6),
            mark(.pen, blue, squiggle, width: 3),
            mark(.line, red, [CGPoint(x: 2050, y: -60), CGPoint(x: 2350, y: -60)]),
            text,
        ]
        let caption = Capturer.Caption(
            icon: NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app"),
            title: "Notes — Sample window title",
            detail: "https://example.com/page  ·  \(Date().formatted(date: .abbreviated, time: .standard))"
        )
        guard
            let image = Capturer.compose(shot, screenFrame: screenFrame, region: window, annotations: annotations, caption: caption),
            let png = Capturer.pngData(image, scale: scale, title: caption.title, description: "sample")
        else {
            print("render failed"); exit(1)
        }
        try! png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(image.width)x\(image.height)")
    }

    private static func fakeScreenshot(screenFrame: CGRect, scale: CGFloat, window: CGRect, targets: [CGRect]) -> CGImage {
        let w = Int(screenFrame.width * scale), h = Int(screenFrame.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.systemTeal.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -screenFrame.minX, y: -screenFrame.minY)
        ctx.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor)
        ctx.fill(window)
        ctx.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
        ctx.fill(CGRect(x: window.minX, y: window.maxY - 28, width: window.width, height: 28))
        ctx.setFillColor(NSColor.black.cgColor)
        targets.forEach { ctx.fill($0) }
        return ctx.makeImage()!
    }
}
