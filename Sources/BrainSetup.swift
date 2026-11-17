import AppKit
import SwiftUI

// Connecting an AI, the same way in the welcome tour and in Settings. You pick the AI you already use, and only
// that one's steps appear: Claude connects by itself when Claude Code is signed in, ChatGPT and Gemini ask for a
// key in one clearly labelled box (with a button to the page that makes one), and the key is checked with the
// service before Mercury says it's connected. A key pasted under the wrong AI is recognised and moved.
// There is no address box unless you choose "Another service", which is the only case that needs one.

enum AIService: String, CaseIterable, Identifiable {
    case claude, chatgpt, gemini, free, grok, openrouter, ollama, custom
    var id: String { rawValue }

    static let main: [AIService] = [.claude, .chatgpt, .gemini, .free]
    static let others: [AIService] = [.grok, .openrouter, .ollama, .custom]

    var name: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "ChatGPT"
        case .gemini: "Gemini"
        case .free: "Mercury free"
        case .grok: "Grok"
        case .openrouter: "OpenRouter"
        case .ollama: "Ollama"
        case .custom: "Another service"
        }
    }

    var blurb: String {
        switch self {
        case .claude: "Pro or Max plan"
        case .chatgpt: "OpenAI key"
        case .gemini: "Free Google key"
        case .free: "No account"
        case .grok: "xAI key"
        case .openrouter: "Many models, one key"
        case .ollama: "Runs on this Mac"
        case .custom: "Works like OpenAI"
        }
    }

    /// Where its key lives in the Keychain. ChatGPT keeps the original account, so keys saved before still work.
    var keyAccount: String? {
        switch self {
        case .chatgpt: Keychain.openAIAccount
        case .gemini: "gemini-api-key"
        case .grok: "grok-api-key"
        case .openrouter: "openrouter-api-key"
        case .custom: "custom-api-key"
        case .claude, .free, .ollama: nil
        }
    }

    /// The address it lives at. Gemini goes through its own client, so it needs none.
    var base: String {
        switch self {
        case .grok: "https://api.x.ai/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .ollama: "http://localhost:11434/v1"
        default: ""
        }
    }

    /// A model that can see pictures, so it can read the screen.
    var defaultModel: String {
        switch self {
        case .chatgpt: "gpt-5-mini"
        case .grok: "grok-4"
        case .openrouter: "openai/gpt-5-mini"
        case .ollama: "gemma3"
        default: ""
        }
    }

    var keyPage: URL? {
        switch self {
        case .chatgpt: URL(string: "https://platform.openai.com/api-keys")
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        case .grok: URL(string: "https://console.x.ai")
        case .openrouter: URL(string: "https://openrouter.ai/keys")
        case .claude: URL(string: "https://console.anthropic.com/settings/keys")
        default: nil
        }
    }

    var keyHint: String {
        switch self {
        case .chatgpt: "sk-proj-…"
        case .gemini: "AIza… or AQ.…"
        case .grok: "xai-…"
        case .openrouter: "sk-or-…"
        case .claude: "sk-ant-…"
        default: "Key"
        }
    }

    /// What getting a key involves, in a sentence.
    var keyNote: String {
        switch self {
        case .chatgpt: "Sign in, press Create new secret key and copy it. Keys are separate from a ChatGPT Plus plan and need a little credit on your OpenAI account, under Billing."
        case .gemini: "Free. Sign in with your Google account, press Create API key and copy it."
        case .grok: "Sign in, open API Keys, create one and copy it."
        case .openrouter: "Sign in, press Create Key and copy it. One key reaches models from many companies."
        case .claude: "Use is billed to your Anthropic account, separately from a Claude plan."
        case .custom: "Your service's documentation says where to find its address, key and model names."
        default: ""
        }
    }

    /// Which service a pasted key belongs to, from how it starts.
    static func spot(key: String) -> AIService? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.hasPrefix("sk-ant-") { return .claude }
        if k.hasPrefix("AIza") || k.hasPrefix("AQ.") { return .gemini }
        if k.hasPrefix("xai-") { return .grok }
        if k.hasPrefix("sk-or-") { return .openrouter }
        if k.hasPrefix("sk-") { return .chatgpt }
        return nil
    }
}

