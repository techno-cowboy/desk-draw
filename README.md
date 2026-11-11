<img src="assets/icon.svg" width="64" height="64" alt="">

# Desk Draw

Draw on your Mac's screen to point things out, then take a screenshot that records which app and
window you drew on. Drawings are temporary. When you stop drawing, they are gone.

Desk Draw is a menu bar app for macOS 14 or later on Apple Silicon.

## Install

Download `Desk-Draw-0.2.0.zip` from the [latest release](https://github.com/techno-cowboy/desk-draw/releases/latest),
unzip it and move `Desk Draw.app` to Applications. The app is not notarized, so macOS blocks the
first launch. To allow it, go to System Settings → Privacy & Security and click **Open Anyway**, or
run `xattr -dr com.apple.quarantine "/Applications/Desk Draw.app"`. You can also build it yourself
(see [Build](#build)).

## Use

1. Press **⌥⇧D** anywhere, or choose **Start Drawing** from the menu bar icon. A see-through layer
   with a pink frame covers the display under your mouse, and a toolbar appears at the top.
2. Draw with the pen, highlighter, line, arrow, rectangle, ellipse or text tool.
3. Press **⌘S** or click **Capture** to take a screenshot. Choose what it covers first:
   - **Window**: the window you drew on, plus any marks that stick out of it
   - **Drawing**: just the area around your marks
   - **Screen**: the whole display
4. Press **Esc** to stop. The drawing is discarded.

With the **Text** tool, click to start typing. **Return** adds a new line; **⌘Return** or a click
outside the text finishes the annotation. Double-click existing text to edit it, or drag it to
move it. **Esc** cancels a text edit. Text edits and moves support undo and redo.

The session stays on the display where you started it, including screenshots. To annotate another
display, stop drawing, move your mouse there, and start again.

### Keys while drawing

| Key | Action |
| --- | --- |
| P H L A R O T | Pen, Highlighter, Line, Arrow, Rectangle, Ellipse, Text |
| Shift + drag | Straight angles, squares, circles |
| 1–8 | Colors |
| `[` `]` or `-` `+` | Thinner / thicker |
| F | Fill rectangles and ellipses |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌫ / ⌘⌫ | Remove last mark / clear all |
| W / D / S | Capture Window / Drawing / Screen |
| ⌘S | Save screenshot |
| Esc | Stop drawing |

## Screenshots and their context

Screenshots go to `~/Pictures/Desk Draw/` and are copied to the clipboard. Each one records:

- The app and window title you drew on, and the URL and title of the active tab in Safari, Chrome,
  Brave, Edge, Arc, Vivaldi or Chromium
- A caption strip below the image with the app icon, window title, URL and time
- The same details in the PNG's description field
- A `.json` file next to the image with the app, window, URL, display, captured region, and each
  mark's type, color, text and position in image pixels. This makes the screenshot easy to hand to
  an AI agent.

You can turn the caption, JSON file, browser URL and clipboard copy on or off in the menu bar menu.

## Permissions

- **Screen Recording**: needed to take screenshots and read window titles. macOS asks on first
  launch. After you allow it, quit and reopen Desk Draw.
- **Automation**: macOS asks the first time Desk Draw reads a browser's tab URL.

## Build

```sh
./scripts/build-app.sh            # builds build/Desk Draw.app
./scripts/build-app.sh --install  # also copies it to ~/Applications and launches it
```

The app is signed ad hoc. macOS ties the Screen Recording permission to the signature, so after a
rebuild you may have to turn Desk Draw off and on again under System Settings → Privacy & Security →
Screen Recording.

`DeskDraw --render-sample out.png` renders a test screenshot from a synthetic display. Use it to
check drawing and coordinate math without Screen Recording permission.

## License

[MIT](LICENSE)
