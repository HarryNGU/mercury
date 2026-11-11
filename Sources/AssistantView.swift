// The Ask Mercury chat: the conversation, the text box, replies, approvals and the controls around them.
// It only draws what AssistantModel holds; asking and saving happen in the model.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import CryptoKit
import ScreenCaptureKit
import Speech
import SwiftUI
import WebKit

struct AssistantView: View {
    @ObservedObject var model: AssistantModel
    let onClose: () -> Void
    @ObservedObject private var keys = ShortcutCenter.shared
    @ObservedObject private var viewer = PictureViewer.shared
    @State private var jump: String?      // a message to scroll back to, from tapping a quote
    @State private var flash: String?     // that message, lit up for a moment
    @AppStorage("assistantDarkness") private var darkness = 0.62
    @AppStorage(Settings.showInCapturesKey) private var inCaptures = true
    @AppStorage("chatMyColor") private var myColor = ChatStyle.defaultMine
    @AppStorage("chatTheirColor") private var theirColor = ChatStyle.defaultTheirs
    @AppStorage("chatTextSize") private var textSize = 14.0
    @AppStorage("chatName") private var name = "Mercury"
    @AppStorage("chatAvatar") private var avatar = ""
    @State private var inputHeight: CGFloat = 18
    @State private var showTranscript = false
    @State private var showLook = false
    @State private var showBuddy = false
    @State private var showHistory = false
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var hoveredChat: UUID?
    @FocusState private var nameFocused: Bool
    @State private var listenInfo = false
    @State private var eyeInfo = false
    @State private var eyeHover: DispatchWorkItem?
    @State private var visibilityInfo = false
    @State private var visibilityHover: DispatchWorkItem?
    @State private var awayFromEnd = false   // you scrolled up, so new text shouldn't pull you down
    @State private var farFromEnd = false    // the latest message is well out of view
    @State private var listenHover: DispatchWorkItem?

    private let chips: [(String, String)] = [
        ("What should I say?", AssistantModel.sayPrompt),
        ("Explain this", "Explain what's on my screen right now, simply."),
        ("Summarise", "Summarise the conversation so far in a few bullets, with any decisions and to-dos."),
        ("Next step", "What's the best next step for what I'm doing on screen?"),
    ]

    private var glass: Color { Color.black.opacity(darkness) }
    private var sized: Bool { model.panelSize != nil }
    private var panelWidth: CGFloat { model.panelSize?.width ?? 700 }

    var body: some View {
        VStack(spacing: 8) {
            bar
            if model.cardOpen { card.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .frame(width: sized ? nil : 700)
        .frame(maxWidth: sized ? .infinity : nil, maxHeight: sized ? .infinity : nil, alignment: .top)
        .padding(.bottom, 4)
        .fixedSize(horizontal: false, vertical: !sized)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { if !sized { model.fitSize = $0 } }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.15), value: model.cardOpen)

    }

    // MARK: Bar

    private var bar: some View {
        // Each row is a bit more compact than the last; SwiftUI shows the first that truly fits the width.
        ViewThatFits(in: .horizontal) { barRow(0); barRow(1); barRow(2); barRow(3); barRow(4) }
        .frame(height: 42)
        // Drag the bar (anywhere that isn't a button) to move the panel.
        .background(WindowDragHandle())
        // The bar is small, so it's always dark enough to read over anything, with a light blur.
        .background(
            ZStack {
                VisualEffect(material: .hudWindow).opacity(0.85)
                Color.black.opacity(max(darkness, 0.6))
            }
            .clipShape(Capsule())
        )
        .shadow(color: .black.opacity(0.35), radius: 1)
        .overlay(Capsule().stroke(.white.opacity(0.16)))
        .overlay { PanelGrips(model: model, edges: model.cardOpen ? [.top, .topLeft, .topRight, .left, .right] : Set(PanelEdge.allCases), capsule: true) }
        .foregroundStyle(.white)
    }

