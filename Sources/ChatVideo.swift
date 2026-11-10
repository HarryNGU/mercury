// Videos that play inside the Mercury chat, and the full screen view shared by videos and pictures.
// A video file Mercury made, or a link to one, shows as a poster in the chat. Click to play it there,
// or send it full screen. Files stay where they are on your Mac and are never uploaded.

import AVFoundation
import AVKit
import SwiftUI

/// Video files Mercury can play itself.
enum LocalVideo {
    static let kinds: Set<String> = ["mp4", "mov", "m4v"]

    private static func hasKind(_ s: String) -> Bool { kinds.contains((s as NSString).pathExtension.lowercased()) }

    /// A file on this Mac or a web address, if `s` is a video.
    static func url(_ text: String) -> URL? {
        let s = text.trimmingCharacters(in: CharacterSet(charactersIn: " `<>\"'"))
        if s.hasPrefix("http://") || s.hasPrefix("https://") {
            guard let u = URL(string: s), kinds.contains(u.pathExtension.lowercased()) else { return nil }
            return u
        }
        if s.hasPrefix("file://") { return URL(string: s).flatMap { hasKind($0.path) ? $0 : nil } }
        guard s.hasPrefix("/") || s.hasPrefix("~/"), hasKind(s) else { return nil }
        return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
    }

    private static func first(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// A line that is only a video: a markdown link, [[video: …]], or a bare address or path.
    static func line(_ line: String) -> URL? {
        if let t = first(#"^!?\[[^\]]*\]\(\s*<?(.+?)>?\s*\)$"#, in: line) ?? first(#"^\[\[\s*(?:video|file)\s*:\s*(.+?)\s*\]\]$"#, in: line) { return url(t) }
        return url(line)
    }

    /// A video mentioned in a sentence, such as "Saved it to `/Users/me/Desktop/clip.mp4`".
    static func mention(in s: String) -> URL? {
        let ends = "(?:mp4|mov|m4v)"
        let start = "(?:~/|/|file://|https?://)"
        // Backticks and angle brackets can hold brackets and spaces, as many file names do.
        let quoted = first("`(\(start)[^`]*\\.\(ends)(?:\\?[^`]*)?)`", in: s) ?? first("<(\(start)[^<>]*\\.\(ends)(?:\\?[^<>]*)?)>", in: s)
            ?? first("\\((\(start)[^()]*\\.\(ends)(?:\\?[^()]*)?)\\)", in: s)
        let bare = first("(?:^|\\s)((?:~/|/|file://|https?://)[^\\s`<>()\"']+\\.\(ends))(?=$|[\\s.,;:!?])", in: s)
        return (quoted ?? bare).flatMap(url)
    }
}

private struct ChatMediaWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 560 }

extension EnvironmentValues {
    /// How wide a picture or video can be in the chat at the panel's current size.
    var chatMediaWidth: CGFloat {
        get { self[ChatMediaWidthKey.self] }
        set { self[ChatMediaWidthKey.self] = newValue }
    }
}

/// Only one video plays at a time, and hiding Mercury stops it.
@MainActor
enum ChatVideos {
    private static weak var playing: AVPlayer?
    static func play(_ p: AVPlayer) {
        if playing !== p { playing?.pause() }
        playing = p
        p.play()
    }
    static func pause() { playing?.pause() }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    var controls: AVPlayerViewControlsStyle = .inline
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = controls
        v.showsFullScreenToggleButton = false
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}

/// A video in the chat: a poster until you click it, then it plays right there.
struct ChatVideo: View {
    let url: URL
    @Environment(\.chatMediaWidth) private var maxWidth
    @State private var player: AVPlayer?
    @State private var poster: NSImage?
    @State private var aspect: CGFloat = 16.0 / 9
    @State private var failed = false
    @State private var hover = false

    private var size: CGSize {
        var w = maxWidth, h = w / aspect
        if h > 400 { h = 400; w = h * aspect }
        return CGSize(width: w, height: h)
    }

    private func start() {
        let p = player ?? AVPlayer(url: url)
        player = p
        ChatVideos.play(p)
    }

