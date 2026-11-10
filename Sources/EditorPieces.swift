// Small views the reel editor page is built from: buttons, the player, the add menu, the stage overlay
// for dragging text and zooms, the export sheet and the scrubber, plus the clock format they share.

import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

func clock(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00.0" }
    let tenths = Int((s * 10).rounded(.down))
    let m = tenths / 600, sec = tenths / 10 % 60, d = tenths % 10
    return m >= 60 ? String(format: "%d:%02d:%02d.%d", m / 60, m % 60, sec, d) : String(format: "%d:%02d.%d", m, sec, d)
}

// MARK: - Pieces of the page

struct IconButton: View {
    let icon: String
    var help = ""
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold))
                .foregroundStyle(enabled ? (hover ? SC.text : SC.dim) : SC.faint.opacity(0.5))
                .frame(width: 30, height: 30)
                .background(Circle().fill(hover && enabled ? SC.wash(0.09) : .clear))
        }
        .buttonStyle(Springy(hoverScale: 1.08)).help(help).onHover { hover = $0 }
    }
}

struct RailButton: View {
    let tool: StudioTool
    let selected: Bool
    let pill: Namespace.ID
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tool.icon).font(.system(size: 15, weight: selected ? .semibold : .regular)).frame(height: 18)
                    .foregroundStyle(selected ? AnyShapeStyle(SC.gradient) : AnyShapeStyle(hover ? SC.text : SC.dim))
                    .symbolEffect(.bounce, value: selected)
                Text(tool.label).font(.system(size: 9.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? SC.text : (hover ? SC.text : SC.dim))
            }
            .frame(width: 62, height: 48)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SC.wash(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(SC.edge))
                        .overlay(alignment: .leading) {
                            Capsule().fill(SC.gradient).frame(width: 3, height: 20).offset(x: -6).shadow(color: SC.accent, radius: 4)
                        }
                        .matchedGeometryEffect(id: "rail", in: pill)
                } else if hover {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SC.wash(0.04))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Springy(hoverScale: 1.04)).onHover { hover = $0 }
    }
}

