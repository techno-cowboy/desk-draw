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

final class CanvasView: NSView, NSTextViewDelegate {
    private let screenFrame: CGRect
    private weak var session: DrawingSession?
    private var state: DrawingState? { session?.state }

    private var current: Annotation?
    private var dragStart: CGPoint = .zero
    private var textView: NSTextView?
    private var editingText: Annotation?
    private var movingText: Annotation?
    private var textTop: CGFloat = 0

    static let accent = NSColor(srgbRed: 0.75, green: 0.15, blue: 0.83, alpha: 1)

    init(screenFrame: CGRect, session: DrawingSession) {
        self.screenFrame = screenFrame
        self.session = session
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
        wantsLayer = true
        clipsToBounds = true
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
            if annotation.id == editingText?.id || annotation.id == movingText?.id { continue }
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

    override func cursorUpdate(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        if state?.tool == .text, text(at: global(event)) != nil {
            NSCursor.openHand.set()
        } else {
            updateCursor()
        }
    }

    func updateCursor() {
        (state?.tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let state else { return }
        window?.makeKey()
        if textView != nil {
            commitText()
            if state.tool == .text { return }
        }
        let p = global(event)
        guard screenFrame.contains(p) else { return }
        if state.tool == .text {
            if let annotation = text(at: p) {
                if event.clickCount >= 2 {
                    beginText(at: p, editing: annotation)
                } else {
                    dragStart = p
                    movingText = annotation
                    current = annotation
                    NSCursor.closedHand.set()
                }
            } else {
                beginText(at: p)
            }
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
        if let original = movingText {
            guard hypot(p.x - dragStart.x, p.y - dragStart.y) >= 3 else { return }
            var rect = original.textRect.offsetBy(dx: p.x - dragStart.x, dy: p.y - dragStart.y)
            rect.origin.x = min(max(rect.minX, screenFrame.minX), max(screenFrame.minX, screenFrame.maxX - rect.width))
            rect.origin.y = min(max(rect.minY, screenFrame.minY), max(screenFrame.minY, screenFrame.maxY - rect.height))
            annotation.textRect = rect
            current = annotation
            setNeedsDisplay(local(old.union(annotation.bounds)))
            return
        }
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
        if let original = movingText {
            movingText = nil
            if annotation.textRect != original.textRect { state?.update(annotation) }
            invalidate(annotation)
            updateCursor()
            return
        }
        let isFreehand = annotation.tool == .pen || annotation.tool == .highlighter
        let size = annotation.shapeBounds
        if isFreehand || max(size.width, size.height) >= 4 {
            state?.add(annotation) // triggers redraw of the overlay
        } else {
            invalidate(annotation)
        }
    }

    private func invalidate(_ annotation: Annotation?) {
        guard let annotation else { return }
        setNeedsDisplay(local(annotation.bounds))
    }

    // MARK: Text

    private func text(at point: CGPoint) -> Annotation? {
        state?.annotations.last { $0.tool == .text && $0.bounds.contains(point) }
    }

    private func beginText(at p: CGPoint, editing annotation: Annotation? = nil) {
        guard let state else { return }
        let fontSize = annotation?.fontSize ?? state.size.fontSize
        let color = annotation?.color ?? state.color
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: fontSize, weight: .semibold)))
        let minWidth = min(120, bounds.width - 16)
        let x = annotation.map { $0.textRect.minX - screenFrame.minX }
            ?? min(max(8, p.x - screenFrame.minX), bounds.maxX - minWidth - 8)
        textTop = annotation.map { $0.textRect.maxY - screenFrame.minY }
            ?? min(bounds.maxY - 8, max(lineHeight + 8, p.y - screenFrame.minY + lineHeight / 2))
        let width = annotation?.textLayoutWidth ?? max(minWidth, bounds.maxX - x - 8)

        let view = AnnotationTextView(frame: CGRect(x: x, y: textTop - lineHeight, width: width, height: lineHeight))
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        view.textColor = color
        view.insertionPointColor = color
        view.typingAttributes = Renderer.textAttributes(color: color, fontSize: fontSize)
        view.string = annotation?.text ?? ""
        if let storage = view.textStorage, storage.length > 0 {
            storage.setAttributes(view.typingAttributes, range: NSRange(location: 0, length: storage.length))
        }
        view.delegate = self
        view.onCommit = { [weak self] in self?.commitText() }
        view.onCapture = { [weak self] in self?.session?.capture() }
        view.toolTip = "Return: new line · ⌘Return or click outside: finish · Esc: cancel"
        textView = view
        editingText = annotation
        addSubview(view)
        resizeTextEditor()
        window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        needsDisplay = true
    }

    func commitText() {
        guard let view = textView, let state else { return }
        let original = editingText
        let text = view.string
        let color = view.textColor ?? state.color
        let fontSize = view.font?.pointSize ?? state.size.fontSize
        let width = view.textContainer?.containerSize.width ?? view.frame.width
        let size = Renderer.textSize(text, color: color, fontSize: fontSize, width: width)
        let origin = CGPoint(x: view.frame.minX + screenFrame.minX, y: textTop - size.height + screenFrame.minY)
        textView = nil
        editingText = nil
        view.delegate = nil
        view.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let original { state.remove(original.id) }
            return
        }
        // Opening and closing an existing label should not create an undo step or move it.
        if let original, original.text == text { return }
        var annotation = original ?? Annotation(
            tool: .text,
            color: color,
            colorName: state.colorName,
            lineWidth: 0,
            filled: false
        )
        annotation.text = text
        annotation.textRect = CGRect(origin: origin, size: size)
        annotation.fontSize = fontSize
        annotation.textLayoutWidth = width
        if original != nil { state.update(annotation) } else { state.add(annotation) }
    }

    private func cancelText() {
        textView?.delegate = nil
        textView?.removeFromSuperview()
        textView = nil
        editingText = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func resizeTextEditor() {
        guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
        layout.ensureLayout(for: container)
        let height = max(ceil(layout.usedRect(for: container).maxY), ceil(layout.extraLineFragmentRect.maxY),
                         ceil(layout.defaultLineHeight(for: view.font ?? .systemFont(ofSize: 28))))
        view.frame = CGRect(x: view.frame.minX, y: textTop - height, width: view.frame.width, height: height)
    }

    func textDidChange(_ notification: Notification) { resizeTextEditor() }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
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
        guard window?.isKeyWindow == true, let session else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (key, event.keyCode) {
        case ("s", _):
            session.capture()
            return true
        case (_, UInt16(kVK_Return)) where textView != nil,
             (_, UInt16(kVK_ANSI_KeypadEnter)) where textView != nil:
            commitText()
            return true
        case (_, UInt16(kVK_Delete)):
            guard textView == nil else { return super.performKeyEquivalent(with: event) }
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

private final class AnnotationTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCapture: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                onCommit?()
                return true
            }
            if event.charactersIgnoringModifiers?.lowercased() == "s" {
                onCapture?()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