    var body: some View {
        Group {
            if failed {
                Label(url.isFileURL ? "This video isn't on your Mac any more." : "Couldn't load this video.", systemImage: "film").font(.system(size: 12)).opacity(0.65)
            } else {
                ZStack(alignment: .topTrailing) {
                    if let player {
                        PlayerSurface(player: player)
                    } else {
                        Button(action: start) {
                            ZStack {
                                Color.black
                                if let poster { Image(nsImage: poster).resizable().scaledToFit() }
                                else { ProgressView().controlSize(.small) }
                                Image(systemName: "play.circle.fill").font(.system(size: 46)).foregroundStyle(.white.opacity(0.92)).shadow(radius: 4)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("Play here")
                    }
                    Button {
                        start()
                        if let p = player { MediaFullScreen.shared.show(AnyView(FullVideo(player: p))) }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 26, height: 26).background(Circle().fill(.black.opacity(0.6)))
                    }
                    .buttonStyle(.plain).help("Full screen").accessibilityLabel("Full screen").padding(8)
                    .opacity(hover || player == nil ? 1 : 0)
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onHover { hover = $0 }
                .contextMenu {
                    Button(url.isFileURL ? "Open in QuickTime Player" : "Open in Browser") { NSWorkspace.shared.open(url) }
                    if url.isFileURL { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                }
            }
        }
        .onDisappear { player?.pause() }
        .task(id: url) { await loadPoster() }
    }

    /// Mercury often mentions a video just before it has finished saving it, so this keeps trying for a while.
    private func loadPoster() async {
        for _ in 0..<(url.isFileURL ? 90 : 1) {
            if Task.isCancelled { return }
            if await tryPoster() { return }
            try? await Task.sleep(for: .seconds(1))
        }
        failed = true
    }

    private func tryPoster() async -> Bool {
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) { return false }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) else { return false }
        let turned = natural.applying(t)
        if abs(turned.height) > 0 { aspect = max(0.4, min(3, abs(turned.width) / abs(turned.height))) }
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 1280, height: 1280)
        if let frame = try? await g.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image {
            poster = NSImage(cgImage: frame, size: .zero)
        }
        return true
    }
}

/// The player filling the whole screen. It's the same player, so the video carries on where it was.
struct FullVideo: View {
    let player: AVPlayer
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            PlayerSurface(player: player, controls: .floating)
            FullScreenClose()
        }
    }
}

struct FullScreenClose: View {
    var body: some View {
        Button { MediaFullScreen.shared.close() } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(Circle().fill(Color(white: 0.2)))
                .overlay(Circle().stroke(.white.opacity(0.2)))
        }
        .buttonStyle(.plain).help("Exit full screen").accessibilityLabel("Exit full screen").padding(20)
    }
}

final class FullScreenPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// One screen filling window on top of everything. It follows Mercury's Visibility switch, because
/// macOS hides it from recordings and screen shares exactly when it hides the panel.
@MainActor
final class MediaFullScreen {
    static let shared = MediaFullScreen()
    private var window: FullScreenPanel?
    private var onExit: (() -> Void)?
    private var panelWasKey = false

    var isOpen: Bool { window != nil }

    func show(_ content: AnyView, onExit: (() -> Void)? = nil) {
        close()
        let parent = (NSApp.delegate as? AppDelegate)?.assistant.panelWindow
        panelWasKey = parent?.isKeyWindow == true
        let frame = (parent?.screen ?? NSScreen.underMouse).frame
        let w = FullScreenPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.alwaysDark()
        w.isOpaque = true
        w.backgroundColor = .black
        w.level = .statusBar
        w.hidesOnDeactivate = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.sharingType = parent?.sharingType ?? .readOnly
        w.isReleasedWhenClosed = false
        w.onEscape = { [weak self] in self?.close() }
        w.contentView = NSHostingView(rootView: content.environment(\.colorScheme, .dark))
        w.setFrame(frame, display: true)
        parent?.addChildWindow(w, ordered: .above)
        w.orderFrontRegardless()
        w.makeKey()
        window = w
        self.onExit = onExit
    }

    func close() {
        guard let w = window else { return }
        window = nil
        w.parent?.removeChildWindow(w)
        w.orderOut(nil)
        let exit = onExit
        onExit = nil
        exit?()
        // The keyboard goes back only if the chat had it before.
        if panelWasKey { (NSApp.delegate as? AppDelegate)?.assistant.panelWindow?.makeKey() }
    }
}