/// A shape choice in the segmented control above the preview.
struct ShapeChip: View {
    let size: ReelSize
    let selected: Bool
    let pill: Namespace.ID
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: size.icon).font(.system(size: 11, weight: .semibold))
                Text(size.ratio).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(selected ? .white : SC.dim)
            .padding(.horizontal, 12).frame(height: 28)
            .background {
                if selected {
                    Capsule().fill(SC.gradient).shadow(color: SC.accent.opacity(0.5), radius: 8).matchedGeometryEffect(id: "shape", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(Springy()).help(size.use)
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}

/// Everything you can put in the video, in one place.
struct AddMenu: View {
    @ObservedObject var ed: ReelEditor
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Add to your video").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(SC.text)
                Text("Or drop files anywhere on the editor.").font(.system(size: 11.5)).foregroundStyle(SC.dim)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                AddTile(title: "Text", icon: "textformat", tint: "8B5CF6", subtitle: "Titles, labels") { done(); ed.addText(ReelEditor.textPresets[0].item) }
                AddTile(title: "Zoom", icon: "plus.magnifyingglass", tint: "14B8A6", subtitle: "Push in") { done(); ed.addZoom() }
                AddTile(title: "Video", icon: "film", tint: "3B82F6", subtitle: "On top, B-roll") { done(); openPanel([.movie]) { ed.addVideo($0) } }
                AddTile(title: "Picture", icon: "photo", tint: "F59E0B", subtitle: "Logo, photo") { done(); openPanel([.image]) { ed.addImage($0) } }
                AddTile(title: "Music", icon: "music.note", tint: "EC4899", subtitle: "Dips for voice") { done(); openPanel([.audio]) { ed.setMusic($0) } }
                AddTile(title: "Subtitles", icon: "captions.bubble", tint: "22C55E", subtitle: "Styles") { done(); ed.change { $0.captions = true }; ed.tool = .captions }
                AddTile(title: "Blur", icon: "eye.slash", tint: "EF4444", subtitle: "Hide a name") { done(); ed.addBlur() }
                AddTile(title: "Filter", icon: "camera.filters", tint: "06B6D4", subtitle: "Film looks") { done(); ed.tool = .colour }
                AddTile(title: "Progress bar", icon: "chart.bar.fill", tint: "A855F7", subtitle: "Keeps them watching") { done(); ed.change { $0.progressBar = $0.progressBar ?? ProgressBar() }; ed.tool = .media }
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(SC.panel)
        .environment(\.colorScheme, .dark)
        .presentationBackground(SC.panel)
    }
}

/// Handles on the preview: click a text, picture or video to pick it, drag it to move it.
struct StageOverlay: View {
    @ObservedObject var ed: ReelEditor
    let viewSize: CGSize
    @State private var dragStart: CGPoint?

    var body: some View {
        let s = ed.timeline.source(at: ed.time)
        let k = viewSize.width / max(1, ed.renderSize.width)
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture { ed.selection = .none }
            ForEach(ed.plan.videos.filter { s >= $0.start && s < $0.end && !$0.full }) { item in
                let w = viewSize.width * item.width
                let h = w / max(0.1, item.aspect)
                handle(selected: ed.selection == .video(item.id), size: CGSize(width: w, height: h))
                    .position(x: viewSize.width * item.x, y: viewSize.height * item.y)
                    .onTapGesture { ed.select(.video(item.id)) }
                    .gesture(move(.video(item.id), x: item.x, y: item.y))
            }
            ForEach(ed.plan.images.filter { s >= $0.start && s < $0.end }) { item in
                let w = viewSize.width * item.width
                let h = w * aspect(of: item)
                handle(selected: ed.selection == .image(item.id), size: CGSize(width: w, height: h))
                    .position(x: viewSize.width * item.x, y: viewSize.height * item.y)
                    .onTapGesture { ed.select(.image(item.id)) }
                    .gesture(move(.image(item.id), x: item.x, y: item.y))
            }
            ForEach(ed.plan.texts.filter { s >= $0.start - 0.001 && s < $0.end }) { item in
                let box = StudioType.box(item, frame: ed.renderSize)
                handle(selected: ed.selection == .text(item.id), size: CGSize(width: box.width * k, height: box.height * k))
                    .position(x: viewSize.width * item.x, y: viewSize.height * item.y)
                    .onTapGesture { ed.select(.text(item.id)) }
                    .gesture(move(.text(item.id), x: item.x, y: item.y))
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
    }

    private static var aspects: [String: CGFloat] = [:]
    private func aspect(of item: ImageItem) -> CGFloat {
        if let a = Self.aspects[item.file] { return a }
        guard let img = NSImage(contentsOfFile: item.file), img.size.width > 0 else { return 1 }
        let a = img.size.height / img.size.width
        Self.aspects[item.file] = a
        return a
    }

    private func handle(selected: Bool, size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.001))
            .frame(width: max(24, size.width), height: max(18, size.height))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(SC.gradient, lineWidth: 2).opacity(selected ? 1 : 0))
            .shadow(color: selected ? SC.accent.opacity(0.6) : .clear, radius: 6)
            .overlay(alignment: .topLeading) { if selected { dot } }
            .overlay(alignment: .topTrailing) { if selected { dot } }
            .overlay(alignment: .bottomLeading) { if selected { dot } }
            .overlay(alignment: .bottomTrailing) { if selected { dot } }
            .animation(SC.spring, value: selected)
            .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
    }

    private var dot: some View {
        Circle().fill(Color.white).frame(width: 8, height: 8).overlay(Circle().stroke(SC.accent, lineWidth: 2)).padding(-4)
    }

    private func move(_ sel: Selection, x: Double, y: Double) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if dragStart == nil { dragStart = CGPoint(x: x, y: y); ed.beginChange(); ed.select(sel) }
                guard let o = dragStart else { return }
                var nx = o.x + v.translation.width / viewSize.width, ny = o.y + v.translation.height / viewSize.height
                // Snap to the middle.
                if abs(nx - 0.5) < 0.012 { nx = 0.5 }
                if abs(ny - 0.5) < 0.012 { ny = 0.5 }
                nx = min(1, max(0, nx)); ny = min(1, max(0, ny))
                switch sel {
                case .text(let id): if let i = ed.plan.texts.firstIndex(where: { $0.id == id }) { ed.plan.texts[i].x = nx; ed.plan.texts[i].y = ny }
                case .image(let id): if let i = ed.plan.images.firstIndex(where: { $0.id == id }) { ed.plan.images[i].x = nx; ed.plan.images[i].y = ny }
                case .video(let id): if let i = ed.plan.videos.firstIndex(where: { $0.id == id }) { ed.plan.videos[i].x = nx; ed.plan.videos[i].y = ny }
                default: break
                }
            }
            .onEnded { _ in dragStart = nil }
    }
}

/// Where and how to save.
struct ExportSheet: View {
    @ObservedObject var ed: ReelEditor

