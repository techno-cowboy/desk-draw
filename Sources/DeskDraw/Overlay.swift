import AppKit
import Carbon.HIToolbox
import QuartzCore

enum Levels {
    /// Above the menu bar, Dock and other apps' floating panels.
    static let overlay = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
    static let toolbar = NSWindow.Level.screenSaver
    /// Questions asked while drawing, above everything else.
    static let alert = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
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

    /// A new mark being drawn, or the live preview of a mark being moved or resized.
    private var current: Annotation?
    private var dragStart: CGPoint = .zero
    private var textView: AnnotationTextView?
    private var editingText: Annotation?
    /// The mark as it was before the current move or resize.
    private var transforming: Annotation?
    private var activeHandle: SelectionHandle?
    private var didDrag = false
    private var textTop: CGFloat = 0

    static let accent = NSColor(srgbRed: 0.75, green: 0.15, blue: 0.83, alpha: 1)

    init(screenFrame: CGRect, session: DrawingSession) {
        self.screenFrame = screenFrame
        self.session = session
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
        session.state.onStyleChange = { [weak self] change in self?.applyStyleToEditor(change) }
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

        if state.whiteboard {
            Whiteboard.background.setFill()
        } else {
            // A barely-there tint so the window always hit-tests as opaque.
            NSColor(white: 0, alpha: 0.008).setFill()
        }
        dirtyRect.fill()

        ctx.saveGState()
        ctx.translateBy(x: -screenFrame.minX, y: -screenFrame.minY)
        let visible = dirtyRect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
        for annotation in state.annotations where annotation.bounds.intersects(visible) {
            if annotation.id == editingText?.id || annotation.id == transforming?.id { continue }
            Renderer.draw(annotation, in: ctx)
        }
        if let current { Renderer.draw(current, in: ctx) }
        if state.tool == .select, editingText == nil, let selected = shownSelection {
            drawSelection(selected, in: ctx)
        }
        ctx.restoreGState()

        // Frame that marks drawing mode. Never ends up in screenshots.
        let border = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        border.lineWidth = 4
        Self.accent.withAlphaComponent(0.75).setStroke()
        border.stroke()
    }

    /// The selected mark, including an unfinished move or resize.
    private var shownSelection: Annotation? {
        guard let id = state?.selectedID else { return nil }
        if let current, current.id == id { return current }
        return state?.selection
    }

    private func drawSelection(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let accent = Self.accent.cgColor
        if !a.isSegment {
            let pad = selectionPad(a)
            let box = a.frame.insetBy(dx: -pad, dy: -pad)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.stroke(box.insetBy(dx: -1, dy: -1))
            ctx.setStrokeColor(accent)
            ctx.stroke(box)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        for handle in a.handles {
            let c = handlePosition(handle, of: a)
            let dot = CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: dot)
            ctx.setLineWidth(2)
            ctx.setStrokeColor(accent)
            ctx.strokeEllipse(in: dot)
        }
    }

    /// Space between a mark's geometry and its dashed outline, so the outline clears the stroke.
    private func selectionPad(_ a: Annotation) -> CGFloat {
        a.tool == .text || a.tool == .number ? 4 : a.effectiveLineWidth / 2 + 4
    }

    /// Box handles sit on the dashed outline, just outside the mark.
    private func handlePosition(_ handle: SelectionHandle, of a: Annotation) -> CGPoint {
        let p = a.position(of: handle)
        guard case .box(let x, let y) = handle else { return p }
        let pad = selectionPad(a)
        return CGPoint(x: p.x + CGFloat(x - 1) * pad, y: p.y + CGFloat(y - 1) * pad)
    }

