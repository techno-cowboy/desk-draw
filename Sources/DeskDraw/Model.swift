import AppKit
import Observation

enum Tool: String, CaseIterable, Identifiable {
    case pen, highlighter, line, arrow, rectangle, ellipse, text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "scribble.variable"
        case .highlighter: "highlighter"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        }
    }

    /// Single-key shortcut while drawing.
    var key: String {
        switch self {
        case .pen: "p"
        case .highlighter: "h"
        case .line: "l"
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        case .text: "t"
        }
    }

    var isShape: Bool { self == .rectangle || self == .ellipse }
}

enum StrokeSize: Int, CaseIterable, Identifiable {
    case thin, medium, thick

    var id: Int { rawValue }
    var lineWidth: CGFloat { [3, 6, 12][rawValue] }
    var fontSize: CGFloat { [18, 28, 44][rawValue] }
    var title: String { ["Thin", "Medium", "Thick"][rawValue] }
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
}

/// One mark on the screen. All geometry is in global AppKit screen coordinates
/// (origin bottom-left of the primary display), so bounds work across displays.
struct Annotation: Identifiable {
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

    /// Bounds including stroke width and arrow heads; used for redraw and cropping.
    var bounds: CGRect {
        if tool == .text { return textRect.insetBy(dx: -6, dy: -6) }
        let pad = effectiveLineWidth * 2 + (tool == .arrow ? 20 : 0)
        return shapeBounds.insetBy(dx: -pad, dy: -pad)
    }

    /// Tight geometric bounds, reported in screenshot metadata.
    var shapeBounds: CGRect {
        if tool == .text { return textRect }
        guard let first = points.first else { return .null }
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
    var tool: Tool = .pen
    var colorIndex = 0
    var size: StrokeSize = .medium
    var fillShapes = false
    var captureTarget: CaptureTarget = .window
    var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    private(set) var annotations: [Annotation] = []
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var color: NSColor { Palette.colors[colorIndex].color }
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

    private enum Edit {
        case add(Annotation)
        case clear([Annotation])
    }

    func add(_ annotation: Annotation) {
        annotations.append(annotation)
        undoStack.append(.add(annotation))
        redoStack.removeAll()
        onChange?()
    }

    func undo() {
        guard let edit = undoStack.popLast() else { return }
        switch edit {
        case .add(let a): annotations.removeAll { $0.id == a.id }
        case .clear(let old): annotations = old
        }
        redoStack.append(edit)
        onChange?()
    }

    func redo() {
        guard let edit = redoStack.popLast() else { return }
        switch edit {
        case .add(let a): annotations.append(a)
        case .clear: annotations = []
        }
        undoStack.append(edit)
        onChange?()
    }

    func clear() {
        guard !annotations.isEmpty else { return }
        undoStack.append(.clear(annotations))
        redoStack.removeAll()
        annotations = []
        onChange?()
    }

    /// Drops everything. Drawings are never persisted.
    func reset() {
        annotations = []
        undoStack = []
        redoStack = []
        toast = nil
        onChange?()
    }

    /// Union of all annotation bounds, in global AppKit coordinates.
    var drawingBounds: CGRect? {
        let rects = annotations.map(\.bounds).filter { !$0.isNull }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    func cycleSize(by delta: Int) {
        let next = min(max(size.rawValue + delta, 0), StrokeSize.allCases.count - 1)
        size = StrokeSize(rawValue: next) ?? size
    }
}
