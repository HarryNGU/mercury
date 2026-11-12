import AppKit
import SwiftUI

// A message the AI wrote for you to send (a ```send block). The free AI and your own key can't act on the Mac,
// but Mercury can type for you: click the message box in your app, then press Type it in or Send. Pressing the
// button is your OK; nothing is typed or sent before that.

enum TypeItIn {
    enum Outcome: Equatable {
        case typed(String?)      // into this app
        case sent(String?)
        case needsAccess         // Accessibility not allowed yet
        case noBox(String?)      // nothing editable focused; the text is on the clipboard
    }

    /// Hands the keyboard back to the app in front, then types `text` into its focused box, pressing Return
    /// after when `send` is on.
    @MainActor
    static func deliver(_ text: String, send: Bool) async -> Outcome {
        guard Inserter.trusted else { Inserter.requestTrust(); return .needsAccess }
        for case let p as AssistantPanel in NSApp.windows { p.handBackKeyboard() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let box = Inserter.focusedTextField()
        guard box.editable else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            log("send card: no box in \(box.app ?? "?")")
            return .noBox(box.app)
        }
        Inserter.paste(text)
        guard send else { log("send card: typed into \(box.app ?? "?")"); return .typed(box.app) }
        try? await Task.sleep(nanoseconds: 250_000_000)
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)   // Return
        CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
        log("send card: sent in \(box.app ?? "?")")
        return .sent(box.app)
    }

    /// What to tell you afterwards.
    static func note(_ o: Outcome) -> String {
        switch o {
        case .typed(let app): return "Typed into \(app ?? "your app"). Check it, then press Return to send."
        case .sent(let app): return "Sent in \(app ?? "your app")."
        case .needsAccess: return "Allow Mercury in System Settings, Privacy and Security, Accessibility, then press again."
        case .noBox(let app): return "Click the message box in \(app ?? "your app") first, then press again. It's also copied, so ⌘V works."
        }
    }
}

struct SendCard: View {
    let message: String
    @State private var note: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Message to send", systemImage: "paperplane").font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text(message).font(.system(size: 14)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack(spacing: 8) {
                button("Type it in", icon: "keyboard", primary: false) { await run(send: false) }
                button("Send", icon: "paperplane.fill", primary: true) { await run(send: true) }
                Spacer(minLength: 0)
            }
            Text(note ?? "Click the message box in your app first.")
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(note == nil ? 0.45 : 0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.11)))   // solid, so it reads on any bubble colour
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.1)))
    }

    private func run(send: Bool) async {
        busy = true
        let o = await TypeItIn.deliver(message, send: send)
        note = TypeItIn.note(o)
        busy = false
    }

    private func button(_ title: String, icon: String, primary: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Label(title, systemImage: icon).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(primary ? Theme.onBrand : .white)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(primary ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.white.opacity(0.12))))
        }
        .buttonStyle(.plain).disabled(busy).opacity(busy ? 0.5 : 1)
    }
}