    /// Redraw area for a mark and its selection handles.
    private func dirtyRect(_ a: Annotation) -> CGRect {
        let pad = selectionPad(a) + 8
        return a.frame.isNull ? a.bounds : a.bounds.union(a.frame.insetBy(dx: -pad, dy: -pad))
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
        guard transforming == nil else { return }
        let p = global(event)
        switch state?.tool {
        case .text where text(at: p) != nil:
            NSCursor.openHand.set()
        case .select:
            if let selected = state?.selection, let handle = handle(at: p, of: selected) {
                Self.cursor(for: handle).set()
            } else if annotation(at: p) != nil {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        default:
            updateCursor()
        }
    }

    func updateCursor() {
        switch state?.tool {
        case .select: NSCursor.arrow.set()
        case .text: NSCursor.iBeam.set()
        default: NSCursor.crosshair.set()
        }
    }

    private static func cursor(for handle: SelectionHandle) -> NSCursor {
        guard case .box(let x, let y) = handle else { return .crosshair }
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition = switch (x, y) {
            case (0, 0): .bottomLeft
            case (2, 0): .bottomRight
            case (0, 2): .topLeft
            case (2, 2): .topRight
            case (1, 0): .bottom
            case (1, 2): .top
            case (0, _): .left
            default: .right
            }
            return .frameResize(position: position, directions: .all)
        }
        if x == 1 { return .resizeUpDown }
        if y == 1 { return .resizeLeftRight }
        return .crosshair
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
                    beginTransform(annotation, handle: nil, at: p)
                }
            } else {
                beginText(at: p)
            }
            return
        }
        if state.tool == .select {
            if let selected = state.selection, let handle = handle(at: p, of: selected) {
                beginTransform(selected, handle: handle, at: p)
                return
            }
            guard let hit = annotation(at: p) else {
                state.select(nil)
                return
            }
            state.select(hit.id)
            if hit.tool == .text, event.clickCount >= 2 {
                beginText(at: p, editing: hit)
            } else {
                beginTransform(hit, handle: nil, at: p)
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
        if state.tool == .number {
            current?.number = state.nextNumber
            current?.diameter = state.size.markerDiameter
        }
        invalidate(current)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var annotation = current else { return }
        let old = annotation.bounds
        var p = global(event)
        if let original = transforming {
            if !didDrag {
                guard hypot(p.x - dragStart.x, p.y - dragStart.y) >= 3 else { return }
                didDrag = true
            }
            if let activeHandle {
                // Keep the grab offset, so the mark does not jump to the pointer.
                let grab = original.position(of: activeHandle)
                let target = CGPoint(x: p.x - (dragStart.x - grab.x), y: p.y - (dragStart.y - grab.y))
                let clamped = CGPoint(x: min(max(target.x, screenFrame.minX), screenFrame.maxX),
                                      y: min(max(target.y, screenFrame.minY), screenFrame.maxY))
                annotation = original.resized(activeHandle, to: clamped,
                                              proportional: event.modifierFlags.contains(.shift))
            } else {
                annotation = original.translated(by: CGVector(dx: p.x - dragStart.x, dy: p.y - dragStart.y),
                                                 within: screenFrame)
            }
            let previous = current ?? original
            current = annotation
            setNeedsDisplay(local(dirtyRect(previous).union(dirtyRect(annotation))))
            return
        }
        switch annotation.tool {
        case .pen, .highlighter:
            if let last = annotation.points.last, hypot(p.x - last.x, p.y - last.y) < 1 { return }
            annotation.points.append(p)
        case .number:
            // Dragging places the dot exactly before letting go.
            annotation.points = [p]
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
        if let original = transforming {
            transforming = nil
            activeHandle = nil
            if annotation != original { state?.update(annotation) }
            setNeedsDisplay(local(dirtyRect(original).union(dirtyRect(annotation))))
            mouseMoved(with: event)
            return
        }
        let isPlaced = [.pen, .highlighter, .number].contains(annotation.tool)
        let size = annotation.shapeBounds
        if isPlaced || max(size.width, size.height) >= 4 {
            state?.add(annotation) // triggers redraw of the overlay
        } else {
            invalidate(annotation)
        }
    }

    private func beginTransform(_ annotation: Annotation, handle: SelectionHandle?, at p: CGPoint) {
        dragStart = p
        didDrag = false
        transforming = annotation
        activeHandle = handle
        current = annotation
        if handle == nil { NSCursor.closedHand.set() }
    }

    // MARK: Selection

    /// The topmost mark under `p`. Strokes win over the inside of an outlined
    /// box, so marks drawn inside a box stay reachable.
    private func annotation(at p: CGPoint) -> Annotation? {
        guard let marks = state?.annotations else { return nil }
        if let hit = marks.last(where: { $0.hitsStroke(p) }) { return hit }
        return marks.filter { $0.interiorContains(p) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private func handle(at p: CGPoint, of a: Annotation) -> SelectionHandle? {
        a.handles
            .map { ($0, hypot(handlePosition($0, of: a).x - p.x, handlePosition($0, of: a).y - p.y)) }
            .filter { $0.1 <= 9 }
            .min { $0.1 < $1.1 }?.0
    }

    private func nudgeSelection(_ dx: CGFloat, _ dy: CGFloat) {
        guard let state, let selected = state.selection else { return }
        let moved = selected.translated(by: CGVector(dx: dx, dy: dy), within: screenFrame)
        if moved != selected { state.update(moved) }
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
        view.colorName = annotation?.colorName ?? state.colorName
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
        // Start from the label as it is now: its color or size may have changed while editing.
        let original = editingText.map { edited in state.annotations.first { $0.id == edited.id } ?? edited }
        let text = view.string
        let color = view.textColor ?? state.color
        let colorName = view.colorName ?? state.colorName
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
        if let original, original.text == text, original.colorName == colorName, original.fontSize == fontSize { return }
        var annotation = original ?? Annotation(
            tool: .text,
            color: color,
            colorName: colorName,
            lineWidth: 0,
            filled: false
        )
        annotation.color = color
        annotation.colorName = colorName
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

    /// A color or size picked while typing applies to the text being typed.
    private func applyStyleToEditor(_ change: DrawingState.StyleChange) {
        guard let view = textView, let state else { return }
        var color = view.textColor ?? state.color
        var fontSize = view.font?.pointSize ?? state.size.fontSize
        switch change {
        case .color:
            color = state.color
            view.colorName = state.colorName
        case .size:
            fontSize = state.size.fontSize
        }
        let attributes = Renderer.textAttributes(color: color, fontSize: fontSize)
        view.font = attributes[.font] as? NSFont
        view.textColor = color
        view.insertionPointColor = color
        view.typingAttributes = attributes
        if let storage = view.textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        resizeTextEditor()
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
            if state.selection != nil { state.select(nil) } else { session.requestEnd() }
            return
        }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            if let selected = state.selection { state.remove(selected.id) } else { state.undo() }
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control]) else { return }
        if state.selection != nil {
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            switch Int(event.keyCode) {
            case kVK_LeftArrow: nudgeSelection(-step, 0); return
            case kVK_RightArrow: nudgeSelection(step, 0); return
            case kVK_UpArrow: nudgeSelection(0, step); return
            case kVK_DownArrow: nudgeSelection(0, -step); return
            default: break
            }
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if let tool = Tool.allCases.first(where: { $0.key == key }) {
            state.tool = tool
            updateCursor()
        } else if let n = Int(key), (1...Palette.colors.count).contains(n) {
            state.setColor(n - 1)
        } else if ["[", "-"].contains(key) {
            state.cycleSize(by: -1)
        } else if ["]", "+", "="].contains(key) {
            state.cycleSize(by: 1)
        } else if key == "f" {
            state.toggleFill()
        } else if key == "b" {
            state.toggleWhiteboard()
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
    var colorName: String?
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
