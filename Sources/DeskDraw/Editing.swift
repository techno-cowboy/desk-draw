import AppKit

/// A grab point on the selected mark.
enum SelectionHandle: Hashable {
    /// On the selection box: 0 = min, 1 = middle, 2 = max on each axis.
    case box(x: Int, y: Int)
    /// Start (0) or end (1) of a line or arrow.
    case endpoint(Int)
}

/// Selecting, moving, resizing and restyling marks. All geometry is in global
/// AppKit screen coordinates, like the rest of `Annotation`.
extension Annotation {
    var isSegment: Bool { tool == .line || tool == .arrow }

    /// The box the selection handles sit on.
    var frame: CGRect { shapeBounds }

    var handles: [SelectionHandle] {
        if isSegment { return [.endpoint(0), .endpoint(1)] }
        let corners: [SelectionHandle] = [.box(x: 0, y: 0), .box(x: 2, y: 0), .box(x: 0, y: 2), .box(x: 2, y: 2)]
        // Text and number dots scale as a whole, so they only get corners.
        if tool == .text || tool == .number { return corners }
        return corners + [.box(x: 1, y: 0), .box(x: 1, y: 2), .box(x: 0, y: 1), .box(x: 2, y: 1)]
    }

    func position(of handle: SelectionHandle) -> CGPoint {
        switch handle {
        case .endpoint(let i):
            return (i == 0 ? points.first : points.last) ?? .zero
        case .box(let x, let y):
            let f = frame
            return CGPoint(x: f.minX + f.width * CGFloat(x) / 2, y: f.minY + f.height * CGFloat(y) / 2)
        }
    }

    // MARK: Hit testing

    /// True when `p` is on what is actually drawn: the stroke, the filled area, or the text.
    func hitsStroke(_ p: CGPoint) -> Bool {
        let t = max(6, effectiveLineWidth / 2 + 4)
        switch tool {
        case .select:
            return false
        case .text:
            return textRect.insetBy(dx: -6, dy: -6).contains(p)
        case .number:
            guard let c = points.first else { return false }
            return hypot(p.x - c.x, p.y - c.y) <= diameter / 2 + 3
        case .pen, .highlighter:
            guard let first = points.first else { return false }
            if points.count == 1 { return hypot(p.x - first.x, p.y - first.y) <= t }
            return zip(points, points.dropFirst()).contains { Self.distance(p, $0, $1) <= t }
        case .line, .arrow:
            guard let p0 = points.first, let p1 = points.last else { return false }
            return Self.distance(p, p0, p1) <= t
        case .rectangle:
            let r = frame
            if filled { return r.insetBy(dx: -t, dy: -t).contains(p) }
            let inner = r.insetBy(dx: t, dy: t)
            return r.insetBy(dx: -t, dy: -t).contains(p) && (inner.isNull || inner.isEmpty || !inner.contains(p))
        case .ellipse:
            let r = frame
            if filled { return Self.ellipse(r.insetBy(dx: -t, dy: -t), contains: p) }
            let inner = r.insetBy(dx: t, dy: t)
            return Self.ellipse(r.insetBy(dx: -t, dy: -t), contains: p)
                && (inner.isNull || inner.isEmpty || !Self.ellipse(inner, contains: p))
        }
    }

