// Ask Mercury's brain: the Claude Code you already use, running in the background. It starts in
// your home folder, so it has your memory notes, your CLAUDE.md files and your connected apps,
// and it uses your Claude subscription (no API key). One session stays open while you use the
// panel, so only the first question pays the start-up time.
//
// It only ever acts with your say-so: reading and searching run freely, but anything that
// changes something (sending, writing, running commands) waits for Approve in the panel.

import AppKit
import Foundation

final class ClaudeCodeSession: @unchecked Sendable {
    struct Approval: Identifiable {
        let id: String          // the request id Claude Code is waiting on
        let tool: String
        let input: [String: Any]
        var summary: String { ClaudeCodeSession.describe(tool, input) }
        var appName: String { ClaudeCodeSession.friendlyTool(tool) }
    }

    /// Told when Claude starts driving the Mac's keyboard or mouse (System Events, synthetic key events,
    /// computer use), so Mercury's panel can keep its hands off the keyboard until the answer finishes.
    var onControlling: (() -> Void)?

    /// True for a tool call that types, clicks or switches apps on the Mac.
    static func controlsComputer(_ tool: String, _ input: [String: Any]) -> Bool {
        let t = tool.lowercased()
        if t.contains("computer-use") || t.contains("computer_use") || t.hasSuffix("__computer") { return true }
        guard t == "bash", let cmd = (input["command"] as? String)?.lowercased() else { return false }
        return ["system events", "keystroke", "key code", "cgevent", "cliclick", "pyautogui", "osascript -e 'tell application",
                "osascript -e \"tell application", "click at", "quartz"].contains { cmd.contains($0) }
    }

    enum Event {
        case text(String)
        case activity(String)            // "Searching Gmail…"
        case approval(Approval)
        case done(error: String?)
    }

