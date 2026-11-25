import AppKit
import Observation

enum Tool: String, CaseIterable, Identifiable {
    case select, pen, highlighter, line, arrow, rectangle, ellipse, text, number

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .number: "Number"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "scribble.variable"
        case .highlighter: "highlighter"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .number: "1.circle"
        }
    }

    /// Single-key shortcut while drawing.
    var key: String {
        switch self {
        case .select: "v"
        case .pen: "p"
        case .highlighter: "h"
        case .line: "l"
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        case .text: "t"
        case .number: "n"
        }
    }

    var isShape: Bool { self == .rectangle || self == .ellipse }
}

enum StrokeSize: Int, CaseIterable, Identifiable {
    case thin, medium, thick

    var id: Int { rawValue }
    var lineWidth: CGFloat { [3, 6, 12][rawValue] }
    var fontSize: CGFloat { [18, 28, 44][rawValue] }
    /// Size of a number dot.
    var markerDiameter: CGFloat { [24, 32, 44][rawValue] }
    var title: String { ["Thin", "Medium", "Thick"][rawValue] }

    /// The preset an annotation uses, if it still matches one exactly.
    init?(matching annotation: Annotation) {
        let match = switch annotation.tool {
        case .text: Self.allCases.first { $0.fontSize == annotation.fontSize }
        case .number: Self.allCases.first { $0.markerDiameter == annotation.diameter }
        default: Self.allCases.first { $0.lineWidth == annotation.lineWidth }
        }
        guard let match else { return nil }
        self = match
    }
}

enum CaptureTarget: String, CaseIterable, Identifiable {
    case window, area, screen

    var id: String { rawValue }
    var title: String {
        switch self {
        case .window: "Window"
        case .area: "Drawing"
        case .screen: "Screen"
        }
    }
    var help: String {
        switch self {
        case .window: "Capture the window you drew on"
        case .area: "Capture just the area around your drawing"
        case .screen: "Capture the whole display"
        }
    }
}

struct PaletteColor {
    let name: String
    let color: NSColor
}

enum Palette {
    static let colors: [PaletteColor] = [
        PaletteColor(name: "Red", color: NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1)),
        PaletteColor(name: "Orange", color: NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1)),
        PaletteColor(name: "Yellow", color: NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1)),
        PaletteColor(name: "Green", color: NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)),
        PaletteColor(name: "Blue", color: NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1)),
        PaletteColor(name: "Purple", color: NSColor(srgbRed: 0.75, green: 0.35, blue: 0.95, alpha: 1)),
        PaletteColor(name: "White", color: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
        PaletteColor(name: "Black", color: NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)),
    ]

    static func index(named name: String) -> Int? {
        colors.firstIndex { $0.name == name }
    }
}

enum Whiteboard {
    /// The board's color, on screen and in saved images.
    static let background = NSColor.white
}

/// One mark on the screen. All geometry is in global AppKit screen coordinates
/// (origin bottom-left of the primary display), so bounds work across displays.
struct Annotation: Identifiable, Equatable {
    let id = UUID()
    var tool: Tool
    var color: NSColor
    var colorName: String
    var lineWidth: CGFloat
    var filled: Bool
    var points: [CGPoint] = []
    var text: String = ""
    var textRect: CGRect = .zero
    var fontSize: CGFloat = 0
    /// Preserve the editor's wrapping width while keeping textRect tight for hit testing and capture.
    var textLayoutWidth: CGFloat? = nil
    /// A number dot's number, and its size. Its center is `points[0]`.
    var number = 0
    var diameter: CGFloat = 0

    /// Bounds including stroke width and arrow heads; used for redraw and cropping.
    var bounds: CGRect {
        if tool == .text { return textRect.insetBy(dx: -6, dy: -6) }
        // Room for the dot's shadow.
        if tool == .number { return shapeBounds.insetBy(dx: -6, dy: -6) }
        let pad = effectiveLineWidth * 2 + (tool == .arrow ? 20 : 0)
        return shapeBounds.insetBy(dx: -pad, dy: -pad)
    }