    /// True when `p` is inside an outlined rectangle or ellipse, so big boxes
    /// can be grabbed anywhere, not just on their edge.
    func interiorContains(_ p: CGPoint) -> Bool {
        switch tool {
        case .rectangle: frame.contains(p)
        case .ellipse: Self.ellipse(frame, contains: p)
        default: false
        }
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private static func ellipse(_ r: CGRect, contains p: CGPoint) -> Bool {
        guard r.width > 0, r.height > 0 else { return false }
        let x = (p.x - r.midX) / (r.width / 2), y = (p.y - r.midY) / (r.height / 2)
        return x * x + y * y <= 1
    }

    // MARK: Moving and resizing

    func translated(by d: CGVector) -> Annotation {
        var a = self
        a.points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
        if tool == .text { a.textRect = textRect.offsetBy(dx: d.dx, dy: d.dy) }
        return a
    }

    /// Moved by `d`, but kept on `screen` so it cannot get lost past the edge.
    func translated(by d: CGVector, within screen: CGRect) -> Annotation {
        let f = frame
        guard !f.isNull else { return self }
        let x = min(max(f.minX + d.dx, screen.minX), max(screen.minX, screen.maxX - f.width))
        let y = min(max(f.minY + d.dy, screen.minY), max(screen.minY, screen.maxY - f.height))
        return translated(by: CGVector(dx: x - f.minX, dy: y - f.minY))
    }

    /// The mark with `handle` dragged to `p`. The opposite side stays put.
    /// `proportional` keeps the aspect ratio on corners and snaps line angles;
    /// text always scales proportionally.
    func resized(_ handle: SelectionHandle, to p: CGPoint, proportional: Bool) -> Annotation {
        var a = self
        switch handle {
        case .endpoint(let i):
            guard let first = points.first, let last = points.last else { return self }
            let other = i == 0 ? last : first
            let q = proportional ? Renderer.constrain(p, from: other, tool: tool) : p
            a.points = i == 0 ? [q, other] : [other, q]
            return a

        case .box(let hx, let hy):
            let old = frame
            guard !old.isNull else { return self }
            // The fixed point: the opposite corner or edge.
            let anchor = CGPoint(x: hx == 0 ? old.maxX : old.minX, y: hy == 0 ? old.maxY : old.minY)
            let minSide: CGFloat = 4
            // Size along each axis, never flipped through the anchor.
            var width = hx == 1 ? old.width : max(minSide, hx == 0 ? anchor.x - p.x : p.x - anchor.x)
            var height = hy == 1 ? old.height : max(minSide, hy == 0 ? anchor.y - p.y : p.y - anchor.y)
            let isCorner = hx != 1 && hy != 1
            if tool == .text || tool == .number || (proportional && isCorner) {
                let sx = old.width > 0.5 ? width / old.width : 0
                let sy = old.height > 0.5 ? height / old.height : 0
                let scale = max(sx, sy, 0.05)
                if tool == .text { return a.scaledText(by: scale, anchoredAt: anchor, handleX: hx, handleY: hy) }
                if tool == .number { return a.scaledMarker(by: scale, anchoredAt: anchor, handleX: hx, handleY: hy) }
                width = old.width * scale
                height = old.height * scale
            }
            let new = CGRect(
                x: hx == 0 ? anchor.x - width : (hx == 1 ? old.minX : anchor.x),
                y: hy == 0 ? anchor.y - height : (hy == 1 ? old.minY : anchor.y),
                width: width, height: height
            )
            // A flat stroke has no size to scale along that axis, so it just moves.
            func map(_ v: CGFloat, _ o0: CGFloat, _ oLen: CGFloat, _ n0: CGFloat, _ nLen: CGFloat) -> CGFloat {
                oLen < 0.5 ? v + (n0 - o0) : n0 + (v - o0) * nLen / oLen
            }
            a.points = points.map {
                CGPoint(x: map($0.x, old.minX, old.width, new.minX, new.width),
                        y: map($0.y, old.minY, old.height, new.minY, new.height))
            }
            return a
        }
    }

    private func scaledText(by scale: CGFloat, anchoredAt anchor: CGPoint, handleX hx: Int, handleY hy: Int) -> Annotation {
        let size = min(max(fontSize * scale, 8), 400)
        var a = withFontSize(size)
        let r = a.textRect
        a.textRect.origin = CGPoint(x: hx == 0 ? anchor.x - r.width : anchor.x,
                                    y: hy == 0 ? anchor.y - r.height : anchor.y)
        return a
    }

    private func scaledMarker(by scale: CGFloat, anchoredAt anchor: CGPoint, handleX hx: Int, handleY hy: Int) -> Annotation {
        let d = min(max(diameter * scale, 14), 240)
        var a = self
        a.diameter = d
        a.points = [CGPoint(x: hx == 0 ? anchor.x - d / 2 : anchor.x + d / 2,
                            y: hy == 0 ? anchor.y - d / 2 : anchor.y + d / 2)]
        return a
    }

    // MARK: Style

    /// Text at a new font size, wrapping at the same places, with its top-left corner kept.
    func withFontSize(_ size: CGFloat) -> Annotation {
        guard tool == .text, fontSize > 0, size != fontSize else { return self }
        var a = self
        let width = (textLayoutWidth ?? textRect.width) * size / fontSize
        a.fontSize = size
        a.textLayoutWidth = width
        let s = Renderer.textSize(text, color: color, fontSize: size, width: width)
        a.textRect = CGRect(x: textRect.minX, y: textRect.maxY - s.height, width: s.width, height: s.height)
        return a
    }

    func withSize(_ size: StrokeSize) -> Annotation {
        if tool == .text { return withFontSize(size.fontSize) }
        var a = self
        if tool == .number { a.diameter = size.markerDiameter }
        a.lineWidth = size.lineWidth
        return a
    }

    func withColor(_ color: PaletteColor) -> Annotation {
        var a = self
        a.color = color.color
        a.colorName = color.name
        return a
    }
}
