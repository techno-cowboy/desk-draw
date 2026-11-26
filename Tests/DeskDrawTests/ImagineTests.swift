import AppKit
import Foundation
import Testing
@testable import DeskDraw

@MainActor
struct ImagineMarkTests {
    private func mark(_ tool: Tool, _ points: [CGPoint]) -> Annotation {
        Annotation(tool: tool, color: .red, colorName: "Red", lineWidth: 6, filled: false, points: points)
    }

    private func loop(center c: CGPoint, radius r: CGFloat, turn: CGFloat = 1) -> [CGPoint] {
        (0...40).map { i in
            let a = CGFloat(i) / 40 * 2 * .pi * turn
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
    }

    @Test func rectanglesEllipsesAndClosedLoopsCircleAnArea() {
        #expect(mark(.rectangle, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 60)]).circlesArea)
        #expect(mark(.ellipse, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 60)]).circlesArea)
        #expect(mark(.pen, loop(center: CGPoint(x: 200, y: 200), radius: 60)).circlesArea)
        // Hand-drawn circles rarely close exactly.
        #expect(mark(.pen, loop(center: CGPoint(x: 200, y: 200), radius: 60, turn: 0.93)).circlesArea)
        #expect(mark(.highlighter, loop(center: CGPoint(x: 200, y: 200), radius: 60)).circlesArea)
    }

    @Test func openStrokesLinesAndTinyShapesDont() {
        #expect(!mark(.pen, loop(center: CGPoint(x: 200, y: 200), radius: 60, turn: 0.5)).circlesArea)
        #expect(!mark(.pen, (0...20).map { CGPoint(x: CGFloat($0) * 10, y: 0) }).circlesArea)
        #expect(!mark(.arrow, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)]).circlesArea)
        #expect(!mark(.line, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)]).circlesArea)
        #expect(!mark(.rectangle, [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 60)]).circlesArea)
    }

    @Test func theBoxCoversTheMarkAndItsStroke() {
        let a = mark(.rectangle, [CGPoint(x: 10, y: 20), CGPoint(x: 110, y: 80)])
        #expect(a.imagineBox.contains(a.bounds.insetBy(dx: a.effectiveLineWidth, dy: a.effectiveLineWidth)))
        #expect(a.imagineBox.contains(a.shapeBounds))
    }

    @Test func theLatestCircleIsTheCandidateUnlessAnotherIsSelected() {
        let state = DrawingState()
        let first = mark(.rectangle, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 60)])
        let second = mark(.ellipse, [CGPoint(x: 300, y: 0), CGPoint(x: 400, y: 60)])
        let arrow = mark(.arrow, [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50)])
        state.add(first)
        state.add(second)
        state.add(arrow)
        #expect(state.imagineCandidate?.id == second.id)
        state.select(first.id)
        #expect(state.imagineCandidate?.id == first.id)
        state.select(arrow.id)
        #expect(state.imagineCandidate?.id == second.id)
        state.toggleWhiteboard()
        #expect(state.imagineCandidate == nil)
    }

    @Test func textNearTheBoxStartsTheRequest() {
        let state = DrawingState()
        var top = Annotation(tool: .text, color: .red, colorName: "Red", lineWidth: 0, filled: false)
        top.text = "make it blue"
        top.textRect = CGRect(x: 10, y: 130, width: 100, height: 20)
        var below = top
        below = Annotation(tool: .text, color: .red, colorName: "Red", lineWidth: 0, filled: false)
        below.text = "and bigger"
        below.textRect = CGRect(x: 10, y: 40, width: 100, height: 20)
        var far = Annotation(tool: .text, color: .red, colorName: "Red", lineWidth: 0, filled: false)
        far.text = "unrelated"
        far.textRect = CGRect(x: 900, y: 900, width: 100, height: 20)
        state.add(below)
        state.add(far)
        state.add(top)
        #expect(state.notes(near: CGRect(x: 0, y: 0, width: 200, height: 120)) == "make it blue\nand bigger")
    }

    @Test func pressingIWithoutACircleExplainsWhatToDo() {
        _ = NSApplication.shared
        let session = DrawingSession(state: DrawingState())
        session.beginImagine()
        #expect(session.state.toast?.contains("Circle something first") == true)
        #expect(session.state.imagineBox == nil)
    }
}

