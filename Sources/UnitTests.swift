// Quick automatic checks of the logic that is easiest to break by accident: how replies split into
// chat bubbles and quotes, which lines become pictures and videos, panel resizing, spotting Claude
// driving the Mac, and what goes into a problem report.
//
//   Mercury --unittests     runs every check, logs each failure and a summary, and quits
//                           (exit code 0 when all pass, 1 when any fail)
//
// Nothing here shows a window, reads or writes saved chats or settings, or touches the screen, camera or
// mic, so it is safe to run while Mercury is in use. It is deliberately not called --selftest: that older
// hook records the real screen. tools/run-tests.sh runs these checks and the offscreen hooks together.

import AppKit

@MainActor
enum UnitTests {
    private static var passed = 0
    private static var failures: [String] = []

    /// Runs every group and returns true when all checks pass.
    static func run() -> Bool {
        passed = 0
        failures = []
        chatBubbles()
        reactions()
        replyPreviews()
        answerBlocks()
        panelSizing()
        computerControl()
        reportFolder()
        openAIAddress()
        snippets()
        for f in failures { log("unittests: FAIL \(f)") }
        log("unittests: \(passed) passed, \(failures.count) failed")
        print("unittests: \(passed) passed, \(failures.count) failed")
        for f in failures { print("  FAIL \(f)") }
        return failures.isEmpty
    }

