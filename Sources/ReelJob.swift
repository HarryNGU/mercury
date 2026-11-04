// Full jobs in the reel editor: paste a whole recipe (cut this recording into a reel with my scripts,
// add captions and a panel, render it) and Claude Code works through it with its tools while you watch.
//
// It works on its own only inside the folders your prompt names, plus Bubble Recordings and temporary
// folders: reading, writing, and running your own scripts, Python, ffmpeg and Manim there. Anything
// else (deleting or moving files, other folders, the network, opening apps, installing) waits for Allow.
// The job keeps running if you leave the editor; come back to see where it is.

import AppKit
import SwiftUI

// MARK: - What a job may do without asking

struct JobPolicy {
    /// Folders the job works in freely (full paths, no trailing slash).
    let roots: [String]

    /// The working folders for a prompt: Bubble Recordings, temporary folders, and the folder two levels
    /// down from home for each path the prompt mentions (~/Desktop/Videos/a/b.py gives ~/Desktop/Videos).
    static func roots(for prompt: String) -> [String] {
        let home = NSHomeDirectory()
        var out = [Settings.folder.path, NSTemporaryDirectory(), "/tmp", "/private/tmp"]
            .map { ($0 as NSString).standardizingPath }
        let re = try! NSRegularExpression(pattern: #"(~|/Users/[^/\s]+)(/[^\s`'"<>()\[\],;]+)+"#)
        for m in re.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)) {
            guard let r = Range(m.range, in: prompt) else { continue }
            let full = (String(prompt[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".:")) as NSString).expandingTildeInPath
            guard full.hasPrefix(home + "/") else { continue }
            let parts = full.dropFirst(home.count + 1).split(separator: "/").prefix(2)
            guard parts.count == 2, parts[0] != "Library", !parts[0].hasPrefix(".claude"), !parts[0].hasPrefix(".ssh") else { continue }
            let root = home + "/" + parts.joined(separator: "/")
            if ClaudeCodeSession.privatePaths.contains(where: { (root + "/").contains($0) }) { continue }
            if !out.contains(root) { out.append(root) }
        }
        return out
    }

    func inRoots(_ path: String) -> Bool {
        let full = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        return roots.contains { full == $0 || full.hasPrefix($0 + "/") }
    }

    /// The folders, shortened for showing: ~/Desktop/Videos.
    var shown: [String] {
        let home = NSHomeDirectory()
        return roots.filter { !$0.hasPrefix("/tmp") && !$0.hasPrefix("/private") && !$0.hasPrefix(NSTemporaryDirectory().dropLast()) }
            .map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }
    }

    func allows(_ tool: String, _ input: [String: Any]) -> Bool {
        switch tool {
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            guard let p = (input["file_path"] ?? input["notebook_path"]) as? String else { return false }
            return inRoots(p)
        case "Bash":
            return (input["command"] as? String).map(bashAllowed) ?? false
        case "TodoWrite", "Task", "Agent", "Skill":
            return true
        default:
            return false
        }
    }

    /// Never fine anywhere in a command, whatever runs it: running hidden commands, or deleting and
    /// rewriting files through options. (Programs such as rm, curl, osascript or open simply aren't on
    /// the list below, so any part that runs them asks.)
    private static let banned: [NSRegularExpression] = [
        #"\$\("#, #"`"#, #"(^|\s)-delete\b"#, #"(^|\s)-exec(dir)?\b"#, #"(^|\s)-ok\b"#, #"\bsed\s+(-[a-zA-Z]*i|--in-place)"#,
        #"\bawk\b.*\bsystem\s*\("#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let programs: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "egrep", "rg", "find", "sed", "awk", "sort", "uniq", "cut", "tr", "echo",
        "printf", "mkdir", "cp", "touch", "pwd", "which", "file", "sips", "du", "stat", "date", "basename", "dirname", "jq",
        "mdls", "ffmpeg", "ffprobe", "manim", "cd", "true", "test", "[", "sleep", "diff", "nl", "column", "realpath",
    ]

    /// Splits a shell command into its parts (at &&, ||, |, ; and new lines), each a list of words with
    /// quotes removed, plus where its output is sent. Close enough to the shell for judging safety.
    static func parse(_ command: String) -> [(words: [String], writes: [String])] {
        var parts: [(words: [String], writes: [String])] = []
        var words: [String] = [], writes: [String] = []
        var word = "", quote: Character? = nil, inWord = false, redirectNext = false
        let home = NSHomeDirectory()
        func endWord() {
            guard inWord else { return }
            let w = word.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
            if redirectNext { writes.append(w); redirectNext = false } else { words.append(w) }
            word = ""; inWord = false
        }
        func endPart() { endWord(); if !words.isEmpty || !writes.isEmpty { parts.append((words, writes)) }; words = []; writes = [] }
        let cs = Array(command)
        var i = 0
        while i < cs.count {
            let c = cs[i]
            if let q = quote {
                if c == q { quote = nil } else if c == "\\", q == "\"", i + 1 < cs.count { i += 1; word.append(cs[i]) } else { word.append(c) }
                i += 1; continue
            }
            switch c {
            case "'", "\"": quote = c; inWord = true
            case "\\": if i + 1 < cs.count { i += 1; word.append(cs[i]); inWord = true }
            case " ", "\t": endWord()
            case ";", "\n": endPart()
            case "|": endPart(); if i + 1 < cs.count, cs[i + 1] == "|" { i += 1 }
            case "&":
                if i + 1 < cs.count, cs[i + 1] == "&" { endPart(); i += 1 }
                else if i + 1 < cs.count, cs[i + 1] == ">" { endWord(); redirectNext = true; i += 1; if i + 1 < cs.count, cs[i + 1] == ">" { i += 1 } }
                else { endPart() }  // running in the background: judge each side alone
            case ">":
                // 2>&1 or >&2 only joins outputs; anything else writes a file.
                if inWord, word.allSatisfy(\.isNumber) { word = ""; inWord = false }
                endWord()
                if i + 1 < cs.count, cs[i + 1] == ">" { i += 1 }
                if i + 1 < cs.count, cs[i + 1] == "&" { i += 1; while i + 1 < cs.count, cs[i + 1].isNumber || cs[i + 1] == "-" { i += 1 } }
                else { redirectNext = true }
            case "<": endWord()
            default: word.append(c); inWord = true
            }
            i += 1
        }
        endPart()
        return parts
    }

    /// A shell command is fine when every part is a known harmless program (or Python running a script
    /// in a working folder) and nothing it writes lands outside the working folders.
    func bashAllowed(_ command: String) -> Bool {
        let all = NSRange(command.startIndex..., in: command)
        if Self.banned.contains(where: { $0.firstMatch(in: command, range: all) != nil }) { return false }
        let parts = Self.parse(command)
        // Relative paths count as inside when the command first moves into a working folder.
        let movesInside = parts.contains { $0.words.first == "cd" && $0.words.count > 1 && inRoots($0.words[1]) }
        func placeOK(_ p: String) -> Bool {
            if p == "/dev/null" || p.hasPrefix("-") { return true }
            return p.hasPrefix("/") || p.hasPrefix("~") ? inRoots(p) : movesInside
        }
        for part in parts {
            guard part.writes.allSatisfy(placeOK) else { return false }
            var w = part.words
            while let f = w.first, f.contains("="), !f.hasPrefix("-"), !f.contains("/") { w.removeFirst() }  // VAR=value
            guard let first = w.first else { continue }
            let name = (first as NSString).lastPathComponent
            if first.contains("/") && !inRoots(first) && !["/usr/bin/", "/bin/", "/opt/homebrew/bin/", "/usr/local/bin/"].contains(where: first.hasPrefix) {
                return false  // a program from somewhere unexpected
            }
            if name.hasPrefix("python") {
                let args = Array(w.dropFirst())
                if args.contains("-c") { return false }
                if let mi = args.firstIndex(of: "-m") { guard mi + 1 < args.count, args[mi + 1] == "manim" else { return false }; continue }
                guard let script = args.first(where: { !$0.hasPrefix("-") }), placeOK(script) else { return false }
                continue
            }
            guard Self.programs.contains(name) else { return false }
            if ["mkdir", "touch"].contains(name), !w.dropFirst().allSatisfy(placeOK) { return false }
            if name == "cp", w.count > 2, let dest = w.last, !placeOK(dest) { return false }
            if name == "ffmpeg", let out = w.last, w.count > 2, !out.hasPrefix("-"), out != "-", !placeOK(out) { return false }
        }
        return true
    }
}

