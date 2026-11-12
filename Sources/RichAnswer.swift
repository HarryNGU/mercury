// Turns an answer's text into blocks the chat can show: prose, code, pictures, molecules and videos.
// Claude writes plain text with paths and links in it, so this is where those become something to look at.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import CryptoKit
import ScreenCaptureKit
import Speech
import SwiftUI
import WebKit

// MARK: - Rich answers

/// Claude's answer as text, code blocks with a copy button, pictures and video links.
struct RichAnswer: View {
    let text: String
    var size: Double = 14

    enum Block: Hashable {
        case prose(String)
        case code(lang: String, body: String)
        case image(URL)
        case video(URL, thumb: URL)
        case localVideo(URL)
        case imageSearch(String)
        case molecule(String)
        /// A message for you to send: shown with Type it in and Send buttons.
        case send(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, b in
                switch b {
                case .prose(let s):
                    Text(Self.inline(s)).font(.system(size: size)).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .tint(Color(red: 0.55, green: 0.75, blue: 1))
                case .code(let lang, let body):
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(lang.isEmpty ? "code" : lang).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                            Spacer()
                            Button { copy(body) } label: { Label("Copy", systemImage: "doc.on.doc").font(.system(size: 11)) }
                                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(body).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
                                .padding(.horizontal, 12).padding(.bottom, 10)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.45)))
                case .image(let url):
                    LinkedPicture(url: url)
                case .imageSearch(let q):
                    ImageSearchStrip(query: q)
                case .molecule(let name):
                    MoleculeCard(name: name)
                case .video(let url, let thumb):
                    VideoBlock(url: url, thumb: thumb)
                case .localVideo(let url):
                    ChatVideo(url: url)
                case .send(let message):
                    SendCard(message: message)
                }
            }
        }
    }

    static func blocks(_ s: String) -> [Block] {
        var out: [Block] = []
        var prose: [String] = []
        var code: [String]? = nil
        var lang = ""
        func flush() {
            let p = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !p.isEmpty { out.append(.prose(p)) }
            prose = []
        }
        for raw in s.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(Self.codeBlock(lang, c)); code = nil }
                else { flush(); lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if let q = Self.capture(#"^\[\[\s*images?\s*:\s*(.+?)\s*\]\]$"#, in: line) {
                flush(); out.append(.imageSearch(q)); continue
            }
            if let q = Self.capture(#"^\[\[\s*molecule\s*:\s*(.+?)\s*\]\]$"#, in: line) {
                flush(); out.append(.molecule(q)); continue
            }
            if let v = LocalVideo.line(line) {
                flush(); out.append(.localVideo(v)); continue
            }
            if let u = Self.pictureLine(line) {
                flush(); out.append(.image(u)); continue
            }
            prose.append(line.hasPrefix("#") ? "**" + line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) + "**" : raw)
            // A YouTube link gets a playable thumbnail under its line.
            if let id = Self.capture(#"(?:youtube\.com/watch\?v=|youtu\.be/)([A-Za-z0-9_-]{11})"#, in: raw),
               let thumb = URL(string: "https://img.youtube.com/vi/\(id)/hqdefault.jpg"),
               let url = URL(string: "https://www.youtube.com/watch?v=\(id)") {
                flush(); out.append(.video(url, thumb: thumb))
            }
            // A video file named in a sentence gets a player under that sentence.
            if let v = LocalVideo.mention(in: raw), !out.contains(.localVideo(v)) {
                flush(); out.append(.localVideo(v))
            }
        }
        if let c = code { out.append(Self.codeBlock(lang, c)) }
        flush()
        return out
    }

    /// A fenced block: a ```send block is a message to type for you, anything else is code.
    private static func codeBlock(_ lang: String, _ lines: [String]) -> Block {
        let body = lines.joined(separator: "\n")
        if lang.lowercased() == "send" { return .send(body.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return .code(lang: lang, body: body)
    }

    /// A line that is only a picture: a markdown image, [[picture: …]], or a bare picture address or file path.
    /// Pictures can come from the web or from a file on this Mac (for example one Claude just made).
    static func pictureLine(_ line: String) -> URL? {
        let target = capture(#"^!\[[^\]]*\]\(\s*<?(.+?)>?\s*\)$"#, in: line)
            ?? capture(#"^\[\[\s*(?:picture|image|file)\s*:\s*(.+?)\s*\]\]$"#, in: line)
            ?? (LocalPicture.isPicture(line.trimmingCharacters(in: CharacterSet(charactersIn: "`<>"))) ? line.trimmingCharacters(in: CharacterSet(charactersIn: "`<>")) : nil)
        guard let t = target?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return URL(string: t) }
        return LocalPicture.url(t)
    }

    /// The first capture group of `pattern` in `s`.
    private static func capture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