    /// Tight geometric bounds, reported in screenshot metadata.
    var shapeBounds: CGRect {
        if tool == .text { return textRect }
        guard let first = points.first else { return .null }
        if tool == .number {
            return CGRect(x: first.x - diameter / 2, y: first.y - diameter / 2, width: diameter, height: diameter)
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var effectiveLineWidth: CGFloat { tool == .highlighter ? lineWidth * 3.2 : lineWidth }
}

/// Tool settings live for the whole app run; annotations only for one drawing session.
@MainActor
@Observable
final class DrawingState {
    var tool: Tool = .pen {
        didSet { if tool != .select { selectedID = nil } }
    }
    var colorIndex = 0
    var size: StrokeSize = .medium
    var fillShapes = false
    var captureTarget: CaptureTarget = .window
    /// The display is covered by an opaque white board instead of see-through.
    var whiteboard = false {
        didSet { if whiteboard != oldValue { onChange?() } }
    }
    var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    private(set) var annotations: [Annotation] = []
    /// The mark the Select tool is working on.
    private(set) var selectedID: Annotation.ID? {
        didSet { if selectedID != oldValue { onChange?() } }
    }
    var selection: Annotation? {
        guard let selectedID else { return nil }
        return annotations.first { $0.id == selectedID }
    }
    /// Counts changes to the marks, so a session can tell whether they changed since a save.
    @ObservationIgnored private(set) var revision = 0
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var color: NSColor { Palette.colors[colorIndex].color }
    /// The number the next number dot gets: one more than the highest one there, so
    /// removing a dot never leads to two with the same number.
    var nextNumber: Int {
        (annotations.lazy.filter { $0.tool == .number }.map(\.number).max() ?? 0) + 1
    }
    var colorName: String { Palette.colors[colorIndex].name }

    func showToast(_ message: String, seconds: Double = 3) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    @ObservationIgnored var onChange: (() -> Void)?
    /// Color or size was picked, so a text field being typed in can follow.
    @ObservationIgnored var onStyleChange: ((StyleChange) -> Void)?

    enum StyleChange { case color, size }

    // MARK: Selection and style

    /// Selects a mark and shows its style in the toolbar, so the next change starts from it.
    func select(_ id: Annotation.ID?) {
        selectedID = id
        guard let a = selection else { return }
        if let i = Palette.index(named: a.colorName) { colorIndex = i }
        if let match = StrokeSize(matching: a) { size = match }
        if a.tool.isShape { fillShapes = a.filled }
    }

    /// Picks a color for new marks and recolors the selected one.
    func setColor(_ index: Int) {
        guard Palette.colors.indices.contains(index) else { return }
        colorIndex = index
        restyleSelection { $0.withColor(Palette.colors[index]) }
        onStyleChange?(.color)
    }

    /// Picks a size for new marks and resizes the selected one's stroke or text.
    func setSize(_ size: StrokeSize) {
        self.size = size
        restyleSelection { $0.withSize(size) }
        onStyleChange?(.size)
    }

    func cycleSize(by delta: Int) {
        let next = min(max(size.rawValue + delta, 0), StrokeSize.allCases.count - 1)
        setSize(StrokeSize(rawValue: next) ?? size)
    }

    /// Toggles fill for new shapes, and for the selected shape.
    func toggleFill() {
        if let a = selection, a.tool.isShape {
            fillShapes = !a.filled
            restyleSelection { var a = $0; a.filled = fillShapes; return a }
        } else {
            fillShapes.toggle()
        }
    }

    /// Turns the whiteboard on or off. White ink would vanish on the board, so it switches to black.
    func toggleWhiteboard() {
        whiteboard.toggle()
        if whiteboard, colorName == "White", let black = Palette.index(named: "Black") {
            colorIndex = black
        }
    }

    private func restyleSelection(_ change: (Annotation) -> Annotation) {
        guard let a = selection else { return }
        let changed = change(a)
        if changed != a { update(changed) }
    }

    private enum Edit {
        case add(Annotation)
        case update(before: Annotation, after: Annotation)
        case remove(Annotation, index: Int)
        case clear([Annotation])
    }

    func add(_ annotation: Annotation) {
        annotations.append(annotation)
        undoStack.append(.add(annotation))
        redoStack.removeAll()
        revision += 1
        onChange?()
    }

    func update(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        let old = annotations[index]
        annotations[index] = annotation
        undoStack.append(.update(before: old, after: annotation))
        redoStack.removeAll()
        revision += 1
        onChange?()
    }

    func remove(_ id: Annotation.ID) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        undoStack.append(.remove(annotations.remove(at: index), index: index))
        redoStack.removeAll()
        revision += 1
        dropStaleSelection()
        onChange?()
    }

    func undo() {
        guard let edit = undoStack.popLast() else { return }
        switch edit {
        case .add(let a): annotations.removeAll { $0.id == a.id }
        case .update(let before, _):
            if let index = annotations.firstIndex(where: { $0.id == before.id }) { annotations[index] = before }
        case .remove(let a, let index): annotations.insert(a, at: min(index, annotations.count))
        case .clear(let old): annotations = old
        }
        redoStack.append(edit)
        revision += 1
        dropStaleSelection()
        onChange?()
    }

    func redo() {
        guard let edit = redoStack.popLast() else { return }
        switch edit {
        case .add(let a): annotations.append(a)
        case .update(_, let after):
            if let index = annotations.firstIndex(where: { $0.id == after.id }) { annotations[index] = after }
        case .remove(let a, _): annotations.removeAll { $0.id == a.id }
        case .clear: annotations = []
        }
        undoStack.append(edit)
        revision += 1
        dropStaleSelection()
        onChange?()
    }

    func clear() {
        guard !annotations.isEmpty else { return }
        undoStack.append(.clear(annotations))
        redoStack.removeAll()
        annotations = []
        revision += 1
        dropStaleSelection()
        onChange?()
    }

    private func dropStaleSelection() {
        if selectedID != nil, selection == nil { selectedID = nil }
    }

    /// Drops everything. Drawings are never persisted.
    func reset() {
        annotations = []
        selectedID = nil
        undoStack = []
        redoStack = []
        toast = nil
        whiteboard = false
        revision += 1
        onChange?()
    }

    /// Union of all annotation bounds, in global AppKit coordinates.
    var drawingBounds: CGRect? {
        let rects = annotations.map(\.bounds).filter { !$0.isNull }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }
}