// MARK: - The job

@MainActor
final class ReelJob: ObservableObject {
    static let shared = ReelJob()

    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable { case you, claude, step, done, problem }
        let id = UUID()
        let kind: Kind
        var text: String
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var running = false
    @Published private(set) var started: Date?
    @Published private(set) var finished: Date?
    @Published var approval: ClaudeCodeSession.Approval?
    @Published private(set) var policy = JobPolicy(roots: [])

    private var session: ClaudeCodeSession?
    private var receivingText = false

    private static let profileKey = "reelJobSessionID"

    private func makeSession() -> ClaudeCodeSession {
        // The rules are fixed for the whole job, and Claude Code asks about tools off the main thread,
        // so the session gets its own copies.
        let prompt = jobPrompt, rules = policy
        let s = ClaudeCodeSession(profile: .init(sessionKey: Self.profileKey, prompt: { prompt }, isJob: true))
        s.autoAllow = { tool, input in rules.allows(tool, input) }
        s.onEvent = { [weak self] e in MainActor.assumeIsolated { self?.handle(e) } }
        return s
    }

    private var jobPrompt: String {
        """
        You're running a job for the user from Mercury's reel editor, a Mac app. Work through what they ask on \
        your own with your tools, until it's done or you need them.

        Keep them posted: before each main step, write one short, plain sentence about what you're doing. They \
        watch these lines as progress, so don't narrate every command.

        Mercury lets you work without asking inside these folders: \(policy.roots.joined(separator: ", ")). There \
        you can read and write files and run their own scripts, Python, ffmpeg, ffprobe and Manim. Anything else \
        (deleting or moving files, other folders, the network, opening apps, installing things) waits for the \
        user to tap Allow, so prefer the first kind and say why when you need the second. Inline Python \
        (python -c) and command substitution also wait, so write small scripts into a working folder instead.

        You can't use the browser, post or send anything from here. If their steps include posting or sending, \
        stop before that and tell them it's ready.

        When you finish, list the full path of every video you made, each on its own line.
        """
    }

