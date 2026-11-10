import AppKit
import SwiftUI

/// Floating toolbar. It never becomes key, so the keyboard stays on the canvas.
final class ToolbarPanel: NSPanel {
    init(session: DrawingSession, on screen: NSScreen) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = Levels.toolbar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true
        appearance = NSAppearance(named: .darkAqua)

        let hosting = NSHostingView(rootView: ToolbarView(session: session, state: session.state))
        let size = hosting.fittingSize
        // Extra room below the bar for status messages.
        let panelSize = CGSize(width: size.width, height: size.height + 44)
        hosting.frame = CGRect(origin: .zero, size: panelSize)
        contentView = hosting

        let visible = screen.visibleFrame
        setFrame(CGRect(
            x: (visible.midX - panelSize.width / 2).rounded(),
            y: visible.maxY - panelSize.height - 4,
            width: panelSize.width,
            height: panelSize.height
        ), display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct ToolbarView: View {
    let session: DrawingSession
    @Bindable var state: DrawingState

    var body: some View {
        VStack(spacing: 8) {
            bar
            if let toast = state.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.8), in: Capsule())
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.toast)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var bar: some View {
        HStack(spacing: 4) {
            DragHandle()
                .frame(width: 16, height: 30)
                .overlay(Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.secondary).rotationEffect(.degrees(90)).allowsHitTesting(false))
                .help("Drag to move the toolbar")

            ForEach(Tool.allCases) { tool in
                IconButton(symbol: tool.symbol, selected: state.tool == tool,
                           help: "\(tool.title) (\(tool.key.uppercased()))") {
                    state.tool = tool
                }
            }

            separator

            ForEach(Palette.colors.indices, id: \.self) { i in
                Button { state.colorIndex = i } label: {
                    Circle()
                        .fill(Color(nsColor: Palette.colors[i].color))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                        .padding(3)
                        .overlay(Circle().strokeBorder(state.colorIndex == i ? Color.white : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .help("\(Palette.colors[i].name) (\(i + 1))")
            }

            separator

            ForEach(StrokeSize.allCases) { size in
                Button { state.size = size } label: {
                    Circle()
                        .fill(state.size == size ? Color.white : Color.secondary)
                        .frame(width: 4 + CGFloat(size.rawValue) * 4, height: 4 + CGFloat(size.rawValue) * 4)
                        .frame(width: 22, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(size.title) ([ and ] change size)")
            }
            IconButton(symbol: state.fillShapes ? "square.fill" : "square", selected: state.fillShapes,
                       help: "Fill rectangles and ellipses (F)") {
                state.fillShapes.toggle()
            }

            separator

            IconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)") { state.undo() }
                .disabled(!state.canUndo)
            IconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { state.redo() }
                .disabled(!state.canRedo)
            IconButton(symbol: "trash", help: "Clear all (⌘⌫)") { state.clear() }
                .disabled(state.annotations.isEmpty)

            separator

            Picker("Capture", selection: $state.captureTarget) {
                ForEach(CaptureTarget.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("What the screenshot covers (W / D / S)")

            Button { session.capture() } label: {
                Label("Capture", systemImage: "camera.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Color(nsColor: CanvasView.accent), in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Save a screenshot with context and copy it (⌘S)")

            IconButton(symbol: "xmark", help: "Stop drawing and discard (Esc)") { session.end() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .fixedSize()
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 20).padding(.horizontal, 3)
    }
}

private struct IconButton: View {
    let symbol: String
    var selected = false
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(selected ? Color.white : (isEnabled ? Color.primary : Color.secondary.opacity(0.5)))
                .background(selected ? Color(nsColor: CanvasView.accent) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct DragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }

    func makeNSView(context: Context) -> NSView { HandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