    private static func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        if got == want { passed += 1 } else { failures.append("\(name): got \(got), want \(want)") }
    }

    // MARK: Snippets

    private static func snippets() {
        let list = [Snippet(trigger: "mercury link", text: "https://harryngu.github.io/mercury/"),
                    Snippet(trigger: "github", text: "https://github.com/HarryNGU"),
                    Snippet(trigger: "email 1", text: "one@example.com"),
                    Snippet(trigger: "email", text: "EMAIL")]
        let x = { SnippetStore.expand($0, with: list) }
        check("expanded text isn't expanded again", x("Mercury link."), "https://harryngu.github.io/mercury/.")
        check("both in one sentence", x("Here's my github and the mercury link"), "Here's my https://github.com/HarryNGU and the https://harryngu.github.io/mercury/")
        check("longer trigger wins", x("Email one, please"), "one@example.com, please")
        check("shorter one still works alone", x("my email"), "my EMAIL")
        check("said twice", x("github github"), "https://github.com/HarryNGU https://github.com/HarryNGU")
        check("no trigger, no change", x("nothing here"), "nothing here")
    }

    // MARK: Your own key

    private static func openAIAddress() {
        let e = { Settings.openAIEndpoint($0)?.absoluteString ?? "nil" }
        let openai = "https://api.openai.com/v1/chat/completions"
        check("empty box means OpenAI", e(""), openai)
        check("spaces only means OpenAI", e("   "), openai)
        check("default address", e("https://api.openai.com/v1"), openai)
        check("trailing slash", e("https://api.openai.com/v1/"), openai)
        check("missing https", e("api.openai.com/v1"), openai)
        check("pasted full endpoint", e("https://api.openai.com/v1/chat/completions"), openai)
        check("Ollama on this Mac", e("http://localhost:11434/v1"), "http://localhost:11434/v1/chat/completions")
        check("OpenRouter", e("https://openrouter.ai/api/v1"), "https://openrouter.ai/api/v1/chat/completions")
        check("Ollama without http", e("localhost:11434/v1"), "http://localhost:11434/v1/chat/completions")
        check("not an address", e("https://"), "nil")
        check("new Gemini key spotted", GeminiClient.isGemini(key: "AQ.example", base: ""), true)
        check("old Gemini key spotted", GeminiClient.isGemini(key: "AIzaTest", base: ""), true)
        check("OpenAI key isn't Gemini", GeminiClient.isGemini(key: "sk-proj-test", base: "https://api.openai.com/v1"), false)
        check("Gemini address spotted", GeminiClient.isGemini(key: "x", base: "https://generativelanguage.googleapis.com/v1beta/openai"), true)
        check("OpenAI model swapped for Gemini", GeminiClient.model("gpt-5-mini"), GeminiClient.defaultModel)
        check("Gemini model kept", GeminiClient.model("gemini-2.5-pro"), "gemini-2.5-pro")
        check("busy fallbacks", GeminiClient.models("gpt-5-mini"), ["gemini-flash-latest", "gemini-flash-lite-latest", "gemini-2.5-flash"])
        check("no repeated fallback", GeminiClient.models("gemini-2.5-flash"), ["gemini-2.5-flash", "gemini-flash-lite-latest"])
        check("no credit explained", OpenAIClient.friendly(status: 429, message: "You exceeded your current quota", raw: ["error": ["code": "insufficient_quota"]]).contains("no credit"), true)
    }

    // MARK: Chat

    private static func chatBubbles() {
        let split = AssistantView.messages
        check("blank lines split bubbles", split("Hi there.\n\nSecond thought."), ["Hi there.", "Second thought."])
        check("nothing gives no bubbles", split("  \n\n \n"), [])
        check("code stays whole and its label joins it", split("Look:\n\n```\nlet a = 1\n\nlet b = 2\n```"),
              ["Look:\n```\nlet a = 1\n\nlet b = 2\n```"])
        check("short list stays one bubble", split("- milk\n- eggs"), ["- milk\n- eggs"])
        let long1 = String(repeating: "first point that runs long ", count: 3), long2 = String(repeating: "second point ", count: 7)
        check("long list sends each point", split("1. \(long1)\n2. \(long2)"), [long1, long2])
        check("long label stays its own bubble", split("This label is far too long to join the next one:\n\nNext"),
              ["This label is far too long to join the next one:", "Next"])
    }

    private static func reactions() {
        let r = AssistantView.splitReactions
        check("reaction comes off", r("[react: ❤️] Thanks!").reactions, ["❤️"])
        check("text after reaction", r("[react: ❤️] Thanks!").text, "Thanks!")
        check("no tag left alone", r("Plain reply").text, "Plain reply")
        check("other tags left alone", r("[note] hi").text, "[note] hi")
        check("half arrived tag hidden", r("[rea").text, "")
        check("at most three reactions", r("[react: 😀, 😂, ❤️, 👍] ok").reactions.count, 3)
    }

    private static func replyPreviews() {
        let p = ReplyQuote.preview
        check("markdown stripped", p("That comes from the **power rule**."), "That comes from the power rule.")
        check("lines joined", p("one\ntwo"), "one two")
        check("code named", p("```swift\nlet x = 1\n```"), "Code")
        check("video named", p("[[video: /tmp/clip.mp4]]"), "Video")
        check("picture named", p("/tmp/photo.png"), "Picture")
        check("empty named", p(""), "Message")
        check("words win over pictures", p("Here it is\n/tmp/photo.png"), "Here it is")
    }

    // MARK: Pictures and videos in answers

    private static func answerBlocks() {
        typealias B = RichAnswer.Block
        let b = RichAnswer.blocks
        let file = { (p: String) in URL(fileURLWithPath: p) }
        check("bare video path", b("/Users/me/Desktop/a b.mp4"), [B.localVideo(file("/Users/me/Desktop/a b.mp4"))])
        check("video tag with ~", b("[[video: ~/Movies/x.mov]]"), [B.localVideo(file(NSHomeDirectory() + "/Movies/x.mov"))])
        check("markdown video", b("![clip](/tmp/y.m4v)"), [B.localVideo(file("/tmp/y.m4v"))])
        check("web video", b("https://example.com/z.mp4?x=1"), [B.localVideo(URL(string: "https://example.com/z.mp4?x=1")!)])
        check("picture path", b("/tmp/not.png"), [B.image(file("/tmp/not.png"))])
        check("video named in a sentence", b("Saved it to `/Users/me/Desktop/My Clip (final).mp4` for you"),
              [B.prose("Saved it to `/Users/me/Desktop/My Clip (final).mp4` for you"), B.localVideo(file("/Users/me/Desktop/My Clip (final).mp4"))])
        check("video before a full stop", b("It is at /tmp/q.mov."), [B.prose("It is at /tmp/q.mov."), B.localVideo(file("/tmp/q.mov"))])
        check("the word mp4 is just text", b("the mp4 is done"), [B.prose("the mp4 is done")])
        check("picture search", b("[[images: koala]]"), [B.imageSearch("koala")])
        check("molecule", b("[[molecule: caffeine]]"), [B.molecule("caffeine")])
        check("markdown picture link", b("![cat](https://example.com/cat.jpg)"), [B.image(URL(string: "https://example.com/cat.jpg")!)])
        check("youtube link", b("Watch https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
              [B.prose("Watch https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
               B.video(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!, thumb: URL(string: "https://img.youtube.com/vi/dQw4w9WgXcQ/hqdefault.jpg")!)])
        check("code block", b("```py\nprint(1)\n```"), [B.code(lang: "py", body: "print(1)")])
        check("heading made bold", b("# Steps"), [B.prose("**Steps**")])
    }

    // MARK: Panel

    private static func panelSizing() {
        let area = NSRect(x: 0, y: 0, width: 1600, height: 1000), s = NSRect(x: 300, y: 300, width: 700, height: 500)
        let r = { (e: PanelEdge, dx: CGFloat, dy: CGFloat) in PanelSizing.resized(s, edge: e, dx: dx, dy: dy, within: area) }
        check("right edge grows", r(.right, 100, 0), NSRect(x: 300, y: 300, width: 800, height: 500))
        check("left edge shrinks", r(.left, 100, 0), NSRect(x: 400, y: 300, width: 600, height: 500))
        check("bottom edge grows down", r(.bottom, 0, -50), NSRect(x: 300, y: 250, width: 700, height: 550))
        check("top edge stops at the screen", r(.top, 0, 2000), NSRect(x: 300, y: 300, width: 700, height: 700))
        check("corner stops at the smallest size", r(.bottomRight, -900, 900), NSRect(x: 300, y: 540, width: 400, height: 260))
        check("corner stops at the screen and smallest size", r(.topLeft, -2000, -900), NSRect(x: 0, y: 300, width: 1000, height: 260))
        for e in PanelEdge.allCases {
            let f = r(e, -5000, -5000), g = r(e, 5000, 5000)
            check("\(e) never below the smallest size", f.width >= PanelSizing.minimum.width && f.height >= PanelSizing.minimum.height
                  && g.width >= PanelSizing.minimum.width && g.height >= PanelSizing.minimum.height, true)
            check("\(e) stays on screen", area.contains(f) && area.contains(g), true)
        }
        check("clamp to screen", PanelSizing.clamp(CGSize(width: 5000, height: 10), to: area), CGSize(width: 1600, height: 260))
    }

    private static func computerControl() {
        let c = ClaudeCodeSession.controlsComputer
        check("keystrokes", c("Bash", ["command": "osascript -e 'tell application \"System Events\" to keystroke \"hi\"'"]), true)
        check("listing files", c("Bash", ["command": "ls -la ~/Desktop"]), false)
        check("computer use tool", c("mcp__computer-use__left_click", [:]), true)
        check("quartz events", c("Bash", ["command": "python3 -c 'import Quartz; Quartz.CGEventPost(0, e)'"]), true)
        check("reading a file", c("Read", [:]), false)
        check("bash with no command", c("Bash", [:]), false)
        check("cliclick", c("Bash", ["command": "cliclick c:10,10"]), true)
    }

    // MARK: Problem reports

    /// Builds a report folder in the temporary folder, checks what it holds, and deletes it again.
    /// Nothing is sent and no email opens.
    private static func reportFolder() {
        let center = ReportCenter.shared, m = center.model
        defer { m.reset() }
        m.reset()
        m.text = "  The record button did nothing.\n"
        m.shot = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { r in NSColor.systemBlue.setFill(); r.fill(); return true }
        m.includeLog = false
        func contents(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
        do {
            let dir = try center.package()
            defer { try? FileManager.default.removeItem(at: dir) }
            check("report is in the temporary folder", dir.path.hasPrefix(FileManager.default.temporaryDirectory.path), true)
            check("report folder without log", contents(dir), ["Report.txt", "Screenshot.png"])
            let note = (try? String(contentsOf: dir.appendingPathComponent("Report.txt"), encoding: .utf8)) ?? ""
            check("note trimmed and first", note.hasPrefix("The record button did nothing.\n\n"), true)
            check("note carries setup details", note.contains(Reports.systemInfo), true)
            check("screenshot is a picture", NSImage(contentsOf: dir.appendingPathComponent("Screenshot.png")) != nil, true)
        } catch { failures.append("report package failed: \(error)") }

        m.reset()
        m.includeLog = true
        do {
            let dir = try center.package()
            defer { try? FileManager.default.removeItem(at: dir) }
            check("report folder with log and no picture", contents(dir), ["Mercury log.txt", "Report.txt"])
            let note = (try? String(contentsOf: dir.appendingPathComponent("Report.txt"), encoding: .utf8)) ?? ""
            check("empty note says so", note.hasPrefix("(no description)"), true)
        } catch { failures.append("report package failed: \(error)") }
    }
}
