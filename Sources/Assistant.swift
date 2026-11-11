// Ask Mercury: a translucent panel you open with a shortcut, anywhere. It can see your screen
// (a screenshot each time you ask) and hear what's playing and what you say (live, on-device
// transcription), and Claude answers in real time with your own API key.
//
// It is deliberately honest: the panel shows up in screen shares and recordings like any other
// window, and a red dot shows whenever it's listening.
//
// This file holds the panel's model: what you've asked, the answers, chats and the brain that answers.
// The rest of Ask Mercury lives in AssistantSenses.swift (listening and screenshots), AssistantClient.swift
// (talking to Claude), AssistantPanel.swift (the floating window), AssistantView.swift (the chat itself),
// RichAnswer.swift, ChatPictures.swift, ChatYouTube.swift and ChatStyle.swift (how answers look).

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import CryptoKit
import ScreenCaptureKit
import Speech
import SwiftUI
import WebKit

// MARK: - When Mercury hides its Dock icon

/// Mercury lives in the menu bar. Its Dock icon shows only while its main window is open, like
/// other menu-bar helpers. (macOS only shows a Dock app's windows on that app's own desktops, so
/// while the pill follows you or the assistant is open, Mercury stays a menu-bar app so its panels
/// can appear over other apps' full-screen spaces too.)
enum AppPresence {
    private static var reasons = Set<String>()
    private static var windowOpen = false
    private static var windowFullScreen = false
    static func need(_ reason: String, _ on: Bool) {
        if on { reasons.insert(reason) } else { reasons.remove(reason) }
        apply()
    }
    static func mainWindow(_ open: Bool) {
        windowOpen = open
        if !open { windowFullScreen = false }
        apply()
    }
    /// A full screen window must keep the menu bar and its title bar buttons, or there is no way out of it.
    static func mainWindowFullScreen(_ on: Bool) {
        windowFullScreen = on
        apply()
    }
    private static func apply() {
        let want: NSApplication.ActivationPolicy = windowOpen && (reasons.isEmpty || windowFullScreen) ? .regular : .accessory
        if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
    }
}

// MARK: - Settings

enum AssistantModelChoice: String, CaseIterable, Identifiable {
    case fast, balanced, smart
    var id: String { rawValue }
    var title: String { switch self { case .fast: "Fast"; case .balanced: "Balanced"; case .smart: "Smartest" } }
    var detail: String { switch self { case .fast: "Haiku 5.5"; case .balanced: "Sonnet 5.5"; case .smart: "Opus 5.5" } }
    var modelID: String { switch self { case .fast: "claude-haiku-5-5"; case .balanced: "claude-sonnet-5-5"; case .smart: "claude-opus-5-5" } }
}

extension Settings {
    static var assistantModel: AssistantModelChoice {
        get { AssistantModelChoice(rawValue: d.string(forKey: "assistantModel") ?? "") ?? .balanced }
        set { d.set(newValue.rawValue, forKey: "assistantModel") }
    }
    static var assistantHearsMac: Bool { get { d.object(forKey: "assistantHearsMac") as? Bool ?? true } set { d.set(newValue, forKey: "assistantHearsMac") } }
    static var assistantHearsMic: Bool { get { d.object(forKey: "assistantHearsMic") as? Bool ?? true } set { d.set(newValue, forKey: "assistantHearsMic") } }
}

// MARK: - The panel

/// Which brain answers: the Claude Code you already use (your memory, apps and subscription), or
/// the plain API with an API key.
enum AssistantBrain: String, CaseIterable, Identifiable {
    case claudeCode, free, openai, api
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claudeCode: "Claude Code (your context)"
        case .free: "Mercury's free AI"
        case .openai: "Your own key (OpenAI, Gemini and more)"
        case .api: "Anthropic API key"
        }
    }
}

extension Settings {
    static var assistantBrain: AssistantBrain {
        // Nothing chosen yet: Claude Code if it's on this Mac, otherwise Mercury's free AI, so nobody hits a dead end.
        get { AssistantBrain(rawValue: d.string(forKey: "assistantBrain") ?? "") ?? (ClaudeCodeSession.binary != nil ? .claudeCode : .free) }
        set { d.set(newValue.rawValue, forKey: "assistantBrain") }
    }
}

@MainActor
final class AssistantModel: ObservableObject {
    struct Exchange: Identifiable {
        let id = UUID(); var question: String; var answer: String; var withScreen: Bool; var activity: String?
        /// Your reactions to Mercury's messages in this reply, by message number.
        var reactions: [Int: [String]] = [:]
        var reactionsTold = false
        var at = Date()
        var replyTo: ChatReply? = nil
    }