struct ImagineGitTests {
    private func shell(_ command: String, in dir: URL) throws {
        let out = try Shell.run("/bin/sh", ["-c", command], in: dir)
        #expect(out.status == 0, "\(command): \(out.stderr)")
    }

    private func repo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deskdraw-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try shell("""
            git init -q && printf 'a\\n' > a.txt && printf 'b\\n' > b.txt && mkdir keep && printf 'k\\n' > keep/k.txt &&
            printf 'ignored.txt\\n' > .gitignore && git add . &&
            git -c user.email=t@t -c user.name=t commit -qm init
            """, in: dir)
        return dir
    }

    private func read(_ dir: URL, _ path: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func discardUndoesOnlyTheAgentsChanges() throws {
        let dir = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The user's own work in progress: staged, unstaged, untracked, ignored.
        try shell("printf 'staged\\n' >> a.txt && git add a.txt && printf 'mine\\n' > mine.txt && printf 'x\\n' > ignored.txt", in: dir)
        let before = try Git.snapshot(dir)
        let statusBefore = try Git.run(["status", "--porcelain"], in: dir)

        // The agent's change.
        try shell("printf 'agent\\n' >> a.txt && rm b.txt && mkdir -p new/deep && printf 'n\\n' > new/deep/n.txt && printf 'more\\n' >> mine.txt", in: dir)
        let after = try Git.snapshot(dir)
        let changes = try Git.changes(in: dir, from: before, to: after)
        #expect(Set(changes.map(\.path)) == ["a.txt", "b.txt", "mine.txt", "new/deep/n.txt"])
        #expect(changes.first { $0.path == "new/deep/n.txt" }?.status == "A")
        #expect(try Git.diff(in: dir, from: before, to: after).contains("+agent"))

        try Git.revert(changes, in: dir, to: before)
        #expect(read(dir, "a.txt") == "a\nstaged\n")
        #expect(read(dir, "b.txt") == "b\n")
        #expect(read(dir, "mine.txt") == "mine\n")
        #expect(read(dir, "ignored.txt") == "x\n")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("new").path))
        #expect(try Git.run(["status", "--porcelain"], in: dir) == statusBefore)
    }

    @Test func snapshotsLeaveTheIndexAlone() throws {
        let dir = try repo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try shell("printf 'untracked\\n' > u.txt && printf 'changed\\n' >> a.txt", in: dir)
        let status = try Git.run(["status", "--porcelain"], in: dir)
        _ = try Git.snapshot(dir)
        #expect(try Git.run(["status", "--porcelain"], in: dir) == status)
        #expect(Git.topLevel(of: dir.appendingPathComponent("keep"))?.resolvingSymlinksInPath() == dir.resolvingSymlinksInPath())
        #expect(Git.topLevel(of: FileManager.default.temporaryDirectory) == nil)
    }
}

