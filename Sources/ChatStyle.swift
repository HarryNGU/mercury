// How the chat looks: bubble colours and widths, message rows, quoted replies, avatars and the typing dots.
// Shared by every message so the whole chat stays consistent.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import CryptoKit
import ScreenCaptureKit
import Speech
import SwiftUI
import WebKit

// MARK: - Chat look

/// Colours and size for the Ask Mercury chat, chosen in Assistant settings.
struct ChatStyle {
    let mine: Color, mineText: Color, theirs: Color, theirsText: Color
    let textSize: Double

    static let defaultMine = "0A84FF"
    static let defaultTheirs = "glass"
    /// Your bubble colours.
    static let mineChoices: [(String, String)] = [("0A84FF", "Blue"), ("7C5CFF", "Violet"), ("30B85A", "Green"), ("FF375F", "Pink"), ("FF8A00", "Orange"), ("3A3A3C", "Graphite")]
    /// Their bubble styles.
    static let theirsChoices: [(String, String)] = [("glass", "Glass"), ("2C2C2E", "Graphite"), ("1C1C1E", "Ink"), ("E9E9EB", "Light")]

    static func current(mine: String, theirs: String, size: Double) -> ChatStyle {
        let m = color(mine) ?? Color(red: 0.04, green: 0.52, blue: 1)
        let t: Color = theirs == "glass" ? .white.opacity(0.14) : (color(theirs) ?? .white.opacity(0.14))
        let light = theirs == "E9E9EB"
        return ChatStyle(mine: m, mineText: .white, theirs: t, theirsText: light ? .black : .white, textSize: size)
    }

