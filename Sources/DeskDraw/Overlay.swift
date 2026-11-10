import AppKit
import Carbon.HIToolbox
import QuartzCore

enum Levels {
    /// Above the menu bar, Dock and other apps' floating panels.
    static let overlay = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
    static let toolbar = NSWindow.Level.screenSaver
}

/// A transparent, borderless window covering one display while drawing.
final class OverlayWindow: NSWindow {
    let canvas: CanvasView

    init(screen: NSScreen, session: DrawingSession) {
        canvas = CanvasView(screenFrame: screen.frame, session: session)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = Levels.overlay
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Set explicitly so fully transparent areas still take clicks.
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        contentView = canvas
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class CanvasView: NSView, NSTextFieldDelegate {
    private let screenFrame: CGRect
    private weak var session: DrawingSession?
    private var state: DrawingState? { session?.state }

    private var current: Annotation?
    private var dragStart: CGPoint = .zero
    private var textField: NSTextField?

    static let accent = NSColor(srgbRed: 0.75, green: 0.15, blue: 0.83, alpha: 1)

    init(screenFrame: CGRect, session: DrawingSession) {
        self.screenFrame = screenFrame
        self.session = session
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
        wantsLayer = true
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Coordinates

    private func global(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x + screenFrame.minX, y: local.y + screenFrame.minY)
    }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let state else { return }

        // A barely-there tint so the window always hit-tests as opaque.
        NSColor(white: 0, alpha: 0.008).setFill()
        dirtyRect.fill()

        ctx.saveGState()
        ctx.translateBy(x: -screenFrame.minX, y: -screenFrame.minY)
        let visible = dirtyRect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
        for annotation in state.annotations where annotation.bounds.intersects(visible) {
            Renderer.draw(annotation, in: ctx)
        }
        if let current { Renderer.draw(current, in: ctx) }
        ctx.restoreGState()

        // Frame that marks drawing mode. Never ends up in screenshots.
        let border = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        border.lineWidth = 4
        Self.accent.withAlphaComponent(0.75).setStroke()
        border.stroke()
    }

    func flash() {
        guard let layer else { return }
        let flash = CALayer()
        flash.frame = layer.bounds
        flash.backgroundColor = NSColor.white.cgColor
        flash.opacity = 0
        layer.addSublayer(flash)
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.45
        anim.toValue = 0
        anim.duration = 0.35
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { flash.removeFromSuperlayer() }
        flash.add(anim, forKey: "flash")
        CATransaction.commit()
    }

    // MARK: Cursor

    override func cursorUpdate(with event: NSEvent) { updateCursor() }
    override func mouseMoved(with event: NSEvent) { updateCursor() }

    func updateCursor() {
        (state?.tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let state else { return }
        window?.makeKey()
        if textField != nil {
            commitText()
            if state.tool == .text { return }
        }
        let p = global(event)
        if state.tool == .text {
            beginText(at: p)
            return
        }
        dragStart = p
        current = Annotation(
            tool: state.tool,
            color: state.color,
            colorName: state.colorName,
            lineWidth: state.size.lineWidth,
            filled: state.fillShapes && state.tool.isShape,
            points: [p]
        )
        invalidate(current)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var annotation = current else { return }
        let old = annotation.bounds
        var p = global(event)
        switch annotation.tool {
        case .pen, .highlighter:
            if let last = annotation.points.last, hypot(p.x - last.x, p.y - last.y) < 1 { return }
            annotation.points.append(p)
        default:
            if event.modifierFlags.contains(.shift) {
                p = Renderer.constrain(p, from: dragStart, tool: annotation.tool)
            }
            annotation.points = [dragStart, p]
        }
        current = annotation
        setNeedsDisplay(local(old.union(annotation.bounds)))
    }

    override func mouseUp(with event: NSEvent) {
        guard let annotation = current else { return }
        current = nil
        let isFreehand = annotation.tool == .pen || annotation.tool == .highlighter
        let size = annotation.shapeBounds
        if isFreehand || max(size.width, size.height) >= 4 {
            state?.add(annotation) // triggers redraw of every overlay
        } else {
            invalidate(annotation)
        }
    }

    private func invalidate(_ annotation: Annotation?) {
        guard let annotation else { return }
        setNeedsDisplay(local(annotation.bounds))
    }

    // MARK: Text

    private func beginText(at p: CGPoint) {
        guard let state else { return }
        let fontSize = state.size.fontSize
        let attrs = Renderer.textAttributes(color: state.color, fontSize: fontSize)
        let lineHeight = ceil(("Xg" as NSString).size(withAttributes: attrs).height)
        let origin = CGPoint(x: p.x - screenFrame.minX, y: p.y - screenFrame.minY - lineHeight / 2)

        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        field.textColor = state.color
        field.placeholderString = "Type, then Return"
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.frame = CGRect(x: origin.x - 2, y: origin.y, width: max(120, bounds.maxX - origin.x - 8), height: lineHeight + 2)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    func commitText() {
        guard let field = textField, let state else { return }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        let color = field.textColor ?? state.color
        let fontSize = field.font?.pointSize ?? state.size.fontSize
        let frame = field.frame
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !text.isEmpty else { return }

        let attrs = Renderer.textAttributes(color: color, fontSize: fontSize)
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = CGPoint(x: frame.minX + 2 + screenFrame.minX, y: frame.maxY - size.height - 1 + screenFrame.minY)
        state.add(Annotation(
            tool: .text,
            color: color,
            colorName: Palette.colors.first { $0.color == color }?.name ?? state.colorName,
            lineWidth: 0,
            filled: false,
            text: text,
            textRect: CGRect(origin: origin, size: size),
            fontSize: fontSize
        ))
    }

    private func cancelText() {
        textField?.delegate = nil
        textField?.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitText(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelText(); return true
        default:
            return false
        }
    }

    // MARK: Keyboard

    @objc func undo(_ sender: Any?) { state?.undo() }
    @objc func redo(_ sender: Any?) { state?.redo() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard textField == nil, window?.isKeyWindow == true, let session else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (key, event.keyCode) {
        case ("s", _):
            session.capture()
            return true
        case (_, UInt16(kVK_Delete)):
            session.state.clear()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let session else { return }
        let state = session.state
        if event.keyCode == UInt16(kVK_Escape) {
            session.end()
            return
        }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            state.undo()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control]) else { return }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if let tool = Tool.allCases.first(where: { $0.key == key }) {
            state.tool = tool
            updateCursor()
        } else if let n = Int(key), (1...Palette.colors.count).contains(n) {
            state.colorIndex = n - 1
        } else if ["[", "-"].contains(key) {
            state.cycleSize(by: -1)
        } else if ["]", "+", "="].contains(key) {
            state.cycleSize(by: 1)
        } else if key == "f" {
            state.fillShapes.toggle()
        } else if key == "w" {
            state.captureTarget = .window
        } else if key == "d" {
            state.captureTarget = .area
        } else if key == "s" {
            state.captureTarget = .screen
        }
    }
}