    private func barRow(_ level: Int) -> some View {
        HStack(spacing: 4) {
            if level < 4 {
                Image(systemName: "circle.fill").font(.system(size: 13)).foregroundStyle(Theme.accent)
                    .padding(.leading, 14).padding(.trailing, 6)
            } else { Color.clear.frame(width: 4, height: 1) }
            barButton(model.listening ? "Listening" : "Listen", tight: level == 4, dot: model.listening ? .red : .white.opacity(0.35)) { listenInfo = false; model.toggleListening() }
                .onHover { inside in hoverCard(inside, item: &listenHover) { listenInfo = $0 } }
                .panelPopover(isPresented: $listenInfo, arrowEdge: .bottom) { listenCard }
            if level < 4 { divider }
            barButton(model.talking ? "Done" : "Talk", keys: level == 0 ? keys.label(.assistVoice) : nil, tight: level == 4, dot: model.talking ? .red : nil) { model.toggleTalk() }
            if level < 4 { divider }
            if level < 3 {
                barButton("Ask", keys: level == 0 ? keys.label(.assistAsk) : nil) { model.cardOpen = true; model.focusInput() }
                if level < 4 { divider }
                barButton(model.cardOpen ? "Collapse" : "Expand", keys: nil) { model.cardOpen.toggle() }
                if level < 4 { divider }
            }
            barButton("Hide", keys: level == 0 ? keys.label(.assist) : nil, tight: level == 4) { onClose() }
            if level < 4 { divider }
            Button { inCaptures.toggle() } label: {
                HStack(spacing: 7) {
                    if level < 2 { Text("Visibility").font(.system(size: 12.5, weight: .medium)).fixedSize() }
                    // Drawn by hand so it reads clearly even when the panel isn't the active window.
                    Capsule().fill(inCaptures ? Theme.accent : .white.opacity(0.22)).frame(width: 28, height: 16)
                        .overlay(alignment: inCaptures ? .trailing : .leading) {
                            Circle().fill(.white).frame(width: 12, height: 12).padding(2).shadow(color: .black.opacity(0.25), radius: 1)
                        }
                        .animation(.easeOut(duration: 0.15), value: inCaptures)
                }
                .padding(.horizontal, level == 4 ? 6 : 10).frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(inCaptures ? "Visibility on: shows in recordings and screen shares" : "Visibility off: only you can see Mercury")
            .onHover { inside in hoverCard(inside, item: &visibilityHover) { visibilityInfo = $0 } }
            .panelPopover(isPresented: $visibilityInfo, arrowEdge: .bottom) { visibilityCard }
            Spacer(minLength: 4)
            Button { model.panelResize(.full) } label: {
                Image(systemName: model.panelFull ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85)).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(model.panelFull ? "Back to your size" : "Fill the screen")
            .accessibilityLabel(model.panelFull ? "Back to your size" : "Fill the screen")
            Button { eyeInfo = false; model.seeScreen.toggle() } label: {
                Image(systemName: model.seeScreen ? "eye" : "eye.slash").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(model.seeScreen ? 0.9 : 0.45)).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.seeScreen ? "Screen sharing on: Mercury sees your screen when you ask" : "Screen sharing off")
            .onHover { inside in hoverCard(inside, item: &eyeHover) { eyeInfo = $0 } }
            .panelPopover(isPresented: $eyeInfo, arrowEdge: .bottom) { eyeCard }
            Menu {
                Button("New Chat") { model.newChat() }
                Button("Delete This Chat", role: .destructive) { model.deleteChat(model.chat) }.disabled(model.exchanges.isEmpty)
                Button("Report a Problem…") { ReportCenter.shared.show() }
                Divider()
                if level >= 3 { Button(model.cardOpen ? "Collapse" : "Expand") { model.cardOpen.toggle() }; Divider() }
                Menu("Size") {
                    Button("Small") { model.panelResize(.preset(CGSize(width: 420, height: 440))) }
                    Button("Medium") { model.panelResize(.preset(CGSize(width: 700, height: 640))) }
                    Button("Large") { model.panelResize(.preset(CGSize(width: 1040, height: 820))) }
                    Button("Fill the Screen") { model.panelResize(.full) }
                    Divider()
                    Button("Grow to Fit") { model.panelResize(.automatic) }
                }
                Divider()
                Text("Move: \(Settings.assistantMove.label) + arrow keys")
            } label: { Image(systemName: "ellipsis").foregroundStyle(.white.opacity(0.8)).frame(width: 26, height: 28).accessibilityLabel("More") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.trailing, 8)
        }
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 18) }

    private func barButton(_ title: String, keys: String? = nil, tight: Bool = false, dot: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(title).font(.system(size: 12.5, weight: .medium)).fixedSize()
                if let keys {
                    Text(keys).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.55)).fixedSize()
                        .padding(.horizontal, 5).frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.1)))
                }
            }
            .padding(.horizontal, tight ? 6 : 10).frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Card

    private var style: ChatStyle { ChatStyle.current(mine: myColor, theirs: theirColor, size: textSize) }

    /// Colours, see-through and text size, changed right from the chat.
    private var lookPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Chat look").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Your bubbles").font(.system(size: 11.5)).foregroundStyle(.secondary)
                HStack(spacing: 9) {
                    ForEach(ChatStyle.mineChoices, id: \.0) { hex, label in
                        Button { myColor = hex } label: {
                            Circle().fill(ChatStyle.color(hex) ?? .blue).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.primary.opacity(myColor == hex ? 0.9 : 0), lineWidth: 2).padding(-3))
                        }
                        .buttonStyle(.plain).help(label)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Their bubbles").font(.system(size: 11.5)).foregroundStyle(.secondary)
                SwiftUI.Picker("", selection: $theirColor) { ForEach(ChatStyle.theirsChoices, id: \.0) { Text($0.1).tag($0.0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("See-through").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { 1 - darkness }, set: { darkness = 1 - $0 }), in: 0.15...0.75)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Text size").font(.system(size: 11.5)).foregroundStyle(.secondary)
                SwiftUI.Picker("", selection: $textSize) { Text("S").tag(13.0); Text("M").tag(14.0); Text("L").tag(16.0) }
                    .pickerStyle(.segmented).labelsHidden()
            }
        }
        .padding(16)
        .frame(width: 270)
    }

    private func headerButton(_ icon: String, label: String, lit: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                .frame(width: 28, height: 28).background(Circle().fill(.white.opacity(lit ? 0.18 : 0.08)))
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    /// Your saved chats, newest first. Click one to carry on with it.
    private var historyList: some View {
        let chats = ChatStore.all()
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chats").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Button("New chat") { showHistory = false; model.newChat() }.buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            if chats.isEmpty {
                Text(Settings.chatKeepDays == 0 ? "Chats aren't being kept. You can change that in Settings → Assistant." : "Your chats will appear here.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 14)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(chats.prefix(40)) { c in
                            if renaming == c.id {
                                TextField("Chat name", text: $newName)
                                    .textFieldStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                                    .focused($nameFocused)
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12)))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent, lineWidth: 1.5))
                                    .onSubmit { model.renameChat(c, to: newName); renaming = nil }
                                    .onExitCommand { renaming = nil }
                                    .onAppear { DispatchQueue.main.async { nameFocused = true } }
                            } else {
                                Button { showHistory = false; model.open(c) } label: {
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(c.id == model.chat.id ? model.chat.title : c.title)
                                                .font(.system(size: 13, weight: c.id == model.chat.id ? .semibold : .medium))
                                                .foregroundStyle(.white).lineLimit(1)
                                            Text(c.updated.formatted(.relative(presentation: .named)) + " · \(c.turns.count) message\(c.turns.count == 1 ? "" : "s")")
                                                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                                        }
                                        Spacer(minLength: 4)
                                        if hoveredChat == c.id {
                                            Button { newName = c.name ?? c.title; renaming = c.id } label: {
                                                Image(systemName: "pencil").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                                                    .frame(width: 24, height: 24).background(Circle().fill(.white.opacity(0.12)))
                                            }
                                            .buttonStyle(.plain).help("Rename").accessibilityLabel("Rename chat")
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(c.id == model.chat.id ? Theme.accent.opacity(0.35)
                                                                                         : hoveredChat == c.id ? .white.opacity(0.08) : .clear))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onHover { hoveredChat = $0 ? c.id : (hoveredChat == c.id ? nil : hoveredChat) }
                                .contextMenu {
                                    Button("Rename…") { newName = c.name ?? c.title; renaming = c.id }
                                    Button("Delete Chat", role: .destructive) { model.deleteChat(c) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(maxHeight: 320)
            }
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
            Text(keepLabel).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).padding(12)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 320)
        .solidPopover()
    }

    private var keepLabel: String {
        switch Settings.chatKeepDays {
        case 0: return "Chats aren't kept after you close them."
        case -1: return "Chats stay on this Mac until you delete them."
        default: return "Chats stay on this Mac for \(Settings.chatKeepDays) days. Hover a chat to rename it; right-click to delete it."
        }
    }

    /// Hover cards open after a short pause and close soon after you move away.
    private func hoverCard(_ inside: Bool, item: inout DispatchWorkItem?, show: @escaping (Bool) -> Void) {
        item?.cancel()
        let work = DispatchWorkItem { show(inside) }
        item = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.45 : 0.15), execute: work)
    }

    /// A solid dark card with white text, so it reads clearly over anything behind it.
    private func infoCard<Content: View>(icon: String, title: String, intro: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            }
            Text(intro).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.85))
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(16)
        .frame(width: 310, alignment: .leading)
        .solidPopover()
    }

    private func infoRow(_ icon: String, _ t: String, _ d: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 12.5)).frame(width: 20).foregroundStyle(Theme.accent).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(t).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                Text(d).font(.system(size: 12)).foregroundStyle(.white.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func infoFoot(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
            Text(text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.65)).lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What Listen is for, shown when you hover over it.
    private var listenCard: some View {
        infoCard(icon: "speaker.wave.2.fill", title: "Listen to your Mac",
                 intro: "Mercury hears the sound playing on your Mac, not your microphone, so it can follow along and help.") {
            VStack(alignment: .leading, spacing: 10) {
                infoRow("person.2.wave.2", "Calls and meetings", "It hears the other people. Ask \"What should I say?\"")
                infoRow("play.rectangle", "Videos and lectures", "Ask it to explain or summarise what was said.")
                infoRow("headphones", "Podcasts and talks", "Ask about a point you missed.")
            }
            infoFoot("Want to talk to \(name.isEmpty ? "Mercury" : name) yourself? Use Talk (\(keys.label(.assistVoice))). Sound is turned into text on this Mac, and a red dot shows while it's on. Let people on a call know.")
        }
    }

    /// What the eye does, shown when you hover over it.
    private var eyeCard: some View {
        infoCard(icon: model.seeScreen ? "eye" : "eye.slash",
                 title: model.seeScreen ? "Mercury can see your screen" : "Mercury isn't looking at your screen",
                 intro: model.seeScreen
                    ? "Each time you ask, \(name.isEmpty ? "Mercury" : name) looks at your screen, so it knows what you're working on and can help right there."
                    : "\(name.isEmpty ? "Mercury" : name) only reads what you type or say. Turn the eye on when you want help with what's on your screen.") {
            VStack(alignment: .leading, spacing: 10) {
                infoRow("camera.viewfinder", "One picture per question", "Taken only when you ask, never in the background, and never of Mercury itself.")
                infoRow("text.magnifyingglass", "Help where you are", "\"What does this error mean?\", \"Reply to this email\", \"Explain this chart\".")
            }
            infoFoot("Click the eye to turn it \(model.seeScreen ? "off" : "on"). Turn it off for private screens, like banking or medical pages.")
        }
    }

    /// What Visibility does, shown when you hover over it.
    private var visibilityCard: some View {
        infoCard(icon: inCaptures ? "person.2.fill" : "person.fill",
                 title: inCaptures ? "Visibility is on" : "Visibility is off",
                 intro: inCaptures
                    ? "Anyone watching sees Mercury too: in your Mercury recordings and when you share your screen in Zoom, Meet, Teams or FaceTime."
                    : "Only you can see Mercury. It's left out of your Mercury recordings, screen shares in every app, and screenshots.") {
            VStack(alignment: .leading, spacing: 10) {
                infoRow("record.circle", "Mercury recordings", inCaptures ? "The panel is recorded over what you're showing." : "The panel isn't recorded.")
                infoRow("rectangle.inset.filled.and.person.filled", "Screen sharing", inCaptures ? "People on the call see the panel." : "People on the call can't see the panel.")
            }
            infoFoot("Click to switch it \(inCaptures ? "off" : "on"). Hide Mercury to keep your chat private, not to cheat in exams or interviews.")
        }
    }

    /// Pick a friendly face and a nickname for Mercury.
    private var buddyPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make it yours").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text("Nickname").font(.system(size: 11.5)).foregroundStyle(.secondary)
                TextField("Mercury", text: $name).textFieldStyle(.roundedBorder)
                    .onChange(of: name) { if name.count > 24 { name = String(name.prefix(24)) } }
            }
            Text("Picture").font(.system(size: 11.5)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 8), count: 5), spacing: 8) {
                ForEach(Buddy.all, id: \.emoji) { b in
                    Button { avatar = b.emoji } label: {
                        Avatar(emoji: b.emoji, size: 36)
                            .overlay(Circle().stroke(Theme.accent, lineWidth: avatar == b.emoji ? 2.5 : 0).padding(-3))
                    }
                    .buttonStyle(.plain).help(b.name)
                }
            }
        }
        .padding(16)
        .frame(width: 262)
    }

    /// Who you're talking to, like the top of a chat.
    private var chatHeader: some View {
        HStack(spacing: 9) {
            Button { showBuddy.toggle() } label: {
                Avatar(emoji: avatar, size: 28)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil").font(.system(size: 7, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 13, height: 13).background(Circle().fill(.white)).offset(x: 3, y: 3)
                    }
            }
            .buttonStyle(.plain).help("Change \(name.isEmpty ? "Mercury" : name)'s picture and name")
            .panelPopover(isPresented: $showBuddy, arrowEdge: .bottom) { buddyPicker.solidPopover() }
            VStack(alignment: .leading, spacing: 1) {
                Text(name.isEmpty ? "Mercury" : name).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    Circle().fill(model.controllingMac ? Color.yellow : model.thinking ? Color.orange : Color.green).frame(width: 6, height: 6)
                    Text(model.controllingMac ? "using your Mac, hands off the keyboard" : model.thinking ? "typing…" : "here for you").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer()
            headerButton("clock.arrow.circlepath", label: "Chat history", lit: showHistory) { showHistory.toggle() }
                .panelPopover(isPresented: $showHistory, arrowEdge: .bottom) { historyList }
                .onChange(of: model.historyRequest) { showHistory = true }
            headerButton("square.and.pencil", label: "New chat (⌘N)", lit: false) { model.newChat() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.exchanges.isEmpty)
            Button { showLook.toggle() } label: {
                Image(systemName: "paintpalette").font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28, height: 28).background(Circle().fill(.white.opacity(showLook ? 0.18 : 0.08)))
            }
            .buttonStyle(.plain).help("Change the chat's look").accessibilityLabel("Change the chat's look")
            .panelPopover(isPresented: $showLook, arrowEdge: .bottom) { lookPicker.solidPopover() }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            chatHeader
            if model.listening || !model.lines.isEmpty { transcriptStrip }
            if !model.exchanges.isEmpty || model.error != nil {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(model.exchanges) { ex in exchange(ex).id(ex.id) }
                            if let a = model.approval { ChatRow(mine: false, style: style) { approvalCard(a) } }
                            if let e = model.error {
                                Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(16)
                        // The column can never be wider than the panel, and long lines stay readable when it's huge.
                        .frame(width: min(880, panelWidth))
                        .frame(maxWidth: .infinity)
                        // Room left for media once a row's margins, avatar and hover buttons are counted.
                        .environment(\.chatMediaWidth, max(150, min(560, panelWidth - 210)))
                    }
                    .frame(maxHeight: sized ? .infinity : 460)
                    .fixedSize(horizontal: false, vertical: !sized)
                    // Follow new content as it arrives (text, or a picture that finishes loading), unless you
                    // scrolled up yourself to read something; then offer Jump to present instead.
                    .onScrollGeometryChange(for: ScrollSpot.self) { g in
                        ScrollSpot(offset: g.contentOffset.y, content: g.contentSize.height, visible: g.containerSize.height)
                    } action: { old, new in
                        let gap = new.content - (new.offset + new.visible)
                        farFromEnd = gap > 120
                        if gap <= 60 { awayFromEnd = false }
                        else if new.offset < old.offset - 0.5 { awayFromEnd = true }      // you scrolled up, even slowly
                        else if new.content > old.content + 1, !awayFromEnd { proxy.scrollTo("end", anchor: .bottom) }  // it grew
                    }
                    .onChange(of: model.exchanges.last?.answer) { if !awayFromEnd { proxy.scrollTo("end", anchor: .bottom) } }
                    .onChange(of: model.exchanges.count) { proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: jump) {
                        guard let j = jump else { return }
                        awayFromEnd = true
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(j, anchor: .center) }
                        flash = j
                        jump = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if flash == j { flash = nil } }
                    }
                    .overlay(alignment: .bottom) {
                        if awayFromEnd || farFromEnd {
                            Button { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) } } label: {
                                Label("Jump to present", systemImage: "arrow.down").font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 12).frame(height: 28)
                                    .background(Capsule().fill(Color(red: 0.16, green: 0.16, blue: 0.17)))
                                    .overlay(Capsule().stroke(.white.opacity(0.18)))
                                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                            }
                            .buttonStyle(.plain).foregroundStyle(.white).padding(.bottom, 10)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                            .accessibilityLabel("Jump to the latest message")
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: awayFromEnd || farFromEnd)
                }
            }
            if model.exchanges.isEmpty, let old = model.resumable {
                Button { model.open(old) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Continue your last chat").font(.system(size: 12, weight: .semibold))
                            Text(old.title).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                        Spacer()
                        Text(old.updated.formatted(.relative(presentation: .named))).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.top, 12)
            }
            if sized, model.exchanges.isEmpty, model.error == nil { Spacer(minLength: 0) }
            if model.exchanges.isEmpty { chipRow }
            inputBar.frame(maxWidth: 908).frame(maxWidth: .infinity)
        }
        // A short chat grows while a picture is open, so there's room to look at it.
        .frame(minHeight: !sized && viewer.item != nil ? 560 : nil, maxHeight: sized ? .infinity : nil, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(glass))
        .overlay {
            if let item = viewer.item, !viewer.fullScreen {
                PictureViewerOverlay(viewer: viewer, item: item)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: viewer.item?.id)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.16)))
        .overlay { if viewer.item == nil || viewer.fullScreen { PanelGrips(model: model, edges: [.left, .right, .bottom, .bottomLeft, .bottomRight]) } }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 0.5)  // keeps text readable over busy backgrounds
    }

    private var transcriptStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { showTranscript.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").font(.system(size: 11))
                    Text("Live transcript").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Image(systemName: showTranscript ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.6)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            let all = model.lines + (model.live.isEmpty ? [] : [model.live])
            if all.isEmpty {
                Text("Waiting for speech…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
            } else {
                Text((showTranscript ? all.suffix(12) : all.suffix(2)).joined(separator: " "))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                    .lineLimit(showTranscript ? 14 : 2).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }

    /// Takes Mercury's "[react: ❤️]" off the start of a reply: the emoji it reacted to your message with.
    static func splitReactions(_ answer: String) -> (reactions: [String], text: String) {
        let t = answer.drop { $0.isWhitespace }
        guard t.hasPrefix("[") else { return ([], answer) }
        guard let close = t.firstIndex(of: "]") else { return t.count < 40 ? ([], "") : ([], answer) }  // still arriving
        let tag = t[t.index(after: t.startIndex)..<close]
        guard tag.lowercased().hasPrefix("react") else { return ([], answer) }
        let emoji = tag.drop { $0 != ":" }.dropFirst().filter { !$0.isWhitespace && $0 != "," }.map(String.init)
        let rest = String(t[t.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (Array(emoji.filter { $0.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0xFF } }.prefix(3)), rest)
    }

    /// Splits a reply into separate texts at blank lines, keeping code blocks and lists whole.
    static func messages(_ text: String) -> [String] {
        var out: [String] = []
        var cur: [String] = []
        var inCode = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle() }
            if !inCode, line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !cur.isEmpty { out.append(cur.joined(separator: "\n")); cur = [] }
            } else {
                cur.append(line)
            }
        }
        if !cur.isEmpty { out.append(cur.joined(separator: "\n")) }
        // A list of longer points becomes one text per point, like a friend sending them one by one.
        out = out.flatMap { chunk -> [String] in
            let lines = chunk.components(separatedBy: "\n")
            let bullet = #"^\s*([-*•]|\d+[.)])\s+"#
            let isList = lines.count > 1 && lines.allSatisfy { $0.range(of: bullet, options: .regularExpression) != nil }
            guard isList, lines.contains(where: { $0.count > 70 }) else { return [chunk] }
            return lines.map { $0.replacingOccurrences(of: bullet, with: "", options: .regularExpression) }
        }
        // A heading or label like "Here's what I found:" reads better with the message after it.
        var merged: [String] = []
        for m in out {
            if let last = merged.last, last.count < 40, last.hasSuffix(":") { merged[merged.count - 1] = last + "\n" + m } else { merged.append(m) }
        }
        return merged.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func exchange(_ ex: AssistantModel.Exchange) -> some View {
        let live = model.thinking && ex.id == model.exchanges.last?.id
        let (bubbleReacts, answer) = Self.splitReactions(ex.answer)
        return VStack(spacing: 4) {
            ChatRow(mine: true, style: style, reactions: bubbleReacts, onReply: { model.reply(to: ex.question, exchange: ex.id, part: nil) }) {
                VStack(alignment: .trailing, spacing: 3) {
                    if let r = ex.replyTo { ReplyQuote(reply: r, name: r.mine ? "You" : name) { jumpBack(to: r) } }
                    Text(ex.question).textSelection(.enabled)
                    if ex.withScreen {
                        Label("saw your screen", systemImage: "eye").font(.system(size: 10.5)).opacity(0.7)
                    }
                }
            }
            .background(flashBack(rowID(ex.id, nil)))
            .id(rowID(ex.id, nil))
            .contextMenu {
                Button("Reply") { model.reply(to: ex.question, exchange: ex.id, part: nil) }
                Button("Copy this message") { copy(ex.question) }
            }
            // Like texts from a friend: each short message is its own bubble; the avatar sits by the last.
            let parts = Self.messages(answer)
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                ChatRow(mine: false, style: style, showAvatar: i == parts.count - 1 && !(live && ex.activity != nil),
                        reactions: ex.reactions[i] ?? [], onReact: { model.toggleReaction($0, exchange: ex.id, part: i) },
                        onReply: { model.reply(to: part, exchange: ex.id, part: i) }) {
                    RichAnswer(text: part, size: style.textSize)
                }
                .background(flashBack(rowID(ex.id, i)))
                .id(rowID(ex.id, i))
                .contextMenu {
                    Button("Reply") { model.reply(to: part, exchange: ex.id, part: i) }
                    Menu("React") { ForEach(ChatRow<EmptyView>.reactionChoices, id: \.self) { e in Button(e) { model.toggleReaction(e, exchange: ex.id, part: i) } } }
                    Button("Copy this message") { copy(part) }
                    Button("Copy whole reply") { copy(answer) }
                }
            }
            if let act = ex.activity, live {
                ChatRow(mine: false, style: style, compact: true, showAvatar: true) { TypingDots(label: act) }
            }
        }
    }

    private func rowID(_ id: UUID, _ part: Int?) -> String { "\(id.uuidString)-\(part.map(String.init) ?? "you")" }

    private func jumpBack(to r: ChatReply) {
        guard model.exchanges.indices.contains(r.exchange) else { return }
        jump = rowID(model.exchanges[r.exchange].id, r.part)
    }

    private func flashBack(_ id: String) -> some View {
        RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(flash == id ? 0.3 : 0)).padding(-4)
            .animation(.easeOut(duration: 0.3), value: flash)
    }

    /// Claude wants to do something that changes things: you decide.
    private func approvalCard(_ a: ClaudeCodeSession.Approval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // The messenger, back before anything goes out.
            VStack(alignment: .leading, spacing: 2) {
                Label("Back with this. OK to go ahead?", systemImage: "arrow.uturn.backward.circle.fill").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.yellow)
                Text(a.appName).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
            }
            if !a.summary.isEmpty {
                Text(a.summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(8).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.4)))
            }
            HStack(spacing: 8) {
                Button("Deny") { model.decide(allow: false) }.buttonStyle(.plain)
                    .padding(.horizontal, 12).frame(height: 28).background(Capsule().fill(.white.opacity(0.12)))
                Spacer()
                Button("Always allow") { model.decide(allow: true, always: true) }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).help("Don't ask again for \(a.appName)")
                Button("Allow once") { model.decide(allow: true) }.buttonStyle(.plain)
                    .foregroundStyle(.black).padding(.horizontal, 14).frame(height: 28).background(Capsule().fill(.white))
            }
            .font(.system(size: 12.5, weight: .medium))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.yellow.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.yellow.opacity(0.35)))
    }

    /// The very first chat: three errands to send Mercury on, one of which shows it coming back for your OK.
    @AppStorage("firstErrandDone") private var firstErrandDone = false
    private let errands: [(String, String)] = [
        ("Tutor me through my screen", "Look at my screen and tutor me through what's on it, step by step, like a friendly teacher. Use a picture or a short video if it helps me understand."),
        ("Write my first Mercury message", "Help me write a short, warm message to a friend saying I've started using a new assistant called Mercury. Open the right app with it ready to go, and come back for my OK before anything is sent."),
        ("Teach me with pictures", "Teach me how black holes work in a few short messages, with pictures and one short video."),
    ]
    @AppStorage(Settings.showInCapturesKey) private var visibleInCaptures = true

    @ViewBuilder private var chipRow: some View {
        if !firstErrandDone {
            VStack(alignment: .leading, spacing: 8) {
                Text("Where shall I run first?").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                HStack(spacing: 6) {
                    ForEach(errands, id: \.0) { c in
                        Button { firstErrandDone = true; model.ask(c.1) } label: {
                            Text(c.0).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.95))
                                .padding(.horizontal, 10).frame(height: 26)
                                .background(Capsule().fill(Theme.accent.opacity(0.45)))
                        }
                        .buttonStyle(.plain).disabled(model.thinking)
                    }
                }
                Text("Or try a trick").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.8)).padding(.top, 2)
                HStack(spacing: 6) {
                    trick("Record with my face in a bubble") { firstErrandDone = true; (NSApp.delegate as? AppDelegate)?.startPicker() }
                    trick(visibleInCaptures ? "Hide me from screen shares" : "Hidden from screen shares ✓") { visibleInCaptures = false }
                }
                Text("Watch how I come back for your OK before anything goes out.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 14).padding(.top, 12)
        } else {
            everydayChips
        }
    }

    private func trick(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 10).frame(height: 26)
                .background(Capsule().fill(.white.opacity(0.12)))
                .overlay(Capsule().stroke(.white.opacity(0.2)))
        }
        .buttonStyle(.plain)
    }

    private var everydayChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips, id: \.0) { c in
                    Button { model.ask(c.1) } label: {
                        Text(c.0).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(Capsule().fill(.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain).disabled(model.thinking)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 10)
    }

    private func replyStrip(_ r: ChatReply) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(Theme.accent).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(r.mine ? "yourself" : name)").font(.system(size: 11.5, weight: .semibold))
                Text(ReplyQuote.preview(r.text)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button { model.replyingTo = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                    .frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain).help("Cancel reply").accessibilityLabel("Cancel reply")
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            DrillStrip(timer: model.drill)
            if let r = model.replyingTo { replyStrip(r) }
            HStack(spacing: 8) {
            ChatToolsButton(timer: model.drill, onKeysChanged: { (NSApp.delegate as? AppDelegate)?.assistant.refreshKeys() })
            if model.talking {
                Image(systemName: "mic.fill").foregroundStyle(.red).symbolEffect(.pulse)
            }
            ChatTextView(text: $model.input,
                         placeholder: model.talking ? "Listening… say what you want" : (model.approval != nil ? "Say or type yes / no…" : "Ask, or press \(keys.label(.assistVoice)) and say it…"),
                         font: .systemFont(ofSize: 13.5), textColor: .white, placeholderColor: NSColor.white.withAlphaComponent(0.45),
                         maxLines: 6, focusRequest: model.focusRequest, height: $inputHeight, onSubmit: { firstErrandDone = true; model.ask() })
                .frame(height: inputHeight)
            if model.thinking {
                Button(action: model.stopAnswer) {
                    Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 26, height: 26).background(Circle().fill(.white))
                }
                .buttonStyle(.plain).help("Stop").accessibilityLabel("Stop answering")
            } else {
                Button { firstErrandDone = true; model.ask() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 26, height: 26).background(Circle().fill(.white))
                }
                .buttonStyle(.plain).help("Send").accessibilityLabel("Send")
                .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.1)))
        .padding(12)
    }
}