extension Settings {
    /// The AI you connected. Before this existed it's worked out from the older settings, so nobody is reset.
    static var aiService: AIService {
        get {
            if let s = AIService(rawValue: d.string(forKey: "aiService") ?? "") { return s }
            switch assistantBrain {
            case .claudeCode, .api: return .claude
            case .free: return .free
            case .openai:
                let b = (d.string(forKey: "openAIBaseURL") ?? "").lowercased()
                if b.contains("x.ai") { return .grok }
                if b.contains("openrouter") { return .openrouter }
                if b.contains("11434") { return .ollama }
                if b.contains("generativelanguage") { return .gemini }
                if b.isEmpty || b.contains("api.openai.com") || looksLikeKey(b) { return .chatgpt }
                return .custom
            }
        }
        set { d.set(newValue.rawValue, forKey: "aiService") }
    }

    /// Makes Mercury answer with `service`. Claude uses Claude Code unless `anthropicKey` is on.
    static func use(_ service: AIService, anthropicKey: Bool = false, customBase: String? = nil, model: String? = nil) {
        // Offscreen test pictures never change your real settings.
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--") && $0.hasSuffix("shot") }) { log("brain: test, not saving \(service.rawValue)"); return }
        aiService = service
        switch service {
        case .claude: assistantBrain = anthropicKey ? .api : .claudeCode
        case .free: assistantBrain = .free
        default:
            assistantBrain = .openai
            openAIBaseURL = service == .custom ? (customBase ?? openAIBaseURL) : service.base
            if let model { openAIModel = model } else if service != .custom { openAIModel = service.defaultModel }
        }
        log("brain: using \(service.rawValue)\(anthropicKey ? " key" : "")")
    }
}

/// Asks a service whether a key works, before Mercury says it's connected. Nothing but the key is sent.
enum KeyCheck {
    /// Nil when it works, otherwise what to tell you.
    static func verify(_ service: AIService, key: String, base: String = "") async -> String? {
        var url: URL?
        var headers: [String: String] = [:]
        switch service {
        case .chatgpt: url = URL(string: "https://api.openai.com/v1/models"); headers["authorization"] = "Bearer \(key)"
        case .gemini: url = URL(string: GeminiClient.base + "/models"); headers["x-goog-api-key"] = key
        case .grok: url = URL(string: "https://api.x.ai/v1/models"); headers["authorization"] = "Bearer \(key)"
        case .openrouter: url = URL(string: "https://openrouter.ai/api/v1/key"); headers["authorization"] = "Bearer \(key)"
        case .claude:
            url = URL(string: "https://api.anthropic.com/v1/models")
            headers["x-api-key"] = key; headers["anthropic-version"] = "2023-06-01"
        case .ollama: url = URL(string: "http://localhost:11434/api/tags")
        case .custom:
            guard let e = Settings.openAIEndpoint(base), !Settings.looksLikeKey(base) else {
                return "That address doesn't look right. It should start with https:// and usually ends in /v1."
            }
            url = URL(string: e.absoluteString.replacingOccurrences(of: "/chat/completions", with: "/models"))
            if !key.isEmpty { headers["authorization"] = "Bearer \(key)" }
        case .free: return nil
        }
        guard let url else { return "Something went wrong. Try again." }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (_, r) = try await URLSession.shared.data(for: req)
            let status = (r as? HTTPURLResponse)?.statusCode ?? 0
            log("keycheck: \(service.rawValue) \(status)")
            if (200..<300).contains(status) { return nil }
            if status == 401 || status == 403 || (service == .gemini && status == 400) {
                return "\(service.name) says that key doesn't work. Copy it again from \(service.keyPage?.host ?? "the service") and paste the whole thing."
            }
            if status == 429 { return nil }   // the key is fine, just busy
            if service == .custom { return nil }   // some services don't list models; the first question will tell
            return "\(service.name) answered with an error (\(status)). Try again in a minute."
        } catch {
            if service == .ollama { return "Ollama isn't running. Open the Ollama app, then press Check again." }
            return "Mercury couldn't reach \(service.name). Check your internet and try again."
        }
    }
}