struct ImagineAgentParsingTests {
    private func json(_ s: String) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: Data(s.utf8))) as! [String: Any]
    }

    @Test func readsClaudeCodeStreamJSON() {
        let edit = CLIStream.parse(json(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/p/src/Header.tsx"}}]}}"#))
        #expect(edit.activity == "Editing Header.tsx")
        let text = CLIStream.parse(json(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Made the line fade."}]}}"#))
        #expect(text.text == "Made the line fade.")
        let done = CLIStream.parse(json(#"{"type":"result","subtype":"success","is_error":false,"result":"Done."}"#))
        #expect(done.final == "Done." && done.error == nil)
        let failed = CLIStream.parse(json(#"{"type":"result","is_error":true,"result":"Not logged in"}"#))
        #expect(failed.error == "Not logged in")
    }

    @Test func readsAntigravityStreamJSON() {
        let step = CLIStream.parse(json(#"{"event":"step_update","step_update":{"state":"ACTIVE","step_type":"tool","tool_name":"edit_file","tool_info":{"name":"edit_file","parameters":{"Path":"/p/a.css"}}}}"#))
        #expect(step.activity == "Editing a.css")
        let denied = CLIStream.parse(json(#"{"event":"result","result":{"status":"SUCCESS","response":"","denied_actions":[{"action":"write_file","display_name":"Edit"}]}}"#))
        #expect(denied.error?.contains("Edit") == true)
        let done = CLIStream.parse(json(#"{"event":"result","result":{"status":"SUCCESS","response":"Changed it."}}"#))
        #expect(done.final == "Changed it." && done.error == nil)
    }

    @Test func acpApprovesReadsAndEditsInTheProjectOnlyWhenApplying() {
        let project = URL(fileURLWithPath: "/work/app")
        let shots = URL(fileURLWithPath: "/tmp/shots")
        func call(_ kind: String, _ paths: [String]) -> [String: Any] {
            ["kind": kind, "locations": paths.map { ["path": $0] }]
        }
        func allows(_ c: [String: Any], commands: Bool = false, edit: Bool = true) -> Bool {
            ACPPolicy.allows(c, project: project, attachments: shots, mayEdit: edit, allowCommands: commands)
        }
        #expect(allows(call("edit", ["/work/app/src/a.ts"])))
        #expect(allows(call("read", ["/tmp/shots/marked.png"])))
        #expect(allows(call("read", [])))
        #expect(!allows(call("edit", ["/work/application/a.ts"])))
        #expect(!allows(call("edit", ["/work/app/../other/a.ts"])))
        #expect(!allows(call("edit", ["/tmp/shots/marked.png"])))
        #expect(!allows(call("edit", [])))
        #expect(!allows(call("execute", [])))
        #expect(allows(call("execute", []), commands: true))
        #expect(!allows(call("fetch", [])))
        // Previews only read.
        #expect(allows(call("read", ["/work/app/src/a.ts"]), edit: false))
        #expect(!allows(call("edit", ["/work/app/src/a.ts"]), edit: false))
        #expect(!allows(call("execute", []), commands: true, edit: false))

        let options: [[String: Any]] = [
            ["optionId": "yes", "kind": "allow_once"], ["optionId": "always", "kind": "allow_always"],
            ["optionId": "no", "kind": "reject_once"],
        ]
        #expect(ACPPolicy.option(allow: true, from: options) == "yes")
        #expect(ACPPolicy.option(allow: false, from: options) == "no")
        #expect(ACPPolicy.option(allow: false, from: [["optionId": "y", "kind": "allow_once"]]) == nil)
    }

    @Test func presetsAreRecognized() {
        #expect(AgentPreset.matching(connection: .acp, command: "agy acp ", applyCommand: "anything") == .antigravity)
        #expect(AgentPreset.matching(connection: .cli, command: "agy acp", applyCommand: "agy acp") == nil)
        let claude = AgentPreset.claudeCode
        #expect(AgentPreset.matching(connection: .cli, command: claude.command, applyCommand: claude.applyCommand) == claude)
        #expect(AgentPreset.matching(connection: .cli, command: claude.command, applyCommand: "my-agent") == nil)
        // The preview command must not be able to edit; the apply command must.
        #expect(!claude.command.contains("acceptEdits") && claude.command.contains("--disallowedTools"))
        #expect(claude.applyCommand.contains("acceptEdits"))
    }

    @Test func previewsComeFromTheLastHTMLBlock() {
        let reply = """
        The button is now green and rounded.

        ```css
        .x { color: red }
        ```

        ```html
        <!doctype html>
        <html><body><button>Buy</button></body></html>
        ```
        """
        let snippet = PreviewSnippet.extract(from: reply)
        #expect(snippet?.html == "<!doctype html>\n<html><body><button>Buy</button></body></html>")
        #expect(snippet?.note.hasPrefix("The button is now green and rounded.") == true)
        #expect(PreviewSnippet.extract(from: "Here:\n<!DOCTYPE html><p>hi</p>")?.html == "<!DOCTYPE html><p>hi</p>")
        #expect(PreviewSnippet.extract(from: "```html\n<div>cut off")?.html == "<div>cut off")
        #expect(PreviewSnippet.extract(from: "I couldn't read the screenshot.") == nil)
    }

    @Test func previewPagesGetTheBoxSizeAndUTF8() {
        let size = CGSize(width: 320, height: 120)
        let fragment = PreviewSnippet.document("<div>Größer</div>", size: size)
        #expect(fragment.hasPrefix("<!doctype html><html><head><meta charset=\"utf-8\">"))
        #expect(fragment.contains("width:320px;height:120px") && fragment.hasSuffix("<div>Größer</div></body></html>"))
        let page = PreviewSnippet.document("<!DOCTYPE html><HTML><Head><title>x</title></Head><body><header>h</header></body></HTML>", size: size)
        #expect(page.hasPrefix("<!DOCTYPE html><HTML><Head><meta charset"))
        let noHead = PreviewSnippet.document("<!doctype html><html lang=\"en\"><body><header>h</header></body></html>", size: size)
        #expect(noHead.hasPrefix("<!doctype html><html lang=\"en\"><head><meta charset"))
        #expect(noHead.contains("<header>h</header>"))
    }

    @Test func localPagesAreRememberedByOrigin() {
        #expect(ProjectLocator.localOrigin("http://localhost:5173/settings?x=1") == "http://localhost:5173")
        #expect(ProjectLocator.localOrigin("http://127.0.0.1:3000/") == "http://127.0.0.1:3000")
        #expect(ProjectLocator.localOrigin("https://example.com") == nil)
        #expect(ProjectLocator.localPort("http://localhost/") == 80)
        #expect(ProjectLocator.key(app: nil, appName: "Safari", tabURL: "http://localhost:3000/a") == "web:http://localhost:3000")
        #expect(ProjectLocator.key(app: nil, appName: "Echo", tabURL: "https://example.com") == "app:Echo")
    }
}

@MainActor
struct ImaginePromptTests {
    private func solidImage(_ w: Int, _ h: Int, r: CGFloat = 0.2, g: CGFloat = 0.2, b: CGFloat = 0.2) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func pixel(_ image: CGImage, x: Int, yTop: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let data = CFDataGetBytePtr(image.dataProvider!.data!)!
        let offset = yTop * image.bytesPerRow + x * 4
        return (data[offset], data[offset + 1], data[offset + 2])
    }

    private func shot() -> Capturer.ImagineShot {
        Capturer.ImagineShot(
            marked: solidImage(2000, 1200),
            cleanWindow: solidImage(2000, 1200, r: 0.1, g: 0.1, b: 0.1),
            area: solidImage(640, 240),
            scale: 2,
            appName: "Safari",
            app: nil,
            windowTitle: "Shop",
            tabURL: "http://localhost:5173/",
            tabTitle: "Desk Lamp — Shop",
            marks: [],
            boxInImage: CGRect(x: 100, y: 200, width: 640, height: 240)
        )
    }

    @Test func previewsAskForReadOnlyHTMLOfTheBoxSize() {
        let folder = URL(fileURLWithPath: "/tmp/dd")
        let prompt = Imagine.previewPrompt(request: "Make the button green", shot: shot(), box: CGSize(width: 320, height: 120),
                                           folder: folder, project: nil, previous: nil, change: nil)
        #expect(prompt.contains("Make the button green"))
        #expect(prompt.contains("exactly 320×120 CSS pixels"))
        #expect(prompt.contains("It's 640×240 pixels"))
        #expect(prompt.contains("/tmp/dd/area.png") && prompt.contains("/tmp/dd/marked.png"))
        #expect(prompt.contains("Don't create, change or delete any files"))
        #expect(prompt.contains("I don't have the app's code"))
        #expect(!prompt.contains("Your last preview"))

        let revision = Imagine.previewPrompt(request: "Make the button green", shot: shot(), box: CGSize(width: 320, height: 120),
                                             folder: folder, project: URL(fileURLWithPath: "/work/shop"),
                                             previous: "<p>v1</p>", change: "a bit darker")
        #expect(revision.contains("The app's code is in /work/shop") && revision.contains("don't change anything there"))
        #expect(revision.contains("<p>v1</p>") && revision.contains("Change it like this: a bit darker"))
    }

    @Test func applyingPointsAtThePreviewAndCopyIncludesContextAndGuardrails() {
        let folder = URL(fileURLWithPath: "/tmp/dd")
        let prompt = Imagine.applyPrompt(request: "Make the button green", shot: shot(), folder: folder,
                                         rendered: folder.appendingPathComponent("preview.png"),
                                         html: folder.appendingPathComponent("preview.html"))
        #expect(prompt.contains("/tmp/dd/preview.png") && prompt.contains("/tmp/dd/preview.html"))
        #expect(prompt.contains("not code to paste in"))

        let screenshot = URL(fileURLWithPath: "/Users/nils/Pictures/Desk Draw/preview.png")
        let copied = Imagine.handoff(
            request: "Make the button green",
            shot: shot(),
            box: CGSize(width: 320, height: 120),
            html: "<p>v1</p>",
            note: "Green full-width Buy button.",
            project: URL(fileURLWithPath: "/work/shop"),
            tabURL: "https://app.example.com/checkout",
            tabTitle: "Checkout",
            screenshot: screenshot
        )
        #expect(copied.contains("Make the button green"))
        #expect(copied.contains("- App: Safari"))
        #expect(copied.contains("- Window: Shop"))
        #expect(copied.contains("- Browser Tab: Checkout"))
        #expect(copied.contains("- URL: https://app.example.com/checkout"))
        #expect(copied.contains("- Project: /work/shop"))
        #expect(copied.contains("- Preview Screenshot: /Users/nils/Pictures/Desk Draw/preview.png"))
        #expect(copied.contains("Green full-width Buy button."))
        #expect(copied.contains("design system"))
        #expect(copied.contains("guardrails"))
        #expect(copied.contains("```html\n<p>v1</p>\n```"))
    }

    @Test func previewCompositePlacesThePreviewAtBoxInImageAndClipboardCarriesBoth() {
        let base = solidImage(200, 120, r: 0.1, g: 0.1, b: 0.1)
        let preview = solidImage(60, 40, r: 0.0, g: 0.9, b: 0.2)
        let s = Capturer.ImagineShot(
            marked: base, cleanWindow: base, area: preview, scale: 1,
            appName: "Safari", app: nil, windowTitle: "Shop",
            tabURL: "http://localhost:5173/", tabTitle: nil,
            marks: [], boxInImage: CGRect(x: 40, y: 20, width: 60, height: 40)
        )
        let composed = Capturer.composeImaginePreview(shot: s, preview: preview, tabURL: s.tabURL, tabTitle: nil, includeCaption: false)
        #expect(composed != nil)
        if let composed {
            let inside = pixel(composed, x: 70, yTop: 40)
            let outside = pixel(composed, x: 10, yTop: 100)
            #expect(inside.g > 180 && inside.r < 40)
            #expect(outside.g < 40 && outside.r < 40)

            let png = Capturer.pngData(composed, scale: 1, title: "Test", description: "Desc")
            #expect(png != nil)
            let pb = NSPasteboard(name: .init("DeskDrawImagineCopyTest-\(UUID().uuidString)"))
            Imagine.writeToPasteboard(pb, text: "Implement this", png: png, image: composed)
            #expect(pb.string(forType: .string) == "Implement this")
            #expect(pb.data(forType: .png) == png)
            pb.releaseGlobally()
        }
    }

    @Test func supportedBrowsersAreRecognized() {
        #expect(Browser.isSupported(bundleIdentifier: "com.apple.Safari"))
        #expect(Browser.isSupported(bundleIdentifier: "com.google.Chrome"))
        #expect(Browser.isSupported(bundleIdentifier: "company.thebrowser.Browser"))
        #expect(Browser.isSupported(bundleIdentifier: "company.thebrowser.dia"))
        #expect(Browser.isSupported(bundleIdentifier: "com.kagi.kagimacOS"))
        #expect(!Browser.isSupported(bundleIdentifier: "com.apple.Terminal"))
        #expect(!Browser.isSupported(bundleIdentifier: nil))
    }
}

@MainActor
struct ImaginePreviewTests {
    @Test func previewsCantReachTheNetwork() async {
        #expect(await ImaginePreview.networkRules() != nil)
    }
}

@Suite(.serialized)
@MainActor
struct ImagineAgentRunTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deskdraw-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.resolvingSymlinksInPath()
    }

    private func run(_ connection: AgentConnection, _ command: String, in dir: URL, mayEdit: Bool = true,
                     allowCommands: Bool = false) async -> (AgentRun.Outcome, [String], String) {
        let run = AgentRun(connection: connection, command: command, allowCommands: allowCommands)
        var activity: [String] = []
        var message = ""
        run.onActivity = { activity.append($0) }
        run.onMessage = { message = $0 }
        let outcome = await withCheckedContinuation { continuation in
            run.onEnd = { continuation.resume(returning: $0) }
            run.start(AgentRequest(project: dir, prompt: "Make it pop", mayEdit: mayEdit, attachments: dir, images: []))
        }
        return (outcome, activity, message)
    }

    @Test func commandLineAgentsGetTheRequestAndReportBack() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let command = #"sh -c 'printf "%s" "$DESKDRAW_PROMPT" > got.txt; echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Write\",\"input\":{\"file_path\":\"$PWD/got.txt\"}}]}}"; echo "{\"type\":\"result\",\"is_error\":false,\"result\":\"Popped.\"}"'"#
        let (outcome, activity, message) = await run(.cli, command, in: dir)
        #expect(outcome == .finished)
        #expect(activity == ["Editing got.txt"])
        #expect(message == "Popped.")
        #expect(try String(contentsOf: dir.appendingPathComponent("got.txt"), encoding: .utf8) == "Make it pop")
    }

    @Test func aMissingCommandSaysSo() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (outcome, _, _) = await run(.cli, "deskdraw-no-such-agent --flag", in: dir)
        guard case .failed(let message) = outcome else { Issue.record("expected a failure"); return }
        #expect(message.contains("deskdraw-no-such-agent"))
    }

    @Test(arguments: [true, false])
    func acpAgentsGetASessionAndOnlyTheirProjectEditsApproved(applying: Bool) async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A tiny ACP agent: asks to edit a file in the project, then outside it, then to run a
        // command, and writes the answers into the project.
        let agent = """
        import json, sys
        def send(o): sys.stdout.write(json.dumps(o) + "\\n"); sys.stdout.flush()
        def read(): return json.loads(sys.stdin.readline())
        m = read(); send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1, "agentInfo": {"name": "fake"}, "agentCapabilities": {"promptCapabilities": {"image": True}}}})
        m = read(); cwd = m["params"]["cwd"]; send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s1"}})
        m = read(); prompt_id = m["id"]; text = m["params"]["prompt"][0]["text"]
        answers = []
        for i, (kind, path) in enumerate([("edit", cwd + "/a.txt"), ("edit", "/etc/hosts"), ("execute", None)]):
            call = {"toolCallId": str(i), "kind": kind, "title": kind, "locations": [{"path": path}] if path else []}
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": dict(call, sessionUpdate="tool_call")}})
            send({"jsonrpc": "2.0", "id": "p%d" % i, "method": "session/request_permission", "params": {"sessionId": "s1", "toolCall": call, "options": [{"optionId": "ok", "kind": "allow_once"}, {"optionId": "no", "kind": "reject_once"}]}})
            answers.append(read()["result"]["outcome"]["optionId"])
        open(cwd + "/answers.txt", "w").write(" ".join(answers) + "|" + text)
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Done "}}}})
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "editing."}}}})
        send({"jsonrpc": "2.0", "id": prompt_id, "result": {"stopReason": "end_turn"}})
        sys.stdin.readline()
        """
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("deskdraw-fake-acp-\(UUID().uuidString).py")
        try agent.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }

        let (outcome, activity, message) = await run(.acp, "/usr/bin/python3 -I '\(script.path)'", in: dir,
                                                     mayEdit: applying, allowCommands: true)
        #expect(outcome == .finished)
        #expect(message == "Done editing.")
        #expect(activity.contains("Editing a.txt"))
        #expect(activity.contains { $0.hasPrefix("Declined") })
        let answers = try String(contentsOf: dir.appendingPathComponent("answers.txt"), encoding: .utf8)
        // Previews may not edit or run anything, even with commands allowed.
        #expect(answers == (applying ? "ok no ok|Make it pop" : "no no no|Make it pop"))
    }
}
