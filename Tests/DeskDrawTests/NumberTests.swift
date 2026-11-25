import AppKit
import Carbon.HIToolbox
import Testing
@testable import DeskDraw

@Suite(.serialized)
@MainActor
struct NumberTests {
    private let screen = CGRect(x: 1512, y: -200, width: 1000, height: 800)

    private func fixture() -> (DrawingSession, NSWindow, CanvasView) {
        _ = NSApplication.shared
        let session = DrawingSession(state: DrawingState())
        session.state.tool = .number
        let canvas = CanvasView(screenFrame: screen, session: session)
        let window = NSWindow(contentRect: screen, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        return (session, window, canvas)
    }

    private func mouse(_ type: NSEvent.EventType, at global: CGPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: global.x - screen.minX, y: global.y - screen.minY),
                          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                          eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func click(_ canvas: CanvasView, in window: NSWindow, at p: CGPoint) {
        canvas.mouseDown(with: mouse(.leftMouseDown, at: p, in: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: p, in: window))
    }

    private func numbers(_ state: DrawingState) -> [Int] {
        state.annotations.filter { $0.tool == .number }.map(\.number)
    }

    @Test func clicksPlaceSequentialNumbersInTheCurrentStyle() {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        session.state.setColor(4)
        session.state.setSize(.thick)
        for x in [1600, 1700, 1800] { click(canvas, in: window, at: CGPoint(x: x, y: 100)) }
        #expect(numbers(session.state) == [1, 2, 3])
        let first = session.state.annotations[0]
        #expect(first.points == [CGPoint(x: 1600, y: 100)])
        #expect(first.colorName == "Blue")
        #expect(first.diameter == StrokeSize.thick.markerDiameter)
    }

    @Test func numbersContinueAfterRemovalAndRestartWhenAllAreGone() {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        for x in [1600, 1700, 1800] { click(canvas, in: window, at: CGPoint(x: x, y: 100)) }
        session.state.remove(session.state.annotations[1].id)
        click(canvas, in: window, at: CGPoint(x: 1900, y: 100))
        #expect(numbers(session.state) == [1, 3, 4])

        session.state.undo()
        #expect(session.state.nextNumber == 4)
        session.state.clear()
        click(canvas, in: window, at: CGPoint(x: 1600, y: 100))
        #expect(numbers(session.state) == [1])
    }

    @Test func draggingPlacesTheDotWhereItIsReleased() {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 1600, y: 100), in: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 1650, y: 140), in: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 1650, y: 140), in: window))
        #expect(session.state.annotations.map(\.points) == [[CGPoint(x: 1650, y: 140)]])
    }

    @Test func selectedDotMovesResizesAndRestylesWithUndo() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        click(canvas, in: window, at: CGPoint(x: 1700, y: 100))
        let original = try #require(session.state.annotations.first)
        session.state.tool = .select

        // Clicking the dot selects it; dragging it moves it.
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 1705, y: 100), in: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 1755, y: 80), in: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 1755, y: 80), in: window))
        #expect(session.state.selectedID == original.id)
        #expect(session.state.annotations[0].points == [CGPoint(x: 1750, y: 80)])

        // Corners scale the dot and keep the opposite corner in place.
        let moved = session.state.annotations[0]
        let resized = moved.resized(.box(x: 2, y: 2), to: CGPoint(x: moved.frame.maxX + 32, y: moved.frame.maxY),
                                    proportional: false)
        #expect(resized.diameter == moved.diameter * 2)
        #expect(resized.frame.origin == moved.frame.origin)
        #expect(moved.handles.count == 4)

        session.state.setSize(.thin)
        session.state.setColor(2)
        #expect(session.state.annotations[0].diameter == StrokeSize.thin.markerDiameter)
        #expect(session.state.annotations[0].colorName == "Yellow")
        #expect(session.state.annotations[0].number == 1)
        session.state.undo()
        session.state.undo()
        #expect(session.state.annotations[0].diameter == original.diameter)
    }

    @Test func nKeyPicksTheNumberTool() {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        session.state.tool = .pen
        canvas.keyDown(with: NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: UInt16(kVK_ANSI_N))!)
        #expect(session.state.tool == .number)
    }

    @Test func dotRendersInItsColorWithANumberThatContrasts() throws {
        var dot = Annotation(tool: .number, color: Palette.colors[0].color, colorName: "Red", lineWidth: 6,
                             filled: false, points: [CGPoint(x: 1712, y: 100)])
        dot.number = 1
        dot.diameter = 44
        let scale: CGFloat = 2
        let image = try #require(Capturer.renderWhiteboard(annotations: [dot], frame: screen, scale: scale, caption: nil))
        let bitmap = NSBitmapImageRep(cgImage: image)
        func pixel(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
            bitmap.colorAt(x: Int((x - screen.minX) * scale), y: Int((screen.maxY - y) * scale))?.usingColorSpace(.sRGB)
        }
        // Inside the dot, clear of the digit: red.
        let fill = try #require(pixel(1712 - 13, 100 - 10))
        #expect(fill.redComponent > 0.9 && fill.greenComponent < 0.4)
        // Somewhere on the digit "1" there is white ink.
        let column = (-6...6).compactMap { dy in pixel(1712, 100 + CGFloat(dy) * 2) }
        #expect(column.contains { $0.greenComponent > 0.9 && $0.blueComponent > 0.9 })
    }
}
