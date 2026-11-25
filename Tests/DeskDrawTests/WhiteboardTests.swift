import AppKit
import Carbon.HIToolbox
import Testing
@testable import DeskDraw

@Suite(.serialized)
@MainActor
struct WhiteboardTests {
    private let screen = CGRect(x: 1512, y: -200, width: 1000, height: 800)

    private func fixture() -> (DrawingSession, NSWindow, CanvasView) {
        _ = NSApplication.shared
        let session = DrawingSession(state: DrawingState())
        let canvas = CanvasView(screenFrame: screen, session: session)
        let window = NSWindow(contentRect: screen, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        return (session, window, canvas)
    }

    private func key(_ code: Int, _ chars: String = "", in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
    }

    private func line() -> Annotation {
        Annotation(tool: .line, color: Palette.colors[0].color, colorName: "Red", lineWidth: 12, filled: false,
                   points: [CGPoint(x: 1600, y: 100), CGPoint(x: 1900, y: 100)])
    }

    @Test func bKeyTogglesWhiteboardAndSwapsWhiteInkForBlack() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        session.state.setColor(try #require(Palette.index(named: "White")))
        canvas.keyDown(with: key(kVK_ANSI_B, "b", in: window))
        #expect(session.state.whiteboard)
        #expect(session.state.colorName == "Black")
        canvas.keyDown(with: key(kVK_ANSI_B, "b", in: window))
        #expect(!session.state.whiteboard)
        session.state.whiteboard = true
        session.state.reset()
        #expect(!session.state.whiteboard)
    }

    @Test func onlyAnUnsavedWhiteboardWithMarksNeedsConfirmation() {
        let (session, window, _) = fixture()
        defer { window.close() }
        session.state.add(line())
        #expect(!session.hasUnsavedWhiteboard)
        session.state.whiteboard = true
        #expect(session.hasUnsavedWhiteboard)
        session.state.clear()
        #expect(!session.hasUnsavedWhiteboard)
        session.state.undo()
        #expect(session.hasUnsavedWhiteboard)
    }

    @Test func escapeOnWhiteboardAsksAndCancelKeepsDrawing() {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        var asked = 0
        session.confirmDiscard = { asked += 1; return .cancel }
        var ended = false
        session.onEnd = { ended = true }

        session.state.whiteboard = true
        session.state.add(line())
        canvas.keyDown(with: key(kVK_Escape, "\u{1b}", in: window))
        #expect(asked == 1)
        #expect(!ended)
        #expect(session.state.annotations.count == 1)
        #expect(session.state.whiteboard)

        #expect(session.requestEnd() == false)
        #expect(asked == 2)
    }

    @Test func escapeWithoutWhiteboardDoesNotAsk() {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        var asked = 0
        session.confirmDiscard = { asked += 1; return .cancel }
        session.state.add(line())
        canvas.keyDown(with: key(kVK_Escape, "\u{1b}", in: window))
        #expect(asked == 0)

        session.state.whiteboard = true
        session.state.clear()
        #expect(session.requestEnd() == true)
        #expect(asked == 0)
    }

    @Test func savedImageIsWhiteBoardWithMarks() throws {
        let scale: CGFloat = 2
        let image = try #require(Capturer.renderWhiteboard(annotations: [line()], frame: screen, scale: scale, caption: nil))
        #expect(image.width == Int(screen.width * scale))
        #expect(image.height == Int(screen.height * scale))
        let bitmap = NSBitmapImageRep(cgImage: image)

        // Bitmap rows run top-down, from the board's top edge.
        func pixel(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
            bitmap.colorAt(x: Int((x - screen.minX) * scale), y: Int((screen.maxY - y) * scale))?.usingColorSpace(.sRGB)
        }
        let blank = try #require(pixel(1550, 600))
        #expect(blank.redComponent > 0.99 && blank.greenComponent > 0.99 && blank.blueComponent > 0.99)
        let ink = try #require(pixel(1750, 100))
        #expect(ink.redComponent > 0.9 && ink.greenComponent < 0.4)
    }
}