    var elapsed: TimeInterval { (finished ?? Date()).timeIntervalSince(started ?? Date()) }

    /// Starts a job, or continues the current one with a follow-up ("make the captions bigger").
    func send(_ text: String, recording: URL) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let first = session == nil
        if first {
            policy = JobPolicy(roots: JobPolicy.roots(for: t))
            Settings.d.removeObject(forKey: Self.profileKey)
            session = makeSession()
        }
        entries.append(Entry(kind: .you, text: t))
        running = true
        started = Date()
        finished = nil
        receivingText = false
        let message = first
            ? "The recording open in Mercury's editor: \(recording.path)\nBubble's recordings folder: \(Settings.folder.path)\n\n\(t)"
            : t
        log("reel job: \(first ? "started" : "follow-up"), working in \(policy.shown.joined(separator: ", "))")
        session?.ask(message, screenshot: nil)
    }

    func stop() {
        session?.interrupt()
        if let a = approval { session?.answer(a, allow: false); approval = nil }
    }

    /// Forget this job; the next prompt starts a fresh one.
    func newJob() {
        session?.reset()
        session = nil
        entries = []
        running = false
        approval = nil
        started = nil
        finished = nil
        policy = JobPolicy(roots: [])
    }

    func answer(allow: Bool) {
        guard let a = approval else { return }
        session?.answer(a, allow: allow)
        entries.append(Entry(kind: .step, text: (allow ? "Allowed: " : "Said no to: ") + a.summary))
        approval = nil
    }

    private func handle(_ e: ClaudeCodeSession.Event) {
        switch e {
        case .text(let t):
            if receivingText, let i = entries.indices.last, entries[i].kind == .claude {
                entries[i].text += t
            } else {
                entries.append(Entry(kind: .claude, text: t.trimmingCharacters(in: .newlines)))
                receivingText = true
            }
        case .activity(let a):
            receivingText = false
            entries.append(Entry(kind: .step, text: a))
        case .approval(let a):
            receivingText = false
            approval = a
            NSSound(named: "Glass")?.play()
            NSApp.requestUserAttention(.informationalRequest)
        case .done(let error):
            receivingText = false
            running = false
            finished = Date()
            approval = nil
            let mins = Int(elapsed) / 60, secs = Int(elapsed) % 60
            if let error { entries.append(Entry(kind: .problem, text: error)) }
            else { entries.append(Entry(kind: .done, text: "Finished in \(mins > 0 ? "\(mins) min " : "")\(secs) s")) }
            log("reel job: \(error == nil ? "finished" : "stopped") after \(Int(elapsed)) s")
            if error == nil { Sounds.stop() }
        }
    }

    /// Videos the job mentions that exist on this Mac, newest mention last.
    static func videos(in text: String) -> [URL] {
        let re = try! NSRegularExpression(pattern: #"(?:~|/Users/|/tmp/|/private/)[^\n"`]*?\.(?:mp4|mov|m4v)"#)
        var seen: [URL] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            let path = (String(text[r]) as NSString).expandingTildeInPath
            let u = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path), !seen.contains(u) { seen.append(u) }
        }
        return seen
    }
}