    static func color(_ hex: String) -> Color? {
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// One message: yours on the right, theirs on the left with their avatar, like a DM.
struct ChatRow<Content: View>: View {
    let mine: Bool
    let style: ChatStyle
    var compact = false
    var showAvatar = true
    /// Emoji reactions shown on the corner of the bubble, like a DM.
    var reactions: [String] = []
    /// Set to let you react to this message (hover for the button, or right-click).
    var onReact: ((String) -> Void)? = nil
    /// Set to let you reply to this message (hover for the button, or right-click).
    var onReply: (() -> Void)? = nil
    @ViewBuilder let content: Content
    @AppStorage("chatAvatar") private var avatar = ""
    @State private var hover = false
    @State private var picking = false

    static var reactionChoices: [String] { ["❤️", "😂", "👍", "😮", "😢", "🙏", "🔥", "🎉"] }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 70); replyButton }
            else if showAvatar { Avatar(emoji: avatar, size: 24) }
            else { Color.clear.frame(width: 24, height: 1) }
            bubble
            if !mine { replyButton }
            if let onReact, !mine {
                Button { picking.toggle() } label: {
                    Image(systemName: "face.smiling").font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                        .frame(width: 24, height: 24).background(Circle().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain).help("React").accessibilityLabel("React to this message")
                .opacity(hover || picking ? 1 : 0)
                .panelPopover(isPresented: $picking, arrowEdge: .top) {
                    HStack(spacing: 4) {
                        ForEach(Self.reactionChoices, id: \.self) { e in
                            Button { onReact(e); picking = false } label: {
                                Text(e).font(.system(size: 20)).frame(width: 32, height: 32)
                                    .background(Circle().fill(reactions.contains(e) ? Color.accentColor.opacity(0.3) : .clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }
            if !mine { Spacer(minLength: 40) }
        }
        .padding(.bottom, reactions.isEmpty ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .onHover { hover = $0 }
        .animation(.spring(duration: 0.3, bounce: 0.4), value: reactions)
    }

    @ViewBuilder private var replyButton: some View {
        if let onReply {
            Button(action: onReply) {
                Image(systemName: "arrowshape.turn.up.left").font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                    .frame(width: 24, height: 24).background(Circle().fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain).help("Reply").accessibilityLabel("Reply to this message")
            .opacity(hover ? 1 : 0)
        }
    }

    private var bubble: some View {
        content
                .font(.system(size: style.textSize))
                .foregroundStyle(mine ? style.mineText : style.theirsText)
                .padding(.horizontal, compact ? 12 : 13).padding(.vertical, compact ? 8 : 9)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: mine ? 18 : 5,
                                           bottomTrailingRadius: mine ? 5 : 18, topTrailingRadius: 18, style: .continuous)
                        .fill(mine ? style.mine : style.theirs)
                )
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: mine ? .bottomLeading : .bottomTrailing) {
                    if !reactions.isEmpty {
                        HStack(spacing: 1) { ForEach(reactions, id: \.self) { Text($0).font(.system(size: 12.5)) } }
                            .padding(.horizontal, 6).frame(height: 22)
                            .background(Capsule().fill(Color(white: 0.17)))
                            .overlay(Capsule().stroke(.white.opacity(0.18)))
                            .offset(x: mine ? -8 : 8, y: 14)
                            .onTapGesture { if let onReact, let last = reactions.last { onReact(last) } }
                            .transition(.scale.combined(with: .opacity))
                    }
                }
    }
}

/// The small quote at the top of a bubble that replies to an earlier message. Tap it to go back there.
struct ReplyQuote: View {
    let reply: ChatReply
    let name: String
    let onTap: () -> Void

    /// One tidy line for a message that may hold markdown, code or pictures.
    static func preview(_ text: String) -> String {
        var words: [String] = []
        var other: String?
        for b in RichAnswer.blocks(text) {
            switch b {
            case .prose(let s): words.append(s)
            case .code: other = other ?? "Code"
            case .video, .localVideo: other = other ?? "Video"
            default: other = other ?? "Picture"
            }
        }
        let plain = words.joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"[*_`#]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return plain.isEmpty ? (other ?? "Message") : plain
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                Capsule().fill(.white.opacity(0.75)).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 11, weight: .semibold))
                    Text(Self.preview(reply.text)).font(.system(size: 12)).opacity(0.8).lineLimit(2).multilineTextAlignment(.leading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: 420, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(.black.opacity(0.2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Go to this message")
    }
}

/// Friendly faces you can give Mercury, each on a soft colour.
enum Buddy {
    struct Face { let emoji: String; let name: String; let hex: UInt32 }
    static let all: [Face] = [
        Face(emoji: "", name: "Mercury", hex: 0),
        Face(emoji: "🦖", name: "Dino", hex: 0xC8F2C2), Face(emoji: "🐼", name: "Panda", hex: 0xE8E8EE),
        Face(emoji: "🦊", name: "Fox", hex: 0xFFD9B8), Face(emoji: "🐨", name: "Koala", hex: 0xD9DEE8),
        Face(emoji: "🐧", name: "Penguin", hex: 0xCFE6FF), Face(emoji: "🦦", name: "Otter", hex: 0xEADCC8),
        Face(emoji: "🐱", name: "Cat", hex: 0xFFE8B0), Face(emoji: "🐶", name: "Pup", hex: 0xF5DEC8),
        Face(emoji: "🐰", name: "Bunny", hex: 0xFFDCE8), Face(emoji: "🐸", name: "Frog", hex: 0xD6F5B8),
        Face(emoji: "🐙", name: "Octopus", hex: 0xFFD0D6), Face(emoji: "🦉", name: "Owl", hex: 0xE6D8F5),
        Face(emoji: "🐳", name: "Whale", hex: 0xC6E9FF), Face(emoji: "🦄", name: "Unicorn", hex: 0xF0DAFF),
    ]
    static func color(for emoji: String) -> Color {
        guard let f = all.first(where: { $0.emoji == emoji }), f.hex != 0 else { return Color.white.opacity(0.16) }
        return Color(red: Double(f.hex >> 16 & 0xFF) / 255, green: Double(f.hex >> 8 & 0xFF) / 255, blue: Double(f.hex & 0xFF) / 255)
    }
}

/// Mercury's planet logo, or a friendly face if you chose one.
struct Avatar: View {
    let emoji: String
    let size: CGFloat
    var body: some View {
        let e = emoji.trimmingCharacters(in: .whitespaces)
        if e.isEmpty || e == "🫧", let planet = Brand.planet {
            Image(nsImage: planet).resizable().interpolation(.high)
                .frame(width: size, height: size)
                .shadow(color: Color(red: 0.31, green: 0.49, blue: 1).opacity(0.55), radius: size * 0.18)
        } else if e.isEmpty || e == "🫧" {
            ZStack {
                Circle().fill(Theme.accent)
                Circle().fill(.white).frame(width: size * 0.36, height: size * 0.36)
            }
            .frame(width: size, height: size)
        } else {
            Text(String(e.prefix(2)))
                .font(.system(size: size * 0.6))
                .frame(width: size, height: size)
                .background(Circle().fill(Buddy.color(for: e)))
        }
    }
}

/// "…" while it's working, with what it's doing underneath.
struct TypingDots: View {
    let label: String
    @State private var phase = 0
    private let tick = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().frame(width: 6, height: 6).opacity(phase == i ? 0.95 : 0.35)
                }
            }
            if !label.isEmpty && label != "Thinking…" {
                Text(label).font(.system(size: 11)).opacity(0.6)
            }
        }
        .onReceive(tick) { _ in phase = (phase + 1) % 3 }
    }
}