    @Published var exchanges: [Exchange] = []
    @Published var input = ""
    let drill = DrillTimer()
    @Published var thinking = false
    @Published var error: String?
    @Published var listening = false
    @Published var lines: [String] = []
    @Published var live = ""
    @Published var level: Float = 0
    @Published var seeScreen = true
    @Published var cardOpen = true
    @Published var focusRequest = 0
    /// Puts the cursor in the message box, making the panel key. Only for things you did in the panel.
    var focusInput: () -> Void = {}
    /// Claude is typing or clicking in other apps right now, so the panel stays off the keyboard.
    @Published var controllingMac = false
    var onControllingChange: (Bool) -> Void = { _ in }
    /// The message your next text will reply to.
    @Published var replyingTo: ChatReply?
    /// The size you've made the panel. Nil means it grows to fit the conversation.
    @Published var panelSize: CGSize?
    @Published var panelFull = false
    /// How big the conversation wants the panel to be when you haven't set a size.
    @Published var fitSize = CGSize.zero
    enum PanelResize { case begin, frame(NSRect), end, preset(CGSize), full, automatic }
    var panelResize: (PanelResize) -> Void = { _ in }
    /// Opens the chat list (used by tests to take screenshots).
    @Published var historyRequest = 0
    @Published var approval: ClaudeCodeSession.Approval?
    @Published var talking = false
    /// The chat on screen, saved to disk as it goes.
    @Published private(set) var chat = ChatRecord()
    /// Your previous chat, offered as "Continue" after Mercury started a fresh one.
    @Published var resumable: ChatRecord?
    private var speech: SpeechSession?
    private var silence: Timer?

    static let sayPrompt = "Based on the conversation and my screen, what should I say next? Give me the exact words."
    static let screenPrompt = "Help me with what's on my screen right now: what is it, and what should I do or know?"

    let listener = LiveListener()
    let session = ClaudeCodeSession()
    var panelNumber: () -> [Int] = { [] }
    private var current: Task<Void, Never>?

    /// Test renders pass true so they never touch your saved chats.
    init(forTesting: Bool = false) {
        listener.onChange = { [weak self] in
            guard let self else { return }
            self.lines = self.listener.lines.suffix(30).map(\.text)
            self.live = self.listener.live
            self.level = self.listener.level
            if self.listening && !self.listener.isRunning { self.listening = false }
        }
        session.onEvent = { [weak self] e in self?.handle(e) }
        session.onControlling = { [weak self] in self?.setControlling(true) }
        guard !forTesting else { return }
        ChatStore.prune()
        if let last = ChatStore.all().first { load(last) } else { session.switchTo(nil) }
    }

    // MARK: Chats

    private func load(_ c: ChatRecord) {
        chat = c
        replyingTo = nil
        exchanges = c.turns.map {
            Exchange(question: $0.question, answer: $0.answer, withScreen: $0.withScreen, activity: nil,
                     reactions: $0.reactions, reactionsTold: true, at: $0.at, replyTo: $0.replyTo)
        }
        session.switchTo(c.claudeSession)
    }

    /// Saves the chat on screen (only finished answers).
    func persist() {
        let turns = exchanges.filter { !$0.answer.isEmpty }.map {
            ChatRecord.Turn(question: $0.question, answer: $0.answer, withScreen: $0.withScreen, at: $0.at, reactions: $0.reactions, replyTo: $0.replyTo)
        }
        guard !turns.isEmpty else { return }
        chat.turns = turns
        chat.updated = Date()
        chat.claudeSession = session.conversationID
        ChatStore.save(chat)
    }

    func newChat() {
        stopAnswer()
        persist()
        replyingTo = nil
        chat = ChatRecord()
        exchanges = []
        error = nil
        resumable = nil
        session.switchTo(nil)
        focusInput()
    }

    func open(_ c: ChatRecord) {
        stopAnswer()
        persist()
        resumable = nil
        error = nil
        load(c)
        focusInput()
    }

    /// Gives a chat your own name (blank goes back to the first question). Its place in the list doesn't change.
    func renameChat(_ c: ChatRecord, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.id == chat.id {
            chat.name = n.isEmpty ? nil : n
            if !chat.turns.isEmpty { ChatStore.save(chat) }
        } else {
            var r = c
            r.name = n.isEmpty ? nil : n
            ChatStore.save(r)
        }
        log("assistant: chat renamed")
    }

    func deleteChat(_ c: ChatRecord) {
        ChatStore.delete(c.id)
        if c.id == chat.id { chat = ChatRecord(); exchanges = []; session.switchTo(nil) }
        if resumable?.id == c.id { resumable = nil }
    }

