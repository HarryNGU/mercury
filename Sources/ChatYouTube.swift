// YouTube videos in the chat: a thumbnail until you click it, then the video plays right there.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import CryptoKit
import ScreenCaptureKit
import Speech
import SwiftUI
import WebKit

// MARK: - Videos that play in the panel

/// A YouTube video: a thumbnail until you click it, then it plays right here.
struct VideoBlock: View {
    let url: URL
    let thumb: URL
    @State private var playing = false
    @State private var img: NSImage?
    @Environment(\.chatMediaWidth) private var mediaWidth

    private var videoID: String? { URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if playing, let id = videoID {
                YouTubePlayer(id: id).frame(width: mediaWidth, height: mediaWidth * 9 / 16).clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Button { playing = true } label: {
                    ZStack {
                        if let img { Image(nsImage: img).resizable().scaledToFill() } else { Color.white.opacity(0.06) }
                        Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.92)).shadow(radius: 4)
                    }
                    .frame(width: 320, height: 180).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).help("Play here")
            }
            Button { NSWorkspace.shared.open(url) } label: {
                Label("Open on YouTube", systemImage: "arrow.up.right").font(.system(size: 11))
            }
            .buttonStyle(.plain).opacity(0.6)
            if let id = videoID {
                Button {
                    // YouTube's player can't be moved, so this one starts fresh and the small one stops.
                    playing = false
                    MediaFullScreen.shared.show(AnyView(ZStack(alignment: .topTrailing) { YouTubePlayer(id: id); FullScreenClose() }))
                } label: {
                    Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 11))
                }
                .buttonStyle(.plain).opacity(0.6)
            }
        }
        .task(id: thumb) { img = await PictureFetch.image(thumb) }
    }
}

/// YouTube's own embedded player. It needs a real web origin, so the page is given one.
struct YouTubePlayer: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.setValue(false, forKey: "drawsBackground")
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{border:0;width:100%;height:100%}</style></head>
        <body><iframe src="https://www.youtube-nocookie.com/embed/\(id)?autoplay=1&playsinline=1&rel=0"
        allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen
        referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """
        v.loadHTMLString(html, baseURL: URL(string: "https://bubble.localhost/"))
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
