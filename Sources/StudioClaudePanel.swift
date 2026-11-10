// The editor's Claude panel: a chat that edits the reel for you, with each change shown so you can undo it.

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Claude

struct ClaudePanel: View {
    @ObservedObject var ed: ReelEditor
    let url: URL
    @State private var message = ""
    @State private var messageHeight: CGFloat = 17
    @AppStorage("editorChatMode") private var chatMode = "quick"
    @State private var apiKey = ""
    @State private var hasKey = Keychain.hasKey

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "Claude", subtitle: "Say what you want and Claude edits it for you.", icon: "sparkles")
            SwiftUI.Picker("", selection: $chatMode) {
                Text("Quick edit").tag("quick")
                Text("Full job").tag("job")
            }
            .pickerStyle(.segmented).labelsHidden()
            .help("Quick edit changes this edit: cuts, speed, captions, text and zooms. Full job runs a whole recipe with your own scripts and tools.")
            VStack(spacing: 0) {
                if chatMode == "job" { ReelJobPanel(recording: url) } else { quickChat }
            }
            .studioCard(16)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
        .onAppear { hasKey = Keychain.hasKey }
    }

    @ViewBuilder private var quickChat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if ed.chat.isEmpty {
                        Text("Try “make it under 60 seconds”, “cut the bit where I restart”, “add a title that says Day 24”, or “zoom in on the code when I mention it”.")
                            .font(.system(size: 12.5)).foregroundStyle(SC.dim)
                    }
                    ForEach(ed.chat) { line in
                        Text(line.text).font(.system(size: 13)).textSelection(.enabled)
                            .padding(.horizontal, 11).padding(.vertical, 8)
                            .foregroundStyle(SC.text)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(line.fromUser ? AnyShapeStyle(SC.gradient) : AnyShapeStyle(SC.hover)))
                            .frame(maxWidth: .infinity, alignment: line.fromUser ? .trailing : .leading)
                            .id(line.id)
                    }
                    if ed.thinking {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Editing…").font(.system(size: 12)).foregroundStyle(SC.dim) }
                            .id("thinking")
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: ed.chat.count) { if let last = ed.chat.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
        }
        Rectangle().fill(SC.line).frame(height: 1)
        if hasKey || ClaudeCodeSession.binary != nil {
            HStack(spacing: 8) {
                ChatTextView(text: $message, placeholder: "Describe a change…", maxLines: 5, height: $messageHeight, onSubmit: send)
                    .frame(height: messageHeight)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(Circle().fill(SC.gradient)).glow(true, radius: 6)
                }
                .buttonStyle(.plain)
                .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty || ed.thinking || ed.analysis == nil)
            }
            .padding(12)
            if !ed.chat.isEmpty {
                Button("Clear chat") { ed.clearChat() }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(SC.dim)
                    .padding(.bottom, 8)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("The chat uses Claude. With Claude Code installed and signed in, it uses your Claude plan and needs nothing else. Otherwise add your own Anthropic API key (from console.anthropic.com); it's kept in your Mac's Keychain. Only the transcript and settings are sent, never the video.")
                    .font(.system(size: 12)).foregroundStyle(SC.dim).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    SecureField("sk-ant-…", text: $apiKey).textFieldStyle(.roundedBorder)
                    PrimaryButton(title: "Save") {
                        Keychain.setAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        apiKey = ""
                        hasKey = Keychain.hasKey
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
        }
    }

    private func send() {
        let t = message
        message = ""
        ed.send(t)
    }
}
