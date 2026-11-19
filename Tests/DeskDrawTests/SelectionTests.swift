import AppKit
import Carbon.HIToolbox
import Testing
@testable import DeskDraw

@Suite(.serialized)
@MainActor
struct SelectionTests {
    private let screen = CGRect(x: 1512, y: -200, width: 1000, height: 800)

    private func fixture() -> (DrawingSession, NSWindow, CanvasView) {
        _ = NSApplication.shared
        let session = DrawingSession(state: DrawingState())
        session.state.tool = .select
        let canvas = CanvasView(screenFrame: screen, session: session)
        let window = NSWindow(contentRect: screen, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        return (session, window, canvas)
    }

    /// Mouse event at a global screen point.
    private func mouse(_ type: NSEvent.EventType, at global: CGPoint, in window: NSWindow,
                       clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: global.x - screen.minX, y: global.y - screen.minY),
                          modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                          eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func drag(_ canvas: CanvasView, in window: NSWindow, from a: CGPoint, to b: CGPoint,
                      flags: NSEvent.ModifierFlags = []) {
        canvas.mouseDown(with: mouse(.leftMouseDown, at: a, in: window, flags: flags))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: b, in: window, flags: flags))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: b, in: window, flags: flags))
    }

    private func key(_ code: Int, _ chars: String = "", in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
    }

    private func mark(_ tool: Tool, _ points: [CGPoint], filled: Bool = false) -> Annotation {
        Annotation(tool: tool, color: Palette.colors[0].color, colorName: "Red", lineWidth: 6, filled: filled,
                   points: points)
    }

    /// A 200×100 outlined rectangle at (1700, 100).
    private func box() -> Annotation {
        mark(.rectangle, [CGPoint(x: 1700, y: 100), CGPoint(x: 1900, y: 200)])
    }

    @Test func dragInsideOutlinedBoxMovesItAndUndoes() {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        let original = box()
        session.state.add(original)
        drag(canvas, in: window, from: CGPoint(x: 1800, y: 150), to: CGPoint(x: 1850, y: 130))
        let moved = session.state.annotations[0]
        #expect(moved.id == original.id)
        #expect(moved.points == [CGPoint(x: 1750, y: 80), CGPoint(x: 1950, y: 180)])
        #expect(session.state.selectedID == original.id)
        session.state.undo()
        #expect(session.state.annotations[0].points == original.points)
    }

    @Test func clickingWithoutDraggingOnlySelects() {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        session.state.add(box())
        drag(canvas, in: window, from: CGPoint(x: 1800, y: 150), to: CGPoint(x: 1801, y: 151))
        #expect(session.state.annotations[0].points == box().points)
        #expect(session.state.selection != nil)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 1600, y: 400), in: window))
        #expect(session.state.selection == nil)
    }

    @Test func cornerHandleResizesAndKeepsOppositeCorner() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        session.state.add(box())
        session.state.select(session.state.annotations[0].id)
        // The top-right handle sits 7 points (half the stroke + 4) outside the corner (1900, 200).
        drag(canvas, in: window, from: CGPoint(x: 1907, y: 207), to: CGPoint(x: 2007, y: 257))
        let resized = try #require(session.state.annotations.first)
        #expect(resized.frame == CGRect(x: 1700, y: 100, width: 300, height: 150))
    }

    @Test func shiftCornerResizeKeepsAspectRatio() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        session.state.add(box())
        session.state.select(session.state.annotations[0].id)
        drag(canvas, in: window, from: CGPoint(x: 1907, y: 207), to: CGPoint(x: 2103, y: 213), flags: .shift)
        let resized = try #require(session.state.annotations.first)
        #expect(resized.frame.minX == 1700 && resized.frame.minY == 100)
        #expect(abs(resized.frame.width / resized.frame.height - 2) < 0.001)
    }

    @Test func edgeHandleResizesOneAxisOnly() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        session.state.add(box())
        session.state.select(session.state.annotations[0].id)
        // Left edge middle handle.
        drag(canvas, in: window, from: CGPoint(x: 1693, y: 150), to: CGPoint(x: 1643, y: 400))
        let resized = try #require(session.state.annotations.first)
        #expect(resized.frame == CGRect(x: 1650, y: 100, width: 250, height: 100))
    }

    @Test func arrowEndpointsMoveIndependently() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        session.state.add(mark(.arrow, [CGPoint(x: 1700, y: 100), CGPoint(x: 1900, y: 300)]))
        session.state.select(session.state.annotations[0].id)
        drag(canvas, in: window, from: CGPoint(x: 1900, y: 300), to: CGPoint(x: 2000, y: 250))
        let arrow = try #require(session.state.annotations.first)
        #expect(arrow.points == [CGPoint(x: 1700, y: 100), CGPoint(x: 2000, y: 250)])
    }

    @Test func penStrokeScalesWithItsBox() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        session.state.add(mark(.pen, [CGPoint(x: 1700, y: 100), CGPoint(x: 1800, y: 200), CGPoint(x: 1900, y: 100)]))
        session.state.select(session.state.annotations[0].id)
        // Bottom-left handle; the top-right corner (1900, 200) stays.
        drag(canvas, in: window, from: CGPoint(x: 1693, y: 93), to: CGPoint(x: 1593, y: -7))
        let pen = try #require(session.state.annotations.first)
        #expect(pen.points == [CGPoint(x: 1600, y: 0), CGPoint(x: 1750, y: 200), CGPoint(x: 1900, y: 0)])
    }

    @Test func colorAndSizeRestyleTheSelectedMarkWithUndo() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        session.state.add(box())
        drag(canvas, in: window, from: CGPoint(x: 1800, y: 100), to: CGPoint(x: 1800, y: 100))
        session.state.setColor(4)
        session.state.setSize(.thick)
        session.state.toggleFill()
        let styled = try #require(session.state.annotations.first)
        #expect(styled.colorName == "Blue")
        #expect(styled.color == Palette.colors[4].color)
        #expect(styled.lineWidth == StrokeSize.thick.lineWidth)
        #expect(styled.filled)
        session.state.undo()
        session.state.undo()
        session.state.undo()
        let restored = try #require(session.state.annotations.first)
        #expect(restored.colorName == "Red" && restored.lineWidth == 6 && !restored.filled)
    }

    @Test func selectingShowsTheMarksStyleInTheToolbar() {
        let (session, window, _) = fixture()
        defer { window.close() }
        var blue = box().withColor(Palette.colors[4])
        blue.lineWidth = StrokeSize.thin.lineWidth
        blue.filled = true
        session.state.add(blue)
        session.state.select(blue.id)
        #expect(session.state.colorIndex == 4)
        #expect(session.state.size == .thin)
        #expect(session.state.fillShapes)
    }

    @Test func colorWithoutSelectionOnlyAffectsNewMarks() {
        let (session, window, _) = fixture()
        defer { window.close() }
        session.state.add(box())
        session.state.setColor(3)
        #expect(session.state.annotations[0].colorName == "Red")
        #expect(!session.state.canRedo)
    }

    @Test func textCornerScalesFontSize() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        let size = Renderer.textSize("Label", color: .red, fontSize: 28, width: 400)
        var label = Annotation(tool: .text, color: .red, colorName: "Red", lineWidth: 0, filled: false,
                               text: "Label", textRect: CGRect(origin: CGPoint(x: 1700, y: 300), size: size), fontSize: 28)
        label.textLayoutWidth = 400
        session.state.add(label)
        session.state.select(label.id)
        // Drag the top-right corner to twice the width; the bottom-left corner stays.
        let corner = CGPoint(x: label.textRect.maxX + 4, y: label.textRect.maxY + 4)
        drag(canvas, in: window, from: corner, to: CGPoint(x: label.textRect.minX + size.width * 2 + 4, y: corner.y))
        let scaled = try #require(session.state.annotations.first)
        #expect(scaled.fontSize == 56)
        #expect(scaled.textLayoutWidth == 800)
        #expect(scaled.textRect.minX == label.textRect.minX)
        #expect(scaled.textRect.minY == label.textRect.minY)
        #expect(scaled.textRect.width > size.width * 1.8)
    }

    @Test func textSizeButtonResizesSelectedText() throws {
        let (session, window, _) = fixture()
        defer { window.close() }
        let size = Renderer.textSize("Label", color: .red, fontSize: 28, width: 400)
        let label = Annotation(tool: .text, color: .red, colorName: "Red", lineWidth: 0, filled: false,
                               text: "Label", textRect: CGRect(origin: CGPoint(x: 1700, y: 300), size: size), fontSize: 28)
        session.state.add(label)
        session.state.select(label.id)
        session.state.setSize(.thick)
        let bigger = try #require(session.state.annotations.first)
        #expect(bigger.fontSize == StrokeSize.thick.fontSize)
        #expect(bigger.textRect.maxY == label.textRect.maxY)
        #expect(bigger.textRect.height > label.textRect.height)
    }

    @Test func strokeInsideBoxWinsOverTheBox() {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        session.state.add(box())
        let line = mark(.line, [CGPoint(x: 1750, y: 150), CGPoint(x: 1850, y: 150)])
        session.state.add(line)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 1800, y: 152), in: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 1800, y: 152), in: window))
        #expect(session.state.selectedID == line.id)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 1720, y: 120), in: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 1720, y: 120), in: window))
        #expect(session.state.selectedID == session.state.annotations[0].id)
    }

    @Test func deleteRemovesSelectionAndEscapeDeselects() {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        let first = box()
        let second = mark(.line, [CGPoint(x: 2000, y: 0), CGPoint(x: 2100, y: 0)])
        session.state.add(first)
        session.state.add(second)
        session.state.select(first.id)
        canvas.keyDown(with: key(kVK_Delete, "\u{7f}", in: window))
        #expect(session.state.annotations.map(\.id) == [second.id])
        #expect(session.state.selection == nil)
        session.state.select(second.id)
        canvas.keyDown(with: key(kVK_Escape, "\u{1b}", in: window))
        #expect(session.state.selection == nil)
        #expect(session.state.annotations.count == 1)
    }

    @Test func arrowKeysNudgeSelection() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        session.state.add(box())
        session.state.select(session.state.annotations[0].id)
        canvas.keyDown(with: key(kVK_RightArrow, in: window))
        canvas.keyDown(with: key(kVK_UpArrow, in: window))
        let moved = try #require(session.state.annotations.first)
        #expect(moved.frame.origin == CGPoint(x: 1701, y: 101))
    }

    @Test func switchingToolsClearsSelection() {
        let (session, window, _) = fixture()
        defer { window.close() }
        session.state.add(box())
        session.state.select(session.state.annotations[0].id)
        session.state.tool = .pen
        #expect(session.state.selection == nil)
    }

    @Test func colorPickedWhileTypingAppliesToTheText() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        session.state.tool = .text
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 1700, y: 300), in: window))
        let input = try #require(canvas.subviews.compactMap { $0 as? NSTextView }.first)
        input.insertText("Hello", replacementRange: NSRange(location: NSNotFound, length: 0))
        session.state.setColor(4)
        session.state.setSize(.thick)
        #expect(input.textColor == Palette.colors[4].color)
        canvas.commitText()
        let label = try #require(session.state.annotations.first)
        #expect(label.colorName == "Blue")
        #expect(label.fontSize == StrokeSize.thick.fontSize)
    }
}