    /// Coming back after a long break starts a fresh chat, with the last one a tap away.
    func freshenIfStale() {
        guard !exchanges.isEmpty, !thinking, approval == nil,
              Date().timeIntervalSince(chat.updated) > ChatStore.freshAfter else { return }
        persist()
        let old = chat
        newChat()
        resumable = old
    }

    /// Opening the panel starts Claude Code in the background, so the first answer is quicker.
    func warmUp() {
        if Settings.assistantBrain == .claudeCode { session.warmUp() }
    }

    func toggleListening() {
        if listening {
            listener.stop()
            listening = false
        } else {
            listening = true
            error = nil
            Task {
                do { try await listener.start(mac: true, mic: false) }
                catch { self.listening = false; self.error = error.localizedDescription }
            }
        }
    }

    func ask(_ preset: String? = nil) {
        var q = (preset ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        if approval != nil, preset == nil, !q.isEmpty {
            input = ""
            spokenOrTyped(q)
            return
        }
        guard !q.isEmpty, !thinking else { return }
        if preset == nil { input = "" }
        // The drill timer's laps go on the end of what you typed; untouched if it never started.
        if preset == nil, let laps = drill.takeSummary() { q += "\n\n" + laps }
        error = nil
        thinking = true
        let reply = replyingTo
        replyingTo = nil
        // Mercury is told which message you mean; only the quote shows in the chat.
        let replyNote = reply.map { "(I'm replying to \($0.mine ? "something I said earlier" : "this message of yours"): \"\($0.text.prefix(1500))\")\n\n" } ?? ""
        let note = contextNote() + replyNote
        let history = exchanges.map { AssistantClient.Turn(question: $0.question, answer: $0.answer) }
        exchanges.append(Exchange(question: q, answer: "", withScreen: seeScreen, activity: seeScreen ? "Looking at your screen…" : "Thinking…", replyTo: reply))
        let index = exchanges.count - 1
        let transcript = listener.recent()
        let screen = seeScreen
        current = Task {
            let shot = screen ? await ScreenGrab.jpeg(excluding: panelNumber()) : nil
            if Settings.assistantBrain == .claudeCode {
                var text = ""
                if !transcript.isEmpty { text += "<recent_conversation>\n\(transcript)\n</recent_conversation>\n\n" }
                if let shot, let file = Self.saveShot(shot) {
                    text += "(The image is a screenshot of my screen right now. It's also saved at \(file.path) if you need to attach or upload it.)\n\n"
                }
                session.ask(text + note + q, screenshot: shot)
                return  // the answer arrives through handle(_:)
            }
            do {
                let onText: @MainActor (String) -> Void = { piece in
                    if index < self.exchanges.count { self.exchanges[index].answer += piece; self.exchanges[index].activity = nil }
                }
                switch Settings.assistantBrain {
                case .free: try await FreeAI.ask(note + q, history: history, screenshot: shot, transcript: transcript, onText: onText)
                case .openai: try await OpenAIClient.ask(note + q, history: history, screenshot: shot, transcript: transcript, onText: onText)
                default: try await AssistantClient.ask(note + q, history: history, screenshot: shot, transcript: transcript, onText: onText)
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
                if index < self.exchanges.count, self.exchanges[index].answer.isEmpty { self.exchanges.remove(at: index) }
            }
            self.thinking = false
            self.persist()
        }
    }

    /// Reactions you've added since your last message, and Mercury's nickname if you changed it.
    private func contextNote() -> String {
        var notes: [String] = []
        // Claude Code keeps the conversation, so what you brought over goes in once at the start.
        let about = Settings.assistantBrain == .claudeCode && exchanges.isEmpty ? AboutMe.forPrompt : ""
        let name = Settings.d.string(forKey: "chatName") ?? ""
        if !name.isEmpty && name != "Mercury" { notes.append("In this chat I call you \(name).") }
        if let i = exchanges.indices.last(where: { !exchanges[$0].reactions.isEmpty && !exchanges[$0].reactionsTold }) {
            let parts = AssistantView.messages(AssistantView.splitReactions(exchanges[i].answer).text)
            for (n, r) in exchanges[i].reactions.sorted(by: { $0.key < $1.key }) where n < parts.count && !r.isEmpty {
                notes.append("I reacted \(r.joined()) to your message \"\(parts[n].prefix(80))\".")
            }
            exchanges[i].reactionsTold = true
        }
        return (about.isEmpty ? "" : about.trimmingCharacters(in: .newlines) + "\n\n") + (notes.isEmpty ? "" : "(" + notes.joined(separator: " ") + ")\n\n")
    }

    /// Starts a reply to one message. The next thing you send is tied to it.
    func reply(to text: String, exchange id: UUID, part: Int?) {
        guard let n = exchanges.firstIndex(where: { $0.id == id }) else { return }
        replyingTo = ChatReply(text: text, mine: part == nil, exchange: n, part: part)
        cardOpen = true
        focusInput()
    }

    func toggleReaction(_ emoji: String, exchange id: UUID, part: Int) {
        guard let i = exchanges.firstIndex(where: { $0.id == id }) else { return }
        var r = exchanges[i].reactions[part] ?? []
        if let k = r.firstIndex(of: emoji) { r.remove(at: k) } else { r.append(emoji) }
        exchanges[i].reactions[part] = r
        exchanges[i].reactionsTold = false
        persist()
    }

    func setControlling(_ on: Bool) {
        guard on != controllingMac else { return }
        controllingMac = on
        onControllingChange(on)
    }

    private func handle(_ e: ClaudeCodeSession.Event) {
        guard !exchanges.isEmpty else { return }
        let i = exchanges.count - 1
        switch e {
        case .text(let t):
            exchanges[i].answer += t
            exchanges[i].activity = nil
        case .activity(let a):
            exchanges[i].activity = a
            if !exchanges[i].answer.isEmpty && !exchanges[i].answer.hasSuffix("\n\n") { exchanges[i].answer += "\n\n" }
        case .approval(let a):
            approval = a
            cardOpen = true
        case .done(let err):
            thinking = false
            approval = nil
            // Hands the keyboard back a moment after Claude finishes, once its last keystrokes have landed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in if self?.thinking == false { self?.setControlling(false) } }
            exchanges[i].activity = nil
            if let err {
                error = err
                if exchanges[i].answer.isEmpty { exchanges.remove(at: i) }
            }
            persist()
        }
    }

    // MARK: Talking to it

    /// Say what you want; when you stop talking (or press the key again) it's asked, or, if
    /// Claude is waiting for your OK, "yes" / "no" answers that.
    func toggleTalk() { talking ? finishTalk() : startTalk() }

    func startTalk() {
        guard !talking else { return }
        cardOpen = true
        Task {
            if let problem = await SpeechSession.checkAvailability() { self.error = problem; return }
            let s = SpeechSession()
            s.onPartial = { [weak self] t in
                guard let self, self.talking else { return }
                self.input = t
            }
            s.onSilence = { [weak self] in self?.finishTalk() }
            do { try s.start(hints: ["yes", "send it", "go ahead", "no", "cancel"] + SnippetStore.shared.triggers) }
            catch { self.error = error.localizedDescription; return }
            self.speech = s
            self.talking = true
            self.input = ""
            self.error = nil
            Sounds.listen()
        }
    }

    func finishTalk() {
        guard talking, let s = speech else { return }
        talking = false
        silence?.invalidate()
        speech = nil
        Sounds.heard()
        s.stop { [weak self] raw in
            Task { @MainActor in
                let text = await s.bestTranscript(apple: raw, hints: ["yes", "send it"] + SnippetStore.shared.triggers)
                self?.spoken(text)
            }
        }
    }

    func cancelTalk() {
        silence?.invalidate()
        speech?.cancel()
        speech = nil
        talking = false
        input = ""
    }

    private static let yesWords = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "send", "send it", "go ahead", "do it", "confirm", "approve", "allow"]
    private static let noWords = ["no", "nope", "don't", "do not", "stop", "cancel", "deny", "wait", "hold on"]

    private func spoken(_ raw: String) {
        input = ""
        spokenOrTyped(Cleaner.clean(raw))
    }

    private func spokenOrTyped(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if approval != nil {
            let w = t.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if Self.noWords.contains(where: { w == $0 || w.hasPrefix($0 + " ") }) { decide(allow: false); return }
            if Self.yesWords.contains(where: { w == $0 || w.hasPrefix($0 + " ") || w.hasPrefix($0 + ",") }) { decide(allow: true); return }
            return  // waiting on a yes or no; ignore anything else
        }
        ask(t)
    }

    /// The latest screenshot, kept on disk so Claude can attach it to an email or upload it.
    private static func saveShot(_ data: Data) -> URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bubble/Assistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("screen.jpg")
        guard (try? data.write(to: url, options: [.atomic, .completeFileProtection])) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)  // only you can read it
        return url
    }

    func decide(allow: Bool, always: Bool = false) {
        guard let a = approval else { return }
        session.answer(a, allow: allow, always: always)
        approval = nil
    }

    func stopAnswer() {
        setControlling(false)
        current?.cancel()
        if Settings.assistantBrain == .claudeCode && thinking { session.interrupt() }
        if let a = approval { session.answer(a, allow: false); approval = nil }
        thinking = false
    }

    /// Starts a new chat; the current one stays in your history.
    func clear() {
        newChat()
        listener.clear()
    }
}