struct BrainSetup: View {
    /// The welcome tour is dark; Settings follows the window.
    var dark = false
    /// Shown as a Continue button once connected (the welcome tour).
    var onContinue: (() -> Void)?

    @State private var picked: AIService?
    @State private var showOthers = false
    @State private var connected: AIService?
    @State private var claude = ClaudeState.checking
    @State private var watchingSignIn = false
    @State private var anthropicKey = false
    @State private var key = ""
    @State private var customBase = ""
    @State private var model = ""
    @State private var showModel = false
    @State private var checking = false
    @State private var message: String?
    @State private var note: String?
    @State private var replacing = false

    enum ClaudeState { case checking, signedIn, signedOut, missing }

    private var ink: Color { dark ? .white : Palette.ink }
    private var sub: Color { dark ? .white.opacity(0.6) : Palette.subtle }
    private var panel: Color { dark ? .white.opacity(0.07) : Palette.canvas }
    private var line: Color { dark ? .white.opacity(0.12) : Palette.border }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ForEach(AIService.main) { tile($0) }
                otherTile
            }
            if showOthers {
                HStack(spacing: 8) {
                    ForEach(AIService.others) { s in pill(s.name, on: picked == s) { choose(s) } }
                    Spacer(minLength: 0)
                }
            }
            if let p = picked { detail(p).transition(.opacity) }
        }
        .animation(.spring(duration: 0.35), value: picked)
        .animation(.spring(duration: 0.35), value: showOthers)
        .onAppear(perform: start)
    }

    // MARK: Tiles

    private func tile(_ s: AIService) -> some View {
        let on = picked == s
        return Button { choose(s) } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    mark(s).frame(width: 38, height: 38)
                    if connected == s {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(.white, .green)
                            .offset(x: 7, y: -6)
                    }
                }
                Text(s.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                Text(s.blurb).font(.system(size: 11.5)).foregroundStyle(sub).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? Theme.accent.opacity(dark ? 0.22 : 0.12) : panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(on ? Theme.accent : line, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var otherTile: some View {
        let on = picked.map { AIService.others.contains($0) } ?? false
        return Button { withAnimation { showOthers.toggle() } } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(dark ? Color.white.opacity(0.14) : Palette.selected)
                        .overlay(HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(ink.opacity(0.7)).frame(width: 5, height: 5) } })
                        .frame(width: 38, height: 38)
                    if let c = connected, AIService.others.contains(c) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(.white, .green).offset(x: 7, y: -6)
                    }
                }
                Text("Other").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(ink)
                Text("Grok, Ollama…").font(.system(size: 11.5)).foregroundStyle(sub).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? Theme.accent.opacity(dark ? 0.22 : 0.12) : panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(on || showOthers ? Theme.accent : line, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Each AI's own logo in its own colours, or Mercury's planet.
    @ViewBuilder private func mark(_ s: AIService) -> some View {
        switch s {
        case .free:
            if let p = Brand.planet { Image(nsImage: p).resizable().scaledToFit() }
        case .claude:
            logo(BrandLogo.claude, AnyShapeStyle(Color(red: 0.851, green: 0.467, blue: 0.341)))
        case .chatgpt:
            logo(BrandLogo.openai, AnyShapeStyle(ink))
        case .gemini:
            logo(BrandLogo.gemini, AnyShapeStyle(LinearGradient(colors: [Color(red: 0.28, green: 0.59, blue: 0.89), Color(red: 0.57, green: 0.47, blue: 0.78), Color(red: 0.79, green: 0.40, blue: 0.45)],
                                                              startPoint: .bottomLeading, endPoint: .topTrailing)))
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func logo(_ image: NSImage?, _ style: AnyShapeStyle) -> some View {
        if let image { Image(nsImage: image).renderingMode(.template).resizable().scaledToFit().padding(3).foregroundStyle(style) }
    }

    // MARK: Steps for the picked AI

    @ViewBuilder private func detail(_ s: AIService) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if connected == s && !replacing && (s != .claude || anthropicKey || claude == .signedIn) {
                connectedView(s)
            } else {
                switch s {
                case .claude: claudeSteps
                case .free: EmptyView()
                case .ollama: ollamaSteps
                default: keySteps(s)
                }
            }
            if let note { Text(note).font(.system(size: 12.5)).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true) }
            if let message {
                Label(message, systemImage: "exclamationmark.circle.fill").font(.system(size: 12.5)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(line))
    }

    private func connectedView(_ s: AIService) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(.white, .green)
                Text("Connected to \(s == .claude && Settings.assistantBrain == .api ? "Claude with your key" : s.name)")
                    .font(.system(size: 14.5, weight: .semibold)).foregroundStyle(ink)
            }
            Text(connectedText(s)).font(.system(size: 12.5)).foregroundStyle(sub).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let onContinue { button("Continue", primary: true) { onContinue() } }
                if s.keyAccount != nil || (s == .claude && Settings.assistantBrain == .api) {
                    button("Use a different key", primary: false) { replacing = true; key = ""; message = nil; note = nil }
                }
                if s != .free && s != .claude { modelLink(s) }
            }
        }
    }

    private func connectedText(_ s: AIService) -> String {
        switch s {
        case .claude where Settings.assistantBrain == .api: "I answer and look at your screen when you ask. Doing things on your Mac needs Claude Code."
        case .claude: "I'll know your notes and the apps you connected to Claude, and I can do things for you, always with your OK."
        case .free: "40 messages a day on this Mac, no account. I answer and look at your screen when you ask. Doing things on your Mac needs Claude."
        default: "Your key is saved in your Mac's Keychain. I answer and look at your screen when you ask. Doing things on your Mac needs Claude."
        }
    }

    @ViewBuilder private var claudeSteps: some View {
        if anthropicKey {
            keySteps(.claude)
            linkButton("Use Claude Code instead") { anthropicKey = false; message = nil; note = nil; checkClaude() }
        } else {
            switch claude {
            case .checking:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for Claude on this Mac…").foregroundStyle(sub) }
                    .font(.system(size: 13))
            case .signedIn:
                EmptyView()
            case .signedOut:
                step(1, "Claude is on this Mac but isn't signed in yet.")
                Text("Press Sign in. Your browser opens; sign in with your Claude Pro or Max account and I'll connect by myself.")
                    .font(.system(size: 12.5)).foregroundStyle(sub).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    button("Sign in with Claude", primary: true) { signIn() }
                    if watchingSignIn {
                        ProgressView().controlSize(.small)
                        Text("Waiting for you to finish in the browser…").font(.system(size: 12.5)).foregroundStyle(sub)
                    }
                }
            case .missing:
                Text("Claude Code isn't on this Mac yet. It comes with Claude Pro and Max, and lets me use your Claude.")
                    .font(.system(size: 13)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                step(1, "Copy this, open Terminal, paste it and press Return.")
                HStack(spacing: 8) {
                    Text(Self.install).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(ink).textSelection(.enabled)
                        .lineLimit(1).padding(.horizontal, 10).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(dark ? Color.black.opacity(0.3) : Palette.card))
                    button("Copy", primary: false) { copy(Self.install); note = "Copied. Now open Terminal and paste it." }
                    button("Open Terminal", primary: false) { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")) }
                }
                step(2, "When it finishes, come back here. I'll notice and help you sign in.")
                HStack(spacing: 8) {
                    button("Check again", primary: true) { checkClaude() }
                    ProgressView().controlSize(.small).opacity(watchingSignIn ? 1 : 0)
                }
            }
            if claude != .checking && claude != .signedIn {
                linkButton("Have an Anthropic API key instead?") { anthropicKey = true; message = nil; note = nil }
            }
        }
    }

    @ViewBuilder private func keySteps(_ s: AIService) -> some View {
        if s == .custom {
            step(1, "Its address and model")
            HStack(spacing: 8) {
                field("https://api.example.com/v1", text: $customBase, secure: false)
                field("Model that sees pictures", text: $model, secure: false).frame(maxWidth: 220)
            }
            step(2, "Your key (leave empty if it doesn't need one)")
        } else {
            step(1, "Get your \(s.name) key")
            HStack(spacing: 8) {
                if let page = s.keyPage { button("Open \(page.host ?? "the page")", primary: false, icon: "arrow.up.right") { NSWorkspace.shared.open(page) } }
            }
            Text(s.keyNote).font(.system(size: 12.5)).foregroundStyle(sub).fixedSize(horizontal: false, vertical: true)
            step(2, "Paste it here")
        }
        HStack(spacing: 8) {
            field(s.keyHint, text: $key, secure: true)
            button(checking ? "Checking…" : "Connect", primary: true) { connect(s) }
                .disabled(checking || (key.trimmingCharacters(in: .whitespaces).isEmpty && s != .custom))
                .opacity(checking || (key.trimmingCharacters(in: .whitespaces).isEmpty && s != .custom) ? 0.5 : 1)
        }
        if s == .custom {
            Text(s.keyNote).font(.system(size: 12.5)).foregroundStyle(sub).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var ollamaSteps: some View {
        Text("Ollama runs AI models on this Mac, so nothing leaves it. Install it from ollama.com, then get a model that can see pictures, such as gemma3.")
            .font(.system(size: 12.5)).foregroundStyle(sub).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
            button(checking ? "Checking…" : "Connect", primary: true) { connect(.ollama) }.disabled(checking)
            button("Open ollama.com", primary: false, icon: "arrow.up.right") { NSWorkspace.shared.open(URL(string: "https://ollama.com")!) }
        }
    }

    private func modelLink(_ s: AIService) -> some View {
        Group {
            if showModel {
                HStack(spacing: 6) {
                    field(s.defaultModel.isEmpty ? "Model" : s.defaultModel, text: $model, secure: false).frame(width: 180)
                    button("Save", primary: false) { Settings.openAIModel = model; showModel = false; note = "Model saved." }
                }
            } else {
                linkButton("Model: \(s == .gemini ? GeminiClient.model(Settings.openAIModel) : Settings.openAIModel)") { model = Settings.openAIModel; showModel = true }
            }
        }
    }

    // MARK: Pieces

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text("\(n)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(Theme.onBrand)
                .frame(width: 20, height: 20).background(Circle().fill(Theme.brand))
            Text(text).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(ink)
        }
    }

    private func field(_ prompt: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure { SecureField("", text: text, prompt: Text(prompt).foregroundColor(sub.opacity(0.7))) }
            else { TextField("", text: text, prompt: Text(prompt).foregroundColor(sub.opacity(0.7))) }
        }
        .textFieldStyle(.plain).font(.system(size: 13.5, design: secure ? .monospaced : .default)).foregroundStyle(ink)
        .padding(.horizontal, 10).frame(height: 32).frame(maxWidth: 340)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(dark ? Color.black.opacity(0.3) : Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(line))
    }

    private func button(_ title: String, primary: Bool, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
            }
            .foregroundStyle(primary ? Theme.onBrand : ink)
            .padding(.horizontal, 14).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(primary ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(dark ? Color.white.opacity(0.12) : Palette.card)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(primary ? Color.clear : line))
        }
        .buttonStyle(.plain)
    }

    private func pill(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(on ? Theme.onBrand : ink)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(on ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(panel)))
                .overlay(Capsule().stroke(on ? Color.clear : line))
        }
        .buttonStyle(.plain)
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.accent) }.buttonStyle(.plain)
    }

    private func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

    static let install = "curl -fsSL https://claude.ai/install.sh | bash"

    // MARK: Doing it

    private func start() {
        // Testing: -setupPick picks a tile, so each layout can be pictured offscreen.
        if let raw = Settings.d.string(forKey: "setupPick"), let s = AIService(rawValue: raw) {
            picked = s; showOthers = AIService.others.contains(s)
            if s == .claude { claude = ClaudeState(rawValue: Settings.d.string(forKey: "setupClaude") ?? "") ?? .missing }
            return
        }
        if onContinue == nil || Settings.d.string(forKey: "aiService") != nil {
            let s = Settings.aiService
            connected = s; picked = s; showOthers = AIService.others.contains(s)
            anthropicKey = s == .claude && Settings.assistantBrain == .api
        }
        checkClaude(autoPick: onContinue != nil && connected == nil)
    }

    private func choose(_ s: AIService) {
        message = nil; note = nil; key = ""; replacing = false; showModel = false
        picked = s
        if s == .custom { customBase = Settings.aiService == .custom ? Settings.openAIBaseURL : ""; model = Settings.aiService == .custom ? Settings.openAIModel : "" }
        switch s {
        case .free: Settings.use(.free); connected = .free
        case .claude: if !anthropicKey { checkClaude() }
        default:
            // A key for it is already saved: use it straight away.
            if let acct = s.keyAccount, s != .custom, Keychain.hasKey(account: acct) { Settings.use(s); connected = s }
        }
    }

    private func checkClaude(autoPick: Bool = false) {
        claude = .checking
        Task { @MainActor in
            let s: ClaudeState = ClaudeCodeSession.binary == nil ? .missing : (await OnboardingView.claudeSignedIn() ? .signedIn : .signedOut)
            claude = s
            if s == .signedIn {
                if autoPick || picked == .claude {
                    picked = .claude; anthropicKey = false
                    Settings.use(.claude); connected = .claude
                    if autoPick { note = "Claude is on this Mac and signed in, so I picked it for you." }
                }
            } else if s == .missing, picked == .claude { watchForInstall() }
        }
    }

    private func signIn() {
        ClaudeCodeSession.openSignIn()
        watchingSignIn = true
        Task { @MainActor in
            for _ in 0..<150 {
                try? await Task.sleep(for: .seconds(2))
                if picked != .claude { break }
                if await OnboardingView.claudeSignedIn() {
                    Sounds.tour(.granted); claude = .signedIn; Settings.use(.claude); connected = .claude
                    break
                }
            }
            watchingSignIn = false
        }
    }

    /// While the install steps are showing, notice Claude Code arriving by itself.
    private func watchForInstall() {
        guard !watchingSignIn else { return }
        watchingSignIn = true
        Task { @MainActor in
            for _ in 0..<200 {
                try? await Task.sleep(for: .seconds(3))
                if picked != .claude || anthropicKey || claude != .missing { break }
                if ClaudeCodeSession.binary != nil { watchingSignIn = false; checkClaude(); return }
            }
            watchingSignIn = false
        }
    }

    private func connect(_ chosen: AIService) {
        var s = chosen
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        message = nil; note = nil
        // A key for a different AI: go with the AI the key belongs to.
        if let spotted = AIService.spot(key: k), spotted != s, s != .custom, s != .ollama {
            note = "That's a \(spotted == .claude ? "Claude (Anthropic)" : spotted.name) key, so I switched to \(spotted.name)."
            s = spotted
            picked = s; showOthers = AIService.others.contains(s)
            if s == .claude { anthropicKey = true }
        }
        if s == .custom && Settings.looksLikeKey(customBase) {
            message = "That's a key, not an address. Put the key in box 2, and the service's web address in box 1."
            return
        }
        checking = true
        let base = customBase
        Task { @MainActor in
            let problem = await KeyCheck.verify(s, key: k, base: base)
            checking = false
            if let problem { message = problem; return }
            if s == .claude { Keychain.setAPIKey(k); Settings.use(.claude, anthropicKey: true) }
            else {
                if let acct = s.keyAccount, !k.isEmpty || s != .custom { Keychain.setKey(k, account: acct) }
                Settings.use(s, customBase: s == .custom ? base : nil, model: s == .custom ? model : nil)
            }
            key = ""; replacing = false; connected = s
            Sounds.tour(.granted)
        }
    }
}

extension BrainSetup.ClaudeState {
    init?(rawValue: String) {
        switch rawValue { case "signedIn": self = .signedIn; case "signedOut": self = .signedOut; case "missing": self = .missing; default: return nil }
    }
}