    /// Roughly how big the file will be, from the length and the picture size.
    private func estimate(_ s: ReelSize) -> String {
        let px = s.render(source: CGSize(width: 1920, height: 1080))
        let mbps = 9.0 * Double(px.width * px.height) / (1920 * 1080) * ed.resolution * ed.resolution
        let mb = ed.editedLength * mbps / 8
        return mb >= 1000 ? String(format: "≈ %.1f GB", mb / 1000) : "≈ \(max(1, Int(mb.rounded()))) MB"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SC.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Export").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(SC.text)
                    Text("Tick the ones you need. Only those are saved.").font(.system(size: 11.5)).foregroundStyle(SC.dim)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("WHERE IT'S GOING").font(.system(size: 10.5, weight: .bold)).tracking(0.9).foregroundStyle(SC.dim)
                ForEach(ReelSize.allCases) { s in
                    let on = ed.toSave.contains(s)
                    Button {
                        withAnimation(SC.spring) { if on { ed.toSave.remove(s) } else { ed.toSave.insert(s) } }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 15))
                                .foregroundStyle(on ? AnyShapeStyle(SC.gradient) : AnyShapeStyle(SC.faint))
                            Image(systemName: s.icon).font(.system(size: 12)).foregroundStyle(SC.dim).frame(width: 16)
                            Text(s.ratio).font(.system(size: 13, weight: .semibold)).foregroundStyle(SC.text).frame(width: 64, alignment: .leading)
                            Text(s.use).font(.system(size: 12)).foregroundStyle(SC.dim).lineLimit(1)
                            Spacer()
                            Text(estimate(s)).font(.system(size: 11, design: .monospaced)).foregroundStyle(SC.faint)
                        }
                        .padding(.horizontal, 10).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? SC.wash(0.07) : SC.wash(0.02)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? SC.lineStrong : SC.line))
                    }
                    .buttonStyle(Springy(hoverScale: 1.01))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("QUALITY").font(.system(size: 10.5, weight: .bold)).tracking(0.9).foregroundStyle(SC.dim)
                Chips(options: [(2.0 / 3.0, "720p"), (1.0, "1080p"), (2.0, "4K")], selection: $ed.resolution)
            }
            Toggle("Move the original to the Bin afterwards", isOn: $ed.replaceOriginal).toggleStyle(.checkbox).font(.system(size: 12.5)).foregroundStyle(SC.dim)
            if let ex = ed.exporting {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(SC.wash(0.08))
                            Capsule().fill(SC.gradient).frame(width: max(6, g.size.width * ex.progress)).shadow(color: SC.accent.opacity(0.6), radius: 6)
                        }
                    }
                    .frame(height: 6)
                    Text("Saving \(ex.size.ratio)… \(Int(ex.progress * 100))%").font(.system(size: 11.5)).foregroundStyle(SC.dim)
                }
            } else if !ed.saved.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).symbolEffect(.bounce, value: ed.saved.count)
                    Text("\(ed.saved.count) video\(ed.saved.count == 1 ? "" : "s") saved").font(.system(size: 12.5, weight: .medium)).foregroundStyle(SC.text)
                    Spacer()
                    GhostButton(title: "Show", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting(ed.saved) }
                }
            }
            HStack {
                Text("Saved to Mercury Recordings › Reels").font(.system(size: 11)).foregroundStyle(SC.faint)
                Spacer()
                GlowButton(title: ed.toSave.isEmpty ? "Pick a shape" : "Export \(ed.toSave.count == 1 ? "1 video" : "\(ed.toSave.count) videos")", icon: "square.and.arrow.down") { ed.save() }
                    .disabled(ed.exporting != nil || ed.toSave.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(SC.panel)
        .environment(\.colorScheme, .dark)
        .presentationBackground(SC.panel)
    }
}

/// The progress bar under the preview: drag it, or click anywhere on it, to move through the video.
struct Scrubber: View {
    @ObservedObject var ed: ReelEditor
    @State private var hover = false
    @State private var dragging = false
    @State private var hoverX: CGFloat?
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let f = CGFloat(ed.editedLength > 0 ? min(1, ed.time / ed.editedLength) : 0)
            let tall = hover || dragging
            ZStack(alignment: .leading) {
                Capsule().fill(SC.wash(0.12)).frame(height: tall ? 7 : 4)
                // The clips, as faint gaps in the bar.
                ForEach(Array(ed.timeline.clips.dropFirst().enumerated()), id: \.offset) { _, c in
                    Rectangle().fill(SC.raised).frame(width: 2, height: tall ? 7 : 4).offset(x: w * CGFloat(c.out.start / max(0.01, ed.editedLength)) - 1)
                }
                Capsule().fill(SC.gradient).frame(width: max(4, f * w), height: tall ? 7 : 4).shadow(color: SC.accent.opacity(0.5), radius: tall ? 5 : 2)
                if let hx = hoverX, hover, !dragging {
                    Text(clock(Double(hx / max(1, w)) * ed.editedLength)).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.black.opacity(0.75)))
                        .fixedSize().offset(x: min(max(0, hx - 24), w - 52), y: -16)
                }
                Circle().fill(Color.white).frame(width: tall ? 15 : 0, height: tall ? 15 : 0)
                    .overlay(Circle().strokeBorder(SC.gradient, lineWidth: 3))
                    .shadow(color: SC.accent.opacity(0.7), radius: 5)
                    .offset(x: f * w - (tall ? 7.5 : 0))
            }
            .frame(height: 18)
            .animation(SC.spring, value: tall)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = true; hoverX = p.x
                case .ended: hover = false; hoverX = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !dragging { dragging = true; ed.player.pause() }
                    ed.seek(Double(min(1, max(0, v.location.x / max(1, w)))) * ed.editedLength)
                }
                .onEnded { _ in dragging = false })
        }
        .frame(height: 18)
        .help("Drag to move through the video")
    }
}
