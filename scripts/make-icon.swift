// Renders the Desk Draw app icon (same design as assets/icon.svg) to a 1024px PNG.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments[1])

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824px body centered on a 1024px canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor(srgbRed: 0xC0 / 255, green: 0x26 / 255, blue: 0xD3 / 255, alpha: 1).setFill()
NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).fill()
NSGraphicsContext.restoreGraphicsState()

let font = NSFont.systemFont(ofSize: 340, weight: .semibold)
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
let text = "DD" as NSString
let textSize = text.size(withAttributes: attrs)
// Center on cap height, not on the line box.
let baseline = body.midY - font.capHeight / 2
text.draw(at: CGPoint(x: body.midX - textSize.width / 2, y: baseline + font.descender), withAttributes: attrs)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
