<img src="assets/icon.svg" width="64" height="64" alt="">

# Desk Draw

Draw on your Mac's screen to point things out, then take a screenshot that records which app and
window you drew on. Drawings are temporary. When you stop drawing, they are gone.

Desk Draw is a menu bar app for macOS 14 or later on Apple Silicon.

## Install

Download the app ZIP from the [latest release](https://github.com/techno-cowboy/desk-draw/releases/latest),
unzip it and move `Desk Draw.app` to Applications. The app is not notarized, so macOS blocks the
first launch. To allow it, go to System Settings → Privacy & Security and click **Open Anyway**, or
run `xattr -dr com.apple.quarantine "/Applications/Desk Draw.app"`. You can also build it yourself
(see [Build](#build)).

## Use

1. Press **⌥⇧D** anywhere, or choose **Start Drawing** from the menu bar icon. A see-through layer
   with a pink frame covers the display under your mouse, and a toolbar appears at the top.
2. Draw with the pen, highlighter, line, arrow, rectangle, ellipse, text or number tool.
3. Press **⌘S** or click **Capture** to take a screenshot. Choose what it covers first:
   - **Window**: the window you drew on, plus any marks that stick out of it
   - **Drawing**: just the area around your marks
   - **Screen**: the whole display
4. Press **Esc** to stop. The drawing is discarded.

To change something you already drew, pick the **Select** tool (**V**) and click it. Then:

- Drag it to move it, or nudge it with the arrow keys (Shift for 10 points at a time).
- Drag a handle to resize it. Corners keep the opposite corner in place, and Shift keeps the
  proportions. Lines and arrows have a handle at each end; Shift snaps them to 45° steps. Dragging
  a corner of text scales its font.
- Pick a color, size or fill in the toolbar, or press its key, to restyle it.
- Press **⌫** to delete it, or **Esc** to deselect it.

Every change can be undone. Clicking the stroke of a mark selects it before the inside of an
outlined box around it, so marks inside boxes stay easy to reach.

With the **Text** tool, click to start typing. Picking a color or size while typing applies it to
the text. **Return** adds a new line; **⌘Return** or a click
outside the text finishes the annotation. Double-click existing text to edit it, or drag it to
move it. **Esc** cancels a text edit. Text edits and moves support undo and redo.

### Numbering steps

With the **Number** tool (**N**), each click places a colored dot with the next number in it: 1, 2,
3 and so on. Drag before letting go to place it exactly. The next number is always one more than the
highest number there, so removing a dot never leads to two with the same number; once all dots are
gone, counting starts at 1 again. The current color and size apply, and like any mark a dot can be
selected, moved, resized and restyled. Screenshot JSON lists each dot's number as its text.

### Whiteboard

Click the whiteboard button in the toolbar, or press **B**, to cover the display with a white board.
All the tools work on it, and white ink switches to black so it stays visible. Press **⌘S** or click
**Save** to save the whole board as an image. It goes to the same folder as screenshots and is copied
to the clipboard, and it needs no Screen Recording permission. Press **B** again to go back to
drawing on the screen; your marks stay.

A whiteboard with unsaved marks is not discarded by accident. **Esc**, the close button, **⌥⇧D**,
**Stop Drawing** and **Quit** first ask whether to save it, discard it or keep drawing. If the
display layout changes while you draw, which always stops drawing, an unsaved whiteboard is saved
first.

The session stays on the display where you started it, including screenshots. To annotate another
display, stop drawing, move your mouse there, and start again.

### Keys while drawing

| Key | Action |
| --- | --- |
| V P H L A R O T N | Select, Pen, Highlighter, Line, Arrow, Rectangle, Ellipse, Text, Number |
| Shift + drag | Straight angles, squares, circles |
| 1–8 | Colors (also recolors the selected mark) |
| `[` `]` or `-` `+` | Thinner / thicker (also the selected mark) |
| F | Fill rectangles and ellipses (also the selected one) |
| B | Whiteboard on / off |
| Arrow keys | Nudge the selected mark (Shift: 10 points) |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌫ / ⌘⌫ | Delete the selected mark, or the last one / clear all |
| W / D / S | Capture Window / Drawing / Screen |
| ⌘S | Save screenshot, or the whiteboard |
| Esc | Deselect, or stop drawing (asks first on an unsaved whiteboard) |

## Updates

Starting with version 0.3.0, Desk Draw uses [Sparkle](https://sparkle-project.org/) to check for and
install updates. The menu bar menu includes **Check for Updates…** and separate switches for
automatic checking and automatic downloading/installing. Both default to on; your choices are
remembered. A pending restart waits until you finish drawing.

Versions 0.1.0 and 0.2.0 need one manual update: quit Desk Draw, download the new ZIP, and replace
the existing app. Future updates can be installed from the app. The update feed and downloads are
signed independently of the app's macOS code signature. Ad-hoc builds may still need renewed
Screen Recording permission after an update.

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

Run `swift test` for the AppKit regression tests. After building the app, run
`./scripts/test-updates.py` to exercise a real Sparkle install/relaunch and rejection of tampered
feeds and archives using disposable apps on localhost.

See [Release process](docs/RELEASING.md) for signing keys, Developer ID signing, notarization, and
preparing the signed update feed.

## License

[MIT](LICENSE)