    static var binary: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) } ?? desktopAppCopy
    }

    /// The Claude desktop app keeps its own copy of Claude Code. Using it means people who already have the
    /// app don't need Terminal, Node or an installer. Newest version first.
    static var desktopAppCopy: URL? {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for v in versions {
            for build in (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(v).path)) ?? [] {
                let bin = root.appendingPathComponent("\(v)/\(build)/claude.app/Contents/MacOS/claude")
                if fm.isExecutableFile(atPath: bin.path) { return bin }
            }
        }
        return nil
    }

    /// Opens a Terminal window that signs Claude Code in. Your browser opens for the Claude sign in; nothing is
    /// typed for you, and Mercury never sees your password.
    static func openSignIn() {
        guard let bin = binary else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Sign in to Claude for Mercury.command")
        let script = """
        #!/bin/zsh
        clear
        echo "Signing Claude in for Mercury. Your browser will open: sign in there, then come back to Mercury."
        echo
        '\(bin.path.replacingOccurrences(of: "'", with: "'\\''"))' auth login
        echo
        echo "All done. You can close this window."
        """
        try? script.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }

    /// Ask Mercury's chat, or a reel editor job: each keeps its own conversation, instructions and rules.
    struct Profile {
        let sessionKey: String
        let prompt: () -> String
        /// A job works through a list of steps on its own: no connected apps, and its own idea of what's safe.
        let isJob: Bool
        static let assistant = Profile(sessionKey: "assistantSessionID", prompt: { ClaudeCodeSession.overlayPrompt }, isJob: false)
    }

    let profile: Profile
    /// Extra things this session may do without asking (a job's working folders), checked after `isSafe`.
    var autoAllow: ((String, [String: Any]) -> Bool)?

    init(profile: Profile = .assistant) {
        self.profile = profile
        sessionID = Settings.d.string(forKey: profile.sessionKey)
        if !profile.isJob { autoAllow = LocalPicture.isDrawing }
    }

    var onEvent: ((Event) -> Void)?
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var sessionID: String?
    private var busy = false
    private let lock = NSLock()

    /// Tools you said "Always allow" for.
    private var alwaysAllowed: Set<String> {
        get { Set(Settings.d.stringArray(forKey: "assistantAlwaysAllow") ?? []) }
        set { Settings.d.set(Array(newValue).sorted(), forKey: "assistantAlwaysAllow") }
    }

    var isRunning: Bool { process?.isRunning == true }

    static var overlayPrompt: String { overlayText + "\n\n" + pictureRules + "\n\n" + actionRules }

    private static let actionRules = """
    Doing things: when the user asks you to do something ("email Alex this", "find me…", "book…"), do it with \
    your tools and connected apps rather than explaining how. For anything that reaches other people (emails, \
    messages, posts, invites): prepare it first, show exactly what will be sent and to whom, and end with a short \
    question like "Send it?". Only send after they say yes; Mercury also shows them an approval card. If they ask \
    to attach or upload what's on their screen, use the screenshot file path given in their message. On a Mac \
    you can use AppleScript (osascript) for Mail, Calendar, Reminders, Notes and opening apps or links.

    Drawing: when a picture you make would help (a diagram, a 3D shape, a graph, a chart), draw it as an SVG \
    file with the Write tool, saved in \(LocalPicture.drawings.path)/ with a short name, then show it in your \
    reply with ![short description](full path) on its own line. Saving there never needs the user's OK, and \
    Mercury shows it right in the chat. Never open it in a browser or Preview, and don't say Mercury can't show \
    your pictures: if an earlier message in this chat said so, that has since been fixed.

    Messaging: for email use the Gmail connector (write a draft, show it, send only after they say yes). For \
    Messenger, Instagram, WhatsApp or Apple Messages use Mercury's prepare_message tool: it opens the chat and \
    types the message but never sends, so tell the user to check it and press Enter. Connected apps (Gmail, \
    Calendar, Notion, Drive and others) load a few seconds after you start and may be deferred: search for them \
    with ToolSearch before ever saying you have no connection to something.
    """

    private static let overlayText = """
    You are answering inside Mercury, a small see-through panel on the user's Mac screen that they open \
    for quick help while they work. Messages may include a screenshot of their screen and a live, \
    on-device transcript of the sound recently playing on their Mac (people on a call or meeting, or a video; \
    never the user's own voice), with mistakes and no speaker names. It looks like a chat with a friend, so text like one: send your reply as a few short \
    messages separated by a blank line, each one thought (one to three sentences), the most useful one first. \
    Keep all the detail that matters; just split it up. A list or code block can be its own message. Use what \
    you know about the user from memory and their connected apps when it helps, and talk to them warmly by name. \
    Show things when useful: code in fenced blocks, markdown links, YouTube watch links on their own line. No \
    tables. Only take actions the user asked for; Mercury asks them to approve anything that changes something. \
    Earlier Mercury chats with this user are saved as JSON files in ~/Library/Application Support/Bubble/Chats; \
    if they refer to something you discussed before that isn't in this conversation, look there.

    Reactions: like a friend in a chat, you can react to the user's message with an emoji by starting your reply \
    with [react: ❤️] (one or two emoji, for example 😂 at a joke, ❤️ at good news or thanks, 👍 at a plan, 🙏 when \
    they help you, 😮 at a surprise). Do it now and then when it fits, not every time, and never mention it. If \
    they tell you they reacted to one of your messages, take it as a friend would.
    """

    // MARK: Starting

    /// Starts the background session if it isn't running (the first answer then comes quicker).
    func warmUp() { _ = try? ensureRunning() }

    /// The connectors the running session was started without, so a change in Settings restarts it.
    private var startedWithout: [String] = []

    private func ensureRunning() throws {
        if isRunning {
            if profile.isJob || startedWithout == Connectors.leftOut { return }
            process?.terminate()  // your connector choice changed: start again (the conversation carries on)
            process = nil
        }
        guard let bin = Self.binary else {
            throw Failure("Claude Code isn't installed. Install it from claude.com/claude-code, then sign in.")
        }
        let p = Process()
        p.executableURL = bin
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-prompt-tool", "stdio",
                    "--model", Settings.assistantModel.alias,
                    // Things that need Claude Code's own window, or would run on after the panel closes.
                    "--disallowedTools", (["AskUserQuestion", "EnterPlanMode", "ExitPlanMode", "EnterWorktree", "ExitWorktree", "CronCreate",
                                           "CronDelete", "ScheduleWakeup", "Monitor", "RemoteTrigger"] + (profile.isJob ? [] : Connectors.leftOut)).joined(separator: ","),
                    "--append-system-prompt", profile.prompt(),
                    // Mercury's instructions change between versions; send the current ones with every
                    // message instead of the copy saved when a long conversation began.
                    "--system-prompt-snapshot", "off"]
        if let id = sessionID { args += ["--resume", id] }
        if profile.isJob {
            args += ["--strict-mcp-config"]  // a video job needs no connected apps, which keeps it lean
        } else {
            startedWithout = Connectors.leftOut
            if let cfg = BubbleToolServer.shared.mcpConfig { args += ["--mcp-config", cfg] }  // Mercury's own tools
        }
        p.arguments = args
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser  // where your memory lives
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [bin.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in self?.received(h.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { log("claude code: \(s.prefix(300))") }
        }
        p.terminationHandler = { [weak self] proc in
            log("claude code: session ended (\(proc.terminationStatus))")
            guard let self else { return }
            self.lock.lock()
            let wasBusy = self.busy
            self.busy = false
            self.process = nil
            self.lock.unlock()
            if wasBusy { self.emit(.done(error: "Claude Code stopped unexpectedly. Try again.")) }
        }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        log("claude code: session started\(sessionID == nil ? "" : " (resumed)")")
    }

    // MARK: Asking

    func ask(_ text: String, screenshot: Data?) {
        do { try ensureRunning() } catch { emit(.done(error: error.localizedDescription)); return }
        var content: [[String: Any]] = []
        if let s = screenshot {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": s.base64EncodedString()]])
        }
        content.append(["type": "text", "text": text])
        lock.lock(); busy = true; lock.unlock()
        send(["type": "user", "message": ["role": "user", "content": content]])
    }

    /// Stops the current answer (the session stays open for the next question).
    func interrupt() {
        send(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
    }

    /// Stops the background process but keeps the conversation for next time.
    func shutdown() { process?.terminate(); process = nil }

    /// The Claude Code conversation being continued (nil until the first answer of a new chat).
    var conversationID: String? { sessionID }

    /// Continue a different saved conversation, or a new one with nil. Takes effect on the next question.
    func switchTo(_ id: String?) {
        guard id != sessionID || process == nil else { return }
        process?.terminate()
        process = nil
        sessionID = id
        if let id { Settings.d.set(id, forKey: profile.sessionKey) } else { Settings.d.removeObject(forKey: profile.sessionKey) }
    }

    /// Forget this conversation and start a new one next time.
    func reset() {
        process?.terminate()
        process = nil
        sessionID = nil
        Settings.d.removeObject(forKey: profile.sessionKey)
    }

    func answer(_ a: Approval, allow: Bool, always: Bool = false) {
        if allow && always { alwaysAllowed.insert(a.tool) }
        let response: [String: Any] = allow
            ? ["behavior": "allow", "updatedInput": a.input]
            : ["behavior": "deny", "message": "The user said no to this action. Don't try it again; tell them what you would have done instead."]
        send(["type": "control_response", "response": ["subtype": "success", "request_id": a.id, "response": response]])
    }

    private func send(_ obj: [String: Any]) {
        guard let h = stdin, var d = try? JSONSerialization.data(withJSONObject: obj) else { log("claude code: nothing to send to"); return }
        if CommandLine.arguments.contains("--assisttest") { log("claude code → \(obj["type"] as? String ?? "?")") }
        d.append(0x0A)
        do { try h.write(contentsOf: d) } catch { log("claude code: write failed: \(error.localizedDescription)") }
    }

    // MARK: Reading what Claude Code says

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ m: [String: Any]) {
        if ProcessInfo.processInfo.environment["BUBBLE_DEBUG"] != nil || CommandLine.arguments.contains("--assisttest") {
            log("claude code ← \(m["type"] as? String ?? "?") \(m["subtype"] as? String ?? "")")
        }
        switch m["type"] as? String {
        case "system":
            if m["subtype"] as? String == "init", let id = m["session_id"] as? String {
                sessionID = id
                Settings.d.set(id, forKey: profile.sessionKey)
            }
        case "stream_event":
            if let ev = m["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
               let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let t = delta["text"] as? String {
                emit(.text(t))
            }
        case "assistant":
            let blocks = (m["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for b in blocks where b["type"] as? String == "tool_use" {
                let tool = b["name"] as? String ?? "", input = b["input"] as? [String: Any] ?? [:]
                if Self.controlsComputer(tool, input), let f = onControlling { DispatchQueue.main.async { f() } }
                emit(.activity(profile.isJob ? Self.jobActivity(tool, input) : Self.activity(tool, input)))
            }
        case "control_request":
            guard let id = m["request_id"] as? String, let req = m["request"] as? [String: Any],
                  req["subtype"] as? String == "can_use_tool", let tool = req["tool_name"] as? String else { return }
            let input = req["input"] as? [String: Any] ?? [:]
            let a = Approval(id: id, tool: tool, input: input)
            if Self.isSafe(tool, input) && (Self.isReadOnly(tool) || (!profile.isJob && alwaysAllowed.contains(tool)) || autoAllow?(tool, input) == true) {
                answer(a, allow: true)
            } else {
                emit(.approval(a))
            }
        case "result":
            lock.lock(); busy = false; lock.unlock()
            if let u = m["usage"] as? [String: Any] {
                let read = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { (u[$0] as? NSNumber)?.intValue }.reduce(0, +)
                log("claude code: answer used \(read) tokens in, \((u["output_tokens"] as? NSNumber)?.intValue ?? 0) out")
            }
            let isError = m["is_error"] as? Bool ?? false
            let text = m["result"] as? String ?? ""
            if isError, text.localizedCaseInsensitiveContains("no conversation found") {
                // The saved conversation is gone: start a new one next time.
                sessionID = nil
                Settings.d.removeObject(forKey: profile.sessionKey)
                process?.terminate()
                emit(.done(error: "Started a fresh conversation. Ask again."))
            } else if isError, text.contains("Not logged in") || text.contains("/login") {
                // Nothing was said yet, so don't try to resume this session later.
                sessionID = nil
                Settings.d.removeObject(forKey: profile.sessionKey)
                emit(.done(error: "Claude Code isn't signed in on this Mac yet. Open Terminal, run `claude`, type /login and sign in with your Claude account, then ask again."))
            } else {
                emit(.done(error: isError ? (text.isEmpty ? "Claude Code hit an error." : text) : nil))
            }
        default:
            break
        }
    }

    private func emit(_ e: Event) { DispatchQueue.main.async { self.onEvent?(e) } }

    // MARK: Which tools run without asking

    /// Places that hold keys, passwords and private history. Reading them, or searching inside
    /// them, always asks first, even for tools you've "always allowed".
    static let privatePaths = ["/.ssh", "/.aws", "/.gnupg", "/.config/gh", "/.netrc", "/.docker", "/.kube",
                                       "/Library/Keychains", "/Library/Cookies", "/Library/Messages", "/Library/Mail",
                                       "/Library/Application Support/Google/Chrome", "/Library/Safari",
                                       "/.zsh_history", "/.bash_history", "/.claude.json", "/.claude/.credentials",
                                       "/Library/Application Support/Bubble/snippets.json", "/Library/Application Support/Bubble/about-me.md"]

    /// Guards against a web page, email or file tricking Claude into leaking something private:
    /// no reading secret files without asking, and no sending data out inside a web address.
    static func isSafe(_ tool: String, _ input: [String: Any]) -> Bool {
        let paths = ["file_path", "path", "notebook_path"].compactMap { input[$0] as? String }
        for p in paths {
            let full = (p as NSString).expandingTildeInPath
            if privatePaths.contains(where: { full.contains($0) }) { return false }
            let name = (full as NSString).lastPathComponent.lowercased()
            if name.hasPrefix(".env") || name.hasSuffix(".pem") || name.hasSuffix(".key") || name.contains("credential") || name.contains("secret") { return false }
        }
        if tool == "Grep" || tool == "Glob", (input["path"] as? String) == nil || (input["path"] as? String) == "~" || (input["path"] as? String) == NSHomeDirectory() {
            // Searching your whole home folder can sweep up secrets: ask.
            return false
        }
        if tool == "WebFetch", let u = input["url"] as? String {
            // Plain pages are fine; a long address or one carrying data in ?query=… asks first.
            guard let c = URLComponents(string: u), c.scheme == "https", (c.query ?? "").isEmpty, u.count <= 160 else { return false }
        }
        return true
    }

    /// Looking things up is fine; changing things needs your OK.
    static func isReadOnly(_ tool: String) -> Bool {
        if ["Read", "Glob", "Grep", "WebSearch", "WebFetch", "TodoWrite", "ToolSearch", "ListMcpResourcesTool", "ReadMcpResourceTool"].contains(tool) { return true }
        // Mercury's prepare_message only fills in the box; you still press send.
        if tool == "mcp__bubble__prepare_message" { return true }
        guard tool.hasPrefix("mcp__") else { return false }
        let action = tool.components(separatedBy: "__").last?.lowercased() ?? tool.lowercased()
        // A draft isn't sent; sending it later still asks.
        if action.contains("draft"), !["send", "delete", "remove", "trash"].contains(where: { action.contains($0) }) { return true }
        let readVerbs = ["get", "list", "search", "read", "fetch", "query", "find", "view", "show", "describe", "lookup", "retrieve"]
        let writeWords = ["send", "create", "delete", "update", "trash", "remove", "post", "publish", "share", "write", "edit", "move", "cancel", "reply", "forward", "pay", "transfer"]
        if writeWords.contains(where: { action.contains($0) }) { return false }
        return readVerbs.contains(where: { action.hasPrefix($0) || action.contains("-" + $0) || action.contains("_" + $0) })
    }

    static func friendlyTool(_ tool: String) -> String {
        if tool == "Bash" { return "Run a command" }
        if tool == "Write" || tool == "Edit" || tool == "NotebookEdit" { return "Change a file" }
        if tool.hasPrefix("mcp__") {
            let parts = tool.components(separatedBy: "__")
            return (parts.last ?? tool).replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
        }
        return tool
    }

    static func describe(_ tool: String, _ input: [String: Any]) -> String {
        if tool == "Bash" { return input["command"] as? String ?? "" }
        if let path = input["file_path"] as? String { return path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        let pairs = input.prefix(4).map { k, v in "\(k): \(String(describing: v).prefix(120))" }
        return pairs.joined(separator: "\n")
    }

    /// Progress lines for a job, where you want to see what's actually happening.
    static func jobActivity(_ tool: String, _ input: [String: Any]) -> String {
        func short(_ s: String) -> String { s.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        func file(_ key: String = "file_path") -> String { ((input[key] as? String) ?? "a file").split(separator: "/").last.map(String.init) ?? "a file" }
        switch tool {
        case "Bash":
            let cmd = short((input["command"] as? String ?? "").replacingOccurrences(of: "\n", with: " "))
            return "Running " + (cmd.count > 110 ? String(cmd.prefix(110)) + "…" : cmd)
        case "Write": return "Writing \(file())"
        case "Edit", "MultiEdit": return "Editing \(file())"
        case "Read": return "Reading \(file())"
        case "Glob", "Grep": return "Looking through files"
        case "TodoWrite": return "Planning the steps"
        case "Task", "Agent": return "Handing part of it to a helper"
        default: return activity(tool, input)
        }
    }

    static func activity(_ tool: String, _ input: [String: Any]) -> String {
        switch tool {
        case "WebSearch": return "Searching the web…"
        case "WebFetch": return "Reading a web page…"
        case "Read": return "Reading \(((input["file_path"] as? String) ?? "a file").split(separator: "/").last ?? "a file")…"
        case "Glob", "Grep": return "Looking through files…"
        case "Bash": return "Running a command…"
        default:
            if tool.hasPrefix("mcp__") { return friendlyTool(tool) + "…" }
            return "Working…"
        }
    }

    struct Failure: LocalizedError { let m: String; init(_ m: String) { self.m = m }; var errorDescription: String? { m } }
}

extension AssistantModelChoice {
    /// Claude Code's model names.
    var alias: String { switch self { case .fast: "haiku"; case .balanced: "sonnet"; case .smart: "opus" } }
}

// MARK: - Connectors

/// The apps connected to your Claude account, and Claude Code plugins with tools. Every one Ask Mercury
/// loads is described to Claude in each chat, so loading all of them (fifty or so) used hundreds of
/// thousands of tokens of your plan per chat. Mercury loads the everyday ones, plus any you add in Settings.
enum Connectors {
    /// On unless you turn them off.
    static let everyday: Set<String> = ["Gmail", "Google Calendar", "Google Drive", "Google Docs", "Google Sheets", "Notion",
                                        "Todoist", "Microsoft 365", "Outlook", "Superhuman Mail", "Slack", "Calendly", "Goodnotes"]

    /// Every connector Claude Code reported last time Mercury checked, as Claude Code names them
    /// ("claude.ai Gmail", "plugin:bio-research:pubmed").
    static var known: [String] { Settings.d.stringArray(forKey: "connectorsKnown") ?? [] }

    static var chosen: Set<String> {
        get { Settings.d.stringArray(forKey: "connectorsChosen").map(Set.init) ?? Set(known.filter { everyday.contains(label($0)) }) }
        set { Settings.d.set(Array(newValue).sorted(), forKey: "connectorsChosen") }
    }

    /// Tool names to leave out of Ask Mercury's Claude Code session.
    static var leftOut: [String] { known.filter { !chosen.contains($0) }.map(toolPrefix).sorted() }

    static func label(_ raw: String) -> String {
        if raw.hasPrefix("claude.ai ") { return String(raw.dropFirst("claude.ai ".count)) }
        let parts = raw.split(separator: ":")
        return parts.count == 3 ? "\(parts[2]) (\(parts[1]) plugin)" : raw
    }

    /// How Claude Code names a server's tools: mcp__claude_ai_Google_Calendar__…, mcp__plugin_bio-research_pubmed__…
    static func toolPrefix(_ raw: String) -> String {
        func clean(_ s: Substring) -> String { String(s).replacingOccurrences(of: #"[^A-Za-z0-9_-]"#, with: "_", options: .regularExpression) }
        if raw.hasPrefix("claude.ai ") { return "mcp__claude_ai_" + clean(raw.dropFirst("claude.ai ".count)) }
        let parts = raw.split(separator: ":")
        if parts.count == 3, parts[0] == "plugin" { return "mcp__plugin_\(clean(parts[1]))_\(clean(parts[2]))" }
        return "mcp__" + clean(Substring(raw))
    }

    /// Asks Claude Code which connectors you have (takes a few seconds; it checks each one).
    static func refresh(done: (() -> Void)? = nil) {
        guard let bin = ClaudeCodeSession.binary else { done?(); return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = bin
            p.arguments = ["mcp", "list"]
            p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = [bin.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { DispatchQueue.main.async { done?() }; return }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            let names = text.split(separator: "\n").compactMap { line -> String? in
                let l = String(line)
                guard l.hasPrefix("claude.ai ") || l.hasPrefix("plugin:"),
                      let r = l.range(of: l.hasPrefix("plugin:") ? #"^plugin:[^:]+:[^:]+"# : #"^claude\.ai [^:]+"#, options: .regularExpression) else { return nil }
                return String(l[r])
            }
            DispatchQueue.main.async {
                if !names.isEmpty {
                    Settings.d.set(names, forKey: "connectorsKnown")
                    Settings.d.set(Date(), forKey: "connectorsChecked")
                    log("connectors: \(names.count) found, Ask Mercury loads \(chosen.count)")
                }
                done?()
            }
        }
    }

    /// Once a day at most.
    static func refreshIfDue() {
        if let last = Settings.d.object(forKey: "connectorsChecked") as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        refresh()
    }
}
