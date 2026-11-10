import AppKit

/// Draws annotations into any CGContext whose user space is global AppKit
/// screen coordinates. Used for the live overlay and for screenshots, so both
/// look the same.
enum Renderer {
    static func draw(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let color = a.color.cgColor
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.setLineWidth(a.effectiveLineWidth)

        switch a.tool {
        case .pen, .highlighter:
            let stroke = a.tool == .highlighter ? color.copy(alpha: 0.38) ?? color : color
            if isDot(a.points), let p = a.points.first {
                let r = a.effectiveLineWidth / 2
                ctx.setFillColor(stroke)
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                return
            }
            if a.tool == .highlighter { ctx.setLineCap(.butt) }
            ctx.setStrokeColor(stroke)
            ctx.addPath(smoothPath(a.points))
            ctx.strokePath()

        case .line:
            guard let p0 = a.points.first, let p1 = a.points.last else { return }
            ctx.setStrokeColor(color)
            ctx.move(to: p0)
            ctx.addLine(to: p1)
            ctx.strokePath()

        case .arrow:
            guard let p0 = a.points.first, let p1 = a.points.last else { return }
            drawArrow(from: p0, to: p1, width: a.lineWidth, color: color, in: ctx)

        case .rectangle, .ellipse:
            guard let p0 = a.points.first, let p1 = a.points.last else { return }
            let rect = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
            let path: CGPath
            if a.tool == .rectangle {
                let radius = min(6, rect.width / 2, rect.height / 2)
                path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            } else {
                path = CGPath(ellipseIn: rect, transform: nil)
            }
            if a.filled {
                ctx.setFillColor(color.copy(alpha: 0.22) ?? color)
                ctx.addPath(path)
                ctx.fillPath()
            }
            ctx.setStrokeColor(color)
            ctx.addPath(path)
            ctx.strokePath()

        case .text:
            drawText(a, in: ctx)
        }
    }

    // MARK: - Text

    static func textAttributes(color: NSColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = .zero
        let isDark = (color.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.35
        shadow.shadowColor = isDark ? NSColor.white.withAlphaComponent(0.8) : NSColor.black.withAlphaComponent(0.65)
        return [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
            .shadow: shadow,
        ]
    }

    private static func drawText(_ a: Annotation, in ctx: CGContext) {
        let attrs = textAttributes(color: a.color, fontSize: a.fontSize)
        let needsContext = NSGraphicsContext.current?.cgContext !== ctx
        if needsContext {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        }
        (a.text as NSString).draw(at: a.textRect.origin, withAttributes: attrs)
        if needsContext { NSGraphicsContext.restoreGraphicsState() }
    }

    // MARK: - Geometry helpers

    private static func isDot(_ points: [CGPoint]) -> Bool {
        guard let first = points.first else { return false }
        return points.allSatisfy { hypot($0.x - first.x, $0.y - first.y) < 1 }
    }

    /// Quadratic curves through the midpoints, which smooths jittery mouse input.
    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard pts.count > 2 else {
            path.addLines(between: pts)
            return path
        }
        path.move(to: pts[0])
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    private static func drawArrow(from p0: CGPoint, to p1: CGPoint, width: CGFloat, color: CGColor, in ctx: CGContext) {
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        let angle = atan2(dy, dx)
        let head = min(max(16, width * 3.6), length)
        let spread = CGFloat.pi / 7

        let shaftEnd = CGPoint(x: p1.x - cos(angle) * head * 0.75, y: p1.y - sin(angle) * head * 0.75)
        ctx.setStrokeColor(color)
        ctx.move(to: p0)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        ctx.setFillColor(color)
        ctx.move(to: p1)
        ctx.addLine(to: CGPoint(x: p1.x - head * cos(angle - spread), y: p1.y - head * sin(angle - spread)))
        ctx.addLine(to: CGPoint(x: p1.x - head * cos(angle + spread), y: p1.y - head * sin(angle + spread)))
        ctx.closePath()
        ctx.fillPath()
    }

    /// Shift-constrain: 45° steps for lines, squares and circles for shapes.
    static func constrain(_ p: CGPoint, from start: CGPoint, tool: Tool) -> CGPoint {
        let dx = p.x - start.x, dy = p.y - start.y
        switch tool {
        case .line, .arrow:
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        case .rectangle, .ellipse:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        default:
            return p
        }
    }
}
