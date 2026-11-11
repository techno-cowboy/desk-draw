import AppKit
import Carbon.HIToolbox
import Testing
@testable import DeskDraw

@Suite(.serialized)
@MainActor
struct TextAnnotationTests {
    private let screen = CGRect(x: 1512, y: -200, width: 1000, height: 800)

    private func fixture() -> (DrawingSession, NSWindow, CanvasView) {
        _ = NSApplication.shared
        let session = DrawingSession(state: DrawingState())
        session.state.tool = .text
        let canvas = CanvasView(screenFrame: screen, session: session)
        let window = NSWindow(contentRect: screen, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        return (session, window, canvas)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                          clickCount: clicks, pressure: 1)!
    }

    private func editor(in canvas: CanvasView) -> NSTextView? {
        canvas.subviews.compactMap { view in
            (view as? NSTextView) ?? ((view as? NSTextField)?.currentEditor() as? NSTextView)
        }.first
    }

    private func text(at rect: CGRect) -> Annotation {
        Annotation(tool: .text, color: .red, colorName: "Red", lineWidth: 0, filled: false,
                   text: "Original", textRect: rect, fontSize: 28)
    }

    @Test func returnInsertsNewlineInsteadOfCommitting() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 600), in: window))
        let input = try #require(editor(in: canvas))
        input.insertText("First", replacementRange: NSRange(location: NSNotFound, length: 0))
        input.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(session.state.annotations.isEmpty)
        #expect(editor(in: canvas) != nil)
        if editor(in: canvas) != nil {
            input.insertText("Second", replacementRange: NSRange(location: NSNotFound, length: 0))
            canvas.commitText()
            #expect(session.state.annotations.first?.text == "First\nSecond")
            #expect((session.state.annotations.first?.textRect.height ?? 0) > 50)
        }
    }

    @Test func doubleClickEditsExistingTextInPlace() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        let original = text(at: CGRect(x: screen.minX + 100, y: screen.minY + 500, width: 180, height: 40))
        session.state.add(original)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 120, y: 520), in: window, clicks: 2))
        let input = try #require(editor(in: canvas))
        #expect(input.string == "Original")
        input.string = "Edited\nAgain"
        canvas.commitText()
        #expect(session.state.annotations.count == 1)
        #expect(session.state.annotations.first?.id == original.id)
        #expect(session.state.annotations.first?.text == "Edited\nAgain")
        session.state.undo()
        #expect(session.state.annotations.first?.text == "Original")
        session.state.redo()
        #expect(session.state.annotations.first?.text == "Edited\nAgain")
    }

    @Test func dragMovesTextAndCanBeUndone() {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        let original = text(at: CGRect(x: screen.minX + 100, y: screen.minY + 500, width: 180, height: 40))
        session.state.add(original)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 120, y: 520), in: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 180, y: 550), in: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 180, y: 550), in: window))
        #expect(session.state.annotations.count == 1)
        #expect(session.state.annotations.first?.textRect.origin == original.textRect.offsetBy(dx: 60, dy: 30).origin)
        session.state.undo()
        #expect(session.state.annotations.first?.id == original.id)
        #expect(session.state.annotations.first?.textRect == original.textRect)
        session.state.redo()
        #expect(session.state.annotations.first?.textRect.origin == original.textRect.offsetBy(dx: 60, dy: 30).origin)
    }

    @Test func escapeCancelsEditingWithoutChangingTextOrHistory() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        let original = text(at: CGRect(x: screen.minX + 100, y: screen.minY + 500, width: 180, height: 40))
        session.state.add(original)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 120, y: 520), in: window, clicks: 2))
        let input = try #require(editor(in: canvas))
        input.string = "Discard this edit"
        input.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(editor(in: canvas) == nil)
        #expect(session.state.annotations.first?.text == "Original")
        session.state.undo()
        #expect(session.state.annotations.isEmpty)
    }

    @Test func commandReturnCommitsText() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 600), in: window))
        let input = try #require(editor(in: canvas))
        input.string = "First\nSecond"
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                                                keyCode: UInt16(kVK_Return)))
        #expect(input.performKeyEquivalent(with: event))
        #expect(editor(in: canvas) == nil)
        #expect(session.state.annotations.first?.text == "First\nSecond")
    }

    @Test func emptyEditRemovesOnlyThatLabelAndUndoRestoresItsOrder() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        let original = text(at: CGRect(x: screen.minX + 100, y: screen.minY + 500, width: 180, height: 40))
        let other = text(at: CGRect(x: screen.minX + 400, y: screen.minY + 500, width: 180, height: 40))
        session.state.add(original)
        session.state.add(other)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 120, y: 520), in: window, clicks: 2))
        let input = try #require(editor(in: canvas))
        input.string = "\n  "
        canvas.commitText()
        #expect(session.state.annotations.map(\.id) == [other.id])
        session.state.undo()
        #expect(session.state.annotations.map(\.id) == [original.id, other.id])
        session.state.redo()
        #expect(session.state.annotations.map(\.id) == [other.id])
    }

    @Test func wrappedTextKeepsItsLayoutAndStyleWhenReopened() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 850, y: 600), in: window))
        let input = try #require(editor(in: canvas))
        input.insertText("Words that wrap into several lines", replacementRange: NSRange(location: NSNotFound, length: 0))
        let top = input.frame.maxY + screen.minY
        let height = input.frame.height
        #expect(height > 60)
        canvas.commitText()
        let original = try #require(session.state.annotations.first)
        #expect(original.textRect.maxY == top)
        #expect(original.textRect.height == height)
        session.state.colorIndex = 4
        session.state.size = .thick
        let point = CGPoint(x: original.textRect.midX - screen.minX, y: original.textRect.maxY - screen.minY - 10)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: point, in: window, clicks: 2))
        let reopened = try #require(editor(in: canvas))
        #expect(reopened.frame.height == height)
        #expect(reopened.font?.pointSize == original.fontSize)
        #expect(reopened.textColor == original.color)
        canvas.commitText()
        #expect(session.state.annotations.first?.textRect == original.textRect)
        session.state.undo()
        #expect(session.state.annotations.isEmpty)
    }

    @Test func draggingTextCannotLoseItBeyondTheDisplayEdge() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        let original = text(at: CGRect(x: screen.minX + 100, y: screen.minY + 500, width: 180, height: 40))
        session.state.add(original)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 120, y: 520), in: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 1200, y: 900), in: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 1200, y: 900), in: window))
        let moved = try #require(session.state.annotations.first)
        #expect(screen.contains(moved.textRect))
        #expect(moved.textRect.maxX == screen.maxX)
        #expect(moved.textRect.maxY == screen.maxY)
    }

    @Test func screenshotRendersBothLinesInOrderOnAnOffsetDisplay() throws {
        let (session, window, canvas) = fixture()
        defer { window.close() }
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 600), in: window))
        let input = try #require(editor(in: canvas))
        input.string = "MMMM\nI"
        canvas.commitText()
        let annotation = try #require(session.state.annotations.first)
        let background = try #require(CGContext(data: nil, width: Int(screen.width), height: Int(screen.height),
                                                bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        background.setFillColor(NSColor.black.cgColor)
        background.fill(CGRect(origin: .zero, size: screen.size))
        let shot = try #require(background.makeImage())
        let region = annotation.bounds.integral
        let image = try #require(Capturer.compose(shot, screenFrame: screen, region: region,
                                                annotations: session.state.annotations, caption: nil))
        let bitmap = NSBitmapImageRep(cgImage: image)
        var runs: [Int] = []
        var currentRun = 0
        for y in 0..<bitmap.pixelsHigh {
            var count = 0
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if color.redComponent > 0.5 && color.greenComponent < 0.4 { count += 1 }
            }
            if count > 0 { currentRun += count }
            else if currentRun > 0 { runs.append(currentRun); currentRun = 0 }
        }
        if currentRun > 0 { runs.append(currentRun) }
        #expect(runs.count == 2)
        if runs.count == 2 { #expect(runs[0] > runs[1] * 3) }
    }
}