// MARK: - The panel in the editor

struct ReelJobPanel: View {
    let recording: URL
    @ObservedObject var job = ReelJob.shared
    @State private var message = ""
    @State private var messageHeight: CGFloat = 17
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            status
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if job.entries.isEmpty { intro }
                        ForEach(job.entries) { row($0).id($0.id) }
                        if let a = job.approval { approvalCard(a).id("approval") }
                    }
                    .padding(14)
                }
                .frame(minHeight: 180, maxHeight: 360)
                .onChange(of: job.entries.count) { if let last = job.entries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: job.approval?.id) { if job.approval != nil { withAnimation { proxy.scrollTo("approval", anchor: .bottom) } } }
            }
            Rectangle().fill(Palette.border).frame(height: 1)
            HStack(spacing: 8) {
                ChatTextView(text: $message, placeholder: job.entries.isEmpty ? "Paste a full prompt, like your Day reel recipe…" : "Reply or ask for a change…",
                             maxLines: 6, height: $messageHeight, onSubmit: send)
                    .frame(height: messageHeight)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.onInk)
                        .frame(width: 26, height: 26).background(Circle().fill(Palette.ink))
                }
                .buttonStyle(.plain)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ClaudeCodeSession.binary == nil)
            }
            .padding(12)
        }
        .onReceive(clock) { now = $0 }
    }

    private var status: some View {
        HStack(spacing: 8) {
            if job.running {
                ProgressView().controlSize(.small)
                Text("Working · \(clockText)").font(.system(size: 12.5, weight: .medium))
                Spacer()
                Button("Stop") { job.stop() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(.red)
            } else {
                Text(job.entries.isEmpty ? "Runs your whole recipe with Claude Code" : "Waiting for you").font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.subtle)
                Spacer()
                if !job.entries.isEmpty {
                    Button("New job") { job.newJob() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.subtle)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var clockText: String {
        _ = now
        let t = Int(job.elapsed)
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste a whole recipe, like your Day reel prompt. Claude Code works through it with your scripts and tools, and you can watch each step here.")
            Text("It works on its own only inside the folders your prompt mentions and Bubble Recordings. Deleting, moving, other folders, the internet or opening apps wait for your OK. It never posts anything.")
                .foregroundStyle(Palette.subtle)
            if ClaudeCodeSession.binary == nil {
                Text("Full jobs need Claude Code installed and signed in.").foregroundStyle(.orange)
            }
        }
        .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func row(_ e: ReelJob.Entry) -> some View {
        switch e.kind {
        case .you:
            Text(e.text.count > 400 ? String(e.text.prefix(400)) + "…" : e.text)
                .font(.system(size: 12.5)).foregroundStyle(Palette.onInk).lineLimit(8)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.ink))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .claude:
            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedStringKey(e.text)).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                ForEach(ReelJob.videos(in: e.text), id: \.self) { videoRow($0) }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.canvas))
            .frame(maxWidth: .infinity, alignment: .leading)
        case .step:
            Label(e.text, systemImage: "gearshape").font(.system(size: 11.5)).foregroundStyle(Palette.subtle).lineLimit(2)
        case .done:
            Label(e.text, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
        case .problem:
            Label(e.text, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func videoRow(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "film").foregroundStyle(Theme.accent)
            Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Play") { NSWorkspace.shared.open(url) }.font(.system(size: 12))
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.font(.system(size: 12))
        }
    }

    private func approvalCard(_ a: ClaudeCodeSession.Approval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs your OK", systemImage: "hand.raised.fill").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.orange)
            Text(a.summary).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(10)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Don't allow") { job.answer(allow: false) }
                Button("Allow") { job.answer(allow: true) }.keyboardShortcut(.defaultAction)
            }
            .font(.system(size: 12))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.orange.opacity(0.35)))
    }

    private func send() {
        let t = message
        message = ""
        job.send(t, recording: recording)
    }
}
